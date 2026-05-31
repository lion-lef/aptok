require "base64"
require "digest/sha256"
require "uri"
require "../http/http"
require "../vocabulary/vocabulary"

module Aptok
  record ActorKeyPair,
    id : String,
    owner : String,
    public_key_pem : String,
    private_key_path : String? = nil,
    private_key_pem : String? = nil,
    algorithm : String = "rsa-sha256"

  def self.public_key(key_pair : ActorKeyPair) : JsonMap
    if key_pair.algorithm.downcase == "ed25519"
      Aptok.multikey(
        key_pair.id,
        key_pair.owner,
        Signatures.ed25519_public_key_multibase(key_pair.public_key_pem)
      )
    else
      Aptok.public_key(key_pair.id, key_pair.owner, key_pair.public_key_pem)
    end
  end

  record SignatureParams,
    key_id : String,
    algorithm : String,
    headers : Array(String),
    signature : String

  record MessageSignatureParams,
    label : String,
    key_id : String,
    algorithm : String,
    components : Array(String),
    signature : String,
    signature_params : String,
    created : Int64? = nil,
    expires : Int64? = nil,
    nonce : String? = nil,
    tag : String? = nil

  record Rfc9421Options,
    label : String = "sig1",
    components : Array(String) = ["@method", "@target-uri", "@authority", "host", "date", "content-digest"],
    created : Int64 = Time.utc.to_unix,
    key_id : String? = nil,
    algorithm : String = "rsa-v1_5-sha256",
    nonce : String? = nil,
    tag : String? = nil,
    expires : Int64? = nil

  record Rfc9421VerifyOptions,
    required_components : Array(String) = ["@method", "@target-uri", "host", "date"],
    max_clock_skew : Time::Span = Time::Span.new(minutes: 5),
    now : Int64 = Time.utc.to_unix

  record AcceptSignatureChallenge,
    label : String,
    components : Array(String),
    algorithm : String? = nil,
    key_id : String? = nil,
    nonce : String? = nil,
    tag : String? = nil,
    expires : Bool = false

  record ObjectProofOptions,
    created : String = Aptok.now,
    verification_method : String? = nil,
    proof_purpose : String = "assertionMethod",
    proof_type : String = "DataIntegrityProof",
    cryptosuite : String = "eddsa-jcs-2022"
end
