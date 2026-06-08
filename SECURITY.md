# Security model

This is the document to read with a skeptical eye. It states what gene protects,
**points each claim at the code that enforces it** so you can verify rather than
trust, and is honest about what it does *not* defend. gene is a zero-knowledge
delivery **primitive**; the properties below are the **security ceiling any app
built on it inherits** — the video-missive app is the reference consumer. The full
design rationale is in [BACKEND.md](BACKEND.md); this is the auditor's view.

## The one-sentence claim

> Message content — whatever bytes an app moves over gene (here, video) — is
> encrypted on the sender's device and decryptable only on the recipient's. The
> relay (Cloudflare) and anyone who controls it see **only ciphertext and coarse
> metadata**, never content, keys, or your durable identity.

## Trust model: what runs where

| Party | Holds | Trusted with |
|---|---|---|
| **The two devices** | identity keys, conversation key `K`, per-feed write keys, the decrypted library | everything — this is where plaintext lives |
| **The relay (Cloudflare Worker + Durable Objects + R2)** | opaque ciphertext, signatures, feed ids, ephemeral handshake keys | routing bytes; verifying signatures it cannot read; nothing else |
| **The out-of-band channel** (the link you send) | the one-time invite link | bootstrapping first contact (TOFU — see Limitations) |

The security rests on the **client being honest** — which is why this repo is
meant to be read and built yourself. E2EE you can't audit is a promise; E2EE you
can audit is a property.

## Can the relay read a video? Follow the key chain.

1. **Pairing derives a shared key `K` on each device and never sends it.**
   X25519 ECDH → `z`, then `K = HKDF(z, salt = S, info = transcript)`.
   → `lib/src/pairing/pairing_service.dart` (`_conversationKey`), `lib/src/crypto/primitives.dart` (`Crypto.sharedSecret`, `Crypto.hkdf`).
   The link secret `S` lives in the URL `#fragment`; the app parses it locally and a browser never transmits a fragment, so the relay never sees `S` either.

2. **Sending a video seals it before upload.** A fresh random per-blob key `mk`
   encrypts the video; only the ciphertext goes to R2. `mk` + the object id are
   placed in a message that is then sealed under a per-message subkey of `K`.
   → `lib/src/messaging/messaging_service.dart` (`send`): `Crypto.seal(mediaKey, clear)` → `putMedia`, then `Crypto.seal(subkey, …Missive…)`.
   → `lib/src/messaging/models.dart` (`Missive` carries `mediaId` + `mediaKey`).
   → `lib/src/messaging/message_crypto.dart` (`messageSubkey` = `HKDF(K, feedId‖seq)`).

3. **So the only copy of `mk` is locked inside a message encrypted under `K`,**
   and `K` is only on the two devices. To read the video you need `mk`; to get
   `mk` you need `K`. The relay has neither.

4. **The relay stores and serves opaque bytes only.** It verifies an Ed25519
   signature over `seq‖ciphertext` (it never decrypts), then appends.
   → `relay/src/index.ts` (handlers store/return raw bytes), `relay/src/feed_slot.ts` (`append` verifies, never reads), `relay/src/crypto.ts` (`verifyEd25519`).
   → `relay/src/landing.ts` serves the invite landing page; the secret is in the fragment, so even that page is zero-knowledge.

**Result:** root on the bucket and the database yields ciphertext plus a key that
is itself ciphertext. There is no plaintext and no usable key on the relay side.

## Properties and where they're enforced

