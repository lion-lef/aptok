module Aptok
  class Context
    private def forwardable_signature?(activity : JsonMap) : Bool
      !!activity["proof"]? || !!activity["signature"]? || !!@inbound_request.try(&.headers["Signature"]?)
    end

    private def process_outbound_delivery(
      delivery : DeliveryConfig,
      activity : JsonMap,
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : SentActivity
      sender_identifier = identifier_from_actor_uri(delivery.actor)
      signing_key_pair = sender_key_pairs.empty? ? first_rsa_key_pair(sender_identifier) : first_rsa_key_pair(sender_key_pairs)
      activity_id = @federation.telemetry.span("aptok.outbox.deliver", telemetry_attributes({"inbox" => delivery.inbox, "actor" => delivery.actor})) do
        @transport.deliver!(delivery, activity, signing_key_pair)
      end
      recipient = Recipient.new(delivery.target || delivery.inbox, delivery.inbox, delivery.actor_ids)
      record = @federation.record_sent(SentActivity.new(sender_identifier, recipient, activity_id, activity, true, "outbox"))
      @federation.telemetry.counter("aptok.outbox.deliveries", attributes: telemetry_attributes({"status" => "delivered"}))
      record
    end

    private def process_forwarded_delivery(
      forwarder_identifier : String,
      delivery : DeliveryConfig,
      activity : JsonMap,
      payload : String,
      source_headers : Hash(String, String),
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : SentActivity
      signing_key_pair = sender_key_pairs.empty? ? first_rsa_key_pair(forwarder_identifier) : first_rsa_key_pair(sender_key_pairs)
      activity_id = @federation.telemetry.span("aptok.outbox.forward", telemetry_attributes({"inbox" => delivery.inbox, "actor" => delivery.actor})) do
        @transport.forward!(delivery, activity, payload, source_headers, signing_key_pair)
      end
      recipient = Recipient.new(delivery.target || delivery.inbox, delivery.inbox, delivery.actor_ids)
      record = @federation.record_sent(SentActivity.new(forwarder_identifier, recipient, activity_id, activity, true, "outbox", 0, payload))
      @federation.telemetry.counter("aptok.outbox.forwarded", attributes: telemetry_attributes({"status" => "delivered"}))
      record
    end

    private def uri_from_template(template : String, identifier : String) : String
      "#{resource_base_uri}#{RouteTemplate.new(template).expand({"identifier" => identifier})}"
    end

    private def string_params(params : NamedTuple) : Hash(String, String)
      values = {} of String => String
      params.each do |key, value|
        values[key.to_s] = value.to_s
      end
      values
    end

    private def strip_trailing_slash(value : String) : String
      value.ends_with?("/") ? value[0, value.size - 1] : value
    end

    private def parsed_origin : URI
      URI.parse(@origin)
    end

    private def authority_from_uri(uri : URI) : String
      authority = uri.host.to_s
      port = uri.port
      if port && !((uri.scheme == "http" && port == 80) || (uri.scheme == "https" && port == 443))
        authority = "#{authority}:#{port}"
      end
      authority
    end

    private def identifier_from_actor_uri(actor_uri : String) : String
      actor_uri.split("/").last? || actor_uri
    end

    private def identifier_from_username(username : String) : String
      @federation.webfinger_identifier(self, username) || raise ArgumentError.new("No actor found for username #{username.inspect}")
    end

    private def tombstone?(object : JsonMap) : Bool
      object["type"]?.try(&.as_s?) == "Tombstone"
    end

    private def first_rsa_key_pair(identifier : String) : ActorKeyPair?
      get_actor_key_pairs(identifier).find do |key_pair|
        key_pair.algorithm.downcase == "rsa-sha256" && (!!key_pair.private_key_path || !!key_pair.private_key_pem)
      end
    end

    private def first_rsa_key_pair(key_pairs : Array(ActorKeyPair)) : ActorKeyPair?
      key_pairs.find do |key_pair|
        key_pair.algorithm.downcase == "rsa-sha256" && (!!key_pair.private_key_path || !!key_pair.private_key_pem)
      end
    end

    private def transformed_outbound_activity(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String? = nil
    ) : JsonMap
      transform_context = ActivityTransformContext.new(
        sender_identifier: sender_identifier,
        sender_actor: get_actor_uri(sender_identifier),
        recipients: recipients,
        collection_name: collection_name
      )
      @federation.transform_activity(self, transform_context, Aptok.json(activity).as_h)
    end

    private def activity_with_object_proofs(sender_identifier : String, activity : JsonMap) : JsonMap
      keys = ed25519_signing_key_pairs(sender_identifier)
      activity_with_object_proofs(keys, activity)
    end

    private def activity_with_object_proofs(keys : Array(ActorKeyPair), activity : JsonMap) : JsonMap
      return activity if keys.empty?
      return activity if Signatures.object_proofs(activity).any? do |proof|
                           keys.any? { |key_pair| proof["verificationMethod"]?.try(&.as_s?) == key_pair.id }
                         end

      signed = activity.dup
      existing_proofs = Signatures.object_proofs(activity)
      added_proofs = keys.map do |key_pair|
        Signatures.create_object_proof(signed, key_pair)
      end
      proofs = existing_proofs + added_proofs
      signed["proof"] = proofs.size == 1 ? Aptok.json(proofs.first) : Aptok.json(proofs)
      signed
    end

    private def ed25519_signing_key_pairs(identifier : String) : Array(ActorKeyPair)
      get_actor_key_pairs(identifier).select do |key_pair|
        key_pair.algorithm.downcase == "ed25519" && !!key_pair.private_key_pem
      end
    end

    private def recipients_from_collection(
      sender_identifier : String,
      collection_name : String,
      options : SendActivityOptions
    ) : Array(Recipient)
      objects = collection_name == "followers" ? @federation.dispatch_collection_for_delivery(self, "followers", sender_identifier) : collection(collection_name, sender_identifier)
      recipients_by_inbox = Hash(String, Recipient).new

      objects.each do |object|
        recipient = recipient_from_actor(object, options)
        next unless recipient
        next if excluded_recipient?(recipient, options.exclude_base_uris)

        if existing = recipients_by_inbox[recipient.inbox]?
          actor_ids = (existing.synchronization_actor_ids + recipient.synchronization_actor_ids).uniq
          recipients_by_inbox[recipient.inbox] = Recipient.new(existing.id, existing.inbox, actor_ids, existing.shared_inbox || recipient.shared_inbox)
        else
          recipients_by_inbox[recipient.inbox] = recipient
        end
      end

      recipients_by_inbox.values
    end

    private def direct_recipients_for_delivery(recipients : Array(Recipient), options : SendActivityOptions) : Array(Recipient)
      inboxes = Aptok.extract_inboxes(recipients, options.prefer_shared_inbox, options.exclude_base_uris)
      inboxes.map do |inbox, extracted|
        Recipient.new(extracted.actor_ids.first, inbox, extracted.actor_ids, extracted.shared_inbox ? inbox : nil)
      end
    end

    private def send_activity_to_recipients(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String?,
      options : SendActivityOptions
    ) : SendActivityResult
      validate_send_activity_options!(options)

      if @federation.outbox_queue && !options.immediate
        if should_enqueue_fanout?(recipients, options)
          enqueue_fanout_activity(
            sender_identifier,
            recipients,
            activity,
            EnqueueOptions.new(ordering_key: options.ordering_key),
            collection_name,
            options.sync_collection
          )
          mark_activity_delivered unless recipients.empty?
          return SendActivityResult.new(fanout_queued: true)
        end

        queued = enqueue_activity(
          sender_identifier,
          recipients,
          activity,
          EnqueueOptions.new(ordering_key: options.ordering_key),
          collection_name,
          options.sync_collection
        )
        mark_activity_delivered unless queued.empty?
        return SendActivityResult.new(queued: queued)
      end

      SendActivityResult.new(sent: send_activity(sender_identifier, recipients, activity, collection_name, options.sync_collection))
    end

    private def send_activity_with_key_pairs(
      sender_key_pairs : Array(ActorKeyPair),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : SendActivityOptions
    ) : SendActivityResult
      validate_send_activity_options!(options)
      raise ArgumentError.new("sender key pairs must not be empty") if sender_key_pairs.empty?
      validate_explicit_sender_key_pairs!(sender_key_pairs)

      signing_key_pair = first_rsa_key_pair(sender_key_pairs)
      initial_sender_actor = activity_actor_id(activity) || sender_key_pairs.first.owner
      sender_identifier = identifier_from_actor_uri(initial_sender_actor)
      transformed_activity = transformed_outbound_activity(sender_identifier, recipients, activity)
      sender_actor = activity_actor_id(transformed_activity)
      require_sendable_activity!(transformed_activity)
      sender_actor = activity_actor_id(transformed_activity).not_nil!
      sender_identifier = identifier_from_actor_uri(sender_actor)
      signed_activity = activity_with_object_proofs(sender_key_pairs, transformed_activity)
      if queue = @federation.outbox_queue
        unless options.immediate
          if should_enqueue_fanout?(recipients, options)
            enqueue_fanout_activity(
              sender_identifier,
              recipients,
              signed_activity,
              EnqueueOptions.new(ordering_key: options.ordering_key),
              nil,
              false,
              sender_key_pairs
            )
            mark_activity_delivered unless recipients.empty?
            return SendActivityResult.new(fanout_queued: true)
          end

          queued = enqueue_signed_activity_with_key_pairs(
            sender_identifier,
            sender_actor,
            sender_key_pairs,
            recipients,
            signed_activity,
            EnqueueOptions.new(ordering_key: options.ordering_key)
          )
          mark_activity_delivered unless queued.empty?
          return SendActivityResult.new(queued: queued)
        end
      end

      sent = [] of SentActivity

      recipients.each do |recipient|
        delivery = DeliveryConfig.new(
          inbox: recipient.inbox,
          actor: sender_actor,
          target: recipient.id,
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
      SendActivityResult.new(sent: sent)
    end

    private def enqueue_signed_activity_with_key_pairs(
      sender_identifier : String,
      sender_actor : String,
      sender_key_pairs : Array(ActorKeyPair),
      recipients : Array(Recipient),
      signed_activity : JsonMap,
      enqueue_options : EnqueueOptions = EnqueueOptions.new,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(QueuedActivity)
      queue = @federation.outbox_queue
      raise ArgumentError.new("outbox queue is not configured") unless queue

      queued = [] of QueuedActivity
      payloads = [] of JsonMap
      recipients.each do |recipient|
        delivery = DeliveryConfig.new(
          inbox: recipient.inbox,
          actor: sender_actor,
          target: recipient.id,
          headers: delivery_headers_for_recipient(sender_identifier, collection_name, recipient, sync_collection),
          actor_ids: recipient.synchronization_actor_ids
        )
        activity_id = signed_activity["id"]?.try(&.as_s?) || ""
        payloads << @federation.outbound_delivery_payload(delivery, signed_activity, sender_key_pairs)
        queued << QueuedActivity.new(sender_identifier, recipient, activity_id, signed_activity)
      end

      if enqueue_options.ordering_key
        payloads.each { |payload| queue.enqueue(@federation.outbox_queue_name, payload, enqueue_options) }
      else
        queue.enqueue_many(@federation.outbox_queue_name, payloads, enqueue_options)
      end
      @federation.auto_start_queue(@data) unless queued.empty?

      queued
    end
  end
end
