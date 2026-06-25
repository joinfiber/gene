# Architecture

## Principles

Minimalist, performant, well-patterned — _thoughtful and efficient, not clever_. Abstractions appear only where they earn their keep: the Dart↔native seam is typed and generated; crypto lives behind one small surface; the relay is reached through one interface (`RelayTransport`) — the integration seam for the delivery primitive, with an in-memory twin that exercises the full client crypto path in tests; and the one genuinely stateful thing (the camera) gets a real controller, while nothing else is dressed up to look like one.

**Primitive, with a demo.** The core is a zero-knowledge delivery primitive — `crypto/`, `pairing/`, `messaging/`, and the `relay/` — that moves only ciphertext and public keys. The video-missive UI (`recorder/`, `editor/`, `playback/`, `contacts/`) is its reference app: the highest-trust point on a spectrum others build _down_ from ([PRIMITIVE.md](PRIMITIVE.md)). Read the layout below as core-plus-consumer, not one flat app.

## Layout

```
lib/
  main.dart                      ProviderScope + GeneApp
  src/
    app.dart                     MaterialApp, theme, home
    theme.dart                   single source of visual style
    crypto/
      primitives.dart            Crypto: Ed25519 · X25519 · SHA-256 · HKDF · XChaCha20-Poly1305
    identity/
      identity_store.dart        device identity (Ed25519 seed) in the Keystore
    pairing/
      models.dart                LocalIdentity · Contact (+ two-sided safety number)
      pairing_service.dart       the authenticated single-use handshake
      relay_transport.dart       RelayTransport interface + in-memory fake
      http_relay_transport.dart  RelayTransport over HTTP
      contact_store.dart         contacts in secure storage
      pairing_providers.dart     identity / contacts / relay providers
    messaging/
      message_crypto.dart        signed-message format + per-message subkeys
      messaging_service.dart     send · fetchNew · confirm  (encrypt → relay → decrypt)
      message_store.dart         the local missive library
      models.dart                Missive · ReceivedMissive
      messaging_providers.dart   library + conversation orchestration
    storage/
      secure_storage.dart        one shared Keystore posture for every store
    contacts/
      contacts_screen.dart       home: the people you're connected to
      connect_screen.dart        create / redeem an invite link
      conversation_screen.dart   one conversation: receive · verify · record
    recorder/
      recorder_controller.dart   camera lifecycle (Riverpod Notifier)
      recorder_state.dart        immutable state
      recorder_screen.dart       composition only
      widgets/                   camera_preview_box · record_button · status_pill
    editor/
      editor_api.g.dart          Pigeon-generated Dart client  (do not edit)
      editor_providers.dart      editorApiProvider  (DI seam)
      tighten_controller.dart    detect → splice orchestration
      tighten_result.dart        domain model; presentation math
      widgets/edit_summary.dart  the branded result card
    playback/
      playback_screen.dart       looping player; optional send action

android/app/src/main/kotlin/dev/gene/               (the editing engine)
  MainActivity.kt                registers the Pigeon host; disposes it on teardown
  editor/
    EditorApi.g.kt               Pigeon-generated host + codec  (do not edit)
    AudioAnalyzer.kt             decode → Otsu → keep-ranges  (pure math, tested)
    VideoSplicer.kt              Media3 Transformer splice
    EditorApiImpl.kt             wiring + threading

pigeons/editor_api.dart          the schema — source of truth for the boundary
relay/                           the zero-knowledge relay (TypeScript) — see relay/README.md
```

## The Dart↔native boundary (Pigeon)

`pigeons/editor_api.dart` is the single source of truth. `dart run pigeon …` generates the Dart client and the Kotlin host interface + message codec, replacing a stringly-typed `MethodChannel` with compile-checked types (`KeepRange`, `DetectionResult`) on **both** sides.

To add a native capability: edit the schema → regenerate → implement the new method in `EditorApiImpl`. The compiler enforces that both ends agree.

## State (Riverpod, no codegen)

