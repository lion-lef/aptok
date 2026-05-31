require "socket"
require "uri"
require "base64"
require "random/secure"
require "openssl/hmac"
require "openssl/pkcs5"
require "digest/sha256"
require "digest/md5"

module Aptork
  # A `SqlConnection` backed by PostgreSQL, speaking the v3 wire protocol over a
  # plain `TCPSocket`. It is **pure Crystal** — no external shard or `libpq`
  # required — so it builds as part of the default toolkit.
  #
  # Authentication supports the trust, cleartext, MD5, and SCRAM-SHA-256
  # methods (SCRAM is the default on modern PostgreSQL). Queries use the
  # extended protocol with text-format parameters and results.
  #
  # ```
  # conn = Aptork::PostgresConnection.connect("postgres://user:pass@localhost/aptork")
  # store = Aptork::SqlKvStore.new(conn, dialect: Aptork::SqlDialect::Postgres)
  # queue = Aptork::SqlMessageQueue.new(conn, dialect: Aptork::SqlDialect::Postgres)
  # ```
  class PostgresConnection
    include SqlConnection

    PROTOCOL_VERSION = 196608 # 3.0

    class Error < Exception
    end

    # Connects using a `postgres://user:password@host:port/database` URL.
    def self.connect(url : String) : PostgresConnection
      uri = URI.parse(url)
      host = uri.host || "localhost"
      port = uri.port || 5432
      user = uri.user || "postgres"
      password = uri.password || ""
      database = uri.path.lchop('/')
      database = user if database.empty?
      new(host, port, user, password, database)
    end

    def initialize(host : String, port : Int32, @user : String, @password : String, database : String)
      @socket = TCPSocket.new(host, port)
      @socket.tcp_nodelay = true
      @mutex = Mutex.new
      startup(database)
    end

    def execute(sql : String, args : Array(SqlValue)) : Int64
      @mutex.synchronize do
        affected = 0_i64
        run_extended(sql, args) do |_row, command_tag|
          affected = parse_affected(command_tag) if command_tag
        end
        affected
      end
    end

    def query(sql : String, args : Array(SqlValue)) : Array(Array(SqlValue))
      @mutex.synchronize do
        rows = [] of Array(SqlValue)
        run_extended(sql, args) do |row, _tag|
          rows << row if row
        end
        rows
      end
    end

    def close : Nil
      @mutex.synchronize do
        write_message('X') { }
        @socket.flush
        @socket.close
      rescue
        # best-effort terminate
      end
    end

    # --- connection startup & authentication -------------------------------

    private def startup(database : String) : Nil
      body = IO::Memory.new
      body.write_bytes(PROTOCOL_VERSION, IO::ByteFormat::BigEndian)
      write_cstring(body, "user")
      write_cstring(body, @user)
      write_cstring(body, "database")
      write_cstring(body, database)
      body.write_byte(0_u8)
      send_raw(nil, body.to_slice)

      loop do
        type, payload = read_message
        case type
        when 'R' then break if handle_auth(payload)
        when 'E' then raise server_error(payload)
        else
          raise Error.new("unexpected message '#{type}' during startup")
        end
      end

      # Drain ParameterStatus / BackendKeyData until ReadyForQuery.
      loop do
        type, payload = read_message
        case type
        when 'Z' then break
        when 'E' then raise server_error(payload)
        else # ignore 'S', 'K', 'N', etc.
        end
      end
    end

    # Returns true when authentication is complete (AuthenticationOk).
    private def handle_auth(payload : Bytes) : Bool
      io = IO::Memory.new(payload)
      code = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
      case code
      when 0 # AuthenticationOk
        true
      when 3 # cleartext password
        send_password(@password)
        false
      when 5 # MD5 password
        salt = Bytes.new(4)
        io.read_fully(salt)
        send_password(md5_auth(salt))
        false
      when 10 # SASL
        scram_authenticate
        false
      else
        raise Error.new("unsupported authentication method: #{code}")
      end
    end

    private def send_password(value : String) : Nil
      write_message('p') { |io| write_cstring(io, value) }
    end

    private def md5_auth(salt : Bytes) : String
      inner = Digest::MD5.hexdigest(@password + @user)
      combined = IO::Memory.new
      combined << inner
      combined.write(salt)
      "md5" + Digest::MD5.hexdigest(combined.to_slice)
    end

    private def scram_authenticate : Nil
      cnonce = Base64.strict_encode(Random::Secure.random_bytes(18))
      client_first_bare = "n=,r=#{cnonce}"
      client_first = "n,,#{client_first_bare}"

      write_message('p') do |io|
        write_cstring(io, "SCRAM-SHA-256")
        io.write_bytes(client_first.bytesize, IO::ByteFormat::BigEndian)
        io << client_first
      end

      type, payload = read_message
      raise server_error(payload) if type == 'E'
      raise Error.new("expected SASL continue") unless type == 'R'
      io = IO::Memory.new(payload)
      raise Error.new("expected SASL continue") unless io.read_bytes(Int32, IO::ByteFormat::BigEndian) == 11
      server_first = io.gets_to_end

      attrs = parse_scram(server_first)
      server_nonce = attrs["r"]
      salt = Base64.decode(attrs["s"])
      iterations = attrs["i"].to_i

      salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, salt, iterations, OpenSSL::Algorithm::SHA256, 32)
      client_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salted, "Client Key")
      stored_key = Digest::SHA256.digest(client_key)

      client_final_bare = "c=biws,r=#{server_nonce}"
      auth_message = "#{client_first_bare},#{server_first},#{client_final_bare}"
      client_signature = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, stored_key, auth_message)
      proof = xor(client_key, client_signature)

      write_message('p') do |io2|
        io2 << client_final_bare << ",p=" << Base64.strict_encode(proof)
      end

      # AuthenticationSASLFinal — verify the server signature.
      type, payload = read_message
      raise server_error(payload) if type == 'E'
      raise Error.new("expected SASL final") unless type == 'R'
      io3 = IO::Memory.new(payload)
      raise Error.new("expected SASL final") unless io3.read_bytes(Int32, IO::ByteFormat::BigEndian) == 12
      final = parse_scram(io3.gets_to_end)
      server_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salted, "Server Key")
      expected = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, server_key, auth_message)
      unless final["v"]? && Base64.decode(final["v"]) == expected
        raise Error.new("SCRAM server signature mismatch")
      end
    end

    private def parse_scram(message : String) : Hash(String, String)
      message.split(',').to_h do |part|
        key, _, value = part.partition('=')
        {key, value}
      end
    end

    private def xor(a : Bytes, b : Bytes) : Bytes
      out = Bytes.new(a.size)
      a.size.times { |i| out[i] = a[i] ^ b[i] }
      out
    end

    # --- extended query protocol ------------------------------------------

    private def run_extended(sql : String, args : Array(SqlValue), &block : Array(SqlValue)?, String? ->) : Nil
      write_message('P') do |io| # Parse (unnamed)
        write_cstring(io, "")
        write_cstring(io, sql)
        io.write_bytes(0_i16, IO::ByteFormat::BigEndian)
      end
      write_message('B') do |io| # Bind (unnamed)
        write_cstring(io, "")
        write_cstring(io, "")
        io.write_bytes(0_i16, IO::ByteFormat::BigEndian) # 0 param format codes => all text
        io.write_bytes(args.size.to_i16, IO::ByteFormat::BigEndian)
        args.each { |value| write_param(io, value) }
        io.write_bytes(0_i16, IO::ByteFormat::BigEndian) # 0 result format codes => all text
      end
      write_message('D') { |io| io.write_byte('P'.ord.to_u8); write_cstring(io, "") }                     # Describe portal
      write_message('E') { |io| write_cstring(io, ""); io.write_bytes(0_i32, IO::ByteFormat::BigEndian) } # Execute
      write_message('S') { }                                                                              # Sync
      @socket.flush

      error : Error? = nil
      loop do
        type, payload = read_message
        case type
        when 'D' # DataRow
          block.call(parse_data_row(payload), nil)
        when 'C' # CommandComplete
          block.call(nil, String.new(payload[0, payload.size - 1]))
        when 'E' # ErrorResponse
          error = server_error(payload)
        when 'Z' # ReadyForQuery
          break
        else
          # '1' ParseComplete, '2' BindComplete, 'T' RowDescription, 'n' NoData,
          # 'S' ParameterStatus, 'N' NoticeResponse — ignored.
        end
      end
      raise error if error
    end

    private def write_param(io : IO, value : SqlValue) : Nil
      case value
      when Nil
        io.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
      else
        text = value.is_a?(String) ? value : value.to_s
        io.write_bytes(text.bytesize.to_i32, IO::ByteFormat::BigEndian)
        io << text
      end
    end

    private def parse_data_row(payload : Bytes) : Array(SqlValue)
      io = IO::Memory.new(payload)
      count = io.read_bytes(Int16, IO::ByteFormat::BigEndian)
      row = Array(SqlValue).new(count)
      count.times do
        length = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        if length < 0
          row << nil
        else
          bytes = Bytes.new(length)
          io.read_fully(bytes)
          row << String.new(bytes)
        end
      end
      row
    end

    private def parse_affected(command_tag : String) : Int64
      command_tag.split(' ').last?.try(&.to_i64?) || 0_i64
    end

    # --- framing helpers ---------------------------------------------------

    private def write_message(type : Char, &) : Nil
      body = IO::Memory.new
      yield body
      send_raw(type, body.to_slice)
    end

    private def send_raw(type : Char?, body : Bytes) : Nil
      @socket.write_byte(type.ord.to_u8) if type
      @socket.write_bytes((body.size + 4).to_i32, IO::ByteFormat::BigEndian)
      @socket.write(body)
    end

    private def read_message : Tuple(Char, Bytes)
      type = @socket.read_byte || raise Error.new("connection closed")
      length = @socket.read_bytes(Int32, IO::ByteFormat::BigEndian)
      body = Bytes.new(length - 4)
      @socket.read_fully(body) if body.size > 0
      {type.chr, body}
    end

    private def write_cstring(io : IO, value : String) : Nil
      io << value
      io.write_byte(0_u8)
    end

    private def server_error(payload : Bytes) : Error
      fields = {} of Char => String
      io = IO::Memory.new(payload)
      loop do
        code = io.read_byte
        break if code.nil? || code == 0
        fields[code.chr] = io.gets('\0', chomp: true) || ""
      end
      Error.new("postgres error: #{fields['M']? || "unknown"} (#{fields['C']?})")
    end
  end
end
