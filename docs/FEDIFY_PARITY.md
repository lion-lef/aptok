# Fedify parity, ForgeFed & marketplace assessment

This document answers issue #1 items 2 and 3: how much of [Fedify][fedify] the
Aptork toolkit currently covers, and the state of the ForgeFed and marketplace
(FEP-0837) helpers. It is a living map — update it as features land.

The columns mean:

- **✅ Implemented** — present with passing specs in `spec/aptork_spec.cr`.
- **🟡 Partial** — a usable subset exists; notable limitations are listed.
- **❌ Missing** — not implemented yet.

[fedify]: https://github.com/fedify-dev/fedify

## Core framework

| Fedify capability | Aptork | Where |
| --- | --- | --- |
| Type-safe Activity vocabulary objects | ✅ | `src/vocabulary/*` |
| `Federation` / `Context` objects | ✅ | `src/federation/*` |
| Fedify-style integration builder | ✅ | `Aptork.create_federation_builder`, `Federation.build` |
| Actor dispatcher | ✅ | `set_actor_dispatcher` |
| Object dispatcher | ✅ | `set_object_dispatcher` |
| Outbox dispatcher | ✅ | `set_outbox_dispatcher` |
| Collection dispatchers (followers/following/inbox/custom) | ✅ | `src/federation/federation_routing*` |
| Cursor & paginated collections | ✅ | `paginated_collection`, `cursor_collection*` |
| Typed inbox listeners | ✅ | `set_inbox_listeners(...).on(...)` |
| Inbox idempotency | ✅ | `with_idempotency` |
| `Context#send_activity` delivery | ✅ | `src/federation/federation_context_delivery*` |
| Followers-recipient expansion | ✅ | `src/federation/federation_delivery*` |
| Inbox forwarding (original body) | ✅ | `src/federation/federation_delivery*` |
| Framework-agnostic request routing | ✅ | `Federation#handle` / `#fetch` |

## Security & authentication

| Fedify capability | Aptork | Where / notes |
| --- | --- | --- |
| HTTP Signatures (draft-cavage) | ✅ | `Signatures.rsa_sha256_headers`, `verify_rsa_sha256?` |
| HTTP Message Signatures (RFC 9421) | ✅ | `rfc9421_rsa_sha256_headers`, `verify_rfc9421_rsa_sha256?` |
| Signature negotiation (`Accept-Signature`) | ✅ | `parse_accept_signatures` |
| Object Integrity Proofs (eddsa-jcs / Ed25519) | ✅ | `create_object_proof`, `verify_object_proof?`, `src/signatures/signatures_sign.cr` |
| Multikey / `publicKeyMultibase` | ✅ | `Aptork.multikey`, `ed25519_public_key_multibase` |
| Signed-fetch access control | ✅ | GET-route gating in `src/federation/*` |
| Authenticated document loader | ✅ | `src/remote/remote_entry.cr` |
| Linked Data Signatures (RsaSignature2017) | ❌ | Only the newer Data Integrity proofs are implemented. |

