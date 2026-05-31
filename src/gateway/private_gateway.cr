require "digest/sha256"
require "http/client"
require "uri"
require "../federation/federation_types"

module Aptok
  module PrivateGateway
    DEFAULT_DOMAIN = "fed.internal"

    record ResolvedUrl,
      original_url : String,
      fetch_url : String,
      authority : String

    record Config,
      resolver : LocalNameResolver,
      acl : AccessList = AccessList.new,
      cache : KvStore? = nil,
      document_cache_ttl : Time::Span? = Time::Span.new(minutes: 10),
      document_cache_prefix : String = "aptok:private-gateway:document"

    class AccessList
      getter host_suffixes : Array(String)
      getter hostnames : Array(String)
      getter actor_ids : Array(String)
      getter blocked_actor_ids : Array(String)

      def initialize(
        host_suffixes : Array(String) = [DEFAULT_DOMAIN],
        hostnames : Array(String) = [] of String,
        actor_ids : Array(String) = [] of String,
        blocked_actor_ids : Array(String) = [] of String
      )
        @host_suffixes = host_suffixes.map { |host| normalize_suffix(host) }.reject { |host| host.empty? }
        @hostnames = hostnames.map { |host| normalize_host(host) }.reject { |host| host.empty? }
        @actor_ids = actor_ids
        @blocked_actor_ids = blocked_actor_ids
      end

      def allows_url?(url : String) : Bool
        uri = URI.parse(url)
        host = uri.hostname || uri.host
        return false unless host

        allows_host?(host)
      rescue
        false
      end

      def allows_host?(host : String) : Bool
        normalized = normalize_host(host)
        return true if @hostnames.includes?(normalized)

        @host_suffixes.any? do |suffix|
          normalized == suffix || normalized.ends_with?(".#{suffix}")
        end
      end

      def allows_actor?(actor_id : String) : Bool
        return false if @blocked_actor_ids.includes?(actor_id)
        return false unless allows_url?(actor_id)

        @actor_ids.empty? || @actor_ids.includes?(actor_id)
      end

      private def normalize_host(host : String) : String
        host.strip.downcase
      end

      private def normalize_suffix(host : String) : String
        normalized = normalize_host(host)
        normalized = normalized[1..] if normalized.starts_with?(".")
        normalized
      end
    end

    class LocalNameResolver
      getter records : Hash(String, String)
      getter domain : String

      def initialize(
        records : Hash(String, String) = Hash(String, String).new,
        domain : String = DEFAULT_DOMAIN
      )
        @domain = normalize_record_key(domain)
        @records = Hash(String, String).new
        records.each do |host, origin|
          @records[normalize_record_key(host)] = normalize_origin(origin)
        end
      end

      def resolve(url : String) : ResolvedUrl?
        uri = URI.parse(url)
        host = uri.hostname || uri.host
        return nil unless host

        origin = origin_for(host)
        return nil unless origin

        ResolvedUrl.new(
          original_url: url,
          fetch_url: build_fetch_url(origin, uri),
          authority: authority(uri, host)
        )
      rescue
        nil
      end

      def document_get_provider(upstream : MetadataDocumentGetProvider? = nil) : MetadataDocumentGetProvider
        MetadataDocumentGetProvider.new do |url, headers|
          if resolved = resolve(url)
            forwarded_headers = copy_headers(headers)
            forwarded_headers["Host"] = resolved.authority
            forwarded_headers["X-Forwarded-Host"] = resolved.authority
            forwarded_headers["X-Forwarded-Proto"] = URI.parse(url).scheme || "https"
            fetch(resolved.fetch_url, forwarded_headers, upstream)
          else
            fetch(url, headers, upstream)
          end
        end
      end

      private def origin_for(host : String) : String?
        normalized = normalize_record_key(host)
        return @records[normalized]? if @records[normalized]?

        @records.each do |pattern, origin|
          if pattern.starts_with?("*.")
            suffix = pattern[2..]
            return origin if normalized != suffix && normalized.ends_with?(".#{suffix}")
          elsif pattern.starts_with?(".")
            suffix = pattern[1..]
            return origin if normalized == suffix || normalized.ends_with?(".#{suffix}")
          end
        end

        nil
      end

      private def fetch(url : String, headers : HTTP::Headers, upstream : MetadataDocumentGetProvider?) : Tuple(Int32, String, HTTP::Headers)
        return upstream.call(url, headers) if upstream

        response = HTTP::Client.get(url, headers: headers)
        {response.status_code, response.body, response.headers}
      end

      private def copy_headers(headers : HTTP::Headers) : HTTP::Headers
        copy = HTTP::Headers.new
        headers.each do |key, values|
          values.each { |value| copy.add(key, value) }
        end
        copy
      end

      private def build_fetch_url(origin : String, uri : URI) : String
        path = uri.path.empty? ? "/" : uri.path
        String.build do |io|
          io << origin
          io << path
          if query = uri.query
            io << '?' << query
          end
        end
      end

      private def authority(uri : URI, host : String) : String
        port = uri.port
        return host unless port

        "#{host}:#{port}"
      end

      private def normalize_record_key(host : String) : String
        host.strip.downcase
      end

      private def normalize_origin(origin : String) : String
        normalized = origin.strip
        parsed = URI.parse(normalized)
        raise ArgumentError.new("gateway origin must use http or https") unless parsed.scheme.try(&.downcase).in?("http", "https")
        raise ArgumentError.new("gateway origin must include a host") unless parsed.hostname || parsed.host

        normalized.ends_with?("/") ? normalized.rchop("/") : normalized
      end
    end

    class ActorCache
      def initialize(
        @store : KvStore,
        @ttl : Time::Span? = Time::Span.new(minutes: 10),
        @prefix : String = "aptok:private-gateway:actor"
      )
      end

      def get(actor_id : String) : JsonMap?
        cached = @store.get(cache_key(actor_id))
        cached ? JSON.parse(cached).as_h : nil
      rescue
        nil
      end

      def set(actor_id : String, actor : JsonMap) : Nil
        return unless actor_document?(actor)

        @store.set(cache_key(actor_id), actor.to_json, @ttl)
      end

      def delete(actor_id : String) : Nil
        @store.delete(cache_key(actor_id))
      end

      def fetch(
        actor_id : String,
        loader : DocumentLoader,
        options : LookupObjectOptions = LookupObjectOptions.new
      ) : JsonMap?
        if cached = get(actor_id)
          return cached
        end

        actor = Remote.lookup_object(actor_id, loader, options)
        return nil unless actor && actor_document?(actor)

        set(actor_id, actor)
        actor
      rescue
        nil
      end

      private def actor_document?(actor : JsonMap) : Bool
        type = actor["type"]?
        return false unless type

        if string = type.as_s?
          return ACTOR_TYPES.includes?(Aptok.type_name(string))
        end

        type.as_a?.try do |items|
          return items.any? do |item|
            item.as_s?.try { |name| ACTOR_TYPES.includes?(Aptok.type_name(name)) } || false
          end
        end

        false
      end

      private def cache_key(actor_id : String) : String
        "#{@prefix}:#{Digest::SHA256.hexdigest(actor_id)}"
      end
    end

    def self.document_loader(
      config : Config,
      upstream : MetadataDocumentGetProvider? = nil,
      *,
      user_agent : String = DEFAULT_USER_AGENT,
      transient_retries : Int32? = nil,
      accept : String = FEDERATION_JSONLD_CONTENT_TYPE
    ) : DocumentLoader
      provider = config.resolver.document_get_provider(upstream)
      metadata_loader = Remote.document_loader_with_metadata(
        provider,
        allow_private_address: true,
        user_agent: user_agent,
        transient_retries: transient_retries,
        accept: accept
      )
      DocumentLoader.new do |url|
        next nil unless config.acl.allows_url?(url)

        if cache = config.cache
          key = document_cache_key(config.document_cache_prefix, url)
          if cached = cache.get(key)
            next JSON.parse(cached).as_h
          end
          document = metadata_loader.call(url).try(&.json)
          cache.set(key, document.to_json, config.document_cache_ttl) if document
          document
        else
          metadata_loader.call(url).try(&.json)
        end
      rescue
        nil
      end
    end

    def self.signature_key_resolver(
      loader : DocumentLoader,
      acl : AccessList = AccessList.new,
      cache : KvStore? = nil
    ) : SignatureKeyResolver
      SignatureKeyResolver.new do |key_id|
        if actor_key_pair = resolve_actor_public_key(key_id, loader, acl, cache)
          actor_key_pair
        elsif acl.allows_url?(key_id)
          key_pair = Remote.resolve_proof_key(key_id, loader, cache)
          key_pair && acl.allows_actor?(key_pair.owner) ? key_pair : nil
        else
          nil
        end
      end
    end

    def self.authorize_signed_fetch(acl : AccessList = AccessList.new) : AuthorizePredicate
      AuthorizePredicate.new do |_ctx, _request, verification, _identifier, _params|
        verification.verified &&
          !!verification.signer_actor.try { |actor_id| acl.allows_actor?(actor_id) }
      end
    end

    private def self.document_cache_key(prefix : String, url : String) : String
      "#{prefix}:#{Digest::SHA256.hexdigest(url)}"
    end

    private def self.resolve_actor_public_key(
      key_id : String,
      loader : DocumentLoader,
      acl : AccessList,
      cache : KvStore?
    ) : ActorKeyPair?
      actor_id = key_id.split("#", 2).first
      return nil unless acl.allows_actor?(actor_id)

      actor = if cache
                ActorCache.new(cache).fetch(actor_id, loader)
              else
                Remote.lookup_object(actor_id, loader)
              end
      return nil unless actor

      public_key_documents(actor["publicKey"]?).each do |key|
        next unless key["id"]?.try(&.as_s?) == key_id

        owner = key["owner"]?.try(&.as_s?) || actor["id"]?.try(&.as_s?)
        public_key_pem = key["publicKeyPem"]?.try(&.as_s?)
        next unless owner && public_key_pem && acl.allows_actor?(owner)

        return ActorKeyPair.new(
          id: key_id,
          owner: owner,
          public_key_pem: public_key_pem,
          algorithm: "rsa-sha256"
        )
      end

      nil
    end

    private def self.public_key_documents(value : JSON::Any?) : Array(JsonMap)
      return [] of JsonMap unless value

      if object = value.as_h?
        [object]
      elsif array = value.as_a?
        array.compact_map(&.as_h?)
      else
        [] of JsonMap
      end
    end
  end
end
