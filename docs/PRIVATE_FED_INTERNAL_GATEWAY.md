# Private `fed.internal` Gateway

This guide describes an ActivityPub proxy gateway for a private
`fed.internal` federation using Aptok. The gateway keeps ActivityPub URLs in the
private namespace while routing fetches through local infrastructure, caching
remote actors, and applying an explicit ACL before any private-network request.

## Architecture

```text
fed.internal clients
  |
  | DNS: *.fed.internal -> gateway/private load balancer
  v
ActivityPub gateway
  - Aptok federation routes
  - signed-fetch ACL
  - inbox signature key resolver
  - local-name document loader
  - KV-backed document and actor cache
  |
  | HTTP Host: team-a.fed.internal
  v
local upstream service or reverse proxy
  |
  v
private ActivityPub actors, inboxes, outboxes, and objects
```

The gateway should be the only network component that can dereference private
ActivityPub documents. Keep the default public Aptok loaders for public
federation and use the private gateway loader only for the trusted
`fed.internal` namespace.

## Crystal Modules

`Aptok::PrivateGateway::AccessList`
: Allows only configured private hosts and, optionally, configured actor IDs.
  Use it for document fetch policy and signed-fetch authorization.

`Aptok::PrivateGateway::LocalNameResolver`
: Rewrites `https://team-a.fed.internal/users/alice` to a local upstream such
  as `http://127.0.0.1:4010/users/alice` while preserving
  `Host: team-a.fed.internal`.

`Aptok::PrivateGateway::ActorCache`
: Caches fetched ActivityPub actors in any Aptok `KvStore`.

`Aptok::PrivateGateway.document_loader`
: Builds an ACL-gated Aptok `DocumentLoader` that uses the local resolver and
  optional KV document cache.

`Aptok::PrivateGateway.signature_key_resolver`
: Resolves inbox and signed-fetch keys only when the key and owner actor pass
  the ACL.

`Aptok::PrivateGateway.authorize_signed_fetch`
: Returns an Aptok authorizer predicate that accepts verified signed fetches
  from ACL-approved private actors.

## Gateway Skeleton

```crystal
store = Aptok::MemoryKvStore.new
acl = Aptok::PrivateGateway::AccessList.new(
  host_suffixes: ["fed.internal"],
  actor_ids: [
    "https://team-a.fed.internal/users/alice",
    "https://team-b.fed.internal/users/bob",
  ]
)
resolver = Aptok::PrivateGateway::LocalNameResolver.new(
  {"*.fed.internal" => "http://127.0.0.1:4010"}
)
loader = Aptok::PrivateGateway.document_loader(
  Aptok::PrivateGateway::Config.new(resolver, acl, store)
)
actor_cache = Aptok::PrivateGateway::ActorCache.new(store)

federation = Aptok.federation(
  "https://gateway.fed.internal",
  document_loader: loader,
  kv: store,
  allow_private_address: true
) do
  signature_keys Aptok::PrivateGateway.signature_key_resolver(loader, acl, store)
  inbox_signature_verification
  authorize_actor Aptok::PrivateGateway.authorize_signed_fetch(acl)

  inbox "/gateway/{identifier}/inbox", "/inbox" do |routes|
    routes.on "Activity" do |ctx, activity|
      actor_id = activity["actor"]?.try(&.as_s?)
      actor_cache.fetch(actor_id, ctx.document_loader) if actor_id
      nil
    end
  end
end
```

See [`examples/fed_internal_gateway.cr`](../examples/fed_internal_gateway.cr)
for a runnable standard-library HTTP server.

## DNS Config

Choose one private gateway address and point the private federation namespace at
it. Examples below use `10.24.0.10`.

### dnsmasq

```conf
address=/fed.internal/10.24.0.10
local=/fed.internal/
domain-needed
bogus-priv
```

### CoreDNS

```coredns
fed.internal:53 {
  template IN A (.*)\.fed\.internal {
    answer "{{ .Name }} 60 IN A 10.24.0.10"
  }
  template IN AAAA (.*)\.fed\.internal {
    rcode NXDOMAIN
  }
  log
}
```

### systemd-resolved Client

```ini
[Resolve]
DNS=10.24.0.10
Domains=~fed.internal
DNSSEC=no
```

## Operating Notes

- Do not expose the `fed.internal` resolver on the public internet.
- Keep `allow_private_address: true` scoped to the private gateway federation;
  the ACL is what makes the private-address fetch path safe.
- Prefer a persistent `KvStore` such as Redis or SQL for multi-process gateway
  deployments.
- Use short document-cache TTLs when actor keys rotate often; use longer TTLs
  for stable private service actors.
