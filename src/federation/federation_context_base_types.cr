module Aptok
  class Context
    getter federation : Federation
    getter origin : String
    getter recipient_identifier : String?
    getter outbox_identifier : String?
    getter inbound_request : Request?
    getter data : JSON::Any?
    getter key_pairs_dispatcher_identifier : String?
    getter portable_authority : String?
    @canonical_origin : String

    def initialize(
      @federation : Federation,
      @origin : String,
      @transport : Transport,
      @recipient_identifier : String? = nil,
      @outbox_identifier : String? = nil,
      @inbound_request : Request? = nil,
      @data : JSON::Any? = nil,
      @delivery_state : DeliveryState = DeliveryState.new,
      @document_loader_override : DocumentLoader? = nil,
      @context_loader_override : DocumentLoader? = nil,
      canonical_origin : String? = nil,
      @key_pairs_dispatcher_identifier : String? = nil,
      @portable_authority : String? = nil
    )
      @origin = strip_trailing_slash(@origin)
      @canonical_origin = strip_trailing_slash(canonical_origin || @origin)
    end

    def with_recipient(recipient_identifier : String?) : Context
      Context.new(@federation, @origin, @transport, recipient_identifier, @outbox_identifier, @inbound_request, @data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def with_outbox(outbox_identifier : String?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, outbox_identifier, @inbound_request, @data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def with_inbound_request(request : Request?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, request, @data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def with_document_loader(loader : DocumentLoader?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, @inbound_request, @data, @delivery_state, loader, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def with_context_loader(loader : DocumentLoader?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, @inbound_request, @data, @delivery_state, @document_loader_override, loader, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def with_data(data : JSON::Any?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, @inbound_request, data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, @portable_authority)
    end

    def clone(data : JSON::Any?) : Context
      with_data(data)
    end

    def with_key_pairs_dispatcher(identifier : String?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, @inbound_request, @data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, identifier, @portable_authority)
    end

    def with_portable_authority(authority : String?) : Context
      Context.new(@federation, @origin, @transport, @recipient_identifier, @outbox_identifier, @inbound_request, @data, @delivery_state, @document_loader_override, @context_loader_override, @canonical_origin, @key_pairs_dispatcher_identifier, normalize_portable_authority(authority))
    end

    def request : Request?
      @inbound_request
    end

    def identifier : String?
      @outbox_identifier || @recipient_identifier
    end

    def url : String?
      req = @inbound_request
      return nil unless req

      query = req.query.empty? ? "" : "?#{URI::Params.encode(req.query)}"
      "#{@origin}#{req.path}#{query}"
    end

    def canonical_origin : String
      @canonical_origin
    end

    def resource_base_uri : String
      if authority = @portable_authority
        "#{AP_URI_PREFIX}#{authority}"
      else
        @canonical_origin
      end
    end

    def host : String
      parsed_origin.host ? authority_from_uri(parsed_origin) : ""
    end

    def hostname : String
      parsed_origin.host.to_s
    end

    def has_delivered_activity? : Bool
      @delivery_state.delivered_activity
    end

    def has_delivered_activity : Bool
      has_delivered_activity?
    end

    def mark_activity_delivered : Nil
      @delivery_state.delivered_activity = true
    end

    def reset_delivered_activity : Nil
      @delivery_state.delivered_activity = false
    end

    def get_actor_uri(identifier : String) : String
      if path = @federation.actor_alias_path(identifier)
        "#{resource_base_uri}#{path}"
      else
        uri_from_template(@federation.actor_path, identifier)
      end
    end

    def get_inbox_uri(identifier : String? = nil) : String
      if identifier
        uri_from_template(@federation.inbox_path, identifier)
      else
        shared = @federation.shared_inbox_path || @federation.inbox_path
        uri_from_template(shared, "")
      end
    end

    def get_outbox_uri(identifier : String) : String
      uri_from_template(@federation.outbox_path, identifier)
    end

    def get_followers_uri(identifier : String) : String
      uri_from_template(@federation.followers_path, identifier)
    end

    def get_following_uri(identifier : String) : String
      uri_from_template(@federation.following_path, identifier)
    end

    def get_liked_uri(identifier : String) : String
      uri_from_template(@federation.liked_path, identifier)
    end

    def get_featured_uri(identifier : String) : String
      uri_from_template(@federation.featured_path, identifier)
    end

    def get_featured_tags_uri(identifier : String) : String
      uri_from_template(@federation.featured_tags_path, identifier)
    end

    def get_collection_uri(name : String, params : Hash(String, String)) : String
      route = @federation.collection_routes.find { |candidate| candidate.name == name }
      raise ArgumentError.new("collection dispatcher is not configured for #{name}") unless route
      "#{resource_base_uri}#{RouteTemplate.new(route.path).expand(params)}"
    end

    def get_collection_uri(name : String, params : NamedTuple) : String
      get_collection_uri(name, string_params(params))
    end

    def get_collection_uri(name : String, identifier : String) : String
      get_collection_uri(name, {"identifier" => identifier})
    end

    def get_nodeinfo_uri : String
      raise ArgumentError.new("No NodeInfo dispatcher registered") unless @federation.has_nodeinfo_dispatcher?

      uri_from_template(@federation.nodeinfo_path, "")
    end

    def get_object_uri(type : String, params : Hash(String, String)) : String
      route = @federation.object_routes.find { |candidate| candidate.type == type }
      raise ArgumentError.new("object dispatcher is not configured for #{type}") unless route
      "#{resource_base_uri}#{RouteTemplate.new(route.path).expand(params)}"
    end

    def get_object_uri(type : String, params : NamedTuple) : String
      get_object_uri(type, string_params(params))
    end

    def get_object_uri(type : String, identifier : String) : String
      get_object_uri(type, {"identifier" => identifier})
    end

    def get_object_uri(type : T.class, params : Hash(String, String)) : String forall T
      get_object_uri(T.type_name, params)
    end

    def get_object_uri(type : T.class, params : NamedTuple) : String forall T
      get_object_uri(T.type_name, params)
    end

    def get_object_uri(type : T.class, identifier : String) : String forall T
      get_object_uri(T.type_name, identifier)
    end

    def parse_uri(uri : Nil) : ParsedUri?
      nil
    end

    def parse_uri(uri : URI) : ParsedUri?
      parse_uri(uri.to_s)
    end

    def parse_uri(uri : String) : ParsedUri?
      if parsed_ap = Aptok.parse_ap_uri(uri) || Aptok.parse_compatible_ap_uri(uri)
        return nil unless @portable_authority == parsed_ap.authority

        return parsed_uri_from_path(parsed_ap.path.empty? ? "/" : parsed_ap.path)
      end

      parsed = URI.parse(uri)
      return nil unless parsed.scheme && parsed.host
      port = parsed.port
      host = parsed.host.to_s
      host = "#{host}:#{port}" if port
      parsed_origin = "#{parsed.scheme}://#{host}"
      return nil unless parsed_origin == @origin || parsed_origin == @canonical_origin

      path = @federation.route_path(parsed.path.empty? ? "/" : parsed.path)
      parsed_uri_from_path(path)
    rescue URI::Error
      nil
    end

    private def parsed_uri_from_path(path : String) : ParsedUri?
      if identifier = @federation.actor_alias_identifier(path)
        return ParsedUri.new("actor", identifier, values: {"identifier" => identifier})
      end
      if params = @federation.match_route(@federation.actor_path, path)
        return ParsedUri.new("actor", params["identifier"]?, values: params)
      end
      if params = @federation.match_route(@federation.outbox_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "outbox", values: params)
      end
      if params = @federation.match_route(@federation.inbox_path, path)
        return ParsedUri.new("inbox", params["identifier"]?, values: params)
      end
      if shared = @federation.shared_inbox_path
        if @federation.match_route(shared, path)
          return ParsedUri.new("inbox", nil)
        end
      end
      if params = @federation.match_route(@federation.followers_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "followers", values: params)
      end
      if params = @federation.match_route(@federation.following_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "following", values: params)
      end
      if params = @federation.match_route(@federation.liked_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "liked", values: params)
      end
      if params = @federation.match_route(@federation.featured_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "featured", values: params)
      end
      if params = @federation.match_route(@federation.featured_tags_path, path)
        return ParsedUri.new("collection", params["identifier"]?, collection_name: "featured_tags", values: params)
      end
      @federation.collection_routes.each do |route|
        if params = @federation.match_route(route.path, path)
          return ParsedUri.new("collection", params["identifier"]?, collection_name: route.name, values: params)
        end
      end
      @federation.object_routes.each do |route|
        if params = @federation.match_route(route.path, path)
          return ParsedUri.new("object", params["identifier"]?, object_type: route.type, values: params)
        end
      end

      nil
    end

    private def normalize_portable_authority(authority : String?) : String?
      return nil unless authority

      parsed = Aptok.parse_ap_uri("#{AP_URI_PREFIX}#{authority}/")
      raise ArgumentError.new("portable authority must be a DID") unless parsed
      parsed.authority
    end

    def actor(identifier : String) : JsonMap?
      @federation.dispatch_actor(self, identifier)
    end

    def actor(identifier : String, type : T.class) : T? forall T
      actor(identifier).try { |actor| T.from_json_ld(actor) }
    end

    def get_actor(identifier : String, options : GetActorOptions = GetActorOptions.new) : JsonMap?
      raise ArgumentError.new("No actor dispatcher registered") unless @federation.has_actor_dispatcher?

      actor = self.actor(identifier)
      return nil unless actor
      return nil if options.tombstone == "suppress" && tombstone?(actor)
      actor
    end

    def get_actor(identifier : String, type : T.class, options : GetActorOptions = GetActorOptions.new) : T? forall T
      get_actor(identifier, options).try { |actor| T.from_json_ld(actor) }
    end

    def object(type : String, identifier : String) : JsonMap?
      @federation.dispatch_object(self, type, identifier)
    end
  end
end
