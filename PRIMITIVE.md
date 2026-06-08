# gene as a primitive

gene is a video-missive app, but only the top of it is about video. Underneath
is a small, general capability that other apps can build on. This document names
that primitive, draws the line between it and the application, and works through
what you'd build on top — including a worked example in a completely different
domain.

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
| **Primitive** | `lib/src/crypto`, `lib/src/identity`, `lib/src/pairing`, `lib/src/messaging` (transport), `relay/` | identity, pairing, sealed feeds, media, the zero-knowledge relay |
| **Application** | `lib/src/recorder`, `lib/src/editor`, `lib/src/playback`, the video-shaped `Missive` | capture, on-device auto-edit, playback — the gene experience |

The **only** thing video-specific in the transport is one record —
`Missive { kind, mediaId, mediaKey, durationMs }` (`lib/src/messaging/models.dart`).
Generalize that to "opaque app payload + optional encrypted blob" and the floor
carries anything.

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

1. Fork the relay, set their own R2 bucket + domain, deploy.
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

Two tiers, both already supported:

- **Teaser** — "there's a show Friday, this vibe." Broadcast-ish, low/no secrecy.
  Discovery.
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

Honest current state: **the relay is already general** (content-agnostic). **The
client core is general but bundled** inside the gene app, and the payload is
video-shaped. To make it a primitive others literally build on:

1. **Extract `gene_core`** — `crypto` + `pairing` + `messaging` (transport) as a
   reusable Dart package with a clean public API.
2. **Generalize the payload** — `Missive` → an opaque, app-defined payload +
   optional encrypted blob. The transport already seals arbitrary bytes; only the
   model is video-shaped.
3. **Write the wire-protocol spec** — handshake transcript, sealing formats, the
   signed-entry bytes, the feed contract — so clients in any language interoperate.
   [relay/README.md](relay/README.md) (HTTP), [BACKEND.md](BACKEND.md) (crypto),
   and `lib/src/messaging/message_crypto.dart` (formats) are ~80% of it.
4. **Relay-as-template** — "fork, set your bucket + domain, deploy" docs (mostly
   present in relay/README.md).

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
