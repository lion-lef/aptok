# Aptok

Aptok is a Crystal ActivityPub toolkit inspired by Fedify. It provides a small
framework surface for building federated apps:

- ActivityStreams JSON-LD vocabulary helpers,
- Fedify-style `Federation` and `Context` objects,
- actor/object/outbox dispatchers,
- followers/following/inbox/custom collection dispatchers,
- typed inbox listeners,
- framework-agnostic request routing,
- `Context#send_activity` delivery,
- followers-recipient expansion for delivery,
- queued outbound delivery with retry helpers,
- queued inbound inbox processing with retry helpers,
- inbox forwarding with original-body delivery,
- actor key-pair dispatchers and RSA HTTP signing,
- resolver-backed inbox RSA signature verification,
- signed-fetch access control for actor/object/collection GET routes,
- remote document loading, object lookup, and collection traversal,
- FEP-ef61 portable `ap://did...` IDs with compatible gateway routing,
- authenticated document loaders for signed fetch,
- in-memory, Redis, and SQL (SQLite/PostgreSQL) KV and queue primitives,
- OpenMetrics/Prometheus metrics telemetry exporter,
- WebFinger handle mapping, alias mapping, link customization, and NodeInfo document builders,
- NodeInfo client lookup with typed parsing helpers,
- testing capture helpers,
- injectable HTTP/signature hooks for tests,
- ForgeFed repository, project, branch, commit, tag, push, ticket, tracker,
  ticket dependency, merge request, typed activity, and strict validation helpers,
- marketplace offer/service/listing and FEP-0837 proposal/agreement builder and
  validation helpers,
- a [`FEDERATION.md`](FEDERATION.md) (FEP-67ff) describing the implementation.

It is distributed under the [0BSD license](LICENSE). It is not a full Fedify port yet. The current implementation focuses on the
core shape and outbound/server-side building blocks.

## Installation

```yaml
dependencies:
  aptok:
    path: ./shards/aptok
```

```crystal
require "aptok"
```

## Federation

`Aptok.federation` creates a federation and configures it with a Crystal-style
DSL:

```crystal
federation = Aptok.federation("https://example.com") do
  actor "/users/{identifier}" do |ctx, identifier|
    Aptok.actor(
      "Person",
      ctx.get_actor_uri(identifier),
      identifier,
      ctx.get_inbox_uri(identifier),
      ctx.get_outbox_uri(identifier)
    ).as(Aptok::JsonMap?)
  end

  inbox "/users/{identifier}/inbox", "/inbox" do |routes|
    routes.with_idempotency
    routes.on "Create" do |_ctx, activity|
      puts activity["id"]?
    end
  end
end

ctx = federation.create_context
actor = ctx.actor("alice")
```

## Request Handling

`Federation#handle` provides a small framework-neutral adapter target. Web
frameworks can translate their native requests into `Aptok::Request` and return
`Aptok::Response`.

```crystal
response = federation.handle(Aptok::Request.new(
  "GET",
  "/users/alice",
  headers: {"Accept" => Aptok::FEDERATION_JSONLD_CONTENT_TYPE}
))

response.status
response.headers
response.body
```

For Crystal's standard HTTP server, use `Aptok.request_from_http` and
`Aptok.write_http_response` around `Federation#fetch`, matching Fedify's custom
middleware integration pattern. See [`examples/server.cr`](examples/server.cr)
for a runnable server.

`Federation#fetch` is an alias for `handle` with Fedify-style request fallback
callbacks. Use these callbacks from framework middleware when normal web routes
share paths with ActivityPub routes. `on_not_found` also applies to
federation-managed misses such as unresolved WebFinger resources, and
`on_unauthorized` can customize access-control denials.

```crystal
fallbacks = Aptok::FetchOptions.new(
  on_not_found: Aptok::RequestHandler.new do |request|
    app_route(request)
  end,
  on_not_acceptable: Aptok::RequestHandler.new do |request|
    response = app_route(request)
    response.status == 404 ? Aptok::Response.new(
      406,
      {"Content-Type" => Aptok::FEDIFY_TEXT_CONTENT_TYPE, "Vary" => "Accept, Signature"},
      "Not Acceptable"
    ) : response
  end,
  on_unauthorized: Aptok::RequestHandler.new do |_request|
    Aptok::Response.new(403, {"Content-Type" => "text/plain"}, "forbidden")
  end
)

response = federation.fetch(
  Aptok::Request.new("GET", "/users/alice", headers: {"Accept" => "text/html"}),
  fallbacks
)
```

Currently routed:

- `GET`/`HEAD /.well-known/webfinger?resource=acct:user@example.com`
- `GET`/`HEAD /.well-known/nodeinfo`
- `GET`/`HEAD`/`POST /.well-known/apgateway/{did...}/{path}`
- `GET`/`HEAD /nodeinfo/2.1` when `nodeinfo` is configured
- actor GET/HEAD via `actor`
- object GET/HEAD via `object`
- outbox GET/HEAD via `outbox`
- outbox page GET/HEAD via `?page=N&size=N`
- followers/following/inbox/custom collection GET/HEAD via collection dispatchers
- inbox POST via `actor` and `inbox` listeners
- outbox POST via `outbox` listeners

ActivityPub GET routes perform Fedify-style `Accept` negotiation and return
`406 Not Acceptable` when HTML or XHTML is the preferred media type, or when
the request does not explicitly accept a JSON ActivityPub representation.
Missing `Accept` is treated like Fedify's wildcard fallback and is not enough
to match an ActivityPub route by itself. Compatible media types are
`application/activity+json`, `application/ld+json`, and `application/json`,
all with a positive `q` value. As in Fedify, an ActivityPub media type still
wins when it has higher quality than HTML. Negotiated ActivityPub `200`
responses use Fedify's `application/activity+json` content type and set
`Vary: Accept`; default `406` responses mirror Fedify's `Not Acceptable` body
with `Vary: Accept, Signature`. `HEAD` follows the same routing and negotiation
as `GET` but returns an empty body. WebFinger and NodeInfo use their own JSON
content types.
WebFinger JRD and WebFinger `410 Gone` responses include
`Access-Control-Allow-Origin: *`, matching Fedify's browser-friendly discovery
behavior. Tombstoned WebFinger responses use Fedify's empty-body `410` shape
without a content type.
When `handle_host` differs from the canonical ActivityPub origin, WebFinger
aliases follow Fedify's shape: handle-host `acct:` lookups include the actor URI
but do not add the canonical-origin `acct:` alias, while canonical `acct:` and
actor-URI lookups still point clients back to the handle host.

Fedify-style inbox POST routing requires an actor dispatcher. Personal inbox
POSTs return `404` when the recipient actor cannot be dispatched or has been
tombstoned; shared inbox POSTs also require the dispatcher to be configured.
For accepted inbox POSTs, Aptok mirrors Fedify's route-result responses:
processed and unsupported activities return an empty `202`, duplicate
activities return `202 Activity <id> has already been processed.`, enqueued
activities return `202 Activity is enqueued.`, missing activity actors return
`400`, and listener failures return `500`.
Malformed JSON request bodies return Fedify's `400 Invalid JSON.` response.
When an inbox POST request accepts ActivityPub or JSON, these text responses set
`Vary: Accept`, matching Fedify's middleware negotiation header.
Syntactically valid JSON bodies that are not ActivityPub Activity objects return
`400 Invalid activity.`. Array-valued `actor` properties are accepted when at
least one actor id can be extracted from the array.
These inbox POST plain-text responses use Fedify's
`text/plain; charset=utf-8` content type.
Like Fedify, malformed inbox bodies notify the configured inbox error handler
before the `400` response is returned.

Actor dispatchers may return an ActivityStreams Tombstone for a deleted local
actor. Aptok responds to the actor route with `410 Gone` and the serialized
tombstone body, and WebFinger for the same account also returns an empty-body
`410 Gone`. Tombstone detection accepts compact `Tombstone`, expanded
ActivityStreams IDs, and array-valued `type` fields.
Like Fedify, Aptok logs `aptok.federation.actor` warnings when a dispatched
actor omits or mismatches the `id`, configured inbox, outbox, followers,
following, liked, featured, featured-tags, `publicKey`, or `assertionMethod`
properties. Use the matching `ctx.get_*_uri` and `ctx.get_actor_key_pairs`
helper values in returned actors to keep route metadata consistent.

```crystal
federation = Aptok.federation("https://example.com") do
  actor "/users/{identifier}" do |ctx, identifier|
    deleted_at = deleted_actor_timestamp(identifier)
    if deleted_at
      Aptok.tombstone(ctx.get_actor_uri(identifier), "Person", deleted_at).as(Aptok::JsonMap?)
    else
      nil
    end
  end
end
```

## Collections

Collections can be returned whole or paged:

```crystal
collection = Aptok.paginated_ordered_collection(
  "https://example.com/users/alice/outbox",
  activities
)

page = Aptok.paginated_ordered_collection(
  "https://example.com/users/alice/outbox",
  activities,
  page: 2,
  size: 20
)
```

Outbox request routing uses the same helper when `page` and `size` query
parameters are present.

For scalable collections, register a cursor dispatcher:

```crystal
federation = Aptok.federation("https://example.com") do
  outbox_page "/users/{identifier}/outbox" do |ctx, identifier, cursor, size|
    items = load_outbox_items(identifier, cursor, size)
    Aptok::CollectionPageResult.new(
      items,
      next_cursor: next_cursor_for(items),
      prev_cursor: cursor,
      total_items: count_outbox_items(identifier),
      first_cursor: "start"
    )
  end
end
```

If an outbox cursor dispatcher returns `nil`, Aptok mirrors Fedify's
`onNotFound` collection behavior and returns `404` for that outbox request.

Fedify also exposes actor collections beyond the outbox. Aptok supports the
same server-side shape for followers, following, inbox, liked, featured,
featured tags, and named custom collections:

```crystal
federation = Aptok.federation("https://example.com") do
  followers "/users/{identifier}/followers" do |_ctx, identifier|
    load_followers(identifier)
  end

  # Cursor followers dispatchers can receive a normalized ?base-url= filter so
  # FEP-8fcf synchronization views can be filtered in storage instead of after
  # loading every follower. Aptok still applies an in-memory safety filter.
  followers(
    "/users/{identifier}/followers",
    Aptok::FilteredCursorCollectionDispatcher.new do |_ctx, identifier, cursor, size, base_url|
      load_followers_page(identifier, cursor, size, base_url)
    end
  )

  # If a cursor followers dispatcher returns nil for cursor nil, send_activity
  # falls back to first_cursor and walks every page when collecting recipients.
  followers(
    "/users/{identifier}/followers",
    Aptok::ParamCursorCollectionDispatcher.new do |_ctx, params, cursor, size|
      cursor.nil? ? nil : load_followers_page(params["identifier"], cursor, size)
    end
  )

  collection "followers" do |routes|
    routes.first_cursor { |_ctx, _params| "".as(String?) }
  end

  following "/users/{identifier}/following" do |_ctx, identifier|
    load_following(identifier)
  end

  # Following, liked, featured, and featured-tags dispatchers also support the
  # same cursor page shape as Fedify's built-in actor collections.
  following(
    "/users/{identifier}/following",
    Aptok::CursorCollectionDispatcher.new do |_ctx, identifier, cursor, size|
      load_following_page(identifier, cursor, size)
    end
  )

  inbox(
    "/users/{identifier}/inbox",
    Aptok::CollectionDispatcher.new do |_ctx, identifier|
      load_received_activities(identifier)
    end
  )

  liked "/users/{identifier}/liked" do |_ctx, identifier|
    load_liked_objects(identifier)
  end

  featured "/users/{identifier}/featured" do |_ctx, identifier|
    load_featured_objects(identifier)
  end

  featured_tags "/users/{identifier}/tags" do |_ctx, identifier|
    load_featured_tags(identifier)
  end

  collection "bookmarks", "/users/{identifier}/collections/bookmarks" do |_ctx, params|
    load_bookmarks(params["identifier"])
  end

  ordered_collection "featured-archive", "/users/{identifier}/collections/featured-archive" do |_ctx, params|
    load_featured_archive(params["identifier"])
  end

  collection "repo-tags", "/repos/{owner}/{repo}/tags" do |_ctx, params|
    load_repo_tags(params["owner"], params["repo"])
  end

  collection_page "stars", "/repos/{owner}/{repo}/stars" do |_ctx, params, cursor, size|
    load_star_page(params["owner"], params["repo"], cursor, size)
  end

  collection "stars" do |stars|
    stars.item_type "Person"
    stars.first_cursor { |_ctx, _params| "start" }
    stars.last_cursor { |_ctx, _params| "end" }
    stars.counter { |_ctx, _params| count_stars }
    stars.filter do |_ctx, item|
      item["id"].as_s.starts_with?("https://remote.example/")
    end
    stars.authorize do |_ctx, _request, verification, _identifier, params|
      verification.verified && can_read_stars?(params["owner"], params["repo"])
    end
  end
end
```

