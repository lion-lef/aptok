module Aptok
  class Federation
    getter origin : String
    getter canonical_origin : String
    getter handle_host : String
    getter sent_activities : Array(SentActivity)
    getter sent_counter : Int32
    getter allow_private_address : Bool
    getter user_agent : String
    getter telemetry : Telemetry
    getter manually_start_queue : Bool
    getter trailing_slash_insensitive : Bool

    @actor_path : String = "/actors/{identifier}"
    @actor_alias_paths = Hash(String, String).new
    @actor_alias_identifiers = Hash(String, String).new
    @inbox_path : String = "/actors/{identifier}/inbox"
    @inbox_path_configured : Bool = false
    @shared_inbox_path : String? = "/inbox"
    @outbox_path : String = "/actors/{identifier}/outbox"
    @outbox_path_configured : Bool = false
    @followers_path : String = "/actors/{identifier}/followers"
    @following_path : String = "/actors/{identifier}/following"
    @liked_path : String = "/actors/{identifier}/liked"
    @featured_path : String = "/actors/{identifier}/featured"
    @featured_tags_path : String = "/actors/{identifier}/featured/tags"
    @nodeinfo_path : String = "/nodeinfo/2.1"
    @actor_dispatcher : ActorDispatcher?
    @object_routes = [] of ObjectRoute
    @collection_routes = [] of CollectionRoute
    @outbox_dispatcher : CollectionDispatcher?
    @outbox_page_dispatcher : NullableCursorCollectionDispatcher?
    @webfinger_dispatcher : WebFingerDispatcher?
    @webfinger_links_dispatcher : WebFingerLinksDispatcher?
    @handle_mapper : HandleMapper?
    @alias_mapper : AliasMapper?
    @nodeinfo_dispatcher : NodeInfoDispatcher?
    @key_pairs_dispatcher : KeyPairsDispatcher?
    @signature_key_resolver : SignatureKeyResolver?
    @actor_authorizer : AuthorizePredicate?
    @object_authorizers = Hash(String, AuthorizePredicate).new
    @collection_authorizers = Hash(String, AuthorizePredicate).new
    @collection_item_types = Hash(String, String).new
    @collection_first_cursor_callbacks = Hash(String, CollectionCursorCallback).new
    @collection_last_cursor_callbacks = Hash(String, CollectionCursorCallback).new
    @collection_counter_callbacks = Hash(String, CollectionCounterCallback).new
    @collection_filter_predicates = Hash(String, CollectionFilterPredicate).new
    @inbox_signature_options : InboxSignatureOptions?
    @inbox_listeners = Hash(String, Array(InboxListener)).new
    @outbox_listeners = Hash(String, Array(OutboxListener)).new
    @inbox_error_handler : InboxErrorHandler?
    @outbox_listener_error_handler : OutboxListenerErrorHandler?
    @undelivered_outbox_activity_listener : UndeliveredOutboxActivityListener?
    @outbox_error_handler : OutboxErrorHandler?
    @outbox_permanent_failure_handler : OutboxPermanentFailureHandler?
    @permanent_failure_status_codes : Set(Int32)
    @outbox_authorizer : OutboxAuthorizePredicate?
    @activity_transformers = [] of ActivityTransformer
    @inbox_verifier : InboxVerifier?
    @unverified_activity_listener : UnverifiedActivityListener?
    @error_handler : Proc(Context, Exception, Nil)?
    @idempotency_ttl : Time::Span?
    @idempotency_strategy : InboxIdempotencyStrategy?
    @outbox_queue : MessageQueue?
    @outbox_queue_name : String = "outbox"
    @outbox_retry_policy : RetryPolicy = RetryPolicy.new
    @inbox_queue : MessageQueue?
    @inbox_queue_name : String = "inbox"
    @inbox_retry_policy : RetryPolicy = RetryPolicy.new
    @fanout_queue : MessageQueue?
    @fanout_queue_name : String = "fanout"
    @fanout_retry_policy : RetryPolicy = RetryPolicy.new
    @fanout_threshold : Int32 = 50
    @shared_inbox_key_dispatcher : SharedInboxKeyDispatcher?
    @document_loader : DocumentLoader
    @context_loader : DocumentLoader
    @context_loader_configured : Bool
    @document_get_provider : DocumentGetProvider?
    @allow_private_address : Bool
    @user_agent : String
    @telemetry : Telemetry
    @manually_start_queue : Bool
    @trailing_slash_insensitive : Bool
    @queue_worker : QueueWorker?

    def initialize(
      @origin : String,
      @transport : Transport = Transport.new(signature_enabled: false),
      @kv : KvStore? = nil,
      @outbox_queue : MessageQueue? = nil,
      @outbox_queue_name : String = "outbox",
      @outbox_retry_policy : RetryPolicy = RetryPolicy.new,
      @inbox_queue : MessageQueue? = nil,
      @inbox_queue_name : String = "inbox",
      @inbox_retry_policy : RetryPolicy = RetryPolicy.new,
      @fanout_queue : MessageQueue? = nil,
      @fanout_queue_name : String = "fanout",
      @fanout_retry_policy : RetryPolicy = RetryPolicy.new,
      @fanout_threshold : Int32 = 50,
      document_loader : DocumentLoader = Remote.default_document_loader,
      context_loader : DocumentLoader? = nil,
      @document_get_provider : DocumentGetProvider? = nil,
      canonical_origin : String? = nil,
      handle_host : String? = nil,
      @allow_private_address : Bool = false,
      @user_agent : String = Remote.default_user_agent,
      @telemetry : Telemetry = NoopTelemetry.new,
      @manually_start_queue : Bool = false,
      permanent_failure_status_codes : Enumerable(Int32) = Set{404, 410},
      @trailing_slash_insensitive : Bool = false
    )
      @origin = validate_origin(@origin)
      @canonical_origin = validate_origin(canonical_origin || @origin)
      @handle_host = normalize_handle_host(handle_host || authority_from_origin(@canonical_origin))
      @document_loader = @document_get_provider ? Remote.default_document_loader(@document_get_provider, allow_private_address: @allow_private_address, user_agent: @user_agent) : document_loader
      @context_loader = context_loader || @document_loader
      @context_loader_configured = !context_loader.nil?
      @permanent_failure_status_codes = permanent_failure_status_codes.to_set
      @idempotency_ttl = Time::Span.new(hours: 24)
      @sent_activities = [] of SentActivity
      @sent_counter = 0
    end

    def self.create(
      origin : String,
      transport : Transport = Transport.new(signature_enabled: false),
      kv : KvStore? = nil,
      outbox_queue : MessageQueue? = nil,
      outbox_queue_name : String = "outbox",
      outbox_retry_policy : RetryPolicy = RetryPolicy.new,
      inbox_queue : MessageQueue? = nil,
      inbox_queue_name : String = "inbox",
      inbox_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_queue : MessageQueue? = nil,
      fanout_queue_name : String = "fanout",
      fanout_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_threshold : Int32 = 50,
      document_loader : DocumentLoader = Remote.default_document_loader,
      context_loader : DocumentLoader? = nil,
      document_get_provider : DocumentGetProvider? = nil,
      canonical_origin : String? = nil,
      handle_host : String? = nil,
      allow_private_address : Bool = false,
      user_agent : String = Remote.default_user_agent,
      telemetry : Telemetry = NoopTelemetry.new,
      manually_start_queue : Bool = false,
      permanent_failure_status_codes : Enumerable(Int32) = Set{404, 410},
      trailing_slash_insensitive : Bool = false
    ) : Federation
      new(origin, transport, kv, outbox_queue, outbox_queue_name, outbox_retry_policy, inbox_queue, inbox_queue_name, inbox_retry_policy, fanout_queue, fanout_queue_name, fanout_retry_policy, fanout_threshold, document_loader, context_loader, document_get_provider, canonical_origin, handle_host, allow_private_address, user_agent, telemetry, manually_start_queue, permanent_failure_status_codes, trailing_slash_insensitive)
    end

    def self.create(
      origin : FederationOrigin,
      transport : Transport = Transport.new(signature_enabled: false),
      kv : KvStore? = nil,
      outbox_queue : MessageQueue? = nil,
      outbox_queue_name : String = "outbox",
      outbox_retry_policy : RetryPolicy = RetryPolicy.new,
      inbox_queue : MessageQueue? = nil,
      inbox_queue_name : String = "inbox",
      inbox_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_queue : MessageQueue? = nil,
      fanout_queue_name : String = "fanout",
      fanout_retry_policy : RetryPolicy = RetryPolicy.new,
      fanout_threshold : Int32 = 50,
      document_loader : DocumentLoader = Remote.default_document_loader,
      context_loader : DocumentLoader? = nil,
      document_get_provider : DocumentGetProvider? = nil,
      allow_private_address : Bool = false,
      user_agent : String = Remote.default_user_agent,
      telemetry : Telemetry = NoopTelemetry.new,
      manually_start_queue : Bool = false,
      permanent_failure_status_codes : Enumerable(Int32) = Set{404, 410},
      trailing_slash_insensitive : Bool = false
    ) : Federation
      create(origin.web_origin, transport, kv, outbox_queue, outbox_queue_name, outbox_retry_policy, inbox_queue, inbox_queue_name, inbox_retry_policy, fanout_queue, fanout_queue_name, fanout_retry_policy, fanout_threshold, document_loader, context_loader, document_get_provider, origin.web_origin, origin.handle_host, allow_private_address, user_agent, telemetry, manually_start_queue, permanent_failure_status_codes, trailing_slash_insensitive)
    end

    def create_context(recipient_identifier : String? = nil, context_data : JSON::Any? = nil) : Context
      Context.new(self, @origin, @transport, recipient_identifier, data: context_data, canonical_origin: @canonical_origin)
    end

    def create_context(request : Request, context_data : JSON::Any? = nil) : Context
      create_context(context_data: context_data).with_inbound_request(request)
    end

    def trailing_slash_insensitive=(value : Bool)
      @trailing_slash_insensitive = value
    end

    def route_path(path : String) : String
      return path unless @trailing_slash_insensitive
      return path if path == "/"
      path.ends_with?("/") ? path.rchop("/") : path
    end

    def match_route(template : String, path : String) : Hash(String, String)?
      unless @trailing_slash_insensitive
        return nil if trailing_slash_mismatch?(template, path)
        return RouteTemplate.new(template).match(path)
      end

      RouteTemplate.new(route_path(template)).match(route_path(path))
    end

    def accepts_webfinger_host?(host : String) : Bool
      normalized = normalize_handle_host(host)
      normalized == @handle_host || normalized == authority_from_origin(@canonical_origin)
    end
  end
end
