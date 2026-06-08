# Backend — identity, pairing & delivery

> Design **and** implementation. This is the spec of the **delivery primitive** — the zero-knowledge relay plus the client pairing/messaging crypto — of which the video-missive app ([ARCHITECTURE.md](ARCHITECTURE.md)) is the reference consumer (see [PRIMITIVE.md](PRIMITIVE.md) for the primitive/app seam). It's built and tested in the real `workerd` runtime; the wire contract is in [relay/README.md](relay/README.md). This document is the _why_.

The whole backend follows from one constraint: **the relay must learn as little as possible and still route bytes** — and a second: **it must fit Cloudflare's free tier.** Those two pressures, taken seriously, produce the entire model below. There are no accounts. There is no plaintext on the server. The relay is interchangeable and zero-knowledge; identity and trust live on the two devices.

This is the "auth model" — but with no accounts, "auth" is not _authentication of persons_. It is **authorization of capabilities**, layered on **public-key identity**. Three primitives, and everything else is consequence:

| Primitive | What it is | Who holds it |
|---|---|---|
| **Device keys** | An Ed25519 identity key + X25519 keys, generated on first launch. The public key _is_ the identity. No phone, email, or username. | The device, forever. Never sent to the relay in the clear. |
| **Capability token** | An unguessable URL/secret. Holding it = authorization to read a feed. The "private-podcast" pattern. | Exchanged at pairing; held by the one peer. |
| **Single-use invite** | The bootstrap that turns _two strangers with keypairs_ into _a mutually-authorized pair_, exchanging capabilities + public keys over an untrusted channel. | Created by the inviter; consumed exactly once. |

---

## 1. Identity: keys, not accounts

On first launch the app generates and stores (in platform secure storage / Keystore):

- an **Ed25519 identity key** — the durable "who," used only to prove continuity to a peer and to render a verifiable safety number;
- **X25519 keys** for ECDH.

The relay never sees the identity key. It is proven _end-to-end_ to the peer during pairing — each side signs the key-exchange transcript with it (§2) — and never used as a server-visible credential, a deliberate choice that keeps the relay from linking a user's separate relationships (see §5).

## 2. Pairing: a single-use sealed rendezvous

The hard problem. Two people, each holding only keys, must end up (a) each knowing the other's feed capability, (b) each knowing the other's public key, and (c) sharing a secret for E2E — having communicated **only over an untrusted, asynchronous, possibly-observed channel** (an SMS or Instagram DM carrying one link).

The link is `https://gene.app/i/<I>#<S>`:

- `I` — a random **invite id**; it addresses a slot on the relay.
- `S` — a 256-bit **link secret** in the URL **fragment**. Fragments are never sent to the server on a GET, so even the fallback web landing page cannot leak `S`. `S` encrypts the invite payload and authorizes its redemption — the relay stores only ciphertext it cannot open.

```mermaid
sequenceDiagram
    participant A as Alice (device)
    participant R as Relay (Worker + Durable Object)
    participant B as Bob (device)

    Note over A: generate per-invite key ia, link secret S, invite id I
    A->>R: PUT /invite/I  { enc_S( A_id, ia_pub, A→B read-cap, A's transcript sig ) }
    Note over A,B: send link  …/i/I#S  over SMS / IG  (S lives in the fragment)
    B->>R: GET /invite/I
    R-->>B: ciphertext
    Note over B: k = HKDF(S); decrypt → A_id, ia_pub, feed, sig; verify sig<br/>ephemeral ib → Z = ECDH(ib, ia_pub)
    B->>R: POST /invite/I/redeem { seal_to(ia_pub): B_id, ib_pub, B→A read-cap }
    Note over R: Durable Object: single-threaded compare-and-set<br/>open → redeemed, atomically. A second redeem fails.
    R-->>B: ok
    A->>R: GET /invite/I/redeem   (poll)
    R-->>A: Bob's sealed response
    Note over A: Z = ECDH(ia, ib_pub) → both derive K = HKDF(Z, salt S, transcript)
    R->>R: TTL elapses → slot deleted
    Note over A,B: paired — each holds peer id key, conv key K,<br/>an inbound read-cap, an outbound write key
```

**Authentication (as implemented).** The ECDH alone is unauthenticated, so each side **signs the transcript** — the invite id, both ephemeral public keys, and both identity keys — with its Ed25519 identity key, and verifies the other's signature *before* deriving `K`. The conversation key also folds the link secret as the HKDF salt: `K = HKDF(Z, salt = S, info = transcript)`. Two consequences: the identity each peer records is genuinely *proven* (so the §4 safety number is a real check, not decoration), and tampering with any exchanged value changes `K` — the two sides simply fail to talk rather than silently pairing through a man-in-the-middle.