Built-in actor collections and `ordered_collection` return
`OrderedCollection` / `OrderedCollectionPage`. `collection`
matches Fedify's unordered custom collection API and returns `Collection` /
`CollectionPage`. Served custom collection document IDs use the same canonical
origin as `ctx.get_collection_uri`. Array dispatchers support `page` and `size` query parameters.
Page dispatchers receive all URI parameters plus `cursor` and `size`, and return
`CollectionPageResult` for cursor pagination. Use `ordered_collection_page` for
ordered cursor collections.
If a cursor page dispatcher returns `nil`, Aptok now mirrors Fedify's
`onNotFound` behavior and returns `404` for that collection request.
Cursor collection links follow Fedify's request-URL behavior: `first`, `last`,
`prev`, `next`, and page `partOf` preserve unrelated query parameters while
replacing or removing only `cursor`.
Collection metadata callbacks mirror Fedify's first-cursor, last-cursor,
counter, and filter-predicate shape for whole collection responses.
For array and cursor dispatchers, the counter callback controls root collection
`totalItems`; page responses still describe the concrete page items. Filtered
collections preserve the dispatcher/counter-provided `totalItems` rather than
replacing it with the filtered item length, matching Fedify's separate counter
and item-filtering behavior.
The `collection "name" do |routes| ... end` block groups metadata, filtering,
and authorization callbacks for a Fedify-style chain.

## Inbox Listeners

Inbox and outbox listener matching follows Fedify's activity-class shape.
Register a specific activity type with a compact string such as `"Follow"` or
`"Create"`, a canonical type ID such as
`"https://www.w3.org/ns/activitystreams#Create"`, or a vocab class such as
`Aptok::Vocab::Create`. Register `"Activity"` to receive every incoming
activity. The legacy `on_any` helper remains available as an explicit wildcard.

```crystal
federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.on Aptok::Vocab::Follow do |ctx, follow|
    accept_follow(ctx, follow)
    nil
  end

  routes.on "Activity" do |_ctx, activity|
    audit_inbox_activity(activity)
    nil
  end
end
```

Aptok normalizes expanded type IDs before matching and also matches ActivityPub
documents whose `type` is an array, so a payload with
`["https://www.w3.org/ns/activitystreams#Create", "Activity"]` reaches both
`"Create"` and `"Activity"` listeners.

When the listener parameter is typed as the vocab class, Aptok parses the
incoming JSON-LD before calling the handler. Use `JsonMap` in the lambda
signature when you want the raw payload instead.

Listener dispatch also follows vocabulary inheritance for common Fedify cases:
an `Invite` reaches `Offer`/`Aptok::Vocab::ActivityOffer` listeners,
`TentativeAccept` reaches `Accept`, `TentativeReject` reaches `Reject`, and
`Block` reaches `Ignore`.

## Outbox Listeners

Fedify exposes outbox listeners for client-to-server `POST` requests to an
actor outbox. Aptok mirrors that shape with local authorization and typed
activity handlers:

```crystal
federation.outbox "/users/{identifier}/outbox" do |routes|
  routes.authorize do |ctx, identifier|
    token = ctx.inbound_request.try(&.headers["Authorization"]?)
    token == "Bearer #{identifier}"
  end

  routes.on "Create" do |ctx, activity|
    persist_outbox_activity(ctx.identifier, activity)
    ctx.send_activity(ctx.identifier.not_nil!, "followers", activity)
    nil
  end
end
```

Outbox POST authorization is local application logic; Aptok does not apply
inbox HTTP Signature verification to client-to-server posts. Like Fedify, the
addressed actor must exist and the posted activity must include an `actor`
matching the outbox actor URI; when the dispatched actor omits `id`, Aptok
falls back to `ctx.get_actor_uri(identifier)` like Fedify. Missing or
mismatched activity actors return `400`.
If an outbox route is configured for `GET` collection dispatch but no outbox
listeners are configured, `POST` returns Fedify's `405 Method not allowed.`
response with `Allow: GET, HEAD`.
When `actor` is an array, every extracted actor id must match the outbox actor,
matching Fedify's `actorIds.every(...)` rule.
Unsupported activity types still return `202`, while listener failures notify
configured outbox error handlers and return `500`.
Malformed JSON request bodies return Fedify's `400 Invalid JSON.` response.
Syntactically valid JSON bodies that are not ActivityPub Activity objects return
`400 Invalid activity.`. Malformed bodies and actor validation failures notify
the configured outbox listener error handler before the `400` response is
returned, matching Fedify's outbox error callback behavior. These outbox POST
plain-text responses use Fedify's `text/plain; charset=utf-8` content type and
set `Vary: Accept` when the request accepts ActivityPub or JSON.
Inside these listeners `ctx.identifier` is the matched outbox route identifier,
matching Fedify's `OutboxContext.identifier`; `ctx.outbox_identifier` remains as
an explicit Aptok alias. Listeners explicitly decide whether to persist, send,
or forward the activity. Outbox listener type matching has the same vocab-class,
type-ID, `"Activity"` catch-all, and array `type` support as inbox listener
matching.

## Inbox Idempotency

Fedify caches processed inbox activities so duplicate delivery does not invoke
listeners repeatedly. Like Fedify 2.x, Aptok enables the `per-inbox` strategy
by default when the federation has a KV store:

```crystal
store = Aptok::MemoryKvStore.new
federation = Aptok::Federation.create("https://example.com", kv: store)

federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.on "Create" do |_ctx, _activity|
    nil
  end
end
```

The default strategy is `per-inbox`, matching Fedify's current behavior: the
same activity id may be processed once for Alice's inbox and once for Bob's
inbox. Use `with_idempotency` to change TTL, or use `per-origin` or `global`
for broader deduplication:

```crystal
federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.with_idempotency "per-origin"
end
```

Custom strategies can return a cache key or `nil` to skip idempotency for a
specific activity:

```crystal
federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.with_idempotency Time::Span.new(hours: 24) do |ctx, activity|
    if activity["type"]?.try(&.as_s?) == "Follow"
      nil
    else
      id = activity["id"]?.try(&.as_s?)
      inbox = ctx.recipient_identifier || "shared"
      id ? "#{ctx.origin}\n#{id}\n#{inbox}" : nil
    end
  end
end
```

Inbox listener contexts expose `ctx.recipient_identifier` for personal inbox
delivery and `nil` for shared inbox delivery.

## Inbox Queueing

Verified inbox POSTs can be enqueued before listeners run. Invalid or unverified
activities are rejected immediately and are not queued:

```crystal
queue = Aptok::InProcessMessageQueue.new
policy = Aptok::RetryPolicy.new(max_attempts: 5)

federation = Aptok::Federation.create(
  "https://example.com",
  inbox_queue: queue,
  inbox_retry_policy: policy
)

federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.with_idempotency
  routes.on "Create" do |_ctx, activity|
    handle_create(activity)
    nil
  end

  routes.on_error do |ctx, error|
    log_inbox_error(ctx.recipient_identifier, error)
    nil
  end
end

federation.create_context.process_queued_inbox_activities(limit: 10)
```

Queued inbox processing retries listener failures with the configured retry
policy. Idempotency is marked only after listeners complete successfully, so
failed queued attempts can retry.
`InboxListeners#on_error` reports listener exceptions for both synchronous and
queued processing, and malformed POST bodies before their Fedify-style `400`
responses. Without a scoped handler Aptok falls back to the federation-wide
`on_error` handler for listener errors and malformed-body notifications, while
unhandled listener exceptions otherwise re-raise.

Manual routing follows Fedify's queue behavior: if an inbox queue is configured,
`Context#route_activity` enqueues by default. Pass `immediate: true` to invoke
listeners synchronously:

```crystal
ctx.route_activity("alice", activity)
ctx.route_activity("alice", activity, Aptok::RouteActivityOptions.new(immediate: true))
ctx.route_activity(
  "alice",
  activity,
  Aptok::RouteActivityOptions.new(document_loader: loader, context_loader: context_loader)
)
```

Use `route_activity_result` when tests or application code need Fedify-style
outcomes instead of a boolean:

```crystal
case ctx.route_activity_result("alice", activity)
when Aptok::RouteActivityResult::Success
  mark_inbox_processed(activity)
when Aptok::RouteActivityResult::Enqueued
  mark_inbox_queued(activity)
when Aptok::RouteActivityResult::UnsupportedActivity
  audit_unsupported(activity)
end
```

Manual routing also follows Fedify's trust model. Unsigned activities are
dereferenced by `id` before listeners see them; Aptok rejects missing actors,
fetched id mismatches, and fetched actors whose origin differs from the fetched
activity. Use `trusted: true` only for activity maps that have already passed
your HTTP signature, Object Integrity Proof, or equivalent queue boundary:

```crystal
ctx.route_activity("alice", verified_activity, Aptok::RouteActivityOptions.new(trusted: true))
```

## Inbox Forwarding

Fedify exposes `forwardActivity()` for forwarding an incoming activity without
rewriting the activity payload. Aptok mirrors that shape with
`Context#forward_activity`:

```crystal
federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.on "Create" do |ctx, activity|
    ctx.forward_activity(
      activity,
      Aptok::ForwardActivityOptions.new(skip_if_unsigned: true)
    )
    nil
  end
end
```

The automatic overload reads local actor ids from top-level `to`, `cc`, and
`audience`, plus embedded `object.to`, `object.cc`, and `object.audience`.
Each addressed local actor is used as the forwarder and the activity is
forwarded to that actor's followers. Use the explicit overload when you already
know the forwarder or target collection:

```crystal
ctx.forward_activity("alice", "followers", activity)
ctx.forward_activity("alice", recipients, activity)
ctx.forward_activity("alice", remote_actor_json, activity)
ctx.forward_activity({username: "alice"}, remote_actor_json, activity)
```

Like `send_activity`, the explicit-recipient forwarding overload can take one
or more `Aptok::ActorKeyPair` values when the forwarder keys are already
available:

```crystal
ctx.forward_activity(
  key_pair,
  remote_actor_json,
  activity,
  Aptok::ForwardActivityOptions.new(ordering_key: "alice")
)
```

Explicit forward targets can be `Recipient` values, raw ActivityPub actor
documents, typed `Aptok::Vocab::Actor` values, or arrays of either actor shape.

Forwarding posts the original inbox request body when one is available, while
the forwarding HTTP POST can still be signed by the local forwarder key. This
preserves embedded Object Integrity Proofs. Without such a proof, remote servers
may still reject the forwarded activity; use `skip_if_unsigned: true` to avoid
forwarding activities without `proof` or legacy `signature` fields.

When an outbox queue is configured, forwarding is queued by default and the
original inbox request body is preserved inside the queued task. Explicit
forwarder key pairs are serialized into queued forward tasks so workers can sign
the later HTTP POST. Pass `immediate: true` to bypass the queue:

```crystal
ctx.forward_activity(
  "alice",
  "followers",
  activity,
  Aptok::ForwardActivityOptions.new(immediate: true)
)
```

## Inbox Verification

Inbox verification is opt-in while the signature stack is still evolving. Apps
can attach a verifier and an unverified-activity callback:

```crystal
federation.inbox_verifier do |request, activity|
  if Aptok::Signatures.verified_by_headers?(request)
    Aptok::VerificationResult.new(true)
  else
    Aptok::VerificationResult.new(false, "missing or invalid signature")
  end
end

federation.on_unverified_activity do |_ctx, activity, result|
  puts result.reason
  nil.as(Aptok::Response?)
end
```

The same callback can be registered from the inbox listener chain. If it returns
a `Response`, Aptok uses it instead of the default `401` response; returning
`nil` preserves the default challenge response:

```crystal
federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.on "Create", create_listener
  routes.on_unverified_activity do |_ctx, activity, result|
    quarantine(activity, result)
    Aptok::Response.new(202, {"Content-Type" => "text/plain"}, "quarantined").as(Aptok::Response?)
  end
end
```

`Aptok::Signatures` currently supports Cavage-style Signature header parsing,
digest validation, signing-string construction, and RSA-SHA256 verification. It
also includes a focused RFC 9421 HTTP Message Signatures helper surface for
RSA-PKCS#1-v1.5 SHA-256 over `@method`, `@target-uri`, `@authority`, `host`,
`date`, and `content-digest`:

```crystal
headers = Aptok::Signatures.rfc9421_rsa_sha256_headers(
  "post",
  "https://remote.example/inbox",
  activity.to_json,
  key_pair
)
```

