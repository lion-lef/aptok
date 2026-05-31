require "uri"
require "digest/sha256"
require "random/secure"
require "../http/http"
require "../vocabulary/vocabulary"
require "../store/store"
require "../telemetry"
require "../transport"
require "../remote/remote"
require "../uri_template"
require "set"
require "log"

module Aptok
  class Context
  end

  record FederationOrigin,
    handle_host : String,
    web_origin : String

  class DeliveryState
    property delivered_activity : Bool = false
  end

  record Recipient,
    id : String,
    inbox : String,
    actor_ids : Array(String) = [] of String,
    shared_inbox : String? = nil do
    def synchronization_actor_ids : Array(String)
      actor_ids.empty? ? [id] : actor_ids
    end
  end
  record ExtractedInbox, actor_ids : Array(String), shared_inbox : Bool
  record SentActivity,
    sender_identifier : String,
    recipient : Recipient,
    activity_id : String,
    activity : JsonMap,
    queued : Bool = false,
    queue : String? = nil,
    sent_order : Int32 = 0,
    raw_activity : String? = nil
  record QueuedActivity, sender_identifier : String, recipient : Recipient, activity_id : String, activity : JsonMap
  record OutboxPermanentFailure,
    inbox : String,
    activity : JsonMap,
    error : DeliveryError,
    status_code : Int32,
    actor_ids : Array(String)

  record OutboxDeliveryFailure,
    inbox : String,
    activity : JsonMap,
    error : DeliveryError,
    status_code : Int32?,
    actor_ids : Array(String),
    attempts : Int32

  record SendActivityOptions,
    immediate : Bool = false,
    prefer_shared_inbox : Bool = false,
    exclude_base_uris : Array(String) = [] of String,
    ordering_key : String? = nil,
    sync_collection : Bool = false,
    fanout : String = "auto"

  record ForwardActivityOptions,
    immediate : Bool = false,
    skip_if_unsigned : Bool = false,
    prefer_shared_inbox : Bool = true,
    exclude_base_uris : Array(String) = [] of String,
    exclude_actor_ids : Array(String) = [] of String,
    include_object_addressing : Bool = true,
    ordering_key : String? = nil

  record GetActorOptions,
    tombstone : String = "suppress"

  record GetSignedKeyOptions,
    document_loader : DocumentLoader? = nil,
    context_loader : DocumentLoader? = nil

  record RouteActivityOptions,
    immediate : Bool = false,
    enqueue_options : EnqueueOptions = EnqueueOptions.new,
    trusted : Bool = false,
    document_loader : DocumentLoader? = nil,
    context_loader : DocumentLoader? = nil

  enum RouteActivityResult
    Success
    Enqueued
    UnsupportedActivity
    MissingActor
    AlreadyProcessed
    UnverifiedActivity
    Error

    def handled? : Bool
      success? || enqueued? || error?
    end
  end

  enum RouteOutboxActivityResult
    Success
    UnsupportedActivity
    Error

    def handled? : Bool
      success? || error?
    end
  end

  record SendActivityResult,
    sent : Array(SentActivity) = [] of SentActivity,
    queued : Array(QueuedActivity) = [] of QueuedActivity,
    fanout_queued : Bool = false

  record InboxSignatureOptions,
    require_actor_key_owner : Bool = true,
    challenge_policy : InboxChallengePolicy = InboxChallengePolicy.new

  record InboxChallengePolicy,
    enabled : Bool = false,
    components : Array(String) = ["@method", "@target-uri", "@authority", "content-digest"],
    request_nonce : Bool = false,
    nonce_ttl : Time::Span = Time::Span.new(minutes: 5),
    label : String = "sig1",
    algorithm : String = "rsa-v1_5-sha256",
    tag : String? = nil

  alias ActorDispatcher = Proc(Context, String, JsonMap?)
  alias ObjectDispatcher = Proc(Context, String, JsonMap?)
  alias ParamObjectDispatcher = Proc(Context, Hash(String, String), JsonMap?)
  alias CollectionDispatcher = Proc(Context, String, Array(JsonMap))
  alias CursorCollectionDispatcher = Proc(Context, String, String?, Int32, CollectionPageResult)
  alias NullableCursorCollectionDispatcher = Proc(Context, String, String?, Int32, CollectionPageResult?)
  alias FilteredCursorCollectionDispatcher = Proc(Context, String, String?, Int32, String?, CollectionPageResult?)
  alias ParamCollectionDispatcher = Proc(Context, Hash(String, String), Array(JsonMap))
  alias ParamCursorCollectionDispatcher = Proc(Context, Hash(String, String), String?, Int32, CollectionPageResult?)
  alias ParamFilteredCursorCollectionDispatcher = Proc(Context, Hash(String, String), String?, Int32, String?, CollectionPageResult?)
  alias CollectionCursorCallback = Proc(Context, Hash(String, String), String?)
  alias CollectionCounterCallback = Proc(Context, Hash(String, String), Int32?)
  alias CollectionFilterPredicate = Proc(Context, JsonMap, Bool)
  alias InboxListener = Proc(Context, JsonMap, Nil)
  alias OutboxListener = Proc(Context, JsonMap, Nil)
  alias InboxErrorHandler = Proc(Context, Exception, Nil)
  alias OutboxListenerErrorHandler = Proc(Context, Exception, Nil)
  alias UndeliveredOutboxActivityListener = Proc(Context, JsonMap, Nil)
  alias OutboxErrorHandler = Proc(Context, OutboxDeliveryFailure, Nil)
  alias OutboxPermanentFailureHandler = Proc(Context, OutboxPermanentFailure, Nil)
  alias InboxVerifier = Proc(Request, JsonMap, VerificationResult)
  alias UnverifiedActivityListener = Proc(Context, JsonMap, VerificationResult, Response?)
  alias WebFingerDispatcher = Proc(Context, String, String, JsonMap?)
  alias WebFingerLinksDispatcher = Proc(Context, String, Array(JsonMap))
  alias HandleMapper = Proc(Context, String, String?)
  alias AliasMapping = String | NamedTuple(identifier: String) | NamedTuple(username: String)
  alias AliasMapper = Proc(Context, String, AliasMapping?)
  alias NodeInfoDispatcher = Proc(Context, JsonMap)
  alias KeyPairsDispatcher = Proc(Context, String, Array(ActorKeyPair))
  alias SignatureKeyResolver = Proc(String, ActorKeyPair?)
  alias AuthorizePredicate = Proc(Context, Request, VerificationResult, String?, Hash(String, String), Bool)
  alias OutboxAuthorizePredicate = Proc(Context, String, Bool)
  alias ActivityTransformer = Proc(Context, ActivityTransformContext, JsonMap, JsonMap)
  alias InboxIdempotencyStrategy = Proc(Context, JsonMap, String?)
  alias RequestHandler = Proc(Request, Response)
  alias SharedInboxKey = ActorKeyPair | NamedTuple(identifier: String) | NamedTuple(username: String)
  alias SharedInboxKeyDispatcher = Proc(Context, SharedInboxKey?)

  record ObjectRoute, type : String, path : String, dispatcher : ParamObjectDispatcher
  record CollectionRoute,
    name : String,
    path : String,
    dispatcher : ParamCollectionDispatcher?,
    page_dispatcher : ParamCursorCollectionDispatcher?,
    filtered_page_dispatcher : ParamFilteredCursorCollectionDispatcher?,
    ordered : Bool = true
  record CollectionPageResult,
    items : Array(JsonMap),
    next_cursor : String? = nil,
    prev_cursor : String? = nil,
    total_items : Int32? = nil,
    first_cursor : String? = nil,
    last_cursor : String? = nil

  record VerificationResult,
    verified : Bool,
    reason : String? = nil,
    key_id : String? = nil,
    signer_actor : String? = nil

  record ActivityTransformContext,
    sender_identifier : String,
    sender_actor : String,
    recipients : Array(Recipient),
    collection_name : String? = nil

  record FetchOptions,
    on_not_found : RequestHandler? = nil,
    on_not_acceptable : RequestHandler? = nil,
    on_unauthorized : RequestHandler? = nil,
    context_data : JSON::Any? = nil

  record QueueStartOptions,
    queues : Array(String) = ["inbox", "outbox", "fanout"],
    poll_interval : Time::Span = Time::Span.new(seconds: 1),
    limit : Int32? = nil

  class QueueWorker
    getter fibers : Array(Fiber)
    getter queues : Array(String)

    def initialize(@fibers : Array(Fiber), @stop : Channel(Nil), @queues : Array(String) = [] of String)
      @stopped = false
    end

    def stopped? : Bool
      @stopped
    end

    def includes_queue?(queue : String) : Bool
      @queues.includes?(queue)
    end

    def stop_channel : Channel(Nil)
      @stop
    end

    def add_queue(queue : String, fiber : Fiber) : Nil
      @queues << queue unless @queues.includes?(queue)
      @fibers << fiber
    end

    def stop : Nil
      return if @stopped

      @stopped = true
      @fibers.size.times { @stop.send(nil) }
    end
  end
end
