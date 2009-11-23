module Stomp

  # Low level connection which maps commands and supports
  # synchronous receives
  class Connection

    alias :obj_send :send
    # A new Connection object accepts the following parameters:
    #
    #   login             (String,  default : '')
    #   passcode          (String,  default : '')
    #   host              (String,  default : 'localhost')
    #   port              (Integer, default : 61613)
    #   reliable          (Boolean, default : false)
    #   reconnect_delay   (Integer, default : 5)
    #
    #   e.g. c = Client.new("username", "password", "localhost", 61613, true)
    #
# TODO
    # Stomp URL :
    #   A Stomp URL must begin with 'stomp://' and can be in one of the following forms:
    #
    #   stomp://host:port
    #   stomp://host.domain.tld:port
    #   stomp://user:pass@host:port
    #   stomp://user:pass@host.domain.tld:port
    #
    def initialize(login = '', passcode = '', host = 'localhost', port = 61613, reliable = false, reconnect_delay = 5, connect_headers = {})
      if login.is_a?(Hash)
        hashed_initialize(login)
      else
        @host = host
        @port = port
        @login = login
        @passcode = passcode
        @reliable = reliable
        @reconnect_delay = reconnect_delay
        @connect_headers = connect_headers
        @ssl = false
        @failover = nil
      end
      
      @transmit_semaphore = Mutex.new
      @read_semaphore = Mutex.new
      @socket_semaphore = Mutex.new
      
      @closed = false
      @subscriptions = {}
      @failure = nil
      @connection_attempts = 0
      
      socket
    end
    
    def hashed_initialize(params)
      @failover = params
      @reliable = true
      @reconnect_delay = @failover[:initialReconnectDelay]
      @connect_headers = params[:headers] || {}
      
      change_master
    end
    
    def Connection.open_with_failover(failover, connect_headers = {})
      failover[:headers] = connect_headers
      
      Connection.new(failover)
    end

    # Syntactic sugar for 'Connection.new' See 'initialize' for usage.
    def Connection.open(login = '', passcode = '', host = 'localhost', port = 61613, reliable = false, reconnect_delay = 5, connect_headers = {})
      Connection.new(login, passcode, host, port, reliable, reconnect_delay, connect_headers)
    end

    def socket
      # Need to look into why the following synchronize does not work.
      #@read_semaphore.synchronize do
      
        s = @socket;
        
        s = nil unless connected?
        
        while s.nil? || !@failure.nil?
          @failure = nil
          begin
            s = open_socket
			
	        headers = @connect_headers.clone
	        headers[:login] = @login
	        headers[:passcode] = @passcode
            _transmit(s, "CONNECT", headers)
            @connect = _receive(s)
            # replay any subscriptions.
            @subscriptions.each { |k,v| _transmit(s, "SUBSCRIBE", v) }
            
            @connection_attempts = 0
          rescue
            @failure = $!;
            s=nil;
            raise unless @reliable
            $stderr.print "connect to #{@host} failed: " + $! +" will retry(##{@connection_attempts}) in #{@reconnect_delay}\n";

            raise "Max number of reconnection attempts reached" if max_reconnect_attempts?

            sleep(@reconnect_delay);
            
            @connection_attempts += 1
            
            if @failover
              change_master
              increase_reconnect_delay
            end
          end
        end
        @socket = s
        return s;
      #end
    end
    
    def connected?
      begin
        TCPSocket.open @host, @port
        true
      rescue
        false
      end
    end

	def open_socket
	  return TCPSocket.open @host, @port unless @ssl
    
    require 'openssl'
	  tcp_socket = TCPSocket.new @host, @port
	  ssl = OpenSSL::SSL::SSLSocket.new(tcp_socket)
	  ssl.connect
	  ssl
	end
    
    def change_master
      @failover[:hosts].shuffle! if @failover[:randomize]
      
      # Set first as master and send it to the end of array
      master_data = @failover[:hosts].shift
      @failover[:hosts] << master_data
      
      @host = master_data[:host]
      @port = master_data[:port]
      @login = master_data[:login]
      @passcode = master_data[:passcode]
      @ssl = master_data[:ssl]
    end
    
    def max_reconnect_attempts?
      !(@failover.nil? || @failover[:maxReconnectAttempts].nil?) && @failover[:maxReconnectAttempts] != 0 && @connection_attempts > @failover[:maxReconnectAttempts]
    end
    
    def increase_reconnect_delay

      @reconnect_delay *= @failover[:backOffMultiplier] if @failover[:useExponentialBackOff] 
      
      @reconnect_delay = @failover[:maxReconnectDelay] if @reconnect_delay > @failover[:maxReconnectDelay]
      
      @reconnect_delay
    end

    # Is this connection open?
    def open?
      !@closed
    end

    # Is this connection closed?
    def closed?
      @closed
    end

    # Begin a transaction, requires a name for the transaction
    def begin(name, headers = {})
      headers[:transaction] = name
      transmit("BEGIN", headers)
    end

    # Acknowledge a message, used when a subscription has specified
    # client acknowledgement ( connection.subscribe "/queue/a", :ack => 'client'g
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def ack(message_id, headers = {})
      headers['message-id'] = message_id
      transmit("ACK", headers)
    end

    # Commit a transaction by name
    def commit(name, headers = {})
      headers[:transaction] = name
      transmit("COMMIT", headers)
    end

    # Abort a transaction by name
    def abort(name, headers = {})
      headers[:transaction] = name
      transmit("ABORT", headers)
    end

    # Subscribe to a destination, must specify a name
    def subscribe(name, headers = {}, subId = nil)
      headers[:destination] = name
      transmit("SUBSCRIBE", headers)

      # Store the sub so that we can replay if we reconnect.
      if @reliable
        subId = name if subId.nil?
        @subscriptions[subId] = headers
      end
    end

    # Unsubscribe from a destination, must specify a name
    def unsubscribe(name, headers = {}, subId = nil)
      headers[:destination] = name
      transmit("UNSUBSCRIBE", headers)
      if @reliable
        subId = name if subId.nil?
        @subscriptions.delete(subId)
      end
    end

    # Send message to destination
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def send(destination, message, headers = {})
      headers[:destination] = destination
      transmit("SEND", headers, message)
    end

    # Close this connection
    def disconnect(headers = {})
      transmit("DISCONNECT", headers)
      @closed = true
    end

    # Return a pending message if one is available, otherwise
    # return nil
    def poll
      @read_semaphore.synchronize do
        return nil if @socket.nil? || !@socket.ready?
        return receive
      end
    end

    # Receive a frame, block until the frame is received
    def __old_receive
      # The recive my fail so we may need to retry.
      while TRUE
        begin
          s = socket
          return _receive(s)
        rescue
          @failure = $!;
          raise unless @reliable
          $stderr.print "receive failed: " + $!;
        end
      end
    end

    def receive
      super_result = __old_receive()
      if super_result.nil? && @reliable
        $stderr.print "connection.receive returning EOF as nil - resetting connection.\n"
        @socket = nil
        super_result = __old_receive()
      end
      return super_result
    end

    private

      def _receive( s )
        line = ' '
        @read_semaphore.synchronize do
          line = s.gets while line =~ /^\s*$/
          return nil if line.nil?

          message = Message.new do |m|
            m.command = line.chomp
            m.headers = {}
            until (line = s.gets.chomp) == ''
              k = (line.strip[0, line.strip.index(':')]).strip
              v = (line.strip[line.strip.index(':') + 1, line.strip.length]).strip
              m.headers[k] = v
            end

            if (m.headers['content-length'])
              m.body = s.read m.headers['content-length'].to_i
              c = RUBY_VERSION > '1.9' ? s.getc.ord : s.getc
              raise "Invalid content length received" unless c == 0
            else
              m.body = ''
              if RUBY_VERSION > '1.9'
                until (c = s.getc.ord) == 0
                  m.body << c.chr
                end
              else
                until (c = s.getc) == 0
                  m.body << c.chr
                end
              end
            end
            #c = s.getc
            #raise "Invalid frame termination received" unless c == 10
          end # message
          return message

        end
      end

      def transmit(command, headers = {}, body = '')
        # The transmit may fail so we may need to retry.
        while TRUE
          begin
            s = socket
            _transmit(s, command, headers, body)
            return
          rescue
            @failure = $!;
            raise unless @reliable
            $stderr.print "transmit to #{@host} failed: " + $!+"\n";
          end
        end
      end

      def _transmit(s, command, headers = {}, body = '')
        @transmit_semaphore.synchronize do
          s.puts command
          headers.each {|k,v| s.puts "#{k}:#{v}" }
          s.puts "content-length: #{body.length}"
          s.puts "content-type: text/plain; charset=UTF-8"
          s.puts
          s.write body
          s.write "\0"
        end
      end

  end

end
