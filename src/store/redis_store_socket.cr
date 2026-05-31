require "socket"
require "uri"
require "random/secure"

module Aptok
  alias RedisReply = String | Int64 | Array(String) | Nil

  module RedisCommandClient
    abstract def command(args : Array(String)) : RedisReply
  end

  class RedisProtocolClient
    include RedisCommandClient

    def self.from_url(url : String) : self
      uri = URI.parse(url)
      host = uri.host || "127.0.0.1"
      port = uri.port || 6379
      password = nil.as(String?)
      if userinfo = uri.userinfo
        password = userinfo.split(":", 2)[1]? || userinfo
      end
      path = uri.path
      database = path && path.size > 1 ? path.lstrip('/').to_i? : nil
      new(host, port, password, database)
    end

    def initialize(
      @host : String = "127.0.0.1",
      @port : Int32 = 6379,
      @password : String? = nil,
      @database : Int32? = nil
    )
      @socket = TCPSocket.new(@host, @port)
      command(["AUTH", password]) if (password = @password)
      command(["SELECT", database.to_s]) if (database = @database)
    end

    def command(args : Array(String)) : RedisReply
      write_command(args)
      read_reply
    end

    def close : Nil
      @socket.close
    end

    private def write_command(args : Array(String)) : Nil
      @socket << "*" << args.size << "\r\n"
      args.each do |arg|
        @socket << "$" << arg.bytesize << "\r\n" << arg << "\r\n"
      end
      @socket.flush
    end

    private def read_reply : RedisReply
      prefix = @socket.read_char
      raise IO::EOFError.new unless prefix
      case prefix
      when '+'
        @socket.gets("\r\n").to_s.chomp("\r\n")
      when '-'
        raise RedisError.new(@socket.gets("\r\n").to_s.chomp("\r\n"))
      when ':'
        @socket.gets("\r\n").to_s.to_i64
      when '$'
        length = @socket.gets("\r\n").to_s.to_i
        return nil if length < 0
        value = @socket.read_string(length)
        @socket.skip(2)
        value
      when '*'
        length = @socket.gets("\r\n").to_s.to_i
        return nil if length < 0
        values = [] of String
        length.times do
          value = read_reply
          values << value.to_s unless value.nil?
        end
        values
      else
        raise RedisError.new("unexpected Redis reply")
      end
    end
  end

  class RedisError < Exception
  end

  class RedisKvStore
    include KvStore

    CAS_SCRIPT = <<-LUA
      local current = redis.call("GET", KEYS[1])
      if ARGV[1] == "1" then
        if current ~= ARGV[2] then
          return 0
        end
      else
        if current ~= false then
          return 0
        end
      end
      if ARGV[3] == "" then
        redis.call("SET", KEYS[1], ARGV[4])
      else
        redis.call("PSETEX", KEYS[1], ARGV[3], ARGV[4])
      end
      return 1
      LUA

    def initialize(@client : RedisCommandClient, @prefix : String = "aptok")
    end

    def self.from_url(url : String, prefix : String = "aptok") : self
      new(RedisProtocolClient.from_url(url), prefix)
    end

    def get(key : String) : String?
      @client.command(["GET", namespaced(key)]).as?(String)
    end

    def set(key : String, value : String, ttl : Time::Span? = nil) : Nil
      args = ["SET", namespaced(key), value]
      if ttl
        args << "PX"
        args << ttl.total_milliseconds.to_i64.to_s
      end
      @client.command(args)
    end

    def delete(key : String) : Nil
      @client.command(["DEL", namespaced(key)])
    end

    def cas(key : String, expected_value : String?, new_value : String, ttl : Time::Span? = nil) : Bool
      result = @client.command([
        "EVAL",
        CAS_SCRIPT,
        "1",
        namespaced(key),
        expected_value.nil? ? "0" : "1",
        expected_value || "",
        ttl ? ttl.not_nil!.total_milliseconds.to_i64.to_s : "",
        new_value,
      ])
      result == 1_i64
    end

    def list(prefix : String? = nil) : Array(KvStoreEntry)
      pattern = namespaced(prefix || "") + "*"
      keys = @client.command(["KEYS", pattern]).as?(Array(String)) || [] of String
      keys.sort.compact_map do |stored_key|
        key = unnamespace(stored_key)
        next if prefix && !key.starts_with?(prefix.not_nil!)

        value = @client.command(["GET", stored_key]).as?(String)
        value ? KvStoreEntry.new(key, value) : nil
      end
    end

    private def namespaced(key : String) : String
      "#{@prefix}:kv:#{key}"
    end

    private def unnamespace(key : String) : String
      key.sub(/^#{Regex.escape("#{@prefix}:kv:")}/, "")
    end
  end

  class RedisMessageQueue
    include MessageQueue

    def initialize(@client : RedisCommandClient, @prefix : String = "aptok")
    end

    def self.from_url(url : String, prefix : String = "aptok") : self
      new(RedisProtocolClient.from_url(url), prefix)
    end

    def enqueue(queue : String, payload : JsonMap, options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      available_at += options.delay.not_nil! if options.delay
      message = QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key)
      @client.command(["ZADD", queue_key(queue), score(available_at), encode_message(message)])
    end

    def enqueue_many(queue : String, payloads : Enumerable(JsonMap), options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      available_at += options.delay.not_nil! if options.delay
      payloads.each do |payload|
        message = QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key)
        @client.command(["ZADD", queue_key(queue), score(available_at), encode_message(message)])
      end
    end

    def depth(queue : String) : Int32
      (@client.command(["ZCARD", queue_key(queue)]).as?(Int64) || 0_i64).to_i
    end

    def get_depth(queue : String, now : Time = Time.utc) : QueueDepth
      queued = depth(queue)
      ready = (@client.command(["ZCOUNT", queue_key(queue), "-inf", score(now)]).as?(Int64) || 0_i64).to_i
      QueueDepth.new(queued, ready, queued - ready)
    end

    def ready(queue : String, now : Time = Time.utc, limit : Int32 = 1) : Array(QueueMessage)
      members = @client.command([
        "ZRANGEBYSCORE",
        queue_key(queue),
        "-inf",
        score(now),
        "LIMIT",
        "0",
        limit.to_s,
      ]).as?(Array(String)) || [] of String
      members.compact_map { |member| decode_message(member) }
    end

    def process_one(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, &handler : QueueMessage -> Nil) : QueueProcessResult
      member = ready_member(queue, now)
      return QueueProcessResult::Deferred unless member
      removed = @client.command(["ZREM", queue_key(queue), member]).as?(Int64) || 0_i64
      return QueueProcessResult::Deferred unless removed > 0

      message = decode_message(member)
      return QueueProcessResult::Deferred unless message

      begin
        handler.call(message)
        QueueProcessResult::Processed
      rescue
        attempts = message.attempts + 1
        retried = QueueMessage.new(
          message.queue,
          message.payload,
          attempts,
          now + retry_delay(policy, attempts),
          message.ordering_key
        )
        if attempts >= policy.max_attempts
          @client.command(["ZADD", dead_key(queue), score(retried.available_at), encode_message(retried)])
          QueueProcessResult::Dead
        else
          @client.command(["ZADD", queue_key(queue), score(retried.available_at), encode_message(retried)])
          QueueProcessResult::Retried
        end
      end
    end

    def listen(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, limit : Int32? = nil, &handler : QueueMessage -> Nil) : Array(QueueProcessResult)
      results = [] of QueueProcessResult
      loop do
        break if limit && results.size >= limit
        result = process_one(queue, policy, now) { |message| handler.call(message) }
        break if result == QueueProcessResult::Deferred
        results << result
      end
      results
    end

    private def ready_member(queue : String, now : Time) : String?
      members = @client.command(["ZRANGEBYSCORE", queue_key(queue), "-inf", score(now), "LIMIT", "0", "1"]).as?(Array(String))
      members.try(&.first?)
    end

    private def encode_message(message : QueueMessage) : String
      JsonMap{
        "id"           => Aptok.json(Random::Secure.hex(12)),
        "queue"        => Aptok.json(message.queue),
        "payload"      => Aptok.json(message.payload),
        "attempts"     => Aptok.json(message.attempts),
        "available_at" => Aptok.json(message.available_at.to_unix_ms),
      }.tap do |json|
        json["ordering_key"] = Aptok.json(message.ordering_key) if message.ordering_key
      end.to_json
    end
  end
end
