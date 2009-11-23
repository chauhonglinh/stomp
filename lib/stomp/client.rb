module Stomp

  # Typical Stomp client class. Uses a listener thread to receive frames
  # from the server, any thread can send.
  #
  # Receives all happen in one thread, so consider not doing much processing
  # in that thread if you have much message volume.
  class Client

    attr_reader :login, :passcode, :host, :port, :reliable, :running, :failover
    alias :obj_send :send

    # A new Client object can be initialized using two forms:
    #
    # Standard positional parameters:
    #   login     (String,  default : '')
    #   passcode  (String,  default : '')
    #   host      (String,  default : 'localhost')
    #   port      (Integer, default : 61613)
    #   reliable  (Boolean, default : false)
    #
    #   e.g. c = Client.new('login', 'passcode', 'localhost', 61613, true)
    #
    # Stomp URL :
    #   A Stomp URL must begin with 'stomp://' and can be in one of the following forms:
    #
    #   stomp://host:port
    #   stomp://host.domain.tld:port
    #   stomp://login:passcode@host:port
    #   stomp://login:passcode@host.domain.tld:port
    #
    def initialize(login = '', passcode = '', host = 'localhost', port = 61613, reliable = false)

      # Parse stomp:// URL's or set positional params
      case login
      when /^stomp:\/\/(([\w\.]+):(\w+)@)?([\w\.]+):(\d+)/ # e.g. stomp://login:passcode@host:port or stomp://host:port
        @login = $2 || ""
        @passcode = $3 || ""
        @host = $4
        @port = $5.to_i
        @reliable = false
      when /^failover:(\/\/)?\(stomp(\+ssl)?:\/\/(([\w\.]*):(\w*)@)?([\w\.]+):(\d+)(,stomp(\+ssl)?:\/\/(([\w\.]*):(\w*)@)?([\w\.]+):(\d+)\))+(\?(.*))?$/ # e.g. failover://(stomp://login1:passcode1@localhost:61616,stomp://login2:passcode2@remotehost:61617)

        master = {}
        master[:ssl] = !$2.nil?
        @login = master[:login] = $4 || ""
        @passcode = master[:passcode] = $5 || ""
        @host = master[:host] = $6
        @port = master[:port] = $7.to_i
        
        options = $16 || ""
        parts = options.split(/&|=/)
        options = Hash[*parts]
        
        
        hosts = [master] + parse_hosts(login)
        
        @failover = {}
        @failover[:hosts] = hosts
        
        @failover.merge! refine_options(options)
                
        @reliable = true
      else
        @login = login
        @passcode = passcode
        @host = host
        @port = port.to_i
        @reliable = reliable
      end

      raise ArgumentError if @host.nil? || @host.empty?
      raise ArgumentError if @port.nil? || @port == '' || @port < 1 || @port > 65535
      raise ArgumentError unless @reliable.is_a?(TrueClass) || @reliable.is_a?(FalseClass)

      @id_mutex = Mutex.new
      @ids = 1

      if @failover
        @connection = Connection.open_with_failover(@failover)
      else
        @connection = Connection.new(@login, @passcode, @host, @port, @reliable)
      end
      
      @listeners = {}
      @receipt_listeners = {}
      @running = true
      @replay_messages_by_txn = {}

      @listener_thread = Thread.start do
        while @running
          message = @connection.receive
          case
          when message.nil?
            break
          when message.command == 'MESSAGE'
            if listener = @listeners[message.headers['destination']]
              listener.call(message)
            end
          when message.command == 'RECEIPT'
            if listener = @receipt_listeners[message.headers['receipt-id']]
              listener.call(message)
            end
          end
        end
      end

    end
    
    # Syntactic sugar for 'Client.new' See 'initialize' for usage.
    def self.open(login = '', passcode = '', host = 'localhost', port = 61613, reliable = false)
      Client.new(login, passcode, host, port, reliable)
    end

    # Join the listener thread for this client,
    # generally used to wait for a quit signal
    def join
      @listener_thread.join
    end

    # Begin a transaction by name
    def begin(name, headers = {})
      @connection.begin(name, headers)
    end

    # Abort a transaction by name
    def abort(name, headers = {})
      @connection.abort(name, headers)

      # lets replay any ack'd messages in this transaction
      replay_list = @replay_messages_by_txn[name]
      if replay_list
        replay_list.each do |message|
          if listener = @listeners[message.headers['destination']]
            listener.call(message)
          end
        end
      end
    end

    # Commit a transaction by name
    def commit(name, headers = {})
      txn_id = headers[:transaction]
      @replay_messages_by_txn.delete(txn_id)
      @connection.commit(name, headers)
    end

    # Subscribe to a destination, must be passed a block
    # which will be used as a callback listener
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def subscribe(destination, headers = {})
      raise "No listener given" unless block_given?
      @listeners[destination] = lambda {|msg| yield msg}
      @connection.subscribe(destination, headers)
    end

    # Unsubecribe from a channel
    def unsubscribe(name, headers = {})
      @connection.unsubscribe(name, headers)
      @listeners[name] = nil
    end

    # Acknowledge a message, used when a subscription has specified
    # client acknowledgement ( connection.subscribe "/queue/a", :ack => 'client'g
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def acknowledge(message, headers = {})
      txn_id = headers[:transaction]
      if txn_id
        # lets keep around messages ack'd in this transaction in case we rollback
        replay_list = @replay_messages_by_txn[txn_id]
        if replay_list.nil?
          replay_list = []
          @replay_messages_by_txn[txn_id] = replay_list
        end
        replay_list << message
      end
      if block_given?
        headers['receipt'] = register_receipt_listener lambda {|r| yield r}
      end
      @connection.ack message.headers['message-id'], headers
    end

    # Send message to destination
    #
    # If a block is given a receipt will be requested and passed to the
    # block on receipt
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def send(destination, message, headers = {})
      if block_given?
        headers['receipt'] = register_receipt_listener lambda {|r| yield r}
      end
      @connection.send(destination, message, headers)
    end

    # Is this client open?
    def open?
      @connection.open?
    end

    # Is this client closed?
    def closed?
      @connection.closed?
    end

    # Close out resources in use by this client
    def close
      @connection.disconnect
      @running = false
    end

    private

      def register_receipt_listener(listener)
        id = -1
        @id_mutex.synchronize do
          id = @ids.to_s
          @ids = @ids.succ
        end
        @receipt_listeners[id] = listener
        id
      end
      
      def parse_hosts(url)
        hosts = []
        
        host_match = /,stomp(\+ssl)?:\/\/(([\w\.]*):(\w*)@)?([\w\.]+):(\d+)\)/
        url.scan(host_match).each do |match|
          host = {}
          host[:ssl] = !match[0].nil?
          host[:login] =  match[2] || ""
          host[:passcode] = match[3] || ""
          host[:host] = match[4]
          host[:port] = match[5].to_i
          
          hosts << host
        end
        
        hosts
      end
      
      def refine_options(options)
        new_options = {}
        new_options[:initialReconnectDelay] = (options["initialReconnectDelay"] || 10).to_f / 1000 # In ms
        new_options[:maxReconnectDelay] = (options["maxReconnectDelay"] || 30000 ).to_f / 1000 # In ms
        new_options[:useExponentialBackOff] = !(options["useExponentialBackOff"] == "false") # Default: true
        new_options[:backOffMultiplier] = (options["backOffMultiplier"] || 2 ).to_i
        new_options[:maxReconnectAttempts] = (options["maxReconnectAttempts"] || 0 ).to_i
        new_options[:randomize] = options["randomize"] == "true" # Default: false
        new_options[:backup] = false # Not implemented yet: I'm using a master X slave solution
        new_options[:timeout] = -1 # Not implemented yet: a "timeout(5) do ... end" would do the trick, feel free
        
        new_options
      end

  end
end
