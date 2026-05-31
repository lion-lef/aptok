module Aptok
  class Context
    private def recipient_from_actor(actor : JsonMap, options : SendActivityOptions) : Recipient?
      Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
    end

    private def require_sendable_activity!(activity : JsonMap) : Nil
      raise ArgumentError.new("The activity to send must have an id") unless activity_object_id(activity)
      raise ArgumentError.new("The activity to send must have at least one actor property") unless activity_actor_id(activity)
    end

    private def validate_send_activity_options!(options : SendActivityOptions) : Nil
      return if {"auto", "skip", "force"}.includes?(options.fanout)

      raise ArgumentError.new(%(fanout must be "auto", "skip", or "force"))
    end

    private def validate_explicit_sender_key_pairs!(key_pairs : Array(ActorKeyPair)) : Nil
      key_pairs.each do |key_pair|
        unless key_pair.private_key_path || key_pair.private_key_pem
          raise ArgumentError.new("sender key pairs must include private key material")
        end

        case key_pair.algorithm.downcase
        when "rsa-sha256"
        when "ed25519"
          raise ArgumentError.new("Ed25519 sender key pairs must include private key PEM") unless key_pair.private_key_pem
        else
          raise ArgumentError.new("unsupported sender key algorithm: #{key_pair.algorithm}")
        end
      end
    end

    private def activity_object_id(activity : JsonMap) : String?
      activity["id"]?.try(&.as_s?) || activity["@id"]?.try(&.as_s?)
    end

    private def activity_actor_id(activity : JsonMap) : String?
      value_id(activity["actor"]?)
    end

    private def value_id(value : JSON::Any?) : String?
      return nil unless value
      if string = value.as_s?
        return string unless string.empty?
        return nil
      end
      if array = value.as_a?
        array.each do |item|
          id = value_id(item)
          return id if id
        end
        return nil
      end
      if object = value.as_h?
        return value_id(object["id"]?)
      end
      nil
    end

    private def should_enqueue_fanout?(recipients : Array(Recipient), options : SendActivityOptions) : Bool
      return false unless @federation.fanout_queue
      case options.fanout
      when "force"
        true
      when "skip"
        false
      else
        recipients.size >= @federation.fanout_threshold
      end
    end

    private def delivery_headers_for_recipient(sender_identifier : String, collection_name : String?, recipient : Recipient, sync_collection : Bool) : Hash(String, String)
      return Hash(String, String).new unless sync_collection && collection_name == "followers"

      header = Federation.collection_synchronization_header(
        get_followers_uri(sender_identifier),
        recipient.synchronization_actor_ids
      )
      header ? {"Collection-Synchronization" => header} : Hash(String, String).new
    end

    private def recipient_from_local_actor_identifier(identifier : String, options : ForwardActivityOptions) : Recipient?
      actor = self.actor(identifier)
      return nil unless actor

      recipient_from_actor(
        actor,
        SendActivityOptions.new(prefer_shared_inbox: options.prefer_shared_inbox)
      )
    end

    private def addressed_local_actor_identifiers(activity : JsonMap, options : ForwardActivityOptions) : Array(String)
      identifiers = [] of String
      seen = Set(String).new
      collect_addressing_values(activity, %w[to cc audience]).each do |iri|
        add_local_actor_identifier(iri, identifiers, seen)
      end
      if options.include_object_addressing
        if object = activity["object"]?.try(&.as_h?)
          collect_addressing_values(object, %w[to cc audience]).each do |iri|
            add_local_actor_identifier(iri, identifiers, seen)
          end
        end
      end
      identifiers
    end

    private def collect_addressing_values(object : JsonMap, fields : Array(String)) : Array(String)
      values = [] of String
      fields.each do |field|
        collect_iri_values(object[field]?, values)
      end
      values
    end

    private def collect_iri_values(value : JSON::Any?, values : Array(String)) : Nil
      return unless value
      if string = value.as_s?
        values << string
      elsif array = value.as_a?
        array.each { |item| collect_iri_values(item, values) }
      elsif object = value.as_h?
        id = object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
        values << id if id
      end
    end

    private def add_local_actor_identifier(iri : String, identifiers : Array(String), seen : Set(String)) : Nil
      return if iri == PUBLIC_COLLECTION

      parsed = parse_uri(iri)
      return unless parsed && parsed.type == "actor"
      identifier = parsed.identifier
      return unless identifier && !seen.includes?(identifier)

      identifiers << identifier
      seen << identifier
    end

    private def excluded_forward_recipient?(
      recipient : Recipient,
      forwarder_identifier : String,
      activity : JsonMap,
      options : ForwardActivityOptions
    ) : Bool
      excluded_ids = Set(String).new(options.exclude_actor_ids)
      excluded_ids << get_actor_uri(forwarder_identifier)
      if actor_id = activity_actor_id(activity)
        excluded_ids << actor_id
      end
      excluded_ids.includes?(recipient.id)
    end

    private def excluded_recipient?(recipient : Recipient, exclude_base_uris : Array(String)) : Bool
      exclude_base_uris.any? do |base|
        normalized = strip_trailing_slash(base)
        same_uri_origin?(recipient.id, normalized) ||
          same_uri_origin?(recipient.inbox, normalized) ||
          recipient.id.starts_with?(normalized) ||
          recipient.inbox.starts_with?(normalized)
      end
    end

    private def activity_actor_id(activity : JsonMap) : String?
      actor_value_id(activity["actor"]?)
    end

    private def actor_value_id(value : JSON::Any?) : String?
      return nil unless value

      if string = value.as_s?
        return string unless string.empty?
      elsif object = value.as_h?
        return actor_value_id(object["id"]?)
      elsif array = value.as_a?
        array.each do |item|
          id = actor_value_id(item)
          return id if id
        end
      end

      nil
    end

    private def same_uri_origin?(left : String, right : String) : Bool
      Aptok.same_resource_origin?(left, right)
    end

    private def telemetry_attributes(values : Hash(String, String)) : TelemetryAttributes
      attrs = TelemetryAttributes.new
      values.each { |key, value| attrs[key] = value }
      attrs
    end
  end
end