Use `Rfc9421Options` for custom labels/components and nonce/tag/expires
parameters. Verification accepts `Rfc9421VerifyOptions` for required components,
clock skew, and deterministic test time. Federation verification reconstructs
the expected target URI from the local origin and request path before validating
`@target-uri`.

Structured component identifiers are preserved in the generated
`Signature-Input` and signature base. Aptok understands request-derived
components such as `@scheme`, `@request-target`, `@query`, and
`@query-param;name="resource"`, and keeps structured field parameters on named
fields such as `content-digest;sf`. `Aptok::Signatures.parse_accept_signatures`
parses multi-member `Accept-Signature` challenges so callers can inspect each
candidate challenge and its parameters.

Aptok also includes Object Integrity Proof helpers inspired by Fedify's
`signObject()`/`createProof()` API. For Fedify-style proofs, use an Ed25519
actor key pair. Aptok publishes that key as a Multikey assertion method, signs
the Data Integrity hash data with Ed25519, and emits a multibase base58btc
`proofValue` with cryptosuite `eddsa-jcs-2022`:

```crystal
ed25519_key = Aptok::ActorKeyPair.new(
  id: "https://example.com/users/alice#multikey-1",
  owner: "https://example.com/users/alice",
  public_key_pem: ed25519_public_key_pem,
  private_key_pem: ed25519_private_key_pem,
  algorithm: "ed25519"
)

signed = Aptok::Signatures.attach_object_proof(
  activity,
  ed25519_key,
  Aptok::ObjectProofOptions.new(created: Aptok.now)
)

valid = Aptok::Signatures.verify_object_proof?(signed, ed25519_key)
```

The proof payload excludes the object's `proof` property, includes the proof
configuration without `proofValue`, and handles a `proof` object or proof array.
This is useful for ForgeFed and marketplace activities that need embedded tamper
evidence. RSA-backed local proofs remain available with cryptosuite
`jcs-rsa-sha256-2026` for applications that only have RSA actor keys, but
Ed25519 Multikey proofs are the Fedify-compatible path.

When `Context#send_activity` or `Context#enqueue_activity` is used with a key
pairs dispatcher or explicit sender key pairs, Aptok automatically creates
Object Integrity Proofs for Ed25519 key pairs before recipient delivery fanout.
Immediate delivery, per-recipient queued delivery, and queued fan-out expansion
therefore send the same pre-signed activity to every recipient.

For inbound verification, Aptok first asks the configured signature key
resolver. If no key is returned, it dereferences the proof `verificationMethod`
with the federation document loader, checks direct Multikey documents or the
controller actor's `assertionMethod`, decodes Ed25519 `publicKeyMultibase`, and
caches validated public keys in the configured KV store.

Inbound Object Integrity Proof verification also checks attribution coverage:
valid proof key owners must cover the activity `actor` and nested object
`actor`/`attributedTo` identities. A ForgeFed `Create(Ticket)` or marketplace
proposal attributed to a second actor therefore needs a second valid proof from
that actor instead of passing with only the activity actor's proof.

For a Fedify-style built-in path, configure a signature key resolver. Aptok will
reject unsigned or invalid inbox POSTs before listeners run, verify Object
Integrity Proofs, RFC 9421 `Signature-Input`/`Content-Digest`, or the legacy RSA
`Signature`/`Digest` headers, and require the resolved key owner to match
`activity.actor` by default:

```crystal
federation.signature_keys do |key_id|
  key = fetch_or_load_remote_key(key_id)
  key ? Aptok::ActorKeyPair.new(
    id: key.id,
    owner: key.owner,
    public_key_pem: key.public_key_pem
  ).as(Aptok::ActorKeyPair?) : nil
end

federation.inbox_signature_verification(
  Aptok::InboxSignatureOptions.new(
    require_actor_key_owner: true,
    challenge_policy: Aptok::InboxChallengePolicy.new(
      enabled: true,
      request_nonce: true
    )
  )
)
```

When `challenge_policy.enabled` is true, HTTP signature verification failures
return `401` with an `Accept-Signature` header describing the RFC 9421 signature
components Aptok accepts. Like Fedify, challenged failures use
`text/plain; charset=utf-8`, `Cache-Control: no-store`,
`Vary: Accept, Signature`, and the generic
`Failed to verify the request signature.` body. Actor/key-owner mismatch
failures are not challenged, because signing with different parameters cannot
fix impersonation. If `request_nonce` is enabled, Aptok stores a one-time nonce
in the configured KV store and consumes it when a valid retry signature arrives.

`signature_keys` enables verification with default options for convenience. Use
`inbox_signature_verification` when you want to make the
policy explicit or relax actor/key-owner matching for a compatibility test.
Manual `inbox_verifier` callbacks take precedence over the built-in resolver
path.

## Access Control

Authorized fetch can be enforced on actor, object, and collection GET routes by
registering authorizer predicates. The predicate receives the signed request
verification result and can decide based on `signer_actor`:

```crystal
federation.signature_keys do |key_id|
  resolve_remote_key(key_id)
end

federation.authorize_actor do |_ctx, _request, verification, identifier, _params|
  verification.verified &&
    !!verification.signer_actor &&
    !blocked?(identifier, verification.signer_actor)
end

federation.object "Ticket" do |ticket|
  ticket.authorize do |_ctx, _request, verification, _identifier, params|
    verification.verified && can_read_ticket?(params["repo"], verification.signer_actor)
  end
end

federation.collection "featured" do |featured|
  featured.authorize do |_ctx, _request, verification, identifier, _params|
    verification.verified && can_read_featured?(identifier, verification.signer_actor)
  end
end
```

If an authorizer returns `false`, Aptok responds with `401 Unauthorized` by
default, or delegates to `on_unauthorized` when the request is handled through
`fetch`/`handle` with fallback callbacks. Inbox signature-challenge `401`
responses keep their `Accept-Signature` headers and do not use this callback.
Collection authorizers run after the collection dispatcher has produced a
collection or page, matching Fedify's `handleCollection` order; missing
dispatcher results still return `404` before authorization.
Actor and object authorizers follow the same Fedify ordering: the dispatcher
runs first, missing resources return `404`, and authorization is checked only
for an existing actor or object.
Routes without an authorizer remain public.

Inside request-derived callbacks, `ctx.get_signed_key` returns the verified
remote signing key and `ctx.get_signed_key_owner` returns its actor URI. Use
`get_signed_key_owner_actor` or a typed `get_signed_key_owner` call to resolve
the signer to an ActivityStreams actor, optionally with a per-call document
loader for mutual authorized fetch. These helpers return `nil` for unsigned,
invalid, or non-request contexts:

```crystal
federation.authorize_actor do |ctx, _request, _verification, _identifier, _params|
  owner = ctx.get_signed_key_owner_actor(
    Aptok::GetSignedKeyOptions.new(document_loader: instance_loader)
  )
  owner.try(&.id) == "https://remote.example/users/bob"
end

person = ctx.get_signed_key_owner(Aptok::Vocab::Person)
```

## Actor Key Pairs

Fedify uses actor key-pair dispatchers to expose public keys and sign outbound
delivery. Aptok mirrors that shape with `key_pairs` and
`Context#get_actor_key_pairs`:

```crystal
federation.key_pairs do |ctx, identifier|
  owner = ctx.get_actor_uri(identifier)
  [
    Aptok::ActorKeyPair.new(
      id: "#{owner}#main-key",
      owner: owner,
      public_key_pem: load_public_key(identifier),
      private_key_pem: load_private_key(identifier)
    ),
  ]
end
```

The dispatcher receives a context whose
`key_pairs_dispatcher_identifier` is set to the identifier currently being
resolved. As in Fedify, calling `ctx.get_actor_key_pairs` from inside this
callback can recurse; Aptok logs a warning when that happens, and dispatcher
code can check the marker to avoid accidental loops.

When an actor is dispatched, Aptok adds `publicKey` from the first RSA key pair
unless the actor already includes one, and adds `assertionMethod` entries for
non-RSA keys:

```crystal
actor = ctx.actor("alice")
actor["publicKey"]?
```

You can also build key material manually:

```crystal
key = ctx.get_actor_key_pairs("alice").first
public_key = Aptok.public_key(key)
```

RSA key maps are emitted as typed `CryptographicKey` objects, while Ed25519 keys
are emitted as typed `Multikey` objects. Both parse through
`Aptok::Vocab::Object.from_json_ld` and are exposed on
`Aptok::Vocab::Person#public_key` / `#assertion_methods`.

`Context#send_activity` and queued delivery processing select the first
RSA-SHA256 key pair with a private key and sign outgoing inbox POSTs with the
legacy ActivityPub `Signature` header. Static transport-level signing remains
available for compatibility.

## Context URI Helpers

`Aptok::Context` mirrors the Fedify style of deriving stable URLs from route
templates:

- `get_actor_uri(identifier)`
- `get_inbox_uri(identifier)`
- `get_inbox_uri` for shared inbox
- `get_outbox_uri(identifier)`
- `get_followers_uri(identifier)`
- `get_following_uri(identifier)`
- `get_liked_uri(identifier)`
- `get_featured_uri(identifier)`
- `get_featured_tags_uri(identifier)`
- `get_collection_uri(name, params)`
- `get_object_uri(type, params)`
- `parse_uri(uri)`

Request-derived contexts expose Fedify-style request helpers:

- `request` / `inbound_request`
- `url`
- `origin`
- `canonical_origin`
- `host`
- `hostname`
- `data`

Pass request-scoped data through `handle`/`fetch` or `create_context`, and use
`clone(data)`/`with_data(data)` to derive a context with replacement data:

```crystal
data = Aptok.json({"tenant" => "alpha"})
response = federation.handle(request, context_data: data)

ctx = federation.create_context(context_data: data)
next_ctx = ctx.clone(Aptok.json({"tenant" => "beta"}))
```

When the request/runtime origin differs from the public ActivityPub origin,
pass `canonical_origin`. Generated actor, object, inbox, outbox, collection, and
NodeInfo URLs use the canonical origin, while `ctx.origin`, `ctx.url`,
`ctx.host`, and `ctx.hostname` still describe the request origin. If handles
should use another host, pass `handle_host`; WebFinger accepts both the handle
host and canonical host. `parse_uri` accepts both runtime and canonical origins.
Like Fedify, runtime and canonical origins must be HTTP(S) origin roots without
path, query, or fragment components; accepted origins are normalized to lower
case and omit default ports.

```crystal
federation = Aptok::Federation.create(
  "https://internal.example:8443",
  canonical_origin: "https://ap.example",
  handle_host: "example.com"
)

origin = Aptok::FederationOrigin.new(
  handle_host: "example.com",
  web_origin: "https://ap.example"
)
federation = Aptok::Federation.create(origin)

ctx = federation.create_context
ctx.get_actor_uri("alice") # "https://ap.example/actors/alice"
federation.handle(Aptok::Request.new(
  "GET",
  "/.well-known/webfinger",
  query: {"resource" => "acct:alice@example.com"}
))
ctx.parse_uri("https://internal.example:8443/actors/alice")
ctx.parse_uri("https://ap.example/actors/alice")
```

Fedify's `trailingSlashInsensitive` option is available as
`trailing_slash_insensitive`. It leaves generated URLs unchanged, but incoming
route matching and `parse_uri` treat `/foo` and `/foo/` as the same path:

```crystal
federation = Aptok::Federation.create(
  "https://example.com",
  trailing_slash_insensitive: true
)
```

Fixed actor aliases map a public path to a stable internal identifier while
still using the normal actor dispatcher. This is useful for instance, bot,
relay, ForgeFed, or marketplace service actors:

```crystal
federation.actor "/users/{identifier}", actor_dispatcher
federation.actor_alias "/bot", "bot"

ctx.get_actor_uri("bot") # "https://example.com/bot"
```

Requests to `/bot` dispatch the actor identifier `"bot"`, and WebFinger self
links use the fixed path when a handle maps to that identifier.

Object dispatchers can use `get_object_uri` to build dereferenceable IDs from
the registered URI template and `Context#object(type, params)` can dispatch a
local object by all URI parameters:

```crystal
federation.object "Ticket", "/repos/{repo}/tickets/{ticket_id}" do |ctx, values|
  Aptok.forgefed_ticket(
    ctx.get_object_uri("Ticket", values),
    "Bug",
    "Fix it"
  )
end

ticket = ctx.object("Ticket", {"repo" => "aptok", "ticket_id" => "42"})
```

Like Fedify's `ctx.getObjectUri(Note, values)`, Aptok also accepts typed
vocabulary classes:

