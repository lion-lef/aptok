module Aptok
  class Federation
    def set_document_loader(loader : DocumentLoader) : self
      @document_loader = loader
      @document_get_provider = nil
      @context_loader = loader unless @context_loader_configured
      self
    end

    def set_context_loader(loader : DocumentLoader) : self
      @context_loader = loader
      @context_loader_configured = true
      self
    end

    def set_document_get_provider(provider : DocumentGetProvider) : self
      @document_get_provider = provider
      @document_loader = Remote.default_document_loader(provider, allow_private_address: @allow_private_address, user_agent: @user_agent)
      @context_loader = @document_loader unless @context_loader_configured
      self
    end

    def set_telemetry(telemetry : Telemetry) : self
      @telemetry = telemetry
      self
    end

    def manually_start_queue=(value : Bool)
      @manually_start_queue = value
    end

    def start_queue(context_data : JSON::Any? = nil, options : QueueStartOptions = QueueStartOptions.new) : QueueWorker
      if worker = @queue_worker
        @queue_worker = nil if worker.stopped?
      end

      worker = @queue_worker
      unless worker
        fibers = [] of Fiber
        stop = Channel(Nil).new(3)
        worker = QueueWorker.new(fibers, stop)
        @queue_worker = worker
      end
      ctx = create_context(context_data: context_data)
      stop = worker.stop_channel

      if options.queues.includes?("outbox") && @outbox_queue && !worker.includes_queue?("outbox")
        worker.add_queue("outbox", spawn(name: "aptok-outbox-queue") do
          queue_worker_loop(stop, options.poll_interval) do
            ctx.process_queued_activities(limit: options.limit)
          end
        end)
      end
      if options.queues.includes?("inbox") && @inbox_queue && !worker.includes_queue?("inbox")
        worker.add_queue("inbox", spawn(name: "aptok-inbox-queue") do
          queue_worker_loop(stop, options.poll_interval) do
            ctx.process_queued_inbox_activities(limit: options.limit)
          end
        end)
      end
      if options.queues.includes?("fanout") && @fanout_queue && !worker.includes_queue?("fanout")
        worker.add_queue("fanout", spawn(name: "aptok-fanout-queue") do
          queue_worker_loop(stop, options.poll_interval) do
            ctx.process_queued_fanout_activities(limit: options.limit)
          end
        end)
      end

      worker
    end

    def stop_queue : Nil
      @queue_worker.try(&.stop)
      @queue_worker = nil
    end

    def queue_started? : Bool
      !!@queue_worker
    end

    def auto_start_queue(context_data : JSON::Any? = nil) : Nil
      return if @manually_start_queue
      start_queue(context_data)
    end

    def enable_document_cache(ttl : Time::Span? = Time::Span.new(hours: 1), prefix : String = "aptok:remote-document") : self
      @kv ||= MemoryKvStore.new
      @document_loader = Remote.cached_json_document_loader(
        @document_loader,
        @kv.not_nil!,
        DocumentCacheOptions.new(ttl: ttl, prefix: prefix)
      )
      self
    end

    def configure_outbox_queue(
      queue : MessageQueue,
      queue_name : String = "outbox",
      retry_policy : RetryPolicy = RetryPolicy.new
    ) : self
      @outbox_queue = queue
      @outbox_queue_name = queue_name
      @outbox_retry_policy = retry_policy
      self
    end

    def configure_inbox_queue(
      queue : MessageQueue,
      queue_name : String = "inbox",
      retry_policy : RetryPolicy = RetryPolicy.new
    ) : self
      @inbox_queue = queue
      @inbox_queue_name = queue_name
      @inbox_retry_policy = retry_policy
      self
    end

    def configure_fanout_queue(
      queue : MessageQueue,
      queue_name : String = "fanout",
      retry_policy : RetryPolicy = RetryPolicy.new,
      threshold : Int32 = 50
    ) : self
      @fanout_queue = queue
      @fanout_queue_name = queue_name
      @fanout_retry_policy = retry_policy
      @fanout_threshold = threshold
      self
    end

    def set_actor_dispatcher(path : String, dispatcher : ActorDispatcher) : self
      validate_identifier_route!(path, "actor")
      @actor_path = path
      @actor_dispatcher = dispatcher
      self
    end

    def map_actor_alias(path : String, identifier : String) : self
      validate_actor_alias!(path, identifier)
      @actor_alias_paths[path] = identifier
      @actor_alias_identifiers[identifier] = path
      self
    end

    def set_object_dispatcher(type : String, path : String, dispatcher : ObjectDispatcher) : self
      param_dispatcher = ->(ctx : Context, params : Hash(String, String)) do
        identifier = params["identifier"]? || params.values.first? || ""
        dispatcher.call(ctx, identifier)
      end
      set_object_route(type, path, param_dispatcher)
    end

    def set_object_dispatcher(type : String, path : String, dispatcher : ParamObjectDispatcher) : self
      set_object_route(type, path, dispatcher)
    end

    private def set_object_route(type : String, path : String, dispatcher : ParamObjectDispatcher) : self
      validate_path!(path)
      @object_routes.reject! { |route| route.type == type && route.path == path }
      @object_routes << ObjectRoute.new(type, path, dispatcher)
      self
    end

    def set_outbox_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      validate_outbox_route!(path)
      validate_existing_route_path!(@outbox_path, path, "outbox") if @outbox_path_configured
      @outbox_path = path
      @outbox_path_configured = true
      @outbox_dispatcher = dispatcher
      self
    end

    def set_inbox_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      validate_identifier_route!(path, "inbox")
      validate_existing_route_path!(@inbox_path, path, "inbox") if @inbox_path_configured
      set_ordered_collection_dispatcher("inbox", path, dispatcher)
      @inbox_path = path
      @inbox_path_configured = true
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
      set_builtin_collection_dispatcher("followers", path, dispatcher)
      @followers_path = path
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
      set_builtin_collection_dispatcher("followers", path, dispatcher)
      @followers_path = path
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_builtin_collection_dispatcher("followers", path, dispatcher)
      @followers_path = path
      self
    end

    def set_followers_dispatcher(path : String, dispatcher : FilteredCursorCollectionDispatcher) : self
      validate_identifier_route!(path, "followers")
      param_dispatcher = ->(ctx : Context, params : Hash(String, String), cursor : String?, size : Int32, base_url : String?) do
        dispatcher.call(ctx, params["identifier"]? || "", cursor, size, base_url)
      end
      set_filtered_cursor_collection_dispatcher("followers", path, param_dispatcher, ordered: true)
      @followers_path = path
      self
    end

    {% for item in [
                     {method: "following", name: "following", ivar: "following_path"},
                     {method: "liked", name: "liked", ivar: "liked_path"},
                     {method: "featured", name: "featured", ivar: "featured_path"},
                     {method: "featured_tags", name: "featured_tags", ivar: "featured_tags_path"},
                   ] %}
      def set_{{item[:method].id}}_dispatcher(path : String, dispatcher : CollectionDispatcher) : self
        set_builtin_collection_dispatcher({{item[:name]}}, path, dispatcher)
        @{{item[:ivar].id}} = path
        self
      end

      def set_{{item[:method].id}}_dispatcher(path : String, dispatcher : CursorCollectionDispatcher) : self
        set_builtin_collection_dispatcher({{item[:name]}}, path, dispatcher)
        @{{item[:ivar].id}} = path
        self
      end

      def set_{{item[:method].id}}_dispatcher(path : String, dispatcher : ParamCursorCollectionDispatcher) : self
        set_builtin_collection_dispatcher({{item[:name]}}, path, dispatcher)
        @{{item[:ivar].id}} = path
        self
      end
    {% end %}

    private def set_builtin_collection_dispatcher(name : String, path : String, dispatcher : CollectionDispatcher) : self
      validate_identifier_route!(path, name)
      set_ordered_collection_dispatcher(name, path, dispatcher)
    end

    private def set_builtin_collection_dispatcher(name : String, path : String, dispatcher : CursorCollectionDispatcher) : self
      set_builtin_cursor_collection_dispatcher(name, path, dispatcher)
    end

    private def set_builtin_collection_dispatcher(name : String, path : String, dispatcher : ParamCursorCollectionDispatcher) : self
      set_builtin_cursor_collection_dispatcher(name, path, dispatcher)
    end
  end
end
