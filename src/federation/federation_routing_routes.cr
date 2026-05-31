module Aptok
  class Federation
    def authorize_outbox?(ctx : Context, identifier : String) : Bool
      authorizer = @outbox_authorizer
      return true unless authorizer
      authorizer.call(ctx, identifier)
    end

    def verify_inbox_request(request : Request, activity : JsonMap) : VerificationResult
      verifier = @inbox_verifier
      return verifier.call(request, activity) if verifier
      verify_signed_request(request, activity)
    end

    def verify_signed_request(request : Request) : VerificationResult
      resolver = @signature_key_resolver
      options = @inbox_signature_options
      return VerificationResult.new(true) unless options
      return VerificationResult.new(false, "signature key resolver is not configured") unless resolver

      if message_params = Signatures.parse_message_signature(request)
        key_pair = resolver.call(message_params.key_id)
        return VerificationResult.new(false, "signature key not found", message_params.key_id) unless key_pair
        return VerificationResult.new(false, "unsupported signature algorithm", message_params.key_id, key_pair.owner) unless message_params.algorithm.downcase == "rsa-v1_5-sha256"
        return VerificationResult.new(false, "invalid content digest", message_params.key_id, key_pair.owner) unless Signatures.valid_content_digest?(request)
        return VerificationResult.new(false, "invalid signature nonce", message_params.key_id, key_pair.owner) unless valid_challenge_nonce?(message_params)

        if Signatures.verify_rfc9421_rsa_sha256?(request, request_target_url(request), key_pair, message_params.label)
          return VerificationResult.new(true, key_id: message_params.key_id, signer_actor: key_pair.owner)
        end
        return VerificationResult.new(false, "invalid signature", message_params.key_id, key_pair.owner)
      end

      signature_header = Signatures.header(request, "Signature")
      return VerificationResult.new(false, "missing signature") unless signature_header

      params = Signatures.parse_signature_header(signature_header)
      return VerificationResult.new(false, "invalid signature header") unless params

      key_pair = resolver.call(params.key_id)
      return VerificationResult.new(false, "signature key not found", params.key_id) unless key_pair
      return VerificationResult.new(false, "unsupported signature algorithm", params.key_id, key_pair.owner) unless params.algorithm.downcase == "rsa-sha256"
      return VerificationResult.new(false, "invalid digest", params.key_id, key_pair.owner) unless Signatures.valid_digest?(request)

      if Signatures.verify_rsa_sha256?(request, key_pair)
        VerificationResult.new(true, key_id: params.key_id, signer_actor: key_pair.owner)
      else
        VerificationResult.new(false, "invalid signature", params.key_id, key_pair.owner)
      end
    end

    def signed_key_owner(request : Request) : String?
      result = verify_signed_request(request)
      result.verified ? result.signer_actor : nil
    end

    def signed_key(request : Request) : ActorKeyPair?
      result = verify_signed_request(request)
      return nil unless result.verified

      key_id = result.key_id
      resolver = @signature_key_resolver
      key_id && resolver ? resolver.call(key_id) : nil
    end

    def verify_signed_request(request : Request, activity : JsonMap) : VerificationResult
      result = verify_object_proof(activity)
      result = verify_signed_request(request) unless result.verified || result.reason == "object proof attribution mismatch"
      return result unless result.verified

      options = @inbox_signature_options
      return result unless options && options.require_actor_key_owner

      actor_id = activity_actor_id(activity)
      return VerificationResult.new(false, "activity actor is missing", result.key_id, result.signer_actor) unless actor_id
      signer_actor = result.signer_actor
      return result if signer_actor && proof_owner_matches?(signer_actor, actor_id)

      VerificationResult.new(false, "signature key owner does not match activity actor", result.key_id, result.signer_actor)
    end

    private def verify_object_proof(activity : JsonMap) : VerificationResult
      options = @inbox_signature_options
      return VerificationResult.new(false, "object proof verification is not configured") unless options

      proofs = Signatures.object_proofs(activity)
      return VerificationResult.new(false, "missing object proof") if proofs.empty?

      valid_key_pairs = [] of ActorKeyPair
      proofs.each do |proof|
        verification_method = proof["verificationMethod"]?.try(&.as_s?)
        next unless verification_method
        key_pair = resolve_proof_key(verification_method)
        next unless key_pair
        if Signatures.verify_object_proof?(activity, key_pair)
          valid_key_pairs << key_pair
        end
      end
      return VerificationResult.new(false, "invalid object proof") if valid_key_pairs.empty?

      owners = valid_key_pairs.map(&.owner).to_set
      required_owners = attributed_identities(activity).to_set
      missing = required_owners.reject do |required|
        owners.any? { |owner| proof_owner_matches?(owner, required) }
      end
      unless missing.empty?
        return VerificationResult.new(
          false,
          "object proof attribution mismatch",
          valid_key_pairs.first.id,
          valid_key_pairs.first.owner
        )
      end

      key_pair = valid_key_pairs.first
      VerificationResult.new(true, key_id: key_pair.id, signer_actor: key_pair.owner)
    end

    private def proof_owner_matches?(owner : String, required : String) : Bool
      return true if owner == required
      return false unless owner.starts_with?("did:")

      Aptok.same_resource_origin?(owner, required)
    end

    private def attributed_identities(object : JsonMap) : Array(String)
      identities = [] of String
      collect_identity_value(object["actor"]?, identities)
      collect_identity_value(object["attributedTo"]?, identities)
      collect_nested_object_identities(object["object"]?, identities)
      collect_nested_object_identities(object["items"]?, identities)
      collect_nested_object_identities(object["orderedItems"]?, identities)
      identities.uniq
    end

    private def collect_nested_object_identities(value : JSON::Any?, identities : Array(String)) : Nil
      return unless value

      if nested = value.as_h?
        attributed_identities(nested.as(JsonMap)).each { |identity| identities << identity }
      elsif array = value.as_a?
        array.each { |item| collect_nested_object_identities(item, identities) }
      end
    end

    private def collect_identity_value(value : JSON::Any?, identities : Array(String)) : Nil
      return unless value

      if string = value.as_s?
        identities << string
      elsif object = value.as_h?
        id = object["id"]?.try(&.as_s?)
        identities << id if id
      elsif array = value.as_a?
        array.each { |item| collect_identity_value(item, identities) }
      end
    end

    private def resolve_proof_key(verification_method : String) : ActorKeyPair?
      if resolver = @signature_key_resolver
        key_pair = resolver.call(verification_method)
        return key_pair if key_pair
      end

      Remote.resolve_proof_key(verification_method, @document_loader, @kv)
    end

    def notify_unverified_activity(ctx : Context, activity : JsonMap, verification : VerificationResult) : Response?
      @unverified_activity_listener.try(&.call(ctx, activity, verification))
    end

    def challenge_headers(verification : VerificationResult) : Hash(String, String)
      options = @inbox_signature_options
      return Hash(String, String).new unless options
      policy = options.challenge_policy
      return Hash(String, String).new unless policy.enabled
      return Hash(String, String).new if verification.reason == "signature key owner does not match activity actor"

      nonce = nil.as(String?)
      if policy.request_nonce
        nonce = Random::Secure.hex(16)
        @kv ||= MemoryKvStore.new
        @kv.try(&.set("aptok:accept-signature:nonce:#{nonce}", "1", policy.nonce_ttl))
      end
      {
        "Accept-Signature" => accept_signature_challenge(policy, nonce),
        "Cache-Control"    => "no-store",
        "Vary"             => "Accept, Signature",
      }
    end

    private def authorize_fetch?(
      authorizer : AuthorizePredicate?,
      ctx : Context,
      request : Request,
      identifier : String?,
      params : Hash(String, String)
    ) : Bool
      return true unless authorizer
      authorizer.call(ctx, request, verify_signed_request(request), identifier, params)
    end

    private def request_target_url(request : Request) : String
      path = request.path.empty? ? "/" : request.path
      "#{@origin}#{path}"
    end

    private def accept_signature_challenge(policy : InboxChallengePolicy, nonce : String?) : String
      components = policy.components.map { |component| %("#{component}") }.join(" ")
      value = "#{policy.label}=(#{components});alg=\"#{policy.algorithm}\""
      value += %(;nonce="#{nonce}") if nonce
      if tag = policy.tag
        value += %(;tag="#{tag}")
      end
      value
    end

    private def valid_challenge_nonce?(params : MessageSignatureParams) : Bool
      options = @inbox_signature_options
      return true unless options && options.challenge_policy.request_nonce
      nonce = params.nonce
      return false unless nonce
      kv = @kv
      return false unless kv

      key = "aptok:accept-signature:nonce:#{nonce}"
      present = !!kv.get(key)
      kv.delete(key) if present
      present
    end

    def enable_idempotency(ttl : Time::Span = Time::Span.new(hours: 24), strategy : String = "per-inbox") : Nil
      @kv ||= MemoryKvStore.new
      @idempotency_ttl = ttl
      @idempotency_strategy = built_in_idempotency_strategy(strategy)
    end

    def enable_idempotency(strategy : String, ttl : Time::Span = Time::Span.new(hours: 24)) : Nil
      enable_idempotency(ttl, strategy)
    end

    def enable_idempotency(ttl : Time::Span, strategy : InboxIdempotencyStrategy) : Nil
      @kv ||= MemoryKvStore.new
      @idempotency_ttl = ttl
      @idempotency_strategy = strategy
    end

    def add_inbox_listener(type : String, listener : InboxListener) : Nil
      type = listener_type_name(type)
      @inbox_listeners[type] ||= [] of InboxListener
      @inbox_listeners[type] << listener
    end

    def inbox_listeners_for(activity : JsonMap) : Array(InboxListener)
      matching_listeners(@inbox_listeners, activity)
    end

    def set_inbox_error_handler(handler : InboxErrorHandler) : self
      @inbox_error_handler = handler
      self
    end

    def notify_inbox_error(ctx : Context, error : Exception) : Nil
      notify_error_handler("inbox", @inbox_error_handler, ctx, error)
    end

    def add_outbox_listener(type : String, listener : OutboxListener) : Nil
      type = listener_type_name(type)
      @outbox_listeners[type] ||= [] of OutboxListener
      @outbox_listeners[type] << listener
    end

    def outbox_listeners_for(activity : JsonMap) : Array(OutboxListener)
      matching_listeners(@outbox_listeners, activity)
    end
  end
end
