require "./spec_helper"

describe Aptok::PrivateGateway do
  it "allows only configured private federation hosts and actors" do
    acl = Aptok::PrivateGateway::AccessList.new(
      host_suffixes: ["fed.internal"],
      actor_ids: ["https://team-a.fed.internal/users/alice"],
      blocked_actor_ids: ["https://team-a.fed.internal/users/blocked"]
    )

    acl.allows_url?("https://team-a.fed.internal/users/alice").should be_true
    acl.allows_url?("https://fed.internal/nodeinfo/2.1").should be_true
    acl.allows_url?("https://public.example/users/alice").should be_false
    acl.allows_actor?("https://team-a.fed.internal/users/alice").should be_true
    acl.allows_actor?("https://team-a.fed.internal/users/bob").should be_false
    acl.allows_actor?("https://team-a.fed.internal/users/blocked").should be_false
  end

  it "rewrites fed.internal document loads to local upstreams" do
    resolver = Aptok::PrivateGateway::LocalNameResolver.new(
      {"*.fed.internal" => "http://127.0.0.1:4010"}
    )
    called_url = ""
    called_host = ""
    provider = resolver.document_get_provider(->(url : String, headers : HTTP::Headers) do
      called_url = url
      called_host = headers["Host"]
      {
        200,
        Aptok.actor(
          "Person",
          "https://team-a.fed.internal/users/alice",
          "alice",
          "https://team-a.fed.internal/users/alice/inbox",
          "https://team-a.fed.internal/users/alice/outbox"
        ).to_json,
        HTTP::Headers{"Content-Type" => "application/activity+json"},
      }
    end)
    loader = Aptok::Remote.document_loader_with_metadata(provider, allow_private_address: true)

    document = loader.call("https://team-a.fed.internal/users/alice?profile=ap").not_nil!

    document.url.should eq("https://team-a.fed.internal/users/alice?profile=ap")
    called_url.should eq("http://127.0.0.1:4010/users/alice?profile=ap")
    called_host.should eq("team-a.fed.internal")
    document.json["id"].as_s.should eq("https://team-a.fed.internal/users/alice")
  end

  it "caches fetched private actors in KV storage" do
    cache = Aptok::PrivateGateway::ActorCache.new(Aptok::MemoryKvStore.new)
    hits = 0
    loader = ->(url : String) do
      hits += 1
      if url == "https://team-a.fed.internal/users/alice"
        Aptok.actor(
          "Person",
          url,
          "alice",
          "https://team-a.fed.internal/users/alice/inbox",
          "https://team-a.fed.internal/users/alice/outbox"
        ).as(Aptok::JsonMap?)
      else
        nil.as(Aptok::JsonMap?)
      end
    end

    first = cache.fetch("https://team-a.fed.internal/users/alice", loader).not_nil!
    second = cache.fetch("https://team-a.fed.internal/users/alice", loader).not_nil!

    hits.should eq(1)
    first["preferredUsername"].as_s.should eq("alice")
    second["preferredUsername"].as_s.should eq("alice")
  end

  it "resolves ACL-approved RSA actor keys through the actor cache" do
    store = Aptok::MemoryKvStore.new
    actor_id = "https://team-a.fed.internal/users/alice"
    key_id = "#{actor_id}#main-key"
    public_key_pem = "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"
    actor = Aptok.actor(
      "Person",
      actor_id,
      "alice",
      "#{actor_id}/inbox",
      "#{actor_id}/outbox",
      public_key: Aptok.public_key(key_id, actor_id, public_key_pem)
    )
    hits = 0
    loader = ->(url : String) do
      hits += 1
      url == actor_id ? actor.as(Aptok::JsonMap?) : nil.as(Aptok::JsonMap?)
    end
    acl = Aptok::PrivateGateway::AccessList.new(host_suffixes: ["fed.internal"])
    resolver = Aptok::PrivateGateway.signature_key_resolver(loader, acl, store)

    first = resolver.call(key_id).not_nil!
    second = resolver.call(key_id).not_nil!

    first.owner.should eq(actor_id)
    first.public_key_pem.should eq(public_key_pem)
    first.algorithm.should eq("rsa-sha256")
    second.owner.should eq(actor_id)
    hits.should eq(1)
  end

  it "builds an ACL-gated cached document loader" do
    hits = 0
    resolver = Aptok::PrivateGateway::LocalNameResolver.new(
      {"*.fed.internal" => "http://127.0.0.1:4010"}
    )
    acl = Aptok::PrivateGateway::AccessList.new(host_suffixes: ["fed.internal"])
    cache = Aptok::MemoryKvStore.new
    provider = ->(_url : String, _headers : HTTP::Headers) do
      hits += 1
      {
        200,
        Aptok.object("Note", "https://team-a.fed.internal/notes/1").to_json,
        HTTP::Headers{"Content-Type" => "application/activity+json"},
      }
    end
    loader = Aptok::PrivateGateway.document_loader(
      Aptok::PrivateGateway::Config.new(resolver, acl, cache),
      provider
    )

    loader.call("https://public.example/notes/1").should be_nil
    loader.call("https://team-a.fed.internal/notes/1").not_nil!["type"].as_s.should eq("Note")
    loader.call("https://team-a.fed.internal/notes/1").not_nil!["type"].as_s.should eq("Note")
    hits.should eq(1)
  end
end
