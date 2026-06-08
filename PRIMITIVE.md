# gene as a primitive

gene **is** a primitive: a zero-knowledge, capability-secured, end-to-end-encrypted
delivery system — a near-free Cloudflare relay plus a client crypto/pairing/messaging
core — for selectively disclosing content to chosen people without the operator ever
learning what moved. The slow, high-fidelity **video-missive app is its reference
demonstration**: a complete, working proof that the primitive carries a real,
high-standards product end to end. This document names the primitive, draws the line
between it and the demo built on it, sets the privacy ceiling it establishes for
everything downstream, and works through other apps you'd build on it — including one
in a completely different domain.

## The primitive, in one line

> A **zero-knowledge, capability-secured, end-to-end-encrypted publish/subscribe
> channel** between parties who pair over an untrusted link — on near-free
> commodity infrastructure.

The relay has no idea it's moving video. It moves sealed bytes and sealed blobs,
verifies signatures it cannot read, and destroys what it routes after delivery.
That content-agnostic floor is the primitive. (Why it's genuinely zero-knowledge:
[SECURITY.md](SECURITY.md). Full design: [BACKEND.md](BACKEND.md).)

What the floor gives a developer:

- **Identity without accounts** — a keypair; the public key is the "who."
- **Pairing** — a single-use sealed rendezvous that turns two strangers-with-keys
  into a mutually-authorized, E2E-keyed relationship over one untrusted link.
- **Feeds** — append-only, **read-by-capability** (holding the unguessable id),
  **write-by-signature** (a per-feed key), content sealed end-to-end, destroyed
  after delivery. "Encrypted RSS," essentially.
- **Media** — arbitrary blobs, encrypted client-side, referenced by a sealed feed
  entry that carries the blob's own key. Operator-blind, egress-free.
- **A relay** — a stateless-ish Cloudflare Worker + Durable Objects + R2 that any
  developer can fork and deploy for ~free.

## The seam: primitive vs. application

The line already exists in the codebase:

| Layer | Code | Role |
|---|---|---|
| **Primitive** | `lib/src/crypto`, `lib/src/identity`, `lib/src/pairing` (incl. the relay transport), `lib/src/messaging/message_crypto`, `relay/` | identity, pairing, sealed feeds, media, the zero-knowledge relay |
| **Application** | `lib/src/recorder`, `lib/src/editor`, `lib/src/playback`, the video-shaped `Missive`/`ReceivedMissive` + the file-coupled `MessagingService` | capture, on-device auto-edit, playback — the reference demo built on the primitive |

The video-specific surface is small, but it's more than one record: the
`Missive`/`ReceivedMissive` models (`lib/src/messaging/models.dart`) and the
file-shaped I/O in `MessagingService` (`send(videoPath: …)`, the `.mp4` write in
`fetchNew`). Generalize those to "opaque app payload + optional encrypted blob handle"
and the floor carries anything — the feed/seal/sign machinery beneath them
(`message_crypto.dart`, the relay transport) is already content-agnostic.

## The privacy ceiling

gene is deliberately pinned to one end of a hard tradeoff: it is the **most
private, least convenient** configuration this architecture allows. Accountless,
no server-side recovery, no cloud, re-pair on device loss, no contact sync — each
of those "inconveniences" is privacy bought at the price of comfort. That's not a
limitation to apologize for; it's the **reference point.** gene sets the *ceiling*
— the highest privacy you can offer on a zero-knowledge relay — and it sets it
about as high as the design space goes.

Everything built on the primitive sits **at or below that ceiling.** An app buys
convenience by trading privacy back, picking a point on the way down:

| Where it sits | The app holds | Gains | Costs |
|---|---|---|---|
| **At the ceiling** — raw gene | nothing | maximum privacy; nothing to breach | recovery (re-pair), easy multi-device |
| **Just below** — accounts + an E2E vault | an *encrypted* vault (keys + contacts), unlockable only by the user | email sign-in, multi-device, sync, recovery — **the operator still can't read content** | a passphrase to remember; trust the app keeps the vault sealed |
| **Lower still** — convenience-first | keys/contacts in the clear | the smoothest, most familiar UX | E2E against the operator |

A Marco-Polo clone with logins, cloud backup, and long-term storage is a
perfectly legitimate thing to build here — it just sits lower on the wall, having
spent some privacy for reach and ease (cf. Signal's PIN, WhatsApp's encrypted
backup — the [device-migration tension in BACKEND.md §9](BACKEND.md) made a
product decision). The primitive doesn't forbid that; it **bounds** it: the
operator-blind transport is the floor under every tier, so even a
convenience-heavy app inherits a relay that can't read content — *as long as it
keeps the vault E2E.* The genuinely low-privacy choice is the one that breaks
that floor by holding keys in the clear.

And the ceiling can be **raised.** Forward secrecy, metadata resistance (padding,
fixed-cadence polling, a mixnet), at-rest encryption of the local library — each
improvement to the *primitive* lifts the maximum for everything above it. The
hope isn't only that people build apps beneath this ceiling; it's that someone
pushes the ceiling higher than gene has, and the whole spectrum rises with it.

