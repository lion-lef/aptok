require "../signatures/signatures_types"
require "base64"
require "digest/sha256"
require "uri"
require "../http/http"
require "../vocabulary/vocabulary"

module Aptok
  module Signatures
    BASE58BTC_ALPHABET      = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    ED25519_MULTIKEY_PREFIX = Bytes[0xed_u8, 0x01_u8]
    ED25519_SPKI_PREFIX     = Bytes[0x30_u8, 0x2a_u8, 0x30_u8, 0x05_u8, 0x06_u8, 0x03_u8, 0x2b_u8, 0x65_u8, 0x70_u8, 0x03_u8, 0x21_u8, 0x00_u8]

    def self.parse_signature_header(value : String) : SignatureParams?
      parts = Hash(String, String).new
      value.split(",").each do |part|
        key, raw = part.split("=", 2)
        next unless key && raw
        parts[key.strip] = raw.strip.gsub(/\A"|"$/, "")
      end

      key_id = parts["keyId"]?
      algorithm = parts["algorithm"]? || "rsa-sha256"
      headers = (parts["headers"]? || "date").split(/\s+/)
      signature = parts["signature"]?
      return nil unless key_id && signature

      SignatureParams.new(key_id, algorithm, headers, signature)
    end

    def self.header(request : Request, name : String) : String?
      request.headers.each do |key, value|
        return value if key.downcase == name.downcase
      end
      nil
    end

    def self.digest_header(body : String) : String
      "SHA-256=#{Base64.strict_encode(Digest::SHA256.digest(body).to_slice)}"
    end

    def self.content_digest_header(body : String) : String
      "sha-256=:#{Base64.strict_encode(Digest::SHA256.digest(body).to_slice)}:"
    end

    def self.valid_digest?(request : Request) : Bool
      digest = header(request, "Digest")
      return true unless digest
      digest == digest_header(request.body)
    end

    def self.valid_content_digest?(request : Request) : Bool
      digest = header(request, "Content-Digest")
      return true unless digest
      digest == content_digest_header(request.body)
    end

    def self.signing_string(request : Request, signed_headers : Array(String)) : String
      signed_headers.map do |name|
        normalized = name.downcase
        if normalized == "(request-target)"
          "(request-target): #{request.method.downcase} #{request.path}"
        else
          value = header(request, normalized) || ""
          "#{normalized}: #{value}"
        end
      end.join("\n")
    end

    def self.verified_by_headers?(request : Request) : Bool
      signature = header(request, "Signature")
      message_signature = parse_message_signature(request)
      return valid_content_digest?(request) if message_signature
      return false unless signature
      return false unless parse_signature_header(signature)
      valid_digest?(request)
    end

    def self.rfc9421_rsa_sha256_headers(method : String, url : String, body : String, key_pair : ActorKeyPair, label : String = "sig1", created : Int64 = Time.utc.to_unix) : Hash(String, String)
      rfc9421_rsa_sha256_headers(
        method,
        url,
        body,
        key_pair,
        Rfc9421Options.new(label: label, created: created, key_id: key_pair.id)
      )
    end

    def self.rfc9421_rsa_sha256_headers(method : String, url : String, body : String, key_pair : ActorKeyPair, options : Rfc9421Options) : Hash(String, String)
      key_path = key_pair.private_key_path || ""
      key_pem = key_pair.private_key_pem
      return {} of String => String if key_pair.id.empty? || (key_path.empty? && key_pem.nil?)

      uri = URI.parse(url)
      authority = uri_authority(uri)
      path = uri_path(uri)
      target_uri = normalized_target_uri(uri)
      content_digest = content_digest_header(body)
      date = Time.unix(options.created).to_s("%a, %d %b %Y %H:%M:%S GMT")
      headers = {
        "host"           => authority,
        "date"           => date,
        "content-digest" => content_digest,
      }
      signature_params = signature_params_value(
        options.components,
        options.created,
        options.key_id || key_pair.id,
        options.algorithm,
        options.nonce,
        options.tag,
        options.expires
      )
      data = build_message_signature_base(method, path, authority, target_uri, headers, options.components, signature_params)
      signature_b64 = key_pem ? sign_string_with_pem(data, key_pem) : sign_string(data, key_path)

      {
        "Host"            => authority,
        "Date"            => date,
        "Content-Digest"  => content_digest,
        "Signature-Input" => %(#{options.label}=#{signature_params}),
        "Signature"       => %(#{options.label}=:#{signature_b64}:),
      }
    end

    def self.parse_message_signature(request : Request, label : String? = nil) : MessageSignatureParams?
      signature_input = header(request, "Signature-Input")
      signature = header(request, "Signature")
      return nil unless signature_input && signature

      parsed_input = parse_signature_input_header(signature_input, label)
      return nil unless parsed_input
      actual_label, components, params, signature_params = parsed_input
      signature_b64 = parse_signature_header_value(signature, actual_label)
      return nil unless signature_b64

      key_id = params["keyid"]?
      algorithm = params["alg"]? || params["algorithm"]? || "rsa-v1_5-sha256"
      return nil unless key_id

      MessageSignatureParams.new(
        label: actual_label,
        key_id: key_id,
        algorithm: algorithm,
        components: components,
        signature: signature_b64,
        signature_params: signature_params,
        created: params["created"]?.try(&.to_i64?),
        expires: params["expires"]?.try(&.to_i64?),
        nonce: params["nonce"]?,
        tag: params["tag"]?
      )
    end

    def self.parse_accept_signature(value : String) : AcceptSignatureChallenge?
      parse_accept_signatures(value).first?
    end

    def self.parse_accept_signatures(value : String) : Array(AcceptSignatureChallenge)
      split_dictionary_members(value).compact_map do |member|
        parsed = parse_signature_input_member(member, nil)
        next unless parsed
        label, components, params, _signature_params = parsed
        AcceptSignatureChallenge.new(
          label: label,
          components: components,
          algorithm: params["alg"]? || params["algorithm"]?,
          key_id: params["keyid"]?,
          nonce: params["nonce"]?,
          tag: params["tag"]?,
          expires: params.has_key?("expires")
        )
      end
    end

    def self.message_signature_base(request : Request, params : MessageSignatureParams) : String
      message_signature_base(request, nil, params)
    end

    def self.message_signature_base(request : Request, target_url : String?, params : MessageSignatureParams) : String
      path = request.path.empty? ? "/" : request.path
      authority = header(request, "Host") || header(request, ":authority") || ""
      target_uri = target_url || begin
        scheme = header(request, ":scheme") || "https"
        "#{scheme}://#{authority}#{path}"
      end
      fields = Hash(String, String).new
      request.headers.each { |key, value| fields[key.downcase] = value }
      data = params.components.map do |component|
        component_name = component_identifier_name(component)
        value = case component
                when .starts_with?("@query-param")
                  query_param_component(path, component)
                else
                  case component_name
                  when "@method"
                    request.method.upcase
                  when "@path"
                    path
                  when "@target-uri"
                    target_uri
                  when "@authority"
                    authority
                  when "@scheme"
                    URI.parse(target_uri).scheme || "https"
                  when "@request-target"
                    path
                  when "@query"
                    query_component(path)
                  when "@status"
                    ""
                  else
                    fields[component_name.downcase]? || ""
                  end
                end
        %(#{format_component_identifier(component)}: #{value})
      end
      data << %("@signature-params": #{params.signature_params})
      data.join("\n")
    end

    def self.verify_rfc9421_rsa_sha256?(request : Request, key_pair : ActorKeyPair, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      verify_rfc9421_rsa_sha256_with_pem?(request, key_pair.public_key_pem, label, options)
    end

    def self.verify_rfc9421_rsa_sha256?(request : Request, target_url : String, key_pair : ActorKeyPair, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      verify_rfc9421_rsa_sha256_with_pem?(request, target_url, key_pair.public_key_pem, label, options)
    end

    def self.verify_rfc9421_rsa_sha256_with_pem?(request : Request, public_key_pem : String, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      verify_rfc9421_rsa_sha256_with_pem?(request, nil, public_key_pem, label, options)
    end

    def self.verify_rfc9421_rsa_sha256_with_pem?(request : Request, target_url : String?, public_key_pem : String, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      keyfile = File.tempfile("aptok-public-key")
      begin
        keyfile.print(public_key_pem)
        keyfile.flush
        verify_rfc9421_rsa_sha256?(request, target_url, keyfile.path, label, options)
      ensure
        keyfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
      end
    end

    def self.verify_rfc9421_rsa_sha256?(request : Request, public_key_path : String, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      verify_rfc9421_rsa_sha256?(request, nil, public_key_path, label, options)
    end

    def self.verify_rfc9421_rsa_sha256?(request : Request, target_url : String?, public_key_path : String, label : String? = nil, options : Rfc9421VerifyOptions = Rfc9421VerifyOptions.new) : Bool
      params = parse_message_signature(request, label)
      return false unless params
      return false unless params.algorithm.downcase == "rsa-v1_5-sha256"
      return false unless valid_content_digest?(request)
      return false unless valid_message_signature_params?(params, target_url, options)

      verify_string_with_openssl(
        message_signature_base(request, target_url, params),
        Base64.decode(params.signature),
        public_key_path
      )
    rescue
      false
    end

    def self.rsa_sha256_headers(method : String, url : String, body : String, key_pair : ActorKeyPair) : Hash(String, String)
      key_path = key_pair.private_key_path || ""
      key_pem = key_pair.private_key_pem
      return {} of String => String if key_pair.id.empty? || (key_path.empty? && key_pem.nil?)

      uri = URI.parse(url)
      host = uri.host.to_s
      host = "#{host}:#{uri.port}" if uri.port
      path = uri.path.empty? ? "/" : uri.path
      path += "?#{uri.query}" if uri.query

      date = Time.utc.to_s("%a, %d %b %Y %H:%M:%S GMT")
      digest_header = digest_header(body)
      headers_list = "(request-target) host date digest"
      data = "(request-target): #{method.downcase} #{path}\nhost: #{host}\ndate: #{date}\ndigest: #{digest_header}"
      signature_b64 = key_pem ? sign_string_with_pem(data, key_pem) : sign_string(data, key_path)
      signature = %(keyId="#{key_pair.id}",algorithm="rsa-sha256",headers="#{headers_list}",signature="#{signature_b64}")

      {
        "Date"      => date,
        "Host"      => host,
        "Digest"    => digest_header,
        "Signature" => signature,
      }
    end
  end
end
