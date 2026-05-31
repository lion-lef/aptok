module Aptok
  class Context
    def send_activity(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(SentActivity)
      sender = get_actor_uri(sender_identifier)
      signing_key_pair = first_rsa_key_pair(sender_identifier)
      transformed_activity = transformed_outbound_activity(sender_identifier, recipients, activity, collection_name)
      require_sendable_activity!(transformed_activity)
      signed_activity = activity_with_object_proofs(sender_identifier, transformed_activity)
      sent = [] of SentActivity

      recipients.each do |recipient|
        delivery = DeliveryConfig.new(
          inbox: recipient.inbox,
          actor: sender,
          target: recipient.id,
          headers: delivery_headers_for_recipient(sender_identifier, collection_name, recipient, sync_collection),
          actor_ids: recipient.synchronization_actor_ids
        )
        activity_id = @federation.telemetry.span("aptok.outbox.deliver", telemetry_attributes({"inbox" => delivery.inbox, "actor" => delivery.actor})) do
          @transport.deliver!(delivery, signed_activity, signing_key_pair)
        end
        record = @federation.record_sent(SentActivity.new(sender_identifier, recipient, activity_id, signed_activity))
        @federation.telemetry.counter("aptok.outbox.deliveries", attributes: telemetry_attributes({"status" => "delivered"}))
        sent << record
      end

      mark_activity_delivered unless sent.empty?
      sent
    end

    def send_activity(
      sender_identifier : String,
      recipient : Recipient,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender_identifier, [recipient], activity, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      recipient : Recipient,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], [recipient], activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      recipient : Recipient,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender_key_pairs, [recipient], activity, options)
    end

    def send_activity(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions
    ) : SendActivityResult
      recipients = direct_recipients_for_delivery(recipients, options)
      send_activity_to_recipients(sender_identifier, recipients, activity, nil, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], recipients, activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = direct_recipients_for_delivery(recipients, options)
      send_activity_with_key_pairs(sender_key_pairs, recipients, activity, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      actor : Vocab::Actor,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], actor, activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      send_activity_with_key_pairs(sender_key_pairs, recipients, activity, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      actor : JsonMap,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], actor, activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      actor : JsonMap,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      send_activity_with_key_pairs(sender_key_pairs, recipients, activity, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], actors, activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      send_activity_with_key_pairs(sender_key_pairs, recipients, activity, options)
    end

    def send_activity(
      sender_key_pair : ActorKeyPair,
      actors : Array(JsonMap),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity([sender_key_pair], actors, activity, options)
    end

    def send_activity(
      sender_key_pairs : Array(ActorKeyPair),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      send_activity_with_key_pairs(sender_key_pairs, recipients, activity, options)
    end

    def send_activity(
      sender_identifier : String,
      actor : Vocab::Actor,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      send_activity_to_recipients(sender_identifier, recipients, activity, nil, options)
    end

    def send_activity(
      sender_identifier : String,
      actor : JsonMap,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      send_activity_to_recipients(sender_identifier, recipients, activity, nil, options)
    end

    def send_activity(
      sender_identifier : String,
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      send_activity_to_recipients(sender_identifier, recipients, activity, nil, options)
    end

    def send_activity(
      sender_identifier : String,
      actors : Array(JsonMap),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      send_activity_to_recipients(sender_identifier, recipients, activity, nil, options)
    end

    def send_activity(
      sender_identifier : String,
      collection_name : String,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      recipients = recipients_from_collection(sender_identifier, collection_name, options)
      send_activity_to_recipients(sender_identifier, recipients, activity, collection_name, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(SentActivity)
      send_activity(sender[:identifier], recipients, activity, collection_name, sync_collection)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(SentActivity)
      send_activity(identifier_from_username(sender[:username]), recipients, activity, collection_name, sync_collection)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      recipient : Recipient,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], recipient, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      recipient : Recipient,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), recipient, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions
    ) : SendActivityResult
      send_activity(sender[:identifier], recipients, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), recipients, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], actor, activity, options)
    end
  end
end
