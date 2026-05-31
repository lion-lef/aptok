require "uri"

module Aptok
  AP_URI_PREFIX    = "ap://"
  AP_GATEWAY_PATH  = "/.well-known/apgateway"
  FEP_EF61_CONTEXT = "https://w3id.org/fep/ef61"

  record ApUri,
    authority : String,
    path : String,
    query : String? = nil,
    fragment : String? = nil do
    def canonical : String
      value = "#{AP_URI_PREFIX}#{@authority}#{@path}"
      @fragment ? "#{value}##{@fragment}" : value
    end

    def gateway_suffix : String
      "#{@authority}#{@path}"
    end
  end

  def self.ap_uri(authority : String, path : String, gateways : Array(String) = [] of String, fragment : String? = nil) : String
    authority = normalized_did_authority(authority)
    raise ArgumentError.new("ap URI path must start with /") unless path.starts_with?("/")

    value = "#{AP_URI_PREFIX}#{authority}#{path}"
    unless gateways.empty?
      normalized_gateways = gateways.compact_map { |gateway| normalize_ap_gateway(gateway) }
      unless normalized_gateways.empty?
        encoded = normalized_gateways.map { |gateway| URI.encode_www_form(gateway) }.join(",")
        value = "#{value}?gateways=#{encoded}"
      end
    end
    fragment ? "#{value}##{fragment}" : value
  end

  def self.canonical_ap_uri(value : String) : String?
    parsed = parse_ap_uri(value) || parse_compatible_ap_uri(value)
    parsed.try(&.canonical)
  end

  def self.ap_uri?(value : String) : Bool
    !!parse_ap_uri(value)
  end

  def self.compatible_ap_uri?(value : String) : Bool
    !!parse_compatible_ap_uri(value)
  end

  def self.ap_uri_equivalent?(left : String, right : String) : Bool
    left_canonical = canonical_ap_uri(left)
    right_canonical = canonical_ap_uri(right)
    !!left_canonical && left_canonical == right_canonical
  end

  def self.ap_uri_gateways(value : String) : Array(String)
    parsed = parse_ap_uri(value)
    query = parsed.try(&.query)
    return [] of String unless query

    gateways = URI::Params.parse(query)["gateways"]?
    return [] of String unless gateways

    gateways.split(",").compact_map { |gateway| normalize_ap_gateway(gateway) }
  rescue
    [] of String
  end

  def self.ap_gateway_url(gateway : String, value : String) : String
    parsed = parse_ap_uri(value) || parse_compatible_ap_uri(value)
    raise ArgumentError.new("value is not an ap URI or compatible gateway URI") unless parsed

    gateway_uri = URI.parse(gateway)
    scheme = gateway_uri.scheme.try(&.downcase)
    raise ArgumentError.new("gateway must use http or https") unless scheme == "http" || scheme == "https"
    raise ArgumentError.new("gateway must include a host") unless gateway_uri.host
    raise ArgumentError.new("gateway must not include a query or fragment") if gateway_uri.query || gateway_uri.fragment

    base_path = gateway_uri.path
    base_path = AP_GATEWAY_PATH if base_path.empty? || base_path == "/"
    base_path = base_path.rchop("/") if base_path.ends_with?("/")
    gateway_uri.path = "#{base_path}/#{parsed.gateway_suffix}"
    gateway_uri.query = nil
    gateway_uri.fragment = nil
    gateway_uri.to_s
  end

  def self.did_key(public_key_multibase : String) : String
    raise ArgumentError.new("did:key multibase value must use base58-btc") unless public_key_multibase.starts_with?("z")

    "did:key:#{public_key_multibase}"
  end

  def self.did_key(key_pair : ActorKeyPair) : String
    raise ArgumentError.new("did:key helpers require an Ed25519 key pair") unless key_pair.algorithm.downcase == "ed25519"

    did_key(Signatures.ed25519_public_key_multibase(key_pair.public_key_pem))
  end

  def self.did_key_verification_method(public_key_multibase : String) : String
    "#{did_key(public_key_multibase)}##{public_key_multibase}"
  end

  def self.did_key_verification_method(key_pair : ActorKeyPair) : String
    raise ArgumentError.new("did:key helpers require an Ed25519 key pair") unless key_pair.algorithm.downcase == "ed25519"

    did_key_verification_method(Signatures.ed25519_public_key_multibase(key_pair.public_key_pem))
  end

  def self.resource_origin(value : String) : String?
    if parsed = parse_ap_uri(value) || parse_compatible_ap_uri(value)
      return parsed.authority
    end
    if did = did_url_origin(value)
      return did
    end
    http_origin(value)
  end

  def self.same_resource_origin?(left : String, right : String) : Bool
    left_origin = resource_origin(left)
    right_origin = resource_origin(right)
    !!left_origin && left_origin == right_origin
  end

  def self.same_resource_id?(left : String, right : String) : Bool
    left_ap = canonical_ap_uri(left)
    right_ap = canonical_ap_uri(right)
    return left_ap == right_ap if left_ap && right_ap

    left == right
  end

  def self.parse_ap_uri(value : String) : ApUri?
    stripped = value.strip
    return nil unless stripped.starts_with?(AP_URI_PREFIX)

    rest = stripped[AP_URI_PREFIX.size..]
    rest, fragment = split_once(rest, '#')
    rest, query = split_once(rest, '?')
    authority_end = rest.index('/')
    return nil unless authority_end

    authority = URI.decode(rest[0...authority_end])
    path = rest[authority_end..]
    return nil unless valid_did_authority?(authority)
    return nil unless path.starts_with?("/") && !path.empty?

    ApUri.new(authority, path, query, fragment)
  rescue
    nil
  end

  def self.parse_compatible_ap_uri(value : String) : ApUri?
    uri = URI.parse(value)
    scheme = uri.scheme.try(&.downcase)
    return nil unless scheme == "http" || scheme == "https"

    suffix = compatible_ap_gateway_suffix(uri.path)
    return nil unless suffix

    suffix, fragment = split_once(suffix, '#')
    authority_end = suffix.index('/')
    return nil unless authority_end

    authority = URI.decode(suffix[0...authority_end])
    path = suffix[authority_end..]
    return nil unless valid_did_authority?(authority)
    return nil unless path.starts_with?("/") && !path.empty?

    ApUri.new(authority, path, nil, uri.fragment || fragment)
  rescue
    nil
  end

  def self.normalize_ap_gateway(value : String) : String?
    uri = URI.parse(value)
    scheme = uri.scheme.try(&.downcase)
    return nil unless scheme == "http" || scheme == "https"
    return nil unless uri.host
    return nil if uri.query || uri.fragment

    port = uri.port
    authority = uri.host.to_s.downcase
    if port && !((scheme == "http" && port == 80) || (scheme == "https" && port == 443))
      authority = "#{authority}:#{port}"
    end
    path = uri.path
    path = "" if path == "/"
    path = path.rchop("/") if path.ends_with?("/")
    "#{scheme}://#{authority}#{path}"
  rescue
    nil
  end

  private def self.compatible_ap_gateway_suffix(path : String) : String?
    prefix = "#{AP_GATEWAY_PATH}/"
    if path.starts_with?(prefix)
      return path[prefix.size..]
    end

    did_index = path.index("/did:")
    return path[(did_index + 1)..] if did_index

    encoded_index = path.downcase.index("/did%3a")
    return path[(encoded_index + 1)..] if encoded_index

    nil
  end

  private def self.normalized_did_authority(value : String) : String
    authority = value.starts_with?("did:") ? value : URI.decode(value)
    raise ArgumentError.new("ap URI authority must be a DID") unless valid_did_authority?(authority)

    authority
  end

  private def self.valid_did_authority?(value : String) : Bool
    !!/\Adid:[a-z0-9]+:.+\z/.match(value)
  end

  private def self.did_url_origin(value : String) : String?
    stripped = value.strip
    return nil unless stripped.starts_with?("did:")

    end_index = stripped.size
    ['/', '?', '#'].each do |char|
      index = stripped.index(char)
      end_index = index if index && index < end_index
    end
    did = stripped[0...end_index]
    valid_did_authority?(did) ? did : nil
  end

  private def self.http_origin(value : String) : String?
    uri = URI.parse(value)
    scheme = uri.scheme.try(&.downcase)
    return nil unless scheme == "http" || scheme == "https"
    return nil unless uri.host

    port = uri.port
    authority = uri.host.to_s.downcase
    if port && !((scheme == "http" && port == 80) || (scheme == "https" && port == 443))
      authority = "#{authority}:#{port}"
    end
    "#{scheme}://#{authority}"
  rescue
    nil
  end

  private def self.split_once(value : String, separator : Char) : Tuple(String, String?)
    index = value.index(separator)
    return {value, nil} unless index

    {value[0...index], value[(index + 1)..]? || ""}
  end
end
