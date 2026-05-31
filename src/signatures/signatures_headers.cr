module Aptok
  module Signatures
    private def self.format_component_identifier(component : String) : String
      pieces = component.split(";", 2)
      name = pieces[0]
      params = pieces[1]?
      formatted = %("#{name}")
      formatted += ";#{params}" if params
      formatted
    end

    private def self.component_identifier_name(component : String) : String
      component.split(";", 2)[0]
    end

    private def self.component_parameter(component : String, name : String) : String?
      pieces = component.split(";", 2)
      params = pieces[1]?
      return nil unless params
      params.split(";").each do |param|
        param_pieces = param.split("=", 2)
        key = param_pieces[0]?
        raw = param_pieces[1]?
        next unless key && key == name && raw
        return raw.gsub(/\A"|"$/, "")
      end
      nil
    end

    private def self.query_component(path : String) : String
      index = path.index('?')
      index ? path[index..] : ""
    end

    private def self.query_param_component(path : String, component : String) : String
      name = component_parameter(component, "name") || ""
      query = query_component(path)
      return "" if query.empty?
      params = URI::Params.parse(query.lchop('?'))
      params[name]? || ""
    end

    private def self.parse_signature_header_value(value : String, label : String) : String?
      value.split(",").each do |part|
        key, raw = part.split("=", 2)
        next unless key && raw
        next unless key.strip == label
        return raw.strip.gsub(/\A:|:\z/, "")
      end
      nil
    end

    private def self.valid_message_signature_params?(params : MessageSignatureParams, target_url : String?, options : Rfc9421VerifyOptions) : Bool
      options.required_components.all? { |component| params.components.includes?(component) } &&
        (!params.components.includes?("@target-uri") || !!target_url) &&
        valid_message_signature_time?(params, options)
    end

    private def self.valid_message_signature_time?(params : MessageSignatureParams, options : Rfc9421VerifyOptions) : Bool
      skew = options.max_clock_skew.total_seconds.to_i64
      now = options.now
      if created = params.created
        return false if created > now + skew
      end
      if expires = params.expires
        return false if expires < now - skew
        return false if params.created && expires < params.created.not_nil!
      end
      true
    end

    private def self.uri_authority(uri : URI) : String
      host = uri.host.to_s
      host = "#{host}:#{uri.port}" if uri.port
      host
    end

    private def self.normalized_target_uri(uri : URI) : String
      scheme = uri.scheme || "https"
      path = uri_path(uri)
      "#{scheme}://#{uri_authority(uri)}#{path}"
    end

    private def self.uri_path(uri : URI) : String
      path = uri.path.empty? ? "/" : uri.path
      path += "?#{uri.query}" if uri.query
      path
    end
  end
end
