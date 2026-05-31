module Aptok
  class Context
    def forward_activity(
      forwarder_identifier : String,
      actor : JsonMap,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      forward_activity(forwarder_identifier, recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      actor : JsonMap,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], actor, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      actor : JsonMap,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), actor, activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      forward_activity(forwarder_identifier, recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], actors, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), actors, activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      actors : Array(JsonMap),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      forward_activity(forwarder_identifier, recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], actors, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), actors, activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      recipient : Recipient,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], [recipient], activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      recipient : Recipient,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder_key_pairs, [recipient], activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      actor : Vocab::Actor,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], actor, activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      forward_activity(forwarder_key_pairs, recipients, activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      actor : JsonMap,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], actor, activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      actor : JsonMap,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      forward_activity(forwarder_key_pairs, recipients, activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], recipients, activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], actors, activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      forward_activity(forwarder_key_pairs, recipients, activity, options)
    end

    def forward_activity(
      forwarder_key_pair : ActorKeyPair,
      actors : Array(JsonMap),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity([forwarder_key_pair], actors, activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipients = actors.compact_map { |actor| Aptok.recipient_from_actor(actor, options.prefer_shared_inbox) }
      forward_activity(forwarder_key_pairs, recipients, activity, options)
    end

    def forward_activity(
      forwarder_key_pairs : Array(ActorKeyPair),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      raise ArgumentError.new("forwarder key pairs must not be empty") if forwarder_key_pairs.empty?
      return [] of SentActivity if options.skip_if_unsigned && !forwardable_signature?(activity)

      source_request = @inbound_request
      payload = source_request.try(&.body) || activity.to_json
      source_headers = source_request.try(&.headers) || Hash(String, String).new
      actor = forwarder_key_pairs.first.owner
      forwarder_identifier = identifier_from_actor_uri(actor)
      signing_key_pair = first_rsa_key_pair(forwarder_key_pairs)
      sent = [] of SentActivity
      queue = @federation.outbox_queue
      queued = 0

      recipients.each do |recipient|
        next if excluded_recipient?(recipient, options.exclude_base_uris)
        next if excluded_forward_recipient?(recipient, forwarder_identifier, activity, options)
        delivery = DeliveryConfig.new(
          inbox: recipient.inbox,
          actor: actor,
          target: recipient.id,
          actor_ids: recipient.synchronization_actor_ids
        )
        if queue && !options.immediate
          queue.enqueue(
            @federation.outbox_queue_name,
            @federation.forwarded_delivery_payload(forwarder_identifier, delivery, activity, payload, source_headers, forwarder_key_pairs),
            EnqueueOptions.new(ordering_key: options.ordering_key)
          )
          queued += 1
          next
        end

        activity_id = @transport.forward!(delivery, activity, payload, source_headers, signing_key_pair)
        record = @federation.record_sent(SentActivity.new(forwarder_identifier, recipient, activity_id, activity, false, nil, 0, payload))
        sent << record
      end

      if queue && !options.immediate && queued > 0
        @federation.auto_start_queue(@data)
        mark_activity_delivered
      else
        mark_activity_delivered unless sent.empty?
      end
      sent
    end

    def enqueue_activity(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : EnqueueOptions = EnqueueOptions.new,
      collection_name : String? = nil,
      sync_collection : Bool = false
    ) : Array(QueuedActivity)
      queue = @federation.outbox_queue
      raise ArgumentError.new("outbox queue is not configured") unless queue

      sender = get_actor_uri(sender_identifier)
      transformed_activity = transformed_outbound_activity(sender_identifier, recipients, activity, collection_name)
      require_sendable_activity!(transformed_activity)
      signed_activity = activity_with_object_proofs(sender_identifier, transformed_activity)
      queued = [] of QueuedActivity
      payloads = [] of JsonMap

      recipients.each do |recipient|
        delivery = DeliveryConfig.new(
          inbox: recipient.inbox,
          actor: sender,
          target: recipient.id,
          headers: delivery_headers_for_recipient(sender_identifier, collection_name, recipient, sync_collection),
          actor_ids: recipient.synchronization_actor_ids
        )
        activity_id = signed_activity["id"]?.try(&.as_s?) || ""
        payload = @federation.outbound_delivery_payload(delivery, signed_activity)
        payloads << payload
        queued << QueuedActivity.new(sender_identifier, recipient, activity_id, signed_activity)
      end

      if options.ordering_key
        payloads.each { |payload| queue.enqueue(@federation.outbox_queue_name, payload, options) }
      else
        queue.enqueue_many(@federation.outbox_queue_name, payloads, options)
      end
      @federation.auto_start_queue(@data) unless payloads.empty?

      queued
    end
  end
end
