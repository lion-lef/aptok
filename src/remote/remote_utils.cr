module Aptok
  module Remote
    private def self.key_pair_from_multikey(document : JsonMap, verification_method : String, owner : String?) : ActorKeyPair?
      key_id = document["id"]?.try(&.as_s?) || document["@id"]?.try(&.as_s?)
      return nil unless key_id == verification_method
      public_key_multibase = document["publicKeyMultibase"]?.try(&.as_s?)
      return nil unless public_key_multibase
      public_key_pem = Signatures.ed25519_public_key_pem_from_multibase(public_key_multibase)
      return nil unless public_key_pem
      resolved_key_id = key_id.not_nil!

      ActorKeyPair.new(
        id: resolved_key_id,
        owner: document["controller"]?.try(&.as_s?) || owner || document_url(resolved_key_id),
        public_key_pem: public_key_pem,
        algorithm: "ed25519"
      )
    end

    private def self.cached_proof_key(verification_method : String, cache : KvStore?) : ActorKeyPair?
      return nil unless cache
      cached = cache.get(proof_key_cache_key(verification_method))
      return nil unless cached

      data = JSON.parse(cached).as_h
      ActorKeyPair.new(
        id: data["id"].as_s,
        owner: data["owner"].as_s,
        public_key_pem: data["publicKeyPem"].as_s,
        algorithm: data["algorithm"]?.try(&.as_s?) || "ed25519"
      )
    rescue
      nil
    end

    private def self.proof_key_cache_key(verification_method : String) : String
      "aptok:public-key:#{verification_method}"
    end

    private def self.proof_key_cache_value(key_pair : ActorKeyPair) : String
      Aptok.json({
        "id"           => key_pair.id,
        "owner"        => key_pair.owner,
        "publicKeyPem" => key_pair.public_key_pem,
        "algorithm"    => key_pair.algorithm,
      }).to_json
    end

    private def self.document_url(url : String) : String
      url.split("#", 2).first
    end

    private def self.append_collection_items(collection : JsonMap, loader : DocumentLoader, results : Array(JsonMap), options : TraverseCollectionOptions) : Nil
      items = collection["orderedItems"]? || collection["items"]?
      return unless items

      items.as_a.each do |item|
        object = begin
          item.as_h? || lookup_item(item, loader)
        rescue ex
          raise ex unless options.suppress_error
          nil
        end
        results << object if object
        if limit = options.limit
          return if results.size >= limit
        end
      end
    end

    private def self.lookup_item(item : JSON::Any, loader : DocumentLoader) : JsonMap?
      url = item.as_s?
      url ? lookup_object(url, loader, LookupObjectOptions.new(cross_origin: "trust")) : nil
    end

    private def self.collection_link(collection : JsonMap, name : String) : String?
      value = collection[name]?
      return nil unless value
      return value.as_s if value.as_s?
      value.as_h? ? value.as_h["id"]?.try(&.as_s?) : nil
    end

    private def self.same_origin?(requested_url : String, object : JsonMap) : Bool
      object_id = object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
      return true unless object_id

      Aptok.same_resource_id?(requested_url, object_id) || Aptok.same_resource_origin?(requested_url, object_id)
    end

    private def self.activitypub_content_type?(value : String) : Bool
      activitypub_document_content_type?(value)
    end

    private def self.wrap_get_provider(provider : DocumentGetProvider?) : MetadataDocumentGetProvider?
      return nil unless provider

      ->(url : String, headers : HTTP::Headers) : Tuple(Int32, String, HTTP::Headers) do
        response = provider.call(url, headers)
        response_headers = HTTP::Headers{"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE}
        {response[0], response[1], response_headers}
      end
    end

    private def self.header_value(headers : HTTP::Headers, name : String) : String?
      headers[name]? || headers[name.downcase]?
    end

    private def self.headers_hash(headers : HTTP::Headers) : Hash(String, String)
      hash = Hash(String, String).new
      headers.each do |key, values|
        hash[key] = values.join(", ")
      end
      hash
    end

    private def self.object_origin(value : JSON::Any?) : String?
      return nil unless value
      id = if string = value.as_s?
             string
           elsif object = value.as_h?
             object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
           end
      return nil unless id

      Aptok.resource_origin(id)
    end

    private def self.same_id?(expected_id : String, object : JsonMap) : Bool
      actual = object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
      !!actual && Aptok.same_resource_id?(expected_id, actual)
    end
  end

  def self.get_actor_handle(actor : JsonMap, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
    Remote.get_actor_handle(actor, loader, options)
  end

  def self.get_actor_handle(actor : Vocab::Actor, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
    Remote.get_actor_handle(actor, loader, options)
  end

  def self.get_actor_handle(actor_uri : String, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
    Remote.get_actor_handle(actor_uri, loader, options)
  end

  def self.normalize_actor_handle(handle : String, options : ActorHandleOptions = ActorHandleOptions.new) : String
    Remote.normalize_actor_handle(handle, options)
  end
end
