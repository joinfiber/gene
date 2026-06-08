# gene

**A zero-knowledge, end-to-end-encrypted delivery primitive — and a reference app built on it.**

gene is two things in one repo:

1. **The relay** (`relay/`) — a small, near-free Cloudflare service that moves end-to-end-encrypted content between people who pair over a single-use link, and learns *nothing* but ciphertext. This is the primitive: the part you'd build on.
2. **The client** (`lib/`) — a Flutter reference app (slow, high-fidelity video missives, auto-edited on-device) that demonstrates the primitive working end to end. This is not a product you download; it's proof the system works, and a worked example of how to build on it.

There is no app store listing and no hosted service to sign up for. **The repo is the system.** You run the relay; the client is a thin thing you point at it.

## The idea

A handful of principles, taken seriously, produce the whole design:

- **Operator-blind.** The relay only ever sees ciphertext. Conversation keys and identity keys never leave the devices. Compromising the relay yields opaque bytes and coarse metadata — not content. (See [SECURITY.md](SECURITY.md).)
- **Accountless.** Identity is a keypair, not a login — the public key *is* the "who." Two strangers become a mutually-authorized, end-to-end-keyed pair by exchanging one single-use link over any channel.
- **Capability-secured.** Reading is holding an unguessable feed id; writing is a per-feed signature. No central authorization, no user table.
- **Ephemeral.** Delivered content is destroyed server-side after the recipient acks. The relay keeps nothing at rest it doesn't need in flight.
- **Cheap by construction.** The whole thing fits a near-free Cloudflare tier (Workers + SQLite Durable Objects + R2's free egress). That constraint *shaped* the design rather than limiting it.

The reference app adds one more idea on top: **latency is the budget.** Because missives are asynchronous, the effort a live app spends racing a round-trip is spent here on _fidelity_ (ship the camera's real capture) and _composure_ (trim the dead air out on-device, before sending).

## How it works (the 60-second version)

- **Pair.** A single-use invite link carries a secret in its URL `#fragment` (never sent to a server). Both sides run an authenticated X25519 handshake — each signs the transcript with its identity key — and derive a shared conversation key `K`. (Trust is TOFU, verifiable after the fact via a two-sided **safety number**.)
- **Talk.** A conversation is two append-only **feeds**, one per direction. Each entry is sealed under a per-message subkey of `K` and signed by a **per-feed** key (never the identity key, so the relay can't link your relationships). Media rides as an encrypted R2 blob whose key lives *inside* the sealed entry.
- **Deliver, then forget.** The recipient pulls, decrypts, acks; the relay destroys the entry and the blob.

Full design and rationale: **[BACKEND.md](BACKEND.md)** · threat model (code-pointered): **[SECURITY.md](SECURITY.md)** · architecture: **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Getting started

The relay is the only infrastructure, and it's the one piece you stand up yourself.

### 1 · Deploy a relay

```sh
cd relay
npm install
npx wrangler login                          # a free Cloudflare account is enough
npx wrangler r2 bucket create gene-media    # for video; R2 needs a card on file,
                                            # but the free tier covers a demo
npm run deploy                              # → https://<your-worker>.workers.dev
```

Workers + SQLite Durable Objects are free with no card. R2 (media) needs a payment method on the account, though the free allowance is far more than a demo uses. Want text/no media? Skip the bucket — media routes return `503` until R2 is wired. Exact HTTP contract: **[relay/README.md](relay/README.md)**.

### 2 · Run the client, pointed at your relay

```sh
flutter pub get
flutter run -d <device> --dart-define=GENE_RELAY_URL=https://<your-worker>.workers.dev
```

**Two people who want to exchange missives must point at the same relay** — it's the shared rendezvous. For local development, run `npm run dev` in `relay/`, `adb reverse tcp:8787 tcp:8787`, and the default (`http://localhost:8787`) just works.

### 3 · Pair and send

On device A: **Connect → Create an invite link**, share it. On device B: **Connect → I have a link**, paste. Then tap the contact → **Record** → the take auto-edits → **Send**; pull down to receive. Tap the shield to compare **safety numbers** and confirm no one's in the middle.

## The on-device edit (what the demo shows off)

The client records at full resolution, decodes the audio natively, finds the speech/silence split with a parameter-free **Otsu threshold**, trims dead air and collapses long pauses, and splices with Media3 — all on the phone, before anything is encrypted or sent. (Why energy + Otsu rather than speech-to-text: [ARCHITECTURE.md](ARCHITECTURE.md).)

## Build on it

Strip the camera and the auto-edit away and what's left is general: *selectively disclose content to a chosen subset of a trust graph, end-to-end, where the operator learns nothing, on cheap infra.* The only video-specific thing in the transport is one record. Other apps on the same floor — accounts-based messengers, private-event "DM for address" tools, location sharing with chosen people — are sketched in **[PRIMITIVE.md](PRIMITIVE.md)**, including the trust spectrum (accountless → accounts) and a worked non-messaging example.

## Tests

```sh
flutter analyze && flutter test                 # Dart: pairing, the messaging loop, the editor
cd android && ./gradlew :app:testDebugUnitTest  # Kotlin: Otsu + keep-range math
cd relay && npm test                            # TypeScript: the relay in the real workerd runtime
```

## Docs

[README](README.md) (here) → [ARCHITECTURE.md](ARCHITECTURE.md) (how it's built) → [SECURITY.md](SECURITY.md) (is it safe — verifiably) → [BACKEND.md](BACKEND.md) (the full design) → [PRIMITIVE.md](PRIMITIVE.md) (building on it) → [relay/README.md](relay/README.md) (the wire contract). [CLAUDE.md](CLAUDE.md) orients an AI assistant exploring the repo.

## Status

Reference + demonstration, not a shipped product. The capture, pairing, and delivery paths are implemented and tested end to end; the client is Android-only for now. Deliberate, documented deferrals: forward secrecy, relay rate-limiting/abuse controls, and streaming AEAD for very large media (see SECURITY.md and relay/README.md — it doesn't claim what it doesn't do).

## License

[MIT](LICENSE).
