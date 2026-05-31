module Aptok
  class Federation
    def set_outbox_listener_error_handler(handler : OutboxListenerErrorHandler) : self
      @outbox_listener_error_handler = handler
      self
    end

    def notify_outbox_listener_error(ctx : Context, error : Exception) : Nil
      notify_error_handler("outbox", @outbox_listener_error_handler, ctx, error)
    end

    def on_undelivered_outbox_activity(listener : UndeliveredOutboxActivityListener) : self
      @undelivered_outbox_activity_listener = listener
      self
    end

    def set_outbox_permanent_failure_handler(handler : OutboxPermanentFailureHandler) : self
      @outbox_permanent_failure_handler = handler
      self
    end

    def set_permanent_failure_status_codes(codes : Enumerable(Int32)) : self
      @permanent_failure_status_codes = codes.to_set
      self
    end

    def permanent_failure_status_codes : Set(Int32)
      @permanent_failure_status_codes
    end

    def set_outbox_error_handler(handler : OutboxErrorHandler) : self
      @outbox_error_handler = handler
      self
    end

    def permanent_delivery_failure?(error : DeliveryError) : Bool
      status_code = error.status_code
      !!status_code && @permanent_failure_status_codes.includes?(status_code)
    end

    def handle_outbox_permanent_failure(ctx : Context, delivery : DeliveryConfig, activity : JsonMap, error : DeliveryError) : Nil
      status_code = error.status_code
      return unless status_code

      failure = OutboxPermanentFailure.new(
        inbox: delivery.inbox,
        activity: activity,
        error: error,
        status_code: status_code,
        actor_ids: delivery.actor_ids
      )
      if handler = @outbox_permanent_failure_handler
        handler.call(ctx, failure)
      else
        Log.for("aptok.federation.outbox").warn do
          "permanent delivery failure for #{delivery.inbox} (#{status_code}); skipping retry"
        end
      end
    end

    def handle_outbox_error(ctx : Context, delivery : DeliveryConfig, activity : JsonMap, error : DeliveryError, attempts : Int32) : Nil
      failure = OutboxDeliveryFailure.new(
        inbox: delivery.inbox,
        activity: activity,
        error: error,
        status_code: error.status_code,
        actor_ids: delivery.actor_ids,
        attempts: attempts
      )
      if handler = @outbox_error_handler
        handler.call(ctx, failure)
      else
        Log.for("aptok.federation.outbox").error do
          "queued delivery failure for #{delivery.inbox} on attempt #{attempts}: #{error.message}"
        end
      end
    end

    def set_outbox_authorizer(authorizer : OutboxAuthorizePredicate) : Nil
      @outbox_authorizer = authorizer
    end

    def actor_path : String
      @actor_path
    end

    def actor_alias_identifier(path : String) : String?
      @actor_alias_paths[path]?
    end

    def actor_alias_path(identifier : String) : String?
      @actor_alias_identifiers[identifier]?
    end

    def inbox_path : String
      @inbox_path
    end

    def shared_inbox_path : String?
      @shared_inbox_path
    end

    def outbox_path : String
      @outbox_path
    end

    def followers_path : String
      @followers_path
    end

    def following_path : String
      @following_path
    end

    def liked_path : String
      @liked_path
    end

    def featured_path : String
      @featured_path
    end

    def featured_tags_path : String
      @featured_tags_path
    end

    def nodeinfo_path : String
      @nodeinfo_path
    end

    def object_routes : Array(ObjectRoute)
      @object_routes
    end

    def collection_routes : Array(CollectionRoute)
      @collection_routes
    end

    def outbox_queue : MessageQueue?
      @outbox_queue
    end

    def outbox_queue_name : String
      @outbox_queue_name
    end

    def outbox_retry_policy : RetryPolicy
      @outbox_retry_policy
    end

    def inbox_queue : MessageQueue?
      @inbox_queue
    end

    def inbox_queue_name : String
      @inbox_queue_name
    end

    def inbox_retry_policy : RetryPolicy
      @inbox_retry_policy
    end

    def fanout_queue : MessageQueue?
      @fanout_queue
    end

    def fanout_queue_name : String
      @fanout_queue_name
    end

    def fanout_retry_policy : RetryPolicy
      @fanout_retry_policy
    end

    def fanout_threshold : Int32
      @fanout_threshold
    end

    def document_loader : DocumentLoader
      @document_loader
    end

    def context_loader : DocumentLoader
      @context_loader
    end

    def document_get_provider : DocumentGetProvider?
      @document_get_provider
    end

    def inbox_document_loader(ctx : Context, recipient_identifier : String?) : DocumentLoader
      if recipient_identifier
        return ctx.get_document_loader(recipient_identifier)
      end

      key = @shared_inbox_key_dispatcher.try(&.call(ctx))
      return @document_loader unless key

      ctx.get_document_loader(key)
    end

    def handle(request : Request) : Response
      handle(request, FetchOptions.new)
    end

    def handle(
      request : Request,
      *,
      on_not_found : RequestHandler? = nil,
      on_not_acceptable : RequestHandler? = nil,
      on_unauthorized : RequestHandler? = nil,
      context_data : JSON::Any? = nil
    ) : Response
      handle(request, FetchOptions.new(on_not_found, on_not_acceptable, on_unauthorized, context_data))
    end

    def handle(request : Request, options : FetchOptions) : Response
      started = Time.monotonic
      attributes = telemetry_attributes({"http.method" => request.method.upcase, "http.route" => request.path})
      @telemetry.span("aptok.http.request", attributes) do
        response = Router.new(self, options).handle(request)
        duration_ms = (Time.monotonic - started).total_milliseconds
        response_attributes = attributes.dup
        response_attributes["http.status_code"] = response.status.to_s
        @telemetry.counter("aptok.http.requests", attributes: response_attributes)
        @telemetry.histogram("aptok.http.request.duration_ms", duration_ms, response_attributes)
        response
      end
    end

    def fetch(request : Request, options : FetchOptions = FetchOptions.new) : Response
      handle(request, options)
    end

    def fetch(
      request : Request,
      *,
      on_not_found : RequestHandler? = nil,
      on_not_acceptable : RequestHandler? = nil,
      on_unauthorized : RequestHandler? = nil,
      context_data : JSON::Any? = nil
    ) : Response
      handle(request, on_not_found: on_not_found, on_not_acceptable: on_not_acceptable, on_unauthorized: on_unauthorized, context_data: context_data)
    end

    def record_sent(activity : SentActivity) : SentActivity
      @sent_counter += 1
      recorded = SentActivity.new(
        activity.sender_identifier,
        activity.recipient,
        activity.activity_id,
        activity.activity,
        activity.queued,
        activity.queue,
        activity.sent_order > 0 ? activity.sent_order : @sent_counter,
        activity.raw_activity
      )
      @sent_activities << recorded
      recorded
    end

    def reset_sent_activities : Nil
      @sent_activities.clear
    end

    def reset : Nil
      reset_sent_activities
    end

    def self.collection_digest(actor_ids : Iterable(String)) : Bytes
      processed = Set(String).new
      result = Bytes.new(32, 0_u8)
      actor_ids.each do |actor_id|
        next if processed.includes?(actor_id)

        processed << actor_id
        Digest::SHA256.digest(actor_id).each_with_index do |byte, index|
          result[index] = result[index] ^ byte
        end
      end
      result
    end
  end
end