- **`recorderControllerProvider`** — a `Notifier` owning the camera lifecycle: permissions, init, recording, a wake-lock that keeps the screen awake while the camera is open, salvage-on-background, and disposal that finalizes an in-flight take. The mutable `CameraController` is held by the controller and exposed via a getter; the *published* state is immutable (`RecorderState`), and writes are guarded so a disposed notifier is never assigned.
- **`tightenControllerProvider`** — orchestrates one auto-edit; its state is just "in flight?" so the UI can show a busy overlay.
- **`editorApiProvider`** — the native engine, injected so callers depend on the boundary (and tests can override it).
- **`identityProvider`** — the device identity, loaded (or created) once.
- **`contactsProvider`** — the `ContactsController`; mutations publish immediately and persist through a **serialized write chain**, and field-level updates (`mutate` / `advanceInboundCursor`) merge onto the *live* contact so a concurrent send and sync can't clobber each other's seq/cursor.
- **`relayTransportProvider`** — the `RelayTransport`; HTTP in the app, swapped for the in-memory fake in tests.
- **`libraryProvider`** / **`missivesDirProvider`** / **`conversationProvider`** — the received-missive library (`ingest` dedups by feed+seq, so a re-sync after a crash never doubles a missive), the shared directory each missive's relative filename resolves against, and the orchestrator that runs a send or a sync (`fetchNew` → persist → `confirm`) and keeps the service, the contact (its seq/cursor), and the library in step.

`recorder_screen.dart` composes the recorder providers with `.select`, so the per-second recording timer rebuilds only the status pill — never the camera texture.

## Pairing, identity & trust

Identity is an **Ed25519 keypair** generated on first launch; the public key *is* the "who," and only its 32-byte seed is persisted (Keystore-backed). The relay never sees it.

Pairing (`pairing_service.dart`, BACKEND.md §2) is a single-use sealed rendezvous over one link, `…/i/<id>#<S>`:

- `S`, the 256-bit link secret, lives in the URL **fragment** — never sent to the server — and seals the invite payload, so the relay stores only ciphertext it can't open.
- Both sides exchange ephemeral X25519 keys and run ECDH → `z`, and **each signs the key-exchange transcript** (invite id, both ephemerals, both identity keys) **with its Ed25519 identity key and verifies the other's before deriving the conversation key**. That turns "the identity is carried" into "the identity is *proven*," which is what makes the safety number meaningful.
- The conversation key folds the out-of-band secret: `K = HKDF(z, salt = S, info = transcript)`. Tampering with any exchanged value changes `K`, so a tampered handshake fails to communicate rather than silently pairing through an attacker.
- `Contact.safetyNumber` is a canonical fingerprint over both identity keys — **identical on both devices** regardless of who invited whom — the TOFU→verified upgrade ("read me your digits"), surfaced in the conversation screen.

Defensive throughout: ECDH rejects an all-zero (low-order) shared secret, and every relay-supplied field is length-checked, so a hostile or buggy relay yields a clean `PairingException`, not a `RangeError` or an opaque AEAD throw.

## Conversations & delivery

A conversation is **two unidirectional, append-only feeds** (BACKEND.md §3–§4). Each is bound to a fresh **per-feed Ed25519 key** — never the identity key — so the relay can't tell that two feeds share an author (social-graph protection). These un-linkability and authenticated-pairing properties belong to the *primitive* — any app on this core inherits them; the missive UI just surfaces the safety number.

