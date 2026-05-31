require "./remote_types"
require "http/client"
require "uri"
require "socket"
require "set"
require "digest/sha256"
require "../vocabulary/vocabulary"
require "../signatures/signatures"
require "../portable"

module Aptok
  module Remote
    def self.default_user_agent : String
      DEFAULT_USER_AGENT
    end

    def self.default_document_loader(get_provider : DocumentGetProvider? = nil, *, allow_private_address : Bool = false, user_agent : String = default_user_agent, transient_retries : Int32? = nil, accept : String = FEDERATION_JSONLD_CONTENT_TYPE) : DocumentLoader
      document_loader(get_provider, allow_private_address: allow_private_address, user_agent: user_agent, transient_retries: transient_retries, accept: accept)
    end

    def self.authenticated_document_loader(key_pair : ActorKeyPair, get_provider : DocumentGetProvider? = nil, *, allow_private_address : Bool = false, user_agent : String = default_user_agent, transient_retries : Int32? = nil, accept : String = FEDERATION_JSONLD_CONTENT_TYPE) : DocumentLoader
      validate_authenticated_document_loader_key!(key_pair)
      document_loader(get_provider, key_pair, allow_private_address: allow_private_address, user_agent: user_agent, transient_retries: transient_retries, accept: accept)
    end

    def self.document_loader(get_provider : DocumentGetProvider? = nil, key_pair : ActorKeyPair? = nil, *, allow_private_address : Bool = false, user_agent : String = default_user_agent, transient_retries : Int32? = nil, accept : String = FEDERATION_JSONLD_CONTENT_TYPE) : DocumentLoader
      validate_authenticated_document_loader_key!(key_pair) if key_pair
      json_document_loader(document_loader_with_metadata(wrap_get_provider(get_provider), key_pair, allow_private_address: allow_private_address, user_agent: user_agent, transient_retries: transient_retries, accept: accept))
    end

    def self.json_document_loader(loader : MetadataDocumentLoader) : DocumentLoader
      ->(url : String) : JsonMap? do
        loader.call(url).try(&.json)
      end
    end

    def self.cached_json_document_loader(loader : DocumentLoader, cache : KvStore, options : DocumentCacheOptions = DocumentCacheOptions.new) : DocumentLoader
      ->(url : String) : JsonMap? do
        key = document_cache_key(options.prefix, url)
        if cached = cache.get(key)
          return JSON.parse(cached).as_h
        end

        document = loader.call(url)
        cache.set(key, document.to_json, options.ttl) if document
        document
    rescue
      nil
      end
    end

    def self.kv_cache(loader : DocumentLoader, cache : KvStore, options : DocumentCacheOptions = DocumentCacheOptions.new) : DocumentLoader
      cached_json_document_loader(loader, cache, options)
    end

    def self.cached_document_loader(loader : MetadataDocumentLoader, cache : KvStore, options : DocumentCacheOptions = DocumentCacheOptions.new) : MetadataDocumentLoader
      ->(url : String) : RemoteDocument? do
        key = document_cache_key(options.prefix, url)
        if cached = cache.get(key)
          return remote_document_from_cache(cached)
        end

        document = loader.call(url)
        cache.set(key, remote_document_cache_value(document), options.ttl) if document
        document
    rescue
      nil
      end
    end

    def self.document_loader_with_metadata(get_provider : MetadataDocumentGetProvider? = nil, key_pair : ActorKeyPair? = nil, *, allow_private_address : Bool = false, user_agent : String = default_user_agent, transient_retries : Int32? = nil, accept : String = FEDERATION_JSONLD_CONTENT_TYPE) : MetadataDocumentLoader
      validate_authenticated_document_loader_key!(key_pair) if key_pair
      ->(url : String) : RemoteDocument? do
        validate_public_url!(url) unless allow_private_address
        max_retries = transient_retries || (key_pair ? 1 : 0)
        max_retries = 0 if max_retries < 0
        attempt = 0
        loop do
          headers = HTTP::Headers{
            "Accept"     => accept,
            "User-Agent" => user_agent,
          }
          if key_pair
            Signatures.rsa_sha256_headers("get", url, "", key_pair).each do |key, value|
              headers[key] = value
            end
          end
          begin
            if provider = get_provider
              status_code, body, response_headers = provider.call(url, headers)
            else
              response = HTTP::Client.get(url, headers: headers)
              status_code = response.status_code
              body = response.body
              response_headers = response.headers
            end
          rescue
            if attempt < max_retries
              attempt += 1
              next
            end
            return nil
          end

          return nil unless status_code >= 200 && status_code < 300

          content_type = header_value(response_headers, "Content-Type")
          return nil unless json_document_content_type?(content_type)

          return RemoteDocument.new(
            url: url,
            content_type: content_type,
            status: status_code,
            headers: headers_hash(response_headers),
            json: JSON.parse(body).as_h
          )
        end
    rescue
      nil
      end
    end

    private def self.validate_authenticated_document_loader_key!(key_pair : ActorKeyPair) : Nil
      has_private_key = !!key_pair.private_key_pem || !!key_pair.private_key_path.try { |path| !path.empty? }
      return if key_pair.algorithm.downcase == "rsa-sha256" && !key_pair.id.empty? && has_private_key

      raise ArgumentError.new("authenticated document loaders require an RSA-SHA256 key pair with a private key")
    end

    def self.validate_public_url!(url : String) : Nil
      uri = URI.parse(url)
      scheme = uri.scheme.try(&.downcase)
      raise ArgumentError.new("document URL must use http or https") unless scheme == "http" || scheme == "https"

      host = uri.hostname || uri.host
      raise ArgumentError.new("document URL must include a host") unless host

      normalized_host = host.downcase
      raise ArgumentError.new("document URL must not use localhost") if normalized_host == "localhost" || normalized_host.ends_with?(".localhost")

      port = uri.port || (scheme == "http" ? 80 : 443)
      if private_ip_address?(host, port)
        raise ArgumentError.new("document URL must not resolve to a private address")
      end

      Socket::Addrinfo.resolve(host, port, type: Socket::Type::STREAM).each do |addrinfo|
        address = addrinfo.ip_address.address
        if private_ip_address?(address, port)
          raise ArgumentError.new("document URL must not resolve to a private address")
        end
      end
    rescue ex : ArgumentError
      raise ex
    rescue Socket::Error
      nil
    end

    def self.lookup_object(target : String, loader : DocumentLoader, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      stripped = target.strip
      if Aptok.ap_uri?(stripped)
        gateways = (options.gateways + Aptok.ap_uri_gateways(stripped)).uniq
        gateways.each do |gateway|
          url = Aptok.ap_gateway_url(gateway, stripped)
          if object = loader.call(url)
            return lookup_object_result(stripped, object, options)
          end
        end
        return nil
      end

      if http_url?(stripped)
        if object = loader.call(stripped)
          return lookup_object_result(stripped, object, options)
        end
      end

      url = object_url(stripped, loader)
      return nil unless url

      object = loader.call(url)
      return nil unless object
      lookup_object_result(url, object, options)
    end

    def self.lookup_object(target : String, type : T.class, loader : DocumentLoader, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      object = lookup_object(target, loader, options)
      object ? Vocab::Object.from_json_ld(object).as?(T) : nil
    end

    def self.lookup_object(target : URI, loader : DocumentLoader, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      lookup_object(target.to_s, loader, options)
    end

    def self.lookup_object(target : URI, type : T.class, loader : DocumentLoader, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      lookup_object(target.to_s, type, loader, options)
    end

    def self.lookup_object(target : String, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      loader = options.document_loader || default_document_loader(allow_private_address: options.allow_private_address, user_agent: options.user_agent)
      lookup_object(target, loader, options)
    end

    def self.lookup_object(target : String, type : T.class, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      loader = options.document_loader || default_document_loader(allow_private_address: options.allow_private_address, user_agent: options.user_agent)
      lookup_object(target, type, loader, options)
    end

    def self.lookup_object(target : URI, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      lookup_object(target.to_s, options)
    end

    def self.lookup_object(target : URI, type : T.class, options : LookupObjectOptions = LookupObjectOptions.new) : T? forall T
      lookup_object(target.to_s, type, options)
    end

    private def self.lookup_object_result(url : String, object : JsonMap, options : LookupObjectOptions) : JsonMap?
      return object if same_origin?(url, object)

      case options.cross_origin
      when "trust"
        object
      when "throw", "raise"
        raise ArgumentError.new("looked up object id has a different origin")
      else
        nil
      end
    end

    def self.lookup_nodeinfo(origin : String, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      Aptok.lookup_nodeinfo(origin, loader, options)
    end

    def self.lookup_nodeinfo(origin : URI, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      Aptok.lookup_nodeinfo(origin, loader, options)
    end

    def self.lookup_nodeinfo(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      Aptok.lookup_nodeinfo(origin, options)
    end

    def self.lookup_nodeinfo(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
      Aptok.lookup_nodeinfo(origin, options)
    end

    def self.lookup_nodeinfo_document(origin : String, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      Aptok.lookup_nodeinfo_document(origin, loader, options)
    end

    def self.lookup_nodeinfo_document(origin : URI, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      Aptok.lookup_nodeinfo_document(origin, loader, options)
    end

    def self.lookup_nodeinfo_document(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      Aptok.lookup_nodeinfo_document(origin, options)
    end

    def self.lookup_nodeinfo_document(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
      Aptok.lookup_nodeinfo_document(origin, options)
    end

    def self.lookup_webfinger(resource : String, loader : DocumentLoader) : JsonMap?
      query_resource, host = webfinger_resource_and_host(resource)
      return nil unless query_resource && host

      url = "https://#{host}/.well-known/webfinger?resource=#{URI.encode_www_form(query_resource)}"
      loader.call(url)
    end

    def self.lookup_webfinger(resource : URI, loader : DocumentLoader) : JsonMap?
      lookup_webfinger(resource.to_s, loader)
    end

    def self.lookup_webfinger(resource : String, options : LookupWebFingerOptions = LookupWebFingerOptions.new) : JsonMap?
      loader = options.document_loader || default_document_loader(allow_private_address: options.allow_private_address, user_agent: options.user_agent)
      lookup_webfinger(resource, loader)
    end

    def self.lookup_webfinger(resource : URI, options : LookupWebFingerOptions = LookupWebFingerOptions.new) : JsonMap?
      lookup_webfinger(resource.to_s, options)
    end

    def self.get_actor_handle(actor : JsonMap, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
      actor_id = actor["id"]?.try(&.as_s?) || actor["@id"]?.try(&.as_s?)
      if actor_id
        if handle = actor_handle_from_webfinger(actor_id, loader, options)
          return handle
        end
      end

      username = actor["preferredUsername"]?.try(&.as_s?)
      if actor_id && username && !username.empty?
        return normalize_actor_handle("@#{username}@#{actor_host(actor_id)}", options)
      end

      raise ArgumentError.new("actor handle not found")
    end
  end
end
