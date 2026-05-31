module Aptok
  module Signatures
    def self.ed25519_public_key_pem_from_multibase(public_key_multibase : String) : String?
      decoded = base58btc_decode(public_key_multibase)
      return nil unless decoded
      return nil unless decoded[0, ED25519_MULTIKEY_PREFIX.size] == ED25519_MULTIKEY_PREFIX

      public_key = decoded[ED25519_MULTIKEY_PREFIX.size, 32]
      return nil unless public_key
      der = Bytes.new(ED25519_SPKI_PREFIX.size + public_key.size)
      ED25519_SPKI_PREFIX.copy_to(der)
      public_key.copy_to(der + ED25519_SPKI_PREFIX.size)
      pem("PUBLIC KEY", der)
    end

    def self.verify_ed25519_with_pem?(data : Bytes, proof_value : String, public_key_pem : String) : Bool
      signature = base58btc_decode(proof_value)
      return false unless signature
      return false unless signature.size == 64

      keyfile = File.tempfile("aptok-ed25519-public-key")
      datafile = File.tempfile("aptok-ed25519-data")
      sigfile = File.tempfile("aptok-ed25519-signature")
      begin
        keyfile.print(public_key_pem)
        keyfile.flush
        datafile.write(data)
        datafile.flush
        sigfile.write(signature)
        sigfile.flush

        errors = IO::Memory.new
        status = Process.run(
          "openssl",
          args: ["pkeyutl", "-verify", "-pubin", "-inkey", keyfile.path, "-rawin", "-in", datafile.path, "-sigfile", sigfile.path],
          output: IO::Memory.new,
          error: errors
        )
        status.success?
      ensure
        keyfile.close
        datafile.close
        sigfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
        File.delete(datafile.path) if File.exists?(datafile.path)
        File.delete(sigfile.path) if File.exists?(sigfile.path)
      end
    rescue
      false
    end

    private def self.verify_string_with_openssl(data : String, signature : Bytes, public_key_path : String) : Bool
      sigfile = File.tempfile("aptok-signature")
      begin
        sigfile.write(signature)
        sigfile.flush
        output = IO::Memory.new
        errors = IO::Memory.new
        status = Process.run(
          "openssl",
          args: ["dgst", "-sha256", "-verify", public_key_path, "-signature", sigfile.path],
          input: IO::Memory.new(data),
          output: output,
          error: errors
        )
        status.success?
      ensure
        sigfile.close
        File.delete(sigfile.path) if File.exists?(sigfile.path)
      end
    rescue
      false
    end

    private def self.object_proof_cryptosuite(key_pair : ActorKeyPair, options : ObjectProofOptions) : String
      return options.cryptosuite unless options.cryptosuite == "eddsa-jcs-2022" && key_pair.algorithm.downcase == "rsa-sha256"
      "jcs-rsa-sha256-2026"
    end

    private def self.proof_config(object : JsonMap, proof : JsonMap) : JsonMap
      config = proof.dup
      config.delete("proofValue")
      config["@context"] = object["@context"] if object["@context"]?
      config
    end

    private def self.ed25519_public_key_bytes(public_key_pem : String) : Bytes
      keyfile = File.tempfile("aptok-ed25519-public-key")
      begin
        keyfile.print(public_key_pem)
        keyfile.flush
        output = IO::Memory.new
        errors = IO::Memory.new
        status = Process.run(
          "openssl",
          args: ["pkey", "-pubin", "-in", keyfile.path, "-outform", "DER"],
          output: output,
          error: errors
        )
        raise "openssl ed25519 public key export failed: #{errors.to_s.strip}" unless status.success?

        der = output.to_slice
        raise "invalid ed25519 public key" unless der.size == ED25519_SPKI_PREFIX.size + 32
        raise "invalid ed25519 public key prefix" unless der[0, ED25519_SPKI_PREFIX.size] == ED25519_SPKI_PREFIX
        der[ED25519_SPKI_PREFIX.size, 32]
      ensure
        keyfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
      end
    end

    private def self.pem(label : String, der : Bytes) : String
      encoded = Base64.strict_encode(der)
      body = encoded.chars.each_slice(64).map(&.join).join("\n")
      "-----BEGIN #{label}-----\n#{body}\n-----END #{label}-----\n"
    end

    private def self.canonical_json_value(value : JSON::Any, skip_proof : Bool) : String
      raw = value.raw
      case raw
      when Nil
        "null"
      when Bool
        raw ? "true" : "false"
      when String, Int64, Float64
        raw.to_json
      when Array
        "[" + raw.map { |item| canonical_json_value(item, skip_proof) }.join(",") + "]"
      when Hash
        keys = raw.keys.map(&.to_s).sort
        keys = keys.reject { |key| key == "proof" } if skip_proof
        "{" + keys.map { |key| "#{key.to_json}:#{canonical_json_value(raw[key], skip_proof)}" }.join(",") + "}"
      else
        value.to_json
      end
    end

    private def self.signature_params_value(
      components : Array(String),
      created : Int64,
      key_id : String,
      algorithm : String,
      nonce : String? = nil,
      tag : String? = nil,
      expires : Int64? = nil
    ) : String
      component_list = components.map { |component| format_component_identifier(component) }.join(" ")
      value = "(#{component_list});created=#{created};keyid=\"#{key_id}\";alg=\"#{algorithm}\""
      value += %(;nonce="#{nonce}") if nonce
      value += %(;tag="#{tag}") if tag
      value += %(;expires=#{expires}) if expires
      value
    end

    private def self.build_message_signature_base(
      method : String,
      path : String,
      authority : String,
      target_uri : String,
      fields : Hash(String, String),
      components : Array(String),
      signature_params : String
    ) : String
      data = components.map do |component|
        component_name = component_identifier_name(component)
        value = case component
                when .starts_with?("@query-param")
                  query_param_component(path, component)
                else
                  case component_name
                  when "@method"
                    method.upcase
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
                    raise ArgumentError.new("@status cannot be signed for requests")
                  else
                    fields[component_name.downcase]? || ""
                  end
                end
        %(#{format_component_identifier(component)}: #{value})
      end
      data << %("@signature-params": #{signature_params})
      data.join("\n")
    end

    private def self.parse_signature_input_header(value : String, preferred_label : String?) : Tuple(String, Array(String), Hash(String, String), String)?
      split_dictionary_members(value).each do |member|
        parsed = parse_signature_input_member(member, preferred_label)
        return parsed if parsed
      end
      nil
    end

    private def self.parse_signature_input_member(value : String, preferred_label : String?) : Tuple(String, Array(String), Hash(String, String), String)?
      label, rest = value.split("=", 2)
      return nil unless label && rest
      label = label.strip
      return nil if preferred_label && label != preferred_label
      start = rest.index('(')
      finish = rest.index(')')
      return nil unless start && finish && finish > start

      components = parse_component_list(rest[(start + 1)...finish])
      params_part = rest[(finish + 1)..]? || ""
      params = Hash(String, String).new
      params_part.split(";").each do |part|
        next if part.strip.empty?
        pieces = part.split("=", 2)
        key = pieces[0]?
        raw = pieces[1]?
        next unless key
        params[key.strip.downcase] = raw ? raw.strip.gsub(/\A"|"$/, "") : "true"
      end
      signature_params = rest[start..]
      {label, components, params, signature_params}
    end

    private def self.split_dictionary_members(value : String) : Array(String)
      members = [] of String
      current = String::Builder.new
      quoted = false
      depth = 0
      value.each_char do |char|
        case char
        when '"'
          quoted = !quoted
          current << char
        when '('
          depth += 1 unless quoted
          current << char
        when ')'
          depth -= 1 if depth > 0 && !quoted
          current << char
        when ','
          if quoted || depth > 0
            current << char
          else
            part = current.to_s.strip
            members << part unless part.empty?
            current = String::Builder.new
          end
        else
          current << char
        end
      end
      part = current.to_s.strip
      members << part unless part.empty?
      members
    end

    private def self.parse_component_list(value : String) : Array(String)
      components = [] of String
      i = 0
      while i < value.size
        while i < value.size && value[i].whitespace?
          i += 1
        end
        break if i >= value.size
        break unless value[i] == '"'
        i += 1
        name = String::Builder.new
        while i < value.size && value[i] != '"'
          name << value[i]
          i += 1
        end
        i += 1
        params = String::Builder.new
        while i < value.size && !value[i].whitespace?
          params << value[i]
          i += 1
        end
        components << "#{name.to_s}#{params.to_s}"
      end
      components
    end
  end
end