- **Sealing** — each entry is sealed with XChaCha20-Poly1305 under a per-message subkey `HKDF(K, feedId‖seq)`; the feed id *is* the direction, so sender and receiver derive the same key with no ratchet state to sync. The signed bytes (`seq‖ciphertext`) and the subkey derivation live in `message_crypto.dart` — one source of truth the relay's verifier matches byte-for-byte.
- **Media** — sealed under a fresh per-blob key, uploaded to R2; the (sealed) entry carries the object id and that key, so the media key never reaches the relay. (Sealed in memory — fine for short missives; streaming AEAD is the large-video upgrade.)
- **Lazy feed creation** — `MessagingService.send` appends, and on a "feed not found" binds the feed with its author key and retries. A retried send (the relay already holds that seq) is treated as delivered, and a freshly-uploaded blob is deleted on any append failure — so neither a feed nor a media object is orphaned. Pairing therefore creates *no* feeds.
- **Destroy-after-delivery** — split for crash-safety: `fetchNew` pulls new entries, decrypts, and writes media to disk (stopping at the first it can't fully receive); the `Conversation` orchestrator persists that library; only then does `confirm` ack — the relay deletes the delivered entry, and the client deletes the R2 blob. The relay copy is never destroyed before the device has durably kept its own — and "durably" is literal: the library index is written via temp file → `flush` → rename (an atomic replace on POSIX, crash-recoverable on Windows — never a truncate-in-place a crash could tear; load prefers a leftover temp as the newer state), and a lost or corrupt index is rebuilt from the on-disk media (each named `<feedId>-<seq>.mp4`), so a torn write degrades to reconstruction rather than silent loss (`message_store.dart`, `test/message_store_test.dart`).

## The editing engine (native)

This is a feature of the reference app, not the delivery primitive — an example of the on-device, pre-encryption processing the core enables, kept off any server.

- **`AudioAnalyzer`** — the decision math (`otsu`, `computeKeepRanges`, expressed as interval `Span` operations: trim → collapse → merge → complement) is pure over decoded PCM with no Android dependencies, which is what makes it unit-testable on the JVM. Only `decodeAudioMono` touches `MediaCodec`; it reads the decoder's *output* format (16-bit or float PCM), carries partial frames across buffers, and releases the codec/extractor in a `finally` on every path.
- **`VideoSplicer`** — Media3 `Transformer`; driven on the main thread because Transformer needs a `Looper`. Each export owns its `Transformer`; a second request while one is in flight is rejected, and `cancel()` is wired to teardown.
- **`EditorApiImpl`** — threading policy in one place: detection on a worker `Executor` (CPU-heavy), splice on the main thread, both replying via the Pigeon callback on the main thread (guarded against a destroyed Activity).

## Why energy + Otsu, not ASR

Measured on real footage: Whisper omitted **100%** of injected fillers and reported a single pause where acoustic analysis found ~27 — its word timestamps smear across silence. So transcription can detect neither fillers nor pauses reliably. A fixed energy threshold proved brittle (a 5 dB nudge swung the cut from 4% to 51%), so the analyzer uses **Otsu's method** to find the silence/speech split per-clip, with no tunable threshold.

## Key decisions & trade-offs

| Decision | Why |
|---|---|
| Pigeon over raw `MethodChannel` | type safety at the riskiest seam |
| Riverpod without codegen | state management without a second build step (Pigeon is the only generator) |
| Authenticated pairing transcript | identity must be *proven*, so the safety number is a real MITM check, not decoration |
| Conversation key folds the link secret `S` | `K` depends on the out-of-band secret, not the ECDH alone |
| Per-feed write keys, never the identity key | keeps the relay from linking one user's separate relationships |
| `RelayTransport` interface + in-memory fake | the whole pairing + messaging crypto path is tested without a network |
| Media sealed in memory, client-side | simple and correct for short missives; streaming AEAD is the large-video upgrade |
| Relay URL is build config (`GENE_RELAY_URL`, default localhost) | the relay is the shared rendezvous; a build points at its own, and the public repo ships no baked-in server |
| Cover-fit preview via an aspect-ratio box | a `Transform.scale` approach stretched the 4:3 preview vertically |
| Wake-lock while the camera is open | the system screen-timeout was pausing the activity and destroying in-progress recordings |
| Filler removal deferred | neither transcription nor energy detects it; it's real R&D, not a quick add |

## Testing strategy

- **Kotlin** — the core algorithm (`otsu`, `computeKeepRanges`, including the all-silence / both-edges / adjacent-pause edge cases) as pure JVM unit tests.
- **Dart** — the pairing handshake (same `K` derived both sides, single-use, the two-sided safety number, malformed-link rejection); the messaging loop end-to-end against the in-memory relay (encrypt → relay → decrypt, media round-trips, destroy-after-delivery, a wrong key reads nothing); transport plumbing via a mock HTTP client; and the editor's domain math + orchestration.
- **TypeScript** — the relay runs its tests inside the real `workerd` runtime (Durable Objects, Ed25519, R2), not against mocks — see `relay/README.md`.
- **Not mocked** — the camera and native-media layers are hardware-bound and verified on a device, not faked.