## Worked example 1 — Marco Polo, with accounts

A developer wants the familiar thing: download the app, sign in, your people are
there. They:

1. Fork the relay, set their own R2 bucket (domain optional), deploy.
2. Build a polished app on the primitive: capture/playback UX, push, discovery.
3. Add an **account layer** — email login backed by an E2E-encrypted vault, so the
   user's identity keys + contacts sync across devices and survive a reinstall.

The user trusts *that app* the way they'd trust any app. But because the vault is
E2E and the relay is zero-knowledge, **a breach of the operator still yields no
message content.** gene's accountless purity becomes one option; this is another,
on the same floor.

## Worked example 2 — "DM for address" (house shows)

A different domain entirely: private events distributed through a trust network.
Alice has a house show; she wants friends-and-friends-of-friends, not the world,
and the address stays private until she lets someone in. This maps onto the
primitive almost unchanged — which is the real validation.

Two tiers — one the primitive supports today, one a thin addition:

- **Teaser** — "there's a show Friday, this vibe." Broadcast-ish, low/no secrecy.
  Discovery. (The feed model allows a publicly-shared-capability feed for this; the
  reference app just doesn't expose broadcast yet.)
- **Address** — *not* in the public feed. When Bob asks and Alice grants, the app
  delivers the address as a **sealed entry on their pair channel**. That is
  gene's existing pair-and-seal, re-skinned — **no new crypto.** Intercept-proof,
  and it only ever reaches who Alice grants.

So "DM for address" = `request → grant → sealed delivery`. What this domain adds
on top of the primitive:

- **Asymmetric handshake.** gene pairs symmetrically (mutual invite); this is
  request→grant. A small variant: Bob's "can I come?" is a pairing request to a
  feed Alice reads; she grants by completing the pair.
- **Revocation is the catch.** Capability-by-possession can't be un-given — once
  Bob holds a key, he holds it. A single shared feed with managed membership would
  need group rekey (the hard MLS problem). **Ephemeral events sidestep it:** short
  TTL + destroy-after-delivery makes access naturally time-bounded; grant
  per-event, and simply don't re-grant. Per-recipient sealing beats a managed
  group here.
- **Trust graph / introductions.** "Friends of friends" is a web-of-trust layer:
  someone Alice already trusts signs an attestation vouching for a newcomer's key.
  Classic and well-trodden; the primitive supplies the authenticated 1:1 edges to
  build the graph from.

## The general shape

Across all of these the pattern is one thing:

> **Selectively disclose content to a chosen subset of a trust graph,
> end-to-end, where the operator learns nothing — on cheap infra.**

That family is large: private missives, accounts-Marco-Polo, "DM for address"
events, location sharing with chosen people, private classifieds, close-friends
posting, mutual-aid and whisper networks. The "API" is always the same — content,
plus a capability-gated, operator-blind, E2E channel to specific people.

## What it would take to make it drop-in

Honest current state: **the relay is already general** (content-agnostic), and **the
client core is already general** — it's simply **not yet split out into its own
package**, and the reference demo's payload is video-shaped. To make it a primitive
others literally build on:

1. **Extract `gene_core`** — `crypto`, `pairing` (including the relay transport), and
   the generic half of `messaging` (`message_crypto`) as a reusable Dart package; the
   file-coupled `MessagingService`/`MessageStore` get generalized per step 2, not
   lifted as-is.
2. **Generalize the payload** — `Missive`/`ReceivedMissive` → an opaque, app-defined
   payload + an optional encrypted-blob handle, and `MessagingService`'s file I/O →
   byte streams. The feed/seal/sign machinery beneath is already content-agnostic.
3. **Write the wire-protocol spec** — the handshake transcript + `K` derivation
   (`pairing_service.dart`), the sealing formats + signed-entry bytes
   (`message_crypto.dart`), and the feed contract — so clients in any language
   interoperate. [relay/README.md](relay/README.md) (HTTP) and [BACKEND.md](BACKEND.md)
   (crypto) are ~80% of it.
4. **Relay-as-template** — "fork, set your bucket (+ optional domain), deploy" docs
   (mostly present in relay/README.md; no domain required — it rides on `*.workers.dev`).

None of that is new cryptography — it's repackaging and a spec. Call it ~80% of
the way to a clean SDK.

## Limits that carry over

Anything built on this inherits the primitive's honest edges (full detail in
[SECURITY.md](SECURITY.md)):

- **Metadata** — the operator still sees IP/timing and the pairwise graph; content
  is opaque, but who-talks-to-whom and when is only partially mitigable.
- **Revocation / groups** — capability-by-possession favors 1:1 + ephemeral;
  durable managed groups need group-key machinery the primitive doesn't include.
- **TOFU** — first contact trusts the channel that carried the link, verifiable
  after the fact via the safety number.
- **Not audited** — standard primitives composed in a documented, tested way, not
  a formally-verified protocol.

These aren't reasons not to build on it — they're the contract you're building
against, stated plainly so the choice is informed.
