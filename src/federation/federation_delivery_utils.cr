module Aptok
  def self.extract_inboxes(
    recipients : Array(Recipient),
    prefer_shared_inbox : Bool = false,
    exclude_base_uris : Array(String) = [] of String
  ) : Hash(String, ExtractedInbox)
    inboxes = Hash(String, ExtractedInbox).new

    recipients.each do |recipient|
      inbox = recipient.inbox
      shared = false
      if prefer_shared_inbox
        if shared_inbox = recipient.shared_inbox
          unless shared_inbox.empty?
            inbox = shared_inbox
            shared = true
          end
        end
      end

      next if recipient_excluded_from_inbox_extraction?(recipient, inbox, exclude_base_uris)

      actor_ids = recipient.synchronization_actor_ids
      if existing = inboxes[inbox]?
        inboxes[inbox] = ExtractedInbox.new((existing.actor_ids + actor_ids).uniq, existing.shared_inbox || shared)
      else
        inboxes[inbox] = ExtractedInbox.new(actor_ids.uniq, shared)
      end
    end

    inboxes
  end

  def self.recipient_from_actor(actor : Vocab::Actor, prefer_shared_inbox : Bool = false) : Recipient?
    recipient_from_actor(actor.to_json_ld, prefer_shared_inbox)
  end

  def self.recipient_from_actor(actor : JsonMap, prefer_shared_inbox : Bool = false) : Recipient?
    id = actor["id"]?.try(&.as_s?) || actor["@id"]?.try(&.as_s?)
    inbox = actor["inbox"]?.try(&.as_s?)
    return nil unless id && inbox && !id.empty? && !inbox.empty?

    shared_inbox = actor["endpoints"]?.try(&.as_h["sharedInbox"]?.try(&.as_s?))
    delivery_inbox = inbox
    if prefer_shared_inbox && shared_inbox && !shared_inbox.empty?
      delivery_inbox = shared_inbox
    end
    gateways = actor_gateways(actor)
    delivery_inbox = gateway_delivery_uri(delivery_inbox, gateways)
    shared_inbox = gateway_delivery_uri(shared_inbox, gateways) if shared_inbox

    Recipient.new(id, delivery_inbox, [id], shared_inbox)
  end

  private def self.actor_gateways(actor : JsonMap) : Array(String)
    value = actor["gateways"]?
    return [] of String unless value

    entries = value.as_a?
    return [] of String unless entries

    entries.compact_map { |item| item.as_s?.try { |gateway| Aptok.normalize_ap_gateway(gateway) } }
  end

  private def self.gateway_delivery_uri(value : String, gateways : Array(String)) : String
    return value unless Aptok.ap_uri?(value)

    gateway = gateways.first?
    gateway ? Aptok.ap_gateway_url(gateway, value) : value
  rescue
    value
  end

  private def self.recipient_excluded_from_inbox_extraction?(recipient : Recipient, inbox : String, exclude_base_uris : Array(String)) : Bool
    exclude_base_uris.any? do |base|
      same_uri_origin_for_extraction?(recipient.id, base) || same_uri_origin_for_extraction?(inbox, base)
    end
  end

  private def self.same_uri_origin_for_extraction?(left : String, right : String) : Bool
    Aptok.same_resource_origin?(left, right)
  end

  class Federation
    private def strip_trailing_slash(value : String) : String
      value.ends_with?("/") ? value[0, value.size - 1] : value
    end

    private def validate_origin(value : String) : String
      uri = URI.parse(value)
      raise ArgumentError.new("origin must include http or https scheme and host") unless uri.host && uri.scheme.in?("http", "https")
      raise ArgumentError.new("origin must not include a path, query, or fragment") unless uri.path.empty? || uri.path == "/"
      raise ArgumentError.new("origin must not include a path, query, or fragment") if uri.query || uri.fragment

      "#{uri.scheme.not_nil!.downcase}://#{normalized_origin_authority(uri)}"
    end

    private def trailing_slash_mismatch?(template : String, path : String) : Bool
      return false if template == "/" || path == "/"
      template.ends_with?("/") != path.ends_with?("/")
    end

    private def authority_from_origin(origin : String) : String
      uri = URI.parse(origin)
      raise ArgumentError.new("origin must include a host") unless uri.host

      normalized_origin_authority(uri)
    end

    private def normalized_origin_authority(uri : URI) : String
      port = uri.port
      authority = uri.host.to_s
      authority = "#{authority}:#{port}" if port && !((uri.scheme == "http" && port == 80) || (uri.scheme == "https" && port == 443))
      authority.downcase
    end

    private def normalize_handle_host(value : String) : String
      raise ArgumentError.new("handle_host must not be empty") if value.empty?
      raise ArgumentError.new("handle_host must not include a scheme") if value.includes?("://")
      raise ArgumentError.new("handle_host must not include a path") if value.includes?("/")

      uri = URI.parse("https://#{value}/")
      raise ArgumentError.new("handle_host must include a host") unless uri.host
      authority = Aptok.normalize_actor_handle(
        "_@#{uri.host}",
        ActorHandleOptions.new(trim_leading_at: true, punycode: true)
      ).split("@", 2)[1]
      port = uri.port
      authority = "#{authority}:#{port}" if port && port != 443
      authority.downcase
    end
  end
end