**Why a Durable Object, not KV.** Single-use must be atomic: if two parties race to redeem, exactly one wins and the other must visibly fail. A Durable Object runs single-threaded, so the redeem is a trivially correct compare-and-set with no locking. (KV would be racy, and its 1k-writes/day cap is far too tight — see §6.) The DO also carries a TTL (e.g. 7 days) and self-deletes, bounding both the interception window and storage.

**What each side stores after pairing** — the contact record, all client-side:

- the peer's **identity public key** (for the safety number and future re-pairing);
- the **conversation key `K`** (symmetric, from the ECDH);
- an **inbound feed**: id + **read-cap** for the _peer→me_ feed;
- an **outbound feed**: id + **write key** for the _me→peer_ feed (a per-feed Ed25519 key; the relay knows only its public half — see §5).

## 3. Feeds & delivery: RSS, encrypted, ephemeral

A conversation is **two unidirectional, append-only feeds** — one per direction. Splitting them keeps the capability model crisp (each feed has one author, no write contention) and matches the per-conversation design: a feed belongs to a _relationship_, not a person.

- **Read** is a capability: holding the feed's unguessable URL authorizes reading it.
- **Write** is a signature: every appended entry must be signed by the feed's bound per-feed key. The relay pins `feed → author pubkey` at creation and verifies each append, so even a leaked write URL cannot forge entries.

The shape is RSS/Atom: a feed is a list of entries pulled by a subscriber. You can emit valid Atom with the ciphertext in `<content>` so ordinary tooling can _fetch_ it — but only Gene can _read_ it. Once encrypted, "RSS" is the architecture (pull-based, feed-per-relationship, polling subscribers), not an interoperable payload. That's the honest framing, and it's the right one.

```mermaid
sequenceDiagram
    participant A as Alice
    participant R as Relay (Worker + Durable Objects / R2)
    participant B as Bob
    Note over A: compose → media? encrypt → R2.  entry = AEAD_K( text | media-ref )
    A->>R: POST /feed/<A→B> { seq, sig(feedkey), ct }
    Note over R: verify sig vs feed's author key → append
    Note over R,B: delivery is poll-based (no push in the built system — see §6)
    B->>R: GET /feed/<A→B>?since=seq   (read-cap)
    R-->>B: entry(s)
    Note over B: verify + decrypt with K; fetch + decrypt media from R2; persist locally first
    B->>R: ACK entries + DELETE media   (destroy-after-delivery)
    Note over R: ack advances acked-watermark (rejects replay); a long TTL sweeps uncollected
```

**Destroy-after-delivery** (the product stance): the recipient persists its local copy, then ACKs — the Worker deletes the entry, the client deletes the R2 blob, and a long in-object TTL sweeps anything never collected. The client keeps its own library; the relay keeps nothing it doesn't need _in flight_. This both minimizes data-at-rest and keeps storage inside the free tier.

**Media vs text.** Text fits inline in the (encrypted) entry and never needs R2. Audio/video are encrypted, stored as an R2 object, and referenced by an entry that carries the object key _and_ the media decryption key — and since the entry is itself encrypted under `K`, that media key never reaches the relay in the clear.

## 4. End-to-end encryption

- **Content key.** Pairing's ECDH yields a conversation root `K`. Each entry is sealed with **XChaCha20-Poly1305** under a per-message subkey `HKDF(K, direction‖seq)` (the direction is the feed id — each direction is its own feed). That gives confidentiality, integrity, and _implicit authenticity_ (only the two of them hold `K`) with no ratchet state to synchronize — which, for one-to-one slow missives at low cadence, is the right amount of machinery. **No keys ever reach the relay in cleartext.** This is what "the app itself isn't privy" actually means.
- **Forward secrecy** is the obvious upgrade (periodic rekey, or a Double Ratchet). It is deliberately _not_ in the baseline: the traffic pattern doesn't justify the synchronization cost. Noted as an option, not ceremony.
- **Trust is TOFU.** A single-use link over SMS is _trust on first use_. If the channel is actively intercepted _before_ Bob redeems, an attacker could pair as "Bob." This is honest and bounded:
  - single-use + short TTL shrink the window;
  - it is **not silent** — an attacker's redemption makes the real Bob's redemption _fail_ ("link already used"), and Alice sees a pairing she can name;
  - the **safety number** — a canonical, two-sided fingerprint of both identity keys, shown in the conversation — upgrades TOFU to verified ("read me your digits"). Because each side signs the pairing transcript with its identity key (§2), the number is a real MITM check: an attacker who substitutes identity yields different digits on the two phones.