| Property | Enforced by |
|---|---|
| Conversation key `K` never leaves the device | `pairing_service.dart` derives it locally; only public keys + sealed blobs are sent |
| Handshake is **authenticated** (identity is proven, not asserted) | both sides sign the transcript and verify before deriving `K` — `pairing_service.dart` (`_inviteTranscript`/`_redeemTranscript`, `Crypto.verify`) |
| `K` also depends on the out-of-band secret `S` | `K = HKDF(z, salt = S, …)` — tampering changes `K`, so a MITM fails to communicate rather than silently succeeding |
| Media sealed before it ever leaves the device | `messaging_service.dart` (`send`) |
| Relay sees only ciphertext | `relay/src/*.ts` — no decryption anywhere; bodies are opaque |
| Relay can't link your relationships | each feed is signed by a **per-feed** Ed25519 key, never your identity key — `pairing_service.dart` (`Crypto.newSigningKey()` per feed); see BACKEND.md §5 |
| Identity keys hidden from the relay | exchanged *inside* the sealed handshake payload/response; the relay sees only ephemeral + per-feed public keys |
| Invites are single-use | Durable Object compare-and-set under the input gate — `relay/src/invite_slot.ts` (`redeem`) |
| Entries can't be forged with a leaked read capability | every append is signature-checked against the pinned per-feed key — `relay/src/feed_slot.ts`, `relay/src/crypto.ts` |
| Replay/regression rejected | per-feed acked-watermark — `relay/src/feed_slot.ts` (`append` rejects `seq ≤ ackedUpTo`; `ack` clamps the watermark to the highest stored seq, so a reader can't brick the author) |
| Destroy-after-delivery | recipient persists locally, *then* destroys the relay copy — `messaging_service.dart` (`fetchNew` writes media to disk; `confirm` acks + deletes), ordered persist-before-destroy in `messaging_providers.dart` (`Conversation.sync`); `relay/src/feed_slot.ts` (`ack`), media `DELETE` |
| Media can't be silently overwritten | `PUT /media/:id` is write-once (`etagDoesNotMatch:"*"` → 409) — `relay/src/index.ts` (`handleMedia`) |
| Keys at rest | identity seed + per-contact `K`/write seeds in the platform Keystore — `lib/src/identity/identity_store.dart`, `lib/src/storage/secure_storage.dart` |

## What it does NOT defend (the honest edges)

- **Active MITM of the *first* contact (TOFU).** If the invite link's secret is
  intercepted before the peer redeems, an attacker could pair as them. It is
  **detectable**: the two-sided **safety number** (`Contact.safetyNumber`,
  `lib/src/pairing/models.dart`) is identical on both phones only if no one is in
  the middle — compare it over a channel you already trust. Not yet *enforced* in
  the UX, so it relies on the users choosing to check.
- **No forward secrecy / post-compromise security (yet).** `K` is static per
  conversation, so a compromised `K` exposes past messages under it. The
  per-message subkey is derived deterministically from `K`, so it is *not* a
  ratchet. This is the deliberate deferral in BACKEND.md §4; the Double Ratchet
  (or a periodic rekey) is the upgrade.
- **Metadata.** The relay/network see IP + timing, the pairing event, and
  sizes/cadence. Sizes/cadence are mitigable (padding + fixed-cadence polling —
  designed, not built); **IP/timing are not** without a mixnet (out of scope for
  a free relay). See BACKEND.md §5.
- **A compromised endpoint.** Keys and the decrypted library live on the device;
  root on the phone defeats E2EE. The local media library is currently stored
  decrypted on disk (`MessageStore`) — at-rest encryption of the library is a
  reasonable future hardening.
- **Formal assurance.** The protocol is standard primitives
  (X25519/Ed25519/HKDF/XChaCha20-Poly1305) composed in a documented, tested way —
  **not** a formally-verified protocol or an audited library. For higher
  assurance, adopt libsignal / Noise / MLS, or commission an audit.
- **Availability / abuse.** Relay ids are client-chosen and creation is
  unauthenticated (high-entropy, so squatting needs a TLS-level MITM, but there's
  no rate-limiting yet). See relay/README.md "Not yet."

## Verify it yourself

- **Read the four files that matter:** `lib/src/pairing/pairing_service.dart`,
  `lib/src/messaging/messaging_service.dart`, `lib/src/messaging/message_crypto.dart`,
  and `relay/src/index.ts`. The entire client→relay→client path is there.
- **Run the relay tests** (`cd relay && npm test`) — they exercise the real
  `workerd` runtime and assert the relay only stores/serves bytes, verifies
  signatures, and destroys on ack.
- **Run the client tests** (`flutter test`) — `test/messaging_test.dart` drives a
  full send→relay→receive loop and asserts the media round-trips *and* that a peer
  with the wrong `K` decrypts nothing.
- **Inspect what's stored:** every relay body is `application/octet-stream`
  ciphertext or base64 inside JSON; grep `relay/src` for any `decrypt`/`open` —
  there is none on the server.

## Cryptographic primitives

Ed25519 (identity + per-feed signing), X25519 (ECDH), HKDF-SHA256 (key
derivation), XChaCha20-Poly1305 (AEAD sealing), SHA-256 (safety number). Client:
`package:cryptography` (pure Dart), wrapped behind `Crypto`
(`lib/src/crypto/primitives.dart`) so it can be swapped for libsodium. Relay:
WebCrypto in `workerd` (`relay/src/crypto.ts`).

## Reporting

This is a prototype, not a hardened product. If you find a weakness, the right
move is to open it with the maintainer directly rather than filing publicly.
