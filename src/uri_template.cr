require "uri"

module Aptok
  record ParsedUri,
    type : String,
    identifier : String? = nil,
    object_type : String? = nil,
    collection_name : String? = nil,
    values : Hash(String, String) = Hash(String, String).new

  class RouteTemplate
    getter template : String

    def initialize(@template : String)
      raise ArgumentError.new("route template must start with /") unless @template.starts_with?("/")
    end

    def match(path : String) : Hash(String, String)?
      if reserved_tail = @template.match(/\A(.+)\/\{\+([^}]+)\}\z/)
        prefix = reserved_tail[1]
        if path.starts_with?("#{prefix}/")
          rest = path[prefix.size + 1..]
          return nil if rest.empty?

          return {reserved_tail[2] => URI.decode(rest)}
        end
      end

      template_parts = parts(@template)
      path_parts = parts(path)
      params = Hash(String, String).new
      template_index = 0
      path_index = 0

      while template_index < template_parts.size
        part = template_parts[template_index]
        variable = variable(part)
        path_part = path_parts[path_index]?

        if variable
          operator, name = variable
          if operator == "+" && template_index == template_parts.size - 1
            rest = path_parts[path_index..]?.try(&.join("/")) || ""
            params[name] = URI.decode(rest)
            path_index = path_parts.size
          else
            return nil unless path_part
            params[name] = URI.decode(path_part)
            path_index += 1
          end
        else
          return nil unless path_part
          return nil unless part == URI.decode(path_part)
          path_index += 1
        end

        template_index += 1
      end

      path_index == path_parts.size ? params : nil
    end

    def expand(params : Hash(String, String)) : String
      expanded = @template.gsub(/\{(\+?)([^}]+)\}/) do
        operator = $1
        key = $2
        value = params[key]?
        raise ArgumentError.new("missing URI template parameter: #{key}") unless value
        operator == "+" ? encode_reserved(value) : URI.encode_path_segment(value)
      end
      expanded
    end

    def variables : Array(String)
      @template.scan(/\{(\+?)([^}]+)\}/).map { |match| match[2] }
    end

    private def parts(path : String) : Array(String)
      path.split("/").reject(&.empty?)
    end

    private def variable(part : String) : Tuple(String, String)?
      match = part.match(/\A\{(\+?)([^}]+)\}\z/)
      match ? {match[1], match[2]} : nil
    end

    private def encode_reserved(value : String) : String
      value.gsub(" ", "%20")
    end
  end
end
