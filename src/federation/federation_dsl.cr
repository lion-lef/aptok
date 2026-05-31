module Aptork
  class Federation
    private alias DslObjectDispatcher = ObjectDispatcher | ParamObjectDispatcher
    private alias DslCollectionDispatcher = CollectionDispatcher | ParamCollectionDispatcher | ParamCursorCollectionDispatcher
    private alias DslBuiltinCollectionDispatcher = CollectionDispatcher | CursorCollectionDispatcher | ParamCursorCollectionDispatcher
    private alias DslFollowersDispatcher = DslBuiltinCollectionDispatcher | FilteredCursorCollectionDispatcher

    def actor(path : String, dispatcher : ActorDispatcher) : self
      set_actor_dispatcher(path, dispatcher)
    end

    def actor_alias(path : String, identifier : String) : self
      map_actor_alias(path, identifier)
    end

    def object(type : String, path : String, dispatcher : DslObjectDispatcher) : self
      set_object_dispatcher(type, path, dispatcher)
    end

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

    def collection(name : String, path : String, dispatcher : DslCollectionDispatcher) : self
      set_collection_dispatcher(name, path, dispatcher)
    end

    def collection_page(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_collection_page_dispatcher(name, path, dispatcher)
    end

    def ordered_collection(name : String, path : String, dispatcher : DslCollectionDispatcher) : self
      set_ordered_collection_dispatcher(name, path, dispatcher)
    end

    def ordered_collection_page(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_ordered_collection_page_dispatcher(name, path, dispatcher)
    end

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

    def webfinger_links(dispatcher : WebFingerLinksDispatcher) : self
      set_webfinger_links_dispatcher(dispatcher)
    end

    def handles(mapper : HandleMapper) : self
      map_handle(mapper)
    end

    def aliases(mapper : Proc(Context, String, T)) : self forall T
      map_alias(mapper)
    end

    def nodeinfo(dispatcher : NodeInfoDispatcher) : self
      set_nodeinfo_dispatcher(dispatcher)
    end

    def nodeinfo(path : String, dispatcher : NodeInfoDispatcher) : self
      set_nodeinfo_dispatcher(path, dispatcher)
    end

    def key_pairs(dispatcher : KeyPairsDispatcher) : self
      set_key_pairs_dispatcher(dispatcher)
    end

    def signature_keys(resolver : SignatureKeyResolver) : self
      set_signature_key_resolver(resolver)
    end
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