> **Replay / `created` age note.** RFC 9421 verification enforces the upper
> `created` bound and `expires` against `max_clock_skew`, but intentionally does
> **not** reject old `created` timestamps when no `expires` is present
> (`src/signatures/signatures_headers.cr:61`). This is by design and covered by
> `spec/aptork_spec.cr` (a signature created in 2024 verifies at today's clock).
> Callers who need strict replay protection should require an `expires`
> component or track nonces.

## Discovery & interoperability

| Fedify capability | Aptork | Where |
| --- | --- | --- |
| WebFinger server (JRD) | ✅ | `Aptork.webfinger_jrd`, handle/alias mapping |
| WebFinger client lookup | ✅ | `src/remote/remote_delivery.cr` |
| NodeInfo document builder | ✅ | `Aptork.nodeinfo`, `nodeinfo_well_known` |
| NodeInfo client lookup + typed parsing | ✅ | `lookup_nodeinfo`, `parse_nodeinfo` |
| Remote document/object loading & collection traversal | ✅ | `src/remote/*` |
| Mastodon-flavoured vocabulary (Emoji, etc.) | 🟡 | Emoji/hashtag/property-value present; some vendor extensions missing. |

## Infrastructure

| Fedify capability | Aptork | Where / notes |
| --- | --- | --- |
| Key-value store | ✅ | `MemoryKvStore`, `RedisKvStore` |
| Message queue + retry | ✅ | `InProcessMessageQueue`, `RedisMessageQueue`, `QueueWorker` |
| AMQP / RabbitMQ driver | ❌ | Redis is the only external broker. |
| SQL stores (Postgres/MySQL/SQLite) | ❌ | Not provided; bring your own via the `KvStore` interface. |
| Telemetry / metrics hooks | 🟡 | `src/telemetry.cr` collects counters; no OpenTelemetry exporter. |

## Developer tooling & integration

| Fedify capability | Aptork | Where / notes |
| --- | --- | --- |
| Standard-library HTTP integration | ✅ | `request_from_http`, `write_http_response` |
| Web framework integration | 🟡 | Kemal adapter (`src/http/kemal.cr`) + generic `Request`/`Response`. Others (Express/Hono/etc.) are JS-only and N/A. |
| Test capture helpers | ✅ | `src/testing.cr`, injectable HTTP/signature hooks |
| Spec-check hooks | ✅ | `.meta/hooks/` (added in this PR) |
| CLI toolchain | ❌ | No `aptork` CLI yet. |
| Debug dashboard | ❌ | Not implemented. |

## ForgeFed coverage

Builders live in `src/vocabulary/vocabulary_forgefed*`; round-trip
`from_json_ld` parsers exist for the trackers/tickets/pushes.

| ForgeFed type | Aptork builder |
| --- | --- |
| Repository | ✅ `Aptork.forgefed_repository` |
| Project | ✅ `Aptork.forgefed_project` |
| Branch | ✅ `Aptork.forgefed_branch` |
| Commit | ✅ `Aptork.forgefed_commit` |
| Tag | ✅ `Aptork.forgefed_tag` |
| Push | ✅ `Aptork.forgefed_push` |
| Ticket | ✅ `Aptork.forgefed_ticket` |
| TicketTracker | ✅ `Aptork.forgefed_ticket_tracker` |
| PatchTracker | ✅ `Aptork.forgefed_patch_tracker` |
| MergeRequest | ✅ `Aptork.forgefed_merge_request` |

**Gaps:** there is no dedicated `Patch`/`Diff` object helper, and the ForgeFed
`@context` is attached but not all optional collections (e.g. `team`,
`dependants`) have typed accessors.

## Marketplace / FEP-0837 coverage

Builders live in `src/vocabulary/vocabulary_marketplace*`; FEP-0837 / ValueFlows
terms are mapped in `Aptork.marketplace_context`.

| Concept | Aptork |
| --- | --- |
| Offer / Service / Product | ✅ `MarketplaceOffer`, `MarketplaceService`, `Product` |
| Listing | ✅ `Aptork.marketplace_listing`, `Listing` |
| PriceSpecification / Measure | ✅ `PriceSpecification`, `Measure`, `marketplace_quantity` |
| Intent | ✅ `Aptork.marketplace_intent`, `Intent` |
| Proposal (FEP-0837) | ✅ `Aptork.marketplace_proposal`, `Proposal` |
| Commitment | ✅ `Aptork.marketplace_commitment`, `Commitment` |
| Agreement / Offer-agreement | ✅ `Aptork.marketplace_agreement`, `marketplace_agreement_offer`, `Agreement` |
| Payment link | ✅ `Aptork.marketplace_payment_link` |

**Gaps:** deserialization does not enforce FEP-0837 required properties (e.g. a
`Listing` may parse with an empty `to`); validation is left to the caller.

## Suggested roadmap (genuine missing parts)

1. Linked Data Signatures (RsaSignature2017) for older fediverse software.
2. An `aptork` CLI for fetching/inspecting objects and verifying signatures.
3. Additional queue/store drivers (AMQP, SQL) behind the existing interfaces.
4. A full RFC 6570 URI Template implementation (the current `RouteTemplate` is a
   pragmatic subset — simple `{var}` and trailing `{+var}` operators).
5. Optional strict-mode validators for ForgeFed and FEP-0837 documents.
