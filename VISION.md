# Vision & contributor map

This is the document for the person who reads the other five, runs the tests, and
thinks *"I could build on this."* You can. gene is a working **zero-knowledge
delivery primitive** with a reference app on top; the interesting part isn't the
video demo, it's that the operator-blind floor underneath it is **general**, and a
whole spectrum of apps can stand on it.

The other docs state what gene *is* ([PRIMITIVE.md](PRIMITIVE.md)), what it
*protects* ([SECURITY.md](SECURITY.md)), and what it *defers* (SECURITY.md "honest
edges", [relay/README.md](relay/README.md) "Not yet"). This one turns those
deferrals into a **prioritized, code-pointered backlog** — so picking something up
is a matter of choosing a row, not reverse-engineering the repo.

## The north star

Two complementary moves, plus the one that unlocks an ecosystem:

1. **Raise the ceiling** — harden the *primitive*. gene sits at the privacy ceiling
   of this architecture; every improvement to the floor (forward secrecy, metadata
   resistance, at-rest encryption) lifts the maximum privacy of **every** app above
   it, all at once. This is the highest-leverage work in the repo.
2. **Populate beneath it** — build *apps* at different points on the
   privacy/convenience spectrum ([PRIMITIVE.md](PRIMITIVE.md) "privacy ceiling").
   Each app trades some privacy for reach, but inherits an operator-blind relay it
   can't betray — *as long as it keeps the vault E2E.*
3. **Make it drop-in** — extract the core as a package + write the wire spec, so the
   builders in moves 1 and 2 aren't all writing Dart against an un-versioned API.

> The hope isn't only that people build apps beneath this ceiling — it's that
> someone pushes the ceiling **higher** than gene has, and the whole spectrum rises
> with it.

## Three tracks

### Track A — Harden the primitive *(raises the ceiling for everyone)*

| Item | What & why | Where it hooks | Difficulty |
|---|---|---|---|
| **~~Forward secrecy~~ → Post-compromise security** | ✅ Forward secrecy is **done**: a per-feed one-way hash ratchet (`message_crypto.dart` `chainRoot`/`nextChainKey`/`messageKey`), `K` discarded at pairing, chain state advanced-and-deleted with each entry, gaps fast-forwarded. What remains is **PCS** — the ratchet is symmetric, so a compromise exposes all *future* keys until re-pair. Mix fresh DH into the chain (Double Ratchet): attach an ephemeral X25519 pubkey to entries and fold a new ECDH into `nextChainKey`. | `lib/src/messaging/message_crypto.dart`, `Contact` chain state in `models.dart`, `messaging_service.dart` | **High** — needs a DH-key-carrying entry format and skipped-key handling across the relay's TTL gaps. Now the headline open problem. |
| **At-rest library encryption** | The received-missive index and the decrypted `.mp4`s sit in the clear on disk (`MessageStore`). Wrap them under a key held in the Keystore. | `lib/src/messaging/message_store.dart` (the atomic-write/disk-rebuild path is already there to build on), `lib/src/storage/secure_storage.dart` | **Medium** — tension: `video_player` wants a real file, so decrypt-on-demand to a temp file (and shred it) or feed a decrypting data source. |
| **Abuse / rate-limiting** | Relay ids are client-chosen and creation is unauthenticated. The feed-entry body cap exists; **creation** is the open door. | `relay/src/index.ts` (the `create` paths), a new gate before `InviteSlot.create` / `FeedSlot.create` | **Medium** — options: a Turnstile / Privacy Pass token at create-time, a per-DO token bucket, or hashcash proof-of-work. Keep it stateless and zero-knowledge. |
| **Metadata resistance** | The relay sees sizes, cadence, IP, and the pairwise graph. **Entry** sizes are now padded (`padEntryPayload`); **media** size, cadence, and IP/timing remain. | fixed-cadence polling in the loops (`connect_screen` `_poll`, `Conversation.sync`); pad media to buckets | **Medium** for cadence/media padding; **Hard** for IP/timing (needs a mixnet — out of scope for a free relay, but a fascinating fork). |
| **Safety-number verification** | ✅ `Contact.verified` + a "They match" action now record the TOFU→verified upgrade, shown as a filled shield (`conversation_screen.dart`). What's left is *enforcement*: a pre-first-send nudge and a QR path so users don't have to read digits aloud. | `conversation_screen.dart`, `connect_screen.dart` | **Low** — the state exists; this is UX. A good first issue. |
| **Streaming AEAD for large media** | Media is sealed *in memory* (`Crypto.seal(mediaKey, clear)`), fine for short missives, not for long video. | chunked/streaming encrypt + upload in `messaging_service.dart` (`send`/`fetchNew`); the relay already streams media | **Medium** — pick a framed AEAD (e.g. per-chunk nonces with a chain) and keep the relay byte-blind. |

### Track B — Make it drop-in *(the SDK + spec)*

PRIMITIVE.md "What it would take to make it drop-in" is the full version; the
sequencing that matters:

1. **Extract `gene_core`** — `crypto`, `identity`, `pairing` (incl. the relay
   transport), and `messaging/message_crypto` into `packages/gene_core` as a reusable
   Dart package. Mechanical, but it's the move that makes everything else a *dependency*
   rather than a *fork*. **Medium.**
2. **Generalize the payload** — `Missive`/`ReceivedMissive` (`messaging/models.dart`)
   → an opaque, app-defined payload + an optional encrypted-blob handle, and
   `MessagingService`'s `videoPath`/`.mp4` file I/O → byte streams. The feed/seal/sign
   machinery beneath is *already* content-agnostic. **Medium.**
3. **Write the wire-protocol spec** — the handshake transcript + `K` derivation, the
   sealing formats + signed-entry bytes, and the feed contract, so clients in **any**
   language interoperate. [BACKEND.md](BACKEND.md) + [relay/README.md](relay/README.md)
   are ~80% of it. The acid test: **a non-Dart reference client** (see Good first
   contributions). **Medium.**
4. **Relay-as-template** — "fork, set your bucket (+ optional domain), deploy" is
   mostly written; polish it into a one-command template. **Low.**

None of this is new cryptography — it's repackaging and a spec.

### Track C — Build apps on it *(populate the spectrum)*

The "API" is always the same: *content, plus a capability-gated, operator-blind, E2E
channel to specific people.* Worked examples live in
[PRIMITIVE.md](PRIMITIVE.md) — here's the shape, with what each app *adds*:

- **Accounts + E2E vault** (a Marco-Polo tier) — email login over an *encrypted* vault
  (keys + contacts) for multi-device, sync, and recovery, **while the operator stays
  blind to content.** Adds: an account layer and the vault; sits one notch below the
  ceiling.
- **"DM for address"** (private events) — `request → grant → sealed delivery`. Adds:
  an *asymmetric* handshake (gene pairs symmetrically) and a trust-graph / introduction
  layer. Ephemeral events sidestep the revocation problem — grant per-event, don't
  re-grant.
- **Broadcast feed** — a publicly-shared-capability feed for low-secrecy discovery
  ("there's a show Friday"). The feed model already allows it; the reference app just
  doesn't expose it. Adds: a broadcast feed type + a screen.
- **Same family, different skin** — location sharing with chosen people, private
  classifieds, close-friends posting, mutual-aid / whisper networks. All the same move.

## Good first contributions

Genuinely small, genuinely useful, with a pointer to start:

- **Clean up the pre-edit raw take.** A sent missive's plaintext is now deleted, but
  the *raw* camera take that an edit superseded still lingers in cache. Delete it after
  a successful send (safe once we `popUntil` the conversation). → `recorder_screen.dart`
  (`_sendMissive`), `recorder_controller.dart`. **Low.**
- **Safety-number QR + "verify now" prompt.** Make the MITM check a tap, not a chore.
  → `conversation_screen.dart`, `models.dart`. **Low–Medium.**
- **Encrypt just the index.** A smaller slice of at-rest encryption — wrap
  `gene_missives.json` (not yet the media) under a Keystore key. → `message_store.dart`.
  **Medium.**
- **A non-Dart relay client.** A ~200-line TypeScript or Python client that pairs and
  exchanges one message against the documented HTTP contract — it *validates the spec*
  and proves interop, which is worth more than its size. → [relay/README.md](relay/README.md).
  **Medium, high-signal.**

## The hard, interesting problems

For the research-minded — these are real, not settled:

- **Forward secrecy over a gapping transport.** A ratchet assumes you see every
  message; gene's relay can TTL-sweep an undelivered one. Double-Ratchet-with-skipped-keys,
  or a periodic rekey that tolerates loss — what's the right point on the
  security/complexity curve for *asynchronous, low-cadence* missives?
- **Durable groups & revocation.** Capability-by-possession can't be un-given, so gene
  favors 1:1 + ephemeral. Real managed groups want MLS-class group-key machinery. Does it
  belong *in* the primitive, or as a layer above the authenticated 1:1 edges it already
  provides?
- **Metadata on near-free infra.** Padding and fixed-cadence polling are designed;
  IP/timing unlinkability wants a mixnet. Is there a cover-traffic design that fits a
  `*.workers.dev` budget?

## Ground rules — don't break the floor

Every contribution inherits — and must preserve — the security invariants (the same
ones in [CLAUDE.md](CLAUDE.md) and enforced by [SECURITY.md](SECURITY.md)):

1. **The relay only ever sees ciphertext.** Never add a server path that decrypts, logs
   plaintext, or transmits a key.
2. **`K` and identity private keys never leave the device.**
3. **Per-feed keys — never the identity key — sign feed writes** (un-linkability).
4. **The link secret `S` lives only in the URL `#fragment`.**
5. **Crypto goes through `Crypto` + `message_crypto`**, byte-compatible with
   `relay/src/codec.ts`/`crypto.ts`.

And the working discipline that keeps this repo trustworthy: **decision logic is pure
and unit-tested; the relay is tested in real `workerd`; the full send→relay→receive loop
is exercised, not mocked.** If you change behavior, a test should prove it — ideally one
that fails before your change and passes after.

## How to start

1. **Read** in order: [README](README.md) → [ARCHITECTURE.md](ARCHITECTURE.md) →
   [SECURITY.md](SECURITY.md) → [BACKEND.md](BACKEND.md) → [PRIMITIVE.md](PRIMITIVE.md) →
   [relay/README.md](relay/README.md).
2. **Run the three suites** (`flutter test`, `cd relay && npm test`,
   `cd android && ./gradlew :app:testDebugUnitTest`) so green is your baseline.
3. **Pick a row** from a track above, respect the seam (core vs. app —
   [ARCHITECTURE.md](ARCHITECTURE.md)) and the ground rules, and bring a test.

The primitive is small on purpose. That's not a limitation to apologize for — it's the
surface you build on.
