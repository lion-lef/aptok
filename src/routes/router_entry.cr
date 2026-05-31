require "json"
require "uri"
require "../http/http"
require "../federation/federation"
require "../discovery/discovery"
require "../uri_template"

module Aptok
  ACTIVITYPUB_ACCEPT_TYPES = [
    "application/activity+json",
    "application/ld+json",
    "application/*",
    "*/*",
  ]
  ACTIVITYSTREAMS_PROFILE  = "https://www.w3.org/ns/activitystreams"
  FEDIFY_TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"

  class Router
    def initialize(@federation : Federation, @options : FetchOptions = FetchOptions.new)
    end

    def handle(request : Request) : Response
      method = request.method.upcase
      head = method == "HEAD"
      read_method = method == "GET" || head

      if read_method && request.path == "/.well-known/webfinger"
        return head ? head_response(handle_webfinger(request)) : handle_webfinger(request)
      end

      if read_method && request.path == "/.well-known/nodeinfo"
        ctx = @federation.create_context(context_data: @options.context_data)
        document = @federation.has_nodeinfo_dispatcher? ? Aptok.nodeinfo_well_known(ctx.get_nodeinfo_uri) : Aptok.json({"links" => [] of Hash(String, String)}).as_h
        response = json_response(document, "application/jrd+json")
        return head ? head_response(response) : response
      end

      if read_method && request.path == @federation.nodeinfo_path
        return not_found(request) unless @federation.has_nodeinfo_dispatcher?

        ctx = @federation.create_context(context_data: @options.context_data)
        response = json_response(@federation.dispatch_nodeinfo(ctx), NODEINFO_2_1_CONTENT_TYPE)
        return head ? head_response(response) : response
      end

      if request.path.starts_with?("#{AP_GATEWAY_PATH}/")
        return handle_apgateway(request, method, head, read_method)
      end

      ctx = @federation.create_context(context_data: @options.context_data)

      if read_method
        response = handle_get(ctx, request)
        return head ? head_response(response) : response
      end

      if method == "POST"
        response = handle_post(ctx, request)
        return vary_accept_response(response) if accepts_activitypub?(request)

        return response
      end

      Response.new(405, {"Allow" => "GET, HEAD, POST"}, "")
    rescue ex : JSON::ParseException
      Response.new(400, {"Content-Type" => "text/plain"}, "invalid JSON")
    end

    private def handle_webfinger(request : Request) : Response
      resource = request.query["resource"]?
      return fedify_text_response(400, "Missing resource parameter.") unless resource
      return fedify_text_response(400, "Invalid resource URL.") unless webfinger_resource_uri?(resource)

      ctx = @federation.create_context(context_data: @options.context_data)
      identifier = nil.as(String?)
      if resource.starts_with?("acct:")
        match = /^acct:([^@]+)@([^@]+)$/.match(resource)
        return not_found(request) unless match

        username = match[1]
        host = normalized_acct_host(match[2])
        return not_found(request) unless @federation.accepts_webfinger_host?(host)
        resource = "acct:#{username}@#{host}"
        identifier = @federation.webfinger_identifier(ctx, username)
      elsif webfinger_url?(resource)
        parsed = ctx.parse_uri(resource)
        if parsed.try(&.type) == "actor"
          identifier = parsed.try(&.identifier)
        else
          identifier = @federation.alias_identifier(ctx, resource)
        end
      else
        identifier = @federation.alias_identifier(ctx, resource)
      end
      return not_found(request) unless identifier

      if jrd = @federation.dispatch_webfinger(ctx, resource, identifier)
        return webfinger_response(jrd)
      end

      actor = ctx.actor(identifier)
      return not_found(request) unless actor
      return gone_webfinger if tombstone?(actor)

      actor_id = actor["id"]?.try(&.as_s?) || ctx.get_actor_uri(identifier)
      links = automatic_webfinger_links(actor) + @federation.dispatch_webfinger_links(ctx, resource)
      aliases = webfinger_aliases(resource, actor, actor_id)
      webfinger_response(Aptok.webfinger_jrd(webfinger_subject(resource, actor), actor_id, aliases: aliases, links: links))
    end

    private def handle_apgateway(request : Request, method : String, head : Bool, read_method : Bool) : Response
      gateway = apgateway_request(request.path)
      return not_found(request) unless gateway

      ctx = @federation.create_context(context_data: @options.context_data).with_portable_authority(gateway[:authority])
      routed_request = Request.new(request.method, gateway[:path], request.headers, request.query, request.body)
      if read_method
        response = handle_get(ctx, routed_request)
        return head ? head_response(response) : response
      end

      if method == "POST"
        response = handle_post(ctx, routed_request)
        return vary_accept_response(response) if accepts_activitypub?(request)

        return response
      end

      Response.new(405, {"Allow" => "GET, HEAD, POST"}, "")
    end

    private def apgateway_request(path : String) : NamedTuple(authority: String, path: String)?
      prefix = "#{AP_GATEWAY_PATH}/"
      return nil unless path.starts_with?(prefix)

      suffix = path[prefix.size..]
      authority_end = suffix.index('/')
      return nil unless authority_end

      authority = URI.decode(suffix[0...authority_end])
      return nil unless Aptok.parse_ap_uri("#{AP_URI_PREFIX}#{authority}/")

      gateway_path = suffix[authority_end..]
      return nil unless gateway_path.starts_with?("/")

      {authority: authority, path: gateway_path}
    rescue
      nil
    end

    private def handle_get(ctx : Context, request : Request) : Response
      path = @federation.route_path(request.path)
      if identifier = @federation.actor_alias_identifier(path)
        return actor_response(ctx, request, identifier, {"identifier" => identifier})
      end

      if params = @federation.match_route(@federation.actor_path, path)
        identifier = params["identifier"]?
        return actor_response(ctx, request, identifier, params)
      end

      if params = @federation.match_route(@federation.outbox_path, path)
        return not_acceptable(request) unless accepts_activitypub?(request)
        identifier = params["identifier"]?
        if identifier
          collection = outbox_collection(ctx, identifier, request)
          return not_found(request) unless collection
          return unauthorized(request) unless @federation.authorize_collection?("outbox", ctx, request, identifier, params)
          return collection ? activity_response(collection) : not_found(request)
        end
      end

      @federation.collection_routes.each do |route|
        if params = @federation.match_route(route.path, path)
          return not_acceptable(request) unless accepts_activitypub?(request)
          identifier = params["identifier"]?
          collection = collection_response(ctx, route, params, request)
          return not_found(request) unless collection
          return unauthorized(request) unless @federation.authorize_collection?(route.name, ctx, request, identifier, params)
          return activity_response(collection)
        end
      end

      @federation.object_routes.each do |route|
        if params = @federation.match_route(route.path, path)
          return not_acceptable(request) unless accepts_activitypub?(request)
          object = route.dispatcher.call(ctx, params)
          return not_found(request) unless object
          return unauthorized(request) unless @federation.authorize_object?(route.type, ctx, request, params["identifier"]?, params)
          return activity_response(object)
        end
      end

      not_found(request)
    end

    private def actor_response(ctx : Context, request : Request, identifier : String?, params : Hash(String, String)) : Response
      return not_acceptable(request) unless accepts_activitypub?(request)

      actor = identifier ? ctx.actor(identifier) : nil
      return not_found(request) unless actor
      return unauthorized(request) unless @federation.authorize_actor?(ctx, request, identifier, params)
      activity_response(actor, tombstone?(actor) ? 410 : 200)
    end

    private def handle_post(ctx : Context, request : Request) : Response
      path = @federation.route_path(request.path)
      if params = @federation.match_route(@federation.outbox_path, path)
        if identifier = params["identifier"]?
          return handle_outbox_post(ctx, request, identifier)
        end
      end

      routed = false
      recipient_identifier = nil.as(String?)
      if params = @federation.match_route(@federation.inbox_path, path)
        if identifier = params["identifier"]?
          recipient_identifier = identifier
          routed = true
        end
      elsif shared = @federation.shared_inbox_path
        routed = true if @federation.match_route(shared, path)
      end
      return not_found(request) unless routed
      return not_found(request) unless @federation.has_actor_dispatcher?
      if recipient_identifier
        actor = ctx.get_actor(recipient_identifier)
        return not_found(request) unless actor && !tombstone?(actor)
      end

      ctx = ctx.with_recipient(recipient_identifier)
      ctx = ctx.with_inbound_request(request)
      ctx = ctx.with_document_loader(@federation.inbox_document_loader(ctx, recipient_identifier))

      json = begin
        JSON.parse(request.body)
      rescue ex : JSON::ParseException
        @federation.notify_inbox_error(ctx, ex)
        return invalid_json_response
      end
      activity = json.as_h?
      unless activity && activity_json?(activity)
        @federation.notify_inbox_error(ctx, ArgumentError.new("Invalid activity."))
        return invalid_activity_response
      end

      verification = @federation.verify_inbox_request(request, activity)
      unless verification.verified
        if response = @federation.notify_unverified_activity(ctx, activity, verification)
          return response
        end
        headers = {"Content-Type" => FEDIFY_TEXT_CONTENT_TYPE}
        challenge_headers = @federation.challenge_headers(verification)
        challenge_headers.each { |key, value| headers[key] = value }
        body = challenge_headers.empty? ? (verification.reason || "unauthorized") : "Failed to verify the request signature."
        return Response.new(401, headers, body)
      end
      if @federation.inbox_queue
        @federation.enqueue_inbox_activity(recipient_identifier, activity, trusted: true)
        return fedify_text_response(202, "Activity is enqueued.")
      end
      result = begin
        @federation.route_activity_result(ctx, activity)
      rescue
        RouteActivityResult::Error
      end
      inbox_activity_response(result, activity)
    end

    private def inbox_activity_response(result : RouteActivityResult, activity : JsonMap) : Response
      case result
      when .already_processed?
        activity_id = activity["id"]?.try(&.as_s?) || activity["@id"]?.try(&.as_s?) || ""
        fedify_text_response(202, "Activity <#{activity_id}> has already been processed.")
      when .missing_actor?
        fedify_text_response(400, "Missing actor.")
      when .enqueued?
        fedify_text_response(202, "Activity is enqueued.")
      when .error?
        fedify_text_response(500, "Internal server error.")
      else
        fedify_text_response(202, "")
      end
    end

    private def handle_outbox_post(ctx : Context, request : Request, identifier : String) : Response
      return method_not_allowed_get_head unless @federation.has_outbox_listeners?

      ctx = ctx.with_outbox(identifier).with_inbound_request(request)
      return unauthorized(request) unless @federation.authorize_outbox?(ctx, identifier)
      return not_found(request) unless @federation.has_actor_dispatcher?
      actor = ctx.get_actor(identifier)
      return not_found(request) unless actor

      json = begin
        JSON.parse(request.body)
      rescue ex : JSON::ParseException
        @federation.notify_outbox_listener_error(ctx, ex)
        return invalid_json_response
      end
      activity = json.as_h?
      unless activity && activity_json?(activity)
        @federation.notify_outbox_listener_error(ctx, ArgumentError.new("Invalid activity."))
        return invalid_activity_response
      end

      unless activity_actor_id(activity)
        message = "The posted activity has no actor."
        @federation.notify_outbox_listener_error(ctx, ArgumentError.new(message))
        return bad_request(message)
      end
      unless outbox_actor_matches?(ctx, identifier, actor, activity)
        message = "The activity actor does not match the outbox owner."
        @federation.notify_outbox_listener_error(ctx, ArgumentError.new(message))
        return bad_request(message)
      end

      result = begin
        @federation.route_outbox_activity_result(ctx, activity)
      rescue
        RouteOutboxActivityResult::Error
      end
      outbox_activity_response(result)
    end
  end
end
