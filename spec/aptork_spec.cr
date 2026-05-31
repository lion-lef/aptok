require "./spec_helper"

# A dependency-free, in-memory `SqlConnection` used to exercise `SqlKvStore`
# and `SqlMessageQueue` without a real database. It dispatches on the
# `/* aptork:<marker> */` comment that the stores embed at the start of every
# statement (real engines ignore the comment), so it tracks the stores'
# control flow and bound parameters rather than parsing arbitrary SQL. The real
# SQL is verified separately against SQLite in spec/drivers/sqlite_driver.cr.
class FakeSqlConnection
  include Aptork::SqlConnection

  # key => {value, expires_at_ms}
  @kv = Hash(String, Tuple(String, Int64?)).new
  @queue = [] of Hash(String, Aptork::SqlValue)

  def execute(sql : String, args : Array(Aptork::SqlValue)) : Int64
    case marker(sql)
    when "kv_migrate", "queue_migrate"
      0_i64
    when "kv_set"
      key = str(args[0]); @kv[key] = {str(args[1]), i64?(args[2])}; 1_i64
    when "kv_delete"
      @kv.delete(str(args[0])) ? 1_i64 : 0_i64
    when "kv_cas_insert"
      key, value, expires, now = str(args[0]), str(args[1]), i64?(args[2]), i64(args[3])
      existing = @kv[key]?
      if existing.nil? || expired?(existing[1], now)
        @kv[key] = {value, expires}; 1_i64
      else
        0_i64
      end
    when "kv_cas_update"
      value, expires, key, expected, now = str(args[0]), i64?(args[1]), str(args[2]), str(args[3]), i64(args[4])
      existing = @kv[key]?
      if existing && existing[0] == expected && !expired?(existing[1], now)
        @kv[key] = {value, expires}; 1_i64
      else
        0_i64
      end
    when "queue_insert"
      @queue << {
        "id"           => args[0],
        "queue"        => args[1],
        "payload"      => args[2],
        "attempts"     => args[3],
        "available_at" => args[4],
        "ordering_key" => args[5],
        "dead"         => args[6],
      }
      1_i64
    when "queue_claim"
      id = str(args[0])
      before = @queue.size
      @queue.reject! { |row| str(row["id"]) == id }
      (before - @queue.size).to_i64
    else
      raise "FakeSqlConnection: unhandled execute marker #{marker(sql).inspect}"
    end
  end

  def query(sql : String, args : Array(Aptork::SqlValue)) : Array(Array(Aptork::SqlValue))
    case marker(sql)
    when "kv_get"
      row = @kv[str(args[0])]?
      row ? [[row[0].as(Aptork::SqlValue), row[1].as(Aptork::SqlValue)]] : [] of Array(Aptork::SqlValue)
    when "kv_list"
      @kv.keys.sort!.map { |k| [k.as(Aptork::SqlValue), @kv[k][0].as(Aptork::SqlValue), @kv[k][1].as(Aptork::SqlValue)] }
    when "kv_list_prefix"
      prefix = unescape_like(str(args[0]))
      @kv.keys.select(&.starts_with?(prefix)).sort!.map do |k|
        [k.as(Aptork::SqlValue), @kv[k][0].as(Aptork::SqlValue), @kv[k][1].as(Aptork::SqlValue)]
      end
    when "queue_depth"
      count = @queue.count { |r| str(r["queue"]) == str(args[0]) && i64(r["dead"]) == 0 }
      [[count.to_i64.as(Aptork::SqlValue)]]
    when "queue_ready_count"
      now = i64(args[1])
      count = @queue.count { |r| str(r["queue"]) == str(args[0]) && i64(r["dead"]) == 0 && i64(r["available_at"]) <= now }
      [[count.to_i64.as(Aptork::SqlValue)]]
    when "queue_ready"
      ready_rows(str(args[0]), i64(args[1]), i64(args[2]).to_i)
    when "queue_next"
      ready_rows(str(args[0]), i64(args[1]), 1)
    when "queue_dead"
      queue = str(args[0])
      sort_queue(@queue.select { |r| str(r["queue"]) == queue && i64(r["dead"]) == 1 }).map { |r| project(r) }
    else
      raise "FakeSqlConnection: unhandled query marker #{marker(sql).inspect}"
    end
  end

  private def ready_rows(queue : String, now : Int64, limit : Int32) : Array(Array(Aptork::SqlValue))
    rows = @queue.select { |r| str(r["queue"]) == queue && i64(r["dead"]) == 0 && i64(r["available_at"]) <= now }
    sort_queue(rows).first(limit).map { |r| project(r) }
  end

  private def sort_queue(rows)
    rows.sort_by { |r| {i64(r["available_at"]), str(r["id"])} }
  end

  private def project(row : Hash(String, Aptork::SqlValue)) : Array(Aptork::SqlValue)
    ["id", "queue", "payload", "attempts", "available_at", "ordering_key"].map { |c| row[c] }
  end

  private def marker(sql : String) : String
    if match = sql.match(/aptork:(\w+)/)
      match[1]
    else
      raise "FakeSqlConnection: no marker in #{sql.inspect}"
    end
  end

  private def expired?(expires_at : Int64?, now : Int64) : Bool
    !!(expires_at && now >= expires_at)
  end

  private def unescape_like(pattern : String) : String
    pattern.rchop('%').gsub("\\%", "%").gsub("\\_", "_").gsub("\\\\", "\\")
  end

  private def str(value : Aptork::SqlValue) : String
    value.as(String)
  end

  private def i64(value : Aptork::SqlValue) : Int64
    Aptork::SqlStatements.to_i64?(value).not_nil!
  end

  private def i64?(value : Aptork::SqlValue) : Int64?
    Aptork::SqlStatements.to_i64?(value)
  end
end

class RecordingTelemetry < Aptork::Telemetry
  getter spans = [] of String
  getter counters = [] of String
  getter histograms = [] of String
  getter counter_attributes = [] of Aptork::TelemetryAttributes

  def span(name : String, attributes : Aptork::TelemetryAttributes = Aptork::TelemetryAttributes.new, &block)
    @spans << name
    yield
  end

  def counter(name : String, value : Int64 = 1_i64, attributes : Aptork::TelemetryAttributes = Aptork::TelemetryAttributes.new) : Nil
    @counters << name
    @counter_attributes << attributes
  end

  def histogram(name : String, value : Float64, attributes : Aptork::TelemetryAttributes = Aptork::TelemetryAttributes.new) : Nil
    @histograms << name
  end
end

def generate_rsa_test_key_pair(owner : String) : Aptork::ActorKeyPair
  Aptork::Testing.generate_rsa_key_pair(owner)
end

def generate_ed25519_test_key_pair(owner : String) : Aptork::ActorKeyPair
  Aptork::Testing.generate_ed25519_key_pair(owner)
end

def proofless_activity_request(activity : Aptork::JsonMap) : Aptork::Request
  Aptork::Request.new(
    "POST",
    "/inbox",
    headers: {"Content-Type" => "application/activity+json"},
    body: activity.to_json
  )
end

def activitypub_headers(headers = Hash(String, String).new) : Hash(String, String)
  {"Accept" => "application/activity+json"}.merge(headers)
end

def activitypub_get(
  path : String,
  query : Hash(String, String) = Hash(String, String).new,
  headers : Hash(String, String) = Hash(String, String).new
) : Aptork::Request
  Aptork::Request.new("GET", path, query: query, headers: activitypub_headers(headers))
end

def configure_local_actor_dispatcher(federation : Aptork::Federation) : Nil
  federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
    Aptork.actor(
      "Person",
      ctx.get_actor_uri(identifier),
      identifier,
      ctx.get_inbox_uri(identifier),
      ctx.get_outbox_uri(identifier)
    ).as(Aptork::JsonMap?)
  end)
end

class FakeRedisCommandClient
  include Aptork::RedisCommandClient

  getter commands = [] of Array(String)

  def initialize
    @strings = Hash(String, String).new
    @expires = Hash(String, Time).new
    @zsets = Hash(String, Hash(String, Int64)).new
  end

  def command(args : Array(String)) : Aptork::RedisReply
    @commands << args
    case args[0]
    when "SET"
      @strings[args[1]] = args[2]
      if args[3]? == "PX"
        @expires[args[1]] = Time.utc + Time::Span.new(nanoseconds: args[4].to_i64 * 1_000_000)
      end
      "OK"
    when "GET"
      if expires_at = @expires[args[1]]?
        if Time.utc >= expires_at
          @strings.delete(args[1])
          @expires.delete(args[1])
          return nil
        end
      end
      @strings[args[1]]?
    when "DEL"
      removed = @strings.delete(args[1]) ? 1_i64 : 0_i64
      @expires.delete(args[1])
      removed
    when "EVAL"
      key = args[3]
      expected_present = args[4] == "1"
      expected_value = args[5]
      ttl_ms = args[6]
      new_value = args[7]
      current = expired?(key) ? nil : @strings[key]?
      if expected_present
        return 0_i64 unless current == expected_value
      else
        return 0_i64 unless current.nil?
      end

      @strings[key] = new_value
      if ttl_ms.empty?
        @expires.delete(key)
      else
        @expires[key] = Time.utc + Time::Span.new(nanoseconds: ttl_ms.to_i64 * 1_000_000)
      end
      1_i64
    when "KEYS"
      pattern = args[1]
      prefix = pattern.ends_with?("*") ? pattern.rchop("*") : pattern
      @strings.keys.select do |key|
        key.starts_with?(prefix) && !expired?(key)
      end.sort
    when "ZADD"
      zset(args[1])[args[3]] = args[2].to_i64
      1_i64
    when "ZCARD"
      zset(args[1]).size.to_i64
    when "ZCOUNT"
      max = args[3].to_i64
      zset(args[1]).count { |_member, score| score <= max }.to_i64
    when "ZRANGEBYSCORE"
      max = args[3].to_i64
      offset = args[5].to_i
      limit = args[6].to_i
      zset(args[1])
        .select { |_member, score| score <= max }
        .to_a
        .sort_by { |member, score| {score, member} }
        .skip(offset)
        .first(limit)
        .map(&.[0])
    when "ZREM"
      zset(args[1]).delete(args[2]) ? 1_i64 : 0_i64
    else
      raise "unsupported fake Redis command #{args.inspect}"
    end
  end

  private def zset(key : String) : Hash(String, Int64)
    @zsets[key] ||= Hash(String, Int64).new
  end

  private def expired?(key : String) : Bool
    if expires_at = @expires[key]?
      if Time.utc >= expires_at
        @strings.delete(key)
        @expires.delete(key)
        return true
      end
    end
    false
  end
end

class BatchRecordingQueue < Aptork::InProcessMessageQueue
  getter enqueue_calls = 0
  getter enqueue_many_calls = 0

  def enqueue(queue : String, payload : Aptork::JsonMap, options : Aptork::EnqueueOptions = Aptork::EnqueueOptions.new) : Nil
    @enqueue_calls += 1
    super
  end

  def enqueue_many(queue : String, payloads : Enumerable(Aptork::JsonMap), options : Aptork::EnqueueOptions = Aptork::EnqueueOptions.new) : Nil
    @enqueue_many_calls += 1
    super
  end
end

describe Aptork::Transport do
  it "builds Create(Note) payload and sends with injected post provider" do
    captured_payload = ""

    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, payload : String) do
        captured_payload = payload
        {202, "accepted"}
      end
    )

    request = Aptork::PublishRequest.new(
      title: "Hello",
      content: "Build this",
      assignee: "https://remote.example/actors/assignee",
      attributed_to: nil
    )
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: "https://local.example/actors/gateway",
      target: "https://remote.example/actors/target"
    )

    activity = transport.build_create_activity(request, delivery)
    transport.deliver!(delivery, activity)

    captured_payload.includes?("\"type\":\"Create\"").should be_true
    captured_payload.includes?("\"type\":\"Note\"").should be_true
    captured_payload.includes?("\"assignee\":\"https://remote.example/actors/assignee\"").should be_true
    captured_payload.includes?("\"type\":\"Task\"").should be_false
  end

  it "supports configurable object type" do
    transport = Aptork::Transport.new(
      object_type: "Task",
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _payload : String) do
        {202, "ok"}
      end
    )

    request = Aptork::PublishRequest.new(
      title: "Title",
      content: "Content",
      assignee: nil,
      attributed_to: nil
    )
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: "https://local.example/actors/gateway",
      target: nil
    )

    activity = transport.build_create_activity(request, delivery)
    activity["object"].as_h["type"].should eq("Task")
  end

  it "retries delivery with RFC 9421 headers after Accept-Signature challenge" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    attempts = 0
    captured_headers = [] of HTTP::Headers
    captured_payloads = [] of String
    transport = Aptork::Transport.new(
      detailed_post_provider: ->(_url : String, headers : HTTP::Headers, payload : String) do
        attempts += 1
        captured_headers << headers
        captured_payloads << payload
        if attempts == 1
          Aptork::PostResponse.new(
            401,
            "signature required",
            HTTP::Headers{"Accept-Signature" => %(retry=("@method" "@target-uri" "@authority" "content-digest");alg="rsa-v1_5-sha256";nonce="n1";tag="activitypub")}
          )
        else
          Aptork::PostResponse.new(202, "ok")
        end
      end
    )
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: key_pair.owner,
      target: "https://remote.example/users/bob"
    )
    activity = Aptork.create(
      "https://local.example/activities/1",
      key_pair.owner,
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    transport.deliver!(delivery, activity, key_pair).should eq("https://local.example/activities/1")

    attempts.should eq(2)
    captured_payloads.uniq.size.should eq(1)
    captured_headers.first["Signature"].includes?("keyId=").should be_true
    captured_headers.last["Signature-Input"].should contain("retry=")
    captured_headers.last["Signature-Input"].should contain(%(nonce="n1"))
    captured_headers.last["Signature-Input"].should contain(%(tag="activitypub"))
    captured_headers.last["Signature"].should start_with("retry=:")
    captured_headers.last["Content-Digest"].should eq(Aptork::Signatures.content_digest_header(activity.to_json))
  end

  it "does not retry incompatible Accept-Signature challenges" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    attempts = 0
    transport = Aptork::Transport.new(
      detailed_post_provider: ->(_url : String, _headers : HTTP::Headers, _payload : String) do
        attempts += 1
        Aptork::PostResponse.new(
          401,
          "signature required",
          HTTP::Headers{"Accept-Signature" => %(sig1=("@method");alg="ed25519")}
        )
      end
    )
    delivery = Aptork::DeliveryConfig.new("https://remote.example/inbox", key_pair.owner, nil)
    activity = Aptork.create(
      "https://local.example/activities/1",
      key_pair.owner,
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    expect_raises(Aptork::DeliveryError) do
      transport.deliver!(delivery, activity, key_pair)
    end
    attempts.should eq(1)
  end

  it "selects compatible structured Accept-Signature challenges" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    attempts = 0
    captured_headers = [] of HTTP::Headers
    transport = Aptork::Transport.new(
      detailed_post_provider: ->(_url : String, headers : HTTP::Headers, _payload : String) do
        attempts += 1
        captured_headers << headers
        if attempts == 1
          Aptork::PostResponse.new(
            401,
            "signature required",
            HTTP::Headers{"Accept-Signature" => %(ed=("@method");alg="ed25519", retry=("@method" "@scheme" "@request-target" "content-digest";sf);alg="rsa-v1_5-sha256";expires;nonce="n2")}
          )
        else
          Aptork::PostResponse.new(202, "ok")
        end
      end
    )
    delivery = Aptork::DeliveryConfig.new("https://remote.example/inbox?resource=acct%3Abob%40remote.example", key_pair.owner, nil)
    activity = Aptork.create(
      "https://local.example/activities/1",
      key_pair.owner,
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    challenges = Aptork::Signatures.parse_accept_signatures(%(ed=("@method");alg="ed25519", retry=("@method" "@query-param";name="resource" "content-digest";sf);alg="rsa-v1_5-sha256";expires))
    transport.deliver!(delivery, activity, key_pair).should eq("https://local.example/activities/1")

    challenges.size.should eq(2)
    challenges.last.components.should eq(["@method", %(@query-param;name="resource"), "content-digest;sf"])
    challenges.last.expires.should be_true
    attempts.should eq(2)
    captured_headers.last["Signature-Input"].should start_with("retry=")
    captured_headers.last["Signature-Input"].should contain(%("@scheme" "@request-target" "content-digest";sf))
    captured_headers.last["Signature-Input"].should contain("expires=")
    captured_headers.last["Signature-Input"].should contain(%(nonce="n2"))
  end

  it "does not fulfill request-invalid Accept-Signature components" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    attempts = 0
    transport = Aptork::Transport.new(
      detailed_post_provider: ->(_url : String, _headers : HTTP::Headers, _payload : String) do
        attempts += 1
        Aptork::PostResponse.new(
          401,
          "signature required",
          HTTP::Headers{"Accept-Signature" => %(bad=("@status" "@method");alg="rsa-v1_5-sha256")}
        )
      end
    )
    delivery = Aptork::DeliveryConfig.new("https://remote.example/inbox", key_pair.owner, nil)
    activity = Aptork.create(
      "https://local.example/activities/1",
      key_pair.owner,
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    expect_raises(Aptork::DeliveryError) do
      transport.deliver!(delivery, activity, key_pair)
    end
    attempts.should eq(1)
  end

  it "builds ForgeFed Create(Ticket) activities" do
    transport = Aptork::Transport.new
    request = Aptork::PublishRequest.new(
      title: "Bug",
      content: "Fix it",
      assignee: "https://remote.example/users/bob",
      attributed_to: nil
    )
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: "https://local.example/users/alice",
      target: nil
    )

    activity = transport.build_forgefed_ticket_create(request, delivery)

    activity["type"].as_s.should eq("Create")
    activity["object"].as_h["type"].as_s.should eq("Ticket")
  end

  it "builds marketplace Offer objects" do
    transport = Aptork::Transport.new
    item = Aptork.object("Service", "https://local.example/services/solver", Aptork::JsonMap{
      "name" => Aptork.json("Solver"),
    })
    request = Aptork::MarketplaceOfferRequest.new("Solver access", item, "10", "USD")
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: "https://local.example/users/alice",
      target: "https://remote.example/users/bob"
    )

    offer = transport.build_marketplace_offer(request, delivery)

    offer["type"].as_s.should eq("Offer")
    offer["item"].as_h["type"].as_s.should eq("Service")
    offer["to"].as_a.includes?(Aptork.json("https://remote.example/users/bob")).should be_true
  end
end

describe Aptork::Federation do
  it "validates Fedify-style route templates for actor, inbox, and outbox routes" do
    actor_dispatcher = ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end
    collection_dispatcher = ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end

    expect_raises(ArgumentError, /exactly one/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users", actor_dispatcher)
    end
    expect_raises(ArgumentError, /exactly one/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users/{identifier}/{handle}", actor_dispatcher)
    end
    expect_raises(ArgumentError, /duplicated/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users/{identifier}/{identifier}", actor_dispatcher)
    end
    expect_raises(ArgumentError, /only supports/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users/{?identifier}", actor_dispatcher)
    end
    expect_raises(ArgumentError, /only supports/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users/{identifier:3}", actor_dispatcher)
    end
    expect_raises(ArgumentError, /only supports/) do
      Aptork::Federation.create("https://local.example").set_actor_dispatcher("/users/{identifier*}", actor_dispatcher)
    end
    expect_raises(ArgumentError, /only supports/) do
      Aptork::Federation.create("https://local.example").set_outbox_dispatcher("/users/{+identifier}/outbox", collection_dispatcher)
    end
    expect_raises(ArgumentError, /must not contain/) do
      Aptork::Federation.create("https://local.example").set_inbox_listeners("/users/{identifier}/inbox", "/shared/{identifier}/inbox")
    end
  end

  it "requires inbox and outbox listener paths to match configured dispatchers" do
    collection_dispatcher = ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end

    inbox_federation = Aptork::Federation.create("https://local.example")
    inbox_federation.set_inbox_dispatcher("/users/{identifier}/inbox", collection_dispatcher)
    expect_raises(ArgumentError, /inbox listener and dispatcher paths must match/) do
      inbox_federation.set_inbox_listeners("/actors/{identifier}/inbox")
    end

    outbox_federation = Aptork::Federation.create("https://local.example")
    outbox_federation.set_outbox_dispatcher("/users/{identifier}/outbox", collection_dispatcher)
    expect_raises(ArgumentError, /outbox listener and dispatcher paths must match/) do
      outbox_federation.set_outbox_listeners("/actors/{identifier}/outbox")
    end
  end

  it "builds a federation from deferred builder registrations" do
    inbox_handled = false
    outbox_handled = false
    builder = Aptork.create_federation_builder
    builder.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    builder.set_outbox_dispatcher("/users/{identifier}/outbox", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "Hello")]
    end)
    builder.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(ctx.get_object_uri("Note", params), "Hello").as(Aptork::JsonMap?)
    end)
    builder.configure_object("Note")
      .authorize(->(_ctx : Aptork::Context, _request : Aptork::Request, _verification : Aptork::VerificationResult, _identifier : String?, params : Hash(String, String)) do
        params["identifier"]? == "alice"
      end)
    builder.set_collection_page_dispatcher("stars", "/users/{identifier}/stars", ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, _size : Int32) do
      if cursor
        Aptork::CollectionPageResult.new([Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox")]).as(Aptork::CollectionPageResult?)
      else
        Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start").as(Aptork::CollectionPageResult?)
      end
    end)
    builder.configure_collection("stars")
      .item_type("Person")
      .set_counter(->(_ctx : Aptork::Context, _params : Hash(String, String)) { 1.as(Int32?) })
    builder.set_liked_dispatcher("/users/{identifier}/liked", ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end)
    builder.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        inbox_handled = true
        nil
      end)
    builder.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        outbox_handled = true
        nil
      end)

    federation = builder.build("https://local.example")
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    ctx.actor("alice").not_nil!["id"].as_s.should eq("https://local.example/users/alice")
    federation.handle(activitypub_get("/users/alice/outbox")).status.should eq(200)
    federation.handle(activitypub_get("/users/alice/notes/1")).status.should eq(200)
    federation.handle(activitypub_get("/users/bob/notes/1")).status.should eq(401)
    stars = federation.handle(activitypub_get("/users/alice/stars"))
    stars.status.should eq(200)
    JSON.parse(stars.body).as_h["itemType"].as_s.should eq("Person")
    JSON.parse(stars.body).as_h["totalItems"].as_i.should eq(1)
    federation.handle(Aptork::Request.new("POST", "/users/alice/inbox", body: activity.to_json)).status.should eq(202)
    federation.handle(Aptork::Request.new("POST", "/users/alice/outbox", body: activity.to_json)).status.should eq(202)
    inbox_handled.should be_true
    outbox_handled.should be_true
  end

  it "supports block-style federation building with runtime options" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.build("https://local.example", outbox_queue: queue) do |builder|
      builder.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
        [
          Aptork.actor(
            "Person",
            "https://remote.example/users/bob",
            "bob",
            "https://remote.example/users/bob/inbox",
            "https://remote.example/users/bob/outbox"
          ),
        ]
      end)
    end
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)

    result.queued.size.should eq(1)
    queue.depth("outbox").should eq(1)
  end

  it "builds Fedify-style context URIs and dispatches actors" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      actor = Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier),
        name: "Alice",
        followers: ctx.get_followers_uri(identifier),
        following: ctx.get_following_uri(identifier),
        shared_inbox: ctx.get_inbox_uri
      )
      actor.as(Aptork::JsonMap?)
    end)

    ctx = federation.create_context
    actor = ctx.actor("alice").not_nil!

    ctx.get_actor_uri("alice").should eq("https://local.example/users/alice")
    ctx.get_inbox_uri("alice").should eq("https://local.example/actors/alice/inbox")
    ctx.get_outbox_uri("alice").should eq("https://local.example/actors/alice/outbox")
    ctx.get_followers_uri("alice").should eq("https://local.example/actors/alice/followers")
    ctx.get_following_uri("alice").should eq("https://local.example/actors/alice/following")
    ctx.get_liked_uri("alice").should eq("https://local.example/actors/alice/liked")
    ctx.get_featured_uri("alice").should eq("https://local.example/actors/alice/featured")
    ctx.get_featured_tags_uri("alice").should eq("https://local.example/actors/alice/featured/tags")
    actor["type"].as_s.should eq("Person")
    actor["preferredUsername"].as_s.should eq("alice")
  end

  it "exposes Fedify-style request context helpers" do
    request = Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/activity+json"},
      query: {"page" => "1", "format" => "activity"}
    )
    federation = Aptork::Federation.create("https://local.example:8443")
    data = Aptork.json({"tenant" => "alpha"})
    ctx = federation.create_context(context_data: data).with_recipient("alice").with_inbound_request(request)
    cloned = ctx.clone(Aptork.json({"tenant" => "beta"}))

    ctx.request.should eq(request)
    ctx.inbound_request.should eq(request)
    ctx.data.not_nil!["tenant"].as_s.should eq("alpha")
    ctx.url.should eq("https://local.example:8443/users/alice?page=1&format=activity")
    ctx.origin.should eq("https://local.example:8443")
    ctx.canonical_origin.should eq("https://local.example:8443")
    ctx.host.should eq("local.example:8443")
    ctx.hostname.should eq("local.example")
    cloned.data.not_nil!["tenant"].as_s.should eq("beta")
    cloned.recipient_identifier.should eq("alice")
    cloned.request.should eq(request)
    federation.create_context.url.should be_nil
  end

  it "validates runtime and canonical origins like Fedify" do
    federation = Aptork::Federation.create("http://example.com:8080/")
    normalized = Aptork::Federation.create(
      "HTTPS://EXAMPLE.COM:443/",
      canonical_origin: "http://AP.EXAMPLE:80/"
    )

    federation.origin.should eq("http://example.com:8080")
    federation.canonical_origin.should eq("http://example.com:8080")
    normalized.origin.should eq("https://example.com")
    normalized.canonical_origin.should eq("http://ap.example")
    normalized.create_context.host.should eq("example.com")
    normalized.create_context.get_actor_uri("alice").should eq("http://ap.example/actors/alice")

    [
      "example.com",
      "ftp://example.com",
      "https://example.com/foo",
      "https://example.com/?foo",
      "https://example.com/#foo",
    ].each do |origin|
      expect_raises(ArgumentError) do
        Aptork::Federation.create(origin)
      end
      expect_raises(ArgumentError) do
        Aptork::Federation.create("https://local.example", canonical_origin: origin)
      end
    end
  end

  it "accepts Fedify-style origin objects" do
    origin = Aptork::FederationOrigin.new(
      handle_host: "EXAMPLE.COM:8443",
      web_origin: "https://AP.EXAMPLE.COM/"
    )
    federation = Aptork::Federation.create(origin)
    built = Aptork::Federation.build(origin) do |builder|
      builder.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ).as(Aptork::JsonMap?)
      end)
    end

    federation.origin.should eq("https://ap.example.com")
    federation.canonical_origin.should eq("https://ap.example.com")
    federation.handle_host.should eq("example.com:8443")
    built.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@example.com:8443"}
    )).status.should eq(200)
  end

  it "exposes separate document and context loaders on contexts" do
    document_loader = ->(url : String) do
      url == "https://remote.example/doc" ? Aptork::JsonMap{"id" => Aptork.json(url)} : nil.as(Aptork::JsonMap?)
    end
    context_loader = ->(url : String) do
      url == "https://remote.example/context" ? Aptork::JsonMap{"@context" => Aptork.json(url)} : nil.as(Aptork::JsonMap?)
    end
    federation = Aptork::Federation.create(
      "https://local.example",
      document_loader: document_loader,
      context_loader: context_loader
    )
    request = Aptork::Request.new("GET", "/users/alice")

    ctx = federation.create_context(request, context_data: Aptork.json({"tenant" => "alpha"}))

    ctx.request.should eq(request)
    ctx.data.not_nil!["tenant"].as_s.should eq("alpha")
    ctx.document_loader.call("https://remote.example/doc").not_nil!["id"].as_s.should eq("https://remote.example/doc")
    ctx.context_loader.call("https://remote.example/context").not_nil!["@context"].as_s.should eq("https://remote.example/context")
    ctx.with_document_loader(context_loader).context_loader.call("https://remote.example/context").should_not be_nil
    ctx.with_context_loader(document_loader).document_loader.call("https://remote.example/doc").should_not be_nil
  end

  it "keeps context loader in sync with document loader until explicitly configured" do
    first_loader = ->(url : String) { Aptork::JsonMap{"id" => Aptork.json("first:#{url}")}.as(Aptork::JsonMap?) }
    second_loader = ->(url : String) { Aptork::JsonMap{"id" => Aptork.json("second:#{url}")}.as(Aptork::JsonMap?) }
    context_loader = ->(url : String) { Aptork::JsonMap{"id" => Aptork.json("context:#{url}")}.as(Aptork::JsonMap?) }
    federation = Aptork::Federation.create("https://local.example", document_loader: first_loader)

    federation.create_context.context_loader.call("x").not_nil!["id"].as_s.should eq("first:x")
    federation.set_document_loader(second_loader)
    federation.create_context.context_loader.call("x").not_nil!["id"].as_s.should eq("second:x")
    federation.set_context_loader(context_loader)
    federation.set_document_loader(first_loader)

    ctx = federation.create_context
    ctx.document_loader.call("x").not_nil!["id"].as_s.should eq("first:x")
    ctx.context_loader.call("x").not_nil!["id"].as_s.should eq("context:x")
  end

  it "uses canonical origin for generated ActivityPub URLs and parses both origins" do
    federation = Aptork::Federation.create("https://internal.example:8443", canonical_origin: "https://ap.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{id}", ->(_ctx : Aptork::Context, _params : Hash(String, String)) do
      nil.as(Aptork::JsonMap?)
    end)
    federation.set_collection_dispatcher("featured", "/users/{identifier}/collections/featured", ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end)
    federation.set_nodeinfo_dispatcher(->(_ctx : Aptork::Context) do
      Aptork.nodeinfo("aptork", Aptork::VERSION)
    end)
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new("GET", "/users/alice"))

    ctx.origin.should eq("https://internal.example:8443")
    ctx.canonical_origin.should eq("https://ap.example")
    ctx.url.should eq("https://internal.example:8443/users/alice")
    ctx.get_actor_uri("alice").should eq("https://ap.example/users/alice")
    ctx.get_object_uri("Note", {"identifier" => "alice", "id" => "1"}).should eq("https://ap.example/users/alice/notes/1")
    ctx.get_collection_uri("featured", "alice").should eq("https://ap.example/users/alice/collections/featured")
    ctx.get_inbox_uri("alice").should eq("https://ap.example/actors/alice/inbox")
    ctx.get_inbox_uri.should eq("https://ap.example/inbox")
    ctx.get_outbox_uri("alice").should eq("https://ap.example/actors/alice/outbox")
    ctx.get_nodeinfo_uri.should eq("https://ap.example/nodeinfo/2.1")

    collection_response = federation.handle(activitypub_get("/users/alice/collections/featured"))
    JSON.parse(collection_response.body).as_h["id"].as_s.should eq("https://ap.example/users/alice/collections/featured")

    ctx.parse_uri("https://ap.example/users/alice").try(&.type).should eq("actor")
    ctx.parse_uri("https://internal.example:8443/users/alice").try(&.type).should eq("actor")
    ctx.parse_uri("https://ap.example/users/alice/notes/1").try(&.object_type).should eq("Note")
    ctx.parse_uri("https://internal.example:8443/users/alice/collections/featured").try(&.collection_name).should eq("featured")
  end

  it "matches local routes with trailing slashes when configured" do
    federation = Aptork::Federation.create("https://local.example", trailing_slash_insensitive: true)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(ctx.get_object_uri("Note", params), "Hello").as(Aptork::JsonMap?)
    end)
    ctx = federation.create_context

    actor_response = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice/",
      headers: {"Accept" => "application/activity+json"}
    ))
    note_response = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice/notes/1/",
      headers: {"Accept" => "application/activity+json"}
    ))
    parsed_actor = ctx.parse_uri("https://local.example/users/alice/").not_nil!
    parsed_note = ctx.parse_uri("https://local.example/users/alice/notes/1/").not_nil!

    actor_response.status.should eq(200)
    JSON.parse(actor_response.body).as_h["preferredUsername"].as_s.should eq("alice")
    note_response.status.should eq(200)
    parsed_actor.type.should eq("actor")
    parsed_actor.identifier.should eq("alice")
    parsed_note.object_type.should eq("Note")
    parsed_note.values.should eq({"identifier" => "alice", "note_id" => "1"})
  end

  it "keeps trailing slash matching strict by default" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)

    response = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice/",
      headers: {"Accept" => "application/activity+json"}
    ))

    response.status.should eq(404)
    federation.create_context.parse_uri("https://local.example/users/alice/").should be_nil
  end

  it "separates WebFinger handle host from canonical ActivityPub URLs" do
    federation = Aptork::Federation.create(
      "https://internal.example:8443",
      canonical_origin: "https://ap.example",
      handle_host: "example.com"
    )
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)

    handle_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@example.com"}
    ))
    canonical_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@ap.example"}
    ))
    url_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "https://ap.example/users/alice"}
    ))
    runtime_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@internal.example:8443"}
    ))

    handle_response.status.should eq(200)
    handle_json = JSON.parse(handle_response.body).as_h
    handle_json["subject"].as_s.should eq("acct:alice@example.com")
    handle_json["links"].as_a.map(&.as_h).find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://ap.example/users/alice")
    handle_json["aliases"].as_a.map(&.as_s).should contain("https://ap.example/users/alice")
    handle_json["aliases"].as_a.map(&.as_s).should_not contain("acct:alice@ap.example")

    canonical_response.status.should eq(200)
    canonical_json = JSON.parse(canonical_response.body).as_h
    canonical_json["subject"].as_s.should eq("acct:alice@ap.example")
    canonical_json["aliases"].as_a.map(&.as_s).should contain("acct:alice@example.com")

    url_response.status.should eq(200)
    url_json = JSON.parse(url_response.body).as_h
    url_json["subject"].as_s.should eq("https://ap.example/users/alice")
    url_json["aliases"].as_a.map(&.as_s).should contain("acct:alice@example.com")
    url_json["aliases"].as_a.map(&.as_s).should contain("acct:alice@ap.example")
    runtime_response.status.should eq(404)
  end

  it "normalizes WebFinger acct hosts like Fedify" do
    federation = Aptork::Federation.create(
      "https://xn--maana-pta.com",
      handle_host: "MAÑANA.COM"
    )
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)

    unicode_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@MAÑANA.COM"}
    ))
    ascii_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@XN--MAANA-PTA.COM"}
    ))

    unicode_response.status.should eq(200)
    unicode_json = JSON.parse(unicode_response.body).as_h
    unicode_json["subject"].as_s.should eq("acct:alice@xn--maana-pta.com")
    unicode_json["links"].as_a.map(&.as_h).find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://xn--maana-pta.com/users/alice")
    ascii_response.status.should eq(200)
    JSON.parse(ascii_response.body).as_h["subject"].as_s.should eq("acct:alice@xn--maana-pta.com")
  end

  it "passes request-scoped context data into routed callbacks" do
    seen_data = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      seen_data = ctx.data.not_nil!["tenant"].as_s
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)

    response = federation.handle(
      Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "application/activity+json"}),
      context_data: Aptork.json({"tenant" => "alpha"})
    )

    response.status.should eq(200)
    seen_data.should eq("alpha")
  end

  it "routes activities to typed inbox listeners" do
    handled = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        handled = activity["type"].as_s == "Create"
        nil
      end)

    ctx = federation.create_context
    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", "https://local.example/users/alice", note)

    ctx.route_activity(nil, activity, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    handled.should be_true
  end

  it "routes expanded type ids and Fedify-style vocab classes to inbox listeners" do
    calls = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on(Aptork::Vocab::Accept, ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        calls << activity["type"].as_s
        nil
      end)
      .on("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Reject", ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        calls << Aptork.type_name(activity["type"].as_s)
        nil
      end)

    ctx = federation.create_context
    note = Aptork.note("https://local.example/notes/expanded-1", "Hello")
    accept = Aptork.activity("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Accept", "https://local.example/activities/accept-1", "https://local.example/users/alice", note)
    reject = Aptork.activity("Reject", "https://local.example/activities/reject-1", "https://local.example/users/alice", note)

    ctx.route_activity(nil, accept, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    ctx.route_activity(nil, reject, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    calls.should eq(["https://www.w3.org/ns/activitystreams#Accept", "Reject"])
  end

  it "passes typed vocabulary objects to Fedify-style inbox listeners" do
    seen_follow = nil.as(Aptork::Vocab::Follow?)
    seen_offer = nil.as(Aptork::Vocab::MarketplaceOffer?)
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on(Aptork::Vocab::Follow, ->(_ctx : Aptork::Context, follow : Aptork::Vocab::Follow) do
        seen_follow = follow
        nil
      end)
      .on(Aptork::Vocab::MarketplaceOffer, ->(_ctx : Aptork::Context, offer : Aptork::Vocab::MarketplaceOffer) do
        seen_offer = offer
        nil
      end)

    ctx = federation.create_context
    follow = Aptork.activity(
      "#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Follow",
      "https://local.example/activities/follow-typed",
      "https://local.example/users/alice",
      Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox")
    )
    offer = Aptork.marketplace_offer(
      "https://local.example/offers/typed",
      "https://local.example/users/alice",
      Aptork.marketplace_product("https://local.example/products/typed", "Typed product"),
      "Typed offer",
      "10",
      "USD"
    )

    ctx.route_activity(nil, follow, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    ctx.route_activity(nil, offer, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    seen_follow.should be_a(Aptork::Vocab::Follow)
    seen_follow.not_nil!.object.should be_a(Aptork::Vocab::Person)
    seen_offer.should be_a(Aptork::Vocab::MarketplaceOffer)
    seen_offer.not_nil!.item.should be_a(Aptork::Vocab::Product)
    seen_offer.not_nil!.price_currency.should eq("USD")
  end

  it "routes activities to nearest vocabulary ancestor listeners" do
    calls = [] of String
    seen_offer = nil.as(Aptork::Vocab::ActivityOffer?)
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Offer", ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        calls << Aptork.type_name(activity["type"].as_s)
        nil
      end)
      .on(Aptork::Vocab::ActivityOffer, ->(_ctx : Aptork::Context, offer : Aptork::Vocab::ActivityOffer) do
        seen_offer = offer
        nil
      end)

    invite = Aptork.activity(
      "#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Invite",
      "https://local.example/activities/invite-1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/invite-1", "Join"),
      target: "https://local.example/groups/crystal"
    )

    federation.create_context.route_activity(nil, invite, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    calls.should eq(["Invite"])
    seen_offer.should be_a(Aptork::Vocab::Invite)
    seen_offer.not_nil!.target.should eq("https://local.example/groups/crystal")
    Aptork.type_lineage("Invite").should eq(["Invite", "Offer", "Activity"])
  end

  it "routes inbox activities to Fedify-style Activity catch-all listeners and array type listeners" do
    calls = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Activity", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls << "activity"
        nil
      end)
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls << "create"
        nil
      end)

    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    activity["type"] = Aptork.json(["Create", "Activity"])

    ctx.route_activity(nil, activity, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    calls.should eq(["create", "activity"])
  end

  it "reports inbox listener errors to scoped handlers" do
    captured_context = nil.as(Aptork::Context?)
    captured_message = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        raise "broken inbox listener"
      end)
      .on_error(->(ctx : Aptork::Context, error : Exception) do
        captured_context = ctx
        captured_message = error.message || ""
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    ctx.route_activity("alice", activity, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should be_true
    captured_context.not_nil!.recipient_identifier.should eq("alice")
    captured_message.should eq("broken inbox listener")
  end

  it "queues manual route_activity calls by default when an inbox queue is configured" do
    handled = false
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        handled = ctx.recipient_identifier == "alice" && activity["type"].as_s == "Create"
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    ctx.route_activity("alice", activity, Aptork::RouteActivityOptions.new(trusted: true)).should be_true
    handled.should be_false
    queue.depth("inbox").should eq(1)

    ctx.process_queued_inbox_activities
    handled.should be_true
    queue.depth("inbox").should eq(0)
  end

  it "processes inbound queued tasks directly with context data" do
    seen_tenant = ""
    seen_recipient = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        seen_tenant = ctx.data.not_nil!["tenant"].as_s
        seen_recipient = ctx.recipient_identifier || ""
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    processed = federation.process_queued_task(
      federation.inbound_delivery_payload("alice", activity, trusted: true),
      Aptork.json({"tenant" => "alpha"})
    )

    processed.should be_true
    seen_tenant.should eq("alpha")
    seen_recipient.should eq("alice")
  end

  it "routes manual route_activity calls immediately when requested" do
    handled = false
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    ctx.route_activity(nil, activity, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should be_true

    handled.should be_true
    queue.depth("inbox").should eq(0)
  end

  it "returns Fedify-style route activity result statuses" do
    calls = [] of String
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls << "create"
        nil
      end)
      .with_idempotency(Time::Span.new(hours: 1), "per-inbox")
    ctx = federation.create_context
    activity = Aptork.create(
      "https://remote.example/activities/route-result",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/route-result", "Hi")
    )
    missing_actor = activity.dup
    missing_actor.delete("actor")
    unsupported = Aptork.activity(
      "Read",
      "https://remote.example/activities/read-1",
      "https://remote.example/users/bob",
      Aptork.object("Article", "https://remote.example/articles/1", Aptork::JsonMap{
        "name" => Aptork.json("Read me"),
      })
    )

    ctx.route_activity_result("alice", activity, Aptork::RouteActivityOptions.new(trusted: true)).should eq(Aptork::RouteActivityResult::Enqueued)
    queue.depth("inbox").should eq(1)
    ctx.route_activity_result("alice", activity, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should eq(Aptork::RouteActivityResult::Success)
    ctx.route_activity_result("alice", activity, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should eq(Aptork::RouteActivityResult::AlreadyProcessed)
    ctx.route_activity_result("alice", missing_actor, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should eq(Aptork::RouteActivityResult::MissingActor)
    ctx.route_activity_result("alice", unsupported, Aptork::RouteActivityOptions.new(immediate: true, trusted: true)).should eq(Aptork::RouteActivityResult::UnsupportedActivity)
    calls.should eq(["create"])
  end

  it "rejects manual route_activity calls without an actor" do
    handled = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/no-actor",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    activity.delete("actor")

    federation.create_context.route_activity("alice", activity).should be_false
    handled.should be_false
  end

  it "dereferences unsigned manual route_activity calls and routes the fetched activity" do
    seen_content = ""
    fetched = Aptork.create(
      "https://remote.example/activities/fetched",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Fetched")
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) { url == fetched["id"].as_s ? fetched : nil.as(Aptork::JsonMap?) })
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        seen_content = activity["object"].as_h["content"].as_s
        nil
      end)
    spoofed = Aptork.create(
      "https://remote.example/activities/fetched",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/spoofed", "Spoofed")
    )

    federation.create_context.route_activity("alice", spoofed).should be_true
    seen_content.should eq("Fetched")
  end

  it "uses per-call document loaders for manual route_activity verification" do
    seen_content = ""
    fetched = Aptork.create(
      "https://remote.example/activities/route-loader",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/route-loader", "Loaded per call")
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) { nil.as(Aptork::JsonMap?) })
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        ctx.document_loader.call(activity["id"].as_s).not_nil!["object"].as_h["content"].as_s.should eq("Loaded per call")
        ctx.context_loader.call("https://remote.example/context").not_nil!["id"].as_s.should eq("ctx:https://remote.example/context")
        seen_content = activity["object"].as_h["content"].as_s
        nil
      end)
    spoofed = Aptork.create(
      "https://remote.example/activities/route-loader",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/spoofed", "Spoofed")
    )
    options = Aptork::RouteActivityOptions.new(
      document_loader: ->(url : String) do
        url == fetched["id"].as_s ? fetched : nil.as(Aptork::JsonMap?)
      end,
      context_loader: ->(url : String) do
        Aptork::JsonMap{"id" => Aptork.json("ctx:#{url}")}.as(Aptork::JsonMap?)
      end
    )

    federation.create_context.route_activity("alice", spoofed, options).should be_true
    seen_content.should eq("Loaded per call")
  end

  it "stores fetched manual route_activity payloads as trusted queued deliveries" do
    seen_content = ""
    queue = Aptork::InProcessMessageQueue.new
    fetched = Aptork.create(
      "https://remote.example/activities/queued-fetched",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Queued fetched")
    )
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
      .set_document_loader(->(url : String) { url == fetched["id"].as_s ? fetched : nil.as(Aptork::JsonMap?) })
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, activity : Aptork::JsonMap) do
        seen_content = activity["object"].as_h["content"].as_s
        nil
      end)
    spoofed = Aptork.create(
      "https://remote.example/activities/queued-fetched",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/spoofed", "Queued spoofed")
    )

    federation.create_context.route_activity("alice", spoofed).should be_true
    queue.messages.first.payload["trusted"].as_bool.should be_true
    federation.create_context.process_queued_inbox_activities.should eq([Aptork::QueueProcessResult::Processed])
    seen_content.should eq("Queued fetched")
  end

  it "rejects unsigned manual route_activity calls when fetched ids do not match" do
    handled = false
    fetched = Aptork.create(
      "https://remote.example/activities/other",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Fetched")
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) { fetched.as(Aptork::JsonMap?) })
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/requested",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    federation.create_context.route_activity("alice", activity).should be_false
    handled.should be_false
  end

  it "rejects unsigned manual route_activity calls when fetched actor origin differs" do
    handled = false
    fetched = Aptork.create(
      "https://remote.example/activities/origin",
      "https://other.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Fetched")
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) { fetched.as(Aptork::JsonMap?) })
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/origin",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    federation.create_context.route_activity("alice", activity).should be_false
    handled.should be_false
  end

  it "enqueues verified inbox POSTs and processes listeners with retry policy" do
    handled = 0
    attempts = 0
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      inbox_queue: queue,
      inbox_retry_policy: Aptork::RetryPolicy.new(max_attempts: 2, initial_delay: Time::Span.new(seconds: 5))
    )
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        attempts += 1
        raise "temporary listener failure" if attempts == 1
        handled += 1
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      body: activity.to_json
    ))
    first = federation.create_context.process_queued_inbox_activities(Time.utc + Time::Span.new(seconds: 1))
    second = federation.create_context.process_queued_inbox_activities(Time.utc + Time::Span.new(seconds: 6))

    response.status.should eq(202)
    handled.should eq(1)
    queue.depth("inbox").should eq(0)
    first.should eq([Aptork::QueueProcessResult::Retried])
    second.should eq([Aptork::QueueProcessResult::Processed])
  end

  it "does not enqueue unverified inbox POSTs" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_verifier(->(_request : Aptork::Request, _activity : Aptork::JsonMap) do
      Aptork::VerificationResult.new(false, "bad signature")
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(401)
    queue.depth("inbox").should eq(0)
  end

  it "deduplicates inbox activities when idempotency is enabled" do
    handled = 0
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled += 1
        nil
      end)

    ctx = federation.create_context
    activity = Aptork.create(
      "https://remote.example/activities/duplicate",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    trusted_options = Aptork::RouteActivityOptions.new(trusted: true)
    ctx.route_activity(nil, activity, trusted_options).should be_true
    ctx.route_activity(nil, activity, trusted_options).should be_false
    handled.should eq(1)
  end

  it "uses recipient actor keys for personal inbox document loaders" do
    captured_headers = HTTP::Headers.new
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {200, Aptork.note("https://remote.example/notes/1", "Remote").to_json}
    end
    federation = Aptork::Federation.create("https://local.example", document_get_provider: provider)
    configure_local_actor_dispatcher(federation)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        ctx.lookup_object("https://remote.example/notes/1").not_nil!
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/source", "Hi")
      ).to_json
    ))

    response.status.should eq(202)
    captured_headers["Signature"].includes?(%(keyId="https://local.example/users/alice#main-key")).should be_true
  end

  it "uses shared key dispatchers for shared inbox document loaders" do
    captured_headers = HTTP::Headers.new
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {200, Aptork.note("https://remote.example/notes/1", "Remote").to_json}
    end
    federation = Aptork::Federation.create("https://local.example", document_get_provider: provider)
    configure_local_actor_dispatcher(federation)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .set_shared_key_dispatcher(->(_ctx : Aptork::Context) { {identifier: "instance"}.as(Aptork::SharedInboxKey?) })
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        ctx.lookup_object("https://remote.example/notes/1").not_nil!
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/source", "Hi")
      ).to_json
    ))

    response.status.should eq(202)
    captured_headers["Signature"].includes?(%(keyId="https://local.example/users/instance#main-key")).should be_true
  end

  it "uses shared inbox document loaders while traversing remote collections" do
    captured_headers = [] of HTTP::Headers
    provider = ->(url : String, headers : HTTP::Headers) do
      captured_headers << headers
      body = if url == "https://market.example/offers"
               Aptork.ordered_collection(
                 "https://market.example/offers",
                 [Aptork.note("https://market.example/offers/1", "Offer")]
               ).to_json
             else
               Aptork.note(url, "Remote").to_json
             end
      {200, body}
    end
    federation = Aptork::Federation.create("https://local.example", document_get_provider: provider)
    configure_local_actor_dispatcher(federation)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .set_shared_key_dispatcher(->(_ctx : Aptork::Context) { {identifier: "instance"}.as(Aptork::SharedInboxKey?) })
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        ctx.traverse_collection("https://market.example/offers").size.should eq(1)
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/source", "Hi")
      ).to_json
    ))

    response.status.should eq(202)
    captured_headers.first["Signature"].includes?(%(keyId="https://local.example/users/instance#main-key")).should be_true
  end

  it "uses mapped shared key usernames for queued shared inbox document loaders" do
    captured_headers = HTTP::Headers.new
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {200, Aptork.note("https://remote.example/notes/1", "Remote").to_json}
    end
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue, document_get_provider: provider)
    configure_local_actor_dispatcher(federation)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "instance" ? "system" : nil
    end)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .set_shared_key_dispatcher(->(_ctx : Aptork::Context) { {username: "instance"}.as(Aptork::SharedInboxKey?) })
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        Aptork::Remote.lookup_object("https://remote.example/notes/1", ctx.document_loader).not_nil!
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/source", "Hi")
      ).to_json
    ))
    ctx = federation.create_context
    ctx.process_queued_inbox_activities

    response.status.should eq(202)
    queue.depth("inbox").should eq(0)
    captured_headers["Signature"].includes?(%(keyId="https://local.example/users/system#main-key")).should be_true
  end

  it "deduplicates inbox activities per inbox by default when a kv store is configured" do
    handled = 0
    recipients = [] of String
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled += 1
        recipients << (ctx.recipient_identifier || "shared")
        nil
      end)

    activity = Aptork.create(
      "https://remote.example/activities/same-id",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    ctx = federation.create_context

    trusted_options = Aptork::RouteActivityOptions.new(trusted: true)
    ctx.route_activity("alice", activity, trusted_options).should be_true
    ctx.route_activity("bob", activity, trusted_options).should be_true
    ctx.route_activity("alice", activity, trusted_options).should be_false

    handled.should eq(2)
    recipients.should eq(["alice", "bob"])
  end

  it "supports per-origin and global inbox idempotency strategies" do
    per_origin = 0
    global = 0
    activity = Aptork.create(
      "https://remote.example/activities/origin-id",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    origin_federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    origin_federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency("per-origin")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        per_origin += 1
        nil
      end)
    origin_ctx = origin_federation.create_context

    global_federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    global_federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency("global")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        global += 1
        nil
      end)
    global_ctx = global_federation.create_context

    trusted_options = Aptork::RouteActivityOptions.new(trusted: true)
    origin_ctx.route_activity("alice", activity, trusted_options).should be_true
    origin_ctx.route_activity("bob", activity, trusted_options).should be_false
    global_ctx.route_activity("alice", activity, trusted_options).should be_true
    global_ctx.route_activity("bob", activity, trusted_options).should be_false

    per_origin.should eq(1)
    global.should eq(1)
  end

  it "supports custom inbox idempotency strategies" do
    handled = 0
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency(Time::Span.new(hours: 24), ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        if activity["type"]?.try(&.as_s?) == "Follow"
          nil
        else
          id = activity["id"]?.try(&.as_s?)
          id ? "#{ctx.origin}\n#{id}\ncustom" : nil
        end
      end)
      .on_any(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled += 1
        nil
      end)
    ctx = federation.create_context
    create = Aptork.create(
      "https://remote.example/activities/custom-create",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    follow = Aptork.activity(
      "Follow",
      "https://remote.example/activities/custom-follow",
      "https://remote.example/users/bob",
      Aptork.object("Person", "https://local.example/users/alice")
    )

    trusted_options = Aptork::RouteActivityOptions.new(trusted: true)
    ctx.route_activity("alice", create, trusted_options).should be_true
    ctx.route_activity("alice", create, trusted_options).should be_false
    ctx.route_activity("alice", follow, trusted_options).should be_true
    ctx.route_activity("alice", follow, trusted_options).should be_true

    handled.should eq(3)
  end

  it "exposes personal inbox recipients to synchronous listeners" do
    seen_recipient = nil.as(String?)
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        seen_recipient = ctx.recipient_identifier
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/personal",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      body: activity.to_json
    ))

    response.status.should eq(202)
    seen_recipient.should eq("alice")
  end

  it "looks up remote actors through WebFinger handles" do
    actor = Aptork.actor(
      "Person",
      "https://remote.example/users/alice",
      "alice",
      "https://remote.example/users/alice/inbox",
      "https://remote.example/users/alice/outbox"
    )
    documents = {
      "https://remote.example/.well-known/webfinger?resource=acct%3Aalice%40remote.example" => Aptork.webfinger_jrd(
        "acct:alice@remote.example",
        "https://remote.example/users/alice"
      ),
      "https://remote.example/users/alice" => actor,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)

    looked_up = federation.create_context.lookup_object("@alice@remote.example").not_nil!

    looked_up["id"].as_s.should eq("https://remote.example/users/alice")
    looked_up["type"].as_s.should eq("Person")
  end

  it "looks up remote objects as typed vocabulary objects" do
    repository = Aptork.forgefed_repository(
      "https://forge.example/repos/aptork",
      "aptork",
      "https://forge.example/repos/aptork/inbox",
      "https://forge.example/repos/aptork/outbox",
      clone_uri: "https://forge.example/repos/aptork.git"
    )
    offer = Aptork.marketplace_offer(
      "https://market.example/offers/solver",
      "https://market.example/users/alice",
      Aptork.marketplace_product("https://market.example/products/solver", "Solver"),
      "Solver",
      "10",
      "USD"
    )
    documents = {
      "https://forge.example/repos/aptork"   => repository,
      "https://market.example/offers/solver" => offer,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    typed_repo = ctx.lookup_object("https://forge.example/repos/aptork", Aptork::Vocab::Repository).not_nil!
    typed_offer = Aptork::Remote.lookup_object(
      URI.parse("https://market.example/offers/solver"),
      Aptork::Vocab::MarketplaceOffer,
      ctx.document_loader
    ).not_nil!

    typed_repo.clone_uri.should eq("https://forge.example/repos/aptork.git")
    typed_offer.price_currency.should eq("USD")
    ctx.lookup_object("https://market.example/offers/solver", Aptork::Vocab::Repository).should be_nil
  end

  it "metadata document loader preserves status, content type, headers, and parsed JSON" do
    loader = Aptork::Remote.document_loader_with_metadata(->(_url : String, _headers : HTTP::Headers) do
      response_headers = HTTP::Headers{
        "Content-Type" => "application/activity+json",
        "X-Trace"      => "abc",
      }
      {200, Aptork.object("Note", "https://remote.example/notes/1").to_json, response_headers}
    end)

    document = loader.call("https://remote.example/notes/1").not_nil!

    document.url.should eq("https://remote.example/notes/1")
    document.status.should eq(200)
    document.content_type.should eq("application/activity+json")
    document.headers["X-Trace"].should eq("abc")
    document.json["type"].as_s.should eq("Note")
  end

  it "retries authenticated document fetches once after transient transport failures" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    attempts = 0
    signed_attempts = [] of HTTP::Headers
    loader = Aptork::Remote.authenticated_document_loader(
      key_pair,
      ->(_url : String, headers : HTTP::Headers) do
        attempts += 1
        signed_attempts << headers
        raise IO::Error.new("temporary network failure") if attempts == 1

        {200, Aptork.object("Note", "https://remote.example/notes/1").to_json}
      end
    )

    document = loader.call("https://remote.example/notes/1").not_nil!

    document["type"].as_s.should eq("Note")
    attempts.should eq(2)
    signed_attempts.size.should eq(2)
    signed_attempts.all? { |headers| headers["Signature"].includes?(%(keyId="https://local.example/users/alice#main-key")) }.should be_true
  end

  it "does not retry public document fetches unless configured" do
    attempts = 0
    loader = Aptork::Remote.default_document_loader(
      ->(_url : String, _headers : HTTP::Headers) do
        attempts += 1
        raise IO::Error.new("temporary network failure")
      end
    )

    loader.call("https://remote.example/notes/1").should be_nil

    attempts.should eq(1)
  end

  it "allows explicit transient retry counts for public document loaders" do
    attempts = 0
    loader = Aptork::Remote.default_document_loader(
      ->(_url : String, _headers : HTTP::Headers) do
        attempts += 1
        raise IO::Error.new("temporary network failure") if attempts < 3

        {200, Aptork.object("Note", "https://remote.example/notes/1").to_json}
      end,
      transient_retries: 2
    )

    loader.call("https://remote.example/notes/1").not_nil!["type"].as_s.should eq("Note")
    attempts.should eq(3)
  end

  it "metadata document loader rejects non-JSON ActivityPub documents" do
    loader = Aptork::Remote.document_loader_with_metadata(->(_url : String, _headers : HTTP::Headers) do
      {200, %(<html></html>), HTTP::Headers{"Content-Type" => "text/html"}}
    end)

    loader.call("https://remote.example/notes/1").should be_nil
  end

  it "adapts metadata document loaders back to legacy JSON document loaders" do
    metadata_loader = Aptork::Remote.document_loader_with_metadata(->(_url : String, _headers : HTTP::Headers) do
      {200, Aptork.object("Note", "https://remote.example/notes/1").to_json, HTTP::Headers{"Content-Type" => "application/activity+json"}}
    end)
    legacy_loader = Aptork::Remote.json_document_loader(metadata_loader)

    legacy_loader.call("https://remote.example/notes/1").not_nil!["type"].as_s.should eq("Note")
  end

  it "metadata document loader accepts WebFinger JRD content types" do
    loader = Aptork::Remote.document_loader_with_metadata(->(_url : String, _headers : HTTP::Headers) do
      {200, Aptork.webfinger_jrd("acct:alice@remote.example", "https://remote.example/users/alice").to_json, HTTP::Headers{"Content-Type" => "application/jrd+json"}}
    end)

    document = loader.call("https://remote.example/.well-known/webfinger").not_nil!

    document.content_type.should eq("application/jrd+json")
    document.json["subject"].as_s.should eq("acct:alice@remote.example")
  end

  it "rejects private document-loader URLs before calling the provider" do
    called = false
    loader = Aptork::Remote.default_document_loader(->(_url : String, _headers : HTTP::Headers) do
      called = true
      {200, Aptork.object("Note", "https://remote.example/notes/1").to_json}
    end)

    %w[
      http://localhost/actor
      http://127.0.0.1/actor
      http://10.0.0.1/actor
      http://172.16.0.1/actor
      http://192.168.0.1/actor
      http://169.254.0.1/actor
      http://[::1]/actor
      http://[fc00::1]/actor
      http://[fe80::1]/actor
    ].each do |url|
      loader.call(url).should be_nil
    end
    called.should be_false
  end

  it "allows private document-loader URLs when explicitly requested" do
    called_url = nil.as(String?)
    loader = Aptork::Remote.default_document_loader(
      ->(url : String, _headers : HTTP::Headers) do
        called_url = url
        {200, Aptork.object("Note", "http://127.0.0.1/notes/1").to_json}
      end,
      allow_private_address: true
    )

    document = loader.call("http://127.0.0.1/notes/1").not_nil!

    document["type"].as_s.should eq("Note")
    called_url.should eq("http://127.0.0.1/notes/1")
  end

  it "uses custom user agents for document loader requests" do
    seen_user_agent = nil.as(String?)
    loader = Aptork::Remote.default_document_loader(
      ->(_url : String, headers : HTTP::Headers) do
        seen_user_agent = headers["User-Agent"]?
        {200, Aptork.object("Note", "https://remote.example/notes/1").to_json}
      end,
      user_agent: "CustomUserAgent/1.2.3"
    )

    loader.call("https://remote.example/notes/1").should_not be_nil

    seen_user_agent.should eq("CustomUserAgent/1.2.3")
  end

  it "applies private-address protection to federation document providers" do
    called = false
    federation = Aptork::Federation.create(
      "https://local.example",
      document_get_provider: ->(_url : String, _headers : HTTP::Headers) do
        called = true
        {200, Aptork.object("Note", "http://127.0.0.1/notes/1").to_json}
      end
    )

    federation.create_context.lookup_object("http://127.0.0.1/notes/1").should be_nil
    called.should be_false
  end

  it "passes federation user agents to document providers" do
    seen_user_agent = nil.as(String?)
    federation = Aptork::Federation.create(
      "https://local.example",
      document_get_provider: ->(_url : String, headers : HTTP::Headers) do
        seen_user_agent = headers["User-Agent"]?
        {200, Aptork.object("Note", "https://remote.example/notes/1").to_json}
      end,
      user_agent: "AptorkApp/9.8.7"
    )

    federation.create_context.lookup_object("https://remote.example/notes/1").should_not be_nil

    federation.user_agent.should eq("AptorkApp/9.8.7")
    seen_user_agent.should eq("AptorkApp/9.8.7")
  end

  it "uses Fedify-style per-call document loaders for object lookup" do
    loader = ->(url : String) do
      if url == "https://remote.example/notes/1"
        Aptork.object("Note", "https://remote.example/notes/1").as(Aptork::JsonMap?)
      else
        nil.as(Aptork::JsonMap?)
      end
    end

    object = Aptork::Remote.lookup_object(
      "https://remote.example/notes/1",
      Aptork::LookupObjectOptions.new(document_loader: loader)
    ).not_nil!

    object["type"].as_s.should eq("Note")
  end

  it "accepts Crystal URI objects for Fedify-style object lookup" do
    loader = ->(url : String) do
      if url == "https://remote.example/notes/1"
        Aptork.object("Note", "https://remote.example/notes/1").as(Aptork::JsonMap?)
      else
        nil.as(Aptork::JsonMap?)
      end
    end

    remote_object = Aptork::Remote.lookup_object(
      URI.parse("https://remote.example/notes/1"),
      Aptork::LookupObjectOptions.new(document_loader: loader)
    ).not_nil!
    context_object = Aptork::Federation.create("https://local.example")
      .set_document_loader(loader)
      .create_context
      .lookup_object(URI.parse("https://remote.example/notes/1"))
      .not_nil!

    remote_object["type"].as_s.should eq("Note")
    context_object["id"].as_s.should eq("https://remote.example/notes/1")
  end

  it "lets context lookup options override the federation document loader" do
    federation_loader_called = false
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) do
        federation_loader_called = true
        nil.as(Aptork::JsonMap?)
      end)
    loader = ->(url : String) do
      if url == "https://remote.example/notes/1"
        Aptork.object("Note", "https://remote.example/notes/1").as(Aptork::JsonMap?)
      else
        nil.as(Aptork::JsonMap?)
      end
    end

    object = federation.create_context.lookup_object(
      "https://remote.example/notes/1",
      Aptork::LookupObjectOptions.new(document_loader: loader)
    ).not_nil!

    object["type"].as_s.should eq("Note")
    federation_loader_called.should be_false
  end

  it "lets context verification options override the federation document loader" do
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) { nil.as(Aptork::JsonMap?) })
    loader = ->(url : String) do
      if url == "https://remote.example/notes/1"
        Aptork.object("Note", "https://remote.example/notes/1").as(Aptork::JsonMap?)
      else
        nil.as(Aptork::JsonMap?)
      end
    end
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.object("Note", "https://remote.example/notes/1")
    )

    object = federation.create_context.verify_activity_object(
      activity,
      Aptork::LookupObjectOptions.new(document_loader: loader)
    ).not_nil!

    object["id"].as_s.should eq("https://remote.example/notes/1")
  end

  it "caches JSON document loader results in KV storage" do
    hits = 0
    cache = Aptork::MemoryKvStore.new
    base_loader = ->(_url : String) : Aptork::JsonMap? do
      hits += 1
      Aptork.object("Note", "https://remote.example/notes/#{hits}")
    end
    loader = Aptork::Remote.cached_json_document_loader(base_loader, cache)

    first = loader.call("https://remote.example/notes/1").not_nil!
    second = loader.call("https://remote.example/notes/1").not_nil!

    hits.should eq(1)
    first["id"].as_s.should eq("https://remote.example/notes/1")
    second["id"].as_s.should eq("https://remote.example/notes/1")
  end

  it "caches metadata document loader results with headers and content type" do
    hits = 0
    cache = Aptork::MemoryKvStore.new
    base_loader = Aptork::Remote.document_loader_with_metadata(->(_url : String, _headers : HTTP::Headers) do
      hits += 1
      {
        200,
        Aptork.object("Note", "https://remote.example/notes/#{hits}").to_json,
        HTTP::Headers{
          "Content-Type" => "application/activity+json",
          "X-Trace"      => "trace-#{hits}",
        },
      }
    end)
    loader = Aptork::Remote.cached_document_loader(base_loader, cache)

    first = loader.call("https://remote.example/notes/1").not_nil!
    second = loader.call("https://remote.example/notes/1").not_nil!

    hits.should eq(1)
    first.headers["X-Trace"].should eq("trace-1")
    second.headers["X-Trace"].should eq("trace-1")
    second.content_type.should eq("application/activity+json")
  end

  it "enables federation document cache for context lookups" do
    hits = 0
    documents = {
      "https://remote.example/users/alice" => Aptork.actor(
        "Person",
        "https://remote.example/users/alice",
        "alice",
        "https://remote.example/users/alice/inbox",
        "https://remote.example/users/alice/outbox"
      ),
    }
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
      .set_document_loader(->(url : String) do
        hits += 1
        documents[url]?.as(Aptork::JsonMap?)
      end)
      .enable_document_cache
    ctx = federation.create_context

    ctx.lookup_object("https://remote.example/users/alice").not_nil!["type"].as_s.should eq("Person")
    ctx.lookup_object("https://remote.example/users/alice").not_nil!["type"].as_s.should eq("Person")
    hits.should eq(1)
  end

  it "looks up WebFinger handles in multiple forms and chooses ActivityPub self links" do
    actor = Aptork.actor(
      "Person",
      "https://remote.example/users/alice",
      "alice",
      "https://remote.example/users/alice/inbox",
      "https://remote.example/users/alice/outbox"
    )
    webfinger = Aptork::JsonMap{
      "subject" => Aptork.json("acct:alice@remote.example"),
      "links"   => Aptork.json([
        {
          "rel"  => "self",
          "type" => "text/html",
          "href" => "https://remote.example/@alice",
        },
        {
          "rel"  => "self",
          "type" => "application/activity+json",
          "href" => "https://remote.example/users/alice",
        },
      ]),
    }
    documents = {
      "https://remote.example/.well-known/webfinger?resource=acct%3Aalice%40remote.example" => webfinger,
      "https://remote.example/users/alice"                                                  => actor,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.lookup_object("@alice@remote.example").not_nil!["id"].as_s.should eq("https://remote.example/users/alice")
    ctx.lookup_object("alice@remote.example").not_nil!["id"].as_s.should eq("https://remote.example/users/alice")
    ctx.lookup_object("acct:alice@remote.example").not_nil!["id"].as_s.should eq("https://remote.example/users/alice")
  end

  it "looks up WebFinger URI and mailto resources" do
    acct_jrd = Aptork.webfinger_jrd("acct:alice@remote.example", "https://remote.example/users/alice")
    mailto_resource = "mailto:juliet@example.com?subject=Hi"
    mailto_jrd = Aptork.webfinger_jrd(mailto_resource, "https://example.com/users/juliet")
    documents = {
      "https://remote.example/.well-known/webfinger?resource=acct%3Aalice%40remote.example"        => acct_jrd,
      "https://example.com/.well-known/webfinger?resource=#{URI.encode_www_form(mailto_resource)}" => mailto_jrd,
    }
    loader = ->(url : String) do
      documents[url]?.as(Aptork::JsonMap?)
    end
    ctx = Aptork::Federation.create("https://local.example")
      .set_document_loader(loader)
      .create_context

    Aptork::Remote.lookup_webfinger(
      URI.parse("acct:alice@remote.example"),
      Aptork::LookupWebFingerOptions.new(document_loader: loader)
    ).not_nil!["subject"].as_s.should eq("acct:alice@remote.example")
    ctx.lookup_webfinger(URI.parse(mailto_resource)).not_nil!["subject"].as_s.should eq(mailto_resource)
    ctx.lookup_webfinger("acct:alice@remote.example?bad=1").should be_nil
  end

  it "falls back to WebFinger when direct URL object lookup misses" do
    actor = Aptork.actor(
      "Person",
      "https://remote.example/users/alice",
      "alice",
      "https://remote.example/users/alice/inbox",
      "https://remote.example/users/alice/outbox"
    )
    documents = {
      "https://remote.example/.well-known/webfinger?resource=https%3A%2F%2Fremote.example%2F%40alice" => Aptork.webfinger_jrd(
        "https://remote.example/@alice",
        "https://remote.example/users/alice"
      ),
      "https://remote.example/users/alice" => actor,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)

    looked_up = federation.create_context.lookup_object("https://remote.example/@alice").not_nil!

    looked_up["id"].as_s.should eq("https://remote.example/users/alice")
  end

  it "applies cross-origin policy after URL WebFinger fallback" do
    actor = Aptork.actor(
      "Person",
      "https://evil.example/users/mallory",
      "mallory",
      "https://evil.example/users/mallory/inbox",
      "https://evil.example/users/mallory/outbox"
    )
    documents = {
      "https://remote.example/.well-known/webfinger?resource=https%3A%2F%2Fremote.example%2F%40mallory" => Aptork.webfinger_jrd(
        "https://remote.example/@mallory",
        "https://remote.example/ap/mallory"
      ),
      "https://remote.example/ap/mallory" => actor,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.lookup_object("https://remote.example/@mallory").should be_nil
    ctx.lookup_object(
      "https://remote.example/@mallory",
      Aptork::LookupObjectOptions.new(cross_origin: "trust")
    ).not_nil!["id"].as_s.should eq("https://evil.example/users/mallory")
    expect_raises(ArgumentError, "looked up object id has a different origin") do
      ctx.lookup_object(
        "https://remote.example/@mallory",
        Aptork::LookupObjectOptions.new(cross_origin: "throw")
      )
    end
    expect_raises(ArgumentError, "looked up object id has a different origin") do
      ctx.lookup_object(
        "https://remote.example/@mallory",
        Aptork::LookupObjectOptions.new(cross_origin: "raise")
      )
    end
  end

  it "discovers actor handles from actor URLs and objects through WebFinger" do
    actor = Aptork.actor(
      "Person",
      "https://foo.example.com/@john",
      "john",
      "https://foo.example.com/@john/inbox",
      "https://foo.example.com/@john/outbox"
    )
    documents = {
      "https://foo.example.com/.well-known/webfinger?resource=https%3A%2F%2Ffoo.example.com%2F%40john" => Aptork.webfinger_jrd(
        "acct:johndoe@foo.example.com",
        "https://foo.example.com/@john"
      ),
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    typed_actor = Aptork::Vocab::Person.from_json_ld(actor)
    ctx.get_actor_handle(actor).should eq("@johndoe@foo.example.com")
    ctx.get_actor_handle(typed_actor).should eq("@johndoe@foo.example.com")
    ctx.get_actor_handle(actor, Aptork::ActorHandleOptions.new(trim_leading_at: true)).should eq("johndoe@foo.example.com")
    Aptork.get_actor_handle(typed_actor, ctx.document_loader, Aptork::ActorHandleOptions.new(trim_leading_at: true)).should eq("johndoe@foo.example.com")
    ctx.get_actor_handle("https://foo.example.com/@john").should eq("@johndoe@foo.example.com")
    Aptork.normalize_actor_handle("@John@FOO.EXAMPLE.COM").should eq("@John@foo.example.com")
    Aptork.normalize_actor_handle("@quux@XN--MAANA-PTA.COM", Aptork::ActorHandleOptions.new(trim_leading_at: true)).should eq("quux@mañana.com")
    Aptork.normalize_actor_handle("@BAZ@☃-⌘.com", Aptork::ActorHandleOptions.new(punycode: true)).should eq("@BAZ@xn----dqo34k.com")
    Aptork.normalize_actor_handle("@quux@MAÑANA.COM", Aptork::ActorHandleOptions.new(punycode: true)).should eq("@quux@xn--maana-pta.com")
  end

  it "verifies cross-origin actor handle aliases and falls back to preferred username" do
    actor = Aptork.actor(
      "Person",
      "https://foo.example.com/@john",
      "john",
      "https://foo.example.com/@john/inbox",
      "https://foo.example.com/@john/outbox"
    )
    documents = {
      "https://foo.example.com/.well-known/webfinger?resource=https%3A%2F%2Ffoo.example.com%2F%40john" => Aptork.webfinger_jrd(
        "https://foo.example.com/@john",
        "https://foo.example.com/@john",
        ["acct:john@bar.example.com", "acct:johndoe@foo.example.com"]
      ),
      "https://bar.example.com/.well-known/webfinger?resource=acct%3Ajohn%40bar.example.com" => Aptork.webfinger_jrd(
        "acct:john@bar.example.com",
        "https://foo.example.com/@john",
        ["https://foo.example.com/@john"]
      ),
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.get_actor_handle(actor).should eq("@john@bar.example.com")

    fallback = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) { nil.as(Aptork::JsonMap?) })
      .create_context
    fallback.get_actor_handle(actor).should eq("@john@foo.example.com")
    expect_raises(ArgumentError, "actor handle not found") do
      fallback.get_actor_handle("https://foo.example.com/@john")
    end
  end

  it "builds object URIs and parses local actor, collection, and object routes" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(
        ctx.get_object_uri("Note", params),
        "Hello"
      ).as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Article", "/articles/{identifier}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.article(
        ctx.get_object_uri(Aptork::Vocab::Article, params),
        name: "Hello"
      ).as(Aptork::JsonMap?)
    end)
    federation.set_collection_dispatcher("featured", "/users/{identifier}/collections/featured", ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end)
    federation.set_collection_dispatcher("repo-tags", "/repos/{owner}/{repo}/tags", ->(_ctx : Aptork::Context, params : Hash(String, String)) do
      [Aptork.object("Hashtag", "https://local.example/repos/#{params["owner"]}/#{params["repo"]}/tags/crystal", Aptork::JsonMap{"name" => Aptork.json(params["repo"])})]
    end)
    ctx = federation.create_context

    note_uri = ctx.get_object_uri("Note", {
      "identifier" => "alice",
      "note_id"    => "1",
    })
    named_note_uri = ctx.get_object_uri("Note", {identifier: "alice", note_id: 3})
    typed_note_uri = ctx.get_object_uri(Aptork::Vocab::Note, {
      "identifier" => "alice",
      "note_id"    => "2",
    })
    typed_named_note_uri = ctx.get_object_uri(Aptork::Vocab::Note, {identifier: "alice", note_id: "4"})
    repo_tags_uri = ctx.get_collection_uri("repo-tags", {owner: "aptork-dev", repo: "aptork"})
    parsed_actor = ctx.parse_uri("https://local.example/users/alice").not_nil!
    parsed_actor_from_uri = ctx.parse_uri(URI.parse("https://local.example/users/alice")).not_nil!
    parsed_outbox = ctx.parse_uri("https://local.example/actors/alice/outbox").not_nil!
    parsed_featured = ctx.parse_uri("https://local.example/users/alice/collections/featured").not_nil!
    parsed_note = ctx.parse_uri(note_uri).not_nil!

    note_uri.should eq("https://local.example/users/alice/notes/1")
    named_note_uri.should eq("https://local.example/users/alice/notes/3")
    typed_note_uri.should eq("https://local.example/users/alice/notes/2")
    typed_named_note_uri.should eq("https://local.example/users/alice/notes/4")
    repo_tags_uri.should eq("https://local.example/repos/aptork-dev/aptork/tags")
    ctx.get_object_uri(Aptork::Vocab::Article, "intro").should eq("https://local.example/articles/intro")
    parsed_actor.type.should eq("actor")
    parsed_actor_from_uri.type.should eq("actor")
    parsed_actor.identifier.should eq("alice")
    parsed_outbox.type.should eq("collection")
    parsed_outbox.collection_name.should eq("outbox")
    parsed_featured.collection_name.should eq("featured")
    parsed_note.type.should eq("object")
    parsed_note.object_type.should eq("Note")
    parsed_note.values.should eq({"identifier" => "alice", "note_id" => "1"})
    ctx.object("Note", {"identifier" => "alice", "note_id" => "1"}).not_nil!["id"].as_s.should eq(note_uri)
    ctx.object("Note", {identifier: "alice", note_id: "3"}).not_nil!["id"].as_s.should eq(named_note_uri)
    typed_note = ctx.get_object(Aptork::Vocab::Note, {
      "identifier" => "alice",
      "note_id"    => "1",
    }).not_nil!
    typed_named_note = ctx.get_object(Aptork::Vocab::Note, {identifier: "alice", note_id: 4}).not_nil!
    typed_note.should be_a(Aptork::Vocab::Note)
    typed_note.id.should eq(note_uri)
    typed_named_note.id.should eq(typed_named_note_uri)
    typed_article = ctx.object(Aptork::Vocab::Article, "intro").not_nil!
    typed_article.name.should eq("Hello")
    ctx.collection("repo-tags", {owner: "aptork-dev", repo: "aptork"}).first["name"].as_s.should eq("aptork")
    ctx.parse_uri(nil).should be_nil
    ctx.parse_uri("https://remote.example/users/alice").should be_nil
  end

  it "gets actors with Fedify-style tombstone options" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      if identifier == "gone"
        Aptork.tombstone(ctx.get_actor_uri(identifier), "Person", "2026-05-22T00:00:00Z").as(Aptork::JsonMap?)
      else
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ).as(Aptork::JsonMap?)
      end
    end)
    ctx = federation.create_context

    ctx.get_actor("alice").not_nil!["preferredUsername"].as_s.should eq("alice")
    typed_actor = ctx.get_actor("alice", Aptork::Vocab::Person).not_nil!
    typed_actor.preferred_username.should eq("alice")
    ctx.actor("alice", Aptork::Vocab::Person).not_nil!.inbox.should eq("https://local.example/actors/alice/inbox")
    ctx.get_actor("gone").should be_nil
    tombstone = ctx.get_actor("gone", Aptork::GetActorOptions.new(tombstone: "passthrough")).not_nil!
    tombstone["type"].as_s.should eq("Tombstone")
    tombstone["formerType"].as_s.should eq("Person")
    typed_tombstone = ctx.get_actor("gone", Aptork::Vocab::Tombstone, Aptork::GetActorOptions.new(tombstone: "passthrough")).not_nil!
    typed_tombstone.former_type.should eq("Person")
  end

  it "gets objects and raises from Fedify-style getters when dispatchers are missing" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_object_dispatcher("Note", "/notes/{identifier}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(ctx.get_object_uri("Note", params), "Hello").as(Aptork::JsonMap?)
    end)
    ctx = federation.create_context

    ctx.get_object("Note", "1").not_nil!["id"].as_s.should eq("https://local.example/notes/1")
    expect_raises(ArgumentError, "No actor dispatcher registered") do
      ctx.get_actor("alice")
    end
    expect_raises(ArgumentError, "No object dispatcher registered for Ticket") do
      ctx.get_object("Ticket", "1")
    end
  end

  it "builds unordered collection vocabulary objects" do
    items = [Aptork.note("https://local.example/notes/1", "One")]
    collection = Aptork.collection("https://local.example/bookmarks", items)
    page = Aptork.collection_page("https://local.example/bookmarks?page=1", "https://local.example/bookmarks", items)
    paged = Aptork.paginated_collection("https://local.example/bookmarks", items, page: 1)

    collection["type"].as_s.should eq("Collection")
    collection["items"].as_a.first.as_h["content"].as_s.should eq("One")
    page["type"].as_s.should eq("CollectionPage")
    page["items"].as_a.first.as_h["content"].as_s.should eq("One")
    paged["type"].as_s.should eq("CollectionPage")
    paged["items"].as_a.first.as_h["content"].as_s.should eq("One")

    parsed_collection = Aptork::Vocab::Object.from_json_ld(collection)
    parsed_collection.should be_a(Aptork::Vocab::Collection)
    parsed_collection.as(Aptork::Vocab::Collection).total_items.should eq(1)
    parsed_collection.as(Aptork::Vocab::Collection).items.first.should be_a(Aptork::Vocab::Note)
    parsed_page = Aptork::Vocab::Object.from_json_ld(page)
    parsed_page.should be_a(Aptork::Vocab::CollectionPage)
    parsed_page.as(Aptork::Vocab::CollectionPage).part_of.should eq("https://local.example/bookmarks")
    parsed_page.as(Aptork::Vocab::CollectionPage).items.first.should be_a(Aptork::Vocab::Note)
  end

  it "parses ordered collection vocabulary objects" do
    items = [Aptork.note("https://local.example/notes/1", "One")]
    collection = Aptork.ordered_collection("https://local.example/outbox", items, 3)
    collection["first"] = Aptork.json("https://local.example/outbox?page=1")
    page = Aptork.ordered_collection_page(
      "https://local.example/outbox?page=1",
      "https://local.example/outbox",
      items,
      "https://local.example/outbox?page=2"
    )

    parsed_collection = Aptork::Vocab::Object.from_json_ld(collection)
    parsed_collection.should be_a(Aptork::Vocab::OrderedCollection)
    ordered_collection = parsed_collection.as(Aptork::Vocab::OrderedCollection)
    ordered_collection.total_items.should eq(3)
    ordered_collection.items.first.should be_a(Aptork::Vocab::Note)
    ordered_collection.first.should eq("https://local.example/outbox?page=1")
    parsed_page = Aptork::Vocab::Object.from_json_ld(page)
    parsed_page.should be_a(Aptork::Vocab::OrderedCollectionPage)
    ordered_page = parsed_page.as(Aptork::Vocab::OrderedCollectionPage)
    ordered_page.part_of.should eq("https://local.example/outbox")
    ordered_page.next.should eq("https://local.example/outbox?page=2")
    ordered_page.prev.should be_nil
    ordered_page.items.first.should be_a(Aptork::Vocab::Note)
  end

  it "raises for unknown object URI routes and missing URI template parameters" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(_ctx : Aptork::Context, _params : Hash(String, String)) do
      nil.as(Aptork::JsonMap?)
    end)
    ctx = federation.create_context

    expect_raises(ArgumentError, "object dispatcher is not configured for Ticket") do
      ctx.get_object_uri("Ticket", {"identifier" => "alice", "ticket_id" => "1"})
    end
    expect_raises(ArgumentError, "missing URI template parameter: note_id") do
      ctx.get_object_uri("Note", {"identifier" => "alice"})
    end
  end

  it "supports reserved URI template expansion for URI-like identifiers" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/actors/{+identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end)
    ctx = federation.create_context

    actor_uri = ctx.get_actor_uri("https://remote.example/users/alice")
    parsed = ctx.parse_uri(actor_uri).not_nil!

    actor_uri.should eq("https://local.example/actors/https://remote.example/users/alice")
    parsed.type.should eq("actor")
    parsed.identifier.should eq("https://remote.example/users/alice")
  end

  it "does not dispatch reserved URI template routes with empty identifiers" do
    dispatches = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/actors/{+identifier}", ->(_ctx : Aptork::Context, identifier : String) do
      dispatches << identifier
      Aptork.actor("Person", "https://local.example/actors/#{identifier}", identifier, "https://local.example/actors/#{identifier}/inbox", "https://local.example/actors/#{identifier}/outbox").as(Aptork::JsonMap?)
    end)
    ctx = federation.create_context

    response = federation.handle(Aptork::Request.new(
      "GET",
      "/actors/",
      headers: {"Accept" => "application/activity+json"}
    ))

    response.status.should eq(404)
    dispatches.should be_empty
    ctx.parse_uri("https://local.example/actors/").should be_nil
  end

  it "looks up direct ForgeFed objects and enforces cross-origin policy" do
    ticket = Aptork.forgefed_ticket(
      "https://forge.example/tickets/1",
      "Bug",
      "Fix it"
    )
    spoofed = Aptork.forgefed_ticket(
      "https://elsewhere.example/tickets/1",
      "Spoof",
      "Wrong origin"
    )
    documents = {
      "https://forge.example/tickets/1"       => ticket,
      "https://forge.example/tickets/spoofed" => spoofed,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.lookup_object("https://forge.example/tickets/1").not_nil!["type"].as_s.should eq("Ticket")
    ctx.lookup_object("https://forge.example/tickets/spoofed").should be_nil
    ctx.lookup_object(
      "https://forge.example/tickets/spoofed",
      Aptork::LookupObjectOptions.new(cross_origin: "trust")
    ).not_nil!["id"].as_s.should eq("https://elsewhere.example/tickets/1")
    expect_raises(ArgumentError, "looked up object id has a different origin") do
      ctx.lookup_object(
        "https://forge.example/tickets/spoofed",
        Aptork::LookupObjectOptions.new(cross_origin: "throw")
      )
    end
    expect_raises(ArgumentError, "looked up object id has a different origin") do
      ctx.lookup_object(
        "https://forge.example/tickets/spoofed",
        Aptork::LookupObjectOptions.new(cross_origin: "raise")
      )
    end
  end

  it "verifies activity objects and fetches cross-origin embedded objects by id" do
    remote_note = Aptork.note("https://remote.example/notes/1", "Remote")
    spoofed = Aptork.note("https://remote.example/notes/spoofed", "Spoofed")
    spoofed["id"] = Aptork.json("https://evil.example/notes/1")
    documents = {
      "https://remote.example/notes/1"       => remote_note,
      "https://remote.example/notes/spoofed" => spoofed,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context
    same_origin = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      remote_note
    )
    cross_origin = Aptork.create(
      "https://local.example/activities/2",
      "https://local.example/users/alice",
      remote_note
    )
    spoofed_activity = Aptork.create(
      "https://local.example/activities/3",
      "https://local.example/users/alice",
      spoofed
    )

    ctx.verify_activity_object(same_origin).not_nil!["id"].as_s.should eq("https://remote.example/notes/1")
    ctx.verify_activity_object(cross_origin).not_nil!["id"].as_s.should eq("https://remote.example/notes/1")
    ctx.verify_activity_object(spoofed_activity).should be_nil
  end

  it "verifies activity object cross-origin trust and throw modes" do
    spoofed = Aptork.note("https://remote.example/notes/spoofed", "Spoofed")
    spoofed["id"] = Aptork.json("https://evil.example/notes/1")
    documents = {
      "https://remote.example/notes/spoofed" => spoofed,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.object("Note", "https://remote.example/notes/spoofed")
    )

    trusted = ctx.verify_activity_object(
      activity,
      Aptork::LookupObjectOptions.new(cross_origin: "trust")
    ).not_nil!

    trusted["id"].as_s.should eq("https://evil.example/notes/1")
    expect_raises(ArgumentError, "looked up object id has a different origin") do
      ctx.verify_activity_object(
        activity,
        Aptork::LookupObjectOptions.new(cross_origin: "throw")
      )
    end
  end

  it "traverses inline and paged marketplace collections" do
    offer_1 = Aptork.marketplace_offer(
      "https://market.example/offers/1",
      "https://market.example/users/alice",
      Aptork.object("Service", "https://market.example/services/1"),
      "Solver"
    )
    offer_2 = Aptork.marketplace_offer(
      "https://market.example/offers/2",
      "https://market.example/users/bob",
      Aptork.object("Product", "https://market.example/products/2"),
      "Widget"
    )
    page_1 = Aptork.ordered_collection_page(
      "https://market.example/offers?page=1",
      "https://market.example/offers",
      [offer_1],
      "https://market.example/offers?page=2"
    )
    page_2 = Aptork.ordered_collection_page(
      "https://market.example/offers?page=2",
      "https://market.example/offers",
      [offer_2]
    )
    collection = Aptork.ordered_collection("https://market.example/offers", [] of Aptork::JsonMap, 2)
    collection["first"] = Aptork.json("https://market.example/offers?page=1")
    documents = {
      "https://market.example/offers"        => collection,
      "https://market.example/offers?page=1" => page_1,
      "https://market.example/offers?page=2" => page_2,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    inline = ctx.traverse_collection(Aptork.ordered_collection("https://market.example/inline", [offer_1]))
    paged = ctx.traverse_collection("https://market.example/offers")
    option_loaded = Aptork::Federation.create("https://local.example").create_context.traverse_collection(
      URI.parse("https://market.example/offers"),
      Aptork::TraverseCollectionOptions.new(document_loader: ->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    )

    inline.size.should eq(1)
    paged.size.should eq(2)
    option_loaded.size.should eq(2)
    paged.map { |item| item["type"].as_s }.should eq(["Offer", "Offer"])
  end

  it "starts collection traversal from first page when present" do
    inline_offer = Aptork.marketplace_offer(
      "https://market.example/offers/inline",
      "https://market.example/users/alice",
      Aptork.object("Service", "https://market.example/services/inline"),
      "Inline offer"
    )
    page_offer = Aptork.marketplace_offer(
      "https://market.example/offers/page",
      "https://market.example/users/bob",
      Aptork.object("Product", "https://market.example/products/page"),
      "Paged offer"
    )
    collection = Aptork.ordered_collection(
      "https://market.example/offers",
      [inline_offer],
      2
    )
    collection["first"] = Aptork.json("https://market.example/offers?page=1")
    page = Aptork.ordered_collection_page(
      "https://market.example/offers?page=1",
      "https://market.example/offers",
      [page_offer]
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        url == "https://market.example/offers?page=1" ? page : nil
      end)
    ctx = federation.create_context

    items = ctx.traverse_collection(collection)

    items.map { |item| item["id"].as_s }.should eq(["https://market.example/offers/page"])
  end

  it "traverses typed collection vocabulary objects" do
    offer = Aptork.marketplace_offer(
      "https://market.example/offers/typed",
      "https://market.example/users/alice",
      Aptork.marketplace_product("https://market.example/products/typed", "Typed product"),
      "Typed offer",
      "10",
      "USD"
    )
    commit = Aptork.forgefed_commit(
      "https://forge.example/repos/aptork/commits/abc",
      "https://forge.example/repos/aptork",
      "abc",
      "https://forge.example/users/alice",
      "Add federation"
    )
    page = Aptork.ordered_collection_page(
      "https://market.example/offers?page=1",
      "https://market.example/offers",
      [offer]
    )
    collection = Aptork.ordered_collection("https://market.example/offers", [] of Aptork::JsonMap, 1)
    collection["first"] = Aptork.json("https://market.example/offers?page=1")
    push = Aptork.forgefed_push(
      "https://forge.example/repos/aptork/outbox/push-1",
      "https://forge.example/repos/aptork",
      "https://forge.example/users/alice",
      "https://forge.example/repos/aptork/branches/main",
      [commit],
      "000",
      "abc"
    )
    documents = {
      "https://market.example/offers?page=1" => page,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    typed_collection = Aptork::Vocab::OrderedCollection.from_json_ld(collection)
    traversed_offers = ctx.traverse_collection(typed_collection)
    typed_push = Aptork::Vocab::Push.from_json_ld(push)
    commit_collection = typed_push.object.as(Aptork::Vocab::OrderedCollection)
    traversed_commits = ctx.traverse_collection(commit_collection)

    traversed_offers.first.should be_a(Aptork::Vocab::MarketplaceOffer)
    traversed_offers.first.as(Aptork::Vocab::MarketplaceOffer).price_currency.should eq("USD")
    traversed_commits.first.should be_a(Aptork::Vocab::Commit)
    traversed_commits.first.as(Aptork::Vocab::Commit).hash.should eq("abc")
  end

  it "suppresses collection traversal page errors when configured" do
    offer = Aptork.marketplace_offer(
      "https://market.example/offers/1",
      "https://market.example/users/alice",
      Aptork.object("Product", "https://market.example/products/1"),
      "Solver",
      "10",
      "USD"
    )
    collection = Aptork.ordered_collection_page(
      "https://market.example/offers?page=1",
      "https://market.example/offers",
      [offer],
      "https://market.example/offers?page=2"
    )
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(_url : String) do
        raise "page unavailable"
      end)
    ctx = federation.create_context

    items = ctx.traverse_collection(
      collection,
      Aptork::TraverseCollectionOptions.new(suppress_error: true)
    )

    items.size.should eq(1)
    items.first["id"].as_s.should eq("https://market.example/offers/1")
    expect_raises(Exception, /page unavailable/) do
      ctx.traverse_collection(collection)
    end
  end

  it "builds authenticated document loaders from actor key pairs" do
    captured_headers = HTTP::Headers.new
    key_pair = nil.as(Aptork::ActorKeyPair?)
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {
        200,
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ).to_json,
      }
    end
    federation = Aptork::Federation.create("https://local.example", user_agent: "AptorkSignedFetch/1.0")
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      key_pair = generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))
      [key_pair.not_nil!]
    end)
    ctx = federation.create_context
    loader = ctx.get_document_loader("alice", provider)

    object = Aptork::Remote.lookup_object("https://remote.example/users/bob", loader).not_nil!
    request = Aptork::Request.new(
      "GET",
      "/users/bob",
      headers: {
        "Date"      => captured_headers["Date"],
        "Host"      => captured_headers["Host"],
        "Digest"    => captured_headers["Digest"],
        "Signature" => captured_headers["Signature"],
      },
      body: ""
    )

    object["id"].as_s.should eq("https://remote.example/users/bob")
    captured_headers["User-Agent"].should eq("AptorkSignedFetch/1.0")
    captured_headers["Signature"].includes?(%(keyId="https://local.example/actors/alice#main-key")).should be_true
    Aptork::Signatures.verify_rsa_sha256?(request, key_pair.not_nil!).should be_true
  end

  it "rejects unsupported explicit signed-fetch key pairs" do
    federation = Aptork::Federation.create("https://local.example")
    ctx = federation.create_context
    ed25519_key = generate_ed25519_test_key_pair("https://local.example/users/alice")
    public_only_key = Aptork::ActorKeyPair.new(
      "https://local.example/users/alice#main-key",
      "https://local.example/users/alice",
      ed25519_key.public_key_pem
    )

    expect_raises(ArgumentError, /RSA-SHA256 key pair/) do
      ctx.get_document_loader(ed25519_key)
    end
    expect_raises(ArgumentError, /private key/) do
      Aptork::Remote.authenticated_document_loader(public_only_key)
    end
  end

  it "builds authenticated document loaders from mapped sender usernames" do
    captured_headers = HTTP::Headers.new
    key_pair = nil.as(Aptork::ActorKeyPair?)
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {
        200,
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ).to_json,
      }
    end
    federation = Aptork::Federation.create("https://local.example")
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      key_pair = generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))
      [key_pair.not_nil!]
    end)
    ctx = federation.create_context
    loader = ctx.get_document_loader({username: "alice"}, provider)

    Aptork::Remote.lookup_object("https://remote.example/users/bob", loader).not_nil!

    captured_headers["Signature"].includes?(%(keyId="https://local.example/actors/user-123#main-key")).should be_true
  end

  it "falls back to the public document loader for unmapped sender usernames" do
    captured_headers = HTTP::Headers.new
    provider = ->(_url : String, headers : HTTP::Headers) do
      captured_headers = headers
      {200, Aptork.note("https://remote.example/notes/1", "Public").to_json}
    end
    federation = Aptork::Federation.create(
      "https://local.example",
      document_loader: Aptork::Remote.default_document_loader(provider)
    )
    federation.map_handle(->(_ctx : Aptork::Context, _username : String) { nil.as(String?) })
    ctx = federation.create_context
    loader = ctx.get_document_loader({username: "missing"})

    Aptork::Remote.lookup_object("https://remote.example/notes/1", loader).not_nil!

    captured_headers.has_key?("Signature").should be_false
  end

  it "authorizes actor GET requests with signed fetch key ownership" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example")
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      if identifier == "alice"
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ).as(Aptork::JsonMap?)
      else
        nil
      end
    end)
    federation.set_actor_authorizer(->(_ctx : Aptork::Context, _request : Aptork::Request, verification : Aptork::VerificationResult, _identifier : String?, _params : Hash(String, String)) do
      verification.verified && verification.signer_actor == remote_key.owner
    end)

    signed_headers = Aptork::Signatures.rsa_sha256_headers("get", "https://local.example/users/alice", "", remote_key)
    unsigned = federation.handle(activitypub_get("/users/alice"))
    signed = federation.handle(activitypub_get("/users/alice", headers: signed_headers))
    missing = federation.handle(activitypub_get("/users/missing"))

    unsigned.status.should eq(401)
    signed.status.should eq(200)
    missing.status.should eq(404)
    JSON.parse(signed.body).as_h["preferredUsername"].as_s.should eq("alice")
  end

  it "exposes signed key helpers on request contexts" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    remote_actor = Aptork.actor(
      "Person",
      remote_key.owner,
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox"
    )
    federation = Aptork::Federation.create("https://local.example")
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    signed_headers = Aptork::Signatures.rsa_sha256_headers("get", "https://local.example/users/alice", "", remote_key)
    request = activitypub_get("/users/alice", headers: signed_headers)
    ctx = federation.create_context.with_inbound_request(request)
    owner_options = Aptork::GetSignedKeyOptions.new(
      document_loader: ->(url : String) do
        url == remote_key.owner ? remote_actor : nil.as(Aptork::JsonMap?)
      end
    )

    ctx.get_signed_key.try(&.id).should eq(remote_key.id)
    ctx.get_signed_key_owner.should eq(remote_key.owner)
    ctx.get_signed_key_owner(request).should eq(remote_key.owner)
    ctx.get_signed_key_owner_actor(owner_options).not_nil!.preferred_username.should eq("bob")
    ctx.get_signed_key_owner(Aptork::Vocab::Person, owner_options).not_nil!.inbox.should eq("https://remote.example/users/bob/inbox")
    federation.create_context.get_signed_key.should be_nil
    federation.create_context.get_signed_key_owner.should be_nil
    federation.create_context.get_signed_key_owner_actor(owner_options).should be_nil
  end

  it "authorizes object and collection GET routes independently" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example")
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    dispatched_offer_ids = [] of String
    federation.set_object_dispatcher("Offer", "/offers/{offer_id}", ->(_ctx : Aptork::Context, params : Hash(String, String)) do
      dispatched_offer_ids << params["offer_id"]
      if params["offer_id"] == "missing"
        nil.as(Aptork::JsonMap?)
      else
        Aptork.marketplace_offer(
          "https://local.example/offers/#{params["offer_id"]}",
          "https://local.example/users/alice",
          Aptork.object("Service", "https://local.example/services/1"),
          "Solver"
        ).as(Aptork::JsonMap?)
      end
    end)
    federation.set_ordered_collection_dispatcher("featured", "/users/{identifier}/collections/featured", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/featured/1", "Pinned")]
    end)
    federation.configure_object("Offer")
      .authorize(->(_ctx : Aptork::Context, _request : Aptork::Request, verification : Aptork::VerificationResult, _identifier : String?, _params : Hash(String, String)) do
        verification.signer_actor == remote_key.owner
      end)
    federation.set_collection_authorizer("featured", ->(_ctx : Aptork::Context, _request : Aptork::Request, verification : Aptork::VerificationResult, identifier : String?, _params : Hash(String, String)) do
      identifier == "alice" && verification.signer_actor == remote_key.owner
    end)

    object_headers = Aptork::Signatures.rsa_sha256_headers("get", "https://local.example/offers/1", "", remote_key)
    collection_headers = Aptork::Signatures.rsa_sha256_headers("get", "https://local.example/users/alice/collections/featured", "", remote_key)
    object_response = federation.handle(activitypub_get("/offers/1", headers: object_headers))
    collection_response = federation.handle(activitypub_get("/users/alice/collections/featured", headers: collection_headers))
    denied = federation.handle(activitypub_get("/offers/1"))
    missing = federation.handle(activitypub_get("/offers/missing"))

    object_response.status.should eq(200)
    JSON.parse(object_response.body).as_h["type"].as_s.should eq("Offer")
    collection_response.status.should eq(200)
    JSON.parse(collection_response.body).as_h["type"].as_s.should eq("OrderedCollection")
    denied.status.should eq(401)
    missing.status.should eq(404)
    dispatched_offer_ids.should contain("missing")
  end

  it "rejects signed fetch when the signature key cannot be resolved" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example")
    federation.set_signature_key_resolver(->(_key_id : String) do
      nil.as(Aptork::ActorKeyPair?)
    end)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_actor_authorizer(->(_ctx : Aptork::Context, _request : Aptork::Request, verification : Aptork::VerificationResult, _identifier : String?, _params : Hash(String, String)) do
      verification.verified
    end)

    headers = Aptork::Signatures.rsa_sha256_headers("get", "https://local.example/users/alice", "", remote_key)
    response = federation.handle(activitypub_get("/users/alice", headers: headers))

    response.status.should eq(401)
  end

  it "looks up remote NodeInfo documents through well-known discovery" do
    nodeinfo = Aptork.nodeinfo("remote-server", "2.0.0", users_total: 42)
    documents = {
      "https://remote.example/.well-known/nodeinfo" => Aptork.nodeinfo_well_known("https://remote.example/nodeinfo/2.1"),
      "https://remote.example/nodeinfo/2.1"         => nodeinfo,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)

    looked_up = federation.create_context.lookup_nodeinfo("https://remote.example/").not_nil!

    looked_up["version"].as_s.should eq("2.1")
    looked_up["software"].as_h["name"].as_s.should eq("remote-server")
    looked_up["usage"].as_h["users"].as_h["total"].as_i.should eq(42)
  end

  it "uses Fedify-style application/json Accept headers for default NodeInfo lookup" do
    seen_headers = [] of HTTP::Headers
    nodeinfo = Aptork.nodeinfo("remote-server", "2.0.0")
    provider = ->(url : String, headers : HTTP::Headers) do
      seen_headers << headers
      case url
      when "https://remote.example/.well-known/nodeinfo"
        {200, Aptork.nodeinfo_well_known("https://remote.example/nodeinfo/2.1").to_json}
      when "https://remote.example/nodeinfo/2.1"
        {200, nodeinfo.to_json}
      else
        {404, "{}"}
      end
    end

    looked_up = Aptork.lookup_nodeinfo(
      "https://remote.example",
      Aptork::NodeInfoLookupOptions.new(document_get_provider: provider)
    ).not_nil!

    looked_up["software"].as_h["name"].as_s.should eq("remote-server")
    seen_headers.size.should eq(2)
    seen_headers.all? { |headers| headers["Accept"] == "application/json" }.should be_true
  end

  it "looks up NodeInfo from Crystal URI origins and normalizes well-known discovery to the origin root" do
    nodeinfo = Aptork.nodeinfo("remote-server", "2.0.0")
    requested = [] of String
    documents = {
      "https://remote.example/.well-known/nodeinfo" => Aptork.nodeinfo_well_known("https://remote.example/nodeinfo/2.1"),
      "https://remote.example/nodeinfo/2.1"         => nodeinfo,
      "https://remote.example/custom/nodeinfo"      => nodeinfo,
    }
    loader = ->(url : String) do
      requested << url
      documents[url]?.as(Aptork::JsonMap?)
    end
    options = Aptork::NodeInfoLookupOptions.new(document_loader: loader)

    discovered = Aptork.lookup_nodeinfo(URI.parse("https://remote.example/users/alice"), options).not_nil!
    direct = Aptork::Federation.create("https://local.example")
      .create_context
      .lookup_nodeinfo(
        URI.parse("https://remote.example/custom/nodeinfo"),
        Aptork::NodeInfoLookupOptions.new(document_loader: loader, direct: true)
      )
      .not_nil!

    discovered["software"].as_h["name"].as_s.should eq("remote-server")
    direct["software"].as_h["name"].as_s.should eq("remote-server")
    requested.should contain("https://remote.example/.well-known/nodeinfo")
    requested.should_not contain("https://remote.example/users/alice/.well-known/nodeinfo")
    requested.should contain("https://remote.example/custom/nodeinfo")
  end

  it "supports best-effort NodeInfo parsing for slightly invalid documents" do
    invalid = Aptork::JsonMap{
      "software"  => Aptork.json({"name" => "remote-server"}),
      "protocols" => Aptork.json(["activitypub"]),
    }
    documents = {
      "https://remote.example/.well-known/nodeinfo" => Aptork.nodeinfo_well_known("https://remote.example/nodeinfo/2.1"),
      "https://remote.example/nodeinfo/2.1"         => invalid,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.lookup_nodeinfo("https://remote.example").should be_nil
    ctx.lookup_nodeinfo("https://remote.example", parse: "best-effort").not_nil!["software"].as_h["name"].as_s.should eq("remote-server")
  end

  it "supports direct and raw NodeInfo lookup and uses the first recognized well-known link" do
    raw = Aptork::JsonMap{
      "software" => Aptork.json({"name" => "remote-server"}),
    }
    discovery = Aptork::JsonMap{
      "links" => Aptork.json([
        {
          "rel"  => Aptork::NODEINFO_2_0_REL,
          "href" => "https://remote.example/nodeinfo/2.0",
        },
        {
          "rel"  => Aptork::NODEINFO_2_1_REL,
          "href" => "https://remote.example/nodeinfo/2.1",
        },
      ]),
    }
    nodeinfo_2_0 = Aptork.nodeinfo("remote-server", "2.0.0")
    nodeinfo_2_0["version"] = Aptork.json("2.0")
    nodeinfo_2_1 = Aptork.nodeinfo("remote-server", "2.1.0")
    documents = {
      "https://remote.example/.well-known/nodeinfo" => discovery,
      "https://remote.example/nodeinfo/2.0"         => nodeinfo_2_0,
      "https://remote.example/nodeinfo/2.1"         => nodeinfo_2_1,
      "https://remote.example/raw-nodeinfo"         => raw,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    fallback = ctx.lookup_nodeinfo("https://remote.example").not_nil!
    direct_raw = ctx.lookup_nodeinfo(
      "https://remote.example/raw-nodeinfo",
      Aptork::NodeInfoLookupOptions.new(direct: true, parse: "none")
    ).not_nil!

    fallback["version"].as_s.should eq("2.0")
    direct_raw["software"].as_h["name"].as_s.should eq("remote-server")
  end

  it "serializes typed NodeInfo values as NodeInfo 2.1 JSON" do
    nodeinfo_2_0 = Aptork.nodeinfo("remote-server", "2.0.0")
    nodeinfo_2_0["version"] = Aptork.json("2.0")

    parsed = Aptork.parse_nodeinfo(nodeinfo_2_0).not_nil!
    serialized = Aptork.nodeinfo_to_json(parsed)

    parsed.version.should eq("2.0")
    serialized["$schema"].as_s.should eq("http://nodeinfo.diaspora.software/ns/schema/2.1#")
    serialized["version"].as_s.should eq("2.1")
  end

  it "parses NodeInfo documents into typed values and converts them back to JSON" do
    document = Aptork.nodeinfo(
      "remote-server",
      "2.1.3",
      open_registrations: true,
      users_total: 42,
      software_repository: "https://github.com/example/remote-server",
      software_homepage: "https://remote.example",
      inbound_services: ["atom1.0"],
      outbound_services: ["rss2.0", "wordpress"],
      users_active_halfyear: 21,
      users_active_month: 7,
      local_posts: 100,
      local_comments: 5,
      metadata: Aptork::JsonMap{"nodeName" => Aptork.json("Remote")}
    )

    parsed = Aptork.parse_nodeinfo(document).not_nil!
    serialized = Aptork.nodeinfo_to_json(parsed)
    numeric_version = Aptork.nodeinfo("remote-server", "1.0.0")
    numeric_version["software"].as_h["version"] = Aptork.json(123)
    parsed_numeric_version = Aptork.parse_nodeinfo(numeric_version).not_nil!

    parsed.version.should eq("2.1")
    parsed.software.name.should eq("remote-server")
    parsed.software.version.should eq("2.1.3")
    parsed.software.repository.should eq("https://github.com/example/remote-server")
    parsed.software.homepage.should eq("https://remote.example")
    parsed.protocols.should eq(["activitypub"])
    parsed.services.inbound.should eq(["atom1.0"])
    parsed.services.outbound.should eq(["rss2.0", "wordpress"])
    parsed.open_registrations.should be_true
    parsed.usage.users.total.should eq(42)
    parsed.usage.users.active_halfyear.should eq(21)
    parsed.usage.users.active_month.should eq(7)
    parsed.usage.local_posts.should eq(100)
    parsed.usage.local_comments.should eq(5)
    parsed.metadata["nodeName"].as_s.should eq("Remote")
    serialized["$schema"].as_s.should eq("http://nodeinfo.diaspora.software/ns/schema/2.1#")
    serialized["version"].as_s.should eq("2.1")
    serialized["software"].as_h["name"].as_s.should eq("remote-server")
    serialized["software"].as_h["repository"].as_s.should eq("https://github.com/example/remote-server")
    serialized["software"].as_h["homepage"].as_s.should eq("https://remote.example")
    serialized["usage"].as_h["users"].as_h["activeMonth"].as_i.should eq(7)
    serialized["usage"].as_h["localComments"].as_i.should eq(5)
    parsed_numeric_version.software.version.should eq("123")
  end

  it "looks up typed NodeInfo documents and supports best-effort parsing" do
    invalid = Aptork::JsonMap{
      "software"  => Aptork.json({"name" => "remote-server"}),
      "protocols" => Aptork.json(["activitypub"]),
    }
    documents = {
      "https://remote.example/.well-known/nodeinfo" => Aptork.nodeinfo_well_known("https://remote.example/nodeinfo/2.1"),
      "https://remote.example/nodeinfo/2.1"         => invalid,
    }
    federation = Aptork::Federation.create("https://local.example")
      .set_document_loader(->(url : String) do
        documents[url]?.as(Aptork::JsonMap?)
      end)
    ctx = federation.create_context

    ctx.lookup_nodeinfo_document("https://remote.example").should be_nil
    parsed = ctx.lookup_nodeinfo_document("https://remote.example", parse: "best-effort").not_nil!

    parsed.version.should eq("2.1")
    parsed.software.name.should eq("remote-server")
    parsed.software.version.should eq("0.0.0")
    parsed.protocols.should eq(["activitypub"])
  end

  it "strictly validates NodeInfo documents and typed serialization" do
    invalid_name = Aptork.nodeinfo("Remote Server", "1.0.0")
    unknown_protocol = Aptork.nodeinfo("remote-server", "1.0.0", protocols: ["activitypub", "unknown"])
    negative_usage = Aptork.nodeinfo("remote-server", "1.0.0")
    negative_usage["usage"].as_h["users"].as_h["total"] = Aptork.json(-1)
    invalid_usage = Aptork.nodeinfo("remote-server", "1.0.0")
    invalid_usage["usage"] = Aptork.json("many")
    negative_local_posts = Aptork.nodeinfo("remote-server", "1.0.0")
    negative_local_posts["usage"].as_h["localPosts"] = Aptork.json(-1)
    invalid_services = Aptork.nodeinfo("remote-server", "1.0.0")
    invalid_services["services"] = Aptork.json("rss2.0")
    invalid_inbound_services = Aptork.nodeinfo("remote-server", "1.0.0")
    invalid_inbound_services["services"] = Aptork.json({"inbound" => ["atom1.0", "unknown"]})
    malformed_inbound_services = Aptork.nodeinfo("remote-server", "1.0.0")
    malformed_inbound_services["services"] = Aptork.json({"inbound" => "atom1.0"})
    inbound_only_services = Aptork.nodeinfo("remote-server", "1.0.0")
    inbound_only_services["services"] = Aptork.json({"inbound" => ["atom1.0"]})
    outbound_only_services = Aptork.nodeinfo("remote-server", "1.0.0")
    outbound_only_services["services"] = Aptork.json({"outbound" => ["rss2.0"]})
    empty_services = Aptork.nodeinfo("remote-server", "1.0.0")
    empty_services["services"] = Aptork.json({} of String => String)
    invalid_open_registrations = Aptork.nodeinfo("remote-server", "1.0.0")
    invalid_open_registrations["openRegistrations"] = Aptork.json("yes")
    invalid_metadata = Aptork.nodeinfo("remote-server", "1.0.0")
    invalid_metadata["metadata"] = Aptork.json("node")
    missing_version = Aptork.nodeinfo("remote-server", "1.0.0")
    missing_version.delete("version")
    unknown_version = Aptork.nodeinfo("remote-server", "1.0.0")
    unknown_version["version"] = Aptork.json("9.9")
    numeric_version = Aptork.nodeinfo("remote-server", "1.0.0")
    numeric_version["version"] = Aptork.json(21)
    malformed_version = Aptork.nodeinfo("remote-server", "1.0.0")
    malformed_version["version"] = Aptork.json({"major" => 2})
    missing_usage = Aptork.nodeinfo("remote-server", "1.0.0")
    missing_usage.delete("usage")
    missing_users = Aptork.nodeinfo("remote-server", "1.0.0")
    missing_users["usage"] = Aptork.json({} of String => String)
    missing_counters = Aptork.nodeinfo("remote-server", "1.0.0")
    missing_counters["usage"].as_h.delete("localPosts")
    missing_counters["usage"].as_h.delete("localComments")

    Aptork.parse_nodeinfo(invalid_name).should be_nil
    Aptork.parse_nodeinfo(unknown_protocol).should be_nil
    Aptork.parse_nodeinfo(invalid_usage).should be_nil
    Aptork.parse_nodeinfo(invalid_services).should be_nil
    Aptork.parse_nodeinfo(invalid_inbound_services).should be_nil
    Aptork.parse_nodeinfo(malformed_inbound_services).should be_nil
    Aptork.parse_nodeinfo(invalid_open_registrations).should be_nil
    Aptork.parse_nodeinfo(invalid_metadata).should be_nil
    Aptork.parse_nodeinfo(missing_users).should be_nil
    parsed_inbound_only_services = Aptork.parse_nodeinfo(inbound_only_services).not_nil!
    parsed_inbound_only_services.services.inbound.should eq(["atom1.0"])
    parsed_inbound_only_services.services.outbound.should eq([] of String)
    parsed_outbound_only_services = Aptork.parse_nodeinfo(outbound_only_services).not_nil!
    parsed_outbound_only_services.services.inbound.should eq([] of String)
    parsed_outbound_only_services.services.outbound.should eq(["rss2.0"])
    parsed_empty_services = Aptork.parse_nodeinfo(empty_services).not_nil!
    parsed_empty_services.services.inbound.should eq([] of String)
    parsed_empty_services.services.outbound.should eq([] of String)
    parsed_missing_version = Aptork.parse_nodeinfo(missing_version).not_nil!
    parsed_missing_version.version.should eq("2.1")
    parsed_unknown_version = Aptork.parse_nodeinfo(unknown_version).not_nil!
    parsed_unknown_version.version.should eq("9.9")
    parsed_numeric_version = Aptork.parse_nodeinfo(numeric_version).not_nil!
    parsed_numeric_version.version.should eq("21")
    parsed_malformed_version = Aptork.parse_nodeinfo(malformed_version).not_nil!
    parsed_malformed_version.version.should eq("2.1")
    parsed_missing_usage = Aptork.parse_nodeinfo(missing_usage).not_nil!
    parsed_missing_usage.usage.local_posts.should eq(0)
    parsed_missing_usage.usage.local_comments.should eq(0)
    parsed_missing_counters = Aptork.parse_nodeinfo(missing_counters).not_nil!
    parsed_missing_counters.usage.local_posts.should eq(0)
    parsed_missing_counters.usage.local_comments.should eq(0)
    parsed_missing_counters.usage.users.total.should eq(0)
    parsed_negative_usage = Aptork.parse_nodeinfo(negative_usage).not_nil!
    parsed_negative_usage.usage.users.total.should eq(-1)
    parsed_negative_local_posts = Aptork.parse_nodeinfo(negative_local_posts).not_nil!
    parsed_negative_local_posts.usage.local_posts.should eq(-1)

    expect_raises(ArgumentError, "invalid NodeInfo document") do
      Aptork.nodeinfo_to_json(Aptork::NodeInfo.new(
        version: "2.1",
        software: Aptork::NodeInfoSoftware.new(name: "Bad Name", version: "1.0.0"),
        protocols: ["activitypub"]
      ))
    end

    expect_raises(ArgumentError, "invalid NodeInfo document") do
      Aptork.nodeinfo_to_json(Aptork::NodeInfo.new(
        version: "2.1",
        software: Aptork::NodeInfoSoftware.new(name: "remote-server", version: "1.0.0"),
        protocols: ["activitypub"]
      ))
    end

    expect_raises(ArgumentError, "invalid NodeInfo document") do
      Aptork.nodeinfo_to_json(parsed_negative_usage)
    end
  end

  it "best-effort parses common invalid NodeInfo fields" do
    invalid = Aptork::JsonMap{
      "version"   => Aptork.json("2.1"),
      "software"  => Aptork.json({"name" => " REMOTE-SERVER ", "version" => "1.0.0", "repository" => "", "homepage" => 456}),
      "protocols" => Aptork.json(["activitypub", "unknown"]),
      "services"  => Aptork.json({
        "inbound"  => ["atom1.0", "unknown"],
        "outbound" => ["rss2.0"],
      }),
      "usage" => Aptork.json({
        "users" => {
          "total"          => "42 users",
          "activeMonth"    => "7",
          "activeHalfyear" => "many",
        },
        "localPosts"    => "100 posts",
        "localComments" => "none",
      }),
    }

    parsed = Aptork.parse_nodeinfo(invalid, parse: "best-effort").not_nil!

    parsed.software.name.should eq("remote-server")
    parsed.software.repository.should be_nil
    parsed.software.homepage.should be_nil
    parsed.protocols.should eq(["activitypub"])
    parsed.services.inbound.should eq(["atom1.0"])
    parsed.usage.users.total.should eq(42)
    parsed.usage.users.active_month.should eq(7)
    parsed.usage.users.active_halfyear.should be_nil
    parsed.usage.local_posts.should eq(100)
    parsed.usage.local_comments.should eq(0)
    Aptork.parse_nodeinfo(
      invalid.merge({"software" => Aptork.json({"name" => "Remote Server!", "version" => "1.0.0"})}),
      parse: "best-effort"
    ).should be_nil
  end

  it "formats and parses semantic versions for NodeInfo software versions" do
    version = Aptork.parse_semver("1.2.3-beta.1+build.5").not_nil!

    version.major.should eq(1)
    version.minor.should eq(2)
    version.patch.should eq(3)
    version.prerelease.should eq("beta.1")
    version.build.should eq("build.5")
    Aptork.format_semver(version).should eq("1.2.3-beta.1+build.5")
    Aptork.parse_semver("1.2").should be_nil
  end

  it "sends activities and tracks sent metadata" do
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.send_activity("alice", [recipient], activity)

    sent.size.should eq(1)
    federation.sent_activities.size.should eq(1)
    delivered_payload.includes?("\"type\":\"Create\"").should be_true
  end

  it "sends activities from mapped sender usernames" do
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    ctx = federation.create_context
    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("user-123"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.send_activity({username: "alice"}, [recipient], activity)

    sent.size.should eq(1)
    sent.first.sender_identifier.should eq("user-123")
    federation.sent_activities.first.sender_identifier.should eq("user-123")
    delivered_payload.includes?("https://local.example/actors/user-123").should be_true
  end

  it "expands followers and queues activities from mapped sender usernames" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, identifier : String) do
      identifier.should eq("user-123")
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("user-123"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity({username: "alice"}, "followers", activity)

    result.queued.size.should eq(1)
    result.queued.first.sender_identifier.should eq("user-123")
    queue.depth("outbox").should eq(1)
  end

  it "sends raw ActivityPub actor recipients from identity sender tuples" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    ctx = federation.create_context
    raw_actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )
    activity = Aptork.create(
      "https://local.example/activities/raw-identity",
      ctx.get_actor_uri("user-123"),
      Aptork.note("https://local.example/notes/raw-identity", "Hello")
    )

    username_result = ctx.send_activity(
      {username: "alice"},
      raw_actor,
      activity,
      Aptork::SendActivityOptions.new(prefer_shared_inbox: true)
    )
    identifier_result = ctx.send_activity({identifier: "user-123"}, [raw_actor], activity)

    username_result.sent.size.should eq(1)
    username_result.sent.first.sender_identifier.should eq("user-123")
    identifier_result.sent.size.should eq(1)
    delivered_inboxes.should eq([
      "https://remote.example/inbox",
      "https://remote.example/users/bob/inbox",
    ])
  end

  it "raises for unmapped sender usernames when sending activities" do
    federation = Aptork::Federation.create("https://local.example")
    federation.map_handle(->(_ctx : Aptork::Context, _username : String) { nil.as(String?) })
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("missing"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /No actor found for username "missing"/) do
      ctx.send_activity({username: "missing"}, [recipient], activity)
    end
  end

  it "forwards inbox activities with local HTTP signing but without payload mutation" do
    delivered_payload = ""
    delivered_headers = HTTP::Headers.new
    transport = Aptork::Transport.new(
      signature_enabled: true,
      headers_provider: ->(_method : String, _url : String, _body : String) do
        {"Signature" => "local-signature"}
      end,
      post_provider: ->(_url : String, headers : HTTP::Headers, body : String) do
        delivered_headers = headers
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    forwarded = [] of Aptork::SentActivity
    configure_local_actor_dispatcher(federation)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
      ]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        forwarded = ctx.forward_activity("alice", "followers", activity)
        nil
      end)
    original_body = %({"id":"https://origin.example/activities/1","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/1","type":"Note","content":"Raw"}})

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: original_body
    ))

    response.status.should eq(202)
    forwarded.size.should eq(1)
    delivered_payload.should eq(original_body)
    forwarded.first.raw_activity.should eq(original_body)
    delivered_headers["Content-Type"].should eq("application/activity+json")
    delivered_headers["Signature"].should eq("local-signature")
    federation.sent_activities.first.sender_identifier.should eq("alice")
  end

  it "queues forwarded inbox activities through a configured outbox queue" do
    delivered_payload = ""
    delivered = 0
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered += 1
        delivered_payload = body
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      transport,
      outbox_queue: queue,
      manually_start_queue: true
    )
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: %({"id":"https://origin.example/activities/1","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/1","type":"Note","content":"Raw"}})
    ))
    activity = JSON.parse(ctx.inbound_request.not_nil!.body).as_h
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.forward_activity("alice", [recipient], activity)

    sent.empty?.should be_true
    delivered.should eq(0)
    queue.depth("outbox").should eq(1)
    message = queue.messages.first
    message.payload["type"].as_s.should eq("ForwardedDelivery")
    message.payload["payload"].as_s.should eq(ctx.inbound_request.not_nil!.body)
    message.payload["sourceHeaders"].as_h["Signature"].as_s.should eq("original-http-signature")

    ctx.process_queued_activities.should eq([Aptork::QueueProcessResult::Processed])
    delivered.should eq(1)
    delivered_payload.should eq(ctx.inbound_request.not_nil!.body)
    federation.sent_activities.size.should eq(1)
    federation.sent_activities.first.sender_identifier.should eq("alice")
    federation.sent_activities.first.raw_activity.should eq(ctx.inbound_request.not_nil!.body)
  end

  it "forwards with explicit sender key pairs and preserves the original payload" do
    delivered_headers = HTTP::Headers.new
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, body : String) do
        delivered_headers = headers
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    original_body = %({"id":"https://origin.example/activities/key-forward","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/key-forward","type":"Note","content":"Raw"}})
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: original_body
    ))
    activity = JSON.parse(original_body).as_h
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.forward_activity(key_pair, [recipient], activity)

    sent.size.should eq(1)
    sent.first.sender_identifier.should eq("alice")
    delivered_payload.should eq(original_body)
    delivered_headers["Signature"].should contain(%(keyId="#{key_pair.id}"))
  end

  it "forwards to raw and typed actor recipients" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: %({"id":"https://origin.example/activities/actor-forward","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/actor-forward","type":"Note","content":"Raw"}})
    ))
    activity = JSON.parse(ctx.inbound_request.not_nil!.body).as_h
    raw_actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )
    typed_actor = Aptork::Vocab::Actor.from_json_ld(Aptork.actor(
      "Person",
      "https://other.example/users/carol",
      "carol",
      "https://other.example/users/carol/inbox",
      "https://other.example/users/carol/outbox"
    ))

    raw_sent = ctx.forward_activity(
      "alice",
      raw_actor,
      activity,
      Aptork::ForwardActivityOptions.new(prefer_shared_inbox: true)
    )
    typed_sent = ctx.forward_activity("alice", typed_actor, activity)

    raw_sent.size.should eq(1)
    typed_sent.size.should eq(1)
    delivered_inboxes.should eq([
      "https://remote.example/inbox",
      "https://other.example/users/carol/inbox",
    ])
  end

  it "forwards from identity sender tuples" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/user-123/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: %({"id":"https://origin.example/activities/identity-forward","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/identity-forward","type":"Note","content":"Raw"}})
    ))
    activity = JSON.parse(ctx.inbound_request.not_nil!.body).as_h
    raw_actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )
    recipient = Aptork::Recipient.new("https://other.example/users/carol", "https://other.example/users/carol/inbox")

    username_sent = ctx.forward_activity(
      {username: "alice"},
      raw_actor,
      activity,
      Aptork::ForwardActivityOptions.new(prefer_shared_inbox: true)
    )
    identifier_sent = ctx.forward_activity({identifier: "user-123"}, recipient, activity)

    username_sent.size.should eq(1)
    username_sent.first.sender_identifier.should eq("user-123")
    identifier_sent.size.should eq(1)
    identifier_sent.first.sender_identifier.should eq("user-123")
    delivered_inboxes.should eq([
      "https://remote.example/inbox",
      "https://other.example/users/carol/inbox",
    ])
  end

  it "forwards with explicit key pairs to raw actor recipients" do
    delivered_headers = HTTP::Headers.new
    delivered_inbox = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, headers : HTTP::Headers, _body : String) do
        delivered_inbox = url
        delivered_headers = headers
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: %({"id":"https://origin.example/activities/key-actor-forward","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/key-actor-forward","type":"Note","content":"Raw"}})
    ))
    activity = JSON.parse(ctx.inbound_request.not_nil!.body).as_h
    raw_actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )

    sent = ctx.forward_activity(
      key_pair,
      raw_actor,
      activity,
      Aptork::ForwardActivityOptions.new(prefer_shared_inbox: true)
    )

    sent.size.should eq(1)
    delivered_inbox.should eq("https://remote.example/inbox")
    delivered_headers["Signature"].should contain(%(keyId="#{key_pair.id}"))
  end

  it "queues forwarded activities with explicit sender key pairs" do
    delivered_headers = HTTP::Headers.new
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        delivered_headers = headers
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      transport,
      outbox_queue: queue,
      manually_start_queue: true
    )
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    ctx = federation.create_context.with_inbound_request(Aptork::Request.new(
      "POST",
      "/users/alice/inbox",
      headers: {"Content-Type" => "application/activity+json", "Signature" => "original-http-signature"},
      body: %({"id":"https://origin.example/activities/queued-key-forward","type":"Create","actor":"https://origin.example/users/ann","object":{"id":"https://origin.example/notes/queued-key-forward","type":"Note","content":"Raw"}})
    ))
    activity = JSON.parse(ctx.inbound_request.not_nil!.body).as_h
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.forward_activity(
      [key_pair],
      [recipient],
      activity,
      Aptork::ForwardActivityOptions.new(ordering_key: "alice")
    )

    sent.should be_empty
    queue.messages.first.ordering_key.should eq("alice")
    stored_key = queue.messages.first.payload["senderKeyPairs"].as_a.first.as_h
    stored_key["id"].as_s.should eq(key_pair.id)
    stored_key["privateKeyPem"].as_s.should eq(key_pair.private_key_pem)

    ctx.process_queued_activities.should eq([Aptork::QueueProcessResult::Processed])

    delivered_headers["Signature"].should contain(%(keyId="#{key_pair.id}"))
    federation.sent_activities.first.sender_identifier.should eq("alice")
  end

  it "forwards immediately when requested even if an outbox queue is configured" do
    delivered = 0
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered += 1
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: queue)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://origin.example/activities/1",
      "https://origin.example/users/ann",
      Aptork.note("https://origin.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    sent = ctx.forward_activity(
      "alice",
      [recipient],
      activity,
      Aptork::ForwardActivityOptions.new(immediate: true)
    )

    sent.size.should eq(1)
    delivered.should eq(1)
    queue.depth("outbox").should eq(0)
  end

  it "skips forwarding proofless activities when requested" do
    delivered = 0
    transport = Aptork::Transport.new(
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered += 1
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    unsigned = Aptork.create(
      "https://origin.example/activities/1",
      "https://origin.example/users/ann",
      Aptork.note("https://origin.example/notes/1", "Unsigned")
    )
    signed = Aptork.create(
      "https://origin.example/activities/2",
      "https://origin.example/users/ann",
      Aptork.note("https://origin.example/notes/2", "Signed")
    )
    signed["proof"] = Aptork.json({"type" => "DataIntegrityProof"})

    skipped = ctx.forward_activity(
      "alice",
      "followers",
      unsigned,
      Aptork::ForwardActivityOptions.new(skip_if_unsigned: true)
    )
    forwarded = ctx.forward_activity(
      "alice",
      "followers",
      signed,
      Aptork::ForwardActivityOptions.new(skip_if_unsigned: true)
    )

    skipped.empty?.should be_true
    forwarded.size.should eq(1)
    delivered.should eq(1)
  end

  it "automatically forwards addressed activities through local recipients' followers" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, identifier : String) do
      case identifier
      when "alice"
        [
          Aptork.actor(
            "Person",
            "https://remote.example/users/bob",
            "bob",
            "https://remote.example/users/bob/inbox",
            "https://remote.example/users/bob/outbox",
            shared_inbox: "https://remote.example/inbox"
          ),
          Aptork.actor(
            "Person",
            "https://remote.example/users/carol",
            "carol",
            "https://remote.example/users/carol/inbox",
            "https://remote.example/users/carol/outbox",
            shared_inbox: "https://remote.example/inbox"
          ),
        ]
      when "mallory"
        [
          Aptork.actor(
            "Person",
            "https://another.example/users/dan",
            "dan",
            "https://another.example/users/dan/inbox",
            "https://another.example/users/dan/outbox"
          ),
        ]
      else
        [] of Aptork::JsonMap
      end
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://origin.example/activities/auto",
      "https://origin.example/users/ann",
      Aptork.note("https://origin.example/notes/auto", "Mention")
    )
    activity["to"] = Aptork.json([
      ctx.get_actor_uri("alice"),
      Aptork::PUBLIC_COLLECTION,
      "https://remote.example/users/not-local",
    ])
    activity["cc"] = Aptork.json(ctx.get_actor_uri("alice"))
    activity["audience"] = Aptork.json({"id" => ctx.get_actor_uri("unknown")})
    activity["object"].as_h["cc"] = Aptork.json(ctx.get_actor_uri("mallory"))
    activity["proof"] = Aptork.json({"type" => "DataIntegrityProof"})

    sent = ctx.forward_activity(
      activity,
      Aptork::ForwardActivityOptions.new(exclude_base_uris: ["https://another.example"])
    )

    sent.size.should eq(1)
    sent.first.sender_identifier.should eq("alice")
    delivered_inboxes.should eq(["https://remote.example/inbox"])
  end

  it "does not auto-forward to the forwarder or activity actor followers" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(ctx : Aptork::Context, identifier : String) do
      [
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ),
        Aptork.actor(
          "Person",
          "https://origin.example/users/ann",
          "ann",
          "https://origin.example/users/ann/inbox",
          "https://origin.example/users/ann/outbox"
        ),
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://origin.example/activities/exclude",
      "https://origin.example/users/ann",
      Aptork.note("https://origin.example/notes/exclude", "Mention")
    )
    activity["to"] = Aptork.json(ctx.get_actor_uri("alice"))
    activity["proof"] = Aptork.json({"type" => "DataIntegrityProof"})

    sent = ctx.forward_activity(activity)

    sent.size.should eq(1)
    sent.first.recipient.id.should eq("https://remote.example/users/bob")
    delivered_inboxes.should eq(["https://remote.example/users/bob/inbox"])
  end

  it "enqueues outbound activities through a configured outbox queue" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      outbox_queue: queue,
      outbox_retry_policy: Aptork::RetryPolicy.new(max_attempts: 2)
    )
    ctx = federation.create_context

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    queued = ctx.enqueue_activity(
      "alice",
      [recipient],
      activity,
      Aptork::EnqueueOptions.new(ordering_key: "alice")
    )

    queued.size.should eq(1)
    queue.depth("outbox").should eq(1)
    message = queue.messages.first
    message.ordering_key.should eq("alice")
    message.payload["type"].as_s.should eq("OutboundDelivery")
    message.payload["delivery"].as_h["inbox"].as_s.should eq("https://remote.example/inbox")
    message.payload["activity"].as_h["id"].as_s.should eq("https://local.example/activities/1")
  end

  it "rejects actorless queued outbound activities" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context
    activity = Aptork.object(
      "Create",
      "https://local.example/activities/queued-missing-actor",
      Aptork::JsonMap{
        "object" => Aptork.json(Aptork.note("https://local.example/notes/queued-missing-actor", "Hello")),
      }
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /at least one actor/) do
      ctx.enqueue_activity("alice", [recipient], activity)
    end
    queue.depth("outbox").should eq(0)
  end

  it "rejects idless queued outbound activities unless an id transformer is installed" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context
    activity = Aptork.object("Create", nil, Aptork::JsonMap{
      "actor"  => Aptork.json(ctx.get_actor_uri("alice")),
      "object" => Aptork.json(Aptork.note("https://local.example/notes/queued-missing-id", "Hello")),
    })
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /must have an id/) do
      ctx.enqueue_activity("alice", [recipient], activity)
    end
    queue.depth("outbox").should eq(0)
  end

  it "batch-enqueues outbound deliveries when no ordering key is required" do
    queue = BatchRecordingQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context

    activity = Aptork.create(
      "https://local.example/activities/batch",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/batch", "Batch")
    )
    recipients = [
      Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox"),
      Aptork::Recipient.new("https://other.example/users/cara", "https://other.example/inbox"),
    ]

    queued = ctx.enqueue_activity("alice", recipients, activity)

    queued.size.should eq(2)
    queue.enqueue_many_calls.should eq(1)
    queue.enqueue_calls.should eq(0)
    queue.depth("outbox").should eq(2)
  end

  it "keeps individual enqueues when an ordering key is specified" do
    queue = BatchRecordingQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context

    activity = Aptork.create(
      "https://local.example/activities/ordered",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/ordered", "Ordered")
    )
    recipients = [
      Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox"),
      Aptork::Recipient.new("https://other.example/users/cara", "https://other.example/inbox"),
    ]

    queued = ctx.enqueue_activity("alice", recipients, activity, Aptork::EnqueueOptions.new(ordering_key: "note:ordered"))

    queued.size.should eq(2)
    queue.enqueue_many_calls.should eq(0)
    queue.enqueue_calls.should eq(2)
    queue.messages.map(&.ordering_key).should eq(["note:ordered", "note:ordered"])
  end

  it "processes queued outbound activities and records sent metadata" do
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport)
      .configure_outbox_queue(queue)
    ctx = federation.create_context

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    ctx.enqueue_activity("alice", [recipient], activity)

    results = ctx.process_queued_activities

    results.should eq([Aptork::QueueProcessResult::Processed])
    queue.depth("outbox").should eq(0)
    federation.sent_activities.size.should eq(1)
    federation.sent_activities.first.sender_identifier.should eq("alice")
    federation.sent_activities.first.queued.should be_true
    federation.sent_activities.first.queue.should eq("outbox")
    federation.sent_activities.first.sent_order.should eq(1)
    delivered_payload.includes?("\"type\":\"Create\"").should be_true
  end

  it "processes outbound queued tasks directly for external workers" do
    delivered_inbox = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inbox = url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    delivery = Aptork::DeliveryConfig.new(
      inbox: "https://remote.example/inbox",
      actor: ctx.get_actor_uri("alice"),
      target: "https://remote.example/users/bob",
      actor_ids: ["https://remote.example/users/bob"]
    )

    processed = federation.process_queued_task(federation.outbound_delivery_payload(delivery, activity))

    processed.should be_true
    delivered_inbox.should eq("https://remote.example/inbox")
    federation.sent_activities.size.should eq(1)
    federation.sent_activities.first.recipient.actor_ids.should eq(["https://remote.example/users/bob"])
  end

  it "retries failed queued outbound delivery with the configured retry policy" do
    attempts = 0
    failures = [] of Aptork::OutboxDeliveryFailure
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        attempts += 1
        {503, "try later"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    policy = Aptork::RetryPolicy.new(max_attempts: 2, initial_delay: Time::Span.new(seconds: 5))
    federation = Aptork::Federation.create("https://local.example", transport)
      .configure_outbox_queue(queue, retry_policy: policy)
      .set_outbox_error_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxDeliveryFailure) do
        failures << failure
        nil
      end)
    ctx = federation.create_context

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    ctx.enqueue_activity("alice", [recipient], activity)
    now = Time.utc + Time::Span.new(seconds: 1)

    first = ctx.process_queued_activities(now)
    second = ctx.process_queued_activities(now + Time::Span.new(seconds: 5))

    first.should eq([Aptork::QueueProcessResult::Retried])
    second.should eq([Aptork::QueueProcessResult::Dead])
    attempts.should eq(2)
    failures.size.should eq(2)
    failures.map(&.attempts).should eq([1, 2])
    failures.map(&.status_code).should eq([503, 503])
    failures.first.inbox.should eq("https://remote.example/inbox")
    failures.first.actor_ids.should eq(["https://remote.example/users/bob"])
    failures.first.activity["id"].as_s.should eq("https://local.example/activities/1")
    queue.dead_messages.size.should eq(1)
    federation.sent_activities.empty?.should be_true
  end

  it "skips retries and reports permanent queued outbound delivery failures" do
    attempts = 0
    transient_failures = [] of Aptork::OutboxDeliveryFailure
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        attempts += 1
        {410, "gone"}
      end
    )
    failures = [] of Aptork::OutboxPermanentFailure
    queue = Aptork::InProcessMessageQueue.new
    policy = Aptork::RetryPolicy.new(max_attempts: 5, initial_delay: Time::Span.new(seconds: 5))
    federation = Aptork::Federation.create("https://local.example", transport)
      .configure_outbox_queue(queue, retry_policy: policy)
      .set_outbox_permanent_failure_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxPermanentFailure) do
        failures << failure
        nil
      end)
      .set_outbox_error_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxDeliveryFailure) do
        transient_failures << failure
        nil
      end)
    ctx = federation.create_context

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    ctx.enqueue_activity("alice", [recipient], activity)

    results = ctx.process_queued_activities(Time.utc + Time::Span.new(seconds: 1))

    results.should eq([Aptork::QueueProcessResult::Dead])
    attempts.should eq(1)
    queue.depth("outbox").should eq(0)
    queue.dead_messages.size.should eq(1)
    failures.size.should eq(1)
    failures.first.inbox.should eq("https://remote.example/inbox")
    failures.first.status_code.should eq(410)
    failures.first.actor_ids.should eq(["https://remote.example/users/bob"])
    failures.first.activity["id"].as_s.should eq("https://local.example/activities/1")
    transient_failures.empty?.should be_true
    federation.sent_activities.empty?.should be_true
  end

  it "treats configured status codes as permanent queued outbound failures" do
    attempts = 0
    permanent_failures = [] of Aptork::OutboxPermanentFailure
    transient_failures = [] of Aptork::OutboxDeliveryFailure
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        attempts += 1
        {451, "unavailable for legal reasons"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      transport,
      permanent_failure_status_codes: [404, 410, 451]
    )
      .configure_outbox_queue(queue, retry_policy: Aptork::RetryPolicy.new(max_attempts: 5, initial_delay: Time::Span.new(seconds: 5)))
      .set_outbox_permanent_failure_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxPermanentFailure) do
        permanent_failures << failure
        nil
      end)
      .set_outbox_error_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxDeliveryFailure) do
        transient_failures << failure
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.enqueue_activity("alice", [recipient], activity)
    results = ctx.process_queued_activities(Time.utc + Time::Span.new(seconds: 1))

    results.should eq([Aptork::QueueProcessResult::Dead])
    attempts.should eq(1)
    permanent_failures.size.should eq(1)
    permanent_failures.first.status_code.should eq(451)
    transient_failures.empty?.should be_true
    queue.dead_messages.size.should eq(1)
  end

  it "retries unconfigured status codes even when they can be configured as permanent" do
    attempts = 0
    permanent_failures = [] of Aptork::OutboxPermanentFailure
    transient_failures = [] of Aptork::OutboxDeliveryFailure
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        attempts += 1
        {451, "unavailable for legal reasons"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport)
      .set_permanent_failure_status_codes([404, 410])
      .configure_outbox_queue(queue, retry_policy: Aptork::RetryPolicy.new(max_attempts: 2, initial_delay: Time::Span.new(seconds: 5)))
      .set_outbox_permanent_failure_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxPermanentFailure) do
        permanent_failures << failure
        nil
      end)
      .set_outbox_error_handler(->(_ctx : Aptork::Context, failure : Aptork::OutboxDeliveryFailure) do
        transient_failures << failure
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    now = Time.utc + Time::Span.new(seconds: 1)

    ctx.enqueue_activity("alice", [recipient], activity)
    first = ctx.process_queued_activities(now)
    second = ctx.process_queued_activities(now + Time::Span.new(seconds: 5))

    first.should eq([Aptork::QueueProcessResult::Retried])
    second.should eq([Aptork::QueueProcessResult::Dead])
    attempts.should eq(2)
    permanent_failures.empty?.should be_true
    transient_failures.map(&.status_code).should eq([451, 451])
  end

  it "processes queued outbound delivery from Redis-backed queues" do
    delivered_inbox = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inbox = url
        {202, "ok"}
      end
    )
    queue = Aptork::RedisMessageQueue.new(FakeRedisCommandClient.new, "app")
    federation = Aptork::Federation.create("https://local.example", transport)
      .configure_outbox_queue(queue)
    ctx = federation.create_context
    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.enqueue_activity("alice", [recipient], activity)
    results = ctx.process_queued_activities(Time.utc + Time::Span.new(seconds: 1))

    results.should eq([Aptork::QueueProcessResult::Processed])
    delivered_inbox.should eq("https://remote.example/inbox")
    federation.sent_activities.size.should eq(1)
    queue.depth("outbox").should eq(0)
  end

  it "processes queued inbox and fanout tasks from Redis-backed queues" do
    inbox_handled = false
    inbox_queue = Aptork::RedisMessageQueue.new(FakeRedisCommandClient.new, "app")
    fanout_queue = Aptork::RedisMessageQueue.new(FakeRedisCommandClient.new, "app")
    outbox_queue = Aptork::RedisMessageQueue.new(FakeRedisCommandClient.new, "app")
    federation = Aptork::Federation.create("https://local.example", inbox_queue: inbox_queue, outbox_queue: outbox_queue, fanout_queue: fanout_queue)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        inbox_handled = true
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hello")
    )

    federation.enqueue_inbox_activity("alice", activity, trusted: true)
    ctx.enqueue_fanout_activity(
      "alice",
      [Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")],
      activity
    )

    ctx.process_queued_inbox_activities(Time.utc + Time::Span.new(seconds: 1)).should eq([Aptork::QueueProcessResult::Processed])
    ctx.process_queued_fanout_activities(Time.utc + Time::Span.new(seconds: 1)).should eq([Aptork::QueueProcessResult::Processed])
    inbox_handled.should be_true
    outbox_queue.depth("outbox").should eq(1)
  end

  it "does not auto-start queue workers when manual queue start is enabled" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create(
      "https://local.example",
      outbox_queue: queue,
      manually_start_queue: true
    )
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.enqueue_activity("alice", [recipient], activity)

    federation.queue_started?.should be_false
    queue.depth("outbox").should eq(1)
  end

  it "starts queue workers explicitly and processes outbox, inbox, and fanout queues" do
    delivered_inboxes = [] of String
    inbox_handled = false
    outbox_queue = Aptork::InProcessMessageQueue.new
    inbox_queue = Aptork::InProcessMessageQueue.new
    fanout_queue = Aptork::InProcessMessageQueue.new
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create(
      "https://local.example",
      transport,
      outbox_queue: outbox_queue,
      inbox_queue: inbox_queue,
      fanout_queue: fanout_queue,
      manually_start_queue: true
    )
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        inbox_handled = true
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    ctx.enqueue_activity("alice", [recipient], activity)
    ctx.enqueue_fanout_activity("alice", [recipient], activity)
    federation.enqueue_inbox_activity("alice", activity, trusted: true)

    worker = federation.start_queue(
      options: Aptork::QueueStartOptions.new(poll_interval: Time::Span.new(nanoseconds: 1_000_000))
    )
    100.times do
      break if inbox_handled && delivered_inboxes.size >= 2
      sleep Time::Span.new(nanoseconds: 10_000_000)
    end
    worker.stop
    federation.stop_queue

    inbox_handled.should be_true
    delivered_inboxes.should eq(["https://remote.example/inbox", "https://remote.example/inbox"])
    outbox_queue.depth("outbox").should eq(0)
    inbox_queue.depth("inbox").should eq(0)
    fanout_queue.depth("fanout").should eq(0)
  end

  it "auto-starts queue workers by default and allows an explicit stop" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.enqueue_activity("alice", [recipient], activity)

    federation.queue_started?.should be_true
    federation.stop_queue
    federation.queue_started?.should be_false
  end

  it "adds missing queue roles when start_queue is called again with another subset" do
    delivered_inboxes = [] of String
    inbox_handled = false
    outbox_queue = Aptork::InProcessMessageQueue.new
    inbox_queue = Aptork::InProcessMessageQueue.new
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create(
      "https://local.example",
      transport,
      outbox_queue: outbox_queue,
      inbox_queue: inbox_queue,
      manually_start_queue: true
    )
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        inbox_handled = true
        nil
      end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
    ctx.enqueue_activity("alice", [recipient], activity)
    federation.enqueue_inbox_activity("alice", activity, trusted: true)

    worker = federation.start_queue(
      options: Aptork::QueueStartOptions.new(
        queues: ["outbox"],
        poll_interval: Time::Span.new(nanoseconds: 1_000_000)
      )
    )
    100.times do
      break unless delivered_inboxes.empty?
      sleep Time::Span.new(nanoseconds: 10_000_000)
    end

    worker.queues.should eq(["outbox"])
    delivered_inboxes.should eq(["https://remote.example/inbox"])
    inbox_handled.should be_false
    inbox_queue.depth("inbox").should eq(1)

    same_worker = federation.start_queue(
      options: Aptork::QueueStartOptions.new(
        queues: ["inbox"],
        poll_interval: Time::Span.new(nanoseconds: 1_000_000)
      )
    )
    100.times do
      break if inbox_handled
      sleep Time::Span.new(nanoseconds: 10_000_000)
    end
    same_worker.stop
    federation.stop_queue

    same_worker.object_id.should eq(worker.object_id)
    same_worker.queues.should eq(["outbox", "inbox"])
    inbox_handled.should be_true
    inbox_queue.depth("inbox").should eq(0)
  end

  it "expands followers collection recipients and sends activities" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
        Aptork.actor(
          "Person",
          "https://remote.example/users/carol",
          "carol",
          "https://remote.example/users/carol/inbox",
          "https://remote.example/users/carol/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)

    result.sent.size.should eq(2)
    result.queued.empty?.should be_true
    delivered_inboxes.should eq([
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/carol/inbox",
    ])
  end

  it "gathers followers recipients through cursor pages when one-shot dispatch is absent" do
    delivered_inboxes = [] of String
    cursors = [] of String?
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_followers_dispatcher(
      "/users/{identifier}/followers",
      ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, _size : Int32) do
        cursors << cursor
        case cursor
        when nil
          nil
        when ""
          Aptork::CollectionPageResult.new([
            Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          ], next_cursor: "next").as(Aptork::CollectionPageResult?)
        when "next"
          Aptork::CollectionPageResult.new([
            Aptork.actor("Person", "https://remote.example/users/carol", "carol", "https://remote.example/users/carol/inbox", "https://remote.example/users/carol/outbox"),
          ]).as(Aptork::CollectionPageResult?)
        else
          nil
        end
      end
    )
    federation.set_collection_first_cursor("followers", ->(_ctx : Aptork::Context, _params : Hash(String, String)) { "".as(String?) })
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/paged-followers",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/paged-followers", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)

    result.sent.size.should eq(2)
    cursors.should eq([nil, "", "next"])
    delivered_inboxes.should eq([
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/carol/inbox",
    ])
  end

  it "extracts delivery inboxes with shared inbox preference and origin exclusions" do
    recipients = [
      Aptork::Recipient.new(
        "https://remote.example/users/bob",
        "https://remote.example/users/bob/inbox",
        [] of String,
        "https://remote.example/inbox"
      ),
      Aptork::Recipient.new(
        "https://remote.example/users/carol",
        "https://remote.example/users/carol/inbox",
        ["https://remote.example/users/carol", "https://remote.example/users/carol/device"],
        "https://remote.example/inbox"
      ),
      Aptork::Recipient.new(
        "https://other.example/users/dan",
        "https://other.example/users/dan/inbox"
      ),
    ]

    personal = Aptork.extract_inboxes(recipients)
    personal.keys.sort.should eq([
      "https://other.example/users/dan/inbox",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/carol/inbox",
    ])

    shared = Aptork.extract_inboxes(recipients, prefer_shared_inbox: true)
    shared.keys.sort.should eq([
      "https://other.example/users/dan/inbox",
      "https://remote.example/inbox",
    ])
    shared["https://remote.example/inbox"].shared_inbox.should be_true
    shared["https://remote.example/inbox"].actor_ids.sort.should eq([
      "https://remote.example/users/bob",
      "https://remote.example/users/carol",
      "https://remote.example/users/carol/device",
    ])

    excluded = Aptork.extract_inboxes(
      recipients,
      prefer_shared_inbox: true,
      exclude_base_uris: ["https://remote.example/projects/aptork"]
    )
    excluded.keys.should eq(["https://other.example/users/dan/inbox"])
  end

  it "converts raw ActivityPub actors into recipients" do
    actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )

    personal = Aptork.recipient_from_actor(actor).not_nil!
    personal.id.should eq("https://remote.example/users/bob")
    personal.inbox.should eq("https://remote.example/users/bob/inbox")
    personal.shared_inbox.should eq("https://remote.example/inbox")

    shared = Aptork.recipient_from_actor(actor, prefer_shared_inbox: true).not_nil!
    shared.inbox.should eq("https://remote.example/inbox")

    alias_actor = Aptork::JsonMap{
      "@id"   => Aptork.json("https://remote.example/users/carol"),
      "inbox" => Aptork.json("https://remote.example/users/carol/inbox"),
    }
    Aptork.recipient_from_actor(alias_actor).not_nil!.id.should eq("https://remote.example/users/carol")

    Aptork.recipient_from_actor(Aptork::JsonMap{"id" => Aptork.json("https://remote.example/users/no-inbox")}).should be_nil
  end

  it "sends explicit recipients with Fedify-style delivery options" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/direct-options",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/direct-options", "Hello")
    )
    recipients = [
      Aptork::Recipient.new(
        "https://remote.example/users/bob",
        "https://remote.example/users/bob/inbox",
        [] of String,
        "https://remote.example/inbox"
      ),
      Aptork::Recipient.new(
        "https://remote.example/users/carol",
        "https://remote.example/users/carol/inbox",
        [] of String,
        "https://remote.example/inbox"
      ),
      Aptork::Recipient.new(
        "https://local.example/users/dave",
        "https://local.example/users/dave/inbox"
      ),
    ]

    result = ctx.send_activity(
      "alice",
      recipients,
      activity,
      Aptork::SendActivityOptions.new(
        prefer_shared_inbox: true,
        exclude_base_uris: ["https://local.example"]
      )
    )

    result.sent.size.should eq(1)
    result.sent.first.recipient.inbox.should eq("https://remote.example/inbox")
    result.sent.first.recipient.synchronization_actor_ids.sort.should eq([
      "https://remote.example/users/bob",
      "https://remote.example/users/carol",
    ])
    delivered_inboxes.should eq(["https://remote.example/inbox"])
  end

  it "rejects actorless explicit recipient sends" do
    delivered = false
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered = true
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    activity = Aptork.object(
      "Create",
      "https://local.example/activities/direct-missing-actor",
      Aptork::JsonMap{
        "object" => Aptork.json(Aptork.note("https://local.example/notes/direct-missing-actor", "Hello")),
      }
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /at least one actor/) do
      ctx.send_activity("alice", [recipient], activity)
    end
    delivered.should be_false
  end

  it "rejects idless explicit recipient sends unless an id transformer is installed" do
    delivered = false
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered = true
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    activity = Aptork.object("Create", nil, Aptork::JsonMap{
      "actor"  => Aptork.json(ctx.get_actor_uri("alice")),
      "object" => Aptork.json(Aptork.note("https://local.example/notes/direct-missing-id", "Hello")),
    })
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /must have an id/) do
      ctx.send_activity("alice", [recipient], activity)
    end
    delivered.should be_false
  end

  it "sends typed actor recipients and queues explicit recipient sends" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/direct-actor",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/direct-actor", "Hello")
    )
    actor = Aptork::Vocab::Actor.from_json_ld(Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    ))

    result = ctx.send_activity(
      {identifier: "alice"},
      actor,
      activity,
      Aptork::SendActivityOptions.new(prefer_shared_inbox: true, ordering_key: "alice")
    )

    result.sent.should be_empty
    result.queued.size.should eq(1)
    result.queued.first.recipient.inbox.should eq("https://remote.example/inbox")
    queue.messages.first.ordering_key.should eq("alice")
    queue.messages.first.payload["delivery"].as_h["inbox"].as_s.should eq("https://remote.example/inbox")
  end

  it "sends raw ActivityPub actor recipients" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/raw-actor",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/raw-actor", "Hello")
    )
    actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )

    result = ctx.send_activity(
      "alice",
      actor,
      activity,
      Aptork::SendActivityOptions.new(prefer_shared_inbox: true)
    )

    result.sent.size.should eq(1)
    delivered_inboxes.should eq(["https://remote.example/inbox"])
  end

  it "sends activities with explicit sender key pairs" do
    delivered_headers = [] of HTTP::Headers
    delivered_bodies = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, body : String) do
        delivered_headers << headers
        delivered_bodies << body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    recipient = Aptork::Recipient.new(
      "https://remote.example/users/bob",
      "https://remote.example/users/bob/inbox"
    )
    activity = Aptork.create(
      "https://local.example/activities/key-sender",
      key_pair.owner,
      Aptork.note("https://local.example/notes/key-sender", "Hello")
    )

    result = ctx.send_activity(key_pair, [recipient], activity)

    result.sent.size.should eq(1)
    result.sent.first.sender_identifier.should eq("alice")
    result.sent.first.activity["actor"].as_s.should eq(key_pair.owner)
    delivered_headers.first["Signature"].should contain(%(keyId="#{key_pair.id}"))
    JSON.parse(delivered_bodies.first).as_h["actor"].as_s.should eq(key_pair.owner)
  end

  it "rejects explicit sender key pair activities without actors" do
    transport = Aptork::Transport.new(signature_enabled: false)
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    recipient = Aptork::Recipient.new(
      "https://remote.example/users/bob",
      "https://remote.example/users/bob/inbox"
    )
    activity = Aptork.object(
      "Create",
      "https://local.example/activities/missing-actor",
      Aptork::JsonMap{
        "object" => Aptork.json(Aptork.note("https://local.example/notes/missing-actor", "Hello")),
      }
    )

    expect_raises(ArgumentError, /at least one actor/) do
      ctx.send_activity(key_pair, [recipient], activity)
    end
  end

  it "rejects explicit sender key pairs without private key material" do
    delivered = false
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered = true
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    key_pair = Aptork::ActorKeyPair.new(
      "https://local.example/users/alice#main-key",
      "https://local.example/users/alice",
      "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"
    )
    recipient = Aptork::Recipient.new(
      "https://remote.example/users/bob",
      "https://remote.example/users/bob/inbox"
    )
    activity = Aptork.create(
      "https://local.example/activities/public-only-key",
      key_pair.owner,
      Aptork.note("https://local.example/notes/public-only-key", "Hello")
    )

    expect_raises(ArgumentError, /private key material/) do
      ctx.send_activity(key_pair, [recipient], activity)
    end
    delivered.should be_false
  end

  it "rejects unsupported explicit sender key algorithms" do
    federation = Aptork::Federation.create("https://local.example", Aptork::Transport.new(signature_enabled: false))
    ctx = federation.create_context
    key_pair = Aptork::ActorKeyPair.new(
      "https://local.example/users/alice#ecdsa-key",
      "https://local.example/users/alice",
      "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n",
      private_key_pem: "-----BEGIN PRIVATE KEY-----\nTEST\n-----END PRIVATE KEY-----\n",
      algorithm: "ecdsa-p256-sha256"
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/users/bob/inbox")
    activity = Aptork.create(
      "https://local.example/activities/unsupported-key",
      key_pair.owner,
      Aptork.note("https://local.example/notes/unsupported-key", "Hello")
    )

    expect_raises(ArgumentError, /unsupported sender key algorithm/) do
      ctx.send_activity(key_pair, [recipient], activity)
    end
  end

  it "rejects Ed25519 explicit sender keys without PEM private material" do
    federation = Aptork::Federation.create("https://local.example", Aptork::Transport.new(signature_enabled: false))
    ctx = federation.create_context
    key_pair = Aptork::ActorKeyPair.new(
      "https://local.example/users/alice#ed25519-key",
      "https://local.example/users/alice",
      "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n",
      private_key_path: "/tmp/ed25519.key",
      algorithm: "ed25519"
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/users/bob/inbox")
    activity = Aptork.create(
      "https://local.example/activities/ed25519-path-key",
      key_pair.owner,
      Aptork.note("https://local.example/notes/ed25519-path-key", "Hello")
    )

    expect_raises(ArgumentError, /Ed25519 sender key pairs must include private key PEM/) do
      ctx.send_activity(key_pair, [recipient], activity)
    end
  end

  it "sends explicit sender key pairs to raw and typed actor recipients" do
    delivered_inboxes = [] of String
    delivered_headers = [] of HTTP::Headers
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        delivered_headers << headers
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    ctx = federation.create_context
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    raw_actor = Aptork.actor(
      "Person",
      "https://remote.example/users/bob",
      "bob",
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/bob/outbox",
      shared_inbox: "https://remote.example/inbox"
    )
    typed_actor = Aptork::Vocab::Actor.from_json_ld(Aptork.actor(
      "Person",
      "https://other.example/users/carol",
      "carol",
      "https://other.example/users/carol/inbox",
      "https://other.example/users/carol/outbox"
    ))
    activity = Aptork.create(
      "https://local.example/activities/key-actor-recipient",
      key_pair.owner,
      Aptork.note("https://local.example/notes/key-actor-recipient", "Hello")
    )

    raw_result = ctx.send_activity(
      [key_pair],
      raw_actor,
      activity,
      Aptork::SendActivityOptions.new(prefer_shared_inbox: true)
    )
    typed_result = ctx.send_activity(key_pair, typed_actor, activity)

    raw_result.sent.size.should eq(1)
    typed_result.sent.size.should eq(1)
    delivered_inboxes.should eq([
      "https://remote.example/inbox",
      "https://other.example/users/carol/inbox",
    ])
    delivered_headers.each do |headers|
      headers["Signature"].should contain(%(keyId="#{key_pair.id}"))
    end
  end

  it "queues explicit sender key pairs for later delivery" do
    delivered_headers = [] of HTTP::Headers
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        delivered_headers << headers
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: queue)
    ctx = federation.create_context
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    recipient = Aptork::Recipient.new(
      "https://remote.example/users/bob",
      "https://remote.example/users/bob/inbox"
    )
    activity = Aptork.create(
      "https://local.example/activities/queued-key-sender",
      key_pair.owner,
      Aptork.note("https://local.example/notes/queued-key-sender", "Hello")
    )

    result = ctx.send_activity(
      [key_pair],
      [recipient],
      activity,
      Aptork::SendActivityOptions.new(ordering_key: "alice")
    )

    result.sent.should be_empty
    result.queued.size.should eq(1)
    queue.messages.first.ordering_key.should eq("alice")
    stored_key = queue.messages.first.payload["senderKeyPairs"].as_a.first.as_h
    stored_key["id"].as_s.should eq(key_pair.id)
    stored_key["privateKeyPem"].as_s.should eq(key_pair.private_key_pem)

    ctx.process_queued_activities

    delivered_headers.first["Signature"].should contain(%(keyId="#{key_pair.id}"))
    federation.sent_activities.first.sender_identifier.should eq("alice")
  end

  it "builds followers collection synchronization digests and delivery headers" do
    Aptork::Federation.collection_digest([
      "https://testing.example.org/users/1",
      "https://testing.example.org/users/2",
      "https://testing.example.org/users/2",
    ]).hexstring.should eq("c33f48cd341ef046a206b8a72ec97af65079f9a3a9b90eef79c5920dce45c61f")

    Aptork::Federation.collection_synchronization_header(
      "https://testing.example.org/users/1/followers",
      [
        "https://testing.example.org/users/2",
        "https://testing.example.org/users/1",
      ]
    ).should eq(
      %(collectionId="https://testing.example.org/users/1/followers", ) +
      %(url="https://testing.example.org/users/1/followers?base-url=https%3A%2F%2Ftesting.example.org%2F", ) +
      %(digest="c33f48cd341ef046a206b8a72ec97af65079f9a3a9b90eef79c5920dce45c61f")
    )

    delivered_headers = [] of HTTP::Headers
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        delivered_headers << headers
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox",
          shared_inbox: "https://remote.example/inbox"
        ),
        Aptork.actor(
          "Person",
          "https://remote.example/users/carol",
          "carol",
          "https://remote.example/users/carol/inbox",
          "https://remote.example/users/carol/outbox",
          shared_inbox: "https://remote.example/inbox"
        ),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    without_sync = ctx.send_activity("alice", "followers", activity, Aptork::SendActivityOptions.new(prefer_shared_inbox: true))
    with_sync = ctx.send_activity("alice", "followers", activity, Aptork::SendActivityOptions.new(prefer_shared_inbox: true, sync_collection: true))

    without_sync.sent.size.should eq(1)
    with_sync.sent.size.should eq(1)
    delivered_headers[0]["Collection-Synchronization"]?.should be_nil
    sync_header = delivered_headers[1]["Collection-Synchronization"]
    sync_header.should contain(%(collectionId="https://local.example/users/alice/followers"))
    sync_header.should contain(%(url="https://local.example/users/alice/followers?base-url=https%3A%2F%2Fremote.example%2F"))
    sync_header.should contain(%(digest="#{Aptork::Federation.collection_digest([
                                             "https://remote.example/users/bob",
                                             "https://remote.example/users/carol",
                                           ]).hexstring}"))
  end

  it "queues followers delivery and supports immediate queue bypass" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: queue)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    queued = ctx.send_activity(
      "alice",
      "followers",
      activity,
      Aptork::SendActivityOptions.new(ordering_key: "alice")
    )
    immediate = ctx.send_activity(
      "alice",
      "followers",
      activity,
      Aptork::SendActivityOptions.new(immediate: true)
    )

    queued.sent.empty?.should be_true
    queued.queued.size.should eq(1)
    queue.messages.first.ordering_key.should eq("alice")
    immediate.sent.size.should eq(1)
    delivered_inboxes.should eq(["https://remote.example/users/bob/inbox"])
  end

  it "fans out followers delivery through a consolidated queue task" do
    outbox_queue = Aptork::InProcessMessageQueue.new
    fanout_queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: outbox_queue)
      .configure_fanout_queue(fanout_queue, threshold: 2)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
        Aptork.actor("Person", "https://remote.example/users/carol", "carol", "https://remote.example/users/carol/inbox", "https://remote.example/users/carol/outbox"),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/fanout",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/fanout", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)

    result.fanout_queued.should be_true
    result.queued.should be_empty
    fanout_queue.depth("fanout").should eq(1)
    outbox_queue.depth("outbox").should eq(0)
    fanout_queue.messages.first.payload["type"].as_s.should eq("FanoutDelivery")

    ctx.process_queued_fanout_activities.should eq([Aptork::QueueProcessResult::Processed])

    fanout_queue.depth("fanout").should eq(0)
    outbox_queue.depth("outbox").should eq(2)
    outbox_queue.messages.map { |message| message.payload["delivery"].as_h["inbox"].as_s }.sort.should eq([
      "https://remote.example/users/bob/inbox",
      "https://remote.example/users/carol/inbox",
    ])
  end

  it "honors force and skip fanout options" do
    outbox_queue = Aptork::InProcessMessageQueue.new
    fanout_queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: outbox_queue)
      .configure_fanout_queue(fanout_queue, threshold: 10)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/fanout-options",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/fanout-options", "Hello")
    )

    forced = ctx.send_activity("alice", "followers", activity, Aptork::SendActivityOptions.new(fanout: "force"))
    skipped = ctx.send_activity("alice", "followers", activity, Aptork::SendActivityOptions.new(fanout: "skip"))

    forced.fanout_queued.should be_true
    skipped.fanout_queued.should be_false
    skipped.queued.size.should eq(1)
    fanout_queue.depth("fanout").should eq(1)
    outbox_queue.depth("outbox").should eq(1)
  end

  it "rejects invalid fanout options instead of treating them as auto" do
    outbox_queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: outbox_queue)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/bad-fanout",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/bad-fanout", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/users/bob/inbox")

    expect_raises(ArgumentError, /fanout must be/) do
      ctx.send_activity("alice", [recipient], activity, Aptork::SendActivityOptions.new(fanout: "sometimes"))
    end

    outbox_queue.depth("outbox").should eq(0)
  end

  it "uses shared inboxes and excludes local followers when expanding delivery" do
    delivered_inboxes = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(url : String, _headers : HTTP::Headers, _body : String) do
        delivered_inboxes << url
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox",
          shared_inbox: "https://remote.example/inbox"
        ),
        Aptork.actor(
          "Person",
          "https://remote.example/users/carol",
          "carol",
          "https://remote.example/users/carol/inbox",
          "https://remote.example/users/carol/outbox",
          shared_inbox: "https://remote.example/inbox"
        ),
        Aptork.actor(
          "Person",
          "https://local.example/users/dave",
          "dave",
          "https://local.example/users/dave/inbox",
          "https://local.example/users/dave/outbox"
        ),
      ]
    end)
    ctx = federation.create_context
    ticket = Aptork.forgefed_ticket("https://local.example/tickets/1", "Bug", "Fix it")
    activity = Aptork.create("https://local.example/activities/create-ticket-1", ctx.get_actor_uri("alice"), ticket)

    result = ctx.send_activity(
      "alice",
      "followers",
      activity,
      Aptork::SendActivityOptions.new(
        prefer_shared_inbox: true,
        exclude_base_uris: ["https://local.example"]
      )
    )

    result.sent.size.should eq(1)
    delivered_inboxes.should eq(["https://remote.example/inbox"])
  end

  it "dispatches actor key pairs and exposes public keys on actors" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      owner = ctx.get_actor_uri(identifier)
      [
        Aptork::ActorKeyPair.new(
          id: "#{owner}#main-key",
          owner: owner,
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"
        ),
      ]
    end)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)

    ctx = federation.create_context
    keys = ctx.get_actor_key_pairs("alice")
    actor = ctx.actor("alice").not_nil!

    keys.size.should eq(1)
    key = actor["publicKey"].as_h
    key["type"].as_s.should eq("CryptographicKey")
    key["id"].as_s.should eq("https://local.example/users/alice#main-key")
    key["owner"].as_s.should eq("https://local.example/users/alice")
    key["publicKeyPem"].as_s.includes?("BEGIN PUBLIC KEY").should be_true
  end

  it "marks contexts used inside key pair dispatchers" do
    dispatcher_marker = nil.as(String?)
    nested_marker = nil.as(String?)
    federation = Aptork::Federation.create("https://local.example")
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      dispatcher_marker = ctx.key_pairs_dispatcher_identifier
      if nested_marker.nil?
        nested_marker = ctx.key_pairs_dispatcher_identifier
        ctx.get_actor_key_pairs(identifier)
      end
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)

    keys = federation.create_context.get_actor_key_pairs("alice")

    keys.size.should eq(1)
    dispatcher_marker.should eq("alice")
    nested_marker.should eq("alice")
  end

  it "signs immediate outbound delivery with the sender key pair dispatcher" do
    captured_signature = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        captured_signature = headers["Signature"]
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.send_activity("alice", [recipient], activity)

    captured_signature.includes?(%(keyId="https://local.example/actors/alice#main-key")).should be_true
    captured_signature.includes?(%(algorithm="rsa-sha256")).should be_true
  end

  it "adds Ed25519 object proofs before immediate follower fanout" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    delivered_payloads = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payloads << body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_key_pairs_dispatcher(->(_ctx : Aptork::Context, _identifier : String) do
      [key_pair]
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
        Aptork.actor("Person", "https://remote.example/users/carol", "carol", "https://remote.example/users/carol/inbox", "https://remote.example/users/carol/outbox"),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity, Aptork::SendActivityOptions.new(immediate: true))

    delivered_payloads.size.should eq(2)
    delivered_payloads.uniq.size.should eq(1)
    signed = JSON.parse(delivered_payloads.first).as_h
    proof = signed["proof"].as_h
    proof["type"].as_s.should eq("DataIntegrityProof")
    proof["cryptosuite"].as_s.should eq("eddsa-jcs-2022")
    proof["verificationMethod"].as_s.should eq(key_pair.id)
    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
    result.sent.all? { |record| record.activity["proof"]? }.should be_true
    activity.has_key?("proof").should be_false
  end

  it "queues pre-signed Ed25519 object proofs before outbound fanout" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", outbox_queue: queue)
    federation.set_key_pairs_dispatcher(->(_ctx : Aptork::Context, _identifier : String) do
      [key_pair]
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
        Aptork.actor("Person", "https://remote.example/users/carol", "carol", "https://remote.example/users/carol/inbox", "https://remote.example/users/carol/outbox"),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)

    result.queued.size.should eq(2)
    queued_activities = queue.messages.map { |message| message.payload["activity"].as_h }
    queued_activities.map { |queued| queued["proof"].to_json }.uniq.size.should eq(1)
    Aptork::Signatures.verify_object_proof?(queued_activities.first, key_pair).should be_true
  end

  it "carries explicit sender key pairs through queued fanout delivery" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    captured_signatures = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        captured_signatures << headers["Signature"]
        {202, "ok"}
      end
    )
    outbox_queue = Aptork::InProcessMessageQueue.new
    fanout_queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: outbox_queue)
      .configure_fanout_queue(fanout_queue, threshold: 10)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/keyed-fanout",
      key_pair.owner,
      Aptork.note("https://local.example/notes/keyed-fanout", "Hello")
    )
    recipients = [
      Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/users/bob/inbox"),
      Aptork::Recipient.new("https://remote.example/users/carol", "https://remote.example/users/carol/inbox"),
    ]

    result = ctx.send_activity(
      [key_pair],
      recipients,
      activity,
      Aptork::SendActivityOptions.new(fanout: "force")
    )

    result.fanout_queued.should be_true
    fanout_queue.depth("fanout").should eq(1)
    outbox_queue.depth("outbox").should eq(0)
    fanout_queue.messages.first.payload["senderKeyPairs"].as_a.first.as_h["privateKeyPem"].as_s.should eq(key_pair.private_key_pem)

    ctx.process_queued_fanout_activities.should eq([Aptork::QueueProcessResult::Processed])
    outbox_queue.depth("outbox").should eq(2)
    outbox_queue.messages.all? { |message| message.payload["senderKeyPairs"].as_a.first.as_h["id"].as_s == key_pair.id }.should be_true

    ctx.process_queued_activities.should eq([
      Aptork::QueueProcessResult::Processed,
      Aptork::QueueProcessResult::Processed,
    ])
    captured_signatures.size.should eq(2)
    captured_signatures.all? { |signature| signature.includes?(%(keyId="#{key_pair.id}")) }.should be_true
  end

  it "applies outbound activity transformers before Ed25519 proofs are created" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_key_pairs_dispatcher(->(_ctx : Aptork::Context, _identifier : String) do
      [key_pair]
    end)
    federation.add_activity_transformer(->(_ctx : Aptork::Context, transform : Aptork::ActivityTransformContext, activity : Aptork::JsonMap) do
      activity["audience"] = Aptork.json(transform.recipients.map(&.id))
      activity
    end)
    federation.add_activity_transformer(->(_ctx : Aptork::Context, _transform : Aptork::ActivityTransformContext, activity : Aptork::JsonMap) do
      activity["summary"] = Aptork.json("transformed")
      activity
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.send_activity("alice", [recipient], activity)

    signed = JSON.parse(delivered_payload).as_h
    signed["audience"].as_a.first.as_s.should eq("https://remote.example/users/bob")
    signed["summary"].as_s.should eq("transformed")
    signed["proof"].as_h["verificationMethod"].as_s.should eq(key_pair.id)
    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
    activity.has_key?("summary").should be_false
  end

  it "applies outbound transformers once before queued fanout and not during queue processing" do
    transform_calls = 0
    delivered_payloads = [] of String
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payloads << body
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: queue)
    federation.add_activity_transformer(->(_ctx : Aptork::Context, transform : Aptork::ActivityTransformContext, activity : Aptork::JsonMap) do
      transform_calls += 1
      activity["collectionName"] = Aptork.json(transform.collection_name)
      activity
    end)
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
        Aptork.actor("Person", "https://remote.example/users/carol", "carol", "https://remote.example/users/carol/inbox", "https://remote.example/users/carol/outbox"),
      ]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    result = ctx.send_activity("alice", "followers", activity)
    ctx.process_queued_activities

    result.queued.size.should eq(2)
    transform_calls.should eq(1)
    queue.depth("outbox").should eq(0)
    delivered_payloads.size.should eq(2)
    delivered_payloads.each do |payload|
      JSON.parse(payload).as_h["collectionName"].as_s.should eq("followers")
    end
  end

  it "provides Fedify-style default outbound activity transformers" do
    delivered_payload = ""
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.set_key_pairs_dispatcher(->(_ctx : Aptork::Context, _identifier : String) do
      [key_pair]
    end)
    federation.add_default_activity_transformers
    ctx = federation.create_context
    ticket = Aptork.forgefed_ticket(
      "https://local.example/tickets/1",
      "Bug",
      "Fix it",
      attributed_to: key_pair.owner,
      attachment: [Aptork.object("Document", "https://local.example/patches/1")]
    )
    ticket["attachment"] = ticket["attachment"].as_a.first
    ticket["to"] = Aptork.json("Public")
    activity = Aptork.object("Create", nil, Aptork::JsonMap{
      "actor"  => Aptork.json(Aptork.actor("Person", ctx.get_actor_uri("alice"), "alice", "#{ctx.get_actor_uri("alice")}/inbox", "#{ctx.get_actor_uri("alice")}/outbox")),
      "object" => Aptork.json(ticket),
      "to"     => Aptork.json(["as:Public"]),
      "cc"     => Aptork.json(["Public"]),
    })
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.send_activity("alice", [recipient], activity)

    delivered = JSON.parse(delivered_payload).as_h
    delivered["id"].as_s.should start_with("https://local.example/#Create/")
    delivered["actor"].as_s.should eq(ctx.get_actor_uri("alice"))
    delivered["to"].as_a.first.as_s.should eq(Aptork::PUBLIC_COLLECTION)
    delivered["cc"].as_a.first.as_s.should eq(Aptork::PUBLIC_COLLECTION)
    delivered["object"].as_h["to"].as_s.should eq(Aptork::PUBLIC_COLLECTION)
    delivered["object"].as_h["attachment"].as_a.first.as_h["id"].as_s.should eq("https://local.example/patches/1")
    Aptork::Signatures.verify_object_proof?(delivered, key_pair).should be_true
    activity.has_key?("id").should be_false
    activity["actor"].as_h["id"].as_s.should eq(ctx.get_actor_uri("alice"))
    activity["to"].as_a.first.as_s.should eq("as:Public")
    activity["object"].as_h["attachment"].as_h["id"].as_s.should eq("https://local.example/patches/1")
  end

  it "rejects actorless sends after default outbound transformers run" do
    delivered = false
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, _body : String) do
        delivered = true
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport)
    federation.add_default_activity_transformers
    ctx = federation.create_context
    activity = Aptork.object("Create", nil, Aptork::JsonMap{
      "object" => Aptork.json(Aptork.note("https://local.example/notes/actorless-default-transform", "Hello")),
    })
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    expect_raises(ArgumentError, /at least one actor/) do
      ctx.send_activity("alice", [recipient], activity)
    end
    delivered.should be_false
  end

  it "signs queued outbound delivery when queued messages are processed" do
    captured_signature = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        captured_signature = headers["Signature"]
        {202, "ok"}
      end
    )
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", transport, outbox_queue: queue)
    federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
      [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
    end)
    ctx = federation.create_context
    activity = Aptork.create(
      "https://local.example/activities/1",
      ctx.get_actor_uri("alice"),
      Aptork.note("https://local.example/notes/1", "Hello")
    )
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.enqueue_activity("alice", [recipient], activity)
    ctx.process_queued_activities

    captured_signature.includes?(%(keyId="https://local.example/actors/alice#main-key")).should be_true
  end

  it "routes authorized client-to-server outbox POSTs to outbox listeners" do
    received = nil.as(Aptork::JsonMap?)
    seen_identifier = nil.as(String?)
    undelivered = false
    federation = Aptork::Federation.create("https://local.example")
    federation.on_undelivered_outbox_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
      undelivered = true
      nil
    end)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .authorize(->(ctx : Aptork::Context, identifier : String) do
        ctx.inbound_request.try(&.headers["Authorization"]?) == "Bearer alice" && identifier == "alice"
      end)
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        seen_identifier = ctx.identifier
        received = activity
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {
        "Content-Type"  => "application/activity+json",
        "Authorization" => "Bearer alice",
      },
      body: activity.to_json
    ))

    response.status.should eq(202)
    seen_identifier.should eq("alice")
    received.not_nil!["id"].as_s.should eq("https://local.example/activities/1")
    undelivered.should be_true
  end

  it "returns Fedify-style 405 for outbox POSTs without listeners" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Accept" => "application/json", "Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(405)
    response.headers["Allow"].should eq("GET, HEAD")
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.headers["Vary"].should eq("Accept")
    response.body.should eq("Method not allowed.")
  end

  it "routes outbox activities to Fedify-style Activity catch-all listeners" do
    calls = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.on_undelivered_outbox_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .authorize(->(_ctx : Aptork::Context, _identifier : String) { true })
      .on("Activity", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls << "activity"
        nil
      end)
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls << "create"
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {
        "Content-Type"  => "application/activity+json",
        "Authorization" => "Bearer alice",
      },
      body: activity.to_json
    ))

    response.status.should eq(202)
    calls.should eq(["create", "activity"])
  end

  it "passes typed vocabulary objects to Fedify-style outbox listeners" do
    seen_create = nil.as(Aptork::Vocab::Create?)
    federation = Aptork::Federation.create("https://local.example")
    federation.on_undelivered_outbox_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .authorize(->(_ctx : Aptork::Context, _identifier : String) { true })
      .on(Aptork::Vocab::Create, ->(_ctx : Aptork::Context, create : Aptork::Vocab::Create) do
        seen_create = create
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/typed-outbox",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/typed-outbox", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {
        "Content-Type"  => "application/activity+json",
        "Authorization" => "Bearer alice",
      },
      body: activity.to_json
    ))

    response.status.should eq(202)
    seen_create.should be_a(Aptork::Vocab::Create)
    seen_create.not_nil!.object.should be_a(Aptork::Vocab::Note)
  end

  it "records dependency-free telemetry for HTTP, inbox, outbox, and delivery paths" do
    telemetry = RecordingTelemetry.new
    delivered_payload = ""
    transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, _headers : HTTP::Headers, body : String) do
        delivered_payload = body
        {202, "ok"}
      end
    )
    federation = Aptork::Federation.create("https://local.example", transport, telemetry: telemetry)
    federation.on_undelivered_outbox_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .authorize(->(_ctx : Aptork::Context, _identifier : String) { true })
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        ctx.send_activity("alice", [Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")], activity)
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    federation.handle(Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "application/activity+json"})).status.should eq(200)
    federation.handle(Aptork::Request.new("POST", "/users/alice/inbox", body: activity.to_json)).status.should eq(202)
    federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    )).status.should eq(202)

    delivered_payload.empty?.should be_false
    telemetry.spans.includes?("aptork.http.request").should be_true
    telemetry.spans.includes?("aptork.inbox.route").should be_true
    telemetry.spans.includes?("aptork.outbox.route").should be_true
    telemetry.spans.includes?("aptork.outbox.deliver").should be_true
    telemetry.counters.includes?("aptork.http.requests").should be_true
    telemetry.counters.includes?("aptork.inbox.activities").should be_true
    telemetry.counters.includes?("aptork.outbox.activities").should be_true
    telemetry.counters.includes?("aptork.outbox.deliveries").should be_true
    telemetry.histograms.includes?("aptork.http.request.duration_ms").should be_true
    telemetry.counter_attributes.any? { |attrs| attrs["status"]? == "processed" }.should be_true
    telemetry.counter_attributes.any? { |attrs| attrs["status"]? == "delivered" }.should be_true
  end

  it "rejects outbox POSTs when the outbox actor is missing or tombstoned" do
    handled = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    no_dispatcher = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    federation.set_actor_dispatcher("/users/{identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end)
    missing = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.tombstone(ctx.get_actor_uri(identifier), "Person").as(Aptork::JsonMap?)
    end)
    tombstoned = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    no_dispatcher.status.should eq(404)
    missing.status.should eq(404)
    tombstoned.status.should eq(404)
    handled.should be_false
  end

  it "reports outbox listener errors to scoped handlers" do
    captured_identifier = ""
    captured_message = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        raise "broken outbox listener"
      end)
      .on_error(->(ctx : Aptork::Context, error : Exception) do
        captured_identifier = ctx.outbox_identifier || ""
        captured_message = error.message || ""
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(500)
    response.body.should eq("Internal server error.")
    captured_identifier.should eq("alice")
    captured_message.should eq("broken outbox listener")
  end

  it "does not warn for outbox POSTs that deliver during listeners" do
    undelivered = false
    federation = Aptork::Testing.create_federation("https://local.example")
    federation.on_undelivered_outbox_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
      undelivered = true
      nil
    end)
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
        ctx.send_activity("alice", [recipient], activity)
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(202)
    federation.sent_activities.size.should eq(1)
    undelivered.should be_false
  end

  it "logs a default warning for outbox POSTs that listeners do not deliver" do
    backend = Log::MemoryBackend.new
    Log.setup("aptork.federation.outbox", :warn, backend)
    begin
      federation = Aptork::Federation.create("https://local.example")
      federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
        Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
      end)
      federation.set_outbox_listeners("/users/{identifier}/outbox")
        .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
          nil
        end)
      activity = Aptork.create(
        "https://local.example/activities/1",
        "https://local.example/users/alice",
        Aptork.note("https://local.example/notes/1", "Hello")
      )

      response = federation.handle(Aptork::Request.new(
        "POST",
        "/users/alice/outbox",
        headers: {"Content-Type" => "application/activity+json"},
        body: activity.to_json
      ))

      response.status.should eq(202)
      backend.entries.size.should eq(1)
      backend.entries.first.source.should eq("aptork.federation.outbox")
      backend.entries.first.message.should contain("without delivering activity https://local.example/activities/1")
    ensure
      Log.setup(:none)
    end
  end

  it "rejects unauthorized outbox POSTs before outbox listeners run" do
    called = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .authorize(->(_ctx : Aptork::Context, _identifier : String) { false })
      .on_any(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        called = true
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(401)
    called.should be_false
  end

  it "rejects outbox POSTs whose actor does not match the outbox actor" do
    called = false
    captured_error = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on_any(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        called = true
        nil
      end)
      .on_error(->(_ctx : Aptork::Context, error : Exception) do
        captured_error = error.message || ""
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/mallory",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(400)
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.body.should eq("The activity actor does not match the outbox owner.")
    captured_error.should eq("The activity actor does not match the outbox owner.")
    called.should be_false
  end

  it "falls back to the route actor URI for outbox POST ownership when actor id is missing" do
    handled = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).tap do |actor|
        actor.delete("id")
      end.as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/missing-actor-id",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/missing-actor-id", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(202)
    handled.should be_true
  end

  it "matches outbox POST array actors using Fedify's all-actors rule" do
    calls = 0
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        calls += 1
        nil
      end)
    accepted = Aptork.create(
      "https://local.example/activities/array-actor-accepted",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/array-actor-accepted", "Hello")
    )
    accepted["actor"] = Aptork.json([
      "https://local.example/users/alice",
      {"id" => "https://local.example/users/alice"},
    ])
    rejected = Aptork.create(
      "https://local.example/activities/array-actor-rejected",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/array-actor-rejected", "Hello")
    )
    rejected["actor"] = Aptork.json([
      "https://local.example/users/alice",
      "https://local.example/users/mallory",
    ])

    accepted_response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: accepted.to_json
    ))
    rejected_response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: rejected.to_json
    ))

    accepted_response.status.should eq(202)
    accepted_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    rejected_response.status.should eq(400)
    rejected_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    rejected_response.body.should eq("The activity actor does not match the outbox owner.")
    calls.should eq(1)
  end

  it "rejects outbox POSTs whose actor is missing" do
    called = false
    captured_error = ""
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on_any(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        called = true
        nil
      end)
      .on_error(->(_ctx : Aptork::Context, error : Exception) do
        captured_error = error.message || ""
        nil
      end)
    activity = Aptork::JsonMap{
      "id"     => Aptork.json("https://local.example/activities/1"),
      "type"   => Aptork.json("Create"),
      "object" => Aptork.json(Aptork.note("https://local.example/notes/1", "Hello")),
    }

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(400)
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.body.should eq("The posted activity has no actor.")
    captured_error.should eq("The posted activity has no actor.")
    called.should be_false
  end

  it "accepts authorized outbox POSTs even when no listener handles the type" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
    activity = Aptork.activity(
      "Like",
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/users/alice/outbox",
      headers: {"Content-Type" => "application/activity+json"},
      body: activity.to_json
    ))

    response.status.should eq(202)
  end

  it "handles ActivityPub actor, object, outbox, inbox, WebFinger, and NodeInfo requests" do
    received = false
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(_ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(
        "https://local.example/users/#{params["identifier"]}/notes/#{params["note_id"]}",
        "Hello"
      ).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "Hello")]
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        received = true
        nil
      end)
    federation.set_nodeinfo_dispatcher(->(_ctx : Aptork::Context) do
      Aptork.nodeinfo("aptork", Aptork::VERSION)
    end)

    actor_response = federation.handle(activitypub_get("/users/alice"))
    object_response = federation.handle(activitypub_get("/users/alice/notes/1"))
    outbox_response = federation.handle(activitypub_get("/users/alice/outbox"))
    webfinger_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@local.example"}
    ))
    nodeinfo_response = federation.handle(Aptork::Request.new("GET", "/.well-known/nodeinfo"))
    inbox_response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    actor_response.status.should eq(200)
    JSON.parse(actor_response.body).as_h["type"].as_s.should eq("Person")
    object_response.status.should eq(200)
    JSON.parse(object_response.body).as_h["type"].as_s.should eq("Note")
    outbox_response.status.should eq(200)
    JSON.parse(outbox_response.body).as_h["type"].as_s.should eq("OrderedCollection")
    webfinger_response.status.should eq(200)
    webfinger_response.headers["Access-Control-Allow-Origin"].should eq("*")
    JSON.parse(webfinger_response.body).as_h["subject"].as_s.should eq("acct:alice@local.example")
    nodeinfo_response.status.should eq(200)
    inbox_response.status.should eq(202)
    received.should be_true
  end

  it "handles HEAD for ActivityPub resources, WebFinger, and NodeInfo" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor("Person", ctx.get_actor_uri(identifier), identifier, ctx.get_inbox_uri(identifier), ctx.get_outbox_uri(identifier)).as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(_ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note("https://local.example/users/#{params["identifier"]}/notes/#{params["note_id"]}", "Hello").as(Aptork::JsonMap?)
    end)
    federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "Hello")]
    end)
    federation.set_nodeinfo_dispatcher(->(_ctx : Aptork::Context) do
      Aptork.nodeinfo("aptork", Aptork::VERSION)
    end)

    actor = federation.handle(Aptork::Request.new("HEAD", "/users/alice", headers: {"Accept" => "application/activity+json"}))
    object = federation.handle(Aptork::Request.new("HEAD", "/users/alice/notes/1", headers: {"Accept" => "application/activity+json"}))
    outbox = federation.handle(Aptork::Request.new("HEAD", "/users/alice/outbox", headers: {"Accept" => "application/activity+json"}))
    webfinger = federation.handle(Aptork::Request.new("HEAD", "/.well-known/webfinger", query: {"resource" => "acct:alice@local.example"}))
    nodeinfo = federation.handle(Aptork::Request.new("HEAD", "/.well-known/nodeinfo"))
    missing = federation.handle(Aptork::Request.new("HEAD", "/missing", headers: {"Accept" => "application/activity+json"}))
    unsupported = federation.handle(Aptork::Request.new("PUT", "/users/alice"))

    [actor, object, outbox].each do |response|
      response.status.should eq(200)
      response.headers["Content-Type"].should eq(Aptork::FEDERATION_ACTIVITY_CONTENT_TYPE)
      response.headers["Vary"].should eq("Accept")
      response.body.should eq("")
    end
    webfinger.status.should eq(200)
    webfinger.headers["Content-Type"].should eq("application/jrd+json")
    webfinger.headers["Access-Control-Allow-Origin"].should eq("*")
    webfinger.body.should eq("")
    nodeinfo.status.should eq(200)
    nodeinfo.headers["Content-Type"].should eq("application/jrd+json")
    nodeinfo.body.should eq("")
    missing.status.should eq(404)
    missing.body.should eq("")
    unsupported.status.should eq(405)
    unsupported.headers["Allow"].should eq("GET, HEAD, POST")
  end

  it "only advertises NodeInfo document routes after a dispatcher is configured" do
    federation = Aptork::Federation.create("https://local.example")

    well_known = federation.handle(Aptork::Request.new("GET", "/.well-known/nodeinfo"))
    document = federation.handle(Aptork::Request.new("GET", "/nodeinfo/2.1"))

    well_known.status.should eq(200)
    well_known.headers["Content-Type"].should eq("application/jrd+json")
    JSON.parse(well_known.body).as_h["links"].as_a.should be_empty
    document.status.should eq(404)
    expect_raises(ArgumentError, "No NodeInfo dispatcher registered") do
      federation.create_context.get_nodeinfo_uri
    end
  end

  it "requires configured and live recipient actors for inbox POSTs" do
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    no_actor_dispatcher = Aptork::Federation.create("https://local.example")
    no_actor_dispatcher.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    missing_actor = Aptork::Federation.create("https://local.example")
    missing_actor.set_actor_dispatcher("/users/{identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
      nil.as(Aptork::JsonMap?)
    end)
    missing_actor.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })
    tombstone_actor = Aptork::Federation.create("https://local.example")
    tombstone_actor.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.tombstone(ctx.get_actor_uri(identifier)).as(Aptork::JsonMap?)
    end)
    tombstone_actor.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) { nil })

    no_actor_dispatcher.handle(Aptork::Request.new("POST", "/inbox", body: activity.to_json)).status.should eq(404)
    missing_actor.handle(Aptork::Request.new("POST", "/users/alice/inbox", body: activity.to_json)).status.should eq(404)
    tombstone_actor.handle(Aptork::Request.new("POST", "/users/alice/inbox", body: activity.to_json)).status.should eq(404)
  end

  it "maps inbox route activity results to Fedify-style HTTP responses" do
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .with_idempotency
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
      .on("Update", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        raise "listener failed"
      end)
    create = Aptork.create(
      "https://remote.example/activities/create-response",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    unsupported = Aptork.activity(
      "Announce",
      "https://remote.example/activities/announce-response",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/2", "Hi")
    )
    missing_actor = Aptork::JsonMap{
      "id"     => Aptork.json("https://remote.example/activities/missing-actor-response"),
      "type"   => Aptork.json("Create"),
      "object" => Aptork.json(Aptork.note("https://remote.example/notes/3", "Hi")),
    }
    failing = Aptork.activity(
      "Update",
      "https://remote.example/activities/update-response",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/4", "Hi")
    )
    array_actor = Aptork.create(
      "https://remote.example/activities/array-actor-response",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/5", "Hi")
    )
    array_actor["actor"] = Aptork.json(["https://remote.example/users/bob"])

    processed = federation.handle(Aptork::Request.new("POST", "/inbox", headers: {"Accept" => "application/activity+json"}, body: create.to_json))
    duplicate = federation.handle(Aptork::Request.new("POST", "/inbox", body: create.to_json))
    ignored = federation.handle(Aptork::Request.new("POST", "/inbox", body: unsupported.to_json))
    invalid = federation.handle(Aptork::Request.new("POST", "/inbox", body: missing_actor.to_json))
    errored = federation.handle(Aptork::Request.new("POST", "/inbox", body: failing.to_json))
    array_processed = federation.handle(Aptork::Request.new("POST", "/inbox", body: array_actor.to_json))

    processed.status.should eq(202)
    processed.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    processed.headers["Vary"].should eq("Accept")
    duplicate.status.should eq(202)
    duplicate.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    duplicate.body.should eq("Activity <https://remote.example/activities/create-response> has already been processed.")
    ignored.status.should eq(202)
    ignored.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    ignored.body.should eq("")
    invalid.status.should eq(400)
    invalid.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    invalid.body.should eq("Missing actor.")
    errored.status.should eq(500)
    errored.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    errored.body.should eq("Internal server error.")
    array_processed.status.should eq(202)
  end

  it "returns Fedify-style response bodies for queued inbox POSTs" do
    queue = Aptork::InProcessMessageQueue.new
    federation = Aptork::Federation.create("https://local.example", inbox_queue: queue)
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/queued-response",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/queued-response", "Hi")
    )

    response = federation.handle(Aptork::Request.new("POST", "/inbox", body: activity.to_json))

    response.status.should eq(202)
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.body.should eq("Activity is enqueued.")
    queue.depth("inbox").should eq(1)
  end

  it "returns Fedify-style invalid body responses for inbox and outbox POSTs" do
    inbox_errors = [] of String
    outbox_errors = [] of String
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
      .on_error(->(_ctx : Aptork::Context, error : Exception) do
        inbox_errors << (error.message || "")
        nil
      end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
      .on_error(->(_ctx : Aptork::Context, error : Exception) do
        outbox_errors << (error.message || "")
        nil
      end)

    inbox = federation.handle(Aptork::Request.new("POST", "/inbox", body: "{"))
    outbox = federation.handle(Aptork::Request.new("POST", "/users/alice/outbox", body: "{"))
    invalid_inbox = federation.handle(Aptork::Request.new("POST", "/inbox", body: "[]"))
    invalid_outbox = federation.handle(Aptork::Request.new("POST", "/users/alice/outbox", body: "[]"))
    object_inbox = federation.handle(Aptork::Request.new("POST", "/inbox", body: Aptork.note("https://remote.example/notes/not-activity", "Not an activity").to_json))
    object_outbox = federation.handle(Aptork::Request.new("POST", "/users/alice/outbox", body: Aptork.note("https://local.example/notes/not-activity", "Not an activity").to_json))

    inbox.status.should eq(400)
    inbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    inbox.body.should eq("Invalid JSON.")
    outbox.status.should eq(400)
    outbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    outbox.body.should eq("Invalid JSON.")
    invalid_inbox.status.should eq(400)
    invalid_inbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    invalid_inbox.body.should eq("Invalid activity.")
    invalid_outbox.status.should eq(400)
    invalid_outbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    invalid_outbox.body.should eq("Invalid activity.")
    object_inbox.status.should eq(400)
    object_inbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    object_inbox.body.should eq("Invalid activity.")
    object_outbox.status.should eq(400)
    object_outbox.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    object_outbox.body.should eq("Invalid activity.")
    inbox_errors.size.should eq(3)
    inbox_errors.count("Invalid activity.").should eq(2)
    outbox_errors.size.should eq(3)
    outbox_errors.count("Invalid activity.").should eq(2)
  end

  it "returns gone for Tombstone actors and their WebFinger accounts" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      if identifier == "alice"
        Aptork.tombstone(
          ctx.get_actor_uri(identifier),
          "Person",
          "2026-05-22T00:00:00Z"
        ).as(Aptork::JsonMap?)
      else
        nil
      end
    end)

    actor_response = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/activity+json"}
    ))
    webfinger_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@local.example"}
    ))

    actor_response.status.should eq(410)
    actor_response.headers["Vary"].should eq("Accept")
    tombstone = JSON.parse(actor_response.body).as_h
    tombstone["type"].as_s.should eq("Tombstone")
    tombstone["formerType"].as_s.should eq("Person")
    tombstone["deleted"].as_s.should eq("2026-05-22T00:00:00Z")
    webfinger_response.status.should eq(410)
    webfinger_response.headers["Access-Control-Allow-Origin"].should eq("*")
    webfinger_response.headers["Content-Type"]?.should be_nil
    webfinger_response.body.should eq("")
  end

  it "recognizes expanded and array-valued Tombstone actor types" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      case identifier
      when "expanded"
        Aptork::JsonMap{
          "@context" => Aptork.json(Aptork::ACTIVITYSTREAMS_CONTEXT),
          "id"       => Aptork.json(ctx.get_actor_uri(identifier)),
          "type"     => Aptork.json("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Tombstone"),
        }.as(Aptork::JsonMap?)
      when "array"
        Aptork::JsonMap{
          "@context" => Aptork.json(Aptork::ACTIVITYSTREAMS_CONTEXT),
          "id"       => Aptork.json(ctx.get_actor_uri(identifier)),
          "type"     => Aptork.json(["Object", "#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Tombstone"]),
        }.as(Aptork::JsonMap?)
      else
        nil
      end
    end)

    expanded_actor = federation.handle(Aptork::Request.new(
      "GET",
      "/users/expanded",
      headers: {"Accept" => "application/activity+json"}
    ))
    array_actor = federation.handle(Aptork::Request.new(
      "GET",
      "/users/array",
      headers: {"Accept" => "application/activity+json"}
    ))
    array_webfinger = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:array@local.example"}
    ))

    expanded_actor.status.should eq(410)
    array_actor.status.should eq(410)
    array_webfinger.status.should eq(410)
    array_webfinger.body.should eq("")
  end

  it "warns about dispatched actors that do not match registered Fedify-style routes" do
    backend = Log::MemoryBackend.new
    Log.setup("aptork.federation.actor", :warn, backend)
    begin
      federation = Aptork::Federation.create("https://local.example")
      federation.set_actor_dispatcher("/users/{identifier}", ->(_ctx : Aptork::Context, _identifier : String) do
        Aptork::JsonMap{
          "type"      => Aptork.json("Person"),
          "id"        => Aptork.json("https://local.example/users/other"),
          "following" => Aptork.json("https://local.example/users/alice/wrong-following"),
          "endpoints" => Aptork.json({"sharedInbox" => "https://local.example/wrong-inbox"}),
        }.as(Aptork::JsonMap?)
      end)
      federation.set_following_dispatcher("/users/{identifier}/following", ->(_ctx : Aptork::Context, _identifier : String) do
        [] of Aptork::JsonMap
      end)
      federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
        [] of Aptork::JsonMap
      end)
      federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(_ctx : Aptork::Context, _identifier : String) do
        [] of Aptork::JsonMap
      end)
      federation.set_key_pairs_dispatcher(->(ctx : Aptork::Context, identifier : String) do
        [generate_rsa_test_key_pair(ctx.get_actor_uri(identifier))]
      end)
      federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")

      response = federation.handle(Aptork::Request.new(
        "GET",
        "/users/alice",
        headers: {"Accept" => "application/activity+json"}
      ))
      messages = backend.entries.map(&.message)

      response.status.should eq(200)
      messages.should contain("Actor dispatcher returned an actor with an id property that does not match the actor URI. Set the property with Context#get_actor_uri(identifier).")
      messages.should contain("You configured a following collection dispatcher, but the actor's following property does not match the following collection URI. Set the property with Context#get_following_uri(identifier).")
      messages.should contain("You configured a followers collection dispatcher, but the actor does not have a followers property. Set the property with Context#get_followers_uri(identifier).")
      messages.should contain("You configured an outbox collection dispatcher, but the actor does not have an outbox property. Set the property with Context#get_outbox_uri(identifier).")
      messages.should contain("You configured inbox listeners, but the actor does not have an inbox property. Set the property with Context#get_inbox_uri(identifier).")
      messages.should contain("You configured inbox listeners, but the actor's endpoints.sharedInbox property does not match the shared inbox URI. Set the property with Context#get_inbox_uri.")
      messages.should contain("You configured a key pairs dispatcher, but the actor does not have a publicKey property. Set the property with Context#get_actor_key_pairs(identifier).")
      messages.should contain("You configured a key pairs dispatcher, but the actor does not have an assertionMethod property. Set the property with Context#get_actor_key_pairs(identifier).")
    ensure
      Log.setup(:none)
    end
  end

  it "honors Accept negotiation for ActivityPub GET routes" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      if identifier == "alice"
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ).as(Aptork::JsonMap?)
      else
        nil
      end
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(_ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note("https://local.example/users/#{params["identifier"]}/notes/#{params["note_id"]}", "Hello").as(Aptork::JsonMap?)
    end)
    federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "Hello")]
    end)

    rejected_html_preferred = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "text/html, application/activity+json"}
    ))
    accepted_profile = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => %(application/ld+json; profile="https://www.w3.org/ns/activitystreams")}
    ))
    rejected_wildcard = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"accept" => "text/html;q=0.9, application/*;q=0.1"}
    ))
    accepted_case_insensitive = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"ACCEPT" => "Application/Activity+Json;q=0.5"}
    ))
    rejected_absent = federation.handle(Aptork::Request.new("GET", "/users/alice"))
    rejected_actor = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "text/html"}
    ))
    rejected_object = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice/notes/1",
      headers: {"Accept" => "text/html"}
    ))
    rejected_outbox = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice/outbox",
      headers: {"Accept" => "text/html"}
    ))
    rejected_q_zero = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/activity+json;q=0, text/html"}
    ))
    accepted_plain_json = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/json"}
    ))
    accepted_plain_jsonld = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/ld+json"}
    ))
    accepted_activity_preferred = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "text/html;q=0.5, application/activity+json;q=0.8"}
    ))

    accepted_activity_preferred.status.should eq(200)
    accepted_activity_preferred.headers["Content-Type"].should eq(Aptork::FEDERATION_ACTIVITY_CONTENT_TYPE)
    accepted_activity_preferred.headers["Vary"].should eq("Accept")
    accepted_profile.status.should eq(200)
    accepted_case_insensitive.status.should eq(200)
    accepted_plain_json.status.should eq(200)
    accepted_plain_jsonld.status.should eq(200)
    rejected_html_preferred.status.should eq(406)
    rejected_wildcard.status.should eq(406)
    rejected_absent.status.should eq(406)
    rejected_actor.status.should eq(406)
    rejected_object.status.should eq(406)
    rejected_outbox.status.should eq(406)
    rejected_q_zero.status.should eq(406)
    rejected_actor.headers["Vary"].should eq("Accept, Signature")
    rejected_actor.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    rejected_actor.body.should eq("Not Acceptable")
  end

  it "delegates not-found and not-acceptable responses to fetch callbacks" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      if identifier == "alice"
        Aptork.actor(
          "Person",
          ctx.get_actor_uri(identifier),
          identifier,
          ctx.get_inbox_uri(identifier),
          ctx.get_outbox_uri(identifier)
        ).as(Aptork::JsonMap?)
      else
        nil
      end
    end)
    not_found_paths = [] of String
    on_not_found = ->(request : Aptork::Request) do
      not_found_paths << request.path
      Aptork::Response.new(200, {"Content-Type" => "text/plain"}, "web app")
    end
    on_not_acceptable = ->(request : Aptork::Request) do
      if request.path == "/users/alice"
        Aptork::Response.new(200, {"Content-Type" => "text/html"}, "<h1>Alice</h1>")
      else
        Aptork::Response.new(406, {"Content-Type" => "text/plain", "Vary" => "Accept"}, "not acceptable")
      end
    end

    web_response = federation.fetch(
      Aptork::Request.new("GET", "/pages/about"),
      on_not_found: on_not_found,
      on_not_acceptable: on_not_acceptable
    )
    html_actor = federation.fetch(
      Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "text/html"}),
      on_not_found: on_not_found,
      on_not_acceptable: on_not_acceptable
    )
    activity_actor = federation.fetch(
      Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "application/activity+json"}),
      on_not_found: on_not_found,
      on_not_acceptable: on_not_acceptable
    )
    wrong_host_webfinger = federation.fetch(
      Aptork::Request.new(
        "GET",
        "/.well-known/webfinger",
        query: {"resource" => "acct:alice@remote.example"}
      ),
      on_not_found: on_not_found,
      on_not_acceptable: on_not_acceptable
    )
    unknown_webfinger = federation.fetch(
      Aptork::Request.new(
        "GET",
        "/.well-known/webfinger",
        query: {"resource" => "acct:unknown@local.example"}
      ),
      on_not_found: on_not_found,
      on_not_acceptable: on_not_acceptable
    )

    web_response.status.should eq(200)
    web_response.body.should eq("web app")
    html_actor.status.should eq(200)
    html_actor.headers["Content-Type"].should eq("text/html")
    html_actor.body.should eq("<h1>Alice</h1>")
    activity_actor.status.should eq(200)
    activity_actor.headers["Content-Type"].should eq(Aptork::FEDERATION_ACTIVITY_CONTENT_TYPE)
    wrong_host_webfinger.status.should eq(200)
    unknown_webfinger.status.should eq(200)
    not_found_paths.should eq([
      "/pages/about",
      "/.well-known/webfinger",
      "/.well-known/webfinger",
    ])
  end

  it "adapts Crystal HTTP requests and responses for framework middleware" do
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    http_request = HTTP::Request.new(
      "GET",
      "/users/alice?view=activity&view=html",
      HTTP::Headers{"Accept" => "application/activity+json", "X-Forwarded-Host" => "local.example"},
      ""
    )

    aptork_request = Aptork.request_from_http(http_request)
    response = federation.fetch(aptork_request)
    io = IO::Memory.new
    http_response = HTTP::Server::Response.new(io)
    Aptork.write_http_response(response, http_response)
    http_response.close
    raw_response = io.to_s

    aptork_request.path.should eq("/users/alice")
    aptork_request.query.should eq({"view" => "activity"})
    aptork_request.headers["Accept"].should eq("application/activity+json")
    response.status.should eq(200)
    raw_response.should contain("HTTP/1.1 200 OK")
    raw_response.should contain("Content-Type: application/activity+json")
    raw_response.should contain(%("type":"Person"))
  end

  it "delegates authorized-fetch denials to an unauthorized fetch callback" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_actor_authorizer(->(_ctx : Aptork::Context, _request : Aptork::Request, _verification : Aptork::VerificationResult, _identifier : String?, _params : Hash(String, String)) do
      false
    end)

    response = federation.fetch(
      Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "application/activity+json"}),
      on_unauthorized: ->(request : Aptork::Request) do
        Aptork::Response.new(403, {"Content-Type" => "text/plain"}, "blocked #{request.path}")
      end
    )
    default_response = federation.fetch(
      Aptork::Request.new("GET", "/users/alice", headers: {"Accept" => "application/activity+json"})
    )

    response.status.should eq(403)
    response.body.should eq("blocked /users/alice")
    default_response.status.should eq(401)
    default_response.headers["Vary"].should eq("Accept, Signature")
    default_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    default_response.body.should eq("Unauthorized")
  end

  it "serves paged outbox OrderedCollectionPage responses" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_outbox_dispatcher("/users/{identifier}/outbox", ->(ctx : Aptork::Context, identifier : String) do
      [
        Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "One"),
        Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/2", "Two"),
        Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/3", "Three"),
      ]
    end)

    response = federation.handle(activitypub_get("/users/alice/outbox", {"page" => "2", "size" => "2"}))

    response.status.should eq(200)
    page = JSON.parse(response.body).as_h
    page["type"].as_s.should eq("OrderedCollectionPage")
    page["orderedItems"].as_a.size.should eq(1)
    page["prev"].as_s.should eq("https://local.example/users/alice/outbox?page=1")
  end

  it "serves cursor-based outbox collections through a page dispatcher" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_outbox_page_dispatcher(
      "/users/{identifier}/outbox",
      ->(ctx : Aptork::Context, identifier : String, cursor : String?, size : Int32) do
        items = [
          Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/1", "One"),
          Aptork.note("#{ctx.get_actor_uri(identifier)}/notes/2", "Two"),
        ]
        if cursor == "missing"
          nil.as(Aptork::CollectionPageResult?)
        elsif cursor
          Aptork::CollectionPageResult.new(items[0, size], nil, "start", 2, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 2, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )

    collection_response = federation.handle(activitypub_get("/users/alice/outbox"))
    page_response = federation.handle(activitypub_get("/users/alice/outbox", {"cursor" => "start", "size" => "1"}))
    missing_response = federation.handle(activitypub_get("/users/alice/outbox", {"cursor" => "missing"}))

    collection = JSON.parse(collection_response.body).as_h
    page = JSON.parse(page_response.body).as_h

    collection["type"].as_s.should eq("OrderedCollection")
    collection["first"].as_s.should eq("https://local.example/users/alice/outbox?cursor=start&size=20")
    page["type"].as_s.should eq("OrderedCollectionPage")
    page["orderedItems"].as_a.size.should eq(1)
    page["prev"].as_s.should eq("https://local.example/users/alice/outbox?cursor=start&size=1")
    missing_response.status.should eq(404)
    missing_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    missing_response.body.should eq("Not Found")
  end

  it "serves cursor-based built-in actor collections beyond followers" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_following_dispatcher(
      "/users/{identifier}/following",
      ->(_ctx : Aptork::Context, identifier : String, cursor : String?, size : Int32) do
        items = [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          Aptork.actor("Person", "https://remote.example/users/cara", "cara", "https://remote.example/users/cara/inbox", "https://remote.example/users/cara/outbox"),
        ]
        if cursor
          Aptork::CollectionPageResult.new(items[0, size], nil, "start", 2, "start", nil)
        else
          identifier.should eq("alice")
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 2, "start", nil)
        end
      end
    )
    federation.set_liked_dispatcher(
      "/users/{identifier}/liked",
      ->(ctx : Aptork::Context, params : Hash(String, String), cursor : String?, _size : Int32) do
        if cursor
          Aptork::CollectionPageResult.new([Aptork.note("#{ctx.get_liked_uri(params["identifier"])}/1", "Liked")], nil, nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )
    federation.set_featured_dispatcher(
      "/users/{identifier}/featured",
      ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, _size : Int32) do
        if cursor
          Aptork::CollectionPageResult.new([Aptork.note("https://local.example/featured/1", "Pinned")], nil, nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )
    federation.set_featured_tags_dispatcher(
      "/users/{identifier}/tags",
      ->(_ctx : Aptork::Context, _identifier : String, cursor : String?, _size : Int32) do
        if cursor
          Aptork::CollectionPageResult.new([Aptork.object("Hashtag", "https://local.example/tags/crystal", Aptork::JsonMap{"name" => Aptork.json("crystal")})], nil, nil, 1, "start", nil)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 1, "start", nil)
        end
      end
    )
    ctx = federation.create_context

    following_collection = JSON.parse(federation.handle(activitypub_get("/users/alice/following")).body).as_h
    following_page = JSON.parse(federation.handle(activitypub_get("/users/alice/following", {"cursor" => "start", "size" => "1"})).body).as_h
    liked_page = JSON.parse(federation.handle(activitypub_get("/users/alice/liked", {"cursor" => "start"})).body).as_h
    featured_page = JSON.parse(federation.handle(activitypub_get("/users/alice/featured", {"cursor" => "start"})).body).as_h
    tags_page = JSON.parse(federation.handle(activitypub_get("/users/alice/tags", {"cursor" => "start"})).body).as_h

    following_collection["type"].as_s.should eq("OrderedCollection")
    following_collection["first"].as_s.should eq("https://local.example/users/alice/following?cursor=start&size=20")
    following_page["orderedItems"].as_a.size.should eq(1)
    following_page["orderedItems"].as_a.first.as_h["id"].as_s.should eq("https://remote.example/users/bob")
    liked_page["orderedItems"].as_a.first.as_h["content"].as_s.should eq("Liked")
    featured_page["orderedItems"].as_a.first.as_h["content"].as_s.should eq("Pinned")
    tags_page["orderedItems"].as_a.first.as_h["name"].as_s.should eq("crystal")
    ctx.get_following_uri("alice").should eq("https://local.example/users/alice/following")
    ctx.get_liked_uri("alice").should eq("https://local.example/users/alice/liked")
    ctx.get_featured_uri("alice").should eq("https://local.example/users/alice/featured")
    ctx.get_featured_tags_uri("alice").should eq("https://local.example/users/alice/tags")
  end

  it "serves Fedify-style actor and custom collections" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_followers_dispatcher("/users/{identifier}/followers", ->(_ctx : Aptork::Context, _identifier : String) do
      [
        Aptork.actor(
          "Person",
          "https://remote.example/users/bob",
          "bob",
          "https://remote.example/users/bob/inbox",
          "https://remote.example/users/bob/outbox"
        ),
        Aptork.actor(
          "Person",
          "https://other.example/users/cara",
          "cara",
          "https://other.example/users/cara/inbox",
          "https://other.example/users/cara/outbox"
        ),
      ]
    end)
    federation.set_following_dispatcher("/users/{identifier}/following", ->(_ctx : Aptork::Context, _identifier : String) do
      [] of Aptork::JsonMap
    end)
    federation.set_inbox_dispatcher("/users/{identifier}/inbox", ->(ctx : Aptork::Context, identifier : String) do
      [
        Aptork.create(
          "#{ctx.get_actor_uri(identifier)}/inbox/activities/1",
          "https://remote.example/users/bob",
          Aptork.note("https://remote.example/notes/1", "Hi")
        ),
      ]
    end)
    federation.set_liked_dispatcher("/users/{identifier}/liked", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_liked_uri(identifier)}/1", "Liked")]
    end)
    federation.set_featured_dispatcher("/users/{identifier}/featured", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_featured_uri(identifier)}/1", "Pinned")]
    end)
    federation.set_featured_tags_dispatcher("/users/{identifier}/tags", ->(_ctx : Aptork::Context, _identifier : String) do
      [Aptork.object("Hashtag", "https://local.example/tags/crystal", Aptork::JsonMap{"name" => Aptork.json("crystal")})]
    end)
    federation.set_ordered_collection_dispatcher("featured", "/users/{identifier}/collections/featured", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_actor_uri(identifier)}/featured/1", "Pinned")]
    end)
    federation.set_collection_dispatcher("bookmarks", "/users/{identifier}/collections/bookmarks", ->(ctx : Aptork::Context, identifier : String) do
      [Aptork.note("#{ctx.get_collection_uri("bookmarks", identifier)}/1", "Bookmarked")]
    end)
    federation.set_collection_dispatcher("repo-tags", "/repos/{owner}/{repo}/tags", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      [Aptork.object("Hashtag", "#{ctx.get_collection_uri("repo-tags", params)}/crystal", Aptork::JsonMap{"name" => Aptork.json("#{params["owner"]}/#{params["repo"]}")})]
    end)
    ctx = federation.create_context

    followers = federation.handle(activitypub_get("/users/alice/followers"))
    filtered_followers = federation.handle(activitypub_get("/users/alice/followers", {"base-url" => "https://remote.example/anything", "page" => "1"}))
    following = federation.handle(activitypub_get("/users/alice/following"))
    inbox_page = federation.handle(activitypub_get("/users/alice/inbox", {"page" => "1", "size" => "1"}))
    liked = federation.handle(activitypub_get("/users/alice/liked", {"page" => "1"}))
    fedify_featured = federation.handle(activitypub_get("/users/alice/featured", {"page" => "1"}))
    featured_tags = federation.handle(activitypub_get("/users/alice/tags", {"page" => "1"}))
    featured = federation.handle(activitypub_get("/users/alice/collections/featured"))
    bookmarks = federation.handle(activitypub_get("/users/alice/collections/bookmarks", {"page" => "1"}))
    repo_tags = federation.handle(activitypub_get("/repos/acme/aptork/tags", {"page" => "1"}))

    parsed_followers = JSON.parse(followers.body).as_h
    parsed_filtered_followers = JSON.parse(filtered_followers.body).as_h
    parsed_following = JSON.parse(following.body).as_h
    parsed_inbox_page = JSON.parse(inbox_page.body).as_h
    parsed_liked = JSON.parse(liked.body).as_h
    parsed_fedify_featured = JSON.parse(fedify_featured.body).as_h
    parsed_featured_tags = JSON.parse(featured_tags.body).as_h
    parsed_featured = JSON.parse(featured.body).as_h
    parsed_bookmarks = JSON.parse(bookmarks.body).as_h
    parsed_repo_tags = JSON.parse(repo_tags.body).as_h

    followers.status.should eq(200)
    parsed_followers["type"].as_s.should eq("OrderedCollection")
    parsed_followers["totalItems"].as_i.should eq(2)
    parsed_filtered_followers["type"].as_s.should eq("OrderedCollectionPage")
    parsed_filtered_followers["orderedItems"].as_a.size.should eq(1)
    parsed_filtered_followers["orderedItems"].as_a.first.as_h["id"].as_s.should eq("https://remote.example/users/bob")
    parsed_following["totalItems"].as_i.should eq(0)
    parsed_inbox_page["type"].as_s.should eq("OrderedCollectionPage")
    parsed_inbox_page["orderedItems"].as_a.first.as_h["type"].as_s.should eq("Create")
    parsed_liked["orderedItems"].as_a.first.as_h["content"].as_s.should eq("Liked")
    parsed_fedify_featured["orderedItems"].as_a.first.as_h["content"].as_s.should eq("Pinned")
    parsed_featured_tags["orderedItems"].as_a.first.as_h["type"].as_s.should eq("Hashtag")
    parsed_featured["first"].as_s.should eq("https://local.example/users/alice/collections/featured?page=1")
    parsed_bookmarks["type"].as_s.should eq("CollectionPage")
    parsed_bookmarks["items"].as_a.first.as_h["content"].as_s.should eq("Bookmarked")
    parsed_repo_tags["items"].as_a.first.as_h["name"].as_s.should eq("acme/aptork")
    ctx.get_collection_uri("bookmarks", "alice").should eq("https://local.example/users/alice/collections/bookmarks")
    ctx.get_collection_uri("repo-tags", {"owner" => "acme", "repo" => "aptork"}).should eq("https://local.example/repos/acme/aptork/tags")
    ctx.collection("repo-tags", {"owner" => "acme", "repo" => "aptork"}).first["name"].as_s.should eq("acme/aptork")
    ctx.parse_uri(ctx.get_liked_uri("alice")).try(&.collection_name).should eq("liked")
    ctx.parse_uri(ctx.get_featured_uri("alice")).try(&.collection_name).should eq("featured")
    ctx.parse_uri(ctx.get_featured_tags_uri("alice")).try(&.collection_name).should eq("featured_tags")
  end

  it "serves multi-parameter cursor custom collections" do
    dispatched_owners = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.set_collection_page_dispatcher(
      "stars",
      "/repos/{owner}/{repo}/stars",
      ->(ctx : Aptork::Context, params : Hash(String, String), cursor : String?, size : Int32) do
        dispatched_owners << params["owner"]
        items = [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          Aptork.actor("Person", "https://remote.example/users/cara", "cara", "https://remote.example/users/cara/inbox", "https://remote.example/users/cara/outbox"),
        ]
        if cursor == "missing"
          nil.as(Aptork::CollectionPageResult?)
        elsif cursor
          Aptork::CollectionPageResult.new(items[0, size], "next", nil, 2, "start", "next").as(Aptork::CollectionPageResult?)
        else
          params["repo"].should eq("aptork")
          if params["owner"] == "acme"
            ctx.get_collection_uri("stars", params).should eq("https://local.example/repos/acme/aptork/stars")
          end
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "fallback", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )
    federation.configure_collection("stars")
      .item_type("Person")
      .set_first_cursor(->(_ctx : Aptork::Context, params : Hash(String, String)) do
        params["owner"] == "acme" ? "start" : nil
      end)
      .set_last_cursor(->(_ctx : Aptork::Context, _params : Hash(String, String)) do
        "end".as(String?)
      end)
      .set_counter(->(_ctx : Aptork::Context, _params : Hash(String, String)) do
        2.as(Int32?)
      end)
      .authorize(->(_ctx : Aptork::Context, _request : Aptork::Request, _verification : Aptork::VerificationResult, _identifier : String?, params : Hash(String, String)) do
        params["owner"]? == "acme"
      end)
    federation.set_ordered_collection_page_dispatcher(
      "updates",
      "/repos/{owner}/{repo}/updates",
      ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, _size : Int32) do
        if cursor
          Aptork::CollectionPageResult.new([Aptork.note("https://local.example/updates/1", "Updated")], nil, nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 1, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )
    ctx = federation.create_context

    collection = federation.handle(activitypub_get("/repos/acme/aptork/stars"))
    page = federation.handle(activitypub_get("/repos/acme/aptork/stars", {"cursor" => "start", "size" => "1"}))
    missing_page = federation.handle(activitypub_get("/repos/acme/aptork/stars", {"cursor" => "missing"}))
    ordered_page = federation.handle(activitypub_get("/repos/acme/aptork/updates", {"cursor" => "start"}))
    denied = federation.handle(activitypub_get("/repos/evil/aptork/stars"))
    parsed = ctx.parse_uri("https://local.example/repos/acme/aptork/stars").not_nil!

    parsed.collection_name.should eq("stars")
    parsed.values.should eq({"owner" => "acme", "repo" => "aptork"})
    collection_json = JSON.parse(collection.body).as_h
    page_json = JSON.parse(page.body).as_h
    collection_json["type"].as_s.should eq("Collection")
    collection_json["totalItems"].as_i.should eq(2)
    collection_json["first"].as_s.should eq("https://local.example/repos/acme/aptork/stars?cursor=start&size=20")
    collection_json["last"].as_s.should eq("https://local.example/repos/acme/aptork/stars?cursor=end&size=20")
    collection_json["itemType"].as_s.should eq("Person")
    page_json["type"].as_s.should eq("CollectionPage")
    page_json["items"].as_a.size.should eq(1)
    page_json["itemType"].as_s.should eq("Person")
    missing_page.status.should eq(404)
    missing_page.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    missing_page.body.should eq("Not Found")
    JSON.parse(ordered_page.body).as_h["type"].as_s.should eq("OrderedCollectionPage")
    JSON.parse(ordered_page.body).as_h["orderedItems"].as_a.first.as_h["content"].as_s.should eq("Updated")
    denied.status.should eq(401)
    dispatched_owners.should contain("evil")
  end

  it "preserves query parameters on cursor collection links" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_collection_page_dispatcher(
      "stars",
      "/repos/{owner}/{repo}/stars",
      ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, size : Int32) do
        items = [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
        ]
        if cursor
          Aptork::CollectionPageResult.new(items[0, size], "next", "prev", 1, "start", "end").as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 1, "start", "end").as(Aptork::CollectionPageResult?)
        end
      end
    )

    collection = federation.handle(activitypub_get("/repos/acme/aptork/stars", {"view" => "remote"}))
    page = federation.handle(activitypub_get("/repos/acme/aptork/stars", {"view" => "remote", "cursor" => "start", "size" => "1"}))

    collection_json = JSON.parse(collection.body).as_h
    page_json = JSON.parse(page.body).as_h
    collection_json["id"].as_s.should eq("https://local.example/repos/acme/aptork/stars")
    collection_json["first"].as_s.should eq("https://local.example/repos/acme/aptork/stars?view=remote&cursor=start&size=20")
    collection_json["last"].as_s.should eq("https://local.example/repos/acme/aptork/stars?view=remote&cursor=end&size=20")
    page_json["id"].as_s.should eq("https://local.example/repos/acme/aptork/stars?cursor=start&size=1")
    page_json["partOf"].as_s.should eq("https://local.example/repos/acme/aptork/stars?view=remote&size=1")
    page_json["next"].as_s.should eq("https://local.example/repos/acme/aptork/stars?view=remote&cursor=next&size=1")
    page_json["prev"].as_s.should eq("https://local.example/repos/acme/aptork/stars?view=remote&cursor=prev&size=1")
  end

  it "filters custom collection items with Fedify-style predicates" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_collection_dispatcher(
      "stars",
      "/repos/{owner}/{repo}/stars",
      ->(_ctx : Aptork::Context, _params : Hash(String, String)) do
        [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          Aptork.actor("Person", "https://local.example/users/alice", "alice", "https://local.example/users/alice/inbox", "https://local.example/users/alice/outbox"),
        ]
      end
    )
    federation.configure_collection("stars")
      .set_counter(->(_ctx : Aptork::Context, params : Hash(String, String)) do
        params["owner"] == "acme" ? 10.as(Int32?) : nil
      end)
      .filter(->(_ctx : Aptork::Context, item : Aptork::JsonMap) do
        item["id"].as_s.starts_with?("https://remote.example/")
      end)
    ctx = federation.create_context

    collection = federation.handle(activitypub_get("/repos/acme/aptork/stars"))
    response = federation.handle(activitypub_get("/repos/acme/aptork/stars", {"page" => "1"}))
    direct_items = ctx.collection("stars", {"owner" => "acme", "repo" => "aptork"})

    collection_json = JSON.parse(collection.body).as_h
    json = JSON.parse(response.body).as_h
    items = json["items"].as_a
    collection_json["type"].as_s.should eq("Collection")
    collection_json["totalItems"].as_i.should eq(10)
    collection_json["items"].as_a.size.should eq(0)
    json["type"].as_s.should eq("CollectionPage")
    items.size.should eq(1)
    items.first.as_h["id"].as_s.should eq("https://remote.example/users/bob")
    direct_items.size.should eq(1)
    direct_items.first["id"].as_s.should eq("https://remote.example/users/bob")
  end

  it "preserves cursor collection totals when filtering page items" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_collection_page_dispatcher(
      "stars",
      "/repos/{owner}/{repo}/stars",
      ->(_ctx : Aptork::Context, _params : Hash(String, String), cursor : String?, _size : Int32) do
        items = [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          Aptork.actor("Person", "https://other.example/users/cara", "cara", "https://other.example/users/cara/inbox", "https://other.example/users/cara/outbox"),
        ]
        if cursor
          Aptork::CollectionPageResult.new(items, nil, nil, 2, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, 2, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )
    federation.configure_collection("stars")
      .filter(->(_ctx : Aptork::Context, item : Aptork::JsonMap) do
        item["id"].as_s.starts_with?("https://remote.example/")
      end)

    collection = federation.handle(activitypub_get("/repos/acme/aptork/stars"))
    collection_json = JSON.parse(collection.body).as_h

    collection_json["totalItems"].as_i.should eq(2)
  end

  it "passes normalized followers base-url filters to cursor dispatchers" do
    seen_filters = [] of String?
    federation = Aptork::Federation.create("https://local.example")
    federation.set_followers_dispatcher(
      "/users/{identifier}/followers",
      ->(_ctx : Aptork::Context, identifier : String, cursor : String?, _size : Int32, base_url : String?) do
        identifier.should eq("alice")
        seen_filters << base_url
        items = [
          Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox"),
          Aptork.actor("Person", "https://other.example/users/cara", "cara", "https://other.example/users/cara/inbox", "https://other.example/users/cara/outbox"),
        ]
        filtered = base_url ? items.select { |item| item["id"].as_s.starts_with?(base_url) } : items
        if cursor
          Aptork::CollectionPageResult.new(filtered, nil, "start", filtered.size, "start", nil).as(Aptork::CollectionPageResult?)
        else
          Aptork::CollectionPageResult.new([] of Aptork::JsonMap, "start", nil, filtered.size, "start", nil).as(Aptork::CollectionPageResult?)
        end
      end
    )

    collection = federation.handle(activitypub_get("/users/alice/followers", {"base-url" => "https://remote.example/users/bob", "size" => "10"}))
    page = federation.handle(activitypub_get("/users/alice/followers", {"base-url" => "https://remote.example/users/bob", "cursor" => "start", "size" => "10"}))
    invalid = federation.handle(activitypub_get("/users/alice/followers", {"base-url" => "not a url", "cursor" => "start", "size" => "10"}))

    collection_json = JSON.parse(collection.body).as_h
    page_json = JSON.parse(page.body).as_h
    invalid_json = JSON.parse(invalid.body).as_h

    seen_filters.should eq(["https://remote.example/", "https://remote.example/", nil])
    collection_json["totalItems"].as_i.should eq(1)
    page_json["orderedItems"].as_a.size.should eq(1)
    page_json["orderedItems"].as_a.first.as_h["id"].as_s.should eq("https://remote.example/users/bob")
    invalid_json["orderedItems"].as_a.size.should eq(2)
  end

  it "maps fixed actor alias paths to actor identifiers" do
    seen_identifiers = [] of String
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      seen_identifiers << identifier
      Aptork.actor(
        "Service",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.map_actor_alias("/bot", "bot")
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "bot" ? "bot" : nil
    end)
    ctx = federation.create_context

    alias_response = federation.handle(Aptork::Request.new(
      "GET",
      "/bot",
      headers: {"Accept" => "application/activity+json"}
    ))
    normal_response = federation.handle(Aptork::Request.new(
      "GET",
      "/users/alice",
      headers: {"Accept" => "application/activity+json"}
    ))
    webfinger_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:bot@local.example"}
    ))
    parsed = ctx.parse_uri("https://local.example/bot").not_nil!

    ctx.get_actor_uri("bot").should eq("https://local.example/bot")
    alias_response.status.should eq(200)
    JSON.parse(alias_response.body).as_h["id"].as_s.should eq("https://local.example/bot")
    normal_response.status.should eq(200)
    JSON.parse(normal_response.body).as_h["id"].as_s.should eq("https://local.example/users/alice")
    JSON.parse(webfinger_response.body).as_h["links"].as_a.map(&.as_h).find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://local.example/bot")
    parsed.type.should eq("actor")
    parsed.identifier.should eq("bot")
    seen_identifiers.should contain("bot")
    seen_identifiers.should contain("alice")
  end

  it "validates fixed actor alias paths" do
    federation = Aptork::Federation.create("https://local.example")

    expect_raises(ArgumentError, "actor alias path must not contain URI template variables") do
      federation.map_actor_alias("/users/{identifier}", "bot")
    end
    expect_raises(ArgumentError, "actor alias identifier must not be empty") do
      federation.map_actor_alias("/bot", "")
    end
    federation.map_actor_alias("/bot", "bot")
    expect_raises(ArgumentError, "actor alias path is already registered: /bot") do
      federation.map_actor_alias("/bot", "other")
    end
    expect_raises(ArgumentError, "actor alias identifier is already registered: bot") do
      federation.map_actor_alias("/other", "bot")
    end
  end

  it "supports custom WebFinger and NodeInfo dispatchers" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_webfinger_dispatcher(->(_ctx : Aptork::Context, resource : String, identifier : String) do
      Aptork.webfinger_jrd(
        resource,
        "https://local.example/@#{identifier}",
        properties: Aptork::JsonMap{
          "https://example.com/ns#role" => Aptork.json("maintainer"),
        },
        links: [
          Aptork::JsonMap{
            "rel"  => Aptork.json("http://webfinger.net/rel/profile-page"),
            "href" => Aptork.json("https://local.example/profile/#{identifier}"),
          },
        ]
      ).as(Aptork::JsonMap?)
    end)
    federation.set_nodeinfo_dispatcher("/nodeinfo/custom", ->(_ctx : Aptork::Context) do
      Aptork.nodeinfo(
        "custom-app",
        "1.2.3",
        metadata: Aptork::JsonMap{
          "nodeName" => Aptork.json("Custom"),
        }
      )
    end)

    webfinger = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@local.example"}
    ))
    wrong_host = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@elsewhere.example"}
    ))
    nodeinfo_well_known = federation.handle(Aptork::Request.new("GET", "/.well-known/nodeinfo"))
    nodeinfo = federation.handle(Aptork::Request.new("GET", "/nodeinfo/custom"))

    webfinger.status.should eq(200)
    webfinger.headers["Access-Control-Allow-Origin"].should eq("*")
    parsed_webfinger = JSON.parse(webfinger.body).as_h
    parsed_webfinger["properties"].as_h["https://example.com/ns#role"].as_s.should eq("maintainer")
    parsed_webfinger["links"].as_a.size.should eq(2)
    wrong_host.status.should eq(404)
    JSON.parse(nodeinfo_well_known.body).as_h["links"].as_a.first.as_h["href"].as_s.should eq("https://local.example/nodeinfo/custom")
    JSON.parse(nodeinfo_well_known.body).as_h["links"].as_a.first.as_h["type"].as_s.should eq(Aptork::NODEINFO_2_1_CONTENT_TYPE)
    nodeinfo.headers["Content-Type"].should eq(Aptork::NODEINFO_2_1_CONTENT_TYPE)
    JSON.parse(nodeinfo.body).as_h["software"].as_h["name"].as_s.should eq("custom-app")
    JSON.parse(nodeinfo.body).as_h["metadata"].as_h["nodeName"].as_s.should eq("Custom")
  end

  it "maps WebFinger handles and aliases to actor identifiers and appends actor links" do
    federation = Aptork::Federation.create("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      return nil unless identifier == "user-123"

      actor = Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        "alice",
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      )
      actor["url"] = Aptork.json([
        "https://local.example/@alice",
        {
          "rel"       => "alternate",
          "href"      => "https://local.example/@alice.atom",
          "mediaType" => "application/atom+xml",
        },
      ])
      actor["icon"] = Aptork.json({
        "url"       => "https://local.example/media/alice.png",
        "mediaType" => "image/png",
      })
      actor.as(Aptork::JsonMap?)
    end)
    federation.map_handle(->(_ctx : Aptork::Context, username : String) do
      username == "alice" ? "user-123" : nil
    end)
    federation.map_alias(->(_ctx : Aptork::Context, resource : String) do
      case resource
      when "https://local.example/@alice"
        "user-123"
      when "https://local.example/@alice-by-username"
        {username: "alice"}
      else
        nil
      end
    end)
    federation.set_webfinger_links_dispatcher(->(_ctx : Aptork::Context, resource : String) do
      [
        Aptork::JsonMap{
          "rel"      => Aptork.json("http://ostatus.org/schema/1.0/subscribe"),
          "template" => Aptork.json("https://local.example/authorize_interaction?uri={uri}&resource=#{resource.gsub(":", "%3A").gsub("@", "%40")}"),
        },
      ]
    end)

    handle_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@local.example"}
    ))
    alias_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "https://local.example/@alice"}
    ))
    username_alias_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "https://local.example/@alice-by-username"}
    ))
    missing_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:unknown@local.example"}
    ))

    handle_response.status.should eq(200)
    handle_json = JSON.parse(handle_response.body).as_h
    handle_json["subject"].as_s.should eq("acct:alice@local.example")
    handle_json["aliases"].as_a.first.as_s.should eq("https://local.example/users/user-123")
    links = handle_json["links"].as_a.map(&.as_h)
    links.find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://local.example/users/user-123")
    profile_link = links.find { |link| link["rel"].as_s == "http://webfinger.net/rel/profile-page" }.not_nil!
    profile_link["href"].as_s.should eq("https://local.example/@alice")
    profile_link.has_key?("type").should be_false
    links.find { |link| link["rel"].as_s == "alternate" }.not_nil!["type"].as_s.should eq("application/atom+xml")
    links.find { |link| link["rel"].as_s == "http://webfinger.net/rel/avatar" }.not_nil!["href"].as_s.should eq("https://local.example/media/alice.png")
    links.find { |link| link["rel"].as_s == "http://ostatus.org/schema/1.0/subscribe" }.not_nil!["template"].as_s.should contain("resource=acct%3Aalice%40local.example")
    JSON.parse(alias_response.body).as_h["subject"].as_s.should eq("https://local.example/@alice")
    JSON.parse(username_alias_response.body).as_h["links"].as_a.map(&.as_h).find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://local.example/users/user-123")
    missing_response.status.should eq(404)
  end

  it "resolves WebFinger actor URL resources and preserves origin ports in acct subjects" do
    federation = Aptork::Federation.create("https://localhost:8000")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.map_alias(->(_ctx : Aptork::Context, resource : String) do
      resource == "mailto:alice@localhost" ? "alice" : nil
    end)

    actor_url_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "https://localhost:8000/users/alice"}
    ))
    acct_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@localhost:8000"}
    ))
    wrong_port_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice@localhost:9000"}
    ))
    malformed_acct_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "acct:alice"}
    ))
    missing_resource_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger"
    ))
    invalid_resource_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => " invalid "}
    ))
    malformed_url_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "https://"}
    ))
    alias_uri_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/webfinger",
      query: {"resource" => "mailto:alice@localhost"}
    ))

    actor_url_response.status.should eq(200)
    actor_url_json = JSON.parse(actor_url_response.body).as_h
    actor_url_json["subject"].as_s.should eq("https://localhost:8000/users/alice")
    actor_url_json["aliases"].as_a.map(&.as_s).should contain("acct:alice@localhost:8000")
    actor_url_links = actor_url_json["links"].as_a.map(&.as_h)
    actor_url_links.find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://localhost:8000/users/alice")
    JSON.parse(acct_response.body).as_h["subject"].as_s.should eq("acct:alice@localhost:8000")
    wrong_port_response.status.should eq(404)
    malformed_acct_response.status.should eq(404)
    missing_resource_response.status.should eq(400)
    missing_resource_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    missing_resource_response.body.should eq("Missing resource parameter.")
    invalid_resource_response.status.should eq(400)
    invalid_resource_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    invalid_resource_response.body.should eq("Invalid resource URL.")
    malformed_url_response.status.should eq(400)
    malformed_url_response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    malformed_url_response.body.should eq("Invalid resource URL.")
    alias_uri_json = JSON.parse(alias_uri_response.body).as_h
    alias_uri_json["subject"].as_s.should eq("mailto:alice@localhost")
    alias_uri_json["links"].as_a.map(&.as_h).find { |link| link["rel"].as_s == "self" }.not_nil!["href"].as_s.should eq("https://localhost:8000/users/alice")
  end

  it "rejects inbox POSTs when the verifier fails" do
    received = false
    unverified = false
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_verifier(->(_request : Aptork::Request, _activity : Aptork::JsonMap) do
      Aptork::VerificationResult.new(false, "bad signature", "key-1")
    end)
    federation.on_unverified_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap, result : Aptork::VerificationResult) do
      unverified = result.key_id == "key-1"
      nil.as(Aptork::Response?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        received = true
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(401)
    response.body.should eq("bad signature")
    received.should be_false
    unverified.should be_true
  end

  it "allows inbox unverified handlers to return custom responses" do
    received = false
    handled_reason = ""
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_verifier(->(_request : Aptork::Request, _activity : Aptork::JsonMap) do
      Aptork::VerificationResult.new(false, "moderated")
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        received = true
        nil
      end)
      .on_unverified_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap, result : Aptork::VerificationResult) do
        handled_reason = result.reason || ""
        Aptork::Response.new(202, {"Content-Type" => "text/plain"}, "quarantined").as(Aptork::Response?)
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(202)
    response.body.should eq("quarantined")
    handled_reason.should eq("moderated")
    received.should be_false
  end

  it "keeps default unverified responses when chained handlers return nil" do
    unverified = false
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_verifier(->(_request : Aptork::Request, _activity : Aptork::JsonMap) do
      Aptork::VerificationResult.new(false, "bad signature")
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on_unverified_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap, _result : Aptork::VerificationResult) do
        unverified = true
        nil.as(Aptork::Response?)
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(401)
    response.body.should eq("bad signature")
    unverified.should be_true
  end

  it "verifies inbox HTTP signatures with a signature key resolver" do
    received = false
    unverified = false
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    captured_headers = Hash(String, String).new
    captured_body = ""
    signing_transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, body : String) do
        captured_headers["Signature"] = headers["Signature"]
        captured_headers["Digest"] = headers["Digest"]
        captured_headers["Date"] = headers["Date"]
        captured_headers["Host"] = headers["Host"]
        captured_headers["Content-Type"] = headers["Content-Type"]
        captured_body = body
        {202, "ok"}
      end
    )
    activity = Aptork.create(
      "https://remote.example/activities/1",
      remote_key.owner,
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    signing_transport.deliver!(
      Aptork::DeliveryConfig.new("https://local.example/inbox", remote_key.owner, nil),
      activity,
      remote_key
    )

    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    federation.on_unverified_activity(->(_ctx : Aptork::Context, _activity : Aptork::JsonMap, _result : Aptork::VerificationResult) do
      unverified = true
      nil.as(Aptork::Response?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        received = true
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      headers: captured_headers,
      body: captured_body
    ))

    response.status.should eq(202)
    received.should be_true
    unverified.should be_false
  end

  it "rejects inbox POSTs when resolver-backed signature verification fails" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    captured_headers = Hash(String, String).new
    signing_transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, _body : String) do
        captured_headers["Signature"] = headers["Signature"]
        captured_headers["Digest"] = headers["Digest"]
        captured_headers["Date"] = headers["Date"]
        captured_headers["Host"] = headers["Host"]
        {202, "ok"}
      end
    )
    activity = Aptork.create(
      "https://remote.example/activities/1",
      remote_key.owner,
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    signing_transport.deliver!(
      Aptork::DeliveryConfig.new("https://local.example/inbox", remote_key.owner, nil),
      activity,
      remote_key
    )

    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      headers: captured_headers,
      body: activity.merge({"content" => Aptork.json("tampered")}).to_json
    ))

    response.status.should eq(401)
    response.body.should eq("invalid digest")
  end

  it "rejects inbox POSTs when the signature key owner does not match the activity actor" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    captured_headers = Hash(String, String).new
    captured_body = ""
    signing_transport = Aptork::Transport.new(
      signature_enabled: false,
      post_provider: ->(_url : String, headers : HTTP::Headers, body : String) do
        captured_headers["Signature"] = headers["Signature"]
        captured_headers["Digest"] = headers["Digest"]
        captured_headers["Date"] = headers["Date"]
        captured_headers["Host"] = headers["Host"]
        captured_body = body
        {202, "ok"}
      end
    )
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/mallory",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    signing_transport.deliver!(
      Aptork::DeliveryConfig.new("https://local.example/inbox", remote_key.owner, nil),
      activity,
      remote_key
    )

    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key.as(Aptork::ActorKeyPair?) : nil
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      headers: captured_headers,
      body: captured_body
    ))

    response.status.should eq(401)
    response.body.should eq("signature key owner does not match activity actor")
  end

  it "rejects unsigned inbox POSTs when signature verification is enabled" do
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(_key_id : String) do
      nil.as(Aptork::ActorKeyPair?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(401)
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.body.should eq("missing signature")
  end

  it "emits Accept-Signature challenges for signature verification failures" do
    federation = Aptork::Federation.create("https://local.example", kv: Aptork::MemoryKvStore.new)
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(_key_id : String) do
      nil.as(Aptork::ActorKeyPair?)
    end)
    federation.enable_inbox_signature_verification(Aptork::InboxSignatureOptions.new(
      challenge_policy: Aptork::InboxChallengePolicy.new(enabled: true, tag: "activitypub")
    ))
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: Aptork.create(
        "https://remote.example/activities/1",
        "https://remote.example/users/bob",
        Aptork.note("https://remote.example/notes/1", "Hi")
      ).to_json
    ))

    response.status.should eq(401)
    response.body.should eq("Failed to verify the request signature.")
    response.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    response.headers["Accept-Signature"].should eq(%(sig1=("@method" "@target-uri" "@authority" "content-digest");alg="rsa-v1_5-sha256";tag="activitypub"))
    response.headers["Cache-Control"].should eq("no-store")
    response.headers["Vary"].should eq("Accept, Signature")
  end

  it "emits and consumes Accept-Signature nonces" do
    store = Aptork::MemoryKvStore.new
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example", kv: store)
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key : nil.as(Aptork::ActorKeyPair?)
    end)
    federation.enable_inbox_signature_verification(Aptork::InboxSignatureOptions.new(
      challenge_policy: Aptork::InboxChallengePolicy.new(enabled: true, request_nonce: true)
    ))
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      remote_key.owner,
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    challenge = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      body: activity.to_json
    ))
    accept_signature = challenge.headers["Accept-Signature"]
    nonce = accept_signature.match(/nonce="([^"]+)"/).not_nil![1]
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://local.example/inbox",
      activity.to_json,
      remote_key,
      Aptork::Rfc9421Options.new(key_id: remote_key.id, nonce: nonce)
    )

    accepted = federation.handle(Aptork::Request.new("POST", "/inbox", headers: headers, body: activity.to_json))
    replay = federation.handle(Aptork::Request.new("POST", "/inbox", headers: headers, body: activity.to_json))

    challenge.status.should eq(401)
    challenge.body.should eq("Failed to verify the request signature.")
    challenge.headers["Content-Type"].should eq(Aptork::FEDIFY_TEXT_CONTENT_TYPE)
    challenge.headers["Cache-Control"].should eq("no-store")
    challenge.headers["Vary"].should eq("Accept, Signature")
    accept_signature.should contain("nonce=\"")
    accepted.status.should eq(202)
    replay.status.should eq(401)
    replay.body.should eq("Failed to verify the request signature.")
    replay.headers["Cache-Control"].should eq("no-store")
  end

  it "does not challenge actor key-owner mismatch failures" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key : nil.as(Aptork::ActorKeyPair?)
    end)
    federation.enable_inbox_signature_verification(Aptork::InboxSignatureOptions.new(
      challenge_policy: Aptork::InboxChallengePolicy.new(enabled: true)
    ))
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/eve",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://local.example/inbox",
      activity.to_json,
      remote_key
    )

    response = federation.handle(Aptork::Request.new("POST", "/inbox", headers: headers, body: activity.to_json))

    response.status.should eq(401)
    response.body.should eq("signature key owner does not match activity actor")
    response.headers["Accept-Signature"]?.should be_nil
  end
end

describe "Aptork vocabulary helpers" do
  it "parses ActivityStreams JSON-LD into typed vocabulary objects" do
    note = Aptork.note(
      "https://local.example/notes/1",
      "Hello from Crystal",
      attributed_to: "https://local.example/users/alice"
    )
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      note
    )

    parsed = Aptork::Vocab::Object.from_json_ld(activity)
    parsed.should be_a(Aptork::Vocab::Create)
    create = parsed.as(Aptork::Vocab::Create)
    create.id.should eq("https://local.example/activities/1")
    create.type.should eq("Create")
    create.actor.should eq("https://local.example/users/alice")
    create.object.should be_a(Aptork::Vocab::Note)

    parsed_note = create.object.as(Aptork::Vocab::Note)
    parsed_note.id.should eq("https://local.example/notes/1")
    parsed_note.content.should eq("Hello from Crystal")
    parsed_note.to_json_ld.should eq(note)
    JSON.parse(create.to_json).as_h["type"].as_s.should eq("Create")

    activity_subtype = Aptork::Vocab::Activity.from_json_ld(activity)
    activity_subtype.should be_a(Aptork::Vocab::Create)
  end

  it "parses common ActivityStreams activities into typed activity objects" do
    note = Aptork.note("https://local.example/notes/2", "A typed object")
    target = Aptork.object("Collection", "https://local.example/collections/featured")
    activity = Aptork.object("Announce", "https://local.example/activities/announce-1", Aptork::JsonMap{
      "actor"      => Aptork.json("https://local.example/users/alice"),
      "object"     => Aptork.json(note),
      "target"     => Aptork.json(target),
      "result"     => Aptork.json("https://local.example/activities/result"),
      "origin"     => Aptork.json("https://local.example/users/alice/outbox"),
      "instrument" => Aptork.json("https://local.example/apps/client"),
      "to"         => Aptork.json([Aptork::PUBLIC_COLLECTION]),
      "cc"         => Aptork.json(["https://local.example/users/alice/followers"]),
      "published"  => Aptork.json("2024-02-01T00:00:00Z"),
    })

    parsed = Aptork::Vocab::Object.from_json_ld(activity)
    parsed.should be_a(Aptork::Vocab::Announce)
    announce = parsed.as(Aptork::Vocab::Announce)
    announce.actor.should eq("https://local.example/users/alice")
    announce.object.should be_a(Aptork::Vocab::Note)
    announce.target.should be_a(Aptork::Vocab::Collection)
    announce.result.should eq("https://local.example/activities/result")
    announce.origin.should eq("https://local.example/users/alice/outbox")
    announce.instrument.should eq("https://local.example/apps/client")
    announce.to.should eq([Aptork::PUBLIC_COLLECTION])
    announce.cc.should eq(["https://local.example/users/alice/followers"])
    announce.published.should eq("2024-02-01T00:00:00Z")

    Aptork::Vocab::Object.from_json_ld(Aptork.object("Follow", "https://local.example/activities/follow-1", Aptork::JsonMap{
      "actor"  => Aptork.json("https://local.example/users/alice"),
      "object" => Aptork.json(Aptork.actor("Person", "https://remote.example/users/bob", "bob", "https://remote.example/users/bob/inbox", "https://remote.example/users/bob/outbox")),
    })).should be_a(Aptork::Vocab::Follow)
    Aptork::Vocab::Activity.from_json_ld(Aptork.activity("Like", "https://local.example/activities/like-1", "https://local.example/users/alice", note)).should be_a(Aptork::Vocab::Like)
    Aptork::Vocab::Object.from_json_ld(Aptork.activity("Undo", "https://local.example/activities/undo-1", "https://local.example/users/alice", activity)).should be_a(Aptork::Vocab::Undo)
    Aptork::Vocab::Object.from_json_ld(Aptork.activity("Update", "https://local.example/activities/update-1", "https://local.example/users/alice", note)).should be_a(Aptork::Vocab::Update)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Offer", "https://local.example/activities/offer-1")).should be_a(Aptork::Vocab::ActivityOffer)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("IntransitiveActivity", "https://local.example/activities/state-1")).should be_a(Aptork::Vocab::IntransitiveActivity)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Arrive", "https://local.example/activities/arrive-1")).should be_a(Aptork::Vocab::IntransitiveActivity)
    Aptork.type_lineage("Arrive").should eq(["Arrive", "IntransitiveActivity", "Activity"])
  end

  it "builds Fedify-style helpers for ActivityStreams activity types" do
    actor = "https://local.example/users/alice"
    note = Aptork.note("https://local.example/notes/builder", "Builder note")

    helpers = {
      "Accept"          => Aptork.accept("https://local.example/activities/accept", actor, "https://remote.example/activities/follow"),
      "Add"             => Aptork.add("https://local.example/activities/add", actor, note, target: "https://local.example/collections/featured"),
      "Announce"        => Aptork.announce("https://local.example/activities/announce", actor, note),
      "Block"           => Aptork.block("https://local.example/activities/block", actor, "https://remote.example/users/spam"),
      "Delete"          => Aptork.delete("https://local.example/activities/delete", actor, "https://local.example/notes/builder"),
      "Dislike"         => Aptork.dislike("https://local.example/activities/dislike", actor, note),
      "Flag"            => Aptork.flag("https://local.example/activities/flag", actor, "https://remote.example/notes/spam"),
      "Follow"          => Aptork.follow("https://local.example/activities/follow", actor, "https://remote.example/users/bob"),
      "Ignore"          => Aptork.ignore("https://local.example/activities/ignore", actor, "https://remote.example/users/noisy"),
      "Invite"          => Aptork.invite("https://local.example/activities/invite", actor, "https://remote.example/users/bob"),
      "Join"            => Aptork.join("https://local.example/activities/join", actor, "https://remote.example/groups/dev"),
      "Leave"           => Aptork.leave("https://local.example/activities/leave", actor, "https://remote.example/groups/dev"),
      "Like"            => Aptork.like("https://local.example/activities/like", actor, note),
      "Listen"          => Aptork.listen("https://local.example/activities/listen", actor, "https://remote.example/audio/1"),
      "Move"            => Aptork.move("https://local.example/activities/move", actor, "https://local.example/users/alice", target: "https://local.example/users/alice-new"),
      "Offer"           => Aptork.offer("https://local.example/activities/offer", actor, note),
      "Reject"          => Aptork.reject("https://local.example/activities/reject", actor, "https://remote.example/activities/follow"),
      "Read"            => Aptork.read("https://local.example/activities/read", actor, "https://remote.example/articles/1"),
      "Remove"          => Aptork.remove("https://local.example/activities/remove", actor, note, target: "https://local.example/collections/featured"),
      "TentativeAccept" => Aptork.tentative_accept("https://local.example/activities/tentative-accept", actor, "https://remote.example/events/1"),
      "TentativeReject" => Aptork.tentative_reject("https://local.example/activities/tentative-reject", actor, "https://remote.example/events/2"),
      "Undo"            => Aptork.undo("https://local.example/activities/undo", actor, "https://local.example/activities/like"),
      "Update"          => Aptork.update("https://local.example/activities/update", actor, note),
      "View"            => Aptork.view("https://local.example/activities/view", actor, "https://remote.example/videos/1"),
    }

    helpers.each do |type, activity|
      activity["type"].as_s.should eq(type)
      activity["actor"].as_s.should eq(actor)
      activity["published"].as_s.should_not be_empty
      Aptork::Vocab::Object.from_json_ld(activity).should be_a(Aptork::Vocab::Activity)
    end

    helpers["Follow"]["object"].as_s.should eq("https://remote.example/users/bob")
    helpers["Add"]["object"].as_h["type"].as_s.should eq("Note")
    helpers["Add"]["target"].as_s.should eq("https://local.example/collections/featured")
    Aptork::Vocab::Object.from_json_ld(helpers["Offer"]).should be_a(Aptork::Vocab::ActivityOffer)

    arrive = Aptork.arrive(
      "https://local.example/activities/arrive-builder",
      actor,
      target: "https://local.example/places/office",
      origin: "https://local.example/places/home"
    )
    arrive["type"].as_s.should eq("Arrive")
    arrive["target"].as_s.should eq("https://local.example/places/office")
    Aptork::Vocab::Object.from_json_ld(arrive).should be_a(Aptork::Vocab::Arrive)

    question = Aptork.question(
      "https://local.example/questions/builder",
      actor,
      one_of: [
        Aptork.note("https://local.example/questions/builder/options/a", "A"),
        "https://local.example/questions/builder/options/b",
      ],
      end_time: "2026-05-23T00:00:00Z",
      closed: false
    )
    parsed_question = Aptork::Vocab::Object.from_json_ld(question).as(Aptork::Vocab::Question)
    parsed_question.one_of.first.should be_a(Aptork::Vocab::Note)
    parsed_question.one_of[1].should eq("https://local.example/questions/builder/options/b")
    parsed_question.end_time.should eq("2026-05-23T00:00:00Z")
    parsed_question.closed.should eq("false")
  end

  it "builds Fedify-style helpers for common ActivityStreams object types" do
    image = Aptork.image(
      "https://local.example/media/image.png",
      name: "Preview image",
      media_type: "image/png",
      url: "https://cdn.example/media/image.png",
      sensitive: false
    )
    document = Aptork.document(
      "https://local.example/files/spec.pdf",
      name: "Spec",
      media_type: "application/pdf"
    )
    hashtag = Aptork.object("Hashtag", nil, Aptork::JsonMap{
      "name" => Aptork.json("#aptork"),
      "href" => Aptork.json("https://local.example/tags/aptork"),
    })

    article = Aptork.article(
      "https://local.example/articles/builders",
      name: "Builder article",
      summary: "Summary",
      content: "Long form content",
      attributed_to: "https://local.example/users/alice",
      attachments: [document, "https://local.example/files/archive.zip"],
      tags: [hashtag],
      url: "https://local.example/articles/builders",
      published: "2026-05-22T00:00:00Z",
      updated: "2026-05-22T01:00:00Z",
      source_content: "Long form source",
      source_media_type: "text/markdown"
    )

    typed_article = Aptork::Vocab::Object.from_json_ld(article).as(Aptork::Vocab::Article)
    typed_article.name.should eq("Builder article")
    typed_article.summary.should eq("Summary")
    typed_article.content.should eq("Long form content")
    typed_article.attributed_to.should eq(["https://local.example/users/alice"])
    typed_article.attachment.first.should be_a(Aptork::Vocab::Document)
    typed_article.attachment[1].should eq("https://local.example/files/archive.zip")
    typed_article.tags.first.should be_a(Aptork::Vocab::Hashtag)
    typed_article.url.should eq("https://local.example/articles/builders")
    typed_article.published.should eq("2026-05-22T00:00:00Z")
    typed_article.updated.should eq("2026-05-22T01:00:00Z")
    typed_article.source.not_nil!.content.should eq("Long form source")
    typed_article.source.not_nil!.media_type.should eq("text/markdown")

    typed_image = Aptork::Vocab::Object.from_json_ld(image).as(Aptork::Vocab::Image)
    typed_image.media_type.should eq("image/png")
    typed_image.url.should eq("https://cdn.example/media/image.png")
    typed_image.sensitive.should be_false

    {
      "Audio"        => Aptork.audio("https://local.example/audio/1", media_type: "audio/ogg", url: "https://cdn.example/audio/1.ogg"),
      "Event"        => Aptork.event("https://local.example/events/1", name: "Launch"),
      "Page"         => Aptork.page("https://local.example/pages/about", name: "About"),
      "Place"        => Aptork.place("https://local.example/places/office", name: "Office"),
      "Profile"      => Aptork.profile("https://local.example/profiles/alice", name: "Alice"),
      "Relationship" => Aptork.relationship("https://local.example/relationships/1", summary: "Alice follows Bob"),
      "Video"        => Aptork.video("https://local.example/videos/1", media_type: "video/mp4", url: "https://cdn.example/videos/1.mp4"),
    }.each do |type, object|
      object["type"].as_s.should eq(type)
      object["published"].as_s.should_not be_empty
      Aptork::Vocab::Object.from_json_ld(object).should be_a(Aptork::Vocab::StandardObject)
    end
  end

  it "builds Fedify-style helpers for links, tags, custom emoji, and profile fields" do
    link = Aptork.link(
      "https://cdn.example/image.png",
      rel: ["preview", "alternate"],
      media_type: "image/png",
      name: "Preview",
      hreflang: "en",
      height: 480,
      width: 640
    )
    mention = Aptork.mention("https://remote.example/users/bob", "@bob@remote.example")
    hashtag = Aptork.hashtag("#aptork", "https://local.example/tags/aptork")
    property_value = Aptork.property_value("Website", "https://example.com")
    emoji = Aptork.emoji(
      "https://local.example/emoji/blobcat",
      ":blobcat:",
      Aptork.image("https://local.example/emoji/blobcat.png", media_type: "image/png")
    )

    typed_link = Aptork::Vocab::Link.from_json_ld(link)
    typed_link.href.should eq("https://cdn.example/image.png")
    typed_link.rel.should eq(["preview", "alternate"])
    typed_link.media_type.should eq("image/png")
    typed_link.name.should eq("Preview")
    typed_link.hreflang.should eq("en")
    typed_link.height.should eq(480)
    typed_link.width.should eq(640)

    Aptork::Vocab::Link.from_json_ld(mention).should be_a(Aptork::Vocab::Mention)
    Aptork::Vocab::Link.from_json_ld(hashtag).should be_a(Aptork::Vocab::Hashtag)
    Aptork::Vocab::Object.from_json_ld(emoji).should be_a(Aptork::Vocab::Emoji)
    Aptork::Vocab::PropertyValue.from_json_ld(property_value).value.should eq("https://example.com")

    profile = Aptork.article(
      "https://local.example/articles/profile-fields",
      attachments: [property_value],
      tags: [mention, hashtag, emoji],
      url: link
    )
    typed_article = Aptork::Vocab::Article.from_json_ld(profile)
    typed_article.attachment.first.should be_a(Aptork::Vocab::PropertyValue)
    typed_article.tags[0].should be_a(Aptork::Vocab::Mention)
    typed_article.tags[1].should be_a(Aptork::Vocab::Hashtag)
    typed_article.tags[2].should be_a(Aptork::Vocab::Emoji)
    typed_article.url.should be_a(Aptork::Vocab::Link)
  end

  it "parses common ActivityStreams objects and links into typed vocabulary objects" do
    link_json = Aptork::JsonMap{
      "type"      => Aptork.json("Link"),
      "href"      => Aptork.json("https://cdn.example/image.png"),
      "rel"       => Aptork.json(["preview", "alternate"]),
      "mediaType" => Aptork.json("image/png"),
      "name"      => Aptork.json("Preview"),
      "height"    => Aptork.json(480),
      "width"     => Aptork.json(640),
    }
    hashtag_json = Aptork::JsonMap{
      "type" => Aptork.json("Hashtag"),
      "href" => Aptork.json("https://local.example/tags/crystal"),
      "name" => Aptork.json("#crystal"),
    }
    mention_json = Aptork::JsonMap{
      "type" => Aptork.json("Mention"),
      "href" => Aptork.json("https://remote.example/users/bob"),
      "name" => Aptork.json("@bob@remote.example"),
    }
    emoji_json = Aptork.object("Emoji", "https://local.example/emoji/blobcat", Aptork::JsonMap{
      "name" => Aptork.json(":blobcat:"),
      "icon" => Aptork.json(Aptork.object("Image", "https://local.example/emoji/blobcat.png", Aptork::JsonMap{
        "mediaType" => Aptork.json("image/png"),
      })),
    })
    property_value_json = Aptork.object("PropertyValue", nil, Aptork::JsonMap{
      "name"  => Aptork.json("Website"),
      "value" => Aptork.json("https://example.com"),
    })
    article = Aptork.object("Article", "https://local.example/articles/1", Aptork::JsonMap{
      "name"         => Aptork.json("Typed Article"),
      "summary"      => Aptork.json("Summary"),
      "content"      => Aptork.json("Long form content"),
      "attributedTo" => Aptork.json("https://local.example/users/alice"),
      "attachment"   => Aptork.json([Aptork.object("Document", "https://local.example/files/1", Aptork::JsonMap{
        "mediaType" => Aptork.json("application/pdf"),
      }), property_value_json]),
      "tag"       => Aptork.json([hashtag_json, mention_json, emoji_json]),
      "url"       => Aptork.json(link_json),
      "preview"   => Aptork.json([link_json]),
      "published" => Aptork.json("2026-05-22T00:00:00Z"),
      "updated"   => Aptork.json("2026-05-22T01:00:00Z"),
      "startTime" => Aptork.json("2026-05-22T00:10:00Z"),
      "endTime"   => Aptork.json("2026-05-22T00:20:00Z"),
      "duration"  => Aptork.json("PT10M"),
      "source"    => Aptork.json({
        "content"   => "Long form source",
        "mediaType" => "text/markdown",
      }),
      "proof" => Aptork.json([{
        "type"               => "DataIntegrityProof",
        "verificationMethod" => "https://local.example/users/alice#multikey",
      }]),
      "replies"        => Aptork.json(Aptork.object("Collection", "https://local.example/articles/1/replies")),
      "shares"         => Aptork.json("https://local.example/articles/1/shares"),
      "likes"          => Aptork.json("https://local.example/articles/1/likes"),
      "emojiReactions" => Aptork.json("https://local.example/articles/1/emoji-reactions"),
      "sensitive"      => Aptork.json(true),
      "quote"          => Aptork.json(Aptork.object("Note", "https://remote.example/notes/quoted", Aptork::JsonMap{
        "content" => Aptork.json("quoted"),
      })),
      "quoteUrl"           => Aptork.json("https://remote.example/notes/quoted"),
      "quoteAuthorization" => Aptork.json("https://remote.example/quote-auth/1"),
    })

    parsed = Aptork::Vocab::Object.from_json_ld(article)

    parsed.should be_a(Aptork::Vocab::Article)
    typed_article = parsed.as(Aptork::Vocab::Article)
    typed_article.name.should eq("Typed Article")
    typed_article.summary.should eq("Summary")
    typed_article.content.should eq("Long form content")
    typed_article.attributed_to.should eq(["https://local.example/users/alice"])
    typed_article.attachment.first.should be_a(Aptork::Vocab::Document)
    typed_article.attachment[1].should be_a(Aptork::Vocab::PropertyValue)
    typed_article.tags[0].should be_a(Aptork::Vocab::Hashtag)
    typed_article.tags[1].should be_a(Aptork::Vocab::Mention)
    typed_article.tags[2].should be_a(Aptork::Vocab::Emoji)
    typed_article.url.should be_a(Aptork::Vocab::Link)
    typed_article.previews.first.should be_a(Aptork::Vocab::Link)
    typed_article.published.should eq("2026-05-22T00:00:00Z")
    typed_article.updated.should eq("2026-05-22T01:00:00Z")
    typed_article.start_time.should eq("2026-05-22T00:10:00Z")
    typed_article.end_time.should eq("2026-05-22T00:20:00Z")
    typed_article.duration.should eq("PT10M")
    typed_article.source.not_nil!.content.should eq("Long form source")
    typed_article.source.not_nil!.media_type.should eq("text/markdown")
    typed_article.proofs.first.should be_a(Aptork::Vocab::Object)
    typed_article.replies.should be_a(Aptork::Vocab::Collection)
    typed_article.shares.should eq("https://local.example/articles/1/shares")
    typed_article.likes.should eq("https://local.example/articles/1/likes")
    typed_article.emoji_reactions.should eq("https://local.example/articles/1/emoji-reactions")
    typed_article.sensitive.should be_true
    typed_article.quote.should be_a(Aptork::Vocab::Note)
    typed_article.quote_url.should eq("https://remote.example/notes/quoted")
    typed_article.quote_authorization.should eq("https://remote.example/quote-auth/1")

    typed_link = typed_article.url.as(Aptork::Vocab::Link)
    typed_link.href.should eq("https://cdn.example/image.png")
    typed_link.rel.should eq(["preview", "alternate"])
    typed_link.media_type.should eq("image/png")
    typed_link.height.should eq(480)
    typed_link.width.should eq(640)

    property_value = typed_article.attachment[1].as(Aptork::Vocab::PropertyValue)
    property_value.name.should eq("Website")
    property_value.value.should eq("https://example.com")
    typed_article.tags[0].as(Aptork::Vocab::Hashtag).href.should eq("https://local.example/tags/crystal")
    typed_article.tags[1].as(Aptork::Vocab::Mention).name.should eq("@bob@remote.example")
    typed_article.tags[2].as(Aptork::Vocab::Emoji).icon.should be_a(Aptork::Vocab::Image)

    Aptork::Vocab::Object.from_json_ld(Aptork.object("Audio", "https://local.example/audio/1")).should be_a(Aptork::Vocab::Audio)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Event", "https://local.example/events/1")).should be_a(Aptork::Vocab::Event)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Image", "https://local.example/images/1")).should be_a(Aptork::Vocab::Image)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Page", "https://local.example/pages/1")).should be_a(Aptork::Vocab::Page)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Place", "https://local.example/places/1")).should be_a(Aptork::Vocab::Place)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Profile", "https://local.example/profiles/1")).should be_a(Aptork::Vocab::Profile)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Relationship", "https://local.example/relationships/1")).should be_a(Aptork::Vocab::Relationship)
    Aptork::Vocab::Object.from_json_ld(Aptork.object("Video", "https://local.example/videos/1")).should be_a(Aptork::Vocab::Video)
    Aptork::Vocab::Link.type_id.should eq("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Link")
    Aptork::Vocab::Hashtag.type_id.should eq("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Hashtag")
    Aptork::Vocab::Mention.type_id.should eq("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Mention")
    Aptork::Vocab::Emoji.type_id.should eq("#{Aptork::MASTODON_CONTEXT}Emoji")
    Aptork::Vocab::PropertyValue.type_id.should eq("#{Aptork::SCHEMA_CONTEXT}PropertyValue")
    Aptork::Vocab::Link.from_json_ld(hashtag_json).should be_a(Aptork::Vocab::Hashtag)
    typed_article.source.not_nil!.to_json_ld["content"].as_s.should eq("Long form source")
  end

  it "parses Fedify-style Question poll fields" do
    question = Aptork.object("Question", "https://local.example/questions/1", Aptork::JsonMap{
      "actor"       => Aptork.json("https://local.example/users/alice"),
      "oneOf"       => Aptork.json([Aptork.object("Note", "https://local.example/questions/1/options/a", Aptork::JsonMap{"name" => Aptork.json("A")})]),
      "anyOf"       => Aptork.json(["https://local.example/questions/1/options/b"]),
      "closed"      => Aptork.json(false),
      "endTime"     => Aptork.json("2026-05-23T00:00:00Z"),
      "votersCount" => Aptork.json(12),
    })

    parsed = Aptork::Vocab::Activity.from_json_ld(question)

    parsed.should be_a(Aptork::Vocab::Question)
    typed_question = parsed.as(Aptork::Vocab::Question)
    typed_question.actor.should eq("https://local.example/users/alice")
    typed_question.one_of.first.should be_a(Aptork::Vocab::Note)
    typed_question.any_of.should eq(["https://local.example/questions/1/options/b"])
    typed_question.closed.should eq("false")
    typed_question.end_time.should eq("2026-05-23T00:00:00Z")
    typed_question.voters_count.should eq(12)
  end

  it "normalizes expanded type ids for typed vocabulary dispatch" do
    note = Aptork.object("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Note", "https://local.example/notes/expanded", Aptork::JsonMap{
      "content" => Aptork.json("expanded"),
    })
    activity = Aptork.activity("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Like", "https://local.example/activities/like-expanded", "https://local.example/users/alice", note)

    Aptork.type_name("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Like").should eq("Like")
    Aptork::Vocab::Like.type_id.should eq("#{Aptork::ACTIVITYSTREAMS_CONTEXT}#Like")
    Aptork::Vocab::Repository.type_id.should eq("#{Aptork::FORGEFED_CONTEXT}#Repository")
    Aptork::Vocab::MarketplaceOffer.type_name.should eq("Offer")
    Aptork::Vocab::Object.from_json_ld(activity).should be_a(Aptork::Vocab::Like)
    Aptork::Vocab::Object.from_json_ld(note).should be_a(Aptork::Vocab::Note)

    marketplace_offer = Aptork.marketplace_offer(
      "https://local.example/offers/expanded",
      "https://local.example/users/alice",
      Aptork.marketplace_product("https://local.example/products/expanded", "Expanded"),
      "Expanded offer"
    )
    marketplace_offer["type"] = Aptork.json("#{Aptork::MARKETPLACE_CONTEXT}#Offer")
    Aptork::Vocab::Object.from_json_ld(marketplace_offer).should be_a(Aptork::Vocab::MarketplaceOffer)
  end

  it "preserves unknown JSON-LD object types and rejects non-object JSON-LD values" do
    unknown = Aptork::Vocab::Object.from_json_ld(Aptork.object("CustomType", "https://local.example/custom/1"))

    unknown.should be_a(Aptork::Vocab::Object)
    unknown.type.should eq("CustomType")
    unknown.json["id"].as_s.should eq("https://local.example/custom/1")

    expect_raises(ArgumentError, "JSON-LD value must be an object") do
      Aptork::Vocab::Object.from_json_ld(Aptork.json("not an object"))
    end
  end

  it "parses actor JSON-LD into typed actor and person objects" do
    actor = Aptork.actor(
      "Person",
      "https://local.example/users/alice",
      "alice",
      "https://local.example/users/alice/inbox",
      "https://local.example/users/alice/outbox",
      followers: "https://local.example/users/alice/followers",
      following: "https://local.example/users/alice/following",
      liked: "https://local.example/users/alice/liked",
      featured: "https://local.example/users/alice/featured",
      featured_tags: "https://local.example/users/alice/tags",
      streams: ["https://local.example/users/alice/streams/public"],
      manually_approves_followers: true,
      discoverable: true,
      suspended: false,
      memorial: false,
      indexable: true,
      successor: "https://local.example/users/alice-next",
      alias_uri: "https://example.com/@alice",
      shared_inbox: "https://local.example/inbox",
      oauth_authorization_endpoint: "https://local.example/oauth/authorize",
      oauth_token_endpoint: "https://local.example/oauth/token",
      provide_client_key: "https://local.example/client-key",
      sign_client_key: "https://local.example/sign-client-key",
      upload_media: "https://local.example/media",
      proxy_url: "https://local.example/proxy",
      public_key: Aptork.public_key(
        "https://local.example/users/alice#main-key",
        "https://local.example/users/alice",
        "pem"
      )
    )

    parsed = Aptork::Vocab::Object.from_json_ld(actor)
    parsed.should be_a(Aptork::Vocab::Person)
    person = parsed.as(Aptork::Vocab::Person)
    person.id.should eq("https://local.example/users/alice")
    person.type.should eq("Person")
    person.preferred_username.should eq("alice")
    person.inbox.should eq("https://local.example/users/alice/inbox")
    person.outbox.should eq("https://local.example/users/alice/outbox")
    person.followers.should eq("https://local.example/users/alice/followers")
    person.following.should eq("https://local.example/users/alice/following")
    person.liked.should eq("https://local.example/users/alice/liked")
    person.featured.should eq("https://local.example/users/alice/featured")
    person.featured_tags.should eq("https://local.example/users/alice/tags")
    person.streams.should eq(["https://local.example/users/alice/streams/public"])
    person.manually_approves_followers.should be_true
    person.discoverable.should be_true
    person.suspended.should be_false
    person.memorial.should be_false
    person.indexable.should be_true
    person.successor.should eq("https://local.example/users/alice-next")
    person.also_known_as.should eq("https://example.com/@alice")
    person.endpoints.should be_a(Aptork::Vocab::Endpoints)
    person.shared_inbox.should eq("https://local.example/inbox")
    person.endpoints.not_nil!.shared_inbox.should eq("https://local.example/inbox")
    person.endpoints.not_nil!.oauth_authorization_endpoint.should eq("https://local.example/oauth/authorize")
    person.endpoints.not_nil!.oauth_token_endpoint.should eq("https://local.example/oauth/token")
    person.endpoints.not_nil!.provide_client_key.should eq("https://local.example/client-key")
    person.endpoints.not_nil!.sign_client_key.should eq("https://local.example/sign-client-key")
    person.endpoints.not_nil!.upload_media.should eq("https://local.example/media")
    person.endpoints.not_nil!.proxy_url.should eq("https://local.example/proxy")
    person.endpoints.not_nil!.to_json_ld["sharedInbox"].as_s.should eq("https://local.example/inbox")
    person.public_key.should be_a(Aptork::Vocab::Object)
    person.public_key.as(Aptork::Vocab::Object).id.should eq("https://local.example/users/alice#main-key")
    person.assertion_methods.should be_empty

    actor_subtype = Aptork::Vocab::Actor.from_json_ld(actor)
    actor_subtype.should be_a(Aptork::Vocab::Person)

    alias_actor = actor.dup
    alias_actor.delete("alsoKnownAs")
    alias_actor["alias"] = Aptork.json("https://example.org/users/alice")
    Aptork::Vocab::Person.from_json_ld(alias_actor).also_known_as.should eq("https://example.org/users/alice")
  end

  it "parses all ActivityStreams actor subtypes into typed actor objects" do
    expected = {
      "Application"  => "Aptork::Vocab::Application",
      "Group"        => "Aptork::Vocab::Group",
      "Organization" => "Aptork::Vocab::Organization",
      "Person"       => "Aptork::Vocab::Person",
      "Service"      => "Aptork::Vocab::Service",
    }

    expected.each do |type, class_name|
      actor = Aptork.actor(
        type,
        "https://local.example/#{type.downcase}/main",
        type.downcase,
        "https://local.example/#{type.downcase}/main/inbox",
        "https://local.example/#{type.downcase}/main/outbox",
        shared_inbox: "https://local.example/inbox"
      )

      parsed = Aptork::Vocab::Object.from_json_ld(actor)
      parsed.class.name.should eq(class_name)
      typed_actor = parsed.as(Aptork::Vocab::Actor)
      typed_actor.id.should eq("https://local.example/#{type.downcase}/main")
      typed_actor.type.should eq(type)
      typed_actor.shared_inbox.should eq("https://local.example/inbox")
      Aptork::Vocab::Actor.from_json_ld(actor).class.name.should eq(class_name)
    end
  end

  it "keeps marketplace Service objects distinct from ActivityStreams Service actors" do
    actor_service = Aptork.object(
      "Service",
      "https://local.example/services/relay",
      Aptork::JsonMap{
        "inbox"  => Aptork.json("https://local.example/services/relay/inbox"),
        "outbox" => Aptork.json("https://local.example/services/relay/outbox"),
      }
    )
    marketplace_service = Aptork.marketplace_service(
      "https://local.example/market/services/review",
      "Code review",
      provider: "https://local.example/users/alice"
    )

    Aptork::Vocab::Object.from_json_ld(actor_service).should be_a(Aptork::Vocab::Service)
    Aptork::Vocab::Object.from_json_ld(marketplace_service).should be_a(Aptork::Vocab::MarketplaceService)
  end

  it "parses Fedify-style actor key vocabulary objects" do
    cryptographic_key = Aptork.public_key(
      "https://local.example/users/alice#main-key",
      "https://local.example/users/alice",
      "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"
    )
    multikey = Aptork.multikey(
      "https://local.example/users/alice#multikey-1",
      "https://local.example/users/alice",
      "z6Mktest"
    )
    actor = Aptork.actor(
      "Person",
      "https://local.example/users/alice",
      "alice",
      "https://local.example/users/alice/inbox",
      "https://local.example/users/alice/outbox",
      public_key: cryptographic_key,
      assertion_methods: [multikey]
    )

    parsed_key = Aptork::Vocab::Object.from_json_ld(cryptographic_key)
    parsed_key.should be_a(Aptork::Vocab::CryptographicKey)
    parsed_key.as(Aptork::Vocab::CryptographicKey).owner.should eq("https://local.example/users/alice")
    parsed_key.as(Aptork::Vocab::CryptographicKey).public_key_pem.not_nil!.should contain("BEGIN PUBLIC KEY")
    Aptork::Vocab::CryptographicKey.type_id.should eq("#{Aptork::SECURITY_CONTEXT}#CryptographicKey")

    parsed_multikey = Aptork::Vocab::Object.from_json_ld(multikey)
    parsed_multikey.should be_a(Aptork::Vocab::Multikey)
    parsed_multikey.as(Aptork::Vocab::Multikey).controller.should eq("https://local.example/users/alice")
    parsed_multikey.as(Aptork::Vocab::Multikey).public_key_multibase.should eq("z6Mktest")
    Aptork::Vocab::Multikey.type_id.should eq("#{Aptork::MULTIKEY_CONTEXT}#Multikey")

    parsed_actor = Aptork::Vocab::Person.from_json_ld(actor)
    parsed_actor.public_key.should be_a(Aptork::Vocab::CryptographicKey)
    parsed_actor.assertion_methods.first.should be_a(Aptork::Vocab::Multikey)
  end

  it "parses Tombstone JSON-LD with deleted timestamp and former types" do
    tombstone = Aptork.tombstone(
      "https://local.example/users/alice",
      "Person",
      "2024-01-15T00:00:00Z"
    )

    parsed = Aptork::Vocab::Object.from_json_ld(tombstone)
    parsed.should be_a(Aptork::Vocab::Tombstone)
    deleted = parsed.as(Aptork::Vocab::Tombstone)
    deleted.id.should eq("https://local.example/users/alice")
    deleted.former_type.should eq("Person")
    deleted.former_types.should eq(["Person"])
    deleted.deleted.should eq("2024-01-15T00:00:00Z")

    multi = Aptork::Vocab::Tombstone.from_json_ld(Aptork::JsonMap{
      "type"       => Aptork.json("Tombstone"),
      "formerType" => Aptork.json(["Note", "Article"]),
    })
    multi.former_types.should eq(["Note", "Article"])
  end

  it "builds ForgeFed Repository objects" do
    repository = Aptork.forgefed_repository(
      "https://local.example/repos/aptork",
      "aptork",
      "https://local.example/repos/aptork/inbox",
      "https://local.example/repos/aptork/outbox",
      clone_uri: "https://local.example/repos/aptork.git",
      push_uris: ["ssh://git@local.example/aptork.git"],
      followers: "https://local.example/repos/aptork/followers",
      tickets_tracked_by: "https://local.example/repos/aptork",
      send_patches_to: "https://local.example/repos/aptork"
    )

    repository["type"].as_s.should eq("Repository")
    repository["@context"].as_a.includes?(Aptork.json(Aptork::FORGEFED_CONTEXT)).should be_true
    repository["cloneUri"].as_s.should eq("https://local.example/repos/aptork.git")
    repository["pushUri"].as_a.first.as_s.should eq("ssh://git@local.example/aptork.git")
    repository["ticketsTrackedBy"].as_s.should eq("https://local.example/repos/aptork")

    parsed = Aptork::Vocab::Object.from_json_ld(repository)
    parsed.should be_a(Aptork::Vocab::Repository)
    repo = parsed.as(Aptork::Vocab::Repository)
    repo.name.should eq("aptork")
    repo.inbox.should eq("https://local.example/repos/aptork/inbox")
    repo.outbox.should eq("https://local.example/repos/aptork/outbox")
    repo.clone_uri.should eq("https://local.example/repos/aptork.git")
    repo.push_uris.should eq(["ssh://git@local.example/aptork.git"])
    repo.tickets_tracked_by.should eq("https://local.example/repos/aptork")
    repo.send_patches_to.should eq("https://local.example/repos/aptork")
  end

  it "builds ForgeFed Project, Tag, and tracker objects" do
    project = Aptork.forgefed_project(
      "https://local.example/projects/aptork",
      "Aptork",
      inbox: "https://local.example/projects/aptork/inbox",
      outbox: "https://local.example/projects/aptork/outbox",
      followers: "https://local.example/projects/aptork/followers"
    )
    tag = Aptork.forgefed_tag(
      "https://local.example/repos/aptork/tags/v1.0.0",
      "v1.0.0",
      context: "https://local.example/repos/aptork",
      href: "https://local.example/repos/aptork/archive/v1.0.0.tar.gz"
    )
    ticket_tracker = Aptork.forgefed_ticket_tracker(
      "https://local.example/repos/aptork/tickets",
      "Tickets",
      context: "https://local.example/repos/aptork",
      inbox: "https://local.example/repos/aptork/tickets/inbox",
      outbox: "https://local.example/repos/aptork/tickets/outbox"
    )
    patch_tracker = Aptork.forgefed_patch_tracker(
      "https://local.example/repos/aptork/patches",
      "Patches",
      context: "https://local.example/repos/aptork"
    )

    project["type"].as_s.should eq("Project")
    tag["type"].as_s.should eq("Tag")
    ticket_tracker["type"].as_s.should eq("TicketTracker")
    patch_tracker["type"].as_s.should eq("PatchTracker")

    parsed_project = Aptork::Vocab::Object.from_json_ld(project)
    parsed_project.should be_a(Aptork::Vocab::Project)
    parsed_project.as(Aptork::Vocab::Project).inbox.should eq("https://local.example/projects/aptork/inbox")
    parsed_project.as(Aptork::Vocab::Project).followers.should eq("https://local.example/projects/aptork/followers")

    parsed_tag = Aptork::Vocab::ForgeFedObject.from_json_ld(tag)
    parsed_tag.should be_a(Aptork::Vocab::ForgeFedTag)
    parsed_tag.as(Aptork::Vocab::ForgeFedTag).href.should eq("https://local.example/repos/aptork/archive/v1.0.0.tar.gz")
    parsed_tag.as(Aptork::Vocab::ForgeFedTag).context.should eq("https://local.example/repos/aptork")

    parsed_ticket_tracker = Aptork::Vocab::Object.from_json_ld(ticket_tracker)
    parsed_ticket_tracker.should be_a(Aptork::Vocab::TicketTracker)
    parsed_ticket_tracker.as(Aptork::Vocab::TicketTracker).outbox.should eq("https://local.example/repos/aptork/tickets/outbox")

    parsed_patch_tracker = Aptork::Vocab::ForgeFedObject.from_json_ld(patch_tracker)
    parsed_patch_tracker.should be_a(Aptork::Vocab::PatchTracker)
    parsed_patch_tracker.as(Aptork::Vocab::PatchTracker).context.should eq("https://local.example/repos/aptork")
  end

  it "builds ForgeFed Branch, Commit, and Push objects" do
    branch = Aptork.forgefed_branch(
      "https://local.example/repos/aptork/branches/main",
      "https://local.example/repos/aptork",
      "main",
      "refs/heads/main"
    )
    commit = Aptork.forgefed_commit(
      "https://local.example/repos/aptork/commits/abc",
      "https://local.example/repos/aptork",
      "abc",
      "https://local.example/users/alice",
      "Add federation"
    )
    push = Aptork.forgefed_push(
      "https://local.example/repos/aptork/outbox/push-1",
      "https://local.example/repos/aptork",
      "https://local.example/users/alice",
      "https://local.example/repos/aptork/branches/main",
      [commit],
      "000",
      "abc"
    )

    branch["type"].as_s.should eq("Branch")
    branch["ref"].as_s.should eq("refs/heads/main")
    commit["type"].as_s.should eq("Commit")
    commit["hash"].as_s.should eq("abc")
    commit["context"].as_s.should eq("https://local.example/repos/aptork")
    push["type"].as_s.should eq("Push")
    push["@context"].as_a.includes?(Aptork.json(Aptork::FORGEFED_CONTEXT)).should be_true
    push["object"].as_h["orderedItems"].as_a.first.as_h["type"].as_s.should eq("Commit")
    push["hashAfter"].as_s.should eq("abc")

    parsed_branch = Aptork::Vocab::Object.from_json_ld(branch)
    parsed_branch.should be_a(Aptork::Vocab::Branch)
    parsed_branch.as(Aptork::Vocab::Branch).ref.should eq("refs/heads/main")
    parsed_branch.as(Aptork::Vocab::Branch).context.should eq("https://local.example/repos/aptork")
    parsed_commit = Aptork::Vocab::Object.from_json_ld(commit)
    parsed_commit.should be_a(Aptork::Vocab::Commit)
    parsed_commit.as(Aptork::Vocab::Commit).hash.should eq("abc")
    parsed_commit.as(Aptork::Vocab::Commit).attributed_to.should eq("https://local.example/users/alice")

    parsed_push = Aptork::Vocab::Object.from_json_ld(push)
    parsed_push.should be_a(Aptork::Vocab::Push)
    typed_push = parsed_push.as(Aptork::Vocab::Push)
    typed_push.actor.should eq("https://local.example/repos/aptork")
    typed_push.attributed_to.should eq("https://local.example/users/alice")
    typed_push.context.should eq("https://local.example/repos/aptork")
    typed_push.target.should eq("https://local.example/repos/aptork/branches/main")
    typed_push.hash_before.should eq("000")
    typed_push.hash_after.should eq("abc")
    typed_push.object.should be_a(Aptork::Vocab::OrderedCollection)
    typed_push.commits.first.should be_a(Aptork::Vocab::Commit)
    typed_push.commits.first.as(Aptork::Vocab::Commit).hash.should eq("abc")
    typed_push.to.should eq([Aptork::PUBLIC_COLLECTION])
    typed_push.published.should_not be_nil
  end

  it "builds ForgeFed Ticket objects" do
    ticket = Aptork.forgefed_ticket(
      "https://local.example/tickets/1",
      "Bug",
      "Fix it",
      assignee: "https://remote.example/users/bob",
      context: "https://local.example/repos/aptork",
      resolved: false
    )

    ticket["type"].as_s.should eq("Ticket")
    ticket["assignee"].as_s.should eq("https://remote.example/users/bob")
    ticket["context"].as_s.should eq("https://local.example/repos/aptork")
    ticket["resolved"].as_bool.should be_false

    parsed = Aptork::Vocab::Object.from_json_ld(ticket)
    parsed.should be_a(Aptork::Vocab::Ticket)
    parsed_ticket = parsed.as(Aptork::Vocab::Ticket)
    parsed_ticket.name.should eq("Bug")
    parsed_ticket.content.should eq("Fix it")
    parsed_ticket.assignee.should eq("https://remote.example/users/bob")
    parsed_ticket.context.should eq("https://local.example/repos/aptork")
    parsed_ticket.resolved.should be_false
  end

  it "builds ForgeFed MergeRequest-like Ticket objects" do
    mr = Aptork.forgefed_merge_request(
      "https://local.example/mrs/1",
      "Add ActivityPub support",
      "Implements signed delivery",
      "https://local.example/repos/aptork",
      "https://remote.example/repos/app/branches/feature",
      "https://local.example/repos/aptork/branches/main",
      mr_diff: "https://local.example/mrs/1.diff"
    )

    mr["type"].as_s.should eq("Ticket")
    mr["@context"].as_a.includes?(Aptork.json(Aptork::FORGEFED_CONTEXT)).should be_true
    mr["context"].as_s.should eq("https://local.example/repos/aptork")
    mr["mrDiff"].as_s.should eq("https://local.example/mrs/1.diff")
    mr["attachment"].as_a.first.as_h["object"].as_s.should eq("https://remote.example/repos/app/branches/feature")

    parsed = Aptork::Vocab::ForgeFedObject.from_json_ld(mr)
    parsed.should be_a(Aptork::Vocab::Ticket)
    parsed_mr = parsed.as(Aptork::Vocab::Ticket)
    parsed_mr.mr_diff.should eq("https://local.example/mrs/1.diff")
    parsed_mr.attachments.first.should be_a(Aptork::Vocab::Activity)
  end

  it "builds marketplace Offer objects" do
    item = Aptork.object("Service", "https://local.example/services/solver", Aptork::JsonMap{
      "name" => Aptork.json("Solver"),
    })
    offer = Aptork.marketplace_offer(
      "https://local.example/offers/1",
      "https://local.example/users/alice",
      item,
      "Solver access",
      price: "10",
      currency: "USD"
    )

    offer["type"].as_s.should eq("Offer")
    offer["item"].as_h["type"].as_s.should eq("Service")
    offer["priceCurrency"].as_s.should eq("USD")

    parsed = Aptork::Vocab::Object.from_json_ld(offer)
    parsed.should be_a(Aptork::Vocab::MarketplaceOffer)
    marketplace_offer = parsed.as(Aptork::Vocab::MarketplaceOffer)
    marketplace_offer.name.should eq("Solver access")
    marketplace_offer.actor.should eq("https://local.example/users/alice")
    marketplace_offer.item.should be_a(Aptork::Vocab::Actor)
    marketplace_offer.price.should eq("10")
    marketplace_offer.price_currency.should eq("USD")
  end

  it "builds marketplace Product, Service, PriceSpecification, and Listing objects" do
    product = Aptork.marketplace_product(
      "https://local.example/products/solver",
      "Solver",
      summary: "Priority solver access",
      attributed_to: "https://local.example/users/alice"
    )
    service = Aptork.marketplace_service(
      "https://local.example/services/review",
      "Review service",
      summary: "Code review",
      attributed_to: "https://local.example/users/alice",
      provider: "https://local.example/users/alice",
      terms_of_service: "https://local.example/terms"
    )
    price = Aptork.marketplace_price_specification("10", "USD", unit_text: "month")
    listing = Aptork.marketplace_listing(
      "https://local.example/listings/solver",
      "https://local.example/users/alice",
      service,
      "Solver subscription",
      price
    )

    product["type"].as_s.should eq("Product")
    product["@context"].as_a.includes?(Aptork.json(Aptork::MARKETPLACE_CONTEXT)).should be_true
    service["type"].as_s.should eq("Service")
    service["@context"].as_a.includes?(Aptork.json(Aptork::MARKETPLACE_CONTEXT)).should be_true
    service["termsOfService"].as_s.should eq("https://local.example/terms")
    price["type"].as_s.should eq("PriceSpecification")
    price["priceCurrency"].as_s.should eq("USD")
    listing["type"].as_s.should eq("Listing")
    listing["item"].as_h["type"].as_s.should eq("Service")
    listing["priceSpecification"].as_h["unitText"].as_s.should eq("month")

    parsed_product = Aptork::Vocab::Object.from_json_ld(product)
    parsed_product.should be_a(Aptork::Vocab::Product)
    parsed_product.as(Aptork::Vocab::Product).summary.should eq("Priority solver access")
    parsed_product.as(Aptork::Vocab::Product).attributed_to.should eq("https://local.example/users/alice")
    parsed_service = Aptork::Vocab::Object.from_json_ld(service)
    parsed_service.should be_a(Aptork::Vocab::MarketplaceService)
    parsed_service.as(Aptork::Vocab::MarketplaceService).summary.should eq("Code review")
    parsed_service.as(Aptork::Vocab::MarketplaceService).attributed_to.should eq("https://local.example/users/alice")
    parsed_service.as(Aptork::Vocab::MarketplaceService).provider.should eq("https://local.example/users/alice")
    parsed_service.as(Aptork::Vocab::MarketplaceService).terms_of_service.should eq("https://local.example/terms")
    parsed_price = Aptork::Vocab::Object.from_json_ld(price)
    parsed_price.should be_a(Aptork::Vocab::PriceSpecification)
    parsed_price.as(Aptork::Vocab::PriceSpecification).price.should eq("10")
    parsed_price.as(Aptork::Vocab::PriceSpecification).price_currency.should eq("USD")
    parsed_price.as(Aptork::Vocab::PriceSpecification).unit_text.should eq("month")
    parsed_listing = Aptork::Vocab::Object.from_json_ld(listing)
    parsed_listing.should be_a(Aptork::Vocab::Listing)
    parsed_listing.as(Aptork::Vocab::Listing).actor.should eq("https://local.example/users/alice")
    parsed_listing.as(Aptork::Vocab::Listing).item.should be_a(Aptork::Vocab::MarketplaceService)
    parsed_listing.as(Aptork::Vocab::Listing).price_specification.should be_a(Aptork::Vocab::PriceSpecification)
    parsed_listing.as(Aptork::Vocab::Listing).to.should eq([Aptork::PUBLIC_COLLECTION])
    parsed_listing.as(Aptork::Vocab::Listing).to_json_ld.should eq(listing)
  end

  it "builds FEP-0837 marketplace Proposal and Agreement flows" do
    quantity = Aptork.marketplace_quantity(value: "1")
    primary = Aptork.marketplace_intent(
      "https://market.example/proposals/1#primary",
      "transfer",
      quantity,
      resource_conforms_to: "https://www.wikidata.org/wiki/Q11442"
    )
    reciprocal = Aptork.marketplace_intent(
      "https://market.example/proposals/1#reciprocal",
      "transfer",
      Aptork.marketplace_quantity(value: "30")
    )
    proposal = Aptork.marketplace_proposal(
      "https://market.example/proposals/1",
      "offer",
      "https://market.example/users/alice",
      primary,
      name: "Used bike",
      reciprocal: reciprocal
    )
    commitment = Aptork.marketplace_commitment(
      "https://market.example/proposals/1#primary",
      quantity,
      id: "https://social.example/agreements/1#primary"
    )
    agreement = Aptork.marketplace_agreement(
      commitment,
      id: "https://social.example/agreements/1",
      attributed_to: "https://social.example/users/bob"
    )
    offer = Aptork.marketplace_agreement_offer(
      "https://social.example/offers/1",
      "https://social.example/users/bob",
      agreement,
      ["https://market.example/users/alice"]
    )
    payment = Aptork.marketplace_payment_link("Buy", "https://market.example/proposals/1")

    proposal["type"].as_s.should eq("Proposal")
    proposal["@context"].as_a.first.as_s.should eq(Aptork::ACTIVITYSTREAMS_CONTEXT)
    proposal["publishes"].as_h["type"].as_s.should eq("Intent")
    proposal["reciprocal"].as_h["resourceQuantity"].as_h["hasNumericalValue"].as_s.should eq("30")
    agreement["type"].as_s.should eq("Agreement")
    agreement["stipulates"].as_h["satisfies"].as_s.should eq("https://market.example/proposals/1#primary")
    offer["type"].as_s.should eq("Offer")
    offer["object"].as_h["type"].as_s.should eq("Agreement")
    payment["rel"].as_a.last.as_s.should eq("#{Aptork::VALUEFLOWS_CONTEXT}Proposal")

    parsed_intent = Aptork::Vocab::Object.from_json_ld(primary)
    parsed_intent.should be_a(Aptork::Vocab::Intent)
    parsed_intent.as(Aptork::Vocab::Intent).action.should eq("transfer")
    parsed_intent.as(Aptork::Vocab::Intent).resource_conforms_to.should eq("https://www.wikidata.org/wiki/Q11442")
    parsed_intent.as(Aptork::Vocab::Intent).resource_quantity.should be_a(Aptork::Vocab::Measure)
    parsed_intent.as(Aptork::Vocab::Intent).resource_quantity.not_nil!.unit.should eq("one")
    parsed_intent.as(Aptork::Vocab::Intent).resource_quantity.not_nil!.numerical_value.should eq("1")
    parsed_intent.as(Aptork::Vocab::Intent).resource_quantity.not_nil!.to_json_ld.should eq(quantity)
    parsed_proposal = Aptork::Vocab::Object.from_json_ld(proposal)
    parsed_proposal.should be_a(Aptork::Vocab::Proposal)
    parsed_proposal.as(Aptork::Vocab::Proposal).purpose.should eq("offer")
    parsed_proposal.as(Aptork::Vocab::Proposal).publishes.should be_a(Aptork::Vocab::Intent)
    parsed_proposal.as(Aptork::Vocab::Proposal).reciprocal.should be_a(Aptork::Vocab::Intent)
    parsed_proposal.as(Aptork::Vocab::Proposal).unit_based.should be_false
    parsed_commitment = Aptork::Vocab::Object.from_json_ld(commitment)
    parsed_commitment.should be_a(Aptork::Vocab::Commitment)
    parsed_commitment.as(Aptork::Vocab::Commitment).satisfies.should eq("https://market.example/proposals/1#primary")
    parsed_agreement = Aptork::Vocab::Object.from_json_ld(agreement)
    parsed_agreement.should be_a(Aptork::Vocab::Agreement)
    parsed_agreement.as(Aptork::Vocab::Agreement).stipulates.should be_a(Aptork::Vocab::Commitment)
    parsed_agreement.as(Aptork::Vocab::Agreement).attributed_to.should eq("https://social.example/users/bob")
    parsed_offer = Aptork::Vocab::Object.from_json_ld(offer)
    parsed_offer.should be_a(Aptork::Vocab::MarketplaceOffer)
    parsed_offer.as(Aptork::Vocab::MarketplaceOffer).object.should be_a(Aptork::Vocab::Agreement)
  end
end

describe "Aptork signature helpers" do
  it "builds and verifies RFC 9421 HTTP Message Signatures" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    body = %({"type":"Create"})
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox?x=1",
      body,
      key_pair,
      created: 1_718_888_000_i64
    )
    request = Aptork::Request.new(
      "POST",
      "/inbox?x=1",
      headers: headers,
      body: body
    )

    params = Aptork::Signatures.parse_message_signature(request).not_nil!

    params.label.should eq("sig1")
    params.key_id.should eq("https://local.example/users/alice#main-key")
    params.algorithm.should eq("rsa-v1_5-sha256")
    params.components.should eq(["@method", "@target-uri", "@authority", "host", "date", "content-digest"])
    params.created.should eq(1_718_888_000_i64)
    headers["Signature-Input"].should contain(%("@method" "@target-uri" "@authority" "host" "date" "content-digest"))
    headers["Content-Digest"].should eq(Aptork::Signatures.content_digest_header(body))
    Aptork::Signatures.valid_content_digest?(request).should be_true
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, "https://remote.example/inbox?x=1", key_pair).should be_true
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, "https://remote.example/other", key_pair).should be_false
  end

  it "supports RFC 9421 custom labels, components, and parameters" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    body = %({"type":"Create"})
    options = Aptork::Rfc9421Options.new(
      label: "mysig",
      components: ["@method", "@target-uri", "@authority", "host", "date", "content-digest"],
      created: 1_718_888_000_i64,
      key_id: key_pair.id,
      nonce: "abc123",
      tag: "activitypub",
      expires: 1_718_888_600_i64
    )
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox",
      body,
      key_pair,
      options
    )
    request = Aptork::Request.new(
      "POST",
      "/inbox",
      headers: headers,
      body: body
    )

    params = Aptork::Signatures.parse_message_signature(request, "mysig").not_nil!

    headers["Signature-Input"].should start_with("mysig=")
    headers["Signature"].should start_with("mysig=:")
    params.nonce.should eq("abc123")
    params.tag.should eq("activitypub")
    params.expires.should eq(1_718_888_600_i64)
    verify_options = Aptork::Rfc9421VerifyOptions.new(now: 1_718_888_100_i64)
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, "https://remote.example/inbox", key_pair, "mysig", verify_options).should be_true
  end

  it "preserves RFC 9421 component parameters in signature bases" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    body = %({"type":"Create"})
    options = Aptork::Rfc9421Options.new(
      label: "structured",
      components: ["@method", "@scheme", "@request-target", "@query", %(@query-param;name="resource"), "content-digest;sf"],
      created: 1_718_888_000_i64,
      key_id: key_pair.id
    )
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox?resource=acct%3Aalice%40example.com&x=1",
      body,
      key_pair,
      options
    )
    request = Aptork::Request.new("POST", "/inbox?resource=acct%3Aalice%40example.com&x=1", headers: headers, body: body)

    params = Aptork::Signatures.parse_message_signature(request, "structured").not_nil!
    base = Aptork::Signatures.message_signature_base(request, "https://remote.example/inbox?resource=acct%3Aalice%40example.com&x=1", params)
    verify_options = Aptork::Rfc9421VerifyOptions.new(
      required_components: ["@method", "@scheme", "@request-target", "content-digest;sf"],
      now: 1_718_888_000_i64
    )

    params.components.should eq(["@method", "@scheme", "@request-target", "@query", %(@query-param;name="resource"), "content-digest;sf"])
    headers["Signature-Input"].should contain(%("@query-param";name="resource"))
    headers["Signature-Input"].should contain(%("content-digest";sf))
    base.should contain(%("@query-param";name="resource": acct:alice@example.com))
    base.should contain(%("content-digest";sf: sha-256=:))
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, "https://remote.example/inbox?resource=acct%3Aalice%40example.com&x=1", key_pair, "structured", verify_options).should be_true
  end

  it "rejects RFC 9421 signatures with missing required components or expired params" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    body = %({"type":"Create"})
    weak_headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox",
      body,
      key_pair,
      Aptork::Rfc9421Options.new(
        components: ["@method", "content-digest"],
        key_id: key_pair.id,
        created: 1_718_888_000_i64
      )
    )
    weak_request = Aptork::Request.new("POST", "/inbox", headers: weak_headers, body: body)
    expired_headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox",
      body,
      key_pair,
      Aptork::Rfc9421Options.new(
        key_id: key_pair.id,
        created: 1_718_000_000_i64,
        expires: 1_718_000_100_i64
      )
    )
    expired_request = Aptork::Request.new("POST", "/inbox", headers: expired_headers, body: body)
    options = Aptork::Rfc9421VerifyOptions.new(now: 1_718_888_000_i64)

    Aptork::Signatures.verify_rfc9421_rsa_sha256?(weak_request, "https://remote.example/inbox", key_pair, options: options).should be_false
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(expired_request, "https://remote.example/inbox", key_pair, options: options).should be_false
  end

  it "rejects malformed RFC 9421 signature bytes without raising" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    body = %({"type":"Create"})
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox",
      body,
      key_pair
    )
    headers["Signature"] = "sig1=:not base64:"
    request = Aptork::Request.new("POST", "/inbox", headers: headers, body: body)

    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, "https://remote.example/inbox", key_pair).should be_false
  end

  it "rejects RFC 9421 signatures when the content digest is tampered" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://remote.example/inbox",
      %({"type":"Create"}),
      key_pair
    )
    request = Aptork::Request.new(
      "POST",
      "/inbox",
      headers: headers,
      body: %({"type":"Update"})
    )

    Aptork::Signatures.valid_content_digest?(request).should be_false
    Aptork::Signatures.verify_rfc9421_rsa_sha256?(request, key_pair).should be_false
  end

  it "verifies inbox POSTs with RFC 9421 HTTP Message Signatures" do
    remote_key = generate_rsa_test_key_pair("https://remote.example/users/bob")
    handled = false
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == remote_key.id ? remote_key : nil.as(Aptork::ActorKeyPair?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      remote_key.owner,
      Aptork.note("https://remote.example/notes/1", "Hi")
    )
    headers = Aptork::Signatures.rfc9421_rsa_sha256_headers(
      "post",
      "https://local.example/inbox",
      activity.to_json,
      remote_key
    )

    response = federation.handle(Aptork::Request.new(
      "POST",
      "/inbox",
      headers: headers,
      body: activity.to_json
    ))

    response.status.should eq(202)
    handled.should be_true
  end

  it "parses Cavage-style Signature headers and validates digest headers" do
    request = Aptork::Request.new(
      "POST",
      "/inbox",
      headers: {
        "Digest"    => Aptork::Signatures.digest_header(%({"type":"Create"})),
        "Signature" => %(keyId="https://example.com/users/alice#main-key",algorithm="rsa-sha256",headers="(request-target) digest",signature="YWJj"),
      },
      body: %({"type":"Create"})
    )

    params = Aptork::Signatures.parse_signature_header(request.headers["Signature"]).not_nil!

    params.key_id.should eq("https://example.com/users/alice#main-key")
    params.headers.should eq(["(request-target)", "digest"])
    Aptork::Signatures.valid_digest?(request).should be_true
    Aptork::Signatures.signing_string(request, params.headers).should eq("(request-target): post /inbox\ndigest: #{request.headers["Digest"]}")
  end

  it "canonicalizes JSON objects with stable key ordering" do
    left = Aptork::JsonMap{
      "b" => Aptork.json(2),
      "a" => Aptork.json({
        "z" => "last",
        "m" => ["one", "two"],
      }),
    }
    right = Aptork::JsonMap{
      "a" => Aptork.json({
        "m" => ["one", "two"],
        "z" => "last",
      }),
      "b" => Aptork.json(2),
    }

    Aptork::Signatures.canonical_json(left).should eq(Aptork::Signatures.canonical_json(right))
    Aptork::Signatures.canonical_json(left).should eq(%({"a":{"m":["one","two"],"z":"last"},"b":2}))
  end

  it "creates and verifies RSA object integrity proofs" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    object = Aptork.note(
      "https://local.example/notes/1",
      "Signed note",
      attributed_to: key_pair.owner
    )

    signed = Aptork::Signatures.attach_object_proof(
      object,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )
    proof = signed["proof"].as_h

    object.has_key?("proof").should be_false
    proof["type"].as_s.should eq("DataIntegrityProof")
    proof["cryptosuite"].as_s.should eq("jcs-rsa-sha256-2026")
    proof["verificationMethod"].as_s.should eq(key_pair.id)
    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
  end

  it "rejects tampered or incompatible object proofs" do
    key_pair = generate_rsa_test_key_pair("https://local.example/users/alice")
    object = Aptork.note("https://local.example/notes/1", "Signed note", attributed_to: key_pair.owner)
    signed = Aptork::Signatures.attach_object_proof(
      object,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )

    tampered = signed.dup
    tampered["content"] = Aptork.json("changed")
    unsupported = signed.dup
    unsupported_proof = signed["proof"].as_h.dup
    unsupported_proof["cryptosuite"] = Aptork.json("eddsa-jcs-2022")
    unsupported["proof"] = Aptork.json(unsupported_proof)

    Aptork::Signatures.verify_object_proof?(tampered, key_pair).should be_false
    Aptork::Signatures.verify_object_proof?(unsupported, key_pair).should be_false
  end

  it "creates multikey actor material for Ed25519 key pairs" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    key = Aptork.public_key(key_pair)

    key["type"].as_s.should eq("Multikey")
    key["controller"].as_s.should eq(key_pair.owner)
    key["publicKeyMultibase"].as_s.should start_with("z")

    public_key_pem = Aptork::Signatures.ed25519_public_key_pem_from_multibase(key["publicKeyMultibase"].as_s)
    public_key_pem.should eq(key_pair.public_key_pem)
  end

  it "creates and verifies Ed25519 object integrity proofs" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    object = Aptork.note(
      "https://local.example/notes/1",
      "Signed note",
      attributed_to: key_pair.owner
    )

    signed = Aptork::Signatures.attach_object_proof(
      object,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )
    proof = signed["proof"].as_h

    proof["type"].as_s.should eq("DataIntegrityProof")
    proof["cryptosuite"].as_s.should eq("eddsa-jcs-2022")
    proof["verificationMethod"].as_s.should eq(key_pair.id)
    proof["proofValue"].as_s.should start_with("z")
    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
  end

  it "verifies proof arrays when one Ed25519 proof is valid" do
    key_pair = generate_ed25519_test_key_pair("https://local.example/users/alice")
    object = Aptork.note("https://local.example/notes/1", "Signed note", attributed_to: key_pair.owner)
    signed = Aptork::Signatures.attach_object_proof(
      object,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )
    valid_proof = signed["proof"].as_h
    invalid_proof = valid_proof.dup
    invalid_proof["proofValue"] = Aptork.json("zBadProofValue")
    signed["proof"] = Aptork.json([invalid_proof, valid_proof])

    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
  end

  it "resolves Ed25519 proof keys from remote actor assertion methods" do
    key_pair = generate_ed25519_test_key_pair("https://remote.example/users/alice")
    key = Aptork.public_key(key_pair)
    actor = Aptork.actor(
      "Person",
      key_pair.owner,
      "alice",
      "https://remote.example/users/alice/inbox",
      "https://remote.example/users/alice/outbox",
      assertion_methods: [key]
    )
    hits = 0
    loader = ->(url : String) : Aptork::JsonMap? do
      hits += 1
      url == key_pair.owner ? actor : nil
    end
    cache = Aptork::MemoryKvStore.new

    resolved = Aptork::Remote.resolve_proof_key(key_pair.id, loader, cache).not_nil!
    cached = Aptork::Remote.resolve_proof_key(key_pair.id, ->(_url : String) { nil.as(Aptork::JsonMap?) }, cache).not_nil!

    resolved.id.should eq(key_pair.id)
    resolved.owner.should eq(key_pair.owner)
    resolved.public_key_pem.should eq(key_pair.public_key_pem)
    cached.public_key_pem.should eq(key_pair.public_key_pem)
    hits.should eq(1)
  end

  it "resolves Ed25519 proof keys from direct Multikey documents" do
    key_pair = generate_ed25519_test_key_pair("https://remote.example/users/alice")
    key = Aptork.public_key(key_pair)
    key["id"] = Aptork.json("https://remote.example/users/alice/keys/multikey-1")
    hits = 0
    loader = ->(url : String) : Aptork::JsonMap? do
      hits += 1
      url == "https://remote.example/users/alice/keys/multikey-1" ? key : nil
    end

    resolved = Aptork::Remote.resolve_proof_key("https://remote.example/users/alice/keys/multikey-1", loader).not_nil!

    resolved.id.should eq("https://remote.example/users/alice/keys/multikey-1")
    resolved.owner.should eq(key_pair.owner)
    hits.should eq(1)
  end

  it "accepts inbox POSTs with resolver-backed Ed25519 object proofs" do
    key_pair = generate_ed25519_test_key_pair("https://remote.example/users/alice")
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    handled = false
    federation.set_signature_key_resolver(->(key_id : String) do
      key_id == key_pair.id ? key_pair : nil.as(Aptork::ActorKeyPair?)
    end)
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      key_pair.owner,
      Aptork.note("https://remote.example/notes/1", "Hi", attributed_to: key_pair.owner)
    )
    signed = Aptork::Signatures.attach_object_proof(
      activity,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )

    response = federation.handle(proofless_activity_request(signed))

    response.status.should eq(202)
    handled.should be_true
  end

  it "rejects object proofs when nested attribution is not covered by a valid proof" do
    alice_key = generate_ed25519_test_key_pair("https://remote.example/users/alice")
    bob_key = generate_ed25519_test_key_pair("https://remote.example/users/bob")
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    handled = false
    federation.set_signature_key_resolver(->(key_id : String) do
      case key_id
      when alice_key.id
        alice_key
      when bob_key.id
        bob_key
      else
        nil.as(Aptork::ActorKeyPair?)
      end
    end)
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    ticket = Aptork.forgefed_ticket(
      "https://remote.example/tickets/1",
      "Bug",
      "Fix it",
      attributed_to: bob_key.owner
    )
    activity = Aptork.create(
      "https://remote.example/activities/create-ticket-1",
      alice_key.owner,
      ticket
    )
    alice_only = Aptork::Signatures.attach_object_proof(
      activity,
      alice_key,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )
    both = activity.dup
    both["proof"] = Aptork.json([
      Aptork::Signatures.create_object_proof(activity, alice_key, Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")),
      Aptork::Signatures.create_object_proof(activity, bob_key, Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")),
    ])

    rejected = federation.verify_inbox_request(proofless_activity_request(alice_only), alice_only)
    accepted = federation.verify_inbox_request(proofless_activity_request(both), both)
    response = federation.handle(proofless_activity_request(alice_only))

    rejected.verified.should be_false
    rejected.reason.should eq("object proof attribution mismatch")
    accepted.verified.should be_true
    response.status.should eq(401)
    response.body.should eq("object proof attribution mismatch")
    handled.should be_false
  end

  it "accepts inbox POSTs with remotely resolved Ed25519 object proofs" do
    key_pair = generate_ed25519_test_key_pair("https://remote.example/users/alice")
    key = Aptork.public_key(key_pair)
    actor = Aptork.actor(
      "Person",
      key_pair.owner,
      "alice",
      "https://remote.example/users/alice/inbox",
      "https://remote.example/users/alice/outbox",
      assertion_methods: [key]
    )
    loader_hits = 0
    loader = ->(url : String) : Aptork::JsonMap? do
      loader_hits += 1
      url == key_pair.owner ? actor : nil
    end
    cache = Aptork::MemoryKvStore.new
    federation = Aptork::Federation.create("https://local.example", kv: cache, document_loader: loader)
    configure_local_actor_dispatcher(federation)
    handled = false
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      key_pair.owner,
      Aptork.note("https://remote.example/notes/1", "Hi", attributed_to: key_pair.owner)
    )
    signed = Aptork::Signatures.attach_object_proof(
      activity,
      key_pair,
      Aptork::ObjectProofOptions.new(created: "2026-05-22T00:00:00Z")
    )

    response = federation.handle(proofless_activity_request(signed))

    response.status.should eq(202)
    handled.should be_true
    loader_hits.should eq(1)
  end

  it "rejects unsigned inbox POSTs when signature verification has no key resolver" do
    federation = Aptork::Federation.create("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/alice",
      Aptork.note("https://remote.example/notes/1", "Hi")
    )

    response = federation.handle(proofless_activity_request(activity))

    response.status.should eq(401)
    response.body.should eq("signature key resolver is not configured")
  end
end

describe "Aptork storage and queue helpers" do
  it "stores values in memory" do
    store = Aptork::MemoryKvStore.new
    store.set("actor:alice", "ok")

    store.get("actor:alice").should eq("ok")
    store.delete("actor:alice")
    store.get("actor:alice").should be_nil
  end

  it "lists memory KV values by prefix" do
    store = Aptork::MemoryKvStore.new
    store.set("actor:alice", "alice")
    store.set("actor:bob", "bob")
    store.set("object:note", "note")

    entries = store.list("actor:")

    entries.map(&.key).should eq(["actor:alice", "actor:bob"])
    entries.map(&.value).should eq(["alice", "bob"])
  end

  it "compares and swaps memory KV values" do
    store = Aptork::MemoryKvStore.new

    store.cas("lock:actor", nil, "alice").should be_true
    store.cas("lock:actor", nil, "bob").should be_false
    store.get("lock:actor").should eq("alice")
    store.cas("lock:actor", "alice", "bob").should be_true
    store.get("lock:actor").should eq("bob")
  end

  it "queues JSON messages in process" do
    queue = Aptork::InProcessMessageQueue.new
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"), Aptork::EnqueueOptions.new(ordering_key: "alice"))

    drained = queue.drain("outbox")

    drained.size.should eq(1)
    drained.first.payload["type"].as_s.should eq("Note")
    drained.first.ordering_key.should eq("alice")
    queue.messages.empty?.should be_true
  end

  it "batch-enqueues JSON messages in process" do
    queue = Aptork::InProcessMessageQueue.new
    payloads = [
      Aptork.object("Note", "https://local.example/notes/1"),
      Aptork.object("Note", "https://local.example/notes/2"),
    ]

    queue.enqueue_many("outbox", payloads, Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 10), ordering_key: "alice"))

    queue.depth("outbox").should eq(2)
    queue.ready("outbox", Time.utc + Time::Span.new(seconds: 1)).should be_empty
    ready = queue.ready("outbox", Time.utc + Time::Span.new(seconds: 20))
    ready.map { |message| message.payload["id"].as_s }.should eq(["https://local.example/notes/1", "https://local.example/notes/2"])
    ready.map(&.ordering_key).should eq(["alice", "alice"])
  end

  it "stores Redis KV values with namespacing and TTL" do
    client = FakeRedisCommandClient.new
    store = Aptork::RedisKvStore.new(client, "app")

    store.set("actor:alice", "ok", Time::Span.new(seconds: 5))
    store.get("actor:alice").should eq("ok")
    store.delete("actor:alice")
    store.get("actor:alice").should be_nil

    client.commands[0].should eq(["SET", "app:kv:actor:alice", "ok", "PX", "5000"])
    client.commands[1].should eq(["GET", "app:kv:actor:alice"])
    client.commands[2].should eq(["DEL", "app:kv:actor:alice"])
  end

  it "lists Redis KV values by prefix" do
    client = FakeRedisCommandClient.new
    store = Aptork::RedisKvStore.new(client, "app")
    store.set("actor:alice", "alice")
    store.set("actor:bob", "bob")
    store.set("object:note", "note")

    entries = store.list("actor:")

    entries.map(&.key).should eq(["actor:alice", "actor:bob"])
    entries.map(&.value).should eq(["alice", "bob"])
    client.commands.any? { |command| command == ["KEYS", "app:kv:actor:*"] }.should be_true
  end

  it "compares and swaps Redis KV values atomically" do
    client = FakeRedisCommandClient.new
    store = Aptork::RedisKvStore.new(client, "app")

    store.cas("lock:actor", nil, "alice").should be_true
    store.cas("lock:actor", nil, "bob").should be_false
    store.get("lock:actor").should eq("alice")
    store.cas("lock:actor", "alice", "bob", Time::Span.new(nanoseconds: 2_500_000_000)).should be_true
    store.cas("lock:actor", "alice", "cara").should be_false
    store.get("lock:actor").should eq("bob")

    client.commands.any? do |command|
      command[0] == "EVAL" &&
        command[3] == "app:kv:lock:actor" &&
        command[4] == "1" &&
        command[5] == "alice" &&
        command[6] == "2500" &&
        command[7] == "bob"
    end.should be_true
  end

  it "queues Redis messages with delay and persisted ordering metadata" do
    client = FakeRedisCommandClient.new
    queue = Aptork::RedisMessageQueue.new(client, "app")
    payload = Aptork.object("Note", "https://local.example/notes/redis")

    queue.enqueue(
      "outbox",
      payload,
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 10), ordering_key: "alice")
    )

    queue.depth("outbox").should eq(1)
    queue.ready("outbox", Time.utc + Time::Span.new(seconds: 1)).should be_empty
    ready = queue.ready("outbox", Time.utc + Time::Span.new(seconds: 20), limit: 10)

    ready.size.should eq(1)
    ready.first.payload["id"].as_s.should eq("https://local.example/notes/redis")
    ready.first.ordering_key.should eq("alice")
  end

  it "batch-enqueues Redis messages with delay and ordering metadata" do
    client = FakeRedisCommandClient.new
    queue = Aptork::RedisMessageQueue.new(client, "app")
    payloads = [
      Aptork.object("Note", "https://local.example/notes/redis-1"),
      Aptork.object("Note", "https://local.example/notes/redis-2"),
    ]

    queue.enqueue_many(
      "outbox",
      payloads,
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 10), ordering_key: "alice")
    )

    queue.depth("outbox").should eq(2)
    queue.ready("outbox", Time.utc + Time::Span.new(seconds: 1), limit: 10).should be_empty
    ready = queue.ready("outbox", Time.utc + Time::Span.new(seconds: 20), limit: 10)
    ready.map { |message| message.payload["id"].as_s }.sort.should eq(["https://local.example/notes/redis-1", "https://local.example/notes/redis-2"])
    ready.map(&.ordering_key).should eq(["alice", "alice"])
  end

  it "reports Redis queue depth with ready and delayed counts" do
    client = FakeRedisCommandClient.new
    queue = Aptork::RedisMessageQueue.new(client, "app")
    now = Time.utc + Time::Span.new(seconds: 1)

    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/ready"))
    queue.enqueue(
      "outbox",
      Aptork.object("Note", "https://local.example/notes/delayed"),
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 30))
    )
    queue.enqueue("inbox", Aptork.object("Note", "https://local.example/notes/other"))

    depth = queue.get_depth("outbox", now)

    depth.queued.should eq(2)
    depth.ready.should eq(1)
    depth.delayed.should eq(1)
  end

  it "processes Redis queued messages and retries failures" do
    client = FakeRedisCommandClient.new
    queue = Aptork::RedisMessageQueue.new(client, "app")
    policy = Aptork::RetryPolicy.new(max_attempts: 2, initial_delay: Time::Span.new(seconds: 1))
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/redis-process"))

    first = queue.process_one("outbox", policy, Time.utc + Time::Span.new(seconds: 1)) do |message|
      message.attempts.should eq(0)
      raise "temporary"
    end
    second = queue.process_one("outbox", policy, Time.utc + Time::Span.new(seconds: 3)) do |message|
      message.attempts.should eq(1)
      nil
    end

    first.should eq(Aptork::QueueProcessResult::Retried)
    second.should eq(Aptork::QueueProcessResult::Processed)
    queue.depth("outbox").should eq(0)
  end

  it "supports delayed enqueue, queue depth, ready filtering, and listen loop processing" do
    queue = Aptork::InProcessMessageQueue.new
    now = Time.utc + Time::Span.new(seconds: 1)
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"))
    queue.enqueue(
      "outbox",
      Aptork.object("Note", "https://local.example/notes/2"),
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 30), ordering_key: "alice")
    )

    processed = 0
    results = queue.listen("outbox", now: now) do |_message|
      processed += 1
      nil
    end

    queue.depth("outbox").should eq(1)
    queue.ready("outbox", now).size.should eq(0)
    results.should eq([Aptork::QueueProcessResult::Processed])
    processed.should eq(1)
    queue.native_retrial?.should be_false
  end

  it "reports in-process queue depth with ready and delayed counts" do
    queue = Aptork::InProcessMessageQueue.new
    now = Time.utc + Time::Span.new(seconds: 1)

    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/ready"))
    queue.enqueue(
      "outbox",
      Aptork.object("Note", "https://local.example/notes/delayed"),
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 30))
    )
    queue.enqueue("inbox", Aptork.object("Note", "https://local.example/notes/other"))

    depth = queue.get_depth("outbox", now)

    depth.queued.should eq(2)
    depth.ready.should eq(1)
    depth.delayed.should eq(1)
  end

  it "retries failed queued messages with backoff and dead-letters after max attempts" do
    queue = Aptork::InProcessMessageQueue.new
    policy = Aptork::RetryPolicy.new(
      max_attempts: 2,
      initial_delay: Time::Span.new(seconds: 5),
      multiplier: 2.0
    )
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"))
    now = Time.utc + Time::Span.new(seconds: 1)

    first = queue.process_one("outbox", policy, now) do |_message|
      raise "temporary failure"
    end
    second = queue.process_one("outbox", policy, now + Time::Span.new(seconds: 5)) do |_message|
      raise "permanent failure"
    end

    first.should eq(Aptork::QueueProcessResult::Retried)
    second.should eq(Aptork::QueueProcessResult::Dead)
    queue.dead_messages.size.should eq(1)
    queue.dead_messages.first.attempts.should eq(2)
  end
end

describe "Aptork SQL-backed storage" do
  it "stores, reads, and deletes KV values" do
    store = Aptork::SqlKvStore.new(FakeSqlConnection.new)

    store.set("actor:alice", "ok")
    store.get("actor:alice").should eq("ok")
    store.delete("actor:alice")
    store.get("actor:alice").should be_nil
  end

  it "expires KV values past their TTL on read" do
    store = Aptork::SqlKvStore.new(FakeSqlConnection.new)

    store.set("temp", "value", ttl: 5.milliseconds)
    store.get("temp").should eq("value")
    sleep 20.milliseconds
    store.get("temp").should be_nil
  end

  it "lists KV values by prefix in key order" do
    store = Aptork::SqlKvStore.new(FakeSqlConnection.new)
    store.set("actor:bob", "bob")
    store.set("actor:alice", "alice")
    store.set("object:note", "note")

    entries = store.list("actor:")

    entries.map(&.key).should eq(["actor:alice", "actor:bob"])
    entries.map(&.value).should eq(["alice", "bob"])
  end

  it "compares and swaps KV values atomically" do
    store = Aptork::SqlKvStore.new(FakeSqlConnection.new)

    store.cas("lock:actor", nil, "alice").should be_true
    store.cas("lock:actor", nil, "bob").should be_false
    store.get("lock:actor").should eq("alice")
    store.cas("lock:actor", "alice", "bob").should be_true
    store.cas("lock:actor", "alice", "carol").should be_false
    store.get("lock:actor").should eq("bob")
  end

  it "enqueues and processes SQL queue messages" do
    queue = Aptork::SqlMessageQueue.new(FakeSqlConnection.new)
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"))
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/2"))

    queue.depth("outbox").should eq(2)

    processed = [] of String
    result = queue.process_one("outbox") { |message| processed << message.payload["id"].as_s }

    result.should eq(Aptork::QueueProcessResult::Processed)
    processed.should eq(["https://local.example/notes/1"])
    queue.depth("outbox").should eq(1)
  end

  it "honors delayed availability for SQL queue messages" do
    queue = Aptork::SqlMessageQueue.new(FakeSqlConnection.new)
    queue.enqueue(
      "outbox",
      Aptork.object("Note", "https://local.example/notes/delayed"),
      Aptork::EnqueueOptions.new(delay: Time::Span.new(seconds: 30))
    )

    now = Time.utc
    depth = queue.get_depth("outbox", now)
    depth.queued.should eq(1)
    depth.ready.should eq(0)
    depth.delayed.should eq(1)
    queue.ready("outbox", now).should be_empty
    queue.ready("outbox", now + Time::Span.new(seconds: 31)).size.should eq(1)
  end

  it "retries failed SQL queue messages and dead-letters after max attempts" do
    queue = Aptork::SqlMessageQueue.new(FakeSqlConnection.new)
    policy = Aptork::RetryPolicy.new(max_attempts: 2, initial_delay: Time::Span.new(seconds: 5))
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"))
    now = Time.utc

    first = queue.process_one("outbox", policy, now) { |_m| raise "temporary failure" }
    second = queue.process_one("outbox", policy, now + Time::Span.new(seconds: 6)) { |_m| raise "permanent failure" }

    first.should eq(Aptork::QueueProcessResult::Retried)
    second.should eq(Aptork::QueueProcessResult::Dead)

    dead = queue.dead_messages("outbox")
    dead.size.should eq(1)
    dead.first.attempts.should eq(2)
  end

  it "rewrites placeholders for the Postgres dialect" do
    sql = "/* aptork:kv_set */ INSERT INTO aptork_kv (k, v, expires_at) VALUES (?, ?, ?)"
    prepared = Aptork::SqlStatements.prepare(sql, Aptork::SqlDialect::Postgres)
    prepared.should contain("VALUES ($1, $2, $3)")

    Aptork::SqlStatements.prepare(sql, Aptork::SqlDialect::Sqlite).should eq(sql)
  end
end

describe "Aptork::MetricsTelemetry" do
  it "aggregates counters with labels" do
    telemetry = Aptork::MetricsTelemetry.new
    telemetry.counter("inbox.received", attributes: {"type" => "Create"})
    telemetry.counter("inbox.received", 2_i64, attributes: {"type" => "Create"})
    telemetry.counter("inbox.received", attributes: {"type" => "Follow"})

    telemetry.counter_value("inbox.received", {"type" => "Create"}).should eq(3_i64)
    telemetry.counter_value("inbox.received", {"type" => "Follow"}).should eq(1_i64)
    telemetry.counter_value("inbox.received").should eq(0_i64)
  end

  it "tracks gauges and histograms" do
    telemetry = Aptork::MetricsTelemetry.new
    telemetry.gauge("queue.depth", 5.0)
    telemetry.gauge("queue.depth", 3.0)
    telemetry.gauge_value("queue.depth").should eq(3.0)

    telemetry.histogram("delivery.duration_ms", 4.0)
    telemetry.histogram("delivery.duration_ms", 80.0)
    data = telemetry.histogram_data("delivery.duration_ms").not_nil!
    data.count.should eq(2_i64)
    data.sum.should eq(84.0)
    # Bucket for le=5.0 should only contain the 4.0 observation.
    index = data.buckets.index(5.0).not_nil!
    data.counts[index].should eq(1_i64)
  end

  it "records span timings as a counter and a duration histogram" do
    telemetry = Aptork::MetricsTelemetry.new
    telemetry.span("delivery.send") { }

    telemetry.counter_value("delivery.send.spans").should eq(1_i64)
    telemetry.histogram_data("delivery.send.duration_ms").not_nil!.count.should eq(1_i64)
  end

  it "renders the OpenMetrics text exposition format" do
    telemetry = Aptork::MetricsTelemetry.new
    telemetry.counter("inbox.received", attributes: {"type" => "Create"})
    telemetry.gauge("queue.depth", 2.0)
    telemetry.histogram("delivery.duration_ms", 3.0)

    output = telemetry.to_openmetrics
    output.should contain(%(inbox_received_total{type="Create"} 1))
    output.should contain("queue_depth 2")
    output.should contain(%(delivery_duration_ms_bucket{le="+Inf"} 1))
    output.should contain("delivery_duration_ms_sum 3")
    output.should contain("delivery_duration_ms_count 1")
    telemetry.to_prometheus.should eq(output)
  end

  it "resets all collected metrics" do
    telemetry = Aptork::MetricsTelemetry.new
    telemetry.counter("inbox.received")
    telemetry.reset
    telemetry.counter_value("inbox.received").should eq(0_i64)
    telemetry.to_openmetrics.should eq("")
  end
end

describe "Aptork discovery helpers" do
  it "builds WebFinger JRD and NodeInfo documents" do
    jrd = Aptork.webfinger_jrd(
      "acct:alice@example.com",
      "https://example.com/users/alice"
    )
    nodeinfo = Aptork.nodeinfo("aptork", "0.1.0")

    jrd["subject"].as_s.should eq("acct:alice@example.com")
    jrd["links"].as_a.first.as_h["rel"].as_s.should eq("self")
    jrd["links"].as_a.first.as_h["type"].as_s.should eq("application/activity+json")
    nodeinfo["$schema"].as_s.should eq("http://nodeinfo.diaspora.software/ns/schema/2.1#")
    nodeinfo["protocols"].as_a.first.as_s.should eq("activitypub")
  end
end

describe "Aptork testing helpers" do
  it "generates RSA key pairs for signed request tests" do
    key_pair = Aptork::Testing.generate_rsa_key_pair("https://local.example/users/alice")
    custom_key_pair = Aptork::Testing.generate_rsa_key_pair(
      "https://local.example/users/alice",
      "https://local.example/keys/test-rsa"
    )
    body = "{}"
    headers = Aptork::Signatures.rsa_sha256_headers(
      "POST",
      "https://remote.example/inbox",
      body,
      key_pair
    )
    request = Aptork::Request.new("POST", "/inbox", headers: headers, body: body)

    key_pair.id.should eq("https://local.example/users/alice#main-key")
    key_pair.owner.should eq("https://local.example/users/alice")
    key_pair.algorithm.should eq("rsa-sha256")
    key_pair.public_key_pem.should contain("BEGIN PUBLIC KEY")
    key_pair.private_key_pem.to_s.should contain("BEGIN")
    custom_key_pair.id.should eq("https://local.example/keys/test-rsa")
    Aptork::Signatures.verify_rsa_sha256?(request, key_pair).should be_true
  end

  it "generates Ed25519 key pairs for object proof tests" do
    key_pair = Aptork::Testing.generate_ed25519_key_pair("https://local.example/users/alice")
    custom_key_pair = Aptork::Testing.generate_ed25519_key_pair(
      "https://local.example/users/alice",
      "https://local.example/keys/test-ed25519"
    )
    object = Aptork.note("https://local.example/notes/1", "Hello")
    signed = Aptork::Signatures.attach_object_proof(object, key_pair)

    key_pair.id.should eq("https://local.example/users/alice#multikey-1")
    key_pair.owner.should eq("https://local.example/users/alice")
    key_pair.algorithm.should eq("ed25519")
    key_pair.public_key_pem.should contain("BEGIN PUBLIC KEY")
    key_pair.private_key_pem.to_s.should contain("BEGIN PRIVATE KEY")
    custom_key_pair.id.should eq("https://local.example/keys/test-ed25519")
    Aptork.public_key(key_pair)["type"].as_s.should eq("Multikey")
    Aptork::Signatures.verify_object_proof?(signed, key_pair).should be_true
  end

  it "creates mock federation contexts with captured delivery" do
    federation = Aptork::Testing.create_federation("https://local.example")
    ctx = federation.create_context
    transport = federation.sent_activities

    note = Aptork.note("https://local.example/notes/1", "Hello")
    activity = Aptork.create("https://local.example/activities/1", ctx.get_actor_uri("alice"), note)
    recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")

    ctx.send_activity("alice", [recipient], activity)

    transport.size.should eq(1)
    transport.first.queued.should be_false
    transport.first.queue.should be_nil
    transport.first.sent_order.should eq(1)
    federation.sent_counter.should eq(1)
    federation.reset
    transport.should be_empty
  end

  it "creates outbox contexts for listener tests" do
    federation = Aptork::Testing.create_federation("https://local.example")
    request = Aptork::Request.new("POST", "/users/alice/outbox", body: "{}")

    ctx = Aptork::Testing.create_outbox_context(federation, "alice", request)

    ctx.outbox_identifier.should eq("alice")
    ctx.identifier.should eq("alice")
    ctx.inbound_request.should eq(request)
    ctx.has_delivered_activity?.should be_false
  end

  it "creates request and inbox contexts for listener tests" do
    federation = Aptork::Testing.create_federation("https://local.example")
    request = Aptork::Request.new("GET", "/users/alice", query: {"page" => "1"})
    inbox_request = Aptork::Request.new("POST", "/users/alice/inbox", body: "{}")
    shared_request = Aptork::Request.new("POST", "/inbox", body: "{}")

    request_ctx = Aptork::Testing.create_request_context(federation, request)
    inbox_ctx = Aptork::Testing.create_inbox_context(federation, "alice", inbox_request)
    shared_ctx = Aptork::Testing.create_inbox_context(federation, nil, shared_request)

    request_ctx.inbound_request.should eq(request)
    request_ctx.url.should eq("https://local.example/users/alice?page=1")
    inbox_ctx.recipient_identifier.should eq("alice")
    inbox_ctx.identifier.should eq("alice")
    inbox_ctx.inbound_request.should eq(inbox_request)
    shared_ctx.recipient_identifier.should be_nil
    shared_ctx.identifier.should be_nil
    shared_ctx.inbound_request.should eq(shared_request)
  end

  it "creates configurable mock contexts with data and loader overrides" do
    federation = Aptork::Testing.create_federation("https://local.example")
    request = Aptork::Request.new("GET", "/users/alice", query: {"view" => "debug"})
    document_loader = ->(url : String) do
      Aptork::JsonMap{"id" => Aptork.json("doc:#{url}")}.as(Aptork::JsonMap?)
    end
    context_loader = ->(url : String) do
      Aptork::JsonMap{"id" => Aptork.json("ctx:#{url}")}.as(Aptork::JsonMap?)
    end

    ctx = Aptork::Testing.create_context(
      federation,
      request,
      recipient_identifier: "alice",
      outbox_identifier: "alice",
      context_data: Aptork.json({"tenant" => "test"}),
      document_loader: document_loader,
      context_loader: context_loader
    )
    request_ctx = Aptork::Testing.create_request_context(
      federation,
      request,
      document_loader: document_loader
    )

    ctx.identifier.should eq("alice")
    ctx.recipient_identifier.should eq("alice")
    ctx.outbox_identifier.should eq("alice")
    ctx.url.should eq("https://local.example/users/alice?view=debug")
    ctx.data.not_nil!.as_h["tenant"].as_s.should eq("test")
    ctx.document_loader.call("https://remote.example/object").not_nil!["id"].as_s.should eq("doc:https://remote.example/object")
    ctx.context_loader.call("https://remote.example/context").not_nil!["id"].as_s.should eq("ctx:https://remote.example/context")
    request_ctx.document_loader.call("https://remote.example/other").not_nil!["id"].as_s.should eq("doc:https://remote.example/other")
  end

  it "posts inbox activities through registered listeners" do
    seen = [] of String
    tenants = [] of String
    federation = Aptork::Testing.create_federation("https://local.example")
    configure_local_actor_dispatcher(federation)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        seen << "#{ctx.recipient_identifier || "shared"}:#{activity["id"].as_s}"
        tenants << (ctx.data.try(&.as_h["tenant"]?.try(&.as_s?)) || "none")
        nil
      end)
    activity = Aptork.create(
      "https://remote.example/activities/1",
      "https://remote.example/users/bob",
      Aptork.note("https://remote.example/notes/1", "Hello")
    )

    personal = Aptork::Testing.receive_activity(federation, activity, "alice", context_data: Aptork.json({"tenant" => "alpha"}))
    shared = Aptork::Testing.post_inbox_activity(federation, activity)

    personal.status.should eq(202)
    shared.status.should eq(202)
    seen.should eq([
      "alice:https://remote.example/activities/1",
      "shared:https://remote.example/activities/1",
    ])
    tenants.should eq(["alpha", "none"])
  end

  it "posts outbox activities through registered listeners" do
    delivered = false
    delivered_before_send = [] of Bool
    delivered_after_send = [] of Bool
    tenants = [] of String
    federation = Aptork::Testing.create_federation("https://local.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier)
      ).as(Aptork::JsonMap?)
    end)
    federation.set_outbox_listeners("/users/{identifier}/outbox")
      .on("Create", ->(ctx : Aptork::Context, activity : Aptork::JsonMap) do
        delivered = ctx.outbox_identifier == "alice"
        tenants << (ctx.data.try(&.as_h["tenant"]?.try(&.as_s?)) || "none")
        delivered_before_send << ctx.has_delivered_activity?
        recipient = Aptork::Recipient.new("https://remote.example/users/bob", "https://remote.example/inbox")
        sending_ctx = ctx.with_inbound_request(ctx.inbound_request)
        sending_ctx.send_activity("alice", [recipient], activity)
        delivered_after_send << ctx.has_delivered_activity?
        nil
      end)
    activity = Aptork.create(
      "https://local.example/activities/1",
      "https://local.example/users/alice",
      Aptork.note("https://local.example/notes/1", "Hello")
    )

    response = Aptork::Testing.post_outbox_activity(federation, "alice", activity, context_data: Aptork.json({"tenant" => "alpha"}))
    mismatch = Aptork::Testing.post_outbox_activity(federation, "bob", activity)

    response.status.should eq(202)
    delivered.should be_true
    tenants.should eq(["alpha"])
    delivered_before_send.should eq([false])
    delivered_after_send.should eq([true])
    federation.sent_activities.size.should eq(1)
    federation.sent_activities.first.sender_identifier.should eq("alice")
    mismatch.status.should eq(400)
    mismatch.body.should eq("The activity actor does not match the outbox owner.")
  end
end

describe Aptork::RouteTemplate do
  it "matches and expands simple identifier templates" do
    template = Aptork::RouteTemplate.new("/users/{identifier}")
    template.match("/users/alice").should eq({"identifier" => "alice"})
    template.expand({"identifier" => "alice"}).should eq("/users/alice")
  end

  it "preserves a literal plus in a path segment when matching" do
    # In a URL path a raw '+' is a literal character (RFC 3986 sub-delim), not a
    # space as in application/x-www-form-urlencoded query strings. Matching must
    # not turn '/users/c+lang' into the identifier 'c lang'.
    template = Aptork::RouteTemplate.new("/users/{identifier}")
    template.match("/users/c+lang").should eq({"identifier" => "c+lang"})
  end

  it "round-trips identifiers containing reserved characters through expand/match" do
    template = Aptork::RouteTemplate.new("/users/{identifier}")
    ["c+lang", "a b", "résumé"].each do |identifier|
      path = template.expand({"identifier" => identifier})
      template.match(path).should eq({"identifier" => identifier})
    end
  end

  it "decodes percent-encoded spaces but keeps literal plus in trailing captures" do
    template = Aptork::RouteTemplate.new("/files/{+path}")
    template.match("/files/a+b/c%20d").should eq({"path" => "a+b/c d"})
  end
end
