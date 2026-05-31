module Aptok
  class Federation
    def outbound_delivery_payload(
      delivery : DeliveryConfig,
      activity : JsonMap,
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : JsonMap
      delivery_payload = JsonMap{
        "inbox" => Aptok.json(delivery.inbox),
        "actor" => Aptok.json(delivery.actor),
      }
      delivery_payload["target"] = Aptok.json(delivery.target) if delivery.target
      delivery_payload["headers"] = Aptok.json(delivery.headers) unless delivery.headers.empty?
      delivery_payload["actorIds"] = Aptok.json(delivery.actor_ids) unless delivery.actor_ids.empty?

      JsonMap{
        "type"     => Aptok.json("OutboundDelivery"),
        "delivery" => Aptok.json(delivery_payload),
        "activity" => Aptok.json(activity),
      }.tap do |payload|
        payload["senderKeyPairs"] = Aptok.json(sender_key_pairs.map { |key_pair| actor_key_pair_payload(key_pair) }) unless sender_key_pairs.empty?
      end
    end

    def fanout_delivery_payload(
      sender_identifier : String,
      recipients : Array(Recipient),
      activity : JsonMap,
      collection_name : String? = nil,
      sync_collection : Bool = false,
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : JsonMap
      JsonMap{
        "type"             => Aptok.json("FanoutDelivery"),
        "senderIdentifier" => Aptok.json(sender_identifier),
        "recipients"       => Aptok.json(recipients.map { |recipient| recipient_payload(recipient) }),
        "activity"         => Aptok.json(activity),
        "syncCollection"   => Aptok.json(sync_collection),
      }.tap do |payload|
        payload["collectionName"] = Aptok.json(collection_name) if collection_name
        payload["senderKeyPairs"] = Aptok.json(sender_key_pairs.map { |key_pair| actor_key_pair_payload(key_pair) }) unless sender_key_pairs.empty?
      end
    end

    def forwarded_delivery_payload(
      forwarder_identifier : String,
      delivery : DeliveryConfig,
      activity : JsonMap,
      payload : String,
      source_headers : Hash(String, String) = Hash(String, String).new,
      sender_key_pairs : Array(ActorKeyPair) = [] of ActorKeyPair
    ) : JsonMap
      delivery_payload = JsonMap{
        "inbox" => Aptok.json(delivery.inbox),
        "actor" => Aptok.json(delivery.actor),
      }
      delivery_payload["target"] = Aptok.json(delivery.target) if delivery.target
      delivery_payload["headers"] = Aptok.json(delivery.headers) unless delivery.headers.empty?
      delivery_payload["actorIds"] = Aptok.json(delivery.actor_ids) unless delivery.actor_ids.empty?

      JsonMap{
        "type"                => Aptok.json("ForwardedDelivery"),
        "forwarderIdentifier" => Aptok.json(forwarder_identifier),
        "delivery"            => Aptok.json(delivery_payload),
        "activity"            => Aptok.json(activity),
        "payload"             => Aptok.json(payload),
        "sourceHeaders"       => Aptok.json(source_headers),
      }.tap do |task_payload|
        task_payload["senderKeyPairs"] = Aptok.json(sender_key_pairs.map { |key_pair| actor_key_pair_payload(key_pair) }) unless sender_key_pairs.empty?
      end
    end

    def inbound_delivery_payload(recipient_identifier : String?, activity : JsonMap, trusted : Bool = false) : JsonMap
      payload = JsonMap{
        "type"     => Aptok.json("InboundDelivery"),
        "activity" => Aptok.json(activity),
      }
      payload["recipientIdentifier"] = Aptok.json(recipient_identifier) if recipient_identifier
      payload["trusted"] = Aptok.json(true) if trusted
      payload
    end

    def enqueue_inbox_activity(
      recipient_identifier : String?,
      activity : JsonMap,
      options : EnqueueOptions = EnqueueOptions.new,
      trusted : Bool = false,
      context_data : JSON::Any? = nil
    ) : Nil
      queue = @inbox_queue
      raise ArgumentError.new("inbox queue is not configured") unless queue
      queue.enqueue(@inbox_queue_name, inbound_delivery_payload(recipient_identifier, activity, trusted), options)
      auto_start_queue(context_data)
    end

    def parse_outbound_delivery(payload : JsonMap) : Tuple(DeliveryConfig, JsonMap)
      delivery_payload = payload["delivery"].as_h
      delivery = DeliveryConfig.new(
        inbox: delivery_payload["inbox"].as_s,
        actor: delivery_payload["actor"].as_s,
        target: delivery_payload["target"]?.try(&.as_s?),
        headers: delivery_payload["headers"]?.try(&.as_h.transform_values(&.as_s)) || Hash(String, String).new,
        actor_ids: delivery_payload["actorIds"]?.try(&.as_a.compact_map(&.as_s?)) || [] of String
      )
      {delivery, payload["activity"].as_h}
    end

    def parse_outbound_delivery_sender_key_pairs(payload : JsonMap) : Array(ActorKeyPair)
      payload["senderKeyPairs"]?.try(&.as_a.compact_map { |key_pair| parse_actor_key_pair_payload(key_pair.as_h) }) || [] of ActorKeyPair
    end

    def parse_forwarded_delivery(payload : JsonMap) : Tuple(String, DeliveryConfig, JsonMap, String, Hash(String, String))
      delivery, activity = parse_outbound_delivery(payload)
      {
        payload["forwarderIdentifier"].as_s,
        delivery,
        activity,
        payload["payload"].as_s,
        payload["sourceHeaders"]?.try(&.as_h.transform_values(&.as_s)) || Hash(String, String).new,
      }
    end

    def parse_forwarded_delivery_sender_key_pairs(payload : JsonMap) : Array(ActorKeyPair)
      parse_outbound_delivery_sender_key_pairs(payload)
    end

    def outbox_failure_context(payload : JsonMap) : Tuple(DeliveryConfig, JsonMap)?
      case payload["type"]?.try(&.as_s?)
      when "OutboundDelivery", "ForwardedDelivery"
        parse_outbound_delivery(payload)
      else
        nil
      end
    end

    private def recipient_payload(recipient : Recipient) : JsonMap
      payload = JsonMap{
        "id"    => Aptok.json(recipient.id),
        "inbox" => Aptok.json(recipient.inbox),
      }
      payload["actorIds"] = Aptok.json(recipient.actor_ids) unless recipient.actor_ids.empty?
      payload
    end

    private def parse_recipient_payload(payload : JsonMap) : Recipient
      Recipient.new(
        payload["id"].as_s,
        payload["inbox"].as_s,
        payload["actorIds"]?.try(&.as_a.compact_map(&.as_s?)) || [] of String
      )
    end

    private def actor_key_pair_payload(key_pair : ActorKeyPair) : JsonMap
      payload = JsonMap{
        "id"           => Aptok.json(key_pair.id),
        "owner"        => Aptok.json(key_pair.owner),
        "publicKeyPem" => Aptok.json(key_pair.public_key_pem),
        "algorithm"    => Aptok.json(key_pair.algorithm),
      }
      payload["privateKeyPath"] = Aptok.json(key_pair.private_key_path) if key_pair.private_key_path
      payload["privateKeyPem"] = Aptok.json(key_pair.private_key_pem) if key_pair.private_key_pem
      payload
    end

    private def parse_actor_key_pair_payload(payload : JsonMap) : ActorKeyPair
      ActorKeyPair.new(
        id: payload["id"].as_s,
        owner: payload["owner"].as_s,
        public_key_pem: payload["publicKeyPem"].as_s,
        private_key_path: payload["privateKeyPath"]?.try(&.as_s?),
        private_key_pem: payload["privateKeyPem"]?.try(&.as_s?),
        algorithm: payload["algorithm"]?.try(&.as_s?) || "rsa-sha256"
      )
    end

    def parse_inbound_delivery(payload : JsonMap) : Tuple(String?, JsonMap, Bool)
      {
        payload["recipientIdentifier"]?.try(&.as_s?),
        payload["activity"].as_h,
        payload["trusted"]?.try(&.as_bool?) || false,
      }
    end

    def parse_fanout_delivery(payload : JsonMap) : Tuple(String, Array(Recipient), JsonMap, String?, Bool)
      {
        payload["senderIdentifier"].as_s,
        payload["recipients"].as_a.map { |recipient| parse_recipient_payload(recipient.as_h) },
        payload["activity"].as_h,
        payload["collectionName"]?.try(&.as_s?),
        payload["syncCollection"]?.try(&.as_bool?) || false,
      }
    end

    def parse_fanout_delivery_sender_key_pairs(payload : JsonMap) : Array(ActorKeyPair)
      parse_outbound_delivery_sender_key_pairs(payload)
    end

    private def collect_collection_pages(ctx : Context, route : CollectionRoute, params : Hash(String, String), size : Int32) : Array(JsonMap)
      cursor = collection_first_cursor(ctx, route.name, params)
      items = [] of JsonMap
      while cursor
        result = if page_dispatcher = route.page_dispatcher
                   page_dispatcher.call(ctx, params, cursor, size)
                 elsif filtered_page_dispatcher = route.filtered_page_dispatcher
                   filtered_page_dispatcher.call(ctx, params, cursor, size, nil)
                 end
        break unless result

        items.concat(result.items)
        cursor = result.next_cursor
      end
      items
    end

    def process_queued_task(payload : JsonMap, context_data : JSON::Any? = nil) : Bool
      create_context(context_data: context_data).process_queued_task(payload)
    end

    private def warn_about_actor_contract(ctx : Context, identifier : String, actor : JsonMap) : Nil
      logger = Log.for("aptok.federation.actor")
      expected_actor_uri = ctx.get_actor_uri(identifier)
      if actor_id = actor["id"]?.try(&.as_s?)
        unless actor_id == expected_actor_uri
          logger.warn do
            "Actor dispatcher returned an actor with an id property that does not match the actor URI. Set the property with Context#get_actor_uri(identifier)."
          end
        end
      else
        logger.warn do
          "Actor dispatcher returned an actor without an id property. Set the property with Context#get_actor_uri(identifier)."
        end
      end

      return if actor["type"]?.try(&.as_s?) == "Tombstone"

      warn_about_actor_collection(logger, actor, "following", ctx.get_following_uri(identifier)) if has_collection_dispatcher?("following")
      warn_about_actor_collection(logger, actor, "followers", ctx.get_followers_uri(identifier)) if has_collection_dispatcher?("followers")
      warn_about_actor_collection(logger, actor, "outbox", ctx.get_outbox_uri(identifier)) if has_outbox_dispatcher?
      warn_about_actor_collection(logger, actor, "liked", ctx.get_liked_uri(identifier)) if has_collection_dispatcher?("liked")
      warn_about_actor_collection(logger, actor, "featured", ctx.get_featured_uri(identifier)) if has_collection_dispatcher?("featured")
      warn_about_actor_collection(logger, actor, "featuredTags", ctx.get_featured_tags_uri(identifier), "featured tags") if has_collection_dispatcher?("featured_tags")
      warn_about_actor_inbox(logger, ctx, identifier, actor) if has_inbox_listeners?
      warn_about_actor_key_pairs(logger, actor) if has_key_pairs_dispatcher?
    end

    private def warn_about_actor_collection(logger : Log, actor : JsonMap, property : String, expected_uri : String, label : String = property) : Nil
      article = label.starts_with?("outbox") ? "an" : "a"
      if value = actor[property]?.try(&.as_s?)
        unless value == expected_uri
          logger.warn do
            "You configured #{article} #{label} collection dispatcher, but the actor's #{property} property does not match the #{label} collection URI. Set the property with Context#get_#{snake_case_method_name(property)}_uri(identifier)."
          end
        end
      else
        property_article = property.starts_with?("outbox") ? "an" : "a"
        logger.warn do
          "You configured #{article} #{label} collection dispatcher, but the actor does not have #{property_article} #{property} property. Set the property with Context#get_#{snake_case_method_name(property)}_uri(identifier)."
        end
      end
    end

    private def warn_about_actor_inbox(logger : Log, ctx : Context, identifier : String, actor : JsonMap) : Nil
      expected_inbox_uri = ctx.get_inbox_uri(identifier)
      if inbox = actor["inbox"]?.try(&.as_s?)
        unless inbox == expected_inbox_uri
          logger.warn do
            "You configured inbox listeners, but the actor's inbox property does not match the inbox URI. Set the property with Context#get_inbox_uri(identifier)."
          end
        end
      else
        logger.warn do
          "You configured inbox listeners, but the actor does not have an inbox property. Set the property with Context#get_inbox_uri(identifier)."
        end
      end

      expected_shared_inbox_uri = ctx.get_inbox_uri
      shared_inbox = actor["endpoints"]?.try(&.as_h?).try { |endpoints| endpoints["sharedInbox"]?.try(&.as_s?) }
      if shared_inbox
        unless shared_inbox == expected_shared_inbox_uri
          logger.warn do
            "You configured inbox listeners, but the actor's endpoints.sharedInbox property does not match the shared inbox URI. Set the property with Context#get_inbox_uri."
          end
        end
      else
        logger.warn do
          "You configured inbox listeners, but the actor does not have a endpoints.sharedInbox property. Set the property with Context#get_inbox_uri."
        end
      end
    end
  end
end
