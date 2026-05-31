module Aptok
  class InboxListeners
    def initialize(@federation : Federation)
    end

    private macro forward_block(method_name, block_type)
      def {{method_name.id}}(&block : {{block_type.id}}) : self
        {{method_name.id}}(block)
      end
    end

    private macro forward_activity_block(method_name, block_type)
      def {{method_name.id}}(type : String, &block : {{block_type.id}}) : self
        {{method_name.id}}(type, block)
      end
    end

    private macro forward_typed_activity_block(method_name)
      def {{method_name.id}}(type : T.class, &block : Proc(Context, T, Nil)) : self forall T
        {{method_name.id}}(type, block)
      end
    end

    def on(type : String, listener : InboxListener) : self
      @federation.add_inbox_listener(type, listener)
      self
    end

    forward_activity_block on, InboxListener

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

    forward_typed_activity_block on

    def on_any(listener : InboxListener) : self
      on("*", listener)
    end

    forward_block on_any, InboxListener

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

    def with_idempotency(ttl : Time::Span, &block : InboxIdempotencyStrategy) : self
      with_idempotency(ttl, block)
    end

    def on_unverified_activity(listener : UnverifiedActivityListener) : self
      @federation.on_unverified_activity(listener)
      self
    end

    forward_block on_unverified_activity, UnverifiedActivityListener

    def on_error(handler : InboxErrorHandler) : self
      @federation.set_inbox_error_handler(handler)
      self
    end

    forward_block on_error, InboxErrorHandler

    def shared_key(dispatcher : SharedInboxKeyDispatcher) : self
      @federation.set_shared_key_dispatcher(dispatcher)
      self
    end

    forward_block shared_key, SharedInboxKeyDispatcher

    def set_shared_key_dispatcher(dispatcher : SharedInboxKeyDispatcher) : self
      shared_key(dispatcher)
    end

    forward_block set_shared_key_dispatcher, SharedInboxKeyDispatcher
  end

  class OutboxListeners
    def initialize(@federation : Federation)
    end

    private macro forward_block(method_name, block_type)
      def {{method_name.id}}(&block : {{block_type.id}}) : self
        {{method_name.id}}(block)
      end
    end

    private macro forward_activity_block(method_name, block_type)
      def {{method_name.id}}(type : String, &block : {{block_type.id}}) : self
        {{method_name.id}}(type, block)
      end
    end

    private macro forward_typed_activity_block(method_name)
      def {{method_name.id}}(type : T.class, &block : Proc(Context, T, Nil)) : self forall T
        {{method_name.id}}(type, block)
      end
    end

    def on(type : String, listener : OutboxListener) : self
      @federation.add_outbox_listener(type, listener)
      self
    end

    forward_activity_block on, OutboxListener

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

    forward_typed_activity_block on

    def on_any(listener : OutboxListener) : self
      on("*", listener)
    end

    forward_block on_any, OutboxListener

    def authorize(authorizer : OutboxAuthorizePredicate) : self
      @federation.set_outbox_authorizer(authorizer)
      self
    end

    forward_block authorize, OutboxAuthorizePredicate

    def on_error(handler : OutboxListenerErrorHandler) : self
      @federation.set_outbox_listener_error_handler(handler)
      self
    end

    forward_block on_error, OutboxListenerErrorHandler
  end

  class CollectionCallbacks
    def initialize(@federation : Federation, @name : String)
    end

    private macro forward_block(method_name, block_type)
      def {{method_name.id}}(&block : {{block_type.id}}) : self
        {{method_name.id}}(block)
      end
    end

    def item_type(item_type : String) : self
      @federation.set_collection_item_type(@name, item_type)
      self
    end

    def first_cursor(callback : CollectionCursorCallback) : self
      @federation.set_collection_first_cursor(@name, callback)
      self
    end

    forward_block first_cursor, CollectionCursorCallback

    def last_cursor(callback : CollectionCursorCallback) : self
      @federation.set_collection_last_cursor(@name, callback)
      self
    end

    forward_block last_cursor, CollectionCursorCallback

    def counter(callback : CollectionCounterCallback) : self
      @federation.set_collection_counter(@name, callback)
      self
    end

    forward_block counter, CollectionCounterCallback

    def set_first_cursor(callback : CollectionCursorCallback) : self
      first_cursor(callback)
    end

    forward_block set_first_cursor, CollectionCursorCallback

    def set_last_cursor(callback : CollectionCursorCallback) : self
      last_cursor(callback)
    end

    forward_block set_last_cursor, CollectionCursorCallback

    def set_counter(callback : CollectionCounterCallback) : self
      counter(callback)
    end

    forward_block set_counter, CollectionCounterCallback

    def filter(predicate : CollectionFilterPredicate) : self
      @federation.set_collection_filter(@name, predicate)
      self
    end

    forward_block filter, CollectionFilterPredicate

    def authorize(authorizer : AuthorizePredicate) : self
      @federation.set_collection_authorizer(@name, authorizer)
      self
    end

    forward_block authorize, AuthorizePredicate
  end

  class ObjectCallbacks
    def initialize(@federation : Federation, @type : String)
    end

    private macro forward_block(method_name, block_type)
      def {{method_name.id}}(&block : {{block_type.id}}) : self
        {{method_name.id}}(block)
      end
    end

    def authorize(authorizer : AuthorizePredicate) : self
      @federation.set_object_authorizer(@type, authorizer)
      self
    end

    forward_block authorize, AuthorizePredicate
  end
end
