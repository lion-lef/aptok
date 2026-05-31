module Aptok
  module Signatures
    def self.verify_rsa_sha256?(request : Request, key_pair : ActorKeyPair) : Bool
      verify_rsa_sha256_with_pem?(request, key_pair.public_key_pem)
    end

    def self.verify_rsa_sha256_with_pem?(request : Request, public_key_pem : String) : Bool
      keyfile = File.tempfile("aptok-public-key")
      begin
        keyfile.print(public_key_pem)
        keyfile.flush
        verify_rsa_sha256?(request, keyfile.path)
      ensure
        keyfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
      end
    end

    def self.verify_rsa_sha256?(request : Request, public_key_path : String) : Bool
      signature = header(request, "Signature")
      return false unless signature
      params = parse_signature_header(signature)
      return false unless params
      return false unless params.algorithm.downcase == "rsa-sha256"
      return false unless valid_digest?(request)

      verify_string_with_openssl(
        signing_string(request, params.headers),
        Base64.decode(params.signature),
        public_key_path
      )
    end

    def self.sign_string(data : String, key_path : String) : String
      output = IO::Memory.new
      errors = IO::Memory.new
      status = Process.run(
        "openssl",
        args: ["dgst", "-sha256", "-sign", key_path],
        input: IO::Memory.new(data),
        output: output,
        error: errors
      )
      raise "openssl sign failed: #{errors.to_s.strip}" unless status.success?
      Base64.strict_encode(output.to_slice)
    end

    def self.sign_string_with_pem(data : String, key_pem : String) : String
      keyfile = File.tempfile("aptok-private-key")
      begin
        keyfile.print(key_pem)
        keyfile.flush
        sign_string(data, keyfile.path)
      ensure
        keyfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
      end
    end

    def self.sign_bytes_ed25519_with_pem(data : Bytes, private_key_pem : String) : String
      keyfile = File.tempfile("aptok-private-key")
      datafile = File.tempfile("aptok-ed25519-data")
      begin
        keyfile.print(private_key_pem)
        keyfile.flush
        datafile.write(data)
        datafile.flush

        output = IO::Memory.new
        errors = IO::Memory.new
        status = Process.run(
          "openssl",
          args: ["pkeyutl", "-sign", "-inkey", keyfile.path, "-rawin", "-in", datafile.path],
          output: output,
          error: errors
        )
        raise "openssl ed25519 sign failed: #{errors.to_s.strip}" unless status.success?
        multibase_base58btc(output.to_slice)
      ensure
        keyfile.close
        datafile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
        File.delete(datafile.path) if File.exists?(datafile.path)
      end
    end

    def self.verify_string?(data : String, signature_b64 : String, public_key_path : String) : Bool
      verify_string_with_openssl(data, Base64.decode(signature_b64), public_key_path)
    rescue
      false
    end

    def self.verify_string_with_pem?(data : String, signature_b64 : String, public_key_pem : String) : Bool
      keyfile = File.tempfile("aptok-public-key")
      begin
        keyfile.print(public_key_pem)
        keyfile.flush
        verify_string?(data, signature_b64, keyfile.path)
      ensure
        keyfile.close
        File.delete(keyfile.path) if File.exists?(keyfile.path)
      end
    end

    def self.canonical_json(value : JsonMap) : String
      canonical_json(Aptok.json(value))
    end

    def self.canonical_json(value : JSON::Any) : String
      canonical_json_value(value, skip_proof: false)
    end

    def self.object_proof_payload(object : JsonMap, proof : JsonMap) : String
      [
        canonical_json_value(Aptok.json(object), skip_proof: true),
        canonical_json_value(Aptok.json(proof_config(object, proof)), skip_proof: false),
      ].join("\n")
    end

    def self.object_proof_hash_data(object : JsonMap, proof : JsonMap) : Bytes
      document = canonical_json_value(Aptok.json(object), skip_proof: true)
      config = canonical_json_value(Aptok.json(proof_config(object, proof)), skip_proof: false)
      data = IO::Memory.new
      data.write(Digest::SHA256.digest(config).to_slice)
      data.write(Digest::SHA256.digest(document).to_slice)
      data.to_slice
    end

    def self.create_object_proof(object : JsonMap, key_pair : ActorKeyPair, options : ObjectProofOptions = ObjectProofOptions.new) : JsonMap
      key_path = key_pair.private_key_path || ""
      key_pem = key_pair.private_key_pem
      raise "missing private key for object proof" if key_path.empty? && key_pem.nil?

      cryptosuite = object_proof_cryptosuite(key_pair, options)
      proof = JsonMap{
        "type"               => Aptok.json(options.proof_type),
        "cryptosuite"        => Aptok.json(cryptosuite),
        "created"            => Aptok.json(options.created),
        "verificationMethod" => Aptok.json(options.verification_method || key_pair.id),
        "proofPurpose"       => Aptok.json(options.proof_purpose),
      }
      signature = case cryptosuite
                  when "eddsa-jcs-2022"
                    raise "missing private key PEM for ed25519 object proof" unless key_pem
                    sign_bytes_ed25519_with_pem(object_proof_hash_data(object, proof), key_pem)
                  when "jcs-rsa-sha256-2026"
                    payload = object_proof_payload(object, proof)
                    key_pem ? sign_string_with_pem(payload, key_pem) : sign_string(payload, key_path)
                  else
                    raise "unsupported object proof cryptosuite: #{cryptosuite}"
                  end
      proof["proofValue"] = Aptok.json(signature)
      proof
    end

    def self.attach_object_proof(object : JsonMap, key_pair : ActorKeyPair, options : ObjectProofOptions = ObjectProofOptions.new) : JsonMap
      signed = object.dup
      signed["proof"] = Aptok.json(create_object_proof(object, key_pair, options))
      signed
    end

    def self.verify_object_proof?(object : JsonMap, key_pair : ActorKeyPair, proof_purpose : String = "assertionMethod") : Bool
      proofs = object_proofs(object)
      proofs.any? do |proof|
        next false unless proof["type"]?.try(&.as_s?) == "DataIntegrityProof"
        cryptosuite = proof["cryptosuite"]?.try(&.as_s?)
        next false unless cryptosuite == "eddsa-jcs-2022" || cryptosuite == "jcs-rsa-sha256-2026"
        next false unless proof["verificationMethod"]?.try(&.as_s?) == key_pair.id
        next false unless proof["proofPurpose"]?.try(&.as_s?) == proof_purpose
        proof_value = proof["proofValue"]?.try(&.as_s?)
        next false unless proof_value

        case cryptosuite
        when "eddsa-jcs-2022"
          verify_ed25519_with_pem?(
            object_proof_hash_data(object, proof),
            proof_value,
            key_pair.public_key_pem
          )
        else
          verify_string_with_pem?(
            object_proof_payload(object, proof),
            proof_value,
            key_pair.public_key_pem
          )
        end
      end
    end

    def self.object_proofs(object : JsonMap) : Array(JsonMap)
      proof = object["proof"]?
      return [] of JsonMap unless proof

      if map = proof.as_h?
        [map]
      elsif list = proof.as_a?
        list.compact_map(&.as_h?)
      else
        [] of JsonMap
      end
    end

    def self.multibase_base58btc(bytes : Bytes) : String
      "z#{base58btc_encode(bytes)}"
    end

    def self.base58btc_encode(bytes : Bytes) : String
      zeroes = 0
      bytes.each do |byte|
        break unless byte == 0
        zeroes += 1
      end

      digits = [0]
      bytes.each do |byte|
        carry = byte.to_i
        digits.size.times do |index|
          value = digits[index] * 256 + carry
          digits[index] = value % 58
          carry = value // 58
        end
        while carry > 0
          digits << carry % 58
          carry //= 58
        end
      end

      encoded = String.build do |io|
        zeroes.times { io << '1' }
        digits.reverse_each { |digit| io << BASE58BTC_ALPHABET[digit] }
      end
      encoded.empty? ? "1" : encoded
    end

    def self.base58btc_decode(value : String) : Bytes?
      raw = value.starts_with?("z") ? value[1..] : value
      bytes = [0]
      raw.each_char do |char|
        carry = BASE58BTC_ALPHABET.index(char)
        return nil unless carry
        bytes.size.times do |index|
          decoded = bytes[index] * 58 + carry
          bytes[index] = decoded & 0xff
          carry = decoded >> 8
        end
        while carry > 0
          bytes << (carry & 0xff)
          carry >>= 8
        end
      end

      raw.each_char do |char|
        break unless char == '1'
        bytes << 0
      end
      Bytes.new(bytes.size) { |index| bytes[bytes.size - index - 1].to_u8 }
    end

    def self.ed25519_public_key_multibase(public_key_pem : String) : String
      public_key = ed25519_public_key_bytes(public_key_pem)
      prefixed = Bytes.new(ED25519_MULTIKEY_PREFIX.size + public_key.size)
      ED25519_MULTIKEY_PREFIX.copy_to(prefixed)
      public_key.copy_to(prefixed + ED25519_MULTIKEY_PREFIX.size)
      multibase_base58btc(prefixed)
    end
  end
end
