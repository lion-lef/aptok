module Aptok
  record KvStoreEntry, key : String, value : String

  module KvStore
    abstract def get(key : String) : String?
    abstract def set(key : String, value : String, ttl : Time::Span? = nil) : Nil
    abstract def delete(key : String) : Nil

    def cas(key : String, expected_value : String?, new_value : String, ttl : Time::Span? = nil) : Bool
      false
    end

    abstract def list(prefix : String? = nil) : Array(KvStoreEntry)
  end

  class MemoryKvStore
    include KvStore

    @values = Hash(String, Tuple(String, Time?)).new

    def get(key : String) : String?
      entry = @values[key]?
      return nil unless entry

      value, expires_at = entry
      if expires_at && Time.utc >= expires_at
        @values.delete(key)
        return nil
      end

      value
    end

    def set(key : String, value : String, ttl : Time::Span? = nil) : Nil
      expires_at = ttl ? Time.utc + ttl.not_nil! : nil
      @values[key] = {value, expires_at}
    end

    def delete(key : String) : Nil
      @values.delete(key)
    end

    def cas(key : String, expected_value : String?, new_value : String, ttl : Time::Span? = nil) : Bool
      current = get(key)
      return false unless current == expected_value

      set(key, new_value, ttl)
      true
    end

    def list(prefix : String? = nil) : Array(KvStoreEntry)
      now = Time.utc
      entries = [] of KvStoreEntry
      @values.each do |key, entry|
        value, expires_at = entry
        if expires_at && now >= expires_at
          @values.delete(key)
          next
        end
        next if prefix && !key.starts_with?(prefix.not_nil!)

        entries << KvStoreEntry.new(key, value)
      end
      entries.sort_by(&.key)
    end
  end

  record QueueMessage,
    queue : String,
    payload : JsonMap,
    attempts : Int32 = 0,
    available_at : Time = Time.utc,
    ordering_key : String? = nil

  record EnqueueOptions,
    delay : Time::Span? = nil,
    ordering_key : String? = nil

  record QueueDepth,
    queued : Int32,
    ready : Int32? = nil,
    delayed : Int32? = nil

  module MessageQueue
    abstract def enqueue(queue : String, payload : JsonMap, options : EnqueueOptions = EnqueueOptions.new) : Nil

    def enqueue_many(queue : String, payloads : Enumerable(JsonMap), options : EnqueueOptions = EnqueueOptions.new) : Nil
      payloads.each { |payload| enqueue(queue, payload, options) }
    end

    def native_retrial? : Bool
      false
    end

    def get_depth(queue : String, now : Time = Time.utc) : QueueDepth?
      nil
    end

    abstract def listen(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, limit : Int32? = nil, &handler : QueueMessage -> Nil) : Array(QueueProcessResult)
  end

  record RetryPolicy,
    max_attempts : Int32 = 10,
    initial_delay : Time::Span = Time::Span.new(seconds: 1),
    multiplier : Float64 = 2.0,
    max_delay : Time::Span = Time::Span.new(hours: 12),
    jitter : Bool = false

  enum QueueProcessResult
    Processed
    Retried
    Dead
    Deferred
  end

  class InProcessMessageQueue
    include MessageQueue

    getter messages : Array(QueueMessage)
    getter dead_messages : Array(QueueMessage)

    def initialize
      @messages = [] of QueueMessage
      @dead_messages = [] of QueueMessage
    end

    def enqueue(queue : String, payload : JsonMap, options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      if delay = options.delay
        available_at += delay
      end
      @messages << QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key)
    end

    def enqueue_many(queue : String, payloads : Enumerable(JsonMap), options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      if delay = options.delay
        available_at += delay
      end
      payloads.each do |payload|
        @messages << QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key)
      end
    end

    def drain(queue : String? = nil) : Array(QueueMessage)
      selected = queue ? @messages.select { |message| message.queue == queue } : @messages.dup
      if queue
        @messages.reject! { |message| message.queue == queue }
      else
        @messages.clear
      end
      selected
    end

    def depth(queue : String? = nil) : Int32
      queue ? @messages.count { |message| message.queue == queue } : @messages.size
    end

    def get_depth(queue : String, now : Time = Time.utc) : QueueDepth
      queued = 0
      ready = 0
      @messages.each do |message|
        next unless message.queue == queue

        queued += 1
        ready += 1 if message.available_at <= now
      end
      QueueDepth.new(queued, ready, queued - ready)
    end

    def ready(queue : String? = nil, now : Time = Time.utc) : Array(QueueMessage)
      @messages.select do |message|
        (queue.nil? || message.queue == queue) && message.available_at <= now
      end
    end

    def native_retrial? : Bool
      false
    end

    def process_one(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, &handler : QueueMessage -> Nil) : QueueProcessResult
      index = @messages.index { |message| message.queue == queue && message.available_at <= now }
      return QueueProcessResult::Deferred unless index

      message = @messages.delete_at(index)
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
          @dead_messages << retried
          QueueProcessResult::Dead
        else
          @messages << retried
          QueueProcessResult::Retried
        end
      end
    end

    def move_to_dead(message : QueueMessage) : Nil
      @messages.delete(message)
      @dead_messages << message
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

    def process_all(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, &handler : QueueMessage -> Nil) : Array(QueueProcessResult)
      results = [] of QueueProcessResult
      loop do
        result = process_one(queue, policy, now) { |message| handler.call(message) }
        break if result == QueueProcessResult::Deferred
        results << result
      end
      results
    end

    private def retry_delay(policy : RetryPolicy, attempts : Int32) : Time::Span
      seconds = policy.initial_delay.total_seconds * (policy.multiplier ** (attempts - 1))
      seconds = {seconds, policy.max_delay.total_seconds}.min
      seconds = seconds * (0.5 + Random.rand) if policy.jitter
      Time::Span.new(seconds: seconds.to_i)
    end
  end
end
