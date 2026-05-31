require "http/client"
require "uri"
require "socket"
require "set"
require "digest/sha256"
require "../vocabulary/vocabulary"
require "../signatures/signatures_types"

module Aptok
  alias DocumentLoader = Proc(String, JsonMap?)
  alias DocumentGetProvider = Proc(String, HTTP::Headers, Tuple(Int32, String))
  alias MetadataDocumentGetProvider = Proc(String, HTTP::Headers, Tuple(Int32, String, HTTP::Headers))
  alias MetadataDocumentLoader = Proc(String, RemoteDocument?)
  DEFAULT_USER_AGENT = "aptok/#{VERSION}"

  record RemoteDocument,
    url : String,
    content_type : String?,
    status : Int32,
    headers : Hash(String, String),
    json : JsonMap

  record LookupObjectOptions,
    document_loader : DocumentLoader? = nil,
    cross_origin : String = "reject",
    allow_private_address : Bool = false,
    user_agent : String = DEFAULT_USER_AGENT,
    gateways : Array(String) = [] of String

  record ActorHandleOptions,
    trim_leading_at : Bool = false,
    punycode : Bool = false

  record LookupWebFingerOptions,
    document_loader : DocumentLoader? = nil,
    allow_private_address : Bool = false,
    user_agent : String = DEFAULT_USER_AGENT

  record DocumentCacheOptions,
    ttl : Time::Span? = Time::Span.new(hours: 1),
    prefix : String = "aptok:remote-document"

  record DocumentLoaderOptions,
    allow_private_address : Bool = false,
    user_agent : String = DEFAULT_USER_AGENT

  record TraverseCollectionOptions,
    limit : Int32? = nil,
    suppress_error : Bool = false,
    document_loader : DocumentLoader? = nil

  record ProofKeyLookupOptions,
    cache_ttl : Time::Span? = Time::Span.new(hours: 1)
end
