# Fedify parity, ForgeFed & marketplace assessment

This document answers issue #1 items 2 and 3: how much of [Fedify][fedify] the
Aptok toolkit currently covers, and the state of the ForgeFed and marketplace
(FEP-0837) helpers. It is a living map — update it as features land.

The columns mean:

- **✅ Implemented** — present with passing specs in `spec/aptok_spec.cr`.
- **🟡 Partial** — a usable subset exists; notable limitations are listed.
- **❌ Missing** — not implemented yet.

[fedify]: https://github.com/fedify-dev/fedify

## Core framework

| Fedify capability | Aptok | Where |
| --- | --- | --- |
| Type-safe Activity vocabulary objects | ✅ | `src/vocabulary/*` |
| `Federation` / `Context` objects | ✅ | `src/federation/*` |
| Crystal-style federation setup DSL | ✅ | `Aptok.federation` |
| Actor dispatcher | ✅ | `actor` |
| Object dispatcher | ✅ | `object` |
| Outbox dispatcher | ✅ | `outbox` |
| Collection dispatchers (followers/following/inbox/custom) | ✅ | `src/federation/federation_routing*` |
| Cursor & paginated collections | ✅ | `paginated_collection`, `cursor_collection*` |
| Typed inbox listeners | ✅ | `inbox ... do |routes| routes.on ... end` |
| Inbox idempotency | ✅ | `with_idempotency` |
| `Context#send_activity` delivery | ✅ | `src/federation/federation_context_delivery*` |
| Followers-recipient expansion | ✅ | `src/federation/federation_delivery*` |
| Inbox forwarding (original body) | ✅ | `src/federation/federation_delivery*` |
| Framework-agnostic request routing | ✅ | `Federation#handle` / `#fetch` |

## Security & authentication

| Fedify capability | Aptok | Where / notes |
| --- | --- | --- |
| HTTP Signatures (draft-cavage) | ✅ | `Signatures.rsa_sha256_headers`, `verify_rsa_sha256?` |
| HTTP Message Signatures (RFC 9421) | ✅ | `rfc9421_rsa_sha256_headers`, `verify_rfc9421_rsa_sha256?` |
| Signature negotiation (`Accept-Signature`) | ✅ | `parse_accept_signatures` |
| Object Integrity Proofs (eddsa-jcs / Ed25519) | ✅ | `create_object_proof`, `verify_object_proof?`, `src/signatures/signatures_sign.cr` |
| Multikey / `publicKeyMultibase` | ✅ | `Aptok.multikey`, `ed25519_public_key_multibase` |
| Signed-fetch access control | ✅ | GET-route gating in `src/federation/*` |
| Authenticated document loader | ✅ | `src/remote/remote_entry.cr` |
| Linked Data Signatures (RsaSignature2017) | ❌ | Only the newer Data Integrity proofs are implemented. |

