
module Mongrel
  #
  # When a handler is found for a registered URI then this class is constructed
  # and passed to your HttpHandler::process method.  You should assume that 
  # *one* handler processes all requests.  Included in the HttpRequest is a
  # HttpRequest#params Hash that matches common CGI params, and a
  # HttpRequest#body which is a string containing the request body
  # (raw for now).
  #
  # The HttpRequest#initialize method will convert any request that is larger
  # than Const::MAX_BODY into a Tempfile and use that as the body.
  # Otherwise it uses a StringIO object. To be safe, you should assume it
  # works like a file.
  #
  class HttpRequest
    attr_reader :body, :params

    # You don't really call this.  It's made for you.
    # Main thing it does is hook up the params, and store any remaining
    # body data into the HttpRequest.body attribute.
    def initialize(params, socket, body)
      @params = params
      @socket = socket
      content_length = @params[Const::CONTENT_LENGTH].to_i

      remain = content_length - body.size
      
      # Some clients (like FF1.0) report 0 for body and then send a body.
      # This will probably truncate them but at least the request goes
      # through usually.
      #
      if remain <= 0
        # we've got everything, pack it up
        @body = StringIO.new body
      elsif remain > 0
        # must read more data to complete body
        if remain > Const::MAX_BODY
          # huge body, put it in a tempfile
          @body = Tempfile.new(Const::MONGREL_TMP_BASE)
          @body.binmode
        else
          # small body, just use that
          @body = StringIO.new 
        end

        @body.write body

        read_body remain, content_length
      end

      @body.rewind if @body
    end

    # Does the heavy lifting of properly reading the larger body requests in 
    # small chunks.  It expects @body to be an IO object, @socket to be valid,
    # and will set @body = nil if the request fails.  It also expects any
    # initial part of the body that has been read to be in the @body already.
    def read_body(remain, total)
      begin
        # write the odd sized chunk first
        chunk = read_socket(remain % Const::CHUNK_SIZE)

        remain -= @body.write(chunk)

        # then stream out nothing but perfectly sized chunks
        until remain <= 0 or @socket.closed?
          # ASSUME: we are writing to a disk and these writes always
          # write the requested amount
          chunk = read_socket(Const::CHUNK_SIZE)
          remain -= @body.write(chunk)
        end
      rescue RuntimeError
        # any errors means we should delete the file, including if the
        # file is dumped
        @socket.close rescue nil
        close_body

        raise BodyReadError
      end
    end

    def close_body
      @body.close! if @body.kind_of? IO
    end
 
    def read_socket(len)
      if @socket.closed?
        raise "Socket already closed when reading."
      else
        data = @socket.read(len)
        if !data
          raise "Socket read return nil"
        elsif data.length != len
          raise "Socket read returned insufficient data: #{data.length}"
        else
          data
        end
      end
    end

    # Performs URI escaping so that you can construct proper
    # query strings faster.  Use this rather than the cgi.rb
    # version since it's faster.  (Stolen from Camping).
    def self.escape(s)
      s.to_s.gsub(/([^ a-zA-Z0-9_.-]+)/n) {
        '%'+$1.unpack('H2'*$1.size).join('%').upcase
      }.tr(' ', '+') 
    end


    # Unescapes a URI escaped string. (Stolen from Camping).
    def self.unescape(s)
      s.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n){
        [$1.delete('%')].pack('H*')
      } 
    end

    # Parses a query string by breaking it up at the '&' 
    # and ';' characters.  You can also use this to parse
    # cookies by changing the characters used in the second
    # parameter (which defaults to '&;'.
    def self.query_parse(qs, d = '&;')
      params = {}
      (qs||'').split(/[#{d}] */n).inject(params) { |h,p|
        k, v=unescape(p).split('=',2)
        if cur = params[k]
          if cur.class == Array
            params[k] << v
          else
            params[k] = [cur, v]
          end
        else
          params[k] = v
        end
      }

      return params
    end
  end
end