```crystal
federation.object "Note", "/users/{identifier}/notes/{note_id}" do |ctx, values|
  Aptok.note(
    ctx.get_object_uri(Aptok::Vocab::Note, values),
    "Hello"
  )
end

note = ctx.get_object(Aptok::Vocab::Note, {
  "identifier" => "alice",
  "note_id" => "1",
})

# Named tuples mirror Fedify's object-literal call shape in Crystal:
note_uri = ctx.get_object_uri(Aptok::Vocab::Note, {identifier: "alice", note_id: "1"})
note = ctx.get_object(Aptok::Vocab::Note, {identifier: "alice", note_id: "1"})
ticket_uri = ctx.get_collection_uri("tickets", {repo: "aptok"})
```

Fedify-style getter aliases are also available. `get_actor` suppresses
`Tombstone` actors by default, or returns them with `tombstone: "passthrough"`:

```crystal
actor = ctx.get_actor("alice", Aptok::Vocab::Person)
raw_actor = ctx.get_actor("alice")
tombstone = ctx.get_actor("gone", Aptok::Vocab::Tombstone, Aptok::GetActorOptions.new(tombstone: "passthrough"))
ticket = ctx.get_object("Ticket", {"repo" => "aptok", "ticket_id" => "42"})
```

`parse_uri` reverses local actor, inbox, collection, and object routes:

```crystal
parsed = ctx.parse_uri("https://example.com/repos/aptok/tickets/42")
parsed = ctx.parse_uri(URI.parse("https://example.com/repos/aptok/tickets/42"))
parsed = ctx.parse_uri(nil)
parsed.try(&.type)        # "object"
parsed.try(&.object_type) # "Ticket"
parsed.try(&.values)      # {"repo" => "aptok", "ticket_id" => "42"}
```

Portable contexts created by `/.well-known/apgateway/{did...}/...` generate
`ap://did...` actor, inbox, outbox, collection, and object IDs from the same
route templates. You can also create one explicitly:

```crystal
portable_ctx = federation.create_context.with_portable_authority("did:key:z6M...")
portable_ctx.get_actor_uri("alice") # "ap://did:key:z6M.../users/alice"
```

Route templates support simple expansion (`{id}`) and reserved expansion
(`{+id}`) for URI-like identifiers. Actor, inbox, followers, following, liked,
featured, and featured-tags routes follow Fedify's validation and must contain
exactly one `{identifier}` or `{+identifier}` variable. Outbox routes must use
exactly one `{identifier}` variable, and Aptok rejects mismatched inbox/outbox
dispatcher and listener paths instead of silently replacing one route with
another. Reserved expansion routes do not match an empty tail, so paths like
`/actors/` are treated as not found instead of dispatching an empty identifier,
matching Fedify's identifier callback contract. Object and custom collection
dispatchers can still use route-specific variables such as
`/repos/{repo}/tickets/{ticket_id}`.

## Remote Lookup

Fedify's `Context#lookupObject` and `Context#traverseCollection` are represented
as raw `JsonMap` helpers in Aptok. Configure a document loader when you want to
control fetching, caching, tests, or authenticated fetch:

```crystal
federation.document_loader do |url|
  response = HTTP::Client.get(
    url,
    headers: HTTP::Headers{"Accept" => Aptok::FEDERATION_JSONLD_CONTENT_TYPE}
  )
  response.success? ? JSON.parse(response.body).as_h : nil
end
```

Like Fedify, contexts expose both `document_loader` and `context_loader`. The
context loader defaults to the document loader, but can be configured separately
for JSON-LD context expansion or tests:

```crystal
federation = Aptok::Federation.create(
  "https://example.com",
  document_loader: document_loader,
  context_loader: context_loader
)

ctx = federation.create_context(
  Aptok::Request.new("GET", "/users/alice"),
  context_data: Aptok.json({"tenant" => "alpha"})
)

ctx.document_loader.call("https://remote.example/users/alice")
ctx.context_loader.call("https://www.w3.org/ns/activitystreams")
```

Use the metadata loader when your integration needs response status, headers,
and content type in addition to parsed JSON:

```crystal
metadata_provider = Aptok::MetadataDocumentGetProvider.new do |url, headers|
  response = HTTP::Client.get(url, headers: headers)
  {response.status_code, response.body, response.headers}
end
metadata_loader = Aptok::Remote.document_loader_with_metadata(metadata_provider)

document = metadata_loader.call("https://remote.example/users/alice")
document.try(&.content_type)
document.try(&.headers)

legacy_loader = Aptok::Remote.json_document_loader(metadata_loader)
federation.document_loader legacy_loader
```

The built-in public and authenticated document loaders reject private-network
URLs by default, matching Fedify's SSRF protection. Requests to `localhost`,
loopback, link-local, RFC 1918 IPv4, carrier-grade NAT, multicast/reserved IPv4,
IPv6 loopback, link-local, and unique-local addresses are blocked before the
HTTP provider runs. Local development or trusted test harnesses can opt out
explicitly:

```crystal
loader = Aptok::Remote.default_document_loader(
  get_provider,
  allow_private_address: true
)

federation = Aptok::Federation.create(
  "https://example.com",
  document_get_provider: get_provider,
  allow_private_address: true
)
```

Fedify-style outbound user-agent configuration is available for the built-in
document loaders and federation document providers:

```crystal
loader = Aptok::Remote.default_document_loader(
  get_provider,
  user_agent: "my-app/1.0"
)

federation = Aptok::Federation.create(
  "https://example.com",
  document_get_provider: get_provider,
  user_agent: "my-app/1.0"
)
```

Custom federation document loaders are responsible for their own fetch policy.

Like Fedify's `lookupObject()`, `LookupObjectOptions` can carry a per-call
loader. The context helpers use this loader for lookup and object verification
instead of the federation default:

```crystal
object = ctx.lookup_object(
  "https://remote.example/notes/1",
  Aptok::LookupObjectOptions.new(document_loader: loader)
)

same_object = ctx.lookup_object(URI.parse("https://remote.example/notes/1"))

repo = ctx.lookup_object(
  "https://forge.example/repos/aptok",
  Aptok::Vocab::Repository
)
repo.try(&.clone_uri)

offer = Aptok::Remote.lookup_object(
  "https://market.example/offers/solver",
  Aptok::Vocab::MarketplaceOffer,
  ctx.document_loader
)
offer.try(&.price_currency)

verified = ctx.verify_activity_object(
  activity,
  Aptok::LookupObjectOptions.new(document_loader: loader)
)
```

Wrap a loader with `Remote.kv_cache` to mirror Fedify's KV-backed `kvCache`
document-loader decorator:

```crystal
store = Aptok::MemoryKvStore.new
loader = Aptok::Remote.kv_cache(
  Aptok::Remote.default_document_loader,
  store,
  Aptok::DocumentCacheOptions.new(ttl: Time::Span.new(minutes: 10))
)
federation.document_loader loader

# Or wrap the federation's current loader with its configured KV store.
federation.document_cache(ttl: Time::Span.new(minutes: 10))
```

Only successful JSON documents are cached by default. Authenticated document
loaders are left uncached unless you explicitly wrap them, because responses can
depend on the requesting actor.

When a remote server requires authorized fetch, build an authenticated document
loader for a local actor. Aptok signs GET requests with the actor's first
RSA-SHA256 key pair and retries one transient transport failure, matching
Fedify's idempotent authenticated document fetch behavior:

```crystal
loader = ctx.get_document_loader("alice")
private_following = Aptok::Remote.lookup_object(
  "https://remote.example/users/bob/following",
  loader,
  Aptok::LookupObjectOptions.new(cross_origin: "trust")
)
```

Public loaders do not retry by default. Pass `transient_retries` when you want a
specific retry count:

```crystal
loader = Aptok::Remote.default_document_loader(transient_retries: 2)
```

The effective loader is available as `ctx.document_loader`, and the context
lookup helpers (`lookup_webfinger`, `lookup_object`, `verify_object_reference`,
`verify_activity_object`, `lookup_nodeinfo`, and `traverse_collection`) use it.
Inbox listener contexts use authenticated loaders automatically for personal
inboxes when key pairs are registered. Shared inboxes can opt into a
Fedify-style shared key dispatcher, usually backed by an instance actor:

```crystal
jrd = ctx.lookup_webfinger(URI.parse("acct:alice@example.com"))
mailto = ctx.lookup_webfinger("mailto:juliet@example.com?subject=Hi")
```

```crystal
federation.document_get_provider remote_get_provider
federation.key_pairs do |ctx, identifier|
  load_actor_keys(ctx.get_actor_uri(identifier))
end

federation.inbox "/users/{identifier}/inbox", "/inbox" do |routes|
  routes.shared_key do |_ctx|
    {identifier: "instance"}.as(Aptok::SharedInboxKey?)
  end

  routes.on "Create" do |ctx, activity|
    object = ctx.lookup_object(activity["object"].as_s)
    offers = ctx.traverse_collection("https://market.example/offers")
  end
end
```

Lookup supports direct object URLs, fediverse handles, and `acct:` URIs:

```crystal
ctx = federation.create_context

actor = ctx.lookup_object("@alice@example.com")
same_actor = ctx.lookup_object("acct:alice@example.com")
ticket = ctx.lookup_object("https://forge.example/tickets/1")
```

FEP-ef61 `ap://did...` IDs are dereferenced through gateway hints in the URI or
explicit lookup options. Compatible gateway HTTP IDs under
`/.well-known/apgateway/{did...}/...` compare equal to their canonical `ap://`
IDs:

```crystal
portable = Aptok.ap_uri("did:key:z6M...", "/objects/1", ["https://example.com"])
object = ctx.lookup_object(portable)

same = Aptok.ap_uri_equivalent?(
  portable,
  "https://example.com/.well-known/apgateway/did:key:z6M.../objects/1"
)
```

For `http`/`https` identifiers, Aptok first fetches the URL directly. If that
misses, it falls back to WebFinger for that URL and follows the ActivityPub
`self` link, matching Fedify's `lookupObject` behavior for profile URLs:

```crystal
actor = ctx.lookup_object("https://example.com/@alice")
```

Fedify-style actor handle discovery is available for actor documents and actor
URIs. Aptok first checks WebFinger URL resources and `acct:` aliases, verifies
cross-origin handle aliases, and falls back to `preferredUsername` on actor
objects:

```crystal
handle = ctx.get_actor_handle(actor)
typed_handle = ctx.get_actor_handle(Aptok::Vocab::Person.from_json_ld(actor))
same_handle = ctx.get_actor_handle("https://example.com/users/alice")
bare = ctx.get_actor_handle(actor, Aptok::ActorHandleOptions.new(trim_leading_at: true))
normalized = Aptok.normalize_actor_handle("@Alice@EXAMPLE.COM")
unicode = Aptok.normalize_actor_handle("@quux@XN--MAANA-PTA.COM")
ascii = Aptok.normalize_actor_handle("@quux@MAÑANA.COM", Aptok::ActorHandleOptions.new(punycode: true))
```

By default, lookup rejects objects whose `id`/`@id` origin differs from the
fetched URL, following the FEP-fe34 anti-spoofing shape. Set
`cross_origin: "trust"` to bypass the check or `"throw"` to turn mismatch into
an exception. The older Crystal-style `"raise"` spelling is kept as an alias:

```crystal
ctx.lookup_object(
  "https://forge.example/tickets/1",
  Aptok::LookupObjectOptions.new(cross_origin: "trust")
)
```

When an incoming activity embeds a cross-origin object, verify the object before
trusting embedded fields. Aptok accepts same-origin embedded objects, dereferences
cross-origin object ids, and rejects spoofed ids by default:

```crystal
verified = ctx.verify_activity_object(activity)

verified = ctx.verify_activity_object(
  activity,
  Aptok::LookupObjectOptions.new(cross_origin: "throw")
)
```

Collections can be traversed from an inline object or a URL. Aptok reads
`orderedItems`/`items` and follows `first`/`next` links:

```crystal
offers = ctx.traverse_collection("https://market.example/offers", limit: 50)
offers.each do |offer|
  puts offer["type"].as_s
end

best_effort = ctx.traverse_collection(
  "https://market.example/offers",
  Aptok::TraverseCollectionOptions.new(limit: 50, suppress_error: true)
)

with_loader = ctx.traverse_collection(
  URI.parse("https://market.example/offers"),
  Aptok::TraverseCollectionOptions.new(document_loader: loader)
)

typed = Aptok::Vocab::OrderedCollection.from_json_ld(collection_json)
typed_items = ctx.traverse_collection(typed)
typed_items.first.as(Aptok::Vocab::MarketplaceOffer).price_currency
```

`TraverseCollectionOptions#suppress_error` mirrors Fedify's `suppressError`
option for best-effort pagination when a later collection page or referenced
item cannot be fetched. `document_loader` overrides the context loader for a
single traversal, matching Fedify's per-call lookup options. When a collection
has a `first` page, traversal starts from that page instead of yielding any
top-level summary items, matching Fedify's `traverseCollection`.

