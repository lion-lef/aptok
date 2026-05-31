module Aptok
  private def self.nodeinfo_link(document : JsonMap) : String?
    links = document["links"]?.try(&.as_a?) || [] of JSON::Any
    link = links.find do |link|
      map = link.as_h?
      next false unless map
      rel = map["rel"]?.try(&.as_s?)
      rel == NODEINFO_2_0_REL || rel == "#{NODEINFO_2_0_REL}#" ||
        rel == NODEINFO_2_1_REL || rel == "#{NODEINFO_2_1_REL}#"
    end
    link.try(&.as_h["href"]?.try(&.as_s?))
  end

  private def self.valid_nodeinfo?(document : JsonMap) : Bool
    software = document["software"]?.try(&.as_h?)
    protocols = document["protocols"]?.try(&.as_a?)
    usage = document["usage"]?.try(&.as_h?)
    !!software &&
      valid_nodeinfo_software?(software) &&
      !!nodeinfo_string_value(software["version"]?) &&
      valid_optional_url?(software["repository"]?) &&
      valid_optional_url?(software["homepage"]?) &&
      valid_string_array?(protocols, NODEINFO_PROTOCOLS, require_nonempty: true) &&
      valid_services?(document["services"]?) &&
      valid_optional_bool?(document["openRegistrations"]?) &&
      valid_usage?(document["usage"]?) &&
      valid_optional_object?(document["metadata"]?)
  end

  private def self.parse_nodeinfo_services(value : JSON::Any?, best_effort : Bool = false) : NodeInfoServices
    services = value.try(&.as_h?)
    return NodeInfoServices.new unless services

    NodeInfoServices.new(
      inbound: nodeinfo_services(services["inbound"]?, NODEINFO_INBOUND_SERVICES, best_effort),
      outbound: nodeinfo_services(services["outbound"]?, NODEINFO_OUTBOUND_SERVICES, best_effort)
    )
  end

  private def self.parse_nodeinfo_usage(value : JSON::Any?, best_effort : Bool = false) : NodeInfoUsage
    usage = value.try(&.as_h?)
    return NodeInfoUsage.new(local_posts: 0_i64, local_comments: 0_i64) unless usage

    users = usage["users"]?.try(&.as_h?)
    NodeInfoUsage.new(
      users: NodeInfoUsageUsers.new(
        total: nodeinfo_integer_value(users.try(&.["total"]?), best_effort),
        active_halfyear: nodeinfo_integer_value(users.try(&.["activeHalfyear"]?), best_effort),
        active_month: nodeinfo_integer_value(users.try(&.["activeMonth"]?), best_effort)
      ),
      local_posts: nodeinfo_integer_value(usage["localPosts"]?, best_effort) || 0_i64,
      local_comments: nodeinfo_integer_value(usage["localComments"]?, best_effort) || 0_i64
    )
  end

  private def self.string_array(value : JSON::Any?) : Array(String)
    value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
  end

  private def self.nodeinfo_protocols(value : JSON::Any?, best_effort : Bool) : Array(String)
    values = string_array(value)
    best_effort ? values.select { |protocol| NODEINFO_PROTOCOLS.includes?(protocol) } : values
  end

  private def self.nodeinfo_services(value : JSON::Any?, allowed : Array(String), best_effort : Bool) : Array(String)
    values = string_array(value)
    best_effort ? values.select { |service| allowed.includes?(service) } : values
  end

  private def self.nodeinfo_integer_value(value : JSON::Any?, best_effort : Bool = false) : Int64?
    integer = value.try(&.as_i64?) || value.try(&.as_i?).try(&.to_i64)
    if integer.nil? && best_effort
      integer = parse_nodeinfo_integer_prefix(value.try(&.as_s?))
    end
    integer
  end

  private def self.non_negative_integer_value(value : JSON::Any?, best_effort : Bool = false) : Int64?
    integer = nodeinfo_integer_value(value, best_effort)
    integer && integer >= 0 ? integer : nil
  end

  private def self.parse_nodeinfo_integer_prefix(value : String?) : Int64?
    return nil unless value
    match = value.match(/\A\s*([+-]?\d+)/)
    return nil unless match

    match[1].to_i64?
  end

  private def self.nodeinfo_string_value(value : JSON::Any?) : String?
    return nil unless value

    if string = value.as_s?
      string
    elsif integer = value.as_i64?
      integer.to_s
    elsif float = value.as_f?
      float.to_s
    elsif bool = value.as_bool?
      bool.to_s
    end
  end

  private def self.nodeinfo_url_value(value : JSON::Any?) : String?
    url = value.try(&.as_s?)
    return nil unless valid_optional_url?(value)

    url
  end

  private def self.valid_nodeinfo_software?(software : Hash(String, JSON::Any)) : Bool
    name = software["name"]?.try(&.as_s?)
    !!name && !!name.match(/\A[a-z0-9-]+\z/)
  end

  private def self.valid_optional_url?(value : JSON::Any?) : Bool
    url = value.try(&.as_s?)
    return true unless url

    parsed = URI.parse(url)
    !!parsed.scheme && ["http", "https"].includes?(parsed.scheme) && !!parsed.host
  rescue
    false
  end

  private def self.valid_string_array?(value : Array(JSON::Any)?, allowed : Array(String), require_nonempty : Bool = false) : Bool
    return false if value.nil?
    return false if require_nonempty && value.empty?

    value.all? do |item|
      string = item.as_s?
      !!string && allowed.includes?(string)
    end
  end

  private def self.valid_services?(value : JSON::Any?) : Bool
    services = value.try(&.as_h?)
    return true if value.nil?
    return false unless services

    valid_optional_string_array?(services["inbound"]?, NODEINFO_INBOUND_SERVICES) &&
      valid_optional_string_array?(services["outbound"]?, NODEINFO_OUTBOUND_SERVICES)
  end

  private def self.valid_optional_string_array?(value : JSON::Any?, allowed : Array(String)) : Bool
    return true if value.nil?

    valid_string_array?(value.as_a?, allowed)
  end

  private def self.valid_optional_bool?(value : JSON::Any?) : Bool
    value.nil? || !value.try(&.as_bool?).nil?
  end

  private def self.valid_optional_object?(value : JSON::Any?) : Bool
    value.nil? || !value.try(&.as_h?).nil?
  end

  private def self.valid_usage?(value : JSON::Any?) : Bool
    return true if value.nil?
    usage = value.try(&.as_h?)
    return false unless usage

    users = usage["users"]?.try(&.as_h?)
    return false unless users

    return false unless [
                          users["total"]?,
                          users["activeHalfyear"]?,
                          users["activeMonth"]?,
                        ].compact.all? { |item| !nodeinfo_integer_value(item).nil? }

    [
      usage["localPosts"]?,
      usage["localComments"]?,
    ].compact.all? { |value| !nodeinfo_integer_value(value).nil? }
  end

  private def self.valid_nodeinfo_for_serialization?(document : JsonMap) : Bool
    usage = document["usage"]?.try(&.as_h?)
    return false unless usage
    users = usage["users"]?.try(&.as_h?)
    return false unless users
    return false unless [
                          users["total"]?,
                          users["activeHalfyear"]?,
                          users["activeMonth"]?,
                        ].compact.all? { |item| !!non_negative_integer_value(item) }
    return false unless non_negative_integer_value(usage["localPosts"]?)
    return false unless non_negative_integer_value(usage["localComments"]?)

    valid_nodeinfo?(document)
  end

  private def self.normalize_nodeinfo_name(value : String?) : String?
    return nil unless value
    return nil unless value.match(/\A\s*[A-Za-z0-9-]+\s*\z/)

    value.strip.downcase
  end
end