For the stated threat model — friends exchanging missives, "little danger of content falling into the wrong hands," not a nation-state — TOFU + content E2E is appropriate and strong. We don't oversell it as Signal-grade _authenticated_; the confidentiality-against-the-relay property, however, is real.

## 5. Metadata: the honest ledger

Content can be made fully opaque to the relay. Metadata cannot — not entirely. Here is everything the relay (Cloudflare) and the network can observe even with perfect content E2E, what's mitigable, and what's residual.

| The relay/network can observe | Mitigable? | How | Residual |
|---|---|---|---|
| **IP + timing** of every publish/poll → coarse geolocation, ISP, online pattern, timezone | ✗ | Only Tor / VPN / a mixnet — none free, none good mobile UX | **The hardest leak.** Out of scope for a free relay. |
| **The pairing event** links two endpoints in time | ~ | Jitter; the slot is opaque and short-lived | "These two devices paired near time T." |
| **Social graph** — who reads/writes which feed | ✓ (cross-relationship) | **Per-feed write keys, never the identity key** → the relay can't tell feed-AB and feed-AC share author Alice. Per-conversation feeds do the rest. | Per _pair_, the two endpoints share a feed and are linkable. Unavoidable. |
| **Sizes, counts, cadence** → infer modality, intensity, time-of-day | ✓ | **Pad** entries to fixed buckets; **fixed-cadence polling** regardless of traffic; optional cover entries | Cheap for text, coarse for media. |
| **Push timing** (if used) — APNs/FCM see a device token + that _a_ notification arrived | ✓ | **Content-free wake pushes** (no feed id — "check your feeds"); or no push at all (background fetch) | Apple/Google learn timing, not which conversation. |
| **TLS SNI / DNS** → "you are a Gene user" | ✓ | Encrypted Client Hello (Cloudflare) + DoH | Reveals app use, not content or peers. |

The one structural insight worth stating plainly: **the identity key must never be the server-visible write credential.** If every feed Alice writes were signed by the same identity key, the relay could trivially link all her relationships. Binding each feed to a _distinct_ per-feed key, and proving the real identity only end-to-end to the peer, is what keeps the relay from reconstructing a user's social graph.

**Ceiling.** Killing IP-level metadata needs a mixnet/onion layer — a different, non-free project (Tor, Nym). So "truly metadata-free" is not on the table for a free Cloudflare relay. "**Content-private with minimized, largely-mitigated metadata**" is — and for text it is genuinely achievable.

## 6. Is it _truly_ free? — the quota math

Cloudflare free-tier limits that bind the design (verified June 2026; confirm before relying):

| Service | Free allowance | Consequence for Gene |
|---|---|---|
| **Workers** | 100k requests/day; 10 ms CPU each | The binding constraint. Polling is the enemy. |
| **KV** | 100k reads/day, **1k writes/day**, 1 GB | Too few writes for an append log — **don't** put feeds here. |
| **D1 / DO (SQLite)** | 100k row-writes/day, 5 M reads/day, 5 GB | The right home for feeds **and** the rendezvous. |
| **R2** | 10 GB; 1 M write-ops, 10 M read-ops /mo; **egress free** | The only reason media is thinkable — buffer-in-flight, not archive. |
| **Durable Objects** | SQLite backend, 100k req/day, 13k GB-s/day | Atomic single-use redemption, free. |

**The binding constraint is Workers requests, and polling drives it.** A device polling every minute, 24/7, spends 1,440 requests/day → the free tier holds only **~69 always-on pollers**. The fix isn't a bigger quota, it's not polling in the background:

- **poll only while the app is foregrounded** (people use a missive app in bursts, minutes/day);
- **a content-free wake push** (the design for the background case — not yet built; today the app syncs only when foregrounded) would move "tell me when there's news" _off_ Workers entirely.

With that, Workers requests ≈ _actual sends + actual fetches_, not continuous polling — and the free tier comfortably holds **hundreds** of low-traffic users.

### How far each modality goes, on the free tier

| | Storage / quota pressure | Privacy (metadata) | Free at meaningful scale? |
|---|---|---|---|
| **Text** | None worth counting — lives in D1/DO | **Best.** Padding + fixed-cadence polling are cheap enough to actually deploy | **Yes — robustly.** The sweet spot. |
| **Audio** (Opus, ~0.5–1 MB/min) | R2 only; destroy-after-delivery keeps steady-state tiny; egress free | Good — small, paddable to coarse buckets | Yes, small/medium scale. Keeps the "missive" feel. |
| **Video** | Largest; leans hard on egress-free R2 + retention discipline | Weakest — size betrays modality and intensity | ≈free at small scale; the most expensive and least private. |

