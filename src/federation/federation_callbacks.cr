module Aptork
  class InboxListeners
    def initialize(@federation : Federation)
    end

    def on(type : String, listener : InboxListener) : self
      @federation.add_inbox_listener(type, listener)
      self
    end

    def on(type : T.class, listener : InboxListener) : self forall T
      on(T.type_name, listener)
    end

    def on(type : T.class, listener : Proc(Context, T, Nil)) : self forall T
      @federation.add_inbox_listener(T.type_name, ->(ctx : Context, activity : JsonMap) do
        listener.call(ctx, Vocab::Object.from_json_ld(activity).as(T))
        nil
      end)
      self
    end

    def on_any(listener : InboxListener) : self
      on("*", listener)
    end

    def with_idempotency(ttl : Time::Span = Time::Span.new(hours: 24), strategy : String = "per-inbox") : self
      @federation.enable_idempotency(ttl, strategy)
      self
    end

    def with_idempotency(strategy : String, ttl : Time::Span = Time::Span.new(hours: 24)) : self
      @federation.enable_idempotency(ttl, strategy)
      self
    end

    def with_idempotency(ttl : Time::Span, strategy : InboxIdempotencyStrategy) : self
      @federation.enable_idempotency(ttl, strategy)
      self
    end

    def on_unverified_activity(listener : UnverifiedActivityListener) : self
      @federation.on_unverified_activity(listener)
      self
    end

    def on_error(handler : InboxErrorHandler) : self
      @federation.set_inbox_error_handler(handler)
      self
    end

    def set_shared_key_dispatcher(dispatcher : SharedInboxKeyDispatcher) : self
      @federation.set_shared_key_dispatcher(dispatcher)
      self
    end
  end

  class BuilderInboxListeners
    def initialize(@builder : FederationBuilder)
    end

    def on(type : String, listener : InboxListener) : self
      @builder.add_step(->(federation : Federation) { federation.add_inbox_listener(type, listener) })
      self
    end

    def on(type : T.class, listener : InboxListener) : self forall T
      on(T.type_name, listener)
    end

    def on(type : T.class, listener : Proc(Context, T, Nil)) : self forall T
      @builder.add_step(->(federation : Federation) do
        federation.add_inbox_listener(T.type_name, ->(ctx : Context, activity : JsonMap) do
          listener.call(ctx, Vocab::Object.from_json_ld(activity).as(T))
          nil
        end)
      end)
      self
    end

    def on_any(listener : InboxListener) : self
      on("*", listener)
    end

    def with_idempotency(ttl : Time::Span = Time::Span.new(hours: 24), strategy : String = "per-inbox") : self
      @builder.add_step(->(federation : Federation) { federation.enable_idempotency(ttl, strategy) })
      self
    end

    def with_idempotency(strategy : String, ttl : Time::Span = Time::Span.new(hours: 24)) : self
      @builder.add_step(->(federation : Federation) { federation.enable_idempotency(strategy, ttl) })
      self
    end

    def with_idempotency(ttl : Time::Span, strategy : InboxIdempotencyStrategy) : self
      @builder.add_step(->(federation : Federation) { federation.enable_idempotency(ttl, strategy) })
      self
    end

    def on_unverified_activity(listener : UnverifiedActivityListener) : self
      @builder.add_step(->(federation : Federation) { federation.on_unverified_activity(listener) })
      self
    end

    def on_error(handler : InboxErrorHandler) : self
      @builder.add_step(->(federation : Federation) { federation.set_inbox_error_handler(handler) })
      self
    end

    def set_shared_key_dispatcher(dispatcher : SharedInboxKeyDispatcher) : self
      @builder.add_step(->(federation : Federation) { federation.set_shared_key_dispatcher(dispatcher) })
      self
    end
  end

  class OutboxListeners
    def initialize(@federation : Federation)
    end

    def on(type : String, listener : OutboxListener) : self
      @federation.add_outbox_listener(type, listener)
      self
    end

    def on(type : T.class, listener : OutboxListener) : self forall T
      on(T.type_name, listener)
    end

    def on(type : T.class, listener : Proc(Context, T, Nil)) : self forall T
      @federation.add_outbox_listener(T.type_name, ->(ctx : Context, activity : JsonMap) do
        listener.call(ctx, Vocab::Object.from_json_ld(activity).as(T))
        nil
      end)
      self
    end

    def on_any(listener : OutboxListener) : self
      on("*", listener)
    end

    def authorize(authorizer : OutboxAuthorizePredicate) : self
      @federation.set_outbox_authorizer(authorizer)
      self
    end

    def on_error(handler : OutboxListenerErrorHandler) : self
      @federation.set_outbox_listener_error_handler(handler)
      self
    end
  end

  class BuilderOutboxListeners
    def initialize(@builder : FederationBuilder)
    end

    def on(type : String, listener : OutboxListener) : self
      @builder.add_step(->(federation : Federation) { federation.add_outbox_listener(type, listener) })
      self
    end

    def on(type : T.class, listener : OutboxListener) : self forall T
      on(T.type_name, listener)
    end

    def on(type : T.class, listener : Proc(Context, T, Nil)) : self forall T
      @builder.add_step(->(federation : Federation) do
        federation.add_outbox_listener(T.type_name, ->(ctx : Context, activity : JsonMap) do
          listener.call(ctx, Vocab::Object.from_json_ld(activity).as(T))
          nil
        end)
      end)
      self
    end

    def on_any(listener : OutboxListener) : self
      on("*", listener)
    end

    def authorize(authorizer : OutboxAuthorizePredicate) : self
      @builder.add_step(->(federation : Federation) { federation.set_outbox_authorizer(authorizer) })
      self
    end

    def on_error(handler : OutboxListenerErrorHandler) : self
      @builder.add_step(->(federation : Federation) { federation.set_outbox_listener_error_handler(handler) })
      self
    end
  end

  class BuilderCollectionCallbacks
    def initialize(@builder : FederationBuilder, @name : String)
    end

    def item_type(item_type : String) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_item_type(@name, item_type) })
      self
    end

    def set_first_cursor(callback : CollectionCursorCallback) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_first_cursor(@name, callback) })
      self
    end

    def set_last_cursor(callback : CollectionCursorCallback) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_last_cursor(@name, callback) })
      self
    end

    def set_counter(callback : CollectionCounterCallback) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_counter(@name, callback) })
      self
    end

    def filter(predicate : CollectionFilterPredicate) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_filter(@name, predicate) })
      self
    end

    def authorize(authorizer : AuthorizePredicate) : self
      @builder.add_step(->(federation : Federation) { federation.set_collection_authorizer(@name, authorizer) })
      self
    end
  end

  class BuilderObjectCallbacks
    def initialize(@builder : FederationBuilder, @type : String)
    end

    def authorize(authorizer : AuthorizePredicate) : self
      @builder.add_step(->(federation : Federation) { federation.set_object_authorizer(@type, authorizer) })
      self
    end
  end

  class CollectionCallbacks
    def initialize(@federation : Federation, @name : String)
    end

    def item_type(item_type : String) : self
      @federation.set_collection_item_type(@name, item_type)
      self
    end

    def set_first_cursor(callback : CollectionCursorCallback) : self
      @federation.set_collection_first_cursor(@name, callback)
      self
    end

    def set_last_cursor(callback : CollectionCursorCallback) : self
      @federation.set_collection_last_cursor(@name, callback)
      self
    end

    def set_counter(callback : CollectionCounterCallback) : self
      @federation.set_collection_counter(@name, callback)
      self
    end

    def filter(predicate : CollectionFilterPredicate) : self
      @federation.set_collection_filter(@name, predicate)
      self
    end

    def authorize(authorizer : AuthorizePredicate) : self
      @federation.set_collection_authorizer(@name, authorizer)
      self
    end
  end

  class ObjectCallbacks
    def initialize(@federation : Federation, @type : String)
    end

    def authorize(authorizer : AuthorizePredicate) : self
      @federation.set_object_authorizer(@type, authorizer)
      self
    end
  end
end
