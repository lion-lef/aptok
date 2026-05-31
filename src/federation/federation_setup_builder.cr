module Aptok
  class Federation
    def set_collection_dispatcher(name : String, path : String, dispatcher : CollectionDispatcher) : self
      set_array_collection_dispatcher(name, path, identifier_collection_dispatcher(dispatcher), ordered: false)
    end

    def set_collection_dispatcher(name : String, path : String, dispatcher : ParamCollectionDispatcher) : self
      set_array_collection_dispatcher(name, path, dispatcher, ordered: false)
    end

    def set_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_collection_page_dispatcher(name, path, dispatcher)
    end

    def set_collection_page_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_cursor_collection_dispatcher(name, path, dispatcher, ordered: false)
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : CollectionDispatcher) : self
      set_array_collection_dispatcher(name, path, identifier_collection_dispatcher(dispatcher), ordered: true)
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : ParamCollectionDispatcher) : self
      set_array_collection_dispatcher(name, path, dispatcher, ordered: true)
    end

    def set_ordered_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_ordered_collection_page_dispatcher(name, path, dispatcher)
    end

    def set_ordered_collection_page_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_cursor_collection_dispatcher(name, path, dispatcher, ordered: true)
    end

    def set_collection_item_type(name : String, item_type : String) : self
      @collection_item_types[name] = item_type
      self
    end

    def set_collection_first_cursor(name : String, callback : CollectionCursorCallback) : self
      @collection_first_cursor_callbacks[name] = callback
      self
    end

    def set_collection_last_cursor(name : String, callback : CollectionCursorCallback) : self
      @collection_last_cursor_callbacks[name] = callback
      self
    end

    def set_collection_counter(name : String, callback : CollectionCounterCallback) : self
      @collection_counter_callbacks[name] = callback
      self
    end

    def set_collection_filter(name : String, predicate : CollectionFilterPredicate) : self
      @collection_filter_predicates[name] = predicate
      self
    end

    def configure_collection(name : String) : CollectionCallbacks
      CollectionCallbacks.new(self, name)
    end

    private def set_array_collection_dispatcher(name : String, path : String, dispatcher : ParamCollectionDispatcher, *, ordered : Bool) : self
      set_collection_route(CollectionRoute.new(name, path, dispatcher, nil, nil, ordered))
    end

    private def set_cursor_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher, *, ordered : Bool) : self
      set_collection_route(CollectionRoute.new(name, path, nil, dispatcher, nil, ordered))
    end

    private def set_filtered_cursor_collection_dispatcher(name : String, path : String, dispatcher : ParamFilteredCursorCollectionDispatcher, *, ordered : Bool) : self
      set_collection_route(CollectionRoute.new(name, path, nil, nil, dispatcher, ordered))
    end

    private def set_collection_route(route : CollectionRoute) : self
      validate_path!(route.path)
      @collection_routes.reject! { |existing| existing.name == route.name && existing.path == route.path }
      @collection_routes << route
      self
    end

    private def identifier_collection_dispatcher(dispatcher : CollectionDispatcher) : ParamCollectionDispatcher
      ->(ctx : Context, params : Hash(String, String)) do
        dispatcher.call(ctx, params["identifier"]? || "")
      end
    end

    private def set_builtin_cursor_collection_dispatcher(name : String, path : String, dispatcher : CursorCollectionDispatcher) : self
      validate_identifier_route!(path, name)
      param_dispatcher = ->(ctx : Context, params : Hash(String, String), cursor : String?, size : Int32) do
        dispatcher.call(ctx, params["identifier"]? || "", cursor, size).as(CollectionPageResult?)
      end
      set_ordered_collection_page_dispatcher(name, path, param_dispatcher)
    end

    private def set_builtin_cursor_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      validate_identifier_route!(path, name)
      set_ordered_collection_page_dispatcher(name, path, dispatcher)
    end

    def set_outbox_page_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      set_outbox_page_dispatcher(path, ->(ctx : Context, identifier : String, cursor : String?, size : Int32) do
        dispatcher.call(ctx, identifier, cursor, size).as(CollectionPageResult?)
      end)
    end

    def set_outbox_page_dispatcher(path : String, dispatcher : NullableCursorCollectionDispatcher) : self
      validate_outbox_route!(path)
      validate_existing_route_path!(@outbox_path, path, "outbox") if @outbox_path_configured
      @outbox_path = path
      @outbox_path_configured = true
      @outbox_page_dispatcher = dispatcher
      self
    end

    def set_inbox_listeners(inbox_path : String, shared_inbox_path : String? = nil) : InboxListeners
      validate_identifier_route!(inbox_path, "inbox")
      validate_existing_route_path!(@inbox_path, inbox_path, "inbox") if @inbox_path_configured
      validate_static_route!(shared_inbox_path, "shared inbox") if shared_inbox_path
      @inbox_path = inbox_path
      @inbox_path_configured = true
      @shared_inbox_path = shared_inbox_path
      InboxListeners.new(self)
    end

    def set_outbox_listeners(outbox_path : String) : OutboxListeners
      validate_outbox_route!(outbox_path)
      validate_existing_route_path!(@outbox_path, outbox_path, "outbox") if @outbox_path_configured
      @outbox_path = outbox_path
      @outbox_path_configured = true
      OutboxListeners.new(self)
    end

    def on_error(handler : Proc(Context, Exception, Nil)) : self
      @error_handler = handler
      self
    end

    def set_inbox_verifier(verifier : InboxVerifier) : self
      @inbox_verifier = verifier
      self
    end

    def set_shared_key_dispatcher(dispatcher : SharedInboxKeyDispatcher) : self
      @shared_inbox_key_dispatcher = dispatcher
      self
    end

    def set_inbox_verifier(verifier : Proc(Request, JsonMap, Bool)) : self
      @inbox_verifier = ->(request : Request, activity : JsonMap) do
        VerificationResult.new(verifier.call(request, activity))
      end
      self
    end

    def on_unverified_activity(listener : UnverifiedActivityListener) : self
      @unverified_activity_listener = listener
      self
    end

    def set_webfinger_dispatcher(dispatcher : WebFingerDispatcher) : self
      @webfinger_dispatcher = dispatcher
      self
    end

    def set_webfinger_links_dispatcher(dispatcher : WebFingerLinksDispatcher) : self
      @webfinger_links_dispatcher = dispatcher
      self
    end

    def map_handle(mapper : HandleMapper) : self
      @handle_mapper = mapper
      self
    end

    def map_alias(mapper : Proc(Context, String, T)) : self forall T
      @alias_mapper = ->(ctx : Context, resource : String) : AliasMapping? do
        normalize_alias_mapping(mapper.call(ctx, resource))
      end
      self
    end

    private def normalize_alias_mapping(mapping : AliasMapping?) : AliasMapping?
      mapping
    end

    def set_nodeinfo_dispatcher(dispatcher : NodeInfoDispatcher) : self
      set_nodeinfo_dispatcher("/nodeinfo/2.1", dispatcher)
    end

    def set_nodeinfo_dispatcher(path : String, dispatcher : NodeInfoDispatcher) : self
      validate_path!(path)
      @nodeinfo_path = path
      @nodeinfo_dispatcher = dispatcher
      self
    end

    def set_key_pairs_dispatcher(dispatcher : KeyPairsDispatcher) : self
      @key_pairs_dispatcher = dispatcher
      self
    end

    def set_signature_key_resolver(resolver : SignatureKeyResolver) : self
      @signature_key_resolver = resolver
      @inbox_signature_options ||= InboxSignatureOptions.new
      self
    end

    def enable_inbox_signature_verification(options : InboxSignatureOptions = InboxSignatureOptions.new) : self
      @inbox_signature_options = options
      self
    end

    def set_actor_authorizer(authorizer : AuthorizePredicate) : self
      @actor_authorizer = authorizer
      self
    end

    def set_object_authorizer(type : String, authorizer : AuthorizePredicate) : self
      @object_authorizers[type] = authorizer
      self
    end

    def configure_object(type : String) : ObjectCallbacks
      ObjectCallbacks.new(self, type)
    end

    def set_collection_authorizer(name : String, authorizer : AuthorizePredicate) : self
      @collection_authorizers[name] = authorizer
      self
    end

    def add_activity_transformer(transformer : ActivityTransformer) : self
      @activity_transformers << transformer
      self
    end

    def add_default_activity_transformers : self
      self.class.default_activity_transformers.each { |transformer| add_activity_transformer(transformer) }
      self
    end

    def self.default_activity_transformers : Array(ActivityTransformer)
      [auto_id_assigner, actor_dehydrator, public_audience_normalizer, attachment_array_normalizer]
    end

    def self.auto_id_assigner : ActivityTransformer
      ->(ctx : Context, _transform : ActivityTransformContext, activity : JsonMap) do
        unless activity.has_key?("id") || activity.has_key?("@id")
          type = activity["type"]?.try(&.as_s?) || "Activity"
          activity["id"] = Aptok.json("#{ctx.origin}/##{type}/#{Random::Secure.hex(16)}")
        end
        activity
      end
    end

    def self.actor_dehydrator : ActivityTransformer
      ->(_ctx : Context, _transform : ActivityTransformContext, activity : JsonMap) do
        if actor = activity["actor"]?
          activity["actor"] = dehydrate_actor_value(actor)
        end
        activity
      end
    end

    def self.public_audience_normalizer : ActivityTransformer
      ->(_ctx : Context, _transform : ActivityTransformContext, activity : JsonMap) do
        normalize_public_audience_values(activity)
        activity
      end
    end
  end
end