**Direct answer to the question.** Yes — a **text-only, fully end-to-end-encrypted** Gene is genuinely free on Cloudflare, not "free until it isn't." Text is also the _most defensible_ version of the idea: opaque content, the cheapest path to real traffic-analysis resistance, and quotas it can't realistically exceed at friend-and-family scale. Audio is a small, attractive step up that preserves the voice of the format. Video works only because R2 egress is free, and only with strict destroy-after-delivery — it's where "≈free" starts needing asterisks.

The shared-RSS idea, then, goes _far_: a zero-knowledge relay, capability-secured feeds, accountless sealed pairing, content encrypted end-to-end and destroyed after delivery — all inside a free tier, for tens-to-hundreds of correspondents. What it can't buy for free is IP-level anonymity; that's the honest edge of the envelope.

## 7. Threat model — what this does and doesn't defend

- **Defends:** content confidentiality + integrity against the relay and the network. The relay holds no PII, no plaintext, no durable content; compromising it yields ciphertext and coarse metadata, not messages.
- **Partially:** traffic-analysis metadata — sizes, cadence, cross-relationship linkage are mitigable (cheaply for text); the pairwise graph and IP/timing are not.
- **Does not defend:** a compromised endpoint device (the keys live there); a global passive adversary correlating IPs (needs a mixnet — out of scope); active MITM of an invite link _before first use_ (TOFU — detectable, and optionally upgraded via safety numbers).

## 8. Open decisions

- **Deferred deep-link across install** — carrying `#S` through an app-store install when the link is opened before the app exists is fiddly; may need a deferred-deep-link path or a "paste your link" fallback.
- **ACK vs TTL** for destroy-after-delivery — *resolved:* explicit ACK is the prompt path (the client acks only after persisting its local copy), with a long in-object TTL sweep as the backstop for entries never collected.
- **Forward secrecy** — baseline ships without; revisit if the threat model rises.
- **Multi-device / key loss** — now designed in §9. v1 has the free fallback (re-pair) implicitly; device-to-device transfer and user-custodied backup are the v2 upgrades.

## 9. Device migration & recovery

A zero-knowledge relay holds none of your secrets — so, by construction, **there is no cloud to restore from.** That isn't a gap; it's the property we paid for. Recovery therefore needs either the old device or a secret only you hold. Exactly three paths, in descending order of grace:

**A. Migrate — old device in hand (the good case).** The transferable *vault* is the identity keys plus every contact record (peer identity key, conversation key `K`, inbound read-cap, outbound write key); optionally the local media library. A **QR shown on the old device bootstraps a direct, encrypted channel** (the QR carries an ephemeral key; the devices derive a shared secret), and the vault transfers **device-to-device over the local network** — never through the relay. This is the Signal/WhatsApp transfer pattern; it's QR-*bootstrapped* rather than QR-*only* because many contacts' keys plus media exceed a QR's capacity. Identity is preserved, so peers' safety numbers stay valid — no re-verification.

**B. Recover — old device gone, backup made (the E2E tax).** With no old device, the only posture-preserving option is a backup **you** custody: the vault sealed under a key derived from a passphrase / recovery code (Argon2id). The ciphertext can live anywhere — your own cloud drive, a file, paper — because it's opaque without the secret; the operator still holds nothing. This reintroduces "something to remember," the unavoidable cost of E2E recovery (cf. Signal's PIN). Opt-in; decline it and loss is final.

**C. Re-pair — nothing saved (the free floor).** Even with no backup and no device, the *connection* isn't gone forever: send each contact a fresh single-use invite. It costs a new conversation key (the old encrypted feed won't decrypt) and a **changed identity key**, which flips the peer's safety number — visibly, as "re-paired from a new device," nameable and re-verifiable. A middle ground: transfer *only* the identity key (it fits one QR) to keep the safety number stable, then re-pair the feeds.

**The line you can't cross.** "The operator restores my account" would require the operator to hold a secret — exactly what zero-knowledge forbids. You get the old device, a secret you kept, or a fresh start. Nothing else is honest.

**v1 vs later.** Re-pair (C) is free — it's just the §2 invite flow, so v1 has it implicitly. Device-to-device transfer (A) and user-custodied backup (B) are the v2 upgrades; this section is their design.
