module Aptok
  class Router
    private def collection_response(ctx : Context, route : CollectionRoute, params : Hash(String, String), request : Request) : JsonMap?
      size = request.query["size"]?.try(&.to_i?) || 20
      page = request.query["page"]?.try(&.to_i?)
      path = RouteTemplate.new(route.path).expand(params)
      id = "#{ctx.canonical_origin}#{path}"
      cursor = request.query["cursor"]?
      if dispatcher = route.filtered_page_dispatcher
        result = dispatcher.call(ctx, params, cursor, size, followers_base_url(route, request))
        return nil unless result
        result = filter_collection_page_result(ctx, route, request, result)
        return collection_with_metadata(route, params, cursor_collection_response(ctx, route, params, request, id, result, cursor, size))
      elsif dispatcher = route.page_dispatcher
        result = dispatcher.call(ctx, params, cursor, size)
        return nil unless result
        result = filter_collection_page_result(ctx, route, request, result)
        return collection_with_metadata(route, params, cursor_collection_response(ctx, route, params, request, id, result, cursor, size))
      end

      dispatcher = route.dispatcher
      items = dispatcher ? dispatcher.call(ctx, params) : [] of JsonMap
      items = filter_collection_items(ctx, route, request, items)
      response = route.ordered ? Aptok.paginated_ordered_collection(id, items, page, size) : Aptok.paginated_collection(id, items, page, size)
      if page.nil?
        if total_items = @federation.collection_count(ctx, route.name, params)
          response["totalItems"] = Aptok.json(total_items)
        end
      end
      collection_with_metadata(route, params, response)
    end

    private def cursor_collection_response(ctx : Context, route : CollectionRoute, params : Hash(String, String), request : Request, id : String, result : CollectionPageResult, cursor : String?, size : Int32) : JsonMap
      page_base = cursor_page_base(id, request)
      if cursor
        return route.ordered ? Aptok.cursor_ordered_collection_page(id, page_base, result.items, cursor, result.next_cursor, result.prev_cursor, size) : Aptok.cursor_collection_page(id, page_base, result.items, cursor, result.next_cursor, result.prev_cursor, size)
      end
      total_items = result.total_items || @federation.collection_count(ctx, route.name, params)
      first_cursor = result.first_cursor || @federation.collection_first_cursor(ctx, route.name, params) || result.next_cursor
      last_cursor = result.last_cursor || @federation.collection_last_cursor(ctx, route.name, params)
      route.ordered ? Aptok.cursor_ordered_collection(id, total_items, first_cursor, last_cursor, size, page_base) : Aptok.cursor_collection(id, total_items, first_cursor, last_cursor, size, page_base)
    end

    private def cursor_page_base(id : String, request : Request) : String
      params = URI::Params.new
      request.query.each do |key, value|
        next if key == "cursor"

        params[key] = value
      end
      return id if params.empty?

      uri = URI.parse(id)
      uri.query = params.to_s
      uri.to_s
    end

    private def filter_collection_page_result(ctx : Context, route : CollectionRoute, request : Request, result : CollectionPageResult) : CollectionPageResult
      items = filter_collection_items(ctx, route, request, result.items)
      return result if items.size == result.items.size

      CollectionPageResult.new(
        items,
        result.next_cursor,
        result.prev_cursor,
        result.total_items,
        result.first_cursor,
        result.last_cursor
      )
    end

    private def filter_collection_items(ctx : Context, route : CollectionRoute, request : Request, items : Array(JsonMap)) : Array(JsonMap)
      items = @federation.filter_collection_items(ctx, route.name, items)
      base_url = followers_base_url(route, request)
      return items unless base_url

      items.select do |item|
        item["id"]?.try(&.as_s?.try(&.starts_with?(base_url))) || false
      end
    end

    private def followers_base_url(route : CollectionRoute, request : Request) : String?
      return nil unless route.name == "followers"

      value = request.query["base-url"]?
      return nil unless value && !value.empty?

      uri = URI.parse(value)
      return nil unless uri.scheme && uri.host

      port = uri.port
      base_url = "#{uri.scheme}://#{uri.host}"
      base_url += ":#{port}" if port && !(uri.scheme == "http" && port == 80) && !(uri.scheme == "https" && port == 443)
      "#{base_url}/"
    rescue URI::Error
      nil
    end

    private def collection_with_metadata(route : CollectionRoute, params : Hash(String, String), collection : JsonMap) : JsonMap
      if item_type = @federation.collection_item_type(route.name)
        collection["itemType"] = Aptok.json(item_type)
      end
      collection
    end

    private def json_response(body : JsonMap, content_type : String = "application/json") : Response
      Response.new(200, {"Content-Type" => content_type}, body.to_json)
    end

    private def head_response(response : Response) : Response
      Response.new(response.status, response.headers, "")
    end

    private def webfinger_response(body : JsonMap) : Response
      Response.new(200, {"Content-Type" => "application/jrd+json", "Access-Control-Allow-Origin" => "*"}, body.to_json)
    end

    private def not_found(request : Request) : Response
      if handler = @options.on_not_found
        return handler.call(request)
      end
      fedify_text_response(404, "Not Found")
    end

    private def gone(_request : Request) : Response
      Response.new(410, {"Content-Type" => "text/plain"}, "gone")
    end

    private def gone_webfinger : Response
      Response.new(410, {"Access-Control-Allow-Origin" => "*"}, "")
    end

    private def unauthorized(request : Request) : Response
      if handler = @options.on_unauthorized
        return handler.call(request)
      end
      Response.new(401, {"Content-Type" => FEDIFY_TEXT_CONTENT_TYPE, "Vary" => "Accept, Signature"}, "Unauthorized")
    end

    private def bad_request(message : String) : Response
      fedify_text_response(400, message)
    end

    private def not_acceptable(request : Request) : Response
      if handler = @options.on_not_acceptable
        return handler.call(request)
      end
      Response.new(406, {"Content-Type" => FEDIFY_TEXT_CONTENT_TYPE, "Vary" => "Accept, Signature"}, "Not Acceptable")
    end

    private def origin_authority : String?
      parsed = URI.parse(@federation.canonical_origin)
      return nil unless parsed.host

      parsed.port ? "#{parsed.host}:#{parsed.port}" : parsed.host
    end

    private def normalized_acct_host(value : String) : String
      normalized = Aptok.normalize_actor_handle(
        "_@#{value}",
        ActorHandleOptions.new(trim_leading_at: true, punycode: true)
      )
      normalized.split("@", 2)[1]
    end
  end
end
