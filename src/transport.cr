require "http/client"
require "http/headers"
require "base64"
require "digest/sha256"
require "uri"
require "set"
require "./vocabulary/vocabulary"
require "./signatures/signatures"

module Aptok
  # Generic payload for content to publish into ActivityPub objects.
  record PublishRequest,
    title : String,
    content : String,
    assignee : String?,
    attributed_to : String?

  record DeliveryConfig,
    inbox : String,
    actor : String,
    target : String?,
    headers : Hash(String, String) = Hash(String, String).new,
    actor_ids : Array(String) = [] of String

  record MarketplaceOfferRequest,
    name : String,
    item : JsonMap,
    price : String?,
    currency : String?

  record PostResponse,
    status_code : Int32,
    body : String,
    headers : HTTP::Headers = HTTP::Headers.new

  class DeliveryError < Exception
    getter status_code : Int32?

    def initialize(message : String, @status_code : Int32? = nil)
      super(message)
    end
  end

  # Shared transport for ActivityPub-style egress payloads.
  # It builds a Create activity and sends it to the configured inbox.
  class Transport
    alias HeadersProvider = Proc(String, String, String, Hash(String, String))
    alias PostProvider = Proc(String, HTTP::Headers, String, Tuple(Int32, String))
    alias DetailedPostProvider = Proc(String, HTTP::Headers, String, PostResponse)

    def initialize(
      @object_type : String = "Note",
      @signature_enabled : Bool = false,
      @signature_key_path : String = "",
      @signature_key_id : String = "",
      @headers_provider : HeadersProvider? = nil,
      @post_provider : PostProvider? = nil,
      @detailed_post_provider : DetailedPostProvider? = nil
    )
    end

    def build_create_activity(req : PublishRequest, delivery : DeliveryConfig) : JsonMap
      object = build_task_object(req, delivery)
      Aptok.create(
        "#{delivery.actor}/activities/create-#{Random::Secure.hex(10)}",
        delivery.actor,
        object,
        activity_recipients(delivery, req),
        delivery.target
      )
    end

    def build_forgefed_ticket_create(req : PublishRequest, delivery : DeliveryConfig) : JsonMap
      suffix = Random::Secure.hex(10)
      ticket = Aptok.forgefed_ticket(
        "#{delivery.actor}/tickets/#{suffix}",
        req.title,
        req.content,
        req.assignee,
        req.attributed_to
      )
      Aptok.create(
        "#{delivery.actor}/activities/create-ticket-#{suffix}",
        delivery.actor,
        ticket,
        activity_recipients(delivery, req),
        delivery.target
      )
    end

    def build_marketplace_offer(req : MarketplaceOfferRequest, delivery : DeliveryConfig) : JsonMap
      suffix = Random::Secure.hex(10)
      recipients = [PUBLIC_COLLECTION]
      if target = delivery.target
        recipients << target unless target.empty?
      end
      Aptok.marketplace_offer(
        "#{delivery.actor}/offers/#{suffix}",
        delivery.actor,
        req.item,
        req.name,
        req.price,
        req.currency,
        recipients
      )
    end

    def deliver!(delivery : DeliveryConfig, activity : JsonMap, key_pair : ActorKeyPair? = nil) : String
      payload = activity.to_json
      headers = HTTP::Headers{
        "Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE,
        "Accept"       => FEDERATION_JSONLD_CONTENT_TYPE,
      }
      delivery.headers.each { |key, value| headers[key] = value }

      signature_headers = build_signature_headers("post", delivery.inbox, payload, key_pair)
      signature_headers.each { |k, v| headers[k] = v }

      response = post_payload(delivery.inbox, headers, payload)
      response = retry_accept_signature_challenge(delivery, payload, headers, response, key_pair)
      unless response.status_code >= 200 && response.status_code < 300
        message = response.body.empty? ? "activitypub inbox delivery failed" : "activitypub inbox delivery failed: #{response.body}"
        raise DeliveryError.new(message, response.status_code)
      end

      activity["id"]?.try(&.as_s?) || ""
    rescue ex : DeliveryError
      raise ex
    rescue ex
      raise DeliveryError.new("activitypub inbox delivery failed: #{ex.message}")
    end

    def forward!(
      delivery : DeliveryConfig,
      activity : JsonMap,
      payload : String,
      source_headers : Hash(String, String) = Hash(String, String).new,
      key_pair : ActorKeyPair? = nil
    ) : String
      headers = HTTP::Headers{
        "Content-Type" => source_headers["Content-Type"]? || source_headers["content-type"]? || FEDERATION_JSONLD_CONTENT_TYPE,
        "Accept"       => FEDERATION_JSONLD_CONTENT_TYPE,
      }
      signature_headers = build_signature_headers("post", delivery.inbox, payload, key_pair)
      signature_headers.each { |k, v| headers[k] = v }

      response = post_payload(delivery.inbox, headers, payload)
      response = retry_accept_signature_challenge(delivery, payload, headers, response, key_pair)
      unless response.status_code >= 200 && response.status_code < 300
        message = response.body.empty? ? "activitypub inbox forwarding failed" : "activitypub inbox forwarding failed: #{response.body}"
        raise DeliveryError.new(message, response.status_code)
      end

      activity["id"]?.try(&.as_s?) || ""
    rescue ex : DeliveryError
      raise ex
    rescue ex
      raise DeliveryError.new("activitypub inbox forwarding failed: #{ex.message}")
    end

    private def post_payload(url : String, headers : HTTP::Headers, payload : String) : PostResponse
      if provider = @detailed_post_provider
        return provider.call(url, headers, payload)
      end
      if provider = @post_provider
        status_code, body = provider.call(url, headers, payload)
        return PostResponse.new(status_code, body)
      end
      response = HTTP::Client.post(url, headers: headers, body: payload)
      PostResponse.new(response.status_code, response.body, response.headers)
    end

    private def retry_accept_signature_challenge(delivery : DeliveryConfig, payload : String, original_headers : HTTP::Headers, response : PostResponse, key_pair : ActorKeyPair?) : PostResponse
      return response unless response.status_code == 401
      challenge_header = response.headers["Accept-Signature"]? || response.headers["accept-signature"]?
      return response unless challenge_header
      signing_key = key_pair || static_key_pair
      return response unless signing_key
      challenge = Signatures.parse_accept_signatures(challenge_header).find do |candidate|
        compatible_accept_signature_challenge?(candidate, signing_key)
      end
      return response unless challenge

      retry_headers = copy_headers(original_headers)
      signature_headers = Signatures.rfc9421_rsa_sha256_headers(
        "post",
        delivery.inbox,
        payload,
        signing_key,
        Rfc9421Options.new(
          label: challenge.label,
          components: challenge.components,
          key_id: signing_key.id,
          nonce: challenge.nonce,
          tag: challenge.tag,
          expires: challenge.expires ? Time.utc.to_unix + 300 : nil
        )
      )
      signature_headers.each { |key, value| retry_headers[key] = value }
      post_payload(delivery.inbox, retry_headers, payload)
    end

    private def compatible_accept_signature_challenge?(challenge : AcceptSignatureChallenge, signing_key : ActorKeyPair) : Bool
      return false if challenge.algorithm && challenge.algorithm.not_nil!.downcase != "rsa-v1_5-sha256"
      return false if challenge.key_id && challenge.key_id != signing_key.id
      return false if challenge.components.any? { |component| component.split(";", 2).first == "@status" }

      true
    end

    private def copy_headers(headers : HTTP::Headers) : HTTP::Headers
      copied = HTTP::Headers.new
      headers.each do |key, values|
        values.each { |value| copied.add(key, value) }
      end
      copied
    end

    private def build_task_object(req : PublishRequest, delivery : DeliveryConfig) : JsonMap
      properties = JsonMap{
        "name"      => Aptok.json(req.title),
        "content"   => Aptok.json(req.content),
        "published" => Aptok.json(Aptok.now),
        "to"        => Aptok.json(activity_recipients(delivery, req)),
      }
      properties["attributedTo"] = Aptok.json(req.attributed_to) if req.attributed_to
      properties["assignee"] = Aptok.json(req.assignee) if req.assignee
      Aptok.object(@object_type, "#{delivery.actor}/objects/#{Random::Secure.hex(10)}", properties)
    end

    private def activity_recipients(delivery : DeliveryConfig, req : PublishRequest) : Array(String)
      recipients = Set(String).new
      recipients << "https://www.w3.org/ns/activitystreams#Public"
      if attributed_to = req.attributed_to
        recipients << attributed_to unless attributed_to.empty?
      end
      if assignee = req.assignee
        recipients << assignee unless assignee.empty?
      end
      if target = delivery.target
        recipients << target unless target.empty?
      end
      recipients.to_a
    end

    private def build_signature_headers(method : String, url : String, body : String, key_pair : ActorKeyPair? = nil) : Hash(String, String)
      return {} of String => String unless @signature_enabled || key_pair
      return @headers_provider.not_nil!.call(method, url, body) if @headers_provider
      signing_key = key_pair || static_key_pair.not_nil!
      Signatures.rsa_sha256_headers(method, url, body, signing_key)
    end

    private def static_key_pair : ActorKeyPair?
      return nil unless @signature_enabled
      return nil if @signature_key_id.empty? || @signature_key_path.empty?

      ActorKeyPair.new(@signature_key_id, "", "", @signature_key_path)
    end

    private def sign_string(data : String, key_path : String) : String
      Signatures.sign_string(data, key_path)
    rescue ex
      raise DeliveryError.new(ex.message || "openssl sign failed")
    end

    private def sign_string_with_pem(data : String, key_pem : String) : String
      Signatures.sign_string_with_pem(data, key_pem)
    rescue ex
      raise DeliveryError.new(ex.message || "openssl sign failed")
    end
  end
end