Broader protocol conformance around HTTP Signature RFC 9421 and Linked Data
Signatures/Object Integrity Proofs remains an area for ongoing parity work.

## Vocabulary

The library exposes generic builders for producing JSON-LD documents:

```crystal
note = Aptok.note(
  "https://example.com/notes/1",
  "Hello from Crystal",
  attributed_to: "https://example.com/users/alice"
)

activity = Aptok.create(
  "https://example.com/activities/1",
  "https://example.com/users/alice",
  note
)
```

Fedify-style activity builder helpers are available for the standard
ActivityStreams activity types. Object-bearing activities accept either an
embedded JSON-LD object or an IRI string:

```crystal
follow = Aptok.follow(
  "https://example.com/activities/follow/1",
  "https://example.com/users/alice",
  "https://remote.example/users/bob"
)

like = Aptok.like(
  "https://example.com/activities/like/1",
  "https://example.com/users/alice",
  note
)

move = Aptok.move(
  "https://example.com/activities/move/1",
  "https://example.com/users/alice",
  "https://example.com/users/alice",
  target: "https://example.net/users/alice"
)

question = Aptok.question(
  "https://example.com/questions/1",
  "https://example.com/users/alice",
  one_of: [
    Aptok.note("https://example.com/questions/1/a", "A"),
    "https://example.com/questions/1/b",
  ],
  end_time: "2026-05-23T00:00:00Z"
)
```

The helper set covers `Accept`, `Add`, `Announce`, `Block`, `Create`, `Delete`,
`Dislike`, `Flag`, `Follow`, `Ignore`, `Invite`, `Join`, `Leave`, `Like`,
`Listen`, `Move`, `Offer`, `Reject`, `Read`, `Remove`, `TentativeAccept`,
`TentativeReject`, `Undo`, `Update`, `View`, plus intransitive `Arrive`,
`Travel`, and `Question`.

Standard ActivityStreams object helpers mirror the typed parser surface and
cover common fields such as `name`, `summary`, `content`, `mediaType`, `url`,
`attributedTo`, `attachment`, `tag`, source text, and sensitivity flags:

```crystal
image = Aptok.image(
  "https://example.com/media/preview.png",
  name: "Preview",
  media_type: "image/png",
  url: "https://cdn.example.com/media/preview.png"
)

article = Aptok.article(
  "https://example.com/articles/1",
  name: "Federated marketplace notes",
  content: "Long-form content",
  attributed_to: "https://example.com/users/alice",
  attachments: [image],
  source_content: "# Federated marketplace notes",
  source_media_type: "text/markdown"
)
```

The helper set covers `Article`, `Audio`, `Document`, `Event`, `Image`, `Page`,
`Place`, `Profile`, `Relationship`, and `Video`. `Aptok.note` and
`Aptok.tombstone` remain specialized helpers for the common Note and Tombstone
shapes.

Link, tag, custom emoji, and profile-field helpers are available for the
objects commonly attached to posts and actor profiles:

```crystal
preview = Aptok.link(
  "https://cdn.example.com/media/preview.png",
  rel: ["preview"],
  media_type: "image/png",
  name: "Preview"
)

mention = Aptok.mention(
  "https://remote.example/users/bob",
  "@bob@remote.example"
)

tag = Aptok.hashtag("#aptok", "https://example.com/tags/aptok")
field = Aptok.property_value("Website", "https://example.com")
emoji = Aptok.emoji(
  "https://example.com/emoji/blobcat",
  ":blobcat:",
  Aptok.image("https://example.com/emoji/blobcat.png", media_type: "image/png")
)
```

Known type constants are available for app-level validation or UI:

- `Aptok::ACTOR_TYPES`
- `Aptok::OBJECT_TYPES`
- `Aptok::ACTIVITY_TYPES`
- `Aptok::FORGEFED_TYPES`
- `Aptok::MARKETPLACE_TYPES`

Use `Aptok.type_name(uri_or_name)` and `Aptok.type_id(name)` to bridge compact
names and canonical JSON-LD type IDs. Vocab classes expose the same canonical
ID through `type_id`:

```crystal
Aptok.type_name("https://www.w3.org/ns/activitystreams#Like") # => "Like"
Aptok::Vocab::Like.type_id
Aptok::Vocab::Repository.type_id
Aptok::Vocab::Multikey.type_id
```

Fedify-style typed parsing is available for common ActivityStreams objects:

```crystal
parsed = Aptok::Vocab::Object.from_json_ld(activity)
if parsed.is_a?(Aptok::Vocab::Create)
  parsed.actor
  parsed.object
  parsed.to_json_ld
end

announce = Aptok::Vocab::Announce.from_json_ld(announce_json)
announce.actor
announce.object
announce.target
announce.cc

follow = Aptok::Vocab::Follow.from_json_ld(follow_json)
follow.object

arrive = Aptok::Vocab::Arrive.from_json_ld(arrive_json)
arrive.is_a?(Aptok::Vocab::IntransitiveActivity)

note = Aptok::Vocab::Note.from_json_ld(note_json)
note.content

article = Aptok::Vocab::Article.from_json_ld(article_json)
article.name
article.summary
article.attachment
article.tags
article.previews
article.start_time
article.end_time
article.duration
article.source
article.proofs
article.sensitive
article.emoji_reactions
article.quote
article.quote_url

question = Aptok::Vocab::Question.from_json_ld(question_json)
question.one_of
question.any_of
question.end_time
question.voters_count

image = Aptok::Vocab::Image.from_json_ld(image_json)
image.media_type
image.url

link = Aptok::Vocab::Link.from_json_ld(link_json)
link.href
link.rel

hashtag = Aptok::Vocab::Hashtag.from_json_ld(hashtag_json)
hashtag.name
hashtag.href

mention = Aptok::Vocab::Mention.from_json_ld(mention_json)
mention.href

emoji = Aptok::Vocab::Emoji.from_json_ld(emoji_json)
emoji.name
emoji.icon

property_value = Aptok::Vocab::PropertyValue.from_json_ld(property_value_json)
property_value.name
property_value.value

collection = Aptok::Vocab::Collection.from_json_ld(collection_json)
collection.total_items
collection.items

actor = Aptok::Vocab::Actor.from_json_ld(actor_json)
actor.preferred_username
actor.manually_approves_followers
actor.liked
actor.featured
actor.featured_tags
actor.streams
actor.gateways
actor.discoverable
actor.indexable
actor.also_known_as
actor.successor
actor.endpoints.try(&.oauth_authorization_endpoint)
actor.endpoints.try(&.upload_media)
actor.shared_inbox
actor.public_key
actor.assertion_methods

person = Aptok::Vocab::Person.from_json_ld(person_json)
service_actor = Aptok::Vocab::Service.from_json_ld(service_actor_json)

key = Aptok::Vocab::CryptographicKey.from_json_ld(public_key_json)
key.public_key_pem

multikey = Aptok::Vocab::Multikey.from_json_ld(multikey_json)
multikey.public_key_multibase

tombstone = Aptok::Vocab::Tombstone.from_json_ld(tombstone_json)
tombstone.former_type
tombstone.deleted

repo = Aptok::Vocab::Repository.from_json_ld(repository_json)
repo.clone_uri
repo.push_uris

project = Aptok::Vocab::Project.from_json_ld(project_json)
project.inbox

branch = Aptok::Vocab::Branch.from_json_ld(branch_json)
branch.ref

tag = Aptok::Vocab::ForgeFedTag.from_json_ld(tag_json)
tag.href

commit = Aptok::Vocab::Commit.from_json_ld(commit_json)
commit.hash

tracker = Aptok::Vocab::TicketTracker.from_json_ld(ticket_tracker_json)
tracker.outbox

push = Aptok::Vocab::Push.from_json_ld(push_json)
push.hash_after
push.commits

ticket = Aptok::Vocab::Ticket.from_json_ld(ticket_json)
ticket.resolved

offer = Aptok::Vocab::MarketplaceOffer.from_json_ld(offer_json)
offer.item
offer.price_currency

listing = Aptok::Vocab::Listing.from_json_ld(listing_json)
listing.item
listing.price_specification

proposal = Aptok::Vocab::Proposal.from_json_ld(proposal_json)
proposal.publishes
proposal.reciprocal
proposal.publishes.as(Aptok::Vocab::Intent).resource_quantity.try(&.unit)

agreement = Aptok::Vocab::Agreement.from_json_ld(agreement_json)
agreement.stipulates
```

`Object.from_json_ld` dispatches known subtypes such as common ActivityStreams
activities (`Accept`, `Announce`, `Follow`, `Like`, `Undo`, `Update`, and the
other `ACTIVITY_TYPES` entries, including `IntransitiveActivity` and its
`Arrive`/`Question`/`Travel` subtypes), standard ActivityStreams objects (`Article`,
`Audio`, `Document`, `Event`, `Image`, `Note`, `Page`, `Place`, `Profile`,
`Relationship`, `Video`), `Link` plus link subtypes `Mention`/`Hashtag`,
Mastodon-style `Emoji`, schema.org `PropertyValue`,
`Collection`/`OrderedCollection`/collection pages, `Tombstone`, all
ActivityStreams actor subtypes (`Application`, `Group`, `Organization`,
`Person`, `Service`) with typed `Endpoints`,
ForgeFed `Repository`/`Branch`/`Commit`/`Push`/`Ticket`, and marketplace
`Offer`/`Product`/`PriceSpecification`/`Listing` plus ValueFlows
`Intent`/`Measure`/`Proposal`/`Commitment`/`Agreement`, while unknown vocabulary
types are preserved as base objects with their raw `json` map intact.

## Sending Activities

`Context#send_activity` delivers immediately and records successful deliveries
in `Federation#sent_activities`:

```crystal
transport = Aptok::Transport.new(signature_enabled: false)
federation = Aptok::Federation.create("https://example.com", transport)
ctx = federation.create_context

recipient = Aptok::Recipient.new(
  "https://remote.example/users/bob",
  "https://remote.example/inbox"
)

ctx.send_activity("alice", [recipient], activity)
```

Explicit recipients can be passed as one recipient, an array of recipients, a
raw ActivityPub actor document, a typed `Aptok::Vocab::Actor`, or arrays of
either actor shape. Use
`Aptok::SendActivityOptions` with explicit recipients for Fedify-style shared
inbox selection, same-origin exclusion, queueing, ordering keys, and fanout:

```crystal
remote_actor_json = fetch_remote_actor(...)

result = ctx.send_activity(
  "alice",
  remote_actor_json,
  activity,
  Aptok::SendActivityOptions.new(
    prefer_shared_inbox: true,
    exclude_base_uris: ["https://example.com"],
    ordering_key: "alice"
  )
)

result.sent
result.queued
result.fanout_queued
```

When a remote actor document is already available, `Aptok.recipient_from_actor`
converts its `id`/`@id`, `inbox`, and `endpoints.sharedInbox` fields into an
explicit recipient without requiring a typed vocabulary wrapper:

```crystal
recipient = Aptok.recipient_from_actor(
  remote_actor_json,
  prefer_shared_inbox: true
)
```

The sender can also be passed in the Fedify-style identity shape. Use
`{identifier: "alice"}` when the internal actor identifier is already known, or
`{username: "alice"}` to resolve a public handle through `handles` first:

```crystal
federation.handles do |_ctx, username|
  username == "alice" ? "user-123" : nil
end

ctx.send_activity({username: "alice"}, [recipient], activity)
ctx.send_activity({identifier: "user-123"}, [recipient], activity)
```

Identity senders accept the same explicit recipient shapes as string senders:
`Recipient`, raw ActivityPub actor documents, typed `Aptok::Vocab::Actor`
values, and actor arrays.

Like Fedify, Aptok rejects outgoing sends whose transformed activity has no
`id`/`@id` or `actor`, whether the delivery is immediate or queued. Install
`auto_id_assigner` or call `default_activity_transformers` when you want Aptok
to assign local ids before validation.

Like Fedify's sender key-pair form, explicit RSA/Ed25519 key pairs can also be
used when the activity already carries its `actor`; Aptok rejects key-pair
sends whose transformed activity has no actor or whose explicit key pairs lack
private key material. Explicit sender keys must use `rsa-sha256` or `ed25519`;
Ed25519 senders need private key PEM because Aptok creates Ed25519 Object
Integrity Proofs from PEM material:

```crystal
key_pair = Aptok::ActorKeyPair.new(
  "https://example.com/users/alice#main-key",
  "https://example.com/users/alice",
  public_key_pem,
  private_key_pem: private_key_pem
)

ctx.send_activity(
  key_pair,
  remote_actor_json,
  activity,
  Aptok::SendActivityOptions.new(ordering_key: "alice")
)
```

