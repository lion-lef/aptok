module Aptork
  class Federation
    private def strip_trailing_slash(value : String) : String
      value.ends_with?("/") ? value[0, value.size - 1] : value
    end

    private def validate_origin(value : String) : String
      uri = URI.parse(value)
      raise ArgumentError.new("origin must include http or https scheme and host") unless uri.host && uri.scheme.in?("http", "https")
      raise ArgumentError.new("origin must not include a path, query, or fragment") unless uri.path.empty? || uri.path == "/"
      raise ArgumentError.new("origin must not include a path, query, or fragment") if uri.query || uri.fragment

      "#{uri.scheme.not_nil!.downcase}://#{normalized_origin_authority(uri)}"
    end

    private def trailing_slash_mismatch?(template : String, path : String) : Bool
      return false if template == "/" || path == "/"
      template.ends_with?("/") != path.ends_with?("/")
    end

    private def authority_from_origin(origin : String) : String
      uri = URI.parse(origin)
      raise ArgumentError.new("origin must include a host") unless uri.host

      normalized_origin_authority(uri)
    end

    private def normalized_origin_authority(uri : URI) : String
      port = uri.port
      authority = uri.host.to_s
      authority = "#{authority}:#{port}" if port && !((uri.scheme == "http" && port == 80) || (uri.scheme == "https" && port == 443))
      authority.downcase
    end

    private def normalize_handle_host(value : String) : String
      raise ArgumentError.new("handle_host must not be empty") if value.empty?
      raise ArgumentError.new("handle_host must not include a scheme") if value.includes?("://")
      raise ArgumentError.new("handle_host must not include a path") if value.includes?("/")

      uri = URI.parse("https://#{value}/")
      raise ArgumentError.new("handle_host must include a host") unless uri.host
      authority = Aptork.normalize_actor_handle(
        "_@#{uri.host}",
        ActorHandleOptions.new(trim_leading_at: true, punycode: true)
      ).split("@", 2)[1]
      port = uri.port
      authority = "#{authority}:#{port}" if port && port != 443
      authority.downcase
    end
  end
end
