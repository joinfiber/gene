# gene relay

The zero-knowledge delivery layer: it learns as little as possible and still routes bytes — no accounts, no plaintext, no durable content. Full design in **[../BACKEND.md](../BACKEND.md)**.

Cloudflare Workers + Durable Objects + R2.

## Pairing — the sealed single-use invite ([BACKEND.md §2](../BACKEND.md))

Each invite is a Durable Object slot holding two opaque blobs: the inviter's sealed payload and the redeemer's sealed response. The DO's single thread makes single-use redemption an atomic compare-and-set, so a second (attacker's) redemption **fails visibly** instead of silently pairing. The slot self-destructs after a TTL.

| Route | Method | Purpose |
|---|---|---|
| `/invite/:id` | `PUT` | inviter creates the slot (opaque payload body) |
| `/invite/:id` | `GET` | redeemer fetches the sealed payload |
| `/invite/:id/redeem` | `POST` | redeemer claims the slot — succeeds at most once |
| `/invite/:id/redeem` | `GET` | inviter polls for the sealed response |

The relay never sees the link secret `S` — it lives in the URL `#fragment`.

The exact wire contract for these routes is in **[HTTP contract](#http-contract)** below.

**The shareable link** is `…/i/<id>#<S>` — the relay's own origin, so `GET /i/:id` returns a small landing page guiding the recipient to paste the link into the app. The `#S` fragment is never sent to the server, so the page stays zero-knowledge; it's simply a friendlier destination than a dead link for anyone who taps instead of pasting. (No domain required — it rides on the `*.workers.dev` origin.) The page is fully static, so it ships `Cache-Control: public, max-age=86400, immutable` + an `ETag`, plus a strict `Content-Security-Policy` and `Referrer-Policy: no-referrer`.

## Feeds — append-only, signed, capability-read ([BACKEND.md §3](../BACKEND.md))

A conversation is two unidirectional feeds, one per direction, each a Durable Object.

- **Read** is a capability: holding the unguessable feed id authorizes reading.
- **Write** is a signature: the author's **per-feed Ed25519 key** (never the identity key) is pinned at creation; every entry is signed over `seq‖ciphertext` and verified with WebCrypto, so a leaked feed id still cannot forge entries.
- Entry ciphertext is sealed end-to-end; the relay stores only opaque bytes. Delivered entries are destroyed on **ack**, and undelivered ones expire via an in-object **TTL sweep**.

| Route | Method | Purpose |
|---|---|---|
| `/feed/:id` | `PUT` | author pins their per-feed public key (raw body) |
| `/feed/:id` | `GET` | reader pulls entries (`?since=<seq>`) |
| `/feed/:id/entry` | `POST` | author appends a signed entry `{ seq, sig, ct }` (base64) |
| `/feed/:id/ack` | `POST` | reader destroys delivered entries `{ upTo: <seq> }` |

## Media — opaque blobs in R2 ([BACKEND.md §3](../BACKEND.md))

Audio/video are encrypted client-side, stored as R2 objects, and referenced by an (encrypted) feed entry carrying the object id and media key — so the media key never reaches the relay. The relay streams opaque ciphertext in and out; **R2 egress is free**, which is the whole reason media is affordable.

| Route | Method | Purpose |
|---|---|---|
| `/media/:id` | `PUT` | author uploads an encrypted blob (streamed to R2) |
| `/media/:id` | `GET` | reader streams it back |
| `/media/:id` | `DELETE` | reader destroys it after delivery |

## HTTP contract

The exact contract a client builds against. Stable across versions; treat it as the source of truth.

**Conventions**

- **Status codes** follow one convention across all resources: a create returns **201** with `{ "ok": true }`; a successful poll with nothing to return yet is **204** (empty body); any other success is **200**; every error is a JSON body `{ "error": "<code>" }` with the status below.
- **Content types.** Opaque blobs (invite payload/response, media) are `application/octet-stream` raw bytes in **and** out. Structured bodies are `application/json`. Feed `sig` and `ct` are **base64** strings inside JSON.
- **Caching.** Every dynamic API response carries `Cache-Control: no-store` — they are per-request and ephemeral. (Only the `/i/:id` landing page is cacheable; see below.)
- **Body caps.** The sealed handshake blobs are tiny: `PUT /invite/:id` and `POST /invite/:id/redeem` reject a body over **8 KB** with **413** `{ "error": "too_large" }`. `PUT /feed/:id` (a 32-byte key) rejects an oversized body with **400** `bad_key`. `POST /feed/:id/entry` and `POST /feed/:id/ack` reject a JSON body over **64 KB** with **413** `{ "error": "too_large" }` (real entries are a few hundred bytes; the cap keeps an entry well under the Durable Object's 128 KB per-value limit, so an oversized append is a clean 413, not a 500). Media streams and is uncapped here (an R2 lifecycle/quota backstop is the operational control — see *Not yet*).
- **`:id`** is a client-chosen, high-entropy string addressing one Durable Object (invite slot or feed) or one R2 object (media).
- An unknown top-level resource, or a known resource with no `:id`, returns **404** `{ "error": "not_found" }`. A recognized route reached with an unsupported method returns **405** `{ "error": "method_not_allowed" }`.

### Invite (pairing rendezvous)

| Method & path | Request body | Success | Errors |
|---|---|---|---|
| `PUT /invite/:id` | raw bytes — inviter's sealed payload | `201` `{ "ok": true }` | `409` `{ "error": "already_exists" }` (slot id taken); `413` `{ "error": "too_large" }` (body over 8 KB) |
| `GET /invite/:id` | — | `200` raw bytes — the sealed payload | `404` `{ "error": "not_found" }` (no such slot) |
| `POST /invite/:id/redeem` | raw bytes — redeemer's sealed response | `200` `{ "ok": true }` | `404` `{ "error": "not_found" }` (no slot); `409` `{ "error": "already_redeemed" }` (claimed already — single-use); `413` `{ "error": "too_large" }` (body over 8 KB) |
| `GET /invite/:id/redeem` | — | `200` raw bytes — the sealed response, **or** `204` (empty) if not redeemed yet | — |

### Feed (one direction of a conversation)

| Method & path | Request body | Success | Errors |
|---|---|---|---|
| `PUT /feed/:id` | raw bytes — the author's Ed25519 public key, **exactly 32 bytes** | `201` `{ "ok": true }` | `400` `{ "error": "bad_key" }` (not 32 bytes); `409` `{ "error": "already_exists" }` (feed id taken — author key is pinned once) |
| `GET /feed/:id?since=<seq>` | — | `200` `{ "entries": [ { "seq": <int>, "sig": "<base64>", "ct": "<base64>" } ] }` — entries with `seq > since`, ascending; empty array when none | `400` `{ "error": "bad_since" }` (`since` present but not a number) |
| `POST /feed/:id/entry` | `{ "seq": <int>, "sig": "<base64>", "ct": "<base64>" }` | `201` `{ "ok": true }` | `400` `{ "error": "bad_request" }` (malformed JSON, missing/wrong-typed field, `seq` not an integer in `0 … 2^53−1`, or `sig`/`ct` not valid base64); `401` `{ "error": "bad_signature" }` (sig fails against pinned key, incl. a malformed key/sig); `404` `{ "error": "not_found" }` (feed never created); `409` `{ "error": "stale_seq" }` (`seq` ≤ the acked watermark — replay/regression); `409` `{ "error": "duplicate_seq" }` (`seq` already pending) |
| `POST /feed/:id/ack` | `{ "upTo": <int> }` | `200` `{ "deleted": <int> }` — count of entries destroyed (`seq ≤ upTo`) | `400` `{ "error": "bad_request" }` (`upTo` missing or not an integer in `0 … 2^53−1`); `404` `{ "error": "not_found" }` (feed never created) |

Notes for the client:

- `seq` and `upTo` must be integers in `0 … Number.MAX_SAFE_INTEGER` (2^53−1). `since` is lenient: omitted ⇒ `0`, negative ⇒ clamped to `0`, non-numeric ⇒ `400`.
- **Monotonicity / replay.** The feed records the highest acked `seq` (the watermark). An append at or below it is rejected `stale_seq`, so a captured signed entry can't be re-delivered and acked seqs can't reappear. Send strictly increasing `seq`s.
- `bad_signature` is **fail-closed**: a malformed pinned key or signature yields `401`, never a `500` — one bad append can't brick a feed.
- Reads and acks page through the whole feed; there is no hidden 1000-entry ceiling.

### Media (opaque blob in R2)

| Method & path | Request body | Success | Errors |
|---|---|---|---|
| `PUT /media/:id` | raw bytes — encrypted blob (streamed) | `201` `{ "ok": true }` | `400` `{ "error": "empty_body" }` (no body); `409` `{ "error": "already_exists" }` (id already holds a blob — **write-once**); `503` `{ "error": "media_unconfigured" }` (no R2 binding on this deploy) |
| `GET /media/:id` | — | `200` raw bytes (`application/octet-stream`, `content-length` set) | `404` `{ "error": "not_found" }`; `503` `{ "error": "media_unconfigured" }` |
| `DELETE /media/:id` | — | `204` (empty) — idempotent: `204` even if the blob was already gone | `503` `{ "error": "media_unconfigured" }` |

Media is live: the `MEDIA` binding points at the `gene-media` R2 bucket (see `wrangler.jsonc`). A deploy without an R2 binding instead returns `503 media_unconfigured` on these routes.

**Write-once.** A media id authorizes *reading* its blob, so an unconditional `PUT` would let anyone holding the id overwrite the author's ciphertext. The upload is conditional (`etagDoesNotMatch: "*"`): a `PUT` to an id that already holds an object is rejected `409 already_exists` and the original is left untouched. `GET`/`DELETE` are unchanged.

## Develop

```sh
npm install
npm test          # vitest, inside the real workerd runtime (DO, Ed25519, R2)
npm run typecheck
npm run dev       # local wrangler
npm run deploy    # publish to Cloudflare
```

## Not yet

- **R2 lifecycle backstop** — media is destroyed on `DELETE` (the prompt path); a bucket-level R2 lifecycle rule (auto-delete after N days, set on the bucket) is the operational catch for blobs a recipient never collected.
- **Abuse / quota** — invite, feed, and media ids are client-chosen and creation is unauthenticated. An accountless relay needs rate-limiting or proof-of-work before public exposure.