When an outbox queue is configured, Aptok serializes the explicit sender key
pairs into each queued delivery task so workers can sign the later HTTP POST.
As in Fedify, `"followers"` delivery still requires an identifier or username
sender because key-pair senders do not imply a local followers collection.
Key-pair senders can use explicit `Recipient` values, raw ActivityPub actor
documents, typed `Aptok::Vocab::Actor` values, or arrays of either actor shape.

When followers are exposed through `followers`, activities can be sent to the
followers collection directly:

```crystal
result = ctx.send_activity(
  {username: "alice"},
  "followers",
  activity,
  Aptok::SendActivityOptions.new(
    prefer_shared_inbox: true,
    sync_collection: true,
    exclude_base_uris: ["https://example.com"]
  )
)

result.sent
result.queued
result.fanout_queued
```

Follower actors are converted to recipients from `id` and `inbox`. When
`prefer_shared_inbox` is enabled, `endpoints.sharedInbox` is used and duplicate
shared inboxes are collapsed. `exclude_base_uris` skips local actors or inboxes.
When `sync_collection` is enabled for `"followers"` delivery, Aptok adds a
FEP-8fcf `Collection-Synchronization` header with the sender's followers
collection URI and the partial follower digest for the actor IDs represented by
that inbox. Followers collection GET also supports `?base-url=` filtering for
remote servers that need to synchronize their slice of the collection.

For Fedify-style delivery planning without sending, call `Aptok.extract_inboxes`
with explicit recipients. It returns a hash keyed by inbox URL and records the
actor IDs represented by each inbox:

```crystal
recipients = [
  Aptok::Recipient.new(
    "https://remote.example/users/bob",
    "https://remote.example/users/bob/inbox",
    shared_inbox: "https://remote.example/inbox"
  ),
  Aptok::Recipient.new(
    "https://remote.example/users/carol",
    "https://remote.example/users/carol/inbox",
    shared_inbox: "https://remote.example/inbox"
  ),
]

inboxes = Aptok.extract_inboxes(
  recipients,
  prefer_shared_inbox: true,
  exclude_base_uris: ["https://example.com"]
)

inboxes["https://remote.example/inbox"].actor_ids
inboxes["https://remote.example/inbox"].shared_inbox
```

`exclude_base_uris` follows Fedify's origin-level exclusion behavior here, so a
base such as `https://remote.example/projects/1` excludes recipients on the
`https://remote.example` origin.

For Fedify-style queued delivery, configure an outbox queue and call
`Context#enqueue_activity`. Each recipient becomes one queued outbound delivery
message. When no ordering key is specified, Aptok uses the queue's
`enqueue_many` hook so backends can batch multi-recipient sends in the same
style as Fedify's optional `MessageQueue.enqueueMany()` API. When an ordering
key is specified, Aptok keeps individual enqueues so queue implementations can
preserve per-message ordering. `Context#process_queued_activities` consumes the
in-process queue, posts through the configured transport, retries failures
according to the retry policy, and records successful sends.

For large follower deliveries, configure a fan-out queue. Collection sends use
Fedify-style `fanout: "auto" | "skip" | "force"` options. `"auto"` enqueues one
`FanoutDelivery` task when the recipient count reaches the configured threshold;
`"skip"` always queues per recipient; `"force"` always uses the fan-out queue
when one is configured. Any other value raises an `ArgumentError` instead of
silently falling back to automatic behavior. The fan-out worker expands that
task into normal outbound delivery messages. Explicit sender key pairs are
serialized with the fan-out task, so forced or threshold-based fanout still
signs the expanded outbound deliveries with the provided sender identity:

```crystal
outbox_queue = Aptok::InProcessMessageQueue.new
fanout_tasks = Aptok::InProcessMessageQueue.new

federation = Aptok::Federation.create(
  "https://example.com",
  transport,
  outbox_queue: outbox_queue
)
federation.fanout_queue fanout_tasks, threshold: 100

result = ctx.send_activity(
  "alice",
  "followers",
  activity,
  Aptok::SendActivityOptions.new(fanout: "auto")
)

ctx.process_queued_fanout_activities(limit: 10)
ctx.process_queued_activities(limit: 10)
```

`Context#get_document_loader` accepts the same sender identity tuples for signed
fetch. Passing an explicit key pair matches Fedify's key-pair form and requires
an RSA-SHA256 key with private key material:

```crystal
loader = ctx.get_document_loader({username: "alice"})
loader = ctx.get_document_loader(rsa_key_pair)
```

If a username cannot be mapped for document loading, Aptok falls back to the
public federation document loader. Sending with an unmapped username raises an
`ArgumentError`.

```crystal
queue = Aptok::InProcessMessageQueue.new
policy = Aptok::RetryPolicy.new(max_attempts: 5)

federation = Aptok::Federation.create(
  "https://example.com",
  transport,
  outbox_queue: queue,
  outbox_retry_policy: policy
)

ctx = federation.create_context
ctx.enqueue_activity(
  "alice",
  [recipient],
  activity,
  Aptok::EnqueueOptions.new(ordering_key: "alice")
)

ctx.process_queued_activities(limit: 10)
```

Queued outbound deliveries that fail with permanent inbox statuses skip retries.
By default, `404` and `410` are treated as permanent failures. Override the set
when a deployment treats additional statuses, such as `451`, as terminal:

```crystal
federation = Aptok::Federation.create(
  "https://example.com",
  permanent_failure_status_codes: [404, 410, 451]
)

federation.permanent_failure_status_codes [404, 410, 451]
```

Register a handler to remove stale followers or update local delivery state:

```crystal
federation.outbox_permanent_failures do |_ctx, failure|
  remove_followers_for_inbox(failure.inbox, failure.actor_ids)
  nil
end
```

For transient delivery failures, register an outbox error handler. It is called
for each failed queued attempt that will continue through the retry policy:

```crystal
federation.outbox_errors do |_ctx, failure|
  log_delivery_retry(failure.inbox, failure.status_code, failure.attempts)
  nil
end
```

For errors raised by local outbox listeners themselves, use the Fedify-style
listener-scoped handler:

```crystal
federation.outbox "/users/{identifier}/outbox" do |routes|
  routes.on "Create" do |_ctx, _activity|
    raise "could not persist local side effect"
  end

  routes.on_error do |ctx, error|
    log_outbox_listener_error(ctx.outbox_identifier, error)
    nil
  end
end
```

You can also attach queueing after creation:

```crystal
federation.outbox_queue queue, retry_policy: policy
```

Activity transformers mirror Fedify's outgoing compatibility hook. They run
once for each outbound activity batch, before Object Integrity Proofs and before
immediate delivery or queue serialization:

```crystal
federation.activity_transformer do |_ctx, transform, activity|
  activity["audience"] = Aptok.json(transform.recipients.map(&.id))
  activity
end
```

The transformer receives a deep JSON copy of the outbound activity, so callers'
original activity maps are not mutated. Forwarded inbox activities are not
transformed; Aptok preserves the original forwarded body.

Aptok includes Fedify-style default compatibility transformers for outbound
activities:

```crystal
federation.default_activity_transformers

# Or install them individually.
federation.activity_transformer Aptok::Federation.auto_id_assigner
federation.activity_transformer Aptok::Federation.actor_dehydrator
federation.activity_transformer Aptok::Federation.public_audience_normalizer
federation.activity_transformer Aptok::Federation.attachment_array_normalizer
```

`auto_id_assigner` assigns a local fragment ID to outgoing activities that do
not already have `id` or `@id`, using the shape
`https://example.com/#Create/<random>`. Send validation still runs after
transformers, so outgoing activities must have both id and actor after
transformation. `actor_dehydrator` replaces inline actor
objects in the top-level `actor` property with their actor URI, including
arrays of actor values. `public_audience_normalizer` rewrites `Public` and
`as:Public` in audience fields to the ActivityStreams public collection URI.
`attachment_array_normalizer` wraps scalar `attachment` values as one-item
arrays. These normalizers run before Aptok creates outbound Object Integrity
Proofs, so the delivered wire shape is what gets signed.

`Federation#sent_activities` tracks delivered metadata. This is useful for
tests and mirrors the testing-oriented shape in `@fedify/testing`: each record
includes `sender_identifier`, `recipient`, `activity_id`, `activity`, `queued`,
`queue`, optional `raw_activity` for preserved forwarded payloads, and
monotonic `sent_order` metadata. Use `reset` or
`reset_sent_activities` between test phases, similar to Fedify's mock federation
reset helper.

`Aptok::Testing` also exposes small helpers for testing outbox code without a
web framework. `receive_activity` mirrors Fedify's mock `receiveActivity`
helper, while the POST helpers accept `context_data:` so listener tests can
exercise tenant or request-scoped data:

```crystal
federation = Aptok::Testing.create_federation("https://example.com")

rsa_key = Aptok::Testing.generate_rsa_key_pair(
  "https://example.com/users/alice"
)

ed25519_key = Aptok::Testing.generate_ed25519_key_pair(
  "https://example.com/users/alice",
  "https://example.com/users/alice#multikey-1"
)

request_ctx = Aptok::Testing.create_request_context(
  federation,
  Aptok::Request.new("GET", "/users/alice")
)

mocked_ctx = Aptok::Testing.create_context(
  federation,
  Aptok::Request.new("GET", "/users/alice"),
  recipient_identifier: "alice",
  context_data: Aptok.json({"tenant" => "test"}),
  document_loader: Aptok::DocumentLoader.new do |url|
    Aptok::JsonMap{"id" => Aptok.json(url)}.as(Aptok::JsonMap?)
  end
)

inbox_ctx = Aptok::Testing.create_inbox_context(federation, "alice")
inbox_ctx.identifier # => "alice"
inbox_ctx.recipient_identifier # => "alice"

ctx = Aptok::Testing.create_outbox_context(federation, "alice")
ctx.identifier # => "alice"
ctx.outbox_identifier # => "alice"
ctx.has_delivered_activity? # => false

inbox_response = Aptok::Testing.receive_activity(
  federation,
  Aptok.create(
    "https://remote.example/activities/1",
    "https://remote.example/users/bob",
    Aptok.note("https://remote.example/notes/1", "Hello")
  ),
  "alice",
  context_data: Aptok.json({"tenant" => "test"})
)

response = Aptok::Testing.post_outbox_activity(
  federation,
  "alice",
  Aptok.create(
    "https://example.com/activities/1",
    "https://example.com/users/alice",
    Aptok.note("https://example.com/notes/1", "Hello")
  ),
  context_data: Aptok.json({"tenant" => "test"})
)
```

Inside an outbox listener, `ctx.has_delivered_activity?` starts as `false` for
the routed activity and becomes `true` after `ctx.send_activity` or
`ctx.forward_activity` successfully sends or queues work.

If an outbox listener returns without delivering or forwarding the posted
activity, Aptok emits a warning on `aptok.federation.outbox`. Applications can
also observe that condition directly:

```crystal
federation.undelivered_outbox_activity do |ctx, activity|
  log_unfederated_outbox_post(ctx.outbox_identifier, activity["id"]?)
  nil
end
```

## Transport and Signatures

`Aptok::Transport` is the HTTP delivery layer. It posts ActivityPub JSON-LD to
recipient inboxes and can add legacy RSA HTTP Signature headers:

```crystal
transport = Aptok::Transport.new(
  signature_enabled: true,
  signature_key_path: "/etc/keys/private.pem",
  signature_key_id: "https://example.com/users/alice#main-key"
)
```

Testing hooks:

- `post_provider`: replaces network delivery.
- `detailed_post_provider`: replaces network delivery and can return response
  headers such as `Accept-Signature`.
- `headers_provider`: replaces signature header generation.

Transport still emits the older `(request-target) host date digest` RSA style by
default for fediverse compatibility. Actor key-pair dispatchers are preferred
for application code; `signature_key_path`/`signature_key_id` are still supported
as a static fallback. If a recipient responds with `401` and an
`Accept-Signature` challenge, delivery retries once with an RFC 9421 signature
that follows the first compatible challenge's requested components, nonce, tag,
and `expires` flag when a signing key is available. Challenge negotiation accepts
RSA SHA-256 or unspecified algorithms, skips challenges for a different key id,
and refuses request-invalid response components such as `@status`. Use
`Aptok::Signatures.attach_object_proof` before delivery when the activity itself
should carry an embedded `DataIntegrityProof`.

## Telemetry

Fedify includes OpenTelemetry instrumentation. Aptok keeps the core shard
dependency-free and exposes a small telemetry adapter surface that can be
bridged to OpenTelemetry, logs, or tests:

```crystal
class AppTelemetry < Aptok::Telemetry
  def span(name : String, attributes : Aptok::TelemetryAttributes = Aptok::TelemetryAttributes.new, &block)
    start_span(name, attributes)
    yield
  ensure
    finish_span(name)
  end

  def counter(name : String, value : Int64 = 1_i64, attributes : Aptok::TelemetryAttributes = Aptok::TelemetryAttributes.new) : Nil
    record_counter(name, value, attributes)
  end

  def histogram(name : String, value : Float64, attributes : Aptok::TelemetryAttributes = Aptok::TelemetryAttributes.new) : Nil
    record_histogram(name, value, attributes)
  end
end

federation = Aptok::Federation.create(
  "https://example.com",
  telemetry: AppTelemetry.new
)
```

The no-op default has no runtime dependency. Built-in instrumentation currently
records HTTP request spans and request counters/durations, inbox and outbox
routing spans/counters, and outbound delivery spans/counters.

For feature parity with Fedify's OpenTelemetry metrics without taking on an
external dependency, Aptok ships `Aptok::MetricsTelemetry`. It aggregates
counters, gauges, histograms, and `span` timings in memory (thread-safe behind a
`Mutex`) and renders them in the OpenMetrics / Prometheus text exposition format,
ready to serve from a `/metrics` endpoint that a Prometheus-compatible scraper
(or any OpenTelemetry collector with a Prometheus receiver) can read:

```crystal
metrics = Aptok::MetricsTelemetry.new

federation = Aptok::Federation.create(
  "https://example.com",
  telemetry: metrics
)

# span/counter/histogram/gauge are recorded automatically by the framework, or
# manually from application code:
metrics.counter("app.activities.created", attributes: Aptok::TelemetryAttributes{"type" => "Note"})
metrics.gauge("app.queue.depth", 12.0)
metrics.span("app.deliver") { deliver_activity }

# Serve from an HTTP handler.
exposition = metrics.to_openmetrics            # alias: to_prometheus
```

`span` records a `<name>_duration_seconds` histogram (plus a call counter) using
a monotonic clock, so request, routing, and delivery latencies are exported with
default buckets. Introspection helpers (`counter_value`, `gauge_value`,
`histogram_data`) and `reset` make `MetricsTelemetry` convenient in tests too.

## Stores, Queues, and Discovery

Fedify exposes pluggable stores and queues. Aptok includes small in-memory
versions for local apps and tests, plus Redis-backed adapters for durable
idempotency, cache, and queue state:

```crystal
store = Aptok::MemoryKvStore.new
store.set("actor:alice", "...")
store.list("actor:")
store.cas("lock:actor", nil, "alice")

queue = Aptok::InProcessMessageQueue.new
queue.enqueue(
  "outbox",
  activity,
  Aptok::EnqueueOptions.new(
    delay: Time::Span.new(seconds: 5),
    ordering_key: "alice"
  )
)

policy = Aptok::RetryPolicy.new(max_attempts: 3)
queue.listen("outbox", policy, limit: 10) do |message|
  # deliver message.payload
end
```

```crystal
redis = Aptok::RedisProtocolClient.from_url("redis://localhost:6379/0")
store = Aptok::RedisKvStore.new(redis, prefix: "my-app")
queue = Aptok::RedisMessageQueue.new(redis, prefix: "my-app")

federation = Aptok::Federation.create(
  "https://example.com",
  kv: store,
  inbox_queue: queue,
  outbox_queue: queue
)
```

`KvStore#list(prefix)` mirrors Fedify's required `KvStore.list()` capability
for enumerating related entries. `MemoryKvStore#cas` mirrors Fedify's optional
`KvStore.cas()` compare-and-swap operation for optimistic local coordination.
`RedisKvStore` supports `list` and atomic `cas`, using Redis `EVAL` for
compare-and-swap plus `GET`, `SET PX`, `DEL`, and prefix scans for `list`.
`RedisMessageQueue` stores scheduled messages in sorted sets and exposes the
same `enqueue`, `ready`, `enqueue_many`, `depth`, `get_depth`, `process_one`,
and `listen` helpers as the in-process queue.
`Context#process_queued_activities`, `#process_queued_inbox_activities`, and
`#process_queued_fanout_activities` consume any configured queue that implements
`MessageQueue#listen`, so Redis-backed workers can use the same processing
helpers as tests that use `InProcessMessageQueue`.

### SQL stores (SQLite & PostgreSQL)

For durable, transactional persistence without an external broker, Aptok
provides SQL-backed implementations of both the `KvStore` and `MessageQueue`
interfaces. `SqlKvStore` and `SqlMessageQueue` work over any object that includes
the `Aptok::SqlConnection` module; the bundled connections target SQLite and
PostgreSQL through Crystal's `DB` ecosystem, and the connection supplies the
right placeholder/upsert dialect by default. Both stores `migrate` their tables
on construction by default.

PostgreSQL is supported by `Aptok::PostgresConnection`, a thin adapter over
`will/crystal-pg`. Pull it in explicitly when you need PostgreSQL-backed
storage:

```crystal
require "aptok"
require "aptok/store/postgres"

conn = Aptok::PostgresConnection.connect("postgres://user:pass@localhost:5432/aptok")

store = Aptok::SqlKvStore.new(conn)
queue = Aptok::SqlMessageQueue.new(conn)

federation = Aptok::Federation.create(
  "https://example.com",
  kv: store,
  inbox_queue: queue,
  outbox_queue: queue
)
```

SQLite is supported by `Aptok::SqliteConnection`, a thin adapter over
`crystal-lang/crystal-sqlite3`. Because it links SQLite at compile time, it is
also opt-in:

```crystal
require "aptok"
require "aptok/store/sqlite"

conn = Aptok::SqliteConnection.open("aptok.db") # or ":memory:"

store = Aptok::SqlKvStore.new(conn)
queue = Aptok::SqlMessageQueue.new(conn)
```

`SqlKvStore` supports `get`/`set` with TTL expiry, `delete`, prefix `list`, and
atomic `cas`. `SqlMessageQueue` supports `enqueue`/`enqueue_many` with delay and
ordering keys, `depth`/`get_depth`, FIFO `process_one` with retry/backoff and a
dead-letter table, and `listen`, matching the in-process and Redis queues. You
can also point the SQL stores at any other engine by implementing
`Aptok::SqlConnection#execute` and `#query` over your own driver.

For Fedify-style queue observability, `MessageQueue#get_depth` returns
structured ready/delayed counts when the backend supports it. Custom backends can
leave it unimplemented and return `nil` from the default method:

```crystal
depth = queue.get_depth("outbox")
depth.try(&.queued)
depth.try(&.ready)
depth.try(&.delayed)
```

By default, Aptok starts lightweight Crystal fiber workers when queued inbox,
outbox, or fanout work is enqueued. This mirrors Fedify's default queue
lifecycle while keeping the shard framework-neutral. For a split web/worker
deployment, disable automatic startup in the web process and start the worker
process explicitly:

```crystal
federation = Aptok::Federation.create(
  "https://example.com",
  inbox_queue: queue,
  outbox_queue: queue,
  fanout_queue: queue,
  manually_start_queue: true
)

worker = federation.start_queue(
  options: Aptok::QueueStartOptions.new(
    queues: ["inbox", "outbox", "fanout"],
    poll_interval: Time::Span.new(seconds: 1),
    limit: 25
  )
)

Signal::INT.trap do
  worker.stop
  exit
end
```

`Federation#start_queue` is idempotent for queue roles that are already running,
and calling it again with a different `queues` subset adds the missing workers.
`#queue_started?` reports whether a worker is active, and `#stop_queue` stops
the current worker. `QueueStartOptions` can limit which queue roles run in a
process, which is useful when inbox, outbox, and fanout workers are scaled
separately.

External backends can still implement `MessageQueue#enqueue` for producer-side
integration and provide their own workers that deserialize `OutboundDelivery`
and `InboundDelivery` payloads. For Fedify-style worker integrations, pass the
queued task payload to `Federation#process_queued_task` or
`Context#process_queued_task`:

```crystal
federation.process_queued_task(message.payload, context_data: worker_data)

ctx = federation.create_context(context_data: worker_data)
ctx.process_queued_task(message.payload)
```

`OutboundDelivery` tasks deliver the activity and record sent metadata.
`InboundDelivery` tasks route to inbox listeners immediately and raise if no
listener handles the activity, so external queue backends can apply their own
retry policy. Inbound tasks produced by Aptok include trusted provenance after
HTTP verification or manual dereferencing. Custom producers can opt in with:

```crystal
payload = federation.inbound_delivery_payload("alice", verified_activity, trusted: true)
```

Discovery helpers:

```crystal
jrd = Aptok.webfinger_jrd(
  "acct:alice@example.com",
  "https://example.com/users/alice"
)

nodeinfo = Aptok.nodeinfo(
  "aptok-app",
  "0.1.0",
  software_repository: "https://github.com/example/aptok-app",
  software_homepage: "https://example.com",
  inbound_services: ["rss2.0"],
  outbound_services: ["wordpress"],
  users_total: 42,
  users_active_month: 7,
  local_posts: 100,
  local_comments: 5
)
```

The default WebFinger self link uses Fedify's `application/activity+json`
media type.

NodeInfo client lookup follows `/.well-known/nodeinfo`, uses the first
recognized NodeInfo 2.0 or 2.1 link in the JRD as Fedify does, and then fetches
the linked document. Default NodeInfo lookups send Fedify's
`Accept: application/json` header.
Aptok's NodeInfo document responses and well-known links use Fedify's NodeInfo
2.1 profile media type,
`application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.1#"`.
As in Fedify, the NodeInfo document route is advertised only after a NodeInfo
dispatcher is configured; otherwise `/.well-known/nodeinfo` returns an empty
JRD `links` array and `ctx.get_nodeinfo_uri` raises.

```crystal
nodeinfo = ctx.lookup_nodeinfo("https://remote.example")
same_nodeinfo = ctx.lookup_nodeinfo(URI.parse("https://remote.example/users/alice"))
```

Like Fedify's `getNodeInfo()`, non-direct lookups resolve
`/.well-known/nodeinfo` from the origin root even when the input URI has a path.

Use `best-effort` for slightly invalid remote documents, `none` to return raw
JSON without validation, or `direct: true` when you already have the NodeInfo
document URL:

```crystal
raw = ctx.lookup_nodeinfo(
  "https://remote.example/nodeinfo/2.1",
  Aptok::NodeInfoLookupOptions.new(direct: true, parse: "none")
)
```

Use `lookup_nodeinfo_document` when you want the Fedify-like typed NodeInfo
client surface instead of raw JSON. Strict parsing rejects invalid software
names, unsupported protocols/services, malformed optional `services`,
`openRegistrations`, `usage`, or `metadata` fields, and negative usage
counters. As in Fedify, a `services` object may include only `inbound`, only
`outbound`, or neither field. Missing top-level `version` or `usage` fields are
normalized to NodeInfo 2.1 defaults, and unsupported top-level `version` values
do not reject the document; when `usage` is present it must include a `users`
object, while missing `localPosts` or `localComments` counters default to zero.
Non-string software versions are stringified while parsing; `parse:
"best-effort"` lowercases and trims otherwise valid software names, but still
rejects names with unsupported characters, matching Fedify's parser. Invalid
software `repository` and `homepage` values are ignored in best-effort mode,
and usage counters are parsed with Fedify-like integer-prefix handling. Negative
integer counters can be parsed from remote documents, but serialization rejects
them.
`Aptok.nodeinfo_to_json` serializes typed values back to NodeInfo 2.1 JSON with
the same version and schema marker Fedify emits, even when the typed value came
from a NodeInfo 2.0 fallback document.

```crystal
nodeinfo = ctx.lookup_nodeinfo_document("https://remote.example")
if nodeinfo
  nodeinfo.software.name
  nodeinfo.usage.users.total
end

semver = Aptok.parse_semver(nodeinfo.software.version) if nodeinfo
json = Aptok.nodeinfo_to_json(nodeinfo) if nodeinfo
```

Applications can override discovery responses in the Fedify style:

```crystal
federation.handles do |_ctx, username|
  lookup_user_id_by_handle(username)
end

federation.aliases do |_ctx, resource|
  lookup_user_id_by_profile_url(resource)
end

federation.aliases do |_ctx, resource|
  # Fedify-style aliases may return either an internal identifier directly
  # or a username that is resolved through `handles`.
  resource == "https://example.com/@alice" ? {username: "alice"} : nil
end

federation.webfinger_links do |_ctx, resource|
  [
    Aptok::JsonMap{
      "rel"      => Aptok.json("http://ostatus.org/schema/1.0/subscribe"),
      "template" => Aptok.json("https://example.com/authorize_interaction?uri={uri}"),
    },
  ]
end

federation.webfinger do |_ctx, resource, identifier|
  Aptok.webfinger_jrd(
    resource,
    "https://example.com/users/#{identifier}",
    properties: Aptok::JsonMap{
      "https://example.com/ns#role" => Aptok.json("maintainer"),
    }
  ).as(Aptok::JsonMap?)
end

federation.nodeinfo "/nodeinfo/custom" do |_ctx|
  Aptok.nodeinfo(
    "my-app",
    "1.0.0",
    metadata: Aptok::JsonMap{"nodeName" => Aptok.json("My node")}
  )
end
```