> **Replay / `created` age note.** RFC 9421 verification enforces the upper
> `created` bound and `expires` against `max_clock_skew`, but intentionally does
> **not** reject old `created` timestamps when no `expires` is present
> (`src/signatures/signatures_headers.cr:61`). This is by design and covered by
> `spec/aptok_spec.cr` (a signature created in 2024 verifies at today's clock).
> Callers who need strict replay protection should require an `expires`
> component or track nonces.

## Discovery & interoperability

| Fedify capability | Aptok | Where |
| --- | --- | --- |
| WebFinger server (JRD) | ✅ | `Aptok.webfinger_jrd`, handle/alias mapping |
| WebFinger client lookup | ✅ | `src/remote/remote_delivery.cr` |
| NodeInfo document builder | ✅ | `Aptok.nodeinfo`, `nodeinfo_well_known` |
| NodeInfo client lookup + typed parsing | ✅ | `lookup_nodeinfo`, `parse_nodeinfo` |
| Remote document/object loading & collection traversal | ✅ | `src/remote/*` |
| Mastodon-flavoured vocabulary (Emoji, etc.) | 🟡 | Emoji/hashtag/property-value present; some vendor extensions missing. |

## Infrastructure

| Fedify capability | Aptok | Where / notes |
| --- | --- | --- |
| Key-value store | ✅ | `MemoryKvStore`, `RedisKvStore`, `SqlKvStore` |
| Message queue + retry | ✅ | `InProcessMessageQueue`, `RedisMessageQueue`, `SqlMessageQueue`, `QueueWorker` |
| AMQP / RabbitMQ driver | ❌ | Redis is the only external broker. |
| SQL stores (Postgres/SQLite) | ✅ | `SqlKvStore` + `SqlMessageQueue` over a `SqlConnection`; `PostgresConnection` uses `will/crystal-pg`, and opt-in `SqliteConnection` uses `crystal-lang/crystal-sqlite3`. MySQL not yet provided. |
| Telemetry / metrics hooks | ✅ | `MetricsTelemetry` aggregates counters/gauges/histograms/span timings and renders OpenMetrics / Prometheus text (`to_openmetrics`). |

## Developer tooling & integration

| Fedify capability | Aptok | Where / notes |
| --- | --- | --- |
| Standard-library HTTP integration | ✅ | `request_from_http`, `write_http_response` |
| Web framework integration | 🟡 | Kemal adapter (`src/http/kemal.cr`) + generic `Request`/`Response`. Others (Express/Hono/etc.) are JS-only and N/A. |
| Test capture helpers | ✅ | `src/testing.cr`, injectable HTTP/signature hooks |
| Spec-check hooks | ✅ | `.meta/hooks/` (added in this PR) |
| CLI toolchain | ❌ | No `aptok` CLI yet. |
| Debug dashboard | ❌ | Not implemented. |

## ForgeFed coverage

This section maps Aptok against the [ForgeFed vocabulary spec][forgefed-vocab].
Builders live in `src/vocabulary/vocabulary_forgefed*`; round-trip
`from_json_ld` parsers exist for the trackers, tickets, ticket dependencies,
and pushes.

[forgefed-vocab]: https://forgefed.org/vocabulary.html

### Object & Actor types

| ForgeFed type | Aptok | Notes |
| --- | --- | --- |
| Repository | ✅ `Aptok.forgefed_repository` | Actor type with `team`/`forks` collections. |
| Project | ✅ `Aptok.forgefed_project` | |
| Branch | ✅ `Aptok.forgefed_branch` | `ref` + `Repository` linkage. |
| Commit | ✅ `Aptok.forgefed_commit` | `committedBy`, `hash`, `committed`, `created`. |
| Tag | ✅ `Aptok.forgefed_tag` | |
| Push | ✅ `Aptok.forgefed_push` | Activity carrying `Commit`s onto a `Branch`. |
| Ticket | ✅ `Aptok.forgefed_ticket` | `isResolved` round-trips. |
| TicketTracker | ✅ `Aptok.forgefed_ticket_tracker` | |
| PatchTracker | ✅ `Aptok.forgefed_patch_tracker` | |
| TicketDependency | ✅ `Aptok.forgefed_ticket_dependency` | Builds and parses the `Relationship`/`TicketDependency` object with `subject`, `relationship: "dependsOn"`, and `object`. |
| Patch / Diff | ❌ | No dedicated helper; model patches via generic objects. |

### Activity / interaction types

| ForgeFed pattern | Aptok | Notes |
| --- | --- | --- |
| Offer a ticket/patch (`Offer`) | ✅ `Aptok.forgefed_merge_request` | Builds an `Offer` with the patch as `object` and tracker as `target`. |
| Push (`Push` activity) | ✅ `Aptok.forgefed_push` | |
| Resolve / reopen ticket | ✅ `Aptok.forgefed_resolve` | Parses as `Aptok::Vocab::Resolve`. |
| Apply a patch (`Apply`) | ✅ `Aptok.forgefed_apply` | Parses as `Aptok::Vocab::Apply`. |
| Grant / Revoke access | ✅ `Aptok.forgefed_grant`, `Aptok.forgefed_revoke` | Typed activity builders with ForgeFed context. |

### Properties & context

| Capability | Aptok | Notes |
| --- | --- | --- |
| ForgeFed `@context` injection | ✅ | Attached by every `forgefed_*` builder. |
| `committedBy` / `hash` / `committed` | ✅ | On `forgefed_commit`. |
| `isResolved` | ✅ | On `forgefed_ticket`. |
| `dependsOn` / `dependants` typed accessors | ✅ | On `Ticket`; values can be links or typed dependency objects. |
| `filesAdded` / `filesModified` / `filesRemoved` | ✅ | On `Commit`; builders accept file-list arrays. |
| Strict validation | ✅ | `valid_forgefed?`, `validate_forgefed!`, and validation error helpers. |

**Gaps:** there is no dedicated `Patch`/`Diff` object helper, and not all
optional collections (e.g. `team`) have typed accessors.

## Marketplace / FEP-0837 coverage

Builders live in `src/vocabulary/vocabulary_marketplace*`; FEP-0837 / ValueFlows
terms are mapped in `Aptok.marketplace_context`.

| Concept | Aptok |
| --- | --- |
| Offer / Service / Product | ✅ `MarketplaceOffer`, `MarketplaceService`, `Product` |
| Listing | ✅ `Aptok.marketplace_listing`, `Listing` |
| PriceSpecification / Measure | ✅ `PriceSpecification`, `Measure`, `marketplace_quantity` |
| Intent | ✅ `Aptok.marketplace_intent`, `Intent` |
| Proposal (FEP-0837) | ✅ `Aptok.marketplace_proposal`, `Proposal` |
| Commitment | ✅ `Aptok.marketplace_commitment`, `Commitment` |
| Agreement / Offer-agreement | ✅ `Aptok.marketplace_agreement`, `marketplace_agreement_offer`, `Agreement` |
| Payment link | ✅ `Aptok.marketplace_payment_link` |

**Validation:** deserialization remains permissive, but callers can opt into
strict checks with `valid_fep_0837?`, `validate_fep_0837!`, and validation error
helpers before accepting remote documents.

## Suggested roadmap (genuine missing parts)

1. Linked Data Signatures (RsaSignature2017) for older fediverse software.
2. An `aptok` CLI for fetching/inspecting objects and verifying signatures.
3. An AMQP/RabbitMQ queue driver and a MySQL `SqlConnection` behind the existing
   interfaces (SQLite and PostgreSQL `SqlConnection`s already ship via Crystal
   `DB` adapters).
4. A full RFC 6570 URI Template implementation (the current `RouteTemplate` is a
   pragmatic subset — simple `{var}` and trailing `{+var}` operators).
5. Dedicated ForgeFed `Patch`/`Diff` object helpers.
