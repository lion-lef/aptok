require "json"

module Aptok
  class RedisMessageQueue
    private def decode_message(member : String) : QueueMessage?
      json = JSON.parse(member).as_h
      QueueMessage.new(
        json["queue"].as_s,
        json["payload"].as_h,
        json["attempts"]?.try(&.as_i) || 0,
        Time.unix_ms(json["available_at"].as_i64),
        json["ordering_key"]?.try(&.as_s?),
      )
    rescue
      nil
    end

    private def queue_key(queue : String) : String
      "#{@prefix}:queue:#{queue}:ready"
    end

    private def dead_key(queue : String) : String
      "#{@prefix}:queue:#{queue}:dead"
    end

    private def score(time : Time) : String
      time.to_unix_ms.to_s
    end

    private def retry_delay(policy : RetryPolicy, attempts : Int32) : Time::Span
      seconds = policy.initial_delay.total_seconds * (policy.multiplier ** (attempts - 1))
      seconds = {seconds, policy.max_delay.total_seconds}.min
      seconds = seconds * (0.5 + Random.rand) if policy.jitter
      Time::Span.new(seconds: seconds.to_i)
    end
  end
end