WebFinger accepts URI-form resources, returns Fedify-style plain-text `400`
responses for missing, whitespace-bearing, or malformed HTTP(S) `resource`
parameters,
accepts `acct:` resources for the configured handle host and canonical origin
authority, including a port when one is configured, and resolves local actor URL
resources through `parse_uri` before falling back to alias mapping for other URI
schemes. Like Fedify, URI-form resources remain the JRD `subject`; `acct:`
resource hosts are normalized with lowercasing and Punycode before host
matching and before being emitted as the JRD `subject`. Account handles are
exposed through `aliases` alongside the actor self link. Plain actor `url`
values become profile-page links without a media type, while structured link
objects can provide `mediaType` or `type`, matching Fedify's WebFinger output.

## ForgeFed

ForgeFed repository and push objects can be built directly:

```crystal
repo = Aptok.forgefed_repository(
  "https://example.com/repos/aptok",
  "aptok",
  "https://example.com/repos/aptok/inbox",
  "https://example.com/repos/aptok/outbox",
  clone_uri: "https://example.com/repos/aptok.git",
  push_uris: ["ssh://git@example.com/aptok.git"],
  tickets_tracked_by: "https://example.com/repos/aptok",
  send_patches_to: "https://example.com/repos/aptok"
)

branch = Aptok.forgefed_branch(
  "https://example.com/repos/aptok/branches/main",
  "https://example.com/repos/aptok",
  "main",
  "refs/heads/main"
)

commit = Aptok.forgefed_commit(
  "https://example.com/repos/aptok/commits/be9f48",
  "https://example.com/repos/aptok",
  "be9f48",
  "https://example.com/users/alice",
  "Add signed delivery",
  files_added: ["src/federation.cr"],
  files_modified: ["README.md"]
)

push = Aptok.forgefed_push(
  "https://example.com/repos/aptok/outbox/push-1",
  "https://example.com/repos/aptok",
  "https://example.com/users/alice",
  branch["id"].as_s,
  [commit],
  "017cbb",
  "be9f48"
)

project = Aptok.forgefed_project(
  "https://example.com/projects/aptok",
  "Aptok",
  inbox: "https://example.com/projects/aptok/inbox",
  outbox: "https://example.com/projects/aptok/outbox"
)

tag = Aptok.forgefed_tag(
  "https://example.com/repos/aptok/tags/v1.0.0",
  "v1.0.0",
  context: repo["id"].as_s
)

tickets = Aptok.forgefed_ticket_tracker(
  "https://example.com/repos/aptok/tickets",
  "Tickets",
  context: repo["id"].as_s
)

patches = Aptok.forgefed_patch_tracker(
  "https://example.com/repos/aptok/patches",
  "Patches",
  context: repo["id"].as_s
)
```

ForgeFed task handoff can be built with `forgefed_ticket`:

```crystal
dependency = Aptok.forgefed_ticket_dependency(
  "https://example.com/ticket-deps/1",
  "https://example.com/tickets/1",
  "https://example.com/tickets/0",
  attributed_to: "https://example.com/users/alice",
  summary: "Delivery bug depends on the tracked regression"
)

ticket = Aptok.forgefed_ticket(
  "https://example.com/tickets/1",
  "Fix federation delivery",
  "Inbox delivery fails on 410 responses",
  assignee: "https://remote.example/users/maintainer",
  attributed_to: "https://example.com/users/alice",
  depends_on: [dependency]
)

activity = Aptok.create(
  "https://example.com/activities/create-ticket-1",
  "https://example.com/users/alice",
  ticket
)
```

Merge requests are represented in the current ForgeFed draft as ticket-like
objects with patch metadata, so Aptok exposes a builder for that JSON-LD shape:

```crystal
mr = Aptok.forgefed_merge_request(
  "https://example.com/mrs/1",
  "Add ActivityPub support",
  "Implements signed inbox delivery",
  "https://example.com/repos/aptok",
  "https://remote.example/repos/app/branches/activitypub",
  "https://example.com/repos/aptok/branches/main",
  mr_diff: "https://example.com/mrs/1.diff"
)
```

ForgeFed-specific interaction activities add the ForgeFed context and parse back
to typed vocabulary classes:

```crystal
resolved = Aptok.forgefed_resolve(
  "https://example.com/activities/resolve-1",
  "https://example.com/users/alice",
  ticket,
  target: repo["id"].as_s
)

applied = Aptok.forgefed_apply(
  "https://example.com/activities/apply-1",
  "https://example.com/users/alice",
  "https://example.com/patches/1",
  target: branch["id"].as_s
)
```

Use the optional strict validators when receiving ForgeFed documents from remote
servers:

```crystal
return unless Aptok.valid_forgefed?(resolved)
Aptok.validate_forgefed!(commit)
```

## Marketplace

Marketplace-style offers can be represented with `marketplace_offer`:

```crystal
service = Aptok.object("Service", "https://example.com/services/solver", Aptok::JsonMap{
  "name" => Aptok.json("Solver access"),
})

offer = Aptok.marketplace_offer(
  "https://example.com/offers/1",
  "https://example.com/users/alice",
  service,
  "Solver access",
  price: "10",
  currency: "USD"
)
```

Product listings can use the lighter marketplace vocabulary helpers:

```crystal
product = Aptok.marketplace_product(
  "https://example.com/products/solver",
  "Solver access",
  summary: "Priority solver access"
)
service = Aptok.marketplace_service(
  "https://example.com/services/review",
  "Review service",
  summary: "Code review",
  provider: "https://example.com/users/alice",
  terms_of_service: "https://example.com/terms"
)
price = Aptok.marketplace_price_specification("10", "USD", unit_text: "month")
listing = Aptok.marketplace_listing(
  "https://example.com/listings/solver",
  "https://example.com/users/alice",
  service,
  "Solver subscription",
  price
)
```

FEP-0837 proposal and agreement flows can be composed with Valueflows-style
intent and commitment builders:

```crystal
primary = Aptok.marketplace_intent(
  "https://market.example/proposals/1#primary",
  "transfer",
  Aptok.marketplace_quantity(value: "1")
)

proposal = Aptok.marketplace_proposal(
  "https://market.example/proposals/1",
  "offer",
  "https://market.example/users/alice",
  primary,
  name: "Used bike"
)

agreement = Aptok.marketplace_agreement(
  Aptok.marketplace_commitment(
    "https://market.example/proposals/1#primary",
    Aptok.marketplace_quantity(value: "1")
  )
)

offer = Aptok.marketplace_agreement_offer(
  "https://social.example/offers/1",
  "https://social.example/users/bob",
  agreement,
  ["https://market.example/users/alice"]
)
```

FEP-0837 documents can also be checked explicitly before application code accepts
them:

```crystal
Aptok.valid_fep_0837?(proposal)
Aptok.validate_fep_0837!(agreement)
```

These helpers build JSON-LD vocabulary objects. Routing, persistence,
negotiation state machines, payment execution, and transaction settlement remain
application concerns.

## Current Scope Compared To Fedify

Implemented now:

- `Federation` registry and `Context` URI helpers,
- Crystal-style `Aptok.federation` setup DSL,
- Fedify-style `FederationOrigin` handle/web origin object,
- Fedify-style HTTP(S) origin-root validation,
- optional trailing-slash-insensitive route matching,
- actor/object/outbox dispatchers,
- followers/following/inbox/liked/featured/featured-tags collection dispatchers,
- unordered and ordered custom collection dispatchers,
- Fedify-style collection item filters,
- typed inbox listener routing,
- typed outbox listener routing for client-to-server POSTs,
- framework-neutral request/response routing,
- Fedify-style KV listing for memory and Redis stores,
- Fedify-style in-memory KV compare-and-swap,
- Fedify-style WebFinger URI and `mailto:` lookup resources,
- Fedify-style per-call lookup document loaders,
- Fedify-style URL/Crystal URI object lookup identifiers,
- Fedify-style `cross_origin: "throw"` lookup strict mode,
- outbound `send_activity`,
- outbound activity transformers for compatibility adjustments,
- followers-recipient expansion for `send_activity`,
- Fedify-style fan-out queue tasks for large collection delivery,
- queued outbound delivery with retries for in-process and Redis queues,
- Fedify-style batch queue enqueueing with `MessageQueue#enqueue_many`,
- Fedify-style structured queue depth reporting,
- configurable permanent delivery failure status codes,
- queued inbound inbox processing with retries for in-process queues,
- inbox forwarding with original-body delivery,
- actor key-pair dispatchers,
- automatic actor `publicKey` enrichment,
- dynamic RSA HTTP signing for immediate and queued delivery,
- Fedify-style `{identifier: ...}` and `{username: ...}` sender identities,
- automatic Ed25519 Object Integrity Proof signing before recipient delivery,
- resolver-backed inbox RSA signature verification with actor/key-owner checks,
- signed-fetch access control for actor/object/collection routes,
- remote object lookup by URL, handle, or `acct:` URI,
- KV-backed remote document cache decorators,
- separate context loader support on federation contexts,
- configurable built-in document-loader user agent,
- authenticated document loaders for signed GET fetches,
- personal and shared-inbox authenticated document loaders,
- collection traversal across `first`/`next` pages,
- Fedify-style best-effort collection traversal with suppressed page errors,
- object URI construction and local URI parsing,
- Fedify-style `get_actor` and `get_object` context helpers,
- simple and reserved URI template expansion,
- ActivityStreams JSON-LD builders,
- ForgeFed repository, project, branch, commit, tag, push, ticket,
  ticket-tracker, patch-tracker, merge-request, and typed activity builders,
- marketplace offer/service/listing plus FEP-0837 proposal/agreement builders
  and strict validators,
- Ed25519/Multikey `eddsa-jcs-2022` Object Integrity Proof helpers,
- remote Multikey fetching/caching for proof verification,
- RSA-backed `DataIntegrityProof` helpers for local canonical JSON proofs,
- in-memory, Redis, and SQL (SQLite/PostgreSQL) KV/queue helpers,
- OpenMetrics/Prometheus metrics telemetry exporter,
- WebFinger and NodeInfo builders,
- NodeInfo client lookup with Fedify-style JRD link ordering, URI inputs, origin-root discovery, direct, raw, and typed modes,
- custom WebFinger and NodeInfo dispatchers,
- inbox idempotency with `per-inbox`, `per-origin`, `global`, and custom strategies,
- basic inbox verification hooks,
- cursor and offset outbox paging,
- offset paging for named collection dispatchers,
- simple test hooks and sent-activity tracking.

Still future work:

- broader JSON-LD typed class coverage,
- durable remote document caches,
- broader RFC 9421 response-signature coverage beyond request signing and
  challenge retries.

For a feature-by-feature breakdown against Fedify, including the ForgeFed and
marketplace (FEP-0837) helpers, see [`docs/FEDIFY_PARITY.md`](docs/FEDIFY_PARITY.md).

## Development

The repository ships POSIX `sh` hooks under `.meta/hooks/` that check the spec —
formatting, a type-checking build, and the full `crystal spec` suite:

```sh
.meta/hooks/check-all.sh                      # format (warn) + build + spec
APTOK_STRICT_FORMAT=1 .meta/hooks/check-all.sh  # also enforce formatting (CI)
ameba                                          # optional static analysis
```

See [`.meta/hooks/README.md`](.meta/hooks/README.md) for details and how to wire
them up as a git `pre-push` hook. CI runs the same hooks via
`.github/workflows/spec.yml`.

## Using From `crater-openai`

The app provider uses `Aptok::Transport`, `Aptok::PublishRequest`, and
`Aptok::DeliveryConfig` as a compatibility layer for the gateway provider.
New code should prefer `Federation` and `Context#send_activity` for Fedify-style
apps.

## Federation Metadata (FEP-67ff)

Following [FEP-67ff][fep-67ff], the repository ships a
[`FEDERATION.md`](FEDERATION.md) document describing which ActivityPub, ForgeFed,
and FEP behaviors Aptok implements, the supported endpoints, and the
authentication mechanisms. Downstream applications embedding Aptok are
encouraged to provide their own `FEDERATION.md` describing their deployment.

[fep-67ff]: https://codeberg.org/fediverse/fep/src/branch/main/fep/67ff/fep-67ff.md

## License

Aptok is distributed under the [BSD Zero Clause License](LICENSE) (0BSD), a
public-domain-equivalent license with no attribution requirement.
