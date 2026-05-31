module Aptok
  class Router
    private def outbox_activity_response(result : RouteOutboxActivityResult) : Response
      case result
      when .error?
        fedify_text_response(500, "Internal server error.")
      else
        fedify_text_response(202, "")
      end
    end

    private def invalid_json_response : Response
      fedify_text_response(400, "Invalid JSON.")
    end

    private def invalid_activity_response : Response
      fedify_text_response(400, "Invalid activity.")
    end

    private def fedify_text_response(status : Int32, body : String) : Response
      Response.new(status, {"Content-Type" => FEDIFY_TEXT_CONTENT_TYPE}, body)
    end

    private def vary_accept_response(response : Response) : Response
      headers = response.headers.dup
      existing = headers["Vary"]?
      includes_accept = existing.try do |value|
        value.split(",").map(&.strip.downcase).includes?("accept")
      end
      unless includes_accept
        headers["Vary"] = existing && !existing.empty? ? "#{existing}, Accept" : "Accept"
      end

      Response.new(response.status, headers, response.body)
    end

    private def method_not_allowed_get_head : Response
      Response.new(405, {"Allow" => "GET, HEAD", "Content-Type" => FEDIFY_TEXT_CONTENT_TYPE}, "Method not allowed.")
    end

    private def activity_json?(activity : JsonMap) : Bool
      type = activity["type"]?
      return false unless type

      if name = type.as_s?
        activity_type_name?(name)
      elsif names = type.as_a?
        names.any? { |entry| entry.as_s?.try { |name| activity_type_name?(name) } || false }
      else
        false
      end
    end

    private def activity_type_name?(type : String) : Bool
      name = Aptok.type_name(type)
      name == "Activity" || ACTIVITY_TYPES.includes?(name)
    end

    private def outbox_actor_matches?(ctx : Context, identifier : String, actor_document : JsonMap, activity : JsonMap) : Bool
      actor_ids = activity_actor_ids(activity)
      expected_actor_id = actor_document["id"]?.try(&.as_s?) || ctx.get_actor_uri(identifier)
      return false if actor_ids.empty?

      actor_ids.all? { |actor_id| Aptok.same_resource_id?(actor_id, expected_actor_id) }
    end

    private def activity_actor_id(activity : JsonMap) : String?
      activity_actor_ids(activity).first?
    end

    private def activity_actor_ids(activity : JsonMap) : Array(String)
      actor_ids(activity["actor"]?)
    end

    private def actor_ids(value : JSON::Any?) : Array(String)
      return [] of String unless value

      if string = value.as_s?
        string.empty? ? [] of String : [string]
      elsif object = value.as_h?
        id = object["id"]?.try(&.as_s?)
        id && !id.empty? ? [id] : [] of String
      elsif array = value.as_a?
        array.flat_map { |item| actor_ids(item) }
      else
        [] of String
      end
    end

    private def accepts_activitypub?(request : Request) : Bool
      accept = header_value(request, "Accept")
      return false if accept.nil?

      types = preferred_media_types(accept)
      return false if types.empty?

      preferred = types.first
      return false if preferred == "text/html" || preferred == "application/xhtml+xml"

      types.any? do |media_type|
        media_type == "application/activity+json" ||
          media_type == "application/ld+json" ||
          media_type == "application/json"
      end
    end

    private def preferred_media_types(accept : String) : Array(String)
      entries = [] of Tuple(String, Float64, Int32)
      accept.split(",").each_with_index do |entry, index|
        parts = entry.split(";").map(&.strip)
        media_type = parts.shift?.try(&.downcase)
        next unless media_type

        q = 1.0
        parts.each do |part|
          name, value = split_parameter(part)
          if name == "q"
            q = value.to_f? || 0.0
          end
        end

        entries << {media_type, q, index}
      end

      entries.select { |entry| entry[1] > 0 }.sort do |left, right|
        q_order = right[1] <=> left[1]
        q_order == 0 ? (left[2] <=> right[2]) : q_order
      end.map { |entry| entry[0] }
    end

    private def split_parameter(part : String) : Tuple(String, String)
      pieces = part.split("=", 2)
      name = pieces[0]? || ""
      value = pieces[1]? || ""
      {name.strip.downcase, value.strip}
    end

    private def unquote(value : String) : String
      stripped = value.strip
      if stripped.size >= 2 && stripped.starts_with?('"') && stripped.ends_with?('"')
        stripped[1...-1]
      else
        stripped
      end
    end

    private def header_value(request : Request, name : String) : String?
      request.headers.each do |key, value|
        return value if key.downcase == name.downcase
      end
      nil
    end

    private def webfinger_url?(resource : String) : Bool
      uri = URI.parse(resource)
      (uri.scheme == "https" || uri.scheme == "http") && !!uri.host
    rescue URI::Error
      false
    end

    private def webfinger_resource_uri?(resource : String) : Bool
      return false if resource =~ /\s/
      return false unless /\A[A-Za-z][A-Za-z0-9+.-]*:/ =~ resource

      uri = URI.parse(resource)
      return !!uri.host && !uri.host.to_s.empty? if uri.scheme == "http" || uri.scheme == "https"

      true
    rescue URI::Error
      false
    end

    private def webfinger_subject(resource : String, actor : JsonMap) : String
      resource
    end

    private def webfinger_aliases(resource : String, actor : JsonMap, actor_id : String) : Array(String)
      aliases = [] of String
      aliases << actor_id unless actor_id == resource

      username = actor["preferredUsername"]?.try(&.as_s?)
      if username
        if resource.starts_with?("acct:")
          acct = "acct:#{username}@#{@federation.handle_host}"
          aliases << acct unless resource.ends_with?("@#{@federation.handle_host}") || acct == resource || acct == webfinger_subject(resource, actor)
        else
          [@federation.handle_host, origin_authority].compact.uniq.each do |host|
            acct = "acct:#{username}@#{host}"
            aliases << acct unless acct == resource || acct == webfinger_subject(resource, actor)
          end
        end
      end

      aliases.uniq
    end

    private def automatic_webfinger_links(actor : JsonMap) : Array(JsonMap)
      links = [] of JsonMap
      append_url_links(links, actor["url"]?)
      append_icon_links(links, actor["icon"]?)
      links
    end

    private def append_url_links(links : Array(JsonMap), value : JSON::Any?) : Nil
      return unless value
      if url = value.as_s?
        links << JsonMap{
          "rel"  => Aptok.json("http://webfinger.net/rel/profile-page"),
          "href" => Aptok.json(url),
        }
      elsif array = value.as_a?
        array.each { |item| append_url_links(links, item) }
      elsif link = value.as_h?
        rel = link["rel"]?.try(&.as_s?) || "http://webfinger.net/rel/profile-page"
        href = link["href"]?.try(&.as_s?) || link["url"]?.try(&.as_s?)
        return unless href

        mapped = JsonMap{
          "rel"  => Aptok.json(rel),
          "href" => Aptok.json(href),
        }
        media_type = link["type"]? || link["mediaType"]?
        mapped["type"] = media_type if media_type
        if template = link["template"]?
          mapped["template"] = template
        end
        links << mapped
      end
    end

    private def append_icon_links(links : Array(JsonMap), value : JSON::Any?) : Nil
      return unless value
      if icon = value.as_h?
        href = icon["url"]?.try(&.as_s?) || icon["href"]?.try(&.as_s?)
        return unless href

        link = JsonMap{
          "rel"  => Aptok.json("http://webfinger.net/rel/avatar"),
          "href" => Aptok.json(href),
        }
        if media_type = icon["mediaType"]? || icon["type"]?
          link["type"] = media_type
        end
        links << link
      elsif array = value.as_a?
        array.each { |item| append_icon_links(links, item) }
      end
    end

    private def tombstone?(object : JsonMap) : Bool
      type_matches?(object["type"]?, "Tombstone")
    end

    private def type_matches?(value : JSON::Any?, expected : String) : Bool
      return false unless value

      if type = value.as_s?
        Aptok.type_name(type) == expected
      elsif types = value.as_a?
        types.any? { |entry| type_matches?(entry, expected) }
      else
        false
      end
    end

    private def activity_response(body : JsonMap, status : Int32 = 200) : Response
      Response.new(status, {"Content-Type" => FEDERATION_ACTIVITY_CONTENT_TYPE, "Vary" => "Accept"}, body.to_json)
    end

    private def outbox_collection(ctx : Context, identifier : String, request : Request) : JsonMap?
      size = request.query["size"]?.try(&.to_i?) || 20
      cursor = request.query["cursor"]?
      base = ctx.get_outbox_uri(identifier)
      page_base = cursor_page_base(base, request)
      if @federation.has_outbox_page_dispatcher?
        result = @federation.dispatch_outbox_page(ctx, identifier, cursor, size)
        return nil unless result
        return cursor ? Aptok.cursor_ordered_collection_page(base, page_base, result.items, cursor, result.next_cursor, result.prev_cursor, size) : Aptok.cursor_ordered_collection(base, result.total_items, result.first_cursor || result.next_cursor, result.last_cursor, size, page_base)
      end

      page = request.query["page"]?.try(&.to_i?)
      Aptok.paginated_ordered_collection(ctx.get_outbox_uri(identifier), ctx.outbox(identifier), page, size)
    end
  end
end
