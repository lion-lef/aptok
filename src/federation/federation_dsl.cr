module Aptok
  class Federation
    private alias DslObjectDispatcher = ObjectDispatcher | ParamObjectDispatcher
    private alias DslCollectionDispatcher = CollectionDispatcher | ParamCollectionDispatcher | ParamCursorCollectionDispatcher
    private alias DslBuiltinCollectionDispatcher = CollectionDispatcher | CursorCollectionDispatcher | ParamCursorCollectionDispatcher
    private alias DslFollowersDispatcher = DslBuiltinCollectionDispatcher | FilteredCursorCollectionDispatcher

    private macro forward_block(method_name, block_type)
      def {{method_name.id}}(&block : {{block_type.id}}) : self
        {{method_name.id}}(block)
      end
    end

    private macro forward_path_block(method_name, block_type)
      def {{method_name.id}}(path : String, &block : {{block_type.id}}) : self
        {{method_name.id}}(path, block)
      end
    end

    private macro forward_type_path_block(method_name, block_type)
      def {{method_name.id}}(type : String, path : String, &block : {{block_type.id}}) : self
        {{method_name.id}}(type, path, block)
      end
    end

    private macro forward_named_path_block(method_name, block_type)
      def {{method_name.id}}(name : String, path : String, &block : {{block_type.id}}) : self
        {{method_name.id}}(name, path, block)
      end
    end

    def document_loader(loader : DocumentLoader) : self
      set_document_loader(loader)
    end

    forward_block document_loader, DocumentLoader

    def context_loader(loader : DocumentLoader) : self
      set_context_loader(loader)
    end

    forward_block context_loader, DocumentLoader

    def document_get_provider(provider : DocumentGetProvider) : self
      set_document_get_provider(provider)
    end

    forward_block document_get_provider, DocumentGetProvider

    def telemetry(metrics : Telemetry) : self
      set_telemetry(metrics)
    end

    def document_cache(ttl : Time::Span? = Time::Span.new(hours: 1), prefix : String = "aptok:remote-document") : self
      enable_document_cache(ttl, prefix)
    end

    def outbox_queue(
      queue : MessageQueue,
      queue_name : String = "outbox",
      retry_policy : RetryPolicy = RetryPolicy.new
    ) : self
      configure_outbox_queue(queue, queue_name, retry_policy)
    end

    def inbox_queue(
      queue : MessageQueue,
      queue_name : String = "inbox",
      retry_policy : RetryPolicy = RetryPolicy.new
    ) : self
      configure_inbox_queue(queue, queue_name, retry_policy)
    end

    def fanout_queue(
      queue : MessageQueue,
      queue_name : String = "fanout",
      retry_policy : RetryPolicy = RetryPolicy.new,
      threshold : Int32 = 50
    ) : self
      configure_fanout_queue(queue, queue_name, retry_policy, threshold)
    end

    def actor(path : String, dispatcher : ActorDispatcher) : self
      set_actor_dispatcher(path, dispatcher)
    end

    forward_path_block actor, ActorDispatcher

    def actor_alias(path : String, identifier : String) : self
      map_actor_alias(path, identifier)
    end

    def object(type : String, path : String, dispatcher : DslObjectDispatcher) : self
      set_object_dispatcher(type, path, dispatcher)
    end

    forward_type_path_block object, ParamObjectDispatcher

    def object(type : String) : ObjectCallbacks
      configure_object(type)
    end

    def object(type : String, &block : ObjectCallbacks -> Nil) : self
      callbacks = configure_object(type)
      block.call(callbacks)
      self
    end

    def outbox(path : String, dispatcher : CollectionDispatcher) : self
      set_outbox_dispatcher(path, dispatcher)
    end

    def outbox_page(path : String, dispatcher : CursorCollectionDispatcher | NullableCursorCollectionDispatcher) : self
      set_outbox_page_dispatcher(path, dispatcher)
    end

    forward_path_block outbox_page, NullableCursorCollectionDispatcher

    def outbox(path : String) : OutboxListeners
      set_outbox_listeners(path)
    end

    def outbox(path : String, &block : OutboxListeners -> Nil) : self
      listeners = set_outbox_listeners(path)
      block.call(listeners)
      self
    end

    def inbox(path : String, dispatcher : CollectionDispatcher) : self
      set_inbox_dispatcher(path, dispatcher)
    end

    def inbox(path : String, shared_inbox_path : String? = nil) : InboxListeners
      set_inbox_listeners(path, shared_inbox_path)
    end

    def inbox(path : String, shared_inbox_path : String? = nil, &block : InboxListeners -> Nil) : self
      listeners = set_inbox_listeners(path, shared_inbox_path)
      block.call(listeners)
      self
    end

    def followers(path : String, dispatcher : DslFollowersDispatcher) : self
      set_followers_dispatcher(path, dispatcher)
    end

    forward_path_block followers, CollectionDispatcher

    def following(path : String, dispatcher : DslBuiltinCollectionDispatcher) : self
      set_following_dispatcher(path, dispatcher)
    end

    def liked(path : String, dispatcher : DslBuiltinCollectionDispatcher) : self
      set_liked_dispatcher(path, dispatcher)
    end

    def featured(path : String, dispatcher : DslBuiltinCollectionDispatcher) : self
      set_featured_dispatcher(path, dispatcher)
    end

    def featured_tags(path : String, dispatcher : DslBuiltinCollectionDispatcher) : self
      set_featured_tags_dispatcher(path, dispatcher)
    end

    {% for method_name in %w(following liked featured featured_tags) %}
      forward_path_block {{method_name.id}}, CollectionDispatcher
    {% end %}

    def collection(name : String, path : String, dispatcher : DslCollectionDispatcher) : self
      set_collection_dispatcher(name, path, dispatcher)
    end

    forward_named_path_block collection, ParamCollectionDispatcher

    def collection_page(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_collection_page_dispatcher(name, path, dispatcher)
    end

    forward_named_path_block collection_page, ParamCursorCollectionDispatcher

    def ordered_collection(name : String, path : String, dispatcher : DslCollectionDispatcher) : self
      set_ordered_collection_dispatcher(name, path, dispatcher)
    end

    forward_named_path_block ordered_collection, ParamCollectionDispatcher

    def ordered_collection_page(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_ordered_collection_page_dispatcher(name, path, dispatcher)
    end

    forward_named_path_block ordered_collection_page, ParamCursorCollectionDispatcher

    def collection(name : String) : CollectionCallbacks
      configure_collection(name)
    end

    def collection(name : String, &block : CollectionCallbacks -> Nil) : self
      callbacks = configure_collection(name)
      block.call(callbacks)
      self
    end

    def webfinger(dispatcher : WebFingerDispatcher) : self
      set_webfinger_dispatcher(dispatcher)
    end

    forward_block webfinger, WebFingerDispatcher

    def webfinger_links(dispatcher : WebFingerLinksDispatcher) : self
      set_webfinger_links_dispatcher(dispatcher)
    end

    forward_block webfinger_links, WebFingerLinksDispatcher

    def handles(mapper : HandleMapper) : self
      map_handle(mapper)
    end

    forward_block handles, HandleMapper

    def aliases(mapper : Proc(Context, String, T)) : self forall T
      map_alias(mapper)
    end

    def aliases(&block : Proc(Context, String, T)) : self forall T
      aliases(block)
    end

    def nodeinfo(dispatcher : NodeInfoDispatcher) : self
      set_nodeinfo_dispatcher(dispatcher)
    end

    forward_block nodeinfo, NodeInfoDispatcher

    def nodeinfo(path : String, dispatcher : NodeInfoDispatcher) : self
      set_nodeinfo_dispatcher(path, dispatcher)
    end

    forward_path_block nodeinfo, NodeInfoDispatcher

    def key_pairs(dispatcher : KeyPairsDispatcher) : self
      set_key_pairs_dispatcher(dispatcher)
    end

    forward_block key_pairs, KeyPairsDispatcher

    def signature_keys(resolver : SignatureKeyResolver) : self
      set_signature_key_resolver(resolver)
    end

    forward_block signature_keys, SignatureKeyResolver

    def inbox_verifier(verifier : InboxVerifier) : self
      set_inbox_verifier(verifier)
    end

    forward_block inbox_verifier, InboxVerifier

    def inbox_verifier(verifier : Proc(Request, JsonMap, Bool)) : self
      set_inbox_verifier(verifier)
    end

    def inbox_signature_verification(options : InboxSignatureOptions = InboxSignatureOptions.new) : self
      enable_inbox_signature_verification(options)
    end

    def authorize_actor(authorizer : AuthorizePredicate) : self
      set_actor_authorizer(authorizer)
    end

    forward_block authorize_actor, AuthorizePredicate

    forward_block on_unverified_activity, UnverifiedActivityListener

    def permanent_failure_status_codes(codes : Enumerable(Int32)) : self
      set_permanent_failure_status_codes(codes)
    end

    def outbox_permanent_failures(handler : OutboxPermanentFailureHandler) : self
      set_outbox_permanent_failure_handler(handler)
    end

    forward_block outbox_permanent_failures, OutboxPermanentFailureHandler

    def outbox_errors(handler : OutboxErrorHandler) : self
      set_outbox_error_handler(handler)
    end

    forward_block outbox_errors, OutboxErrorHandler

    def activity_transformer(transformer : ActivityTransformer) : self
      add_activity_transformer(transformer)
    end

    forward_block activity_transformer, ActivityTransformer

    def default_activity_transformers : self
      add_default_activity_transformers
    end

    def undelivered_outbox_activity(listener : UndeliveredOutboxActivityListener) : self
      on_undelivered_outbox_activity(listener)
    end

    forward_block undelivered_outbox_activity, UndeliveredOutboxActivityListener
  end

  def self.federation(origin : String, **options, &block) : Federation
    federation = Federation.create(origin, **options)
    with federation yield federation
    federation
  end

  def self.federation(origin : FederationOrigin, **options, &block) : Federation
    federation = Federation.create(origin, **options)
    with federation yield federation
    federation
  end
end
