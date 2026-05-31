module Aptok
  class Context
    def enqueue_fanout_activity(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : EnqueueOptions = EnqueueOptions.new,
      collection_name : String? = nil,
      sync_collection : Bool = false,
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : Nil
      queue = @federation.fanout_queue
      raise ArgumentError.new("fanout queue is not configured") unless queue

      payload = @federation.fanout_delivery_payload(sender_identifier, recipients, activity, collection_name, sync_collection, sender_key_pairs)
      queue.enqueue(@federation.fanout_queue_name, payload, options)
      @federation.auto_start_queue(@data)
    end

    def enqueue_activity(
      sender : NamedTuple(identifier: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : EnqueueOptions = EnqueueOptions.new,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(QueuedActivity)
      enqueue_activity(sender[:identifier], recipients, activity, options, collection_name, sync_collection)
    end

    def enqueue_activity(
      sender : NamedTuple(username: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : EnqueueOptions = EnqueueOptions.new,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(QueuedActivity)
      enqueue_activity(identifier_from_username(sender[:username]), recipients, activity, options, collection_name, sync_collection)
    end

    def process_queued_activities(
      now : Time = Time.utc,
      limit : Int32? = nil
    ) : Array(QueueProcessResult)
      queue = @federation.outbox_queue
      raise ArgumentError.new("outbox queue is not configured") unless queue
      in_process_queue = queue.as?(InProcessMessageQueue)
      unless in_process_queue
        return queue.listen(@federation.outbox_queue_name, @federation.outbox_retry_policy, now, limit) do |message|
          begin
            process_queued_task(message.payload)
          rescue ex : DeliveryError
            if context = @federation.outbox_failure_context(message.payload)
              delivery, activity = context
              if @federation.permanent_delivery_failure?(ex)
                @federation.handle_outbox_permanent_failure(self, delivery, activity, ex)
              else
                @federation.handle_outbox_error(self, delivery, activity, ex, message.attempts + 1)
                raise ex
              end
            end
          end
          nil
        end
      end

      results = [] of QueueProcessResult
      loop do
        break if limit && results.size >= limit

        message = in_process_queue.ready(@federation.outbox_queue_name, now).first?
        break unless message

        delivery_error = nil.as(DeliveryError?)
        result = in_process_queue.process_one(@federation.outbox_queue_name, @federation.outbox_retry_policy, now) do |_message|
          begin
            process_queued_task(message.payload)
          rescue ex : DeliveryError
            delivery_error = ex
            raise ex
          end
          nil
        end

        if error = delivery_error
          if context = @federation.outbox_failure_context(message.payload)
            delivery, activity = context
            if @federation.permanent_delivery_failure?(error)
              if result == QueueProcessResult::Retried
                retried = in_process_queue.messages.last?
                if retried && retried.payload == message.payload
                  in_process_queue.messages.delete(retried)
                  in_process_queue.dead_messages << retried
                end
                result = QueueProcessResult::Dead
              end
              @federation.handle_outbox_permanent_failure(self, delivery, activity, error)
            else
              @federation.handle_outbox_error(self, delivery, activity, error, message.attempts + 1)
            end
          end
        end

        results << result unless result == QueueProcessResult::Deferred
        break if result == QueueProcessResult::Deferred
      end
      results
    end

    def process_queued_fanout_activities(
      now : Time = Time.utc,
      limit : Int32? = nil
    ) : Array(QueueProcessResult)
      queue = @federation.fanout_queue
      raise ArgumentError.new("fanout queue is not configured") unless queue
      queue.listen(@federation.fanout_queue_name, @federation.fanout_retry_policy, now, limit) do |message|
        process_queued_task(message.payload)
        nil
      end
    end

    def process_queued_inbox_activities(
      now : Time = Time.utc,
      limit : Int32? = nil
    ) : Array(QueueProcessResult)
      queue = @federation.inbox_queue
      raise ArgumentError.new("inbox queue is not configured") unless queue
      queue.listen(@federation.inbox_queue_name, @federation.inbox_retry_policy, now, limit) do |message|
        process_queued_task(message.payload)
        nil
      end
    end

    def process_queued_task(payload : JsonMap) : Bool
      case payload["type"]?.try(&.as_s?)
      when "OutboundDelivery"
        delivery, activity = @federation.parse_outbound_delivery(payload)
        sender_key_pairs = @federation.parse_outbound_delivery_sender_key_pairs(payload)
        process_outbound_delivery(delivery, activity, sender_key_pairs)
        true
      when "ForwardedDelivery"
        forwarder_identifier, delivery, activity, raw_payload, source_headers = @federation.parse_forwarded_delivery(payload)
        sender_key_pairs = @federation.parse_forwarded_delivery_sender_key_pairs(payload)
        process_forwarded_delivery(forwarder_identifier, delivery, activity, raw_payload, source_headers, sender_key_pairs)
        true
      when "InboundDelivery"
        recipient_identifier, activity, trusted = @federation.parse_inbound_delivery(payload)
        handled = route_activity(recipient_identifier, activity, RouteActivityOptions.new(immediate: true, trusted: trusted))
        raise "inbox activity had no matching listener" unless handled
        true
      when "FanoutDelivery"
        sender_identifier, recipients, activity, collection_name, sync_collection = @federation.parse_fanout_delivery(payload)
        sender_key_pairs = @federation.parse_fanout_delivery_sender_key_pairs(payload)
        if sender_key_pairs.empty?
          enqueue_activity(sender_identifier, recipients, activity, EnqueueOptions.new, collection_name, sync_collection)
        else
          sender_actor = activity_actor_id(activity) || sender_key_pairs.first.owner
          enqueue_signed_activity_with_key_pairs(sender_identifier, sender_actor, sender_key_pairs, recipients, activity, EnqueueOptions.new, collection_name, sync_collection)
        end
        true
      else
        raise ArgumentError.new("unknown queued task type")
      end
    end

    def route_activity(
      recipient_identifier : String?,
      activity : JsonMap,
      options : RouteActivityOptions = RouteActivityOptions.new
    ) : Bool
      route_activity_result(recipient_identifier, activity, options).handled?
    end

    def route_activity_result(
      recipient_identifier : String?,
      activity : JsonMap,
      options : RouteActivityOptions = RouteActivityOptions.new
    ) : RouteActivityResult
      ctx = with_recipient(recipient_identifier)
      ctx = ctx.with_document_loader(options.document_loader || @federation.inbox_document_loader(ctx, recipient_identifier))
      ctx = ctx.with_context_loader(options.context_loader) if options.context_loader

      routed_activity = if options.trusted
                          activity
                        else
                          @federation.trusted_inbox_activity(ctx, activity)
                        end
      return RouteActivityResult::UnverifiedActivity unless routed_activity

      if @federation.inbox_queue && !options.immediate
        @federation.enqueue_inbox_activity(recipient_identifier, routed_activity, options.enqueue_options, trusted: true, context_data: @data)
        return RouteActivityResult::Enqueued
      end

      @federation.route_activity_result(ctx, routed_activity)
    end
  end
end
