module Aptok
  class Federation
    def transform_activity(ctx : Context, transform_context : ActivityTransformContext, activity : JsonMap) : JsonMap
      @activity_transformers.reduce(activity) do |current, transformer|
        transformer.call(ctx, transform_context, current)
      end
    end

    def dispatch_actor(ctx : Context, identifier : String) : JsonMap?
      actor = @actor_dispatcher.try(&.call(ctx, identifier))
      return nil unless actor

      warn_about_actor_contract(ctx, identifier, actor)
      with_actor_key_material(ctx, identifier, actor)
    end

    def has_actor_dispatcher? : Bool
      !@actor_dispatcher.nil?
    end

    def dispatch_object(ctx : Context, type : String, identifier : String) : JsonMap?
      dispatch_object(ctx, type, {"identifier" => identifier})
    end

    def dispatch_object(ctx : Context, type : String, params : Hash(String, String)) : JsonMap?
      route = @object_routes.find { |candidate| candidate.type == type }
      route ? route.dispatcher.call(ctx, params) : nil
    end

    def has_object_dispatcher?(type : String) : Bool
      @object_routes.any? { |candidate| candidate.type == type }
    end

    def dispatch_outbox(ctx : Context, identifier : String) : Array(JsonMap)
      @outbox_dispatcher.try(&.call(ctx, identifier)) || [] of JsonMap
    end

    def dispatch_collection(ctx : Context, name : String, identifier : String) : Array(JsonMap)
      dispatch_collection(ctx, name, {"identifier" => identifier})
    end

    def dispatch_collection(ctx : Context, name : String, params : Hash(String, String)) : Array(JsonMap)
      route = @collection_routes.find { |candidate| candidate.name == name }
      return [] of JsonMap unless route

      if dispatcher = route.dispatcher
        filter_collection_items(ctx, name, dispatcher.call(ctx, params))
      elsif page_dispatcher = route.page_dispatcher
        items = page_dispatcher.call(ctx, params, nil, 20).try(&.items) || [] of JsonMap
        filter_collection_items(ctx, name, items)
      else
        [] of JsonMap
      end
    end

    def dispatch_collection_for_delivery(ctx : Context, name : String, identifier : String, size : Int32 = 20) : Array(JsonMap)
      route = @collection_routes.find { |candidate| candidate.name == name }
      return [] of JsonMap unless route

      params = {"identifier" => identifier}
      if dispatcher = route.dispatcher
        return dispatcher.call(ctx, params)
      end

      if page_dispatcher = route.page_dispatcher
        if result = page_dispatcher.call(ctx, params, nil, size)
          return result.items
        end
        return collect_collection_pages(ctx, route, params, size)
      end

      if filtered_page_dispatcher = route.filtered_page_dispatcher
        if result = filtered_page_dispatcher.call(ctx, params, nil, size, nil)
          return result.items
        end
        return collect_collection_pages(ctx, route, params, size)
      end

      [] of JsonMap
    end

    def dispatch_outbox_page(ctx : Context, identifier : String, cursor : String?, size : Int32) : CollectionPageResult?
      @outbox_page_dispatcher.try(&.call(ctx, identifier, cursor, size))
    end

    def has_outbox_page_dispatcher? : Bool
      !@outbox_page_dispatcher.nil?
    end

    def has_outbox_dispatcher? : Bool
      !@outbox_dispatcher.nil? || !@outbox_page_dispatcher.nil?
    end

    def has_outbox_listeners? : Bool
      @outbox_path_configured && !@outbox_listeners.empty?
    end

    def has_inbox_listeners? : Bool
      @inbox_path_configured
    end

    def has_collection_dispatcher?(name : String) : Bool
      @collection_routes.any? { |route| route.name == name }
    end

    def has_key_pairs_dispatcher? : Bool
      !@key_pairs_dispatcher.nil?
    end

    def has_nodeinfo_dispatcher? : Bool
      !@nodeinfo_dispatcher.nil?
    end

    def dispatch_webfinger(ctx : Context, resource : String, identifier : String) : JsonMap?
      @webfinger_dispatcher.try(&.call(ctx, resource, identifier))
    end

    def dispatch_webfinger_links(ctx : Context, resource : String) : Array(JsonMap)
      @webfinger_links_dispatcher.try(&.call(ctx, resource)) || [] of JsonMap
    end

    def webfinger_identifier(ctx : Context, username : String) : String?
      if mapper = @handle_mapper
        mapper.call(ctx, username)
      else
        username
      end
    end

    def alias_identifier(ctx : Context, resource : String) : String?
      mapping = @alias_mapper.try(&.call(ctx, resource))
      alias_mapping_identifier(ctx, mapping)
    end

    private def alias_mapping_identifier(ctx : Context, mapping : AliasMapping?) : String?
      case mapping
      in String
        mapping
      in NamedTuple(identifier: String)
        mapping[:identifier]
      in NamedTuple(username: String)
        webfinger_identifier(ctx, mapping[:username])
      in Nil
        nil
      end
    end

    def dispatch_nodeinfo(ctx : Context) : JsonMap
      if dispatcher = @nodeinfo_dispatcher
        dispatcher.call(ctx)
      else
        raise ArgumentError.new("No NodeInfo dispatcher registered")
      end
    end

    def dispatch_key_pairs(ctx : Context, identifier : String) : Array(ActorKeyPair)
      @key_pairs_dispatcher.try(&.call(ctx.with_key_pairs_dispatcher(identifier), identifier)) || [] of ActorKeyPair
    end

    def authorize_actor?(ctx : Context, request : Request, identifier : String?, params : Hash(String, String)) : Bool
      authorize_fetch?(@actor_authorizer, ctx, request, identifier, params)
    end

    def authorize_object?(type : String, ctx : Context, request : Request, identifier : String?, params : Hash(String, String)) : Bool
      authorize_fetch?(@object_authorizers[type]?, ctx, request, identifier, params)
    end

    def authorize_collection?(name : String, ctx : Context, request : Request, identifier : String?, params : Hash(String, String)) : Bool
      authorize_fetch?(@collection_authorizers[name]?, ctx, request, identifier, params)
    end

    def collection_item_type(name : String) : String?
      @collection_item_types[name]?
    end

    def collection_first_cursor(ctx : Context, name : String, params : Hash(String, String)) : String?
      @collection_first_cursor_callbacks[name]?.try(&.call(ctx, params))
    end

    def collection_last_cursor(ctx : Context, name : String, params : Hash(String, String)) : String?
      @collection_last_cursor_callbacks[name]?.try(&.call(ctx, params))
    end

    def collection_count(ctx : Context, name : String, params : Hash(String, String)) : Int32?
      @collection_counter_callbacks[name]?.try(&.call(ctx, params))
    end

    def filter_collection_item?(ctx : Context, name : String, item : JsonMap) : Bool
      predicate = @collection_filter_predicates[name]?
      predicate.nil? || predicate.call(ctx, item)
    end

    def filter_collection_items(ctx : Context, name : String, items : Array(JsonMap)) : Array(JsonMap)
      return items unless @collection_filter_predicates.has_key?(name)

      items.select { |item| filter_collection_item?(ctx, name, item) }
    end

    def route_activity(ctx : Context, activity : JsonMap) : Bool
      route_activity_result(ctx, activity).handled?
    end

    def route_activity_result(ctx : Context, activity : JsonMap) : RouteActivityResult
      unless activity_actor_id(activity)
        @telemetry.counter("aptok.inbox.activities", attributes: telemetry_attributes({"status" => "missing_actor"}))
        return RouteActivityResult::MissingActor
      end
      if processed_activity?(ctx, activity)
        @telemetry.counter("aptok.inbox.activities", attributes: telemetry_attributes({"status" => "duplicate"}))
        return RouteActivityResult::AlreadyProcessed
      end

      listeners = inbox_listeners_for(activity)
      if listeners.empty?
        @telemetry.counter("aptok.inbox.activities", attributes: telemetry_attributes({"status" => "ignored"}))
        return RouteActivityResult::UnsupportedActivity
      end

      failed = false
      @telemetry.span("aptok.inbox.route", telemetry_attributes({"activity.type" => activity_type_names(activity).join(",")})) do
        listeners.each do |listener|
          begin
            listener.call(ctx, activity)
          rescue ex
            failed = true
            @telemetry.counter("aptok.inbox.activities", attributes: telemetry_attributes({"status" => "error"}))
            handle_inbox_listener_error(ctx, ex)
          end
        end
      end
      mark_activity_processed(ctx, activity)
      if failed
        RouteActivityResult::Error
      else
        @telemetry.counter("aptok.inbox.activities", attributes: telemetry_attributes({"status" => "processed"}))
        RouteActivityResult::Success
      end
    end

    def trusted_inbox_activity(ctx : Context, activity : JsonMap) : JsonMap?
      actor_id = activity_actor_id(activity)
      return nil unless actor_id

      if verify_object_proof(activity).verified
        return activity
      end

      activity_id = object_id(activity)
      return activity if activity_id && local_origin_activity?(activity_id, actor_id)
      return nil unless activity_id

      fetched = Remote.lookup_object(
        activity_id,
        ctx.document_loader,
        LookupObjectOptions.new(cross_origin: "trust")
      )
      return nil unless fetched
      fetched_id = object_id(fetched)
      return nil unless fetched_id && Aptok.same_resource_id?(fetched_id, activity_id)

      fetched_actor_id = activity_actor_id(fetched)
      return nil unless fetched_actor_id
      return nil unless same_uri_origin?(activity_id, fetched_actor_id)

      fetched
    end

    def route_outbox_activity(ctx : Context, activity : JsonMap) : Bool
      route_outbox_activity_result(ctx, activity).handled?
    end

    def route_outbox_activity_result(ctx : Context, activity : JsonMap) : RouteOutboxActivityResult
      listeners = outbox_listeners_for(activity)
      if listeners.empty?
        @telemetry.counter("aptok.outbox.activities", attributes: telemetry_attributes({"status" => "ignored"}))
        return RouteOutboxActivityResult::UnsupportedActivity
      end

      failed = false
      ctx.reset_delivered_activity
      @telemetry.span("aptok.outbox.route", telemetry_attributes({"activity.type" => activity_type_names(activity).join(",")})) do
        listeners.each do |listener|
          begin
            listener.call(ctx, activity)
          rescue ex
            failed = true
            @telemetry.counter("aptok.outbox.activities", attributes: telemetry_attributes({"status" => "error"}))
            handle_outbox_listener_error(ctx, ex)
          end
        end
      end
      return RouteOutboxActivityResult::Error if failed

      notify_undelivered_outbox_activity(ctx, activity) unless ctx.has_delivered_activity?
      @telemetry.counter("aptok.outbox.activities", attributes: telemetry_attributes({"status" => "processed"}))
      RouteOutboxActivityResult::Success
    end
  end
end
