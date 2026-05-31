module Aptok
  class Federation
    def self.collection_synchronization_header(collection_id : String, actor_ids : Iterable(String)) : String?
      ids = actor_ids.to_a
      return nil if ids.empty?

      collection_uri = URI.parse(collection_id)
      base_url = synchronization_base_url(ids.first)
      query = URI::Params.parse(collection_uri.query || "")
      query["base-url"] = base_url
      collection_uri.query = query.to_s
      digest = collection_digest(ids).hexstring
      %(collectionId="#{collection_id}", url="#{collection_uri}", digest="#{digest}")
    end

    private def self.synchronization_base_url(actor_id : String) : String
      uri = URI.parse(actor_id)
      raise ArgumentError.new("actor id must include an absolute URI origin") unless uri.scheme && uri.host

      port = uri.port
      origin = "#{uri.scheme}://#{uri.host}"
      origin += ":#{port}" if port && !(uri.scheme == "http" && port == 80) && !(uri.scheme == "https" && port == 443)
      "#{origin}/"
    end

    private def notify_undelivered_outbox_activity(ctx : Context, activity : JsonMap) : Nil
      if listener = @undelivered_outbox_activity_listener
        listener.call(ctx, activity)
      else
        activity_id = activity["id"]?.try(&.as_s?) || "(missing id)"
        Log.for("aptok.federation.outbox").warn do
          "outbox listener returned without delivering activity #{activity_id}; call Context#send_activity or Context#forward_activity to federate it"
        end
      end
    end

    private def handle_inbox_listener_error(ctx : Context, error : Exception) : Nil
      if handler = @inbox_error_handler
        handler.call(ctx, error)
      elsif handler = @error_handler
        handler.call(ctx, error)
      else
        raise error
      end
    end

    private def handle_outbox_listener_error(ctx : Context, error : Exception) : Nil
      if handler = @outbox_listener_error_handler
        handler.call(ctx, error)
      elsif handler = @error_handler
        handler.call(ctx, error)
      else
        raise error
      end
    end

    private def notify_error_handler(kind : String, handler : Proc(Context, Exception, Nil)?, ctx : Context, error : Exception) : Nil
      callback = handler || @error_handler
      return unless callback

      callback.call(ctx, error)
    rescue callback_error
      Log.for("aptok.federation.#{kind}").error(exception: callback_error) do
        "unexpected error in #{kind} error handler"
      end
    end

    private def matching_listeners(registry : Hash(String, Array(T)), activity : JsonMap) : Array(T) forall T
      listeners = [] of T
      activity_type_names(activity).each do |type|
        Aptok.type_lineage(type).each do |ancestor|
          registry[ancestor]?.try { |typed| listeners.concat(typed) }
        end
      end
      registry["Activity"]?.try { |activity_listeners| listeners.concat(activity_listeners) }
      registry["*"]?.try { |any_listeners| listeners.concat(any_listeners) }
      listeners.uniq
    end

    private def activity_type_names(activity : JsonMap) : Array(String)
      type = activity["type"]?
      return [] of String unless type

      if name = type.as_s?
        [listener_type_name(name)]
      elsif names = type.as_a?
        names.compact_map(&.as_s?).map { |name| listener_type_name(name) }.uniq
      else
        [] of String
      end
    end

    private def listener_type_name(type : String) : String
      return type if type == "*" || type == "Activity"

      Aptok.type_name(type)
    end

    private def telemetry_attributes(values : Hash(String, String)) : TelemetryAttributes
      attrs = TelemetryAttributes.new
      values.each { |key, value| attrs[key] = value }
      attrs
    end
  end
end
