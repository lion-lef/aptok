require "./spec_helper"

private RELAY_ORIGIN = "https://relay.example"

# Build a relay harness backed by an in-memory subscription store and a transport
# that captures every delivery as {inbox_url, payload} instead of hitting the
# network. The subscription registry is reachable through `server.subscriptions`.
private def build_relay(relay_id : String, sender : String = "relay")
  deliveries = [] of Tuple(String, String)
  transport = Aptok::Transport.new(
    signature_enabled: false,
    post_provider: ->(url : String, _headers : HTTP::Headers, body : String) do
      deliveries << {url, body}
      {202, "ok"}
    end
  )
  federation = Aptok::Federation.create(RELAY_ORIGIN, transport)
  subscriptions = Aptok::Relay::Subscriptions.new(Aptok::MemoryKvStore.new, relay_id)
  {
    ctx:        federation.create_context,
    server:     Aptok::Relay::Server.new(relay_id, sender, subscriptions),
    deliveries: deliveries,
  }
end

private def person(id : String, host : String) : Aptok::JsonMap
  Aptok.actor("Person", id, "user", "#{host}/inbox", "#{host}/outbox")
end

describe Aptok::Relay do
  describe "subscription builders" do
    it "builds a Mastodon-style Follow targeting the public collection" do
      relay = "https://relay.example/actor"
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", relay)

      follow["type"].as_s.should eq("Follow")
      follow["actor"].as_s.should eq("https://news.example/actor")
      follow["object"].as_s.should eq(Aptok::PUBLIC_COLLECTION)
      follow["to"].as_a.map(&.as_s).should eq([relay])

      Aptok::Relay.subscription_protocol(follow, relay).should eq(Aptok::Relay::Protocol::Mastodon)
      Aptok::Relay.subscription?(follow, relay).should be_true
      Aptok::Relay.follower(follow).should eq("https://news.example/actor")
    end

    it "builds a LitePub-style Follow targeting the relay actor" do
      relay = "https://relay.example/relay"
      follow = Aptok::Relay.subscribe(
        "https://pleroma.example/follow/1",
        "https://pleroma.example/relay",
        relay,
        Aptok::Relay::Protocol::LitePub
      )

      follow["object"].as_s.should eq(relay)
      follow["to"].as_a.map(&.as_s).should eq([relay])
      Aptok::Relay.subscription_protocol(follow, relay).should eq(Aptok::Relay::Protocol::LitePub)
    end

    it "does not classify a Follow of an unrelated object as a subscription" do
      relay = "https://relay.example/actor"
      follow = Aptok.follow("https://news.example/follow/1", "https://news.example/actor", "https://news.example/other")

      Aptok::Relay.subscription_protocol(follow, relay).should be_nil
      Aptok::Relay.subscription?(follow, relay).should be_false
    end

    it "builds an Undo wrapping the original Follow for unsubscription" do
      relay = "https://relay.example/actor"
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", relay)
      undo = Aptok::Relay.unsubscribe("https://news.example/undo/1", "https://news.example/actor", follow, relay)

      undo["type"].as_s.should eq("Undo")
      undo["actor"].as_s.should eq("https://news.example/actor")
      undo["object"].as_h["type"].as_s.should eq("Follow")
      undo["to"].as_a.map(&.as_s).should eq([relay])

      Aptok::Relay.unsubscription?(undo).should be_true
      Aptok::Relay.unfollower(undo).should eq("https://news.example/actor")
    end

    it "infers the relay address from an embedded Follow when undoing" do
      relay = "https://relay.example/relay"
      follow = Aptok::Relay.subscribe(
        "https://pleroma.example/follow/1",
        "https://pleroma.example/relay",
        relay,
        Aptok::Relay::Protocol::LitePub
      )
      undo = Aptok::Relay.unsubscribe("https://pleroma.example/undo/1", "https://pleroma.example/relay", follow)

      undo["to"].as_a.map(&.as_s).should eq([relay])
    end

    it "accepts a bare Follow URI as an unsubscription" do
      undo = Aptok.undo("https://news.example/undo/1", "https://news.example/actor", "https://news.example/follow/1")

      Aptok::Relay.unsubscription?(undo).should be_true
      Aptok::Relay.unfollower(undo).should eq("https://news.example/actor")
    end

    it "builds a LitePub publish Announce addressed to the relay followers" do
      announce = Aptok::Relay.announce(
        "https://pleroma.example/announce/1",
        "https://pleroma.example/relay",
        "https://pleroma.example/objects/1",
        "https://relay.example/relay/followers",
        admin: "https://relay.example/admin"
      )

      announce["type"].as_s.should eq("Announce")
      announce["object"].as_s.should eq("https://pleroma.example/objects/1")
      announce["to"].as_a.map(&.as_s).should eq([
        "https://relay.example/relay/followers",
        "https://relay.example/admin",
      ])
      announce.has_key?("published").should be_true
    end
  end

  describe "relay server actor" do
    it "builds an Application actor with the required relay endpoints" do
      actor = Aptok::Relay.actor(
        "https://relay.example/actor",
        "relay",
        "https://relay.example/inbox",
        "https://relay.example/outbox",
        "https://relay.example/followers"
      )

      actor["type"].as_s.should eq("Application")
      actor["followers"].as_s.should eq("https://relay.example/followers")
      actor["inbox"].as_s.should eq("https://relay.example/inbox")
    end

    it "builds a portable FEP-ef61 relay actor with gateways" do
      relay_id = Aptok.ap_uri("did:key:zrelay", "/relay")
      actor = Aptok::Relay.actor(
        relay_id,
        "relay",
        Aptok.ap_uri("did:key:zrelay", "/relay/inbox"),
        Aptok.ap_uri("did:key:zrelay", "/relay/outbox"),
        Aptok.ap_uri("did:key:zrelay", "/relay/followers"),
        gateways: ["https://gw.example"]
      )

      actor["@context"].as_a.map(&.as_s).should contain(Aptok::FEP_EF61_CONTEXT)
      actor["gateways"].as_a.map(&.as_s).should eq(["https://gw.example"])
    end
  end

  describe "relayable classification" do
    it "marks content activities as relayable" do
      %w[Create Update Delete Move Announce].each do |type|
        activity = Aptok.activity(type, "https://a.example/activities/1", "https://a.example/actor", "https://a.example/objects/1")
        Aptok::Relay.relayable?(activity).should be_true
      end
    end

    it "does not relay control or social activities" do
      %w[Follow Like Accept Undo].each do |type|
        activity = Aptok.activity(type, "https://a.example/activities/1", "https://a.example/actor", "https://a.example/objects/1")
        Aptok::Relay.relayable?(activity).should be_false
      end
    end
  end

  describe ".fanout_recipients" do
    it "excludes the origin actor and de-duplicates by inbox" do
      origin = Aptok::Recipient.new("https://a.example/actor", "https://a.example/inbox")
      other = Aptok::Recipient.new("https://b.example/actor", "https://b.example/inbox")
      duplicate = Aptok::Recipient.new("https://c.example/actor", "https://b.example/inbox")

      targets = Aptok::Relay.fanout_recipients([origin, other, duplicate], "https://a.example/actor")

      targets.map(&.inbox).should eq(["https://b.example/inbox"])
    end

    it "excludes a portable origin regardless of the URI form used" do
      canonical = Aptok.ap_uri("did:key:zsubscriber", "/actor")
      hinted = Aptok.ap_uri("did:key:zsubscriber", "/actor", gateways: ["https://gw.example"])
      portable = Aptok::Recipient.new(canonical, "https://gw.example/.well-known/apgateway/did:key:zsubscriber/actor/inbox", [canonical])
      classic = Aptok::Recipient.new("https://b.example/actor", "https://b.example/inbox")

      targets = Aptok::Relay.fanout_recipients([portable, classic], hinted)

      targets.map(&.id).should eq(["https://b.example/actor"])
    end
  end

  describe Aptok::Relay::Subscriptions do
    it "registers, lists and removes subscribers" do
      subs = Aptok::Relay::Subscriptions.new(Aptok::MemoryKvStore.new, "https://relay.example/actor")
      actor = person("https://a.example/actor", "https://a.example")

      recipient = subs.add(actor).not_nil!
      recipient.id.should eq("https://a.example/actor")
      recipient.inbox.should eq("https://a.example/inbox")
      subs.subscribed?("https://a.example/actor").should be_true
      subs.size.should eq(1)
      subs.actor_ids.should eq(["https://a.example/actor"])

      subs.remove("https://a.example/actor").should be_true
      subs.subscribed?("https://a.example/actor").should be_false
      subs.size.should eq(0)
    end

    it "returns nil when an actor lacks a deliverable inbox" do
      subs = Aptok::Relay::Subscriptions.new(Aptok::MemoryKvStore.new, "https://relay.example/actor")
      subs.add(Aptok::JsonMap{"id" => Aptok.json("https://a.example/actor")}).should be_nil
    end

    it "matches portable subscribers across equivalent URI forms" do
      subs = Aptok::Relay::Subscriptions.new(Aptok::MemoryKvStore.new, "https://relay.example/actor")
      hinted = Aptok.ap_uri("did:key:zsubscriber", "/actor", gateways: ["https://gw.example"])
      portable = Aptok.actor(
        "Person",
        hinted,
        "sub",
        Aptok.ap_uri("did:key:zsubscriber", "/actor/inbox"),
        Aptok.ap_uri("did:key:zsubscriber", "/actor/outbox"),
        gateways: ["https://gw.example"]
      )

      expected_inbox = Aptok.ap_gateway_url("https://gw.example", Aptok.ap_uri("did:key:zsubscriber", "/actor/inbox"))
      recipient = subs.add(portable).not_nil!
      recipient.inbox.should eq(expected_inbox)

      canonical = Aptok.ap_uri("did:key:zsubscriber", "/actor")
      subs.subscribed?(canonical).should be_true
      # Unsubscribing via the equivalent gateway URL still resolves to the same
      # canonical subscriber.
      subs.remove(Aptok.ap_gateway_url("https://gw.example", canonical)).should be_true
      subs.subscribed?(canonical).should be_false
    end

    it "tracks relayed activity ids for de-duplication" do
      subs = Aptok::Relay::Subscriptions.new(Aptok::MemoryKvStore.new, "https://relay.example/actor")
      subs.relayed?("https://a.example/activities/1").should be_false
      subs.mark_relayed("https://a.example/activities/1")
      subs.relayed?("https://a.example/activities/1").should be_true
    end

    it "scopes subscribers to each relay sharing a store" do
      store = Aptok::MemoryKvStore.new
      relay_a = Aptok::Relay::Subscriptions.new(store, "https://relay-a.example/actor")
      relay_b = Aptok::Relay::Subscriptions.new(store, "https://relay-b.example/actor")
      relay_a.add(person("https://a.example/actor", "https://a.example"))

      relay_a.size.should eq(1)
      relay_b.size.should eq(0)
    end
  end

  describe Aptok::Relay::Server do
    it "registers a Mastodon follower and sends an Accept" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      follower = person("https://news.example/actor", "https://news.example")
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", "https://relay.example/actor")

      result = server.subscribe(h[:ctx], follower, follow, Aptok::Relay::Protocol::Mastodon)

      result.subscribed?.should be_true
      result.protocol.should eq(Aptok::Relay::Protocol::Mastodon)
      result.sent.size.should eq(1)
      server.subscriptions.subscribed?("https://news.example/actor").should be_true

      h[:deliveries].size.should eq(1)
      url, body = h[:deliveries].first
      url.should eq("https://news.example/inbox")
      accept = JSON.parse(body)
      accept["type"].as_s.should eq("Accept")
      accept["object"].as_h["id"].as_s.should eq("https://news.example/follow/1")
    end

    it "registers a LitePub follower and sends an Accept plus a reciprocal Follow" do
      h = build_relay("https://relay.example/relay")
      server = h[:server]
      follower = person("https://pleroma.example/relay", "https://pleroma.example")
      follow = Aptok::Relay.subscribe(
        "https://pleroma.example/follow/1",
        "https://pleroma.example/relay",
        "https://relay.example/relay",
        Aptok::Relay::Protocol::LitePub
      )

      result = server.subscribe(h[:ctx], follower, follow, Aptok::Relay::Protocol::LitePub)

      result.subscribed?.should be_true
      result.sent.size.should eq(2)
      types = h[:deliveries].map { |(_url, body)| JSON.parse(body)["type"].as_s }
      types.sort.should eq(["Accept", "Follow"])
    end

    it "resolves the follower actor via lookup when not embedded" do
      h = build_relay("https://relay.example/actor")
      follower = person("https://news.example/actor", "https://news.example")
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", "https://relay.example/actor")
      loader = ->(url : String) : Aptok::JsonMap? do
        url == "https://news.example/actor" ? follower : nil
      end

      result = h[:server].handle(h[:ctx], follow, Aptok::LookupObjectOptions.new(document_loader: loader))

      result.subscribed?.should be_true
      h[:server].subscriptions.subscribed?("https://news.example/actor").should be_true
    end

    it "reports an unresolvable follower when the actor cannot be fetched" do
      h = build_relay("https://relay.example/actor")
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", "https://relay.example/actor")
      loader = ->(_url : String) : Aptok::JsonMap? { nil }

      result = h[:server].handle(h[:ctx], follow, Aptok::LookupObjectOptions.new(document_loader: loader))

      result.outcome.should eq(Aptok::Relay::Outcome::Unresolvable)
      h[:server].subscriptions.size.should eq(0)
    end

    it "removes a subscriber on Undo" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      server.subscriptions.add(person("https://news.example/actor", "https://news.example"))
      follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", "https://relay.example/actor")
      undo = Aptok::Relay.unsubscribe("https://news.example/undo/1", "https://news.example/actor", follow, "https://relay.example/actor")

      result = server.handle(h[:ctx], undo)

      result.unsubscribed?.should be_true
      server.subscriptions.subscribed?("https://news.example/actor").should be_false
    end

    it "fans content out to every subscriber except the origin" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      server.subscriptions.add(person("https://a.example/actor", "https://a.example"))
      server.subscriptions.add(person("https://b.example/actor", "https://b.example"))
      activity = Aptok.create(
        "https://a.example/activities/1",
        "https://a.example/actor",
        Aptok.note("https://a.example/notes/1", "Hello")
      )

      sent = server.relay(h[:ctx], activity)

      sent.size.should eq(1)
      h[:deliveries].map(&.first).should eq(["https://b.example/inbox"])
    end

    it "forwards the activity unchanged, preserving an existing LD signature" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      server.subscriptions.add(person("https://b.example/actor", "https://b.example"))
      activity = Aptok.create(
        "https://a.example/activities/1",
        "https://a.example/actor",
        Aptok.note("https://a.example/notes/1", "Hello")
      )
      activity["signature"] = Aptok.json({
        "type"           => "RsaSignature2017",
        "creator"        => "https://a.example/actor#main-key",
        "signatureValue" => "Zm9vYmFy",
      })

      server.relay(h[:ctx], activity)

      forwarded = JSON.parse(h[:deliveries].first[1])
      forwarded["signature"].as_h["type"].as_s.should eq("RsaSignature2017")
      forwarded["id"].as_s.should eq("https://a.example/activities/1")
    end

    it "does not relay the same activity twice" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      server.subscriptions.add(person("https://b.example/actor", "https://b.example"))
      activity = Aptok.create(
        "https://a.example/activities/1",
        "https://a.example/actor",
        Aptok.note("https://a.example/notes/1", "Hello")
      )

      server.relay(h[:ctx], activity).size.should eq(1)
      server.relay(h[:ctx], activity).size.should eq(0)
      h[:deliveries].size.should eq(1)
    end

    it "ignores non-relayable activities" do
      h = build_relay("https://relay.example/actor")
      h[:server].subscriptions.add(person("https://b.example/actor", "https://b.example"))
      like = Aptok.like("https://a.example/activities/1", "https://a.example/actor", "https://a.example/objects/1")

      h[:server].relay(h[:ctx], like).should be_empty
      h[:deliveries].should be_empty
    end

    it "relays to and excludes portable FEP-ef61 subscribers through their gateway" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      portable = Aptok.actor(
        "Person",
        Aptok.ap_uri("did:key:zsubscriber", "/actor"),
        "sub",
        Aptok.ap_uri("did:key:zsubscriber", "/actor/inbox"),
        Aptok.ap_uri("did:key:zsubscriber", "/actor/outbox"),
        gateways: ["https://gw.example"]
      )
      server.subscriptions.add(portable)

      # A classic origin fans out to the portable subscriber via its gateway URL.
      classic_activity = Aptok.create(
        "https://a.example/activities/1",
        "https://a.example/actor",
        Aptok.note("https://a.example/notes/1", "Hello")
      )
      server.relay(h[:ctx], classic_activity)
      expected_inbox = Aptok.ap_gateway_url("https://gw.example", Aptok.ap_uri("did:key:zsubscriber", "/actor/inbox"))
      h[:deliveries].map(&.first).should eq([expected_inbox])

      # The portable subscriber's own activity (gateway-hinted actor URI) is not
      # echoed back to it.
      h[:deliveries].clear
      portable_activity = Aptok.create(
        Aptok.ap_uri("did:key:zsubscriber", "/activities/1"),
        Aptok.ap_uri("did:key:zsubscriber", "/actor", gateways: ["https://gw.example"]),
        Aptok.note(Aptok.ap_uri("did:key:zsubscriber", "/notes/1"), "Hello")
      )
      server.relay(h[:ctx], portable_activity).should be_empty
      h[:deliveries].should be_empty
    end

    it "drives a full classic Mastodon subscribe-then-relay flow" do
      h = build_relay("https://relay.example/actor")
      server = h[:server]
      news = person("https://news.example/actor", "https://news.example")
      reader = person("https://reader.example/actor", "https://reader.example")
      news_follow = Aptok::Relay.subscribe("https://news.example/follow/1", "https://news.example/actor", "https://relay.example/actor")
      reader_follow = Aptok::Relay.subscribe("https://reader.example/follow/1", "https://reader.example/actor", "https://relay.example/actor")

      server.subscribe(h[:ctx], news, news_follow, Aptok::Relay::Protocol::Mastodon)
      server.subscribe(h[:ctx], reader, reader_follow, Aptok::Relay::Protocol::Mastodon)
      h[:deliveries].clear

      activity = Aptok.create(
        "https://news.example/activities/1",
        "https://news.example/actor",
        Aptok.note("https://news.example/notes/1", "Breaking")
      )
      server.relay(h[:ctx], activity)

      # The publisher (news) is excluded; only the reader receives the content.
      h[:deliveries].map(&.first).should eq(["https://reader.example/inbox"])
      JSON.parse(h[:deliveries].first[1])["object"].as_h["content"].as_s.should eq("Breaking")
    end
  end
end
