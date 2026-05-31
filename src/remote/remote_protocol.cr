module Aptok
  module Remote
    def self.get_actor_handle(actor : Vocab::Actor, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
      get_actor_handle(actor.to_json_ld, loader, options)
    end

    def self.get_actor_handle(actor_uri : String, loader : DocumentLoader, options : ActorHandleOptions = ActorHandleOptions.new) : String
      if handle = actor_handle_from_webfinger(actor_uri, loader, options)
        return handle
      end

      raise ArgumentError.new("actor handle not found")
    end

    def self.normalize_actor_handle(handle : String, options : ActorHandleOptions = ActorHandleOptions.new) : String
      normalized = handle.sub(/^@/, "")
      at_index = normalized.index('@')
      raise ArgumentError.new("invalid actor handle") unless at_index && at_index > 0

      username = normalized[0, at_index]
      domain = normalized[(at_index + 1)..]
      raise ArgumentError.new("invalid actor handle") if domain.empty? || domain.includes?('@')

      normalized_domain = normalize_actor_handle_domain(domain, options)
      result = "#{username}@#{normalized_domain}"
      options.trim_leading_at ? result : "@#{result}"
    end

    private PUNYCODE_BASE         =  36
    private PUNYCODE_TMIN         =   1
    private PUNYCODE_TMAX         =  26
    private PUNYCODE_SKEW         =  38
    private PUNYCODE_DAMP         = 700
    private PUNYCODE_INITIAL_BIAS =  72
    private PUNYCODE_INITIAL_N    = 128

    private def self.normalize_actor_handle_domain(domain : String, options : ActorHandleOptions) : String
      labels = domain.downcase.split(".")
      labels.map do |label|
        next label if label.empty?

        options.punycode ? punycode_encode_label(label) : punycode_decode_label(label)
      end.join(".")
    end

    private def self.punycode_encode_label(label : String) : String
      return label if label.each_char.all? { |char| char.ord < 128 }

      codepoints = label.each_char.map(&.ord.to_i).to_a
      output = String.build do |io|
        codepoints.each do |codepoint|
          io << codepoint.chr if codepoint < 128
        end
      end
      basic_count = output.size
      handled = basic_count
      output += "-" if basic_count > 0

      n = PUNYCODE_INITIAL_N
      delta = 0
      bias = PUNYCODE_INITIAL_BIAS

      while handled < codepoints.size
        m = codepoints.select { |codepoint| codepoint >= n }.min
        delta += (m - n) * (handled + 1)
        n = m

        codepoints.each do |codepoint|
          delta += 1 if codepoint < n
          next unless codepoint == n

          q = delta
          k = PUNYCODE_BASE
          loop do
            t = punycode_threshold(k, bias)
            break if q < t

            output += punycode_encode_digit(t + ((q - t) % (PUNYCODE_BASE - t)))
            q = (q - t) // (PUNYCODE_BASE - t)
            k += PUNYCODE_BASE
          end
          output += punycode_encode_digit(q)
          bias = punycode_adapt(delta, handled + 1, handled == basic_count)
          delta = 0
          handled += 1
        end

        delta += 1
        n += 1
      end

      "xn--#{output}"
    end

    private def self.punycode_decode_label(label : String) : String
      return label unless label.starts_with?("xn--")

      input = label[4..]
      output = [] of Int32
      delimiter = input.rindex('-')
      index = 0
      if delimiter
        input[0, delimiter].each_char { |char| output << char.ord.to_i }
        index = delimiter + 1
      end

      n = PUNYCODE_INITIAL_N
      i = 0
      bias = PUNYCODE_INITIAL_BIAS

      while index < input.size
        old_i = i
        w = 1
        k = PUNYCODE_BASE
        loop do
          raise ArgumentError.new("invalid actor handle") if index >= input.size

          digit = punycode_decode_digit(input[index])
          index += 1
          i += digit * w
          t = punycode_threshold(k, bias)
          break if digit < t

          w *= PUNYCODE_BASE - t
          k += PUNYCODE_BASE
        end

        output_size = output.size + 1
        bias = punycode_adapt(i - old_i, output_size, old_i == 0)
        n += i // output_size
        insert_at = i % output_size
        output.insert(insert_at, n)
        i = insert_at + 1
      end

      String.build do |io|
        output.each { |codepoint| io << codepoint.chr }
      end
    end

    private def self.punycode_threshold(k : Int32, bias : Int32) : Int32
      return PUNYCODE_TMIN if k <= bias
      return PUNYCODE_TMAX if k >= bias + PUNYCODE_TMAX

      k - bias
    end

    private def self.punycode_adapt(delta : Int32, num_points : Int32, first_time : Bool) : Int32
      delta = first_time ? delta // PUNYCODE_DAMP : delta // 2
      delta += delta // num_points
      k = 0
      while delta > ((PUNYCODE_BASE - PUNYCODE_TMIN) * PUNYCODE_TMAX) // 2
        delta //= PUNYCODE_BASE - PUNYCODE_TMIN
        k += PUNYCODE_BASE
      end
      k + (((PUNYCODE_BASE - PUNYCODE_TMIN + 1) * delta) // (delta + PUNYCODE_SKEW))
    end

    private def self.punycode_encode_digit(digit : Int32) : String
      (digit < 26 ? ('a'.ord + digit) : ('0'.ord + digit - 26)).chr.to_s
    end

    private def self.punycode_decode_digit(char : Char) : Int32
      case char
      when 'a'..'z'
        char.ord - 'a'.ord
      when '0'..'9'
        char.ord - '0'.ord + 26
      else
        raise ArgumentError.new("invalid actor handle")
      end
    end

    def self.verify_activity_object(activity : JsonMap, loader : DocumentLoader, options : LookupObjectOptions = LookupObjectOptions.new) : JsonMap?
      object = activity["object"]?
      parent_origin = object_origin(activity["id"]?) || object_origin(activity["actor"]?)
      object ? verify_object_reference(object, loader, parent_origin, options) : nil
    end

    def self.resolve_proof_key(
      verification_method : String,
      loader : DocumentLoader,
      cache : KvStore? = nil,
      options : ProofKeyLookupOptions = ProofKeyLookupOptions.new
    ) : ActorKeyPair?
      if key_pair = did_key_proof_key(verification_method)
        return key_pair
      end

      cached = cached_proof_key(verification_method, cache)
      return cached if cached

      document = loader.call(document_url(verification_method))
      return nil unless document

      key = proof_key_from_document(verification_method, document, loader, Set{document_url(verification_method)})
      if key && cache
        cache.set(proof_key_cache_key(verification_method), proof_key_cache_value(key), options.cache_ttl)
      end
      key
    rescue
      nil
    end

    private def self.did_key_proof_key(verification_method : String) : ActorKeyPair?
      document_id, fragment = verification_method.split("#", 2)
      return nil unless document_id.starts_with?("did:key:")

      public_key_multibase = fragment || document_id["did:key:".size..]
      return nil unless public_key_multibase.starts_with?("z")

      public_key_pem = Signatures.ed25519_public_key_pem_from_multibase(public_key_multibase)
      return nil unless public_key_pem

      ActorKeyPair.new(
        id: verification_method,
        owner: document_id,
        public_key_pem: public_key_pem,
        algorithm: "ed25519"
      )
    rescue
      nil
    end

    def self.verify_object_reference(
      object_or_id : JSON::Any,
      loader : DocumentLoader,
      parent_origin : String? = nil,
      options : LookupObjectOptions = LookupObjectOptions.new
    ) : JsonMap?
      if object = object_or_id.as_h?
        return object if parent_origin.nil? || object_origin(object_or_id) == parent_origin

        id = object["id"]?.try(&.as_s?) || object["@id"]?.try(&.as_s?)
        return nil unless id
        looked_up = lookup_object(id, loader, options)
        return nil unless looked_up
        return looked_up if same_id?(id, looked_up)
        return looked_up if options.cross_origin == "trust"
        raise ArgumentError.new("verified object id does not match embedded object id") if options.cross_origin == "raise"
        nil
      elsif id = object_or_id.as_s?
        lookup_object(id, loader, options)
      else
        nil
      end
    end

    def self.traverse_collection(collection : JsonMap, loader : DocumentLoader, limit : Int32? = nil) : Array(JsonMap)
      traverse_collection(collection, loader, TraverseCollectionOptions.new(limit: limit))
    end

    def self.traverse_collection(collection : Vocab::Collection, loader : DocumentLoader, limit : Int32? = nil) : Array(Vocab::Object)
      traverse_collection(collection, loader, TraverseCollectionOptions.new(limit: limit))
    end

    def self.traverse_collection(collection : JsonMap, loader : DocumentLoader, options : TraverseCollectionOptions) : Array(JsonMap)
      results = [] of JsonMap
      current = collection
      visited = Set(String).new
      limit = options.limit

      if first_url = collection_link(collection, "first")
        visited << first_url
        loaded = begin
          loader.call(first_url)
        rescue ex
          raise ex unless options.suppress_error
          nil
        end
        return results unless loaded
        current = loaded
      end

      loop do
        begin
          append_collection_items(current, loader, results, options)
        rescue ex
          raise ex unless options.suppress_error
        end
        break if limit && results.size >= limit

        next_url = collection_link(current, "next")
        break unless next_url
        break if visited.includes?(next_url)

        visited << next_url
        loaded = begin
          loader.call(next_url)
        rescue ex
          raise ex unless options.suppress_error
          nil
        end
        break unless loaded
        current = loaded
      end

      limit ? results.first(limit) : results
    end

    def self.traverse_collection(collection : Vocab::Collection, loader : DocumentLoader, options : TraverseCollectionOptions) : Array(Vocab::Object)
      traverse_collection(collection.to_json_ld, loader, options).map do |item|
        Vocab::Object.from_json_ld(item)
      end
    end
  end
end
