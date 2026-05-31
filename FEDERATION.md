# Federation

This document describes how **Aptok** federates, following the convention
defined by [FEP-67ff: FEDERATION.md][fep-67ff]. Aptok is a Crystal toolkit for
building ActivityPub servers (inspired by [Fedify][fedify]); the federation
behavior listed here is what the toolkit itself implements and exposes to
applications built on top of it.

## Supported federation protocols and standards

- **[ActivityPub][activitypub]** — server-to-server (federation) protocol.
  Actor, object, outbox, inbox, followers, following and custom collection
  dispatchers; typed inbox listeners; `Create`/`Follow`/`Accept`/`Undo`/`Like`/
  `Announce`/`Delete` and ForgeFed/marketplace activities.
- **[ActivityStreams 2.0][as2]** — the vocabulary objects in `src/vocabulary/*`
  serialize to and parse from AS2 JSON-LD (`application/activity+json` and
  `application/ld+json; profile="…activitystreams"`).
- **[ForgeFed][forgefed]** — repository, project, branch, commit, push, ticket,
  merge request, ticket dependency, and access activity helpers with typed
  parsing and optional strict validation.
- **[WebFinger (RFC 7033)][webfinger]** — JRD server (`/.well-known/webfinger`)
  with handle/alias/link mapping, and a client lookup helper.
- **[HTTP Signatures (draft-cavage-http-signatures)][cavage]** — signing and
  verification of inbox POSTs and signed GETs (`rsa-sha256`).
- **[HTTP Message Signatures (RFC 9421)][rfc9421]** — the newer signature suite,
  including `Accept-Signature` negotiation.
- **[NodeInfo 2.0 / 2.1][nodeinfo]** — document builder, `/.well-known/nodeinfo`
  discovery, dispatcher route, and a typed client lookup.

## Supported FEPs

| FEP | Title | Status | Notes |
| --- | --- | --- | --- |
| [FEP-67ff][fep-67ff] | FEDERATION.md | ✅ | This document. |
| [FEP-8b32][fep-8b32] | Object Integrity Proofs | ✅ | `eddsa-jcs-2022` Ed25519 proofs (`create_object_proof`, `verify_object_proof?`). |
| [FEP-521a][fep-521a] | Representing actor's public keys | ✅ | `Multikey` / `publicKeyMultibase` assertion methods (`Aptok.multikey`). |
| [FEP-8fcf][fep-8fcf] | Followers collection synchronization | ✅ | `Collection-Synchronization` header generation during delivery. |
| [FEP-ef61][fep-ef61] | Portable objects | ✅ | `ap://did...` helpers, compatible `/.well-known/apgateway/...` routing and lookup, actor `gateways`, and `did:key` proof keys. |
| [FEP-0837][fep-0837] | Federated Marketplace | ✅ | Proposal/Intent/Commitment/Agreement builders, ValueFlows mapping, and optional strict validators. |
| [FEP-044f][fep-044f] | Surface-level federation interop hints | 🟡 | `@context` term registered; no dedicated behavior yet. |
| LD Signatures (RsaSignature2017) | — | ❌ | Only the newer Data Integrity proofs are implemented. |

## ActivityPub implementation details

- **Inbox** — typed listeners with idempotency (`with_idempotency`), inbox
  forwarding that preserves the original signed body, and signed-request access
  control. Inbox delivery can be backed by the in-process queue, Redis, or a SQL
  store (see below).
- **Outbox & delivery** — `Context#send_activity` with followers-recipient
  expansion, shared-inbox fan-out, retry with exponential backoff, and a
  `QueueWorker` for background delivery.
- **Collections** — cursor-based and paginated collections for outbox,
  followers, following, and custom collections.
- **Discovery** — WebFinger and NodeInfo as above; remote document/object
  loading with an authenticated document loader and collection traversal.
- **Portable objects** — FEP-ef61 `ap://did...` canonical IDs, compatible HTTP
  gateway routes, gateway-hinted lookup, and `did:key` object proof resolution.
- **Storage** — pluggable `KvStore` and `MessageQueue` interfaces with in-memory,
  Redis, and SQL (SQLite/Postgres) drivers.

## Additional documentation

- [README.md](README.md) — usage guide and API walkthrough.
- [docs/FEDIFY_PARITY.md](docs/FEDIFY_PARITY.md) — feature-by-feature parity
  matrix against Fedify, plus full ForgeFed and FEP-0837 marketplace coverage.

[fep-67ff]: https://codeberg.org/fediverse/fep/src/branch/main/fep/67ff/fep-67ff.md
[fep-8b32]: https://codeberg.org/fediverse/fep/src/branch/main/fep/8b32/fep-8b32.md
[fep-521a]: https://codeberg.org/fediverse/fep/src/branch/main/fep/521a/fep-521a.md
[fep-8fcf]: https://codeberg.org/fediverse/fep/src/branch/main/fep/8fcf/fep-8fcf.md
[fep-ef61]: https://codeberg.org/fediverse/fep/src/branch/main/fep/ef61/fep-ef61.md
[fep-0837]: https://codeberg.org/fediverse/fep/src/branch/main/fep/0837/fep-0837.md
[fep-044f]: https://codeberg.org/fediverse/fep/src/branch/main/fep/044f/fep-044f.md
[fedify]: https://github.com/fedify-dev/fedify
[forgefed]: https://forgefed.org/spec/
[activitypub]: https://www.w3.org/TR/activitypub/
[as2]: https://www.w3.org/TR/activitystreams-core/
[webfinger]: https://datatracker.ietf.org/doc/html/rfc7033
[cavage]: https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures-12
[rfc9421]: https://datatracker.ietf.org/doc/html/rfc9421
[nodeinfo]: https://nodeinfo.diaspora.software/
