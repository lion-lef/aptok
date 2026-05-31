require "./federation_types"

module Aptork
  def self.create_federation_builder : FederationBuilder
    FederationBuilder.new
  end

  def self.extract_inboxes(
    recipients : Array(Recipient),
    prefer_shared_inbox : Bool = false,
    exclude_base_uris : Array(String) = [] of String
  ) : Hash(String, ExtractedInbox)
    inboxes = Hash(String, ExtractedInbox).new

    recipients.each do |recipient|
      inbox = recipient.inbox
      shared = false
      if prefer_shared_inbox
        if shared_inbox = recipient.shared_inbox
          unless shared_inbox.empty?
            inbox = shared_inbox
            shared = true
          end
        end
      end

      next if recipient_excluded_from_inbox_extraction?(recipient, inbox, exclude_base_uris)

      actor_ids = recipient.synchronization_actor_ids
      if existing = inboxes[inbox]?
        inboxes[inbox] = ExtractedInbox.new((existing.actor_ids + actor_ids).uniq, existing.shared_inbox || shared)
      else
        inboxes[inbox] = ExtractedInbox.new(actor_ids.uniq, shared)
      end
    end

    inboxes
  end

  def self.recipient_from_actor(actor : Vocab::Actor, prefer_shared_inbox : Bool = false) : Recipient?
    recipient_from_actor(actor.to_json_ld, prefer_shared_inbox)
  end

  def self.recipient_from_actor(actor : JsonMap, prefer_shared_inbox : Bool = false) : Recipient?
    id = actor["id"]?.try(&.as_s?) || actor["@id"]?.try(&.as_s?)
    inbox = actor["inbox"]?.try(&.as_s?)
    return nil unless id && inbox && !id.empty? && !inbox.empty?

    shared_inbox = actor["endpoints"]?.try(&.as_h["sharedInbox"]?.try(&.as_s?))
    delivery_inbox = inbox
    if prefer_shared_inbox && shared_inbox && !shared_inbox.empty?
      delivery_inbox = shared_inbox
    end

    Recipient.new(id, delivery_inbox, [id], shared_inbox)
  end

  private def self.recipient_excluded_from_inbox_extraction?(recipient : Recipient, inbox : String, exclude_base_uris : Array(String)) : Bool
    exclude_base_uris.any? do |base|
      same_uri_origin_for_extraction?(recipient.id, base) || same_uri_origin_for_extraction?(inbox, base)
    end
  end

  private def self.same_uri_origin_for_extraction?(left : String, right : String) : Bool
    left_origin = uri_origin_for_extraction(left)
    right_origin = uri_origin_for_extraction(right)
    !!left_origin && left_origin == right_origin
  end

  private def self.uri_origin_for_extraction(value : String) : String?
    uri = URI.parse(value)
    return nil unless uri.scheme && uri.host
    host = uri.host.to_s
    host = "#{host}:#{uri.port}" if uri.port
    "#{uri.scheme}://#{host}"
  rescue
    nil
  end

  class FederationBuilder
    @steps = [] of FederationSetup

    def build(
      origin : String,
      transport : Transport = Transport.new(signature_enabled: false),
      kv : KvStore? = nil,
      outbox_queue : MessageQueue? = nil,
      outbox_queue_name : String = "outbox",
      outbox_retry_policy : RetryPolicy = RetryPolicy.new,
      inbox_queue : MessageQueue? = nil,
      inbox_queue_name : String = "inbox",
      inbox_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_queue : MessageQueue? = nil,
      fanout_queue_name : String = "fanout",
      fanout_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_threshold : Int32 = 50,
      document_loader : DocumentLoader = Remote.default_document_loader,
      context_loader : DocumentLoader? = nil,
      document_get_provider : DocumentGetProvider? = nil,
      canonical_origin : String? = nil,
      handle_host : String? = nil,
      allow_private_address : Bool = false,
      user_agent : String = Remote.default_user_agent,
      telemetry : Telemetry = NoopTelemetry.new,
      manually_start_queue : Bool = false,
      permanent_failure_status_codes : Enumerable(Int32) = Set{404, 410},
      trailing_slash_insensitive : Bool = false
    ) : Federation
      federation = Federation.create(
        origin,
        transport,
        kv,
        outbox_queue,
        outbox_queue_name,
        outbox_retry_policy,
        inbox_queue,
        inbox_queue_name,
        inbox_retry_policy,
        fanout_queue,
        fanout_queue_name,
        fanout_retry_policy,
        fanout_threshold,
        document_loader,
        context_loader,
        document_get_provider,
        canonical_origin,
        handle_host,
        allow_private_address,
        user_agent,
        telemetry,
        manually_start_queue,
        permanent_failure_status_codes,
        trailing_slash_insensitive
      )
      @steps.each { |step| step.call(federation) }
      federation
    end

    def build(
      origin : FederationOrigin,
      transport : Transport = Transport.new(signature_enabled: false),
      kv : KvStore? = nil,
      outbox_queue : MessageQueue? = nil,
      outbox_queue_name : String = "outbox",
      outbox_retry_policy : RetryPolicy = RetryPolicy.new,
      inbox_queue : MessageQueue? = nil,
      inbox_queue_name : String = "inbox",
      inbox_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_queue : MessageQueue? = nil,
      fanout_queue_name : String = "fanout",
      fanout_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_threshold : Int32 = 50,
      document_loader : DocumentLoader = Remote.default_document_loader,
      context_loader : DocumentLoader? = nil,
      document_get_provider : DocumentGetProvider? = nil,
      allow_private_address : Bool = false,
      user_agent : String = Remote.default_user_agent,
      telemetry : Telemetry = NoopTelemetry.new,
      manually_start_queue : Bool = false,
      permanent_failure_status_codes : Enumerable(Int32) = Set{404, 410},
      trailing_slash_insensitive : Bool = false
    ) : Federation
      build(
        origin.web_origin,
        transport,
        kv,
        outbox_queue,
        outbox_queue_name,
        outbox_retry_policy,
        inbox_queue,
        inbox_queue_name,
        inbox_retry_policy,
        fanout_queue,
        fanout_queue_name,
        fanout_retry_policy,
        fanout_threshold,
        document_loader,
        context_loader,
        document_get_provider,
        origin.web_origin,
        origin.handle_host,
        allow_private_address,
        user_agent,
        telemetry,
        manually_start_queue,
        permanent_failure_status_codes,
        trailing_slash_insensitive
      )
    end

    def add_step(step : FederationSetup) : Nil
      @steps << step
    end

    def set_actor_dispatcher(path : String, dispatcher : ActorDispatcher) : self
      add_step(->(federation : Federation) { federation.set_actor_dispatcher(path, dispatcher) })
      self
    end

    def set_object_dispatcher(type : String, path : String, dispatcher : ObjectDispatcher) : self
      add_step(->(federation : Federation) { federation.set_object_dispatcher(type, path, dispatcher) })
      self
    end

    def set_object_dispatcher(type : String, path : String, dispatcher : ParamObjectDispatcher) : self
      add_step(->(federation : Federation) { federation.set_object_dispatcher(type, path, dispatcher) })
      self
    end

    def configure_object(type : String) : BuilderObjectCallbacks
      BuilderObjectCallbacks.new(self, type)
    end

    def set_outbox_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_outbox_dispatcher(path, dispatcher) })
      self
    end

    def add_activity_transformer(transformer : ActivityTransformer) : self
      add_step(->(federation : Federation) { federation.add_activity_transformer(transformer) })
      self
    end

    def add_default_activity_transformers : self
      add_step(->(federation : Federation) { federation.add_default_activity_transformers })
      self
    end

    def configure_outbox_queue(queue : MessageQueue, queue_name : String = "outbox", retry_policy : RetryPolicy = RetryPolicy.new) : self
      add_step(->(federation : Federation) { federation.configure_outbox_queue(queue, queue_name, retry_policy) })
      self
    end

    def configure_inbox_queue(queue : MessageQueue, queue_name : String = "inbox", retry_policy : RetryPolicy = RetryPolicy.new) : self
      add_step(->(federation : Federation) { federation.configure_inbox_queue(queue, queue_name, retry_policy) })
      self
    end

    def configure_fanout_queue(queue : MessageQueue, queue_name : String = "fanout", retry_policy : RetryPolicy = RetryPolicy.new, threshold : Int32 = 50) : self
      add_step(->(federation : Federation) { federation.configure_fanout_queue(queue, queue_name, retry_policy, threshold) })
      self
    end

    def set_outbox_page_dispatcher(path : String, dispatcher : CursorCollectionDispatcher | NullableCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_outbox_page_dispatcher(path, dispatcher) })
      self
    end

    def set_inbox_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_inbox_dispatcher(path, dispatcher) })
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_followers_dispatcher(path, dispatcher) })
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_followers_dispatcher(path, dispatcher) })
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_followers_dispatcher(path, dispatcher) })
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : FilteredCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_followers_dispatcher(path, dispatcher) })
      self
    end

    def set_following_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_following_dispatcher(path, dispatcher) })
      self
    end

    def set_following_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_following_dispatcher(path, dispatcher) })
      self
    end
  end
end
