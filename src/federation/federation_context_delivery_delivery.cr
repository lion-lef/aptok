module Aptok
  class Context
    def send_activity(
      sender : NamedTuple(username: String),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), actor, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      actor : JsonMap,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], actor, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      actor : JsonMap,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), actor, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], actors, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      actors : Array(Vocab::Actor),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), actors, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], actors, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      actors : Array(JsonMap),
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), actors, activity, options)
    end

    def send_activity(
      sender : NamedTuple(identifier: String),
      collection_name : String,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(sender[:identifier], collection_name, activity, options)
    end

    def send_activity(
      sender : NamedTuple(username: String),
      collection_name : String,
      activity : JsonMap,
      options : SendActivityOptions = SendActivityOptions.new
    ) : SendActivityResult
      send_activity(identifier_from_username(sender[:username]), collection_name, activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder_identifier, "followers", activity, options)
    end

    def forward_activity(
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      return [] of SentActivity if options.skip_if_unsigned && !forwardable_signature?(activity)

      sent = [] of SentActivity
      seen_inboxes = Set(String).new
      addressed_local_actor_identifiers(activity, options).each do |identifier|
        forward_activity(identifier, "followers", activity, options).each do |record|
          next if seen_inboxes.includes?(record.recipient.inbox)

          sent << record
          seen_inboxes << record.recipient.inbox
        end
      end
      sent
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      collection_name : String,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      return [] of SentActivity if options.skip_if_unsigned && !forwardable_signature?(activity)

      recipients = recipients_from_collection(
        forwarder_identifier,
        collection_name,
        SendActivityOptions.new(
          prefer_shared_inbox: options.prefer_shared_inbox,
          exclude_base_uris: options.exclude_base_uris
        )
      )
      forward_activity(forwarder_identifier, recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      collection_name : String,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], collection_name, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      collection_name : String,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), collection_name, activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      return [] of SentActivity if options.skip_if_unsigned && !forwardable_signature?(activity)

      source_request = @inbound_request
      payload = source_request.try(&.body) || activity.to_json
      source_headers = source_request.try(&.headers) || Hash(String, String).new
      actor = get_actor_uri(forwarder_identifier)
      signing_key_pair = first_rsa_key_pair(forwarder_identifier)
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
            @federation.forwarded_delivery_payload(forwarder_identifier, delivery, activity, payload, source_headers),
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

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      recipient : Recipient,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], [recipient], activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      recipient : Recipient,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), [recipient], activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      recipients : Array(Recipient),
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), recipients, activity, options)
    end

    def forward_activity(
      forwarder_identifier : String,
      actor : Vocab::Actor,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      recipient = Aptok.recipient_from_actor(actor, options.prefer_shared_inbox)
      recipients = recipient ? [recipient] : [] of Recipient
      forward_activity(forwarder_identifier, recipients, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(identifier: String),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(forwarder[:identifier], actor, activity, options)
    end

    def forward_activity(
      forwarder : NamedTuple(username: String),
      actor : Vocab::Actor,
      activity : JsonMap,
      options : ForwardActivityOptions = ForwardActivityOptions.new
    ) : Array(SentActivity)
      forward_activity(identifier_from_username(forwarder[:username]), actor, activity, options)
    end
  end
end
