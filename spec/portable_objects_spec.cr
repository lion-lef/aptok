require "./spec_helper"

describe "FEP-ef61 portable objects" do
  it "canonicalizes ap URIs and compatible gateway IDs" do
    hinted = "ap://did%3Akey%3Azabc/users/alice?gateways=https%3A%2F%2Fserver1.example,https%3A%2F%2Fserver2.example"

    Aptok.canonical_ap_uri(hinted).should eq("ap://did:key:zabc/users/alice")
    Aptok.canonical_ap_uri("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice").should eq("ap://did:key:zabc/users/alice")
    Aptok.ap_uri_equivalent?(hinted, "https://server2.example/.well-known/apgateway/did:key:zabc/users/alice").should be_true
    Aptok.ap_uri_gateways(hinted).should eq(["https://server1.example", "https://server2.example"])
    Aptok.ap_gateway_url("https://server1.example", hinted).should eq("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice")
  end

  it "builds portable actor metadata and gateway delivery recipients" do
    actor_id = Aptok.ap_uri("did:key:zabc", "/users/alice")
    inbox = Aptok.ap_uri("did:key:zabc", "/users/alice/inbox")
    actor = Aptok.actor(
      "Person",
      actor_id,
      "alice",
      inbox,
      Aptok.ap_uri("did:key:zabc", "/users/alice/outbox"),
      gateways: ["https://server1.example", "https://server2.example"]
    )

    typed = Aptok::Vocab::Actor.from_json_ld(actor)
    actor["@context"].as_a.map(&.as_s).should contain(Aptok::FEP_EF61_CONTEXT)
    typed.gateways.should eq(["https://server1.example", "https://server2.example"])

    recipient = Aptok.recipient_from_actor(actor).not_nil!
    recipient.id.should eq(actor_id)
    recipient.inbox.should eq("https://server1.example/.well-known/apgateway/did:key:zabc/users/alice/inbox")
  end

  it "looks up ap URIs through gateway hints and accepts canonical IDs from compatible URLs" do
    requests = [] of String
    object = Aptok.note("ap://did:key:zabc/objects/1", "Portable")
    loader = ->(url : String) : Aptok::JsonMap? do
      requests << url
      if url == "https://server1.example/.well-known/apgateway/did:key:zabc/objects/1" ||
         url == "https://server2.example/.well-known/apgateway/did:key:zabc/objects/1"
        object
      else
        nil
      end
    end

    hinted = "ap://did:key:zabc/objects/1?gateways=https%3A%2F%2Fserver1.example"
    Aptok::Remote.lookup_object(hinted, loader).not_nil!["id"].as_s.should eq("ap://did:key:zabc/objects/1")
    Aptok::Remote.lookup_object(
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
    federation = Aptok::Federation.create("https://server.example")
    federation.set_actor_dispatcher("/users/{identifier}", ->(ctx : Aptok::Context, identifier : String) do
      Aptok.actor(
        "Person",
        ctx.get_actor_uri(identifier),
        identifier,
        ctx.get_inbox_uri(identifier),
        ctx.get_outbox_uri(identifier),
        gateways: ["https://server.example"]
      ).as(Aptok::JsonMap?)
    end)
    federation.set_object_dispatcher("Note", "/users/{identifier}/notes/{note_id}", ->(ctx : Aptok::Context, params : Hash(String, String)) do
      Aptok.note(
        ctx.get_object_uri("Note", params),
        "Portable",
        attributed_to: ctx.get_actor_uri(params["identifier"])
      ).as(Aptok::JsonMap?)
    end)
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(ctx : Aptok::Context, _activity : Aptok::JsonMap) do
        handled_recipient = ctx.recipient_identifier
        nil
      end)

    actor_response = federation.handle(Aptok::Request.new(
      "GET",
      "/.well-known/apgateway/did:key:zlocal/users/alice",
      headers: {"Accept" => Aptok::FEDERATION_JSONLD_CONTENT_TYPE}
    ))
    actor_response.status.should eq(200)
    actor = JSON.parse(actor_response.body).as_h
    actor["id"].as_s.should eq("ap://did:key:zlocal/users/alice")
    actor["inbox"].as_s.should eq("ap://did:key:zlocal/users/alice/inbox")

    object_response = federation.handle(Aptok::Request.new(
      "GET",
      "/.well-known/apgateway/did:key:zlocal/users/alice/notes/1",
      headers: {"Accept" => Aptok::FEDERATION_JSONLD_CONTENT_TYPE}
    ))
    object_response.status.should eq(200)
    JSON.parse(object_response.body).as_h["id"].as_s.should eq("ap://did:key:zlocal/users/alice/notes/1")

    activity = Aptok.create(
      "ap://did:key:zremote/activities/1",
      "ap://did:key:zremote/actor",
      Aptok.note("ap://did:key:zremote/objects/1", "Hi")
    )
    post_response = federation.handle(Aptok::Request.new(
      "POST",
      "/.well-known/apgateway/did:key:zlocal/users/alice/inbox",
      headers: {"Content-Type" => Aptok::FEDERATION_JSONLD_CONTENT_TYPE},
      body: activity.to_json
    ))
    post_response.status.should eq(202)
    handled_recipient.should eq("alice")
  end

  it "verifies did:key proofs for portable actor attribution" do
    raw_key = Aptok::Testing.generate_ed25519_key_pair("unused")
    public_key_multibase = Aptok::Signatures.ed25519_public_key_multibase(raw_key.public_key_pem)
    did = Aptok.did_key(public_key_multibase)
    verification_method = Aptok.did_key_verification_method(public_key_multibase)
    key_pair = Aptok::ActorKeyPair.new(
      id: verification_method,
      owner: did,
      public_key_pem: raw_key.public_key_pem,
      private_key_pem: raw_key.private_key_pem,
      algorithm: "ed25519"
    )

    actor_id = Aptok.ap_uri(did, "/actor")
    note = Aptok.note(Aptok.ap_uri(did, "/objects/1"), "Portable", attributed_to: actor_id)
    activity = Aptok.create(Aptok.ap_uri(did, "/activities/1"), actor_id, note)
    signed = Aptok::Signatures.attach_object_proof(activity, key_pair)

    handled = false
    federation = Aptok::Federation.create("https://server.example")
    federation.enable_inbox_signature_verification
    federation.set_inbox_listeners("/users/{identifier}/inbox", "/inbox")
      .on("Create", ->(_ctx : Aptok::Context, _activity : Aptok::JsonMap) do
        handled = true
        nil
      end)

    federation.create_context.route_activity("alice", signed).should be_true
    handled.should be_true
  end
end
