# CLAUDE.md

Orientation for Claude working in this repo. Keep answers grounded in the code
and the docs below; this is a real, working system, not a sketch.

## What this is

**gene** — slow, high-fidelity, one-to-one video missives. A take is recorded,
**auto-edited on-device** (dead air trimmed via acoustic analysis), then sent
**end-to-end encrypted** through a **zero-knowledge Cloudflare relay** and
destroyed server-side after delivery. Accountless: people connect via a
single-use invite link. The product framing is "familiar, high-quality, free
video messaging," not a privacy pitch — but the privacy properties are real (see
SECURITY.md).

Note: the working folder is `C:\dev2\roger` and the Android package is `dev.gene`
— the product was renamed Roger→Gene; the folder path was intentionally left as
`roger`. There is no remaining "roger" or personal name in source.

## Read these first

- **[README.md](README.md)** — what it does, how to run it, the pipeline.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — module map, the Pigeon boundary, state model, the editing engine.
- **[SECURITY.md](SECURITY.md)** — the threat model, code-pointered. Read this before answering any "is it secure / can Cloudflare see X" question.
- **[BACKEND.md](BACKEND.md)** — the full pairing + delivery + E2EE design and rationale.
- **[PRIMITIVE.md](PRIMITIVE.md)** — gene as a reusable primitive: the primitive/app seam, the trust spectrum, and building other apps (incl. non-messaging) on its core.
- **[relay/README.md](relay/README.md)** — the relay's exact HTTP contract.

## Repo map

```
lib/src/
  crypto/        Crypto — the only crypto surface (Ed25519, X25519, HKDF, XChaCha20-Poly1305, SHA-256)
  identity/      device identity (Ed25519 seed) in the Keystore
  pairing/       the authenticated single-use handshake, Contact model, RelayTransport (+ in-memory fake)
  messaging/     per-message crypto, send/sync service, the local missive library
  storage/       one shared Keystore posture
  contacts/      home list · connect (invite) · conversation screens
  recorder/      camera lifecycle (Riverpod Notifier) + capture UI
  editor/        tighten (auto-edit) orchestration over the Pigeon boundary
  playback/      looping player + send action
android/app/src/main/kotlin/dev/gene/   native editing engine (AudioAnalyzer · VideoSplicer · EditorApiImpl)
pigeons/editor_api.dart                  the typed Dart↔Kotlin boundary (source of truth; regenerate, don't hand-edit *.g.*)
relay/                                   the zero-knowledge relay (TypeScript; Workers + SQLite DOs + R2)
```

## Security invariants (do not violate when editing or advising)

1. **The relay only ever sees ciphertext.** Never add a server path that decrypts, logs plaintext, or transmits a key/`K`/`S`. All sealing/opening is client-side.
2. **`K` and identity private keys never leave the device.** Only public keys and sealed blobs cross the wire.
3. **Per-feed keys, never the identity key, sign feed writes** (un-linkability — BACKEND.md §5).
4. **The link secret `S` lives only in the URL `#fragment`.** Don't move it into a path/query or send it to the server.
5. **Crypto goes through `Crypto`** (`lib/src/crypto/primitives.dart`) and the shared formats in `lib/src/messaging/message_crypto.dart` — which must stay byte-compatible with `relay/src/codec.ts` + `crypto.ts`.

## Build · run · test

```sh
flutter pub get
flutter run -d <device>                           # Android device with a front camera
flutter analyze && flutter test                   # Dart: pairing, messaging loop, editor
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin: Otsu + keep-range math
cd relay && npm test && npm run typecheck         # relay in the real workerd runtime
dart run pigeon --input pigeons/editor_api.dart   # regenerate the native boundary after editing the schema
```

The relay URL is **config, not hardcoded**: pass
`--dart-define=GENE_RELAY_URL=https://<your-worker>.workers.dev`
(`relayBaseUrlProvider` reads it; defaults to `http://localhost:8787`). Local
dev: `cd relay && npm run dev` + `adb reverse tcp:8787 tcp:8787`. Two devices
must point at the **same** relay to pair.

## Conventions

- **Thoughtful and efficient, not clever.** Minimal, well-patterned, reuse componentry; abstractions only where they earn their keep.
- **Riverpod without codegen**; **Pigeon is the only code generator** (the `*.g.dart`/`*.g.kt` files).
- **Feature-first** layout: `<feature>/<feature>_{controller,state,screen}` + `widgets/`; providers are the DI seam.
- Domain/decision logic is kept pure and unit-tested; hardware layers (camera, media codec) are verified on a device, not mocked.

## Glossary

- **Conversation key `K`** — the per-relationship root key from pairing's ECDH; every message subkey derives from it.
- **Feed** — one direction of a conversation: append-only, signed by a per-feed key, read by capability (holding its unguessable id).
- **Missive** — one video message (the sealed feed entry references its encrypted R2 blob + that blob's key).
- **Capability** — holding a feed's unguessable id authorizes reading it.
- **TOFU / safety number** — trust-on-first-use pairing, verifiable out-of-band via a two-sided fingerprint of both identity keys.
- **Relay** — the stateless-ish Cloudflare layer that routes opaque bytes and destroys them after delivery.

## Environment

Windows dev host (PowerShell 5.1). The relay's media bucket is R2 (`gene-media`);
a deploy without the R2 binding returns `503 media_unconfigured` on `/media/*` by
design. Forward secrecy and abuse/rate-limiting are documented, deliberate
deferrals — see SECURITY.md and relay/README.md before claiming they exist.
