module Aptok
  module Remote
    def self.activitypub_document_content_type?(value : String?) : Bool
      return false unless value
      content_type = value.downcase
      content_type.includes?("application/activity+json") ||
        (content_type.includes?("application/ld+json") && content_type.includes?("profile=\"https://www.w3.org/ns/activitystreams\"")) ||
        content_type.includes?("application/json")
    end

    def self.webfinger_content_type?(value : String?) : Bool
      return false unless value
      content_type = value.downcase
      content_type.includes?("application/jrd+json") || content_type.includes?("application/json")
    end

    def self.nodeinfo_content_type?(value : String?) : Bool
      return false unless value
      content_type = value.downcase
      content_type.includes?("application/json")
    end

    def self.json_document_content_type?(value : String?) : Bool
      activitypub_document_content_type?(value) ||
        webfinger_content_type?(value) ||
        nodeinfo_content_type?(value)
    end

    private def self.object_url(target : String, loader : DocumentLoader) : String?
      stripped = target.strip

      webfinger = lookup_webfinger(stripped, loader)
      return nil unless webfinger

      links = webfinger["links"]?.try(&.as_a?) || [] of JSON::Any
      self_link = links.find do |link|
        map = link.as_h?
        next false unless map
        rel = map["rel"]?.try(&.as_s?)
        type = map["type"]?.try(&.as_s?)
        rel == "self" && (type.nil? || activitypub_content_type?(type))
      end
      self_link.try(&.as_h["href"]?.try(&.as_s?))
    end

    private def self.http_url?(value : String) : Bool
      value.starts_with?("http://") || value.starts_with?("https://")
    end

    private def self.private_ip_address?(value : String, port : Int32) : Bool
      address = Socket::IPAddress.new(value, port)
      case address.family
      when Socket::Family::INET
        private_ipv4_address?(address.address)
      when Socket::Family::INET6
        private_ipv6_address?(address.address)
      else
        false
      end
    rescue Socket::Error
      false
    end

    private def self.private_ipv4_address?(address : String) : Bool
      parts = address.split(".").map(&.to_i?)
      return false unless parts.size == 4 && parts.all?

      octets = parts.compact
      first = octets[0]
      second = octets[1]

      first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && 64 <= second && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && 16 <= second && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 198 && (second == 18 || second == 19)) ||
        first >= 224
    end

    private def self.private_ipv6_address?(address : String) : Bool
      normalized = address.downcase
      first = normalized.split(":").first?

      normalized == "::1" ||
        normalized == "::" ||
        normalized.starts_with?("::ffff:127.") ||
        normalized.starts_with?("::ffff:10.") ||
        normalized.starts_with?("::ffff:192.168.") ||
        (first == "fc00" || first == "fd00") ||
        (first.try { |part| part.starts_with?("fc") || part.starts_with?("fd") } || false) ||
        (first.try { |part| part.starts_with?("fe8") || part.starts_with?("fe9") || part.starts_with?("fea") || part.starts_with?("feb") } || false)
    end

    private def self.actor_handle_from_webfinger(actor_id : String, loader : DocumentLoader, options : ActorHandleOptions) : String?
      actor_uri = URI.parse(actor_id)
      return nil unless actor_uri.scheme && actor_uri.host

      webfinger = lookup_webfinger(actor_id, loader)
      return nil unless webfinger

      aliases = [] of String
      if subject = webfinger["subject"]?.try(&.as_s?)
        aliases << subject
      end
      webfinger["aliases"]?.try(&.as_a?).try do |items|
        items.each do |item|
          alias_value = item.as_s?
          aliases << alias_value if alias_value
        end
      end

      aliases.each do |alias_value|
        next unless alias_value.starts_with?("acct:")
        handle = alias_value[5..]
        parts = handle.split("@", 2)
        next unless parts.size == 2 && !parts[0].empty? && !parts[1].empty?
        next unless same_actor_handle_origin?(actor_uri, parts[1]) || verified_cross_origin_actor_handle?(actor_id, alias_value, loader)

        return normalize_actor_handle("@#{parts[0]}@#{parts[1]}", options)
      end

      nil
    rescue URI::Error
      nil
    end

    private def self.verified_cross_origin_actor_handle?(actor_id : String, acct_alias : String, loader : DocumentLoader) : Bool
      webfinger = lookup_webfinger(acct_alias, loader)
      return false unless webfinger

      webfinger["aliases"]?.try(&.as_a?).try do |aliases|
        aliases.each do |alias_value|
          return true if alias_value.as_s? == actor_id
        end
      end
      false
    end

    private def self.same_actor_handle_origin?(actor_uri : URI, handle_host : String) : Bool
      handle_uri = URI.parse("https://#{handle_host}/")
      handle_uri.host == actor_uri.host
    rescue URI::Error
      false
    end

    private def self.actor_host(actor_id : String) : String
      uri = URI.parse(actor_id)
      host = uri.host.to_s
      port = uri.port
      if port && !((uri.scheme == "http" && port == 80) || (uri.scheme == "https" && port == 443))
        host = "#{host}:#{port}"
      end
      host
    end

    private def self.webfinger_resource_and_host(resource : String) : Tuple(String?, String?)
      stripped = resource.strip
      if stripped.starts_with?("http://") || stripped.starts_with?("https://")
        uri = URI.parse(stripped)
        return {stripped, actor_host(stripped)} if uri.scheme && uri.host

        return {nil, nil}
      end

      if stripped.starts_with?("mailto:")
        uri = URI.parse(stripped)
        host = host_from_opaque_resource_path(uri.path)
        return {stripped, host} if host

        return {nil, nil}
      end

      if stripped.starts_with?("acct:")
        uri = URI.parse(stripped)
        return {nil, nil} unless uri.query.nil? && uri.fragment.nil?

        path = uri.path
        return {nil, nil} if path.includes?("/")

        host = host_from_opaque_resource_path(path)
        return {stripped, host} if host

        return {nil, nil}
      end

      handle = stripped
      handle = handle[1..] if handle.starts_with?("@")
      parts = handle.split("@", 2)
      return {nil, nil} unless parts.size == 2 && !parts[0].empty? && !parts[1].empty?

      {"acct:#{parts[0]}@#{parts[1]}", parts[1]}
    rescue URI::Error
      {nil, nil}
    end

    private def self.host_from_opaque_resource_path(path : String) : String?
      at_index = path.rindex('@')
      return nil unless at_index

      host = path[(at_index + 1)..]?
      return nil unless host && !host.empty? && !host.includes?("/") && !host.includes?("?") && !host.includes?("#")

      host
    end

    private def self.document_cache_key(prefix : String, url : String) : String
      "#{prefix}:#{Digest::SHA256.hexdigest(url)}"
    end

    private def self.remote_document_cache_value(document : RemoteDocument) : String
      Aptok.json({
        "url"         => document.url,
        "contentType" => document.content_type,
        "status"      => document.status,
        "headers"     => document.headers,
        "json"        => document.json,
      }).to_json
    end

    private def self.remote_document_from_cache(value : String) : RemoteDocument?
      data = JSON.parse(value).as_h
      headers = Hash(String, String).new
      data["headers"]?.try(&.as_h?).try do |map|
        map.each { |key, header_value| headers[key] = header_value.as_s }
      end

      RemoteDocument.new(
        url: data["url"].as_s,
        content_type: data["contentType"]?.try(&.as_s?),
        status: data["status"].as_i,
        headers: headers,
        json: data["json"].as_h
      )
    rescue
      nil
    end

    private def self.proof_key_from_document(verification_method : String, document : JsonMap, loader : DocumentLoader, visited : Set(String)) : ActorKeyPair?
      return key_pair_from_multikey(document, verification_method, document["controller"]?.try(&.as_s?)) if multikey_document?(document, verification_method)

      assertion_methods = document["assertionMethod"]? || document["assertionMethods"]?
      owner = document["id"]?.try(&.as_s?) || document["@id"]?.try(&.as_s?)
      return nil unless assertion_methods && owner

      assertion_methods_from_json(assertion_methods).each do |method|
        if method.as_s?
          next unless method.as_s == verification_method
          next_url = document_url(method.as_s)
          next if visited.includes?(next_url)
          visited << next_url
          loaded = loader.call(next_url)
          next unless loaded
          key = proof_key_from_document(verification_method, loaded, loader, visited)
          return key if key
        elsif map = method.as_h?
          key = key_pair_from_multikey(map, verification_method, owner)
          return key if key
        end
      end
      nil
    end

    private def self.assertion_methods_from_json(value : JSON::Any) : Array(JSON::Any)
      if list = value.as_a?
        list
      else
        [value]
      end
    end

    private def self.multikey_document?(document : JsonMap, verification_method : String) : Bool
      key_id = document["id"]?.try(&.as_s?) || document["@id"]?.try(&.as_s?)
      key_id == verification_method && !!document["publicKeyMultibase"]?
    end
  end
end
