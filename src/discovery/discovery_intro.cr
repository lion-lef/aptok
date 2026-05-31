require "../vocabulary/vocabulary"
require "../remote/remote"

module Aptok
  NODEINFO_2_1_REL           = "http://nodeinfo.diaspora.software/ns/schema/2.1"
  NODEINFO_2_0_REL           = "http://nodeinfo.diaspora.software/ns/schema/2.0"
  NODEINFO_2_1_CONTENT_TYPE  = "application/json; profile=\"http://nodeinfo.diaspora.software/ns/schema/2.1#\""
  NODEINFO_PROTOCOLS         = %w[activitypub buddycloud dfrn diaspora libertree ostatus pumpio tent xmpp zot]
  NODEINFO_INBOUND_SERVICES  = %w[atom1.0 gnusocial imap pnut pop3 pumpio rss2.0 twitter]
  NODEINFO_OUTBOUND_SERVICES = %w[
    atom1.0 blogger buddycloud diaspora dreamwidth drupal facebook friendica
    gnusocial google insanejournal libertree linkedin livejournal mediagoblin
    myspace pinterest pnut posterous pumpio redmatrix rss2.0 smtp tent tumblr
    twitter wordpress xmpp
  ]
  NODEINFO_SERVICES = (NODEINFO_INBOUND_SERVICES + NODEINFO_OUTBOUND_SERVICES).uniq

  record NodeInfoLookupOptions,
    document_loader : DocumentLoader? = nil,
    document_get_provider : DocumentGetProvider? = nil,
    allow_private_address : Bool = false,
    user_agent : String = DEFAULT_USER_AGENT,
    direct : Bool = false,
    parse : String = "strict"

  record SemVer,
    major : Int32,
    minor : Int32,
    patch : Int32,
    prerelease : String? = nil,
    build : String? = nil do
    def to_s(io : IO) : Nil
      io << major << "." << minor << "." << patch
      io << "-" << prerelease if prerelease
      io << "+" << build if build
    end
  end

  record NodeInfoSoftware,
    name : String,
    version : String,
    repository : String? = nil,
    homepage : String? = nil

  record NodeInfoServices,
    inbound : Array(String) = [] of String,
    outbound : Array(String) = [] of String

  record NodeInfoUsageUsers,
    total : Int64? = nil,
    active_halfyear : Int64? = nil,
    active_month : Int64? = nil

  record NodeInfoUsage,
    users : NodeInfoUsageUsers = NodeInfoUsageUsers.new,
    local_posts : Int64? = nil,
    local_comments : Int64? = nil

  record NodeInfo,
    version : String,
    software : NodeInfoSoftware,
    protocols : Array(String),
    services : NodeInfoServices = NodeInfoServices.new,
    open_registrations : Bool = false,
    usage : NodeInfoUsage = NodeInfoUsage.new,
    metadata : JsonMap = JsonMap.new

  def self.parse_semver(value : String) : SemVer?
    match = value.match(/\A(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?\z/)
    return nil unless match

    SemVer.new(
      major: match[1].to_i,
      minor: match[2].to_i,
      patch: match[3].to_i,
      prerelease: match[4]?,
      build: match[5]?
    )
  end

  def self.format_semver(version : SemVer) : String
    version.to_s
  end

  def self.parse_nodeinfo(document : JsonMap, parse : String = "strict") : NodeInfo?
    return nil unless parse == "best-effort" || valid_nodeinfo?(document)

    version = nodeinfo_string_value(document["version"]?) || "2.1"
    software_map = document["software"]?.try(&.as_h?)
    name = software_map.try(&.["name"]?.try(&.as_s?))
    name = parse == "best-effort" ? normalize_nodeinfo_name(name) : name
    return nil unless name
    software = NodeInfoSoftware.new(
      name: name,
      version: nodeinfo_string_value(software_map.try(&.["version"]?)) || "0.0.0",
      repository: nodeinfo_url_value(software_map.try(&.["repository"]?)),
      homepage: nodeinfo_url_value(software_map.try(&.["homepage"]?))
    )
    NodeInfo.new(
      version: version,
      software: software,
      protocols: nodeinfo_protocols(document["protocols"]?, parse == "best-effort"),
      services: parse_nodeinfo_services(document["services"]?, parse == "best-effort"),
      open_registrations: document["openRegistrations"]?.try(&.as_bool?) || false,
      usage: parse_nodeinfo_usage(document["usage"]?, parse == "best-effort"),
      metadata: document["metadata"]?.try(&.as_h?) || JsonMap.new
    )
  end

  def self.nodeinfo_to_json(nodeinfo : NodeInfo) : JsonMap
    software = JsonMap{
      "name"    => json(nodeinfo.software.name),
      "version" => json(nodeinfo.software.version),
    }
    software["repository"] = json(nodeinfo.software.repository) if nodeinfo.software.repository
    software["homepage"] = json(nodeinfo.software.homepage) if nodeinfo.software.homepage

    users = JsonMap.new
    users["total"] = json(nodeinfo.usage.users.total) if nodeinfo.usage.users.total
    users["activeHalfyear"] = json(nodeinfo.usage.users.active_halfyear) if nodeinfo.usage.users.active_halfyear
    users["activeMonth"] = json(nodeinfo.usage.users.active_month) if nodeinfo.usage.users.active_month

    usage = JsonMap{"users" => json(users)}
    usage["localPosts"] = json(nodeinfo.usage.local_posts) if nodeinfo.usage.local_posts
    usage["localComments"] = json(nodeinfo.usage.local_comments) if nodeinfo.usage.local_comments

    document = json({
      "version"   => "2.1",
      "$schema"   => "http://nodeinfo.diaspora.software/ns/schema/2.1#",
      "software"  => software,
      "protocols" => nodeinfo.protocols,
      "services"  => {
        "inbound"  => nodeinfo.services.inbound,
        "outbound" => nodeinfo.services.outbound,
      },
      "openRegistrations" => nodeinfo.open_registrations,
      "usage"             => usage,
      "metadata"          => nodeinfo.metadata,
    }).as_h
    raise ArgumentError.new("invalid NodeInfo document") unless valid_nodeinfo_for_serialization?(document)

    document
  end

  def self.webfinger_jrd(
    subject : String,
    self_href : String,
    aliases : Array(String) = [] of String,
    properties : JsonMap = JsonMap.new,
    links : Array(JsonMap) = [] of JsonMap
  ) : JsonMap
    default_link = JsonMap{
      "rel"  => json("self"),
      "type" => json("application/activity+json"),
      "href" => json(self_href),
    }
    doc = json({
      "subject" => subject,
      "aliases" => aliases,
    }).as_h
    doc["links"] = json([default_link] + links)
    doc["properties"] = json(properties) unless properties.empty?
    doc
  end

  def self.nodeinfo(
    software_name : String,
    software_version : String,
    protocols : Array(String) = ["activitypub"],
    open_registrations : Bool = false,
    users_total : Int64 = 0_i64,
    metadata : JsonMap = JsonMap.new,
    software_repository : String? = nil,
    software_homepage : String? = nil,
    inbound_services : Array(String) = [] of String,
    outbound_services : Array(String) = [] of String,
    users_active_halfyear : Int64? = nil,
    users_active_month : Int64? = nil,
    local_posts : Int64 = 0_i64,
    local_comments : Int64 = 0_i64
  ) : JsonMap
    software = {
      "name"       => software_name,
      "version"    => software_version,
      "repository" => software_repository,
      "homepage"   => software_homepage,
    }.compact
    users = {
      "total"          => users_total,
      "activeHalfyear" => users_active_halfyear,
      "activeMonth"    => users_active_month,
    }.compact

    json({
      "version"   => "2.1",
      "$schema"   => "http://nodeinfo.diaspora.software/ns/schema/2.1#",
      "software"  => software,
      "protocols" => protocols,
      "services"  => {
        "inbound"  => inbound_services,
        "outbound" => outbound_services,
      },
      "openRegistrations" => open_registrations,
      "usage"             => {
        "users"         => users,
        "localPosts"    => local_posts,
        "localComments" => local_comments,
      },
      "metadata" => metadata,
    }).as_h
  end

  def self.nodeinfo_well_known(href : String) : JsonMap
    json({
      "links" => [
        {
          "rel"  => "http://nodeinfo.diaspora.software/ns/schema/2.1",
          "type" => NODEINFO_2_1_CONTENT_TYPE,
          "href" => href,
        },
      ],
    }).as_h
  end

  def self.lookup_nodeinfo(origin : String, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
    document_url = origin
    unless options.direct
      well_known = loader.call(nodeinfo_well_known_url(origin))
      return nil unless well_known

      link = nodeinfo_link(well_known)
      return nil unless link
      document_url = link
    end

    document = loader.call(document_url)
    return nil unless document
    return document if options.parse == "none"
    return document if valid_nodeinfo?(document)
    options.parse == "best-effort" ? document : nil
  end

  def self.lookup_nodeinfo(origin : URI, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
    lookup_nodeinfo(origin.to_s, loader, options)
  end

  def self.lookup_nodeinfo(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
    loader = options.document_loader || Remote.default_document_loader(options.document_get_provider, allow_private_address: options.allow_private_address, user_agent: options.user_agent, accept: "application/json")
    lookup_nodeinfo(origin, loader, options)
  end

  def self.lookup_nodeinfo(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : JsonMap?
    lookup_nodeinfo(origin.to_s, options)
  end

  def self.lookup_nodeinfo_document(origin : String, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
    return nil if options.parse == "none"

    document = lookup_nodeinfo(origin, loader, options)
    document ? parse_nodeinfo(document, options.parse) : nil
  end

  def self.lookup_nodeinfo_document(origin : URI, loader : DocumentLoader, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
    lookup_nodeinfo_document(origin.to_s, loader, options)
  end

  def self.lookup_nodeinfo_document(origin : String, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
    return nil if options.parse == "none"

    document = lookup_nodeinfo(origin, options)
    document ? parse_nodeinfo(document, options.parse) : nil
  end

  def self.lookup_nodeinfo_document(origin : URI, options : NodeInfoLookupOptions = NodeInfoLookupOptions.new) : NodeInfo?
    lookup_nodeinfo_document(origin.to_s, options)
  end

  private def self.nodeinfo_well_known_url(origin : String) : String
    uri = URI.parse(origin)
    scheme = uri.scheme
    host = uri.host
    raise URI::Error.new("NodeInfo origin must include a scheme and host") unless scheme && host

    authority = host
    authority += ":#{uri.port}" if uri.port
    "#{scheme}://#{authority}/.well-known/nodeinfo"
  end
end
