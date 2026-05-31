module Aptok
  class Context
    def object(type : String, params : Hash(String, String)) : JsonMap?
      @federation.dispatch_object(self, type, params)
    end

    def object(type : String, params : NamedTuple) : JsonMap?
      object(type, string_params(params))
    end

    def object(type : T.class, identifier : String) : T? forall T
      object(type, {"identifier" => identifier})
    end

    def object(type : T.class, params : Hash(String, String)) : T? forall T
      raw = object(T.type_name, params)
      raw ? T.from_json_ld(raw) : nil
    end

    def object(type : T.class, params : NamedTuple) : T? forall T
      object(type, string_params(params))
    end

    def get_object(type : String, identifier : String) : JsonMap?
      get_object(type, {"identifier" => identifier})
    end

    def get_object(type : String, params : Hash(String, String)) : JsonMap?
      raise ArgumentError.new("No object dispatcher registered for #{type}") unless @federation.has_object_dispatcher?(type)

      object(type, params)
    end

    def get_object(type : String, params : NamedTuple) : JsonMap?
      get_object(type, string_params(params))
    end

    def get_object(type : T.class, identifier : String) : T? forall T
      get_object(type, {"identifier" => identifier})
    end

    def get_object(type : T.class, params : Hash(String, String)) : T? forall T
      raw = get_object(T.type_name, params)
      raw ? T.from_json_ld(raw) : nil
    end

    def get_object(type : T.class, params : NamedTuple) : T? forall T
      get_object(type, string_params(params))
    end

    def get_actor_key_pairs(identifier : String) : Array(ActorKeyPair)
      if dispatcher_identifier = @key_pairs_dispatcher_identifier
        Log.warn { "Context#get_actor_key_pairs(#{identifier.inspect}) was called from the actor key pairs dispatcher for #{dispatcher_identifier.inspect}; this may cause an infinite loop" }
      end
      @federation.dispatch_key_pairs(self, identifier)
    end

    def outbox(identifier : String) : Array(JsonMap)
      @federation.dispatch_outbox(self, identifier)
    end

    def collection(name : String, identifier : String) : Array(JsonMap)
      @federation.dispatch_collection(self, name, identifier)
    end

    def collection(name : String, params : Hash(String, String)) : Array(JsonMap)
      @federation.dispatch_collection(self, name, params)
    end

    def collection(name : String, params : NamedTuple) : Array(JsonMap)
      collection(name, string_params(params))
    end

    def get_signed_key_owner(request : Request) : String?
      @federation.signed_key_owner(request)
    end

    def get_signed_key : ActorKeyPair?
      request = @inbound_request
      request ? @federation.signed_key(request) : nil
    end

    def get_signed_key_owner : String?
      request = @inbound_request
      request ? @federation.signed_key_owner(request) : nil
    end

    def get_signed_key_owner_actor(options : GetSignedKeyOptions = GetSignedKeyOptions.new) : Vocab::Actor?
      get_signed_key_owner(Aptok::Vocab::Actor, options)
    end

    def get_signed_key_owner(type : T.class, options : GetSignedKeyOptions = GetSignedKeyOptions.new) : T? forall T
      owner = get_signed_key_owner
      return nil unless owner

      loader = options.document_loader || document_loader
      Remote.lookup_object(owner, type, loader)
    end

    def document_loader : DocumentLoader
      @document_loader_override || @federation.document_loader
    end

    def context_loader : DocumentLoader
      @context_loader_override || @federation.context_loader
    end

    def get_document_loader(identifier : String, get_provider : DocumentGetProvider? = nil) : DocumentLoader
      key_pair = first_rsa_key_pair(identifier)
      provider = get_provider || @federation.document_get_provider
      key_pair ? Remote.authenticated_document_loader(key_pair, provider, allow_private_address: @federation.allow_private_address, user_agent: @federation.user_agent) : @federation.document_loader
    end

    def get_document_loader(key_pair : ActorKeyPair, get_provider : DocumentGetProvider? = nil) : DocumentLoader
      Remote.authenticated_document_loader(key_pair, get_provider || @federation.document_get_provider, allow_private_address: @federation.allow_private_address, user_agent: @federation.user_agent)
    end

    def get_document_loader(sender : NamedTuple(identifier: String), get_provider : DocumentGetProvider? = nil) : DocumentLoader
      get_document_loader(sender[:identifier], get_provider)
    end

    def get_document_loader(sender : NamedTuple(username: String), get_provider : DocumentGetProvider? = nil) : DocumentLoader
      if identifier = @federation.webfinger_identifier(self, sender[:username])
        get_document_loader(identifier, get_provider)
      else
        @federation.document_loader
      end
    end

    def lookup_webfinger(resource : String, options : LookupWebFingerOptions = LookupWebFingerOptions.new) : JsonMap?
      Remote.lookup_webfinger(resource, lookup_webfinger_document_loader(options))
    end

    def lookup_webfinger(resource : URI, options : LookupWebFingerOptions = LookupWebFingerOptions.new) : JsonMap?
      lookup_webfinger(resource.to_s, options)
    end

    def lookup_object(target : String, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      Remote.lookup_object(target, lookup_document_loader(options), options)
    end

    def lookup_object(target : String, type : T.class, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      Remote.lookup_object(target, type, lookup_document_loader(options), options)
    end

    def lookup_object(target : URI, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      lookup_object(target.to_s, options)
    end

    def lookup_object(target : URI, type : T.class, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      lookup_object(target.to_s, type, options)
    end

    def get_actor_handle(actor : JsonMap, options : ActorHandleOptions = ActorHandleOptions.new) : String
      Remote.get_actor_handle(actor, document_loader, options)
    end

    def get_actor_handle(actor : Vocab::Actor, options : ActorHandleOptions = ActorHandleOptions.new) : String
      Remote.get_actor_handle(actor, document_loader, options)
    end

    def get_actor_handle(actor_uri : String, options : ActorHandleOptions = ActorHandleOptions.new) : String
      Remote.get_actor_handle(actor_uri, document_loader, options)
    end

    def verify_object_reference(object_or_id : JSON::Any, parent_origin : String? = nil, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      Remote.verify_object_reference(object_or_id, lookup_document_loader(options), parent_origin, options)
    end

    def verify_activity_object(activity : JsonMap, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      Remote.verify_activity_object(activity, lookup_document_loader(options), options)
    end

    private def lookup_document_loader(options : LookupObjectOptions) : DocumentLoader
      options.document_loader || document_loader
    end

    private def lookup_webfinger_document_loader(options : LookupWebFingerOptions) : DocumentLoader
      options.document_loader || document_loader
    end

    private def lookup_nodeinfo_document_loader(options : NodeInfoLookupOptions) : DocumentLoader
      if loader = options.document_loader
        loader
      elsif provider = options.document_get_provider
        Remote.default_document_loader(provider, allow_private_address: @federation.allow_private_address, user_agent: @federation.user_agent, accept: "application/json")
      else
        document_loader
      end
    end

    def lookup_nodeinfo(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      Aptok.lookup_nodeinfo(origin, lookup_nodeinfo_document_loader(options), options)
    end

    def lookup_nodeinfo(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      lookup_nodeinfo(origin.to_s, options)
    end

    def lookup_nodeinfo(origin : String, parse : String) : JsonMap?
      lookup_nodeinfo(origin, NodeInfoLookupOptions.new(parse: parse))
    end

    def lookup_nodeinfo_document(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      Aptok.lookup_nodeinfo_document(origin, lookup_nodeinfo_document_loader(options), options)
    end

    def lookup_nodeinfo_document(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      lookup_nodeinfo_document(origin.to_s, options)
    end

    def lookup_nodeinfo_document(origin : String, parse : String) : NodeInfo?
      lookup_nodeinfo_document(origin, NodeInfoLookupOptions.new(parse: parse))
    end

    def traverse_collection(collection : JsonMap, limit : Int32? = nil) : Array(JsonMap)
      Remote.traverse_collection(collection, document_loader, limit)
    end

    def traverse_collection(collection : Vocab::Collection, limit : Int32? = nil) : Array(Vocab::Object)
      Remote.traverse_collection(collection, document_loader, limit)
    end

    def traverse_collection(collection : JsonMap, options : TraverseCollectionOptions) : Array(JsonMap)
      Remote.traverse_collection(collection, traverse_document_loader(options), options)
    end

    def traverse_collection(collection : Vocab::Collection, options : TraverseCollectionOptions) : Array(Vocab::Object)
      Remote.traverse_collection(collection, traverse_document_loader(options), options)
    end

    def traverse_collection(collection_url : String, limit : Int32? = nil) : Array(JsonMap)
      collection = lookup_object(collection_url, LookupObjectOptions.new(cross_origin: "trust"))
      collection ? traverse_collection(collection, limit) : [] of JsonMap
    end

    def traverse_collection(collection_url : String, options : TraverseCollectionOptions) : Array(JsonMap)
      collection = lookup_object(collection_url, LookupObjectOptions.new(document_loader: options.document_loader, cross_origin: "trust"))
      collection ? traverse_collection(collection, options) : [] of JsonMap
    rescue ex
      raise ex unless options.suppress_error
      [] of JsonMap
    end

    def traverse_collection(collection_url : URI, limit : Int32? = nil) : Array(JsonMap)
      traverse_collection(collection_url.to_s, limit)
    end

    def traverse_collection(collection_url : URI, options : TraverseCollectionOptions) : Array(JsonMap)
      traverse_collection(collection_url.to_s, options)
    end

    private def traverse_document_loader(options : TraverseCollectionOptions) : DocumentLoader
      options.document_loader || document_loader
    end
  end
end
