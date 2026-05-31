module Aptok
  class Federation
    private def snake_case_method_name(property : String) : String
      property == "featuredTags" ? "featured_tags" : property
    end

    private def warn_about_actor_key_pairs(logger : Log, actor : JsonMap) : Nil
      unless actor["publicKey"]?
        logger.warn do
          "You configured a key pairs dispatcher, but the actor does not have a publicKey property. Set the property with Context#get_actor_key_pairs(identifier)."
        end
      end

      unless actor["assertionMethod"]?
        logger.warn do
          "You configured a key pairs dispatcher, but the actor does not have an assertionMethod property. Set the property with Context#get_actor_key_pairs(identifier)."
        end
      end
    end

    private def with_actor_key_material(ctx : Context, identifier : String, actor : JsonMap) : JsonMap
      key_pairs = dispatch_key_pairs(ctx, identifier)
      return actor if key_pairs.empty?

      unless actor["publicKey"]?
        rsa_key = key_pairs.find { |key_pair| key_pair.algorithm.downcase == "rsa-sha256" }
        actor["publicKey"] = Aptok.json(Aptok.public_key(rsa_key)) if rsa_key
      end

      if !actor["assertionMethod"]?
        assertion_methods = key_pairs
          .reject { |key_pair| key_pair.algorithm.downcase == "rsa-sha256" }
          .map { |key_pair| Aptok.public_key(key_pair) }
        actor["assertionMethod"] = Aptok.json(assertion_methods) unless assertion_methods.empty?
      end

      actor
    end

    private def self.dehydrate_actor_value(actor : JSON::Any) : JSON::Any
      if object = actor.as_h?
        object["id"]? || actor
      elsif actors = actor.as_a?
        Aptok.json(actors.map { |item| dehydrate_actor_value(item) })
      else
        actor
      end
    end

    private def self.normalize_public_audience_values(value : JsonMap) : Nil
      value.each do |key, item|
        if key.in?("to", "cc", "bto", "bcc", "audience")
          value[key] = normalize_public_audience_value(item)
        else
          normalize_public_audience_nested(item)
        end
      end
    end

    private def self.normalize_public_audience_nested(value : JSON::Any) : Nil
      if object = value.as_h?
        normalize_public_audience_values(object.as(JsonMap))
      elsif array = value.as_a?
        array.each { |item| normalize_public_audience_nested(item) }
      end
    end

    private def self.normalize_public_audience_value(value : JSON::Any) : JSON::Any
      if string = value.as_s?
        public_audience_alias?(string) ? Aptok.json(PUBLIC_COLLECTION) : value
      elsif array = value.as_a?
        Aptok.json(array.map { |item| normalize_public_audience_value(item) })
      elsif object = value.as_h?
        normalize_public_audience_values(object.as(JsonMap))
        value
      else
        value
      end
    end

    private def self.public_audience_alias?(value : String) : Bool
      value == "Public" || value == "as:Public"
    end

    private def self.normalize_attachment_values(value : JsonMap) : Nil
      value.each do |key, item|
        if key == "attachment" && !item.as_a?
          value[key] = Aptok.json([item])
        else
          normalize_attachment_nested(item)
        end
      end
    end

    private def self.normalize_attachment_nested(value : JSON::Any) : Nil
      if object = value.as_h?
        normalize_attachment_values(object.as(JsonMap))
      elsif array = value.as_a?
        array.each { |item| normalize_attachment_nested(item) }
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

    private def object_id(object : JsonMap) : String?
      object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
    end

    private def local_origin_activity?(activity_id : String, actor_id : String) : Bool
      same_uri_origin?(activity_id, actor_id) && (same_uri_origin?(activity_id, @origin) || same_uri_origin?(activity_id, @canonical_origin))
    end

    private def same_uri_origin?(left : String, right : String) : Bool
      Aptok.same_resource_origin?(left, right)
    end

    private def processed_activity?(ctx : Context, activity : JsonMap) : Bool
      ttl = @idempotency_ttl
      kv = @kv
      return false unless ttl && kv

      key = idempotency_key(ctx, activity)
      return false unless key

      !!kv.get(key)
    end

    private def mark_activity_processed(ctx : Context, activity : JsonMap) : Nil
      ttl = @idempotency_ttl
      kv = @kv
      return unless ttl && kv

      key = idempotency_key(ctx, activity)
      return unless key

      kv.set(key, "1", ttl)
    end

    private def idempotency_key(ctx : Context, activity : JsonMap) : String?
      strategy = @idempotency_strategy
      id = activity["id"]?.try(&.as_s?)
      return unless id && !id.empty?

      key = strategy ? strategy.call(ctx, activity) : default_idempotency_key(ctx, id)
      key ? "aptok:inbox:#{key}" : nil
    end

    private def default_idempotency_key(ctx : Context, activity_id : String) : String
      inbox = ctx.recipient_identifier ? "inbox\n#{ctx.recipient_identifier}" : "sharedInbox"
      "#{ctx.origin}\n#{activity_id}\n#{inbox}"
    end

    private def built_in_idempotency_strategy(strategy : String) : InboxIdempotencyStrategy
      case strategy
      when "per-inbox"
        ->(ctx : Context, activity : JsonMap) do
          id = activity["id"]?.try(&.as_s?)
          id ? default_idempotency_key(ctx, id) : nil
        end
      when "per-origin"
        ->(ctx : Context, activity : JsonMap) do
          id = activity["id"]?.try(&.as_s?)
          id ? "#{ctx.origin}\n#{id}" : nil
        end
      when "global"
        ->(_ctx : Context, activity : JsonMap) do
          activity["id"]?.try(&.as_s?)
        end
      else
        raise ArgumentError.new("unknown inbox idempotency strategy: #{strategy}")
      end
    end

    private def validate_path!(path : String) : Nil
      raise ArgumentError.new("path must start with /") unless path.starts_with?("/")
    end

    private def queue_worker_loop(stop : Channel(Nil), poll_interval : Time::Span, &block : -> Array(QueueProcessResult)) : Nil
      loop do
        select
        when stop.receive
          break
        when timeout(poll_interval)
        end
        block.call
      end
    end

    private def validate_identifier_route!(path : String, route_name : String, *, allow_reserved : Bool = true) : Nil
      validate_path!(path)
      expressions = route_template_expressions(path)
      if expressions.size != 1
        raise ArgumentError.new("#{route_name} route must contain exactly one {identifier} URI template variable")
      end

      expression = expressions.first
      valid = expression == "identifier" || (allow_reserved && expression == "+identifier")
      unless valid
        raise ArgumentError.new("#{route_name} route only supports {identifier}#{allow_reserved ? " or {+identifier}" : ""}")
      end
    end

    private def validate_outbox_route!(path : String) : Nil
      validate_identifier_route!(path, "outbox", allow_reserved: false)
    end

    private def validate_static_route!(path : String, route_name : String) : Nil
      validate_path!(path)
      unless route_template_expressions(path).empty?
        raise ArgumentError.new("#{route_name} route must not contain URI template variables")
      end
    end

    private def validate_existing_route_path!(existing_path : String?, path : String, route_name : String) : Nil
      return unless existing_path
      return if existing_path == path

      raise ArgumentError.new("#{route_name} listener and dispatcher paths must match: #{existing_path} != #{path}")
    end

    private def route_template_expressions(path : String) : Array(String)
      expressions = path.scan(/\{([^}]*)\}/).map { |match| match[1] }
      if path.scan(/\{/).size != expressions.size || path.scan(/\}/).size != expressions.size
        raise ArgumentError.new("route template has unbalanced braces")
      end
      if expressions.any?(&.empty?)
        raise ArgumentError.new("route template variable must not be empty")
      end
      if expressions.uniq.size != expressions.size
        raise ArgumentError.new("route template variables must not be duplicated")
      end
      expressions
    end

    private def validate_actor_alias!(path : String, identifier : String) : Nil
      validate_path!(path)
      raise ArgumentError.new("actor alias identifier must not be empty") if identifier.empty?
      raise ArgumentError.new("actor alias path must not contain URI template variables") if path.includes?("{") || path.includes?("}")
      raise ArgumentError.new("actor alias path is already registered: #{path}") if @actor_alias_paths.has_key?(path)
      raise ArgumentError.new("actor alias identifier is already registered: #{identifier}") if @actor_alias_identifiers.has_key?(identifier)
    end
  end
end
