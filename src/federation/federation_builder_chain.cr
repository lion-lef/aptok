module Aptork

  class FederationBuilder
    def set_following_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_following_dispatcher(path, dispatcher) })
      self
    end

    def set_liked_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_liked_dispatcher(path, dispatcher) })
      self
    end

    def set_liked_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_liked_dispatcher(path, dispatcher) })
      self
    end

    def set_liked_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_liked_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_tags_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_tags_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_tags_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_tags_dispatcher(path, dispatcher) })
      self
    end

    def set_featured_tags_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_featured_tags_dispatcher(path, dispatcher) })
      self
    end

    def set_collection_dispatcher(name : String, path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_collection_dispatcher(name, path, dispatcher) })
      self
    end

    def set_collection_dispatcher(name : String, path : String, dispatcher : ParamCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_collection_dispatcher(name, path, dispatcher) })
      self
    end

    def set_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_collection_page_dispatcher(name, path, dispatcher) })
      self
    end

    def set_collection_page_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_collection_page_dispatcher(name, path, dispatcher) })
      self
    end

    def set_collection_item_type(name : String, item_type : String) : self
      add_step(->(federation : Federation) { federation.set_collection_item_type(name, item_type) })
      self
    end

    def set_collection_first_cursor(name : String, callback : CollectionCursorCallback) : self
      add_step(->(federation : Federation) { federation.set_collection_first_cursor(name, callback) })
      self
    end

    def set_collection_last_cursor(name : String, callback : CollectionCursorCallback) : self
      add_step(->(federation : Federation) { federation.set_collection_last_cursor(name, callback) })
      self
    end

    def set_collection_counter(name : String, callback : CollectionCounterCallback) : self
      add_step(->(federation : Federation) { federation.set_collection_counter(name, callback) })
      self
    end

    def set_collection_filter(name : String, predicate : CollectionFilterPredicate) : self
      add_step(->(federation : Federation) { federation.set_collection_filter(name, predicate) })
      self
    end

    def configure_collection(name : String) : BuilderCollectionCallbacks
      BuilderCollectionCallbacks.new(self, name)
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : CollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_ordered_collection_dispatcher(name, path, dispatcher) })
      self
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : ParamCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_ordered_collection_dispatcher(name, path, dispatcher) })
      self
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_ordered_collection_page_dispatcher(name, path, dispatcher) })
      self
    end

    def set_ordered_collection_page_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      add_step(->(federation : Federation) { federation.set_ordered_collection_page_dispatcher(name, path, dispatcher) })
      self
    end

    def set_inbox_listeners(inbox_path : String, shared_inbox_path : String? = nil) : BuilderInboxListeners
      add_step(->(federation : Federation) { federation.set_inbox_listeners(inbox_path, shared_inbox_path) })
      BuilderInboxListeners.new(self)
    end

    def set_outbox_listeners(outbox_path : String) : BuilderOutboxListeners
      add_step(->(federation : Federation) { federation.set_outbox_listeners(outbox_path) })
      BuilderOutboxListeners.new(self)
    end

    def set_inbox_error_handler(handler : InboxErrorHandler) : self
      add_step(->(federation : Federation) { federation.set_inbox_error_handler(handler) })
      self
    end

    def set_outbox_listener_error_handler(handler : OutboxListenerErrorHandler) : self
      add_step(->(federation : Federation) { federation.set_outbox_listener_error_handler(handler) })
      self
    end

    def on_undelivered_outbox_activity(listener : UndeliveredOutboxActivityListener) : self
      add_step(->(federation : Federation) { federation.on_undelivered_outbox_activity(listener) })
      self
    end

    def set_outbox_permanent_failure_handler(handler : OutboxPermanentFailureHandler) : self
      add_step(->(federation : Federation) { federation.set_outbox_permanent_failure_handler(handler) })
      self
    end

    def set_permanent_failure_status_codes(codes : Enumerable(Int32)) : self
      add_step(->(federation : Federation) { federation.set_permanent_failure_status_codes(codes) })
      self
    end

    def set_outbox_error_handler(handler : OutboxErrorHandler) : self
      add_step(->(federation : Federation) { federation.set_outbox_error_handler(handler) })
      self
    end

    def on_error(handler : Proc(Context, Exception, Nil)) : self
      add_step(->(federation : Federation) { federation.on_error(handler) })
      self
    end

    def on_unverified_activity(listener : UnverifiedActivityListener) : self
      add_step(->(federation : Federation) { federation.on_unverified_activity(listener) })
      self
    end

    def set_inbox_verifier(verifier : InboxVerifier) : self
      add_step(->(federation : Federation) { federation.set_inbox_verifier(verifier) })
      self
    end

    def set_shared_key_dispatcher(dispatcher : SharedInboxKeyDispatcher) : self
      add_step(->(federation : Federation) { federation.set_shared_key_dispatcher(dispatcher) })
      self
    end

    def set_webfinger_dispatcher(dispatcher : WebFingerDispatcher) : self
      add_step(->(federation : Federation) { federation.set_webfinger_dispatcher(dispatcher) })
      self
    end

    def set_webfinger_links_dispatcher(dispatcher : WebFingerLinksDispatcher) : self
      add_step(->(federation : Federation) { federation.set_webfinger_links_dispatcher(dispatcher) })
      self
    end

    def map_handle(mapper : HandleMapper) : self
      add_step(->(federation : Federation) { federation.map_handle(mapper) })
      self
    end

    def map_alias(mapper : Proc(Context, String, T)) : self forall T
      add_step(->(federation : Federation) { federation.map_alias(mapper) })
      self
    end

    def map_actor_alias(path : String, identifier : String) : self
      add_step(->(federation : Federation) { federation.map_actor_alias(path, identifier) })
      self
    end

    def set_nodeinfo_dispatcher(dispatcher : NodeInfoDispatcher) : self
      add_step(->(federation : Federation) { federation.set_nodeinfo_dispatcher(dispatcher) })
      self
    end

    def set_nodeinfo_dispatcher(path : String, dispatcher : NodeInfoDispatcher) : self
      add_step(->(federation : Federation) { federation.set_nodeinfo_dispatcher(path, dispatcher) })
      self
    end

    def set_key_pairs_dispatcher(dispatcher : KeyPairsDispatcher) : self
      add_step(->(federation : Federation) { federation.set_key_pairs_dispatcher(dispatcher) })
      self
    end

    def set_signature_key_resolver(resolver : SignatureKeyResolver) : self
      add_step(->(federation : Federation) { federation.set_signature_key_resolver(resolver) })
      self
    end

    def enable_inbox_signature_verification(options : InboxSignatureOptions = InboxSignatureOptions.new) : self
      add_step(->(federation : Federation) { federation.enable_inbox_signature_verification(options) })
      self
    end

    def set_actor_authorizer(authorizer : AuthorizePredicate) : self
      add_step(->(federation : Federation) { federation.set_actor_authorizer(authorizer) })
      self
    end

    def set_object_authorizer(type : String, authorizer : AuthorizePredicate) : self
      add_step(->(federation : Federation) { federation.set_object_authorizer(type, authorizer) })
      self
    end

    def set_collection_authorizer(name : String, authorizer : AuthorizePredicate) : self
      add_step(->(federation : Federation) { federation.set_collection_authorizer(name, authorizer) })
      self
    end

    def set_document_loader(loader : DocumentLoader) : self
      add_step(->(federation : Federation) { federation.set_document_loader(loader) })
      self
    end

    def set_context_loader(loader : DocumentLoader) : self
      add_step(->(federation : Federation) { federation.set_context_loader(loader) })
      self
    end

    def set_telemetry(telemetry : Telemetry) : self
      add_step(->(federation : Federation) { federation.set_telemetry(telemetry) })
      self
    end

    def enable_document_cache(ttl : Time::Span? = Time::Span.new(hours: 1), prefix : String = "aptork:remote-document") : self
      add_step(->(federation : Federation) { federation.enable_document_cache(ttl, prefix) })
      self
    end
  end

end
