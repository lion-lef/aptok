require "./spec_helper"

describe "FEP-ef61 portable objects" do
  it "canonicalizes ap URIs and compatible gateway IDs" do
    hinted = "ap://did%3Akey%3Azabc/users/alice?gateways=https%3A%2F%2Fserver1.example,https%3A%2F%2Fserver2.example"

    Aptork.canonical_ap_uri(hinted).should eq("ap://did:key:zabc/users/alice")
    Aptork.canonical_ap_uri("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice").should eq("ap://did:key:zabc/users/alice")
    Aptork.ap_uri_equivalent?(hinted, "https://server2.example/.well-known/apgateway/did:key:zabc/users/alice").should be_true
    Aptork.ap_uri_gateways(hinted).should eq(["https://server1.example", "https://server2.example"])
    Aptork.ap_gateway_url("https://server1.example", hinted).should eq("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice")
  end

  it "builds portable actor metadata and gateway delivery recipients" do
    actor_id = Aptork.ap_uri("did:key:zabc", "/users/alice")
    inbox = Aptork.ap_uri("did:key:zabc", "/users/alice/inbox")
    actor = Aptork.actor(
      "Person",
      actor_id,
      "alice",
      inbox,
      Aptork.ap_uri("did:key:zabc", "/users/alice/outbox"),
      gateways: ["https://server1.example", "https://server2.example"]
    )

    typed = Aptork::Vocab::Actor.from_json_ld(actor)
    actor["@context"].as_a.map(&.as_s).should contain(Aptork::FEP_EF61_CONTEXT)
    typed.gateways.should eq(["https://server1.example", "https://server2.example"])

    recipient = Aptork.recipient_from_actor(actor).not_nil!
    recipient.id.should eq(actor_id)
    recipient.inbox.should eq("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice/inbox")
  end

  it "looks up ap URIs through gateway hints and accepts canonical IDs from compatible URLs" do
    requests = [] of String
    object = Aptork.note("ap://did:key:zabc/objects/1", "Portable")
    loader = ->(url : String) : Aptork::JsonMap? do
      requests << url
      if url == "https://server1.example/.well-known/apgateway/did:key:zabc/objects/1" ||
         url == "https://server2.example/.well-known/apgateway/did:key:zabc/objects/1"
        object
      else
        nil
      end
    end

    hinted = "ap://did:key:zabc/objects/1?gateways=https%3A%2F%2Fserver1.example"
    Aptork::Remote.lookup_object(hinted, loader).not_nil!["id"].as_s.should eq("ap://did:key:zabc/objects/1")
    Aptork::Remote.lookup_object(
      "https://server2.example/.well-known/apgateway/did:key:zabc/objects/1",
      loader
    ).not_nil!["id"].as_s.should eq("ap://did:key:zabc/objects/1")
    requests.should eq([
      "https://server1.example/.well-known/apgateway/did:key:zabc/objects/1",
      "https://server2.example/.well-known/apgateway/did:key:zabc/objects/1",
    ])
  end

  it "routes apgateway GET and POST requests through portable context URIs" do
    handled_recipient = nil.as(String?)
    federation = Aptork::Federation.create("https://server.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptork::Context, identifier : String) do
      Aptork.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier),
        gateways: ["https://server.example"]
      ).as(Aptork::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(ctx : Aptork::Context, params : Hash(String, String)) do
      Aptork.note(
        ctx.get_object_uri("Note", params),
        "Portable",
        attributed_to: ctx.get_actor_uri(params["identifier"])
      ).as(Aptork::JsonMap?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled_recipient = ctx.recipient_identifier
        nil
      end)

    actor_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/apgateway/did:key:zlocal/users/alice",
      headers: {"Accept" => Aptork::FEDERATION_JSONLD_CONTENT_TYPE}
    ))
    actor_response.status.should eq(200)
    actor = JSON.parse(actor_response.body).as_h
    actor["id"].as_s.should eq("ap://did:key:zlocal/users/alice")
    actor["inbox"].as_s.should eq("ap://did:key:zlocal/users/alice/inbox")

    object_response = federation.handle(Aptork::Request.new(
      "GET",
      "/.well-known/apgateway/did:key:zlocal/users/alice/notes/1",
      headers: {"Accept" => Aptork::FEDERATION_JSONLD_CONTENT_TYPE}
    ))
    object_response.status.should eq(200)
    JSON.parse(object_response.body).as_h["id"].as_s.should eq("ap://did:key:zlocal/users/alice/notes/1")

    activity = Aptork.create(
      "ap://did:key:zremote/activities/1",
      "ap://did:key:zremote/actor",
      Aptork.note("ap://did:key:zremote/objects/1", "Hi")
    )
    post_response = federation.handle(Aptork::Request.new(
      "POST",
      "/.well-known/apgateway/did:key:zlocal/users/alice/inbox",
      headers: {"Content-Type" => Aptork::FEDERATION_JSONLD_CONTENT_TYPE},
      body: activity.to_json
    ))
    post_response.status.should eq(202)
    handled_recipient.should eq("alice")
  end

  it "verifies did:key proofs for portable actor attribution" do
    raw_key = Aptork::Testing.generate_ed25519_key_pair("unused")
    public_key_multibase = Aptork::Signatures.ed25519_public_key_multibase(raw_key.public_key_pem)
    did = Aptork.did_key(public_key_multibase)
    verification_method = Aptork.did_key_verification_method(public_key_multibase)
    key_pair = Aptork::ActorKeyPair.new(
      id: verification_method,
      owner: did,
      public_key_pem: raw_key.public_key_pem,
      private_key_pem: raw_key.private_key_pem,
      algorithm: "ed25519"
    )

    actor_id = Aptork.ap_uri(did, "/actor")
    note = Aptork.note(Aptork.ap_uri(did, "/objects/1"), "Portable", attributed_to: actor_id)
    activity = Aptork.create(Aptork.ap_uri(did, "/activities/1"), actor_id, note)
    signed = Aptork::Signatures.attach_object_proof(activity, key_pair)

    handled = false
    federation = Aptork::Federation.create("https://server.example")
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptork::Context, _activity : Aptork::JsonMap) do
        handled = true
        nil
      end)

    federation.create_context.route_activity("alice", signed).should be_true
    handled.should be_true
  end
end
