import { fromB64, toB64 } from "./codec";
import { FeedSlot } from "./feed_slot";
import { bytes, json } from "./http";
import { InviteSlot } from "./invite_slot";
import { landingPage } from "./landing";

export { FeedSlot, InviteSlot };

export interface Env {
  INVITE: DurableObjectNamespace<InviteSlot>;
  FEED: DurableObjectNamespace<FeedSlot>;
  /// Optional: absent on the free-plan deploy (no R2); present in tests and once
  /// video sending is wired.
  MEDIA?: R2Bucket;
}

/** A seq/upTo is a non-negative, safe-integer feed index. */
function isFeedIndex(n: unknown): n is number {
  return (
    typeof n === "number" &&
    Number.isInteger(n) &&
    n >= 0 &&
    n <= Number.MAX_SAFE_INTEGER
  );
}

/** Decode base64, returning `undefined` on malformed input (atob throws). */
function tryFromB64(text: string): Uint8Array | undefined {
  try {
    return fromB64(text);
  } catch {
    return undefined;
  }
}

// The sealed handshake blobs are tiny (a few hundred bytes); 8 KB is generous
// headroom while still capping what a single unauthenticated request can buffer.
const INVITE_MAX_BYTES = 8 * 1024;

// A feed entry's JSON wraps a base64 signature plus the sealed ciphertext — for
// these missives a few hundred bytes. 64 KB is generous headroom while staying
// well under the Durable Object's 128 KB per-value storage limit, so an oversized
// entry is a clean 413 rather than a 500 from the storage layer, and one
// unauthenticated append can't buffer an arbitrary amount. Acks are tinier still;
// the same cap covers them trivially.
const FEED_JSON_MAX_BYTES = 64 * 1024;

/**
 * Buffer a request body, refusing anything larger than [max] bytes. Checks the
 * declared `content-length` first so an oversized upload is rejected *before* it
 * is read into memory, then re-checks the actual size (the header can be absent
 * on a chunked body, or simply lie). Returns `"too_large"` to signal a 413.
 */
async function readCappedBody(
  request: Request,
  max: number,
): Promise<ArrayBuffer | "too_large"> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return "too_large";
  const body = await request.arrayBuffer();
  if (body.byteLength > max) return "too_large";
  return body;
}

/**
 * Buffer, size-cap, and parse a JSON body. Returns `"too_large"` to signal a
 * 413, or `undefined` for malformed JSON (so callers validate shape uniformly).
 */
async function readCappedJson(
  request: Request,
  max: number,
): Promise<unknown | "too_large"> {
  const body = await readCappedBody(request, max);
  if (body === "too_large") return "too_large";
  try {
    return JSON.parse(new TextDecoder().decode(body));
  } catch {
    return undefined;
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const [resource, id, action] = url.pathname.split("/").filter(Boolean);

    if (resource === "invite" && id) {
      return handleInvite(request, env, id, action);
    }
    if (resource === "feed" && id) {
      return handleFeed(request, env, id, action, url);
    }
    if (resource === "media" && id) {
      return handleMedia(request, env, id);
    }
    // Human-facing landing page for a shared invite link (…/i/:id#secret). The
    // fragment-secret is never sent to the server, so this stays zero-knowledge;
    // the page just guides the recipient to paste the link into the app.
    if (resource === "i" && id) {
      if (request.method === "GET") return landingPage();
      return json({ error: "method_not_allowed" }, 405);
    }
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;

/** Routes one invite slot's requests to its Durable Object. */
async function handleInvite(
  request: Request,
  env: Env,
  id: string,
  action: string | undefined,
): Promise<Response> {
  const slot = env.INVITE.get(env.INVITE.idFromName(id));

  if (action === undefined) {
    if (request.method === "PUT") {
      const payload = await readCappedBody(request, INVITE_MAX_BYTES);
      if (payload === "too_large") return json({ error: "too_large" }, 413);
      const created = await slot.create(payload);
      return created
        ? json({ ok: true }, 201)
        : json({ error: "already_exists" }, 409);
    }
    if (request.method === "GET") {
      const payload = await slot.payload();
      return payload ? bytes(payload) : json({ error: "not_found" }, 404);
    }
  } else if (action === "redeem") {
    if (request.method === "POST") {
      const response = await readCappedBody(request, INVITE_MAX_BYTES);
      if (response === "too_large") return json({ error: "too_large" }, 413);
      const result = await slot.redeem(response);
      if (result === "missing") return json({ error: "not_found" }, 404);
      if (result === "taken") return json({ error: "already_redeemed" }, 409);
      return json({ ok: true });
    }
    if (request.method === "GET") {
      const response = await slot.response();
      return response
        ? bytes(response)
        : new Response(null, {
            status: 204,
            headers: { "cache-control": "no-store" },
          });
    }
  }

  return json({ error: "method_not_allowed" }, 405);
}

/** Routes one feed's requests to its Durable Object. */
async function handleFeed(
  request: Request,
  env: Env,
  id: string,
  action: string | undefined,
  url: URL,
): Promise<Response> {
  const feed = env.FEED.get(env.FEED.idFromName(id));

  if (action === undefined) {
    if (request.method === "PUT") {
      // Ed25519 public keys are exactly 32 bytes. Reject an oversized body by its
      // declared length *before* buffering it, so a bogus PUT can't make us read
      // an arbitrary amount into memory; then enforce the exact length after.
      const declared = Number(request.headers.get("content-length"));
      if (Number.isFinite(declared) && declared > 32) {
        return json({ error: "bad_key" }, 400);
      }
      const authorKey = new Uint8Array(await request.arrayBuffer());
      // reject anything that isn't exactly 32 bytes so a malformed key can never
      // be pinned and brick the feed's verification.
      if (authorKey.length !== 32) {
        return json({ error: "bad_key" }, 400);
      }
      const created = await feed.create(authorKey);
      return created
        ? json({ ok: true }, 201)
        : json({ error: "already_exists" }, 409);
    }
    if (request.method === "GET") {
      // `since` is a query param: clamp a negative value to 0, but reject a
      // present-yet-unparseable one rather than silently treating it as 0.
      const raw = url.searchParams.get("since");
      let since = 0;
      if (raw !== null) {
        const n = Number(raw);
        if (!Number.isFinite(n)) return json({ error: "bad_since" }, 400);
        since = Math.max(0, Math.trunc(n));
      }
      const entries = await feed.since(since);
      return json({
        entries: entries.map((e) => ({
          seq: e.seq,
          sig: toB64(e.sig),
          ct: toB64(e.ct),
        })),
      });
    }
  } else if (action === "entry" && request.method === "POST") {
    const body = await readCappedJson(request, FEED_JSON_MAX_BYTES);
    if (body === "too_large") return json({ error: "too_large" }, 413);
    if (
      typeof body !== "object" ||
      body === null ||
      !isFeedIndex((body as { seq?: unknown }).seq) ||
      typeof (body as { sig?: unknown }).sig !== "string" ||
      typeof (body as { ct?: unknown }).ct !== "string"
    ) {
      return json({ error: "bad_request" }, 400);
    }
    const { seq, sig, ct } = body as { seq: number; sig: string; ct: string };
    const sigBytes = tryFromB64(sig);
    const ctBytes = tryFromB64(ct);
    if (!sigBytes || !ctBytes) return json({ error: "bad_request" }, 400);
    const result = await feed.append(seq, sigBytes, ctBytes);
    if (result === "missing") return json({ error: "not_found" }, 404);
    if (result === "bad_signature") return json({ error: "bad_signature" }, 401);
    if (result === "stale") return json({ error: "stale_seq" }, 409);
    if (result === "duplicate") return json({ error: "duplicate_seq" }, 409);
    return json({ ok: true }, 201);
  } else if (action === "ack" && request.method === "POST") {
    const body = await readCappedJson(request, FEED_JSON_MAX_BYTES);
    if (body === "too_large") return json({ error: "too_large" }, 413);
    if (
      typeof body !== "object" ||
      body === null ||
      !isFeedIndex((body as { upTo?: unknown }).upTo)
    ) {
      return json({ error: "bad_request" }, 400);
    }
    const deleted = await feed.ack((body as { upTo: number }).upTo);
    if (deleted === "missing") return json({ error: "not_found" }, 404);
    return json({ deleted });
  }

  return json({ error: "method_not_allowed" }, 405);
}

/** Stores / serves / destroys an opaque, end-to-end-encrypted media blob in R2. */
async function handleMedia(
  request: Request,
  env: Env,
  id: string,
): Promise<Response> {
  const bucket = env.MEDIA;
  if (bucket === undefined) {
    return json({ error: "media_unconfigured" }, 503);
  }
  if (request.method === "PUT") {
    if (!request.body) return json({ error: "empty_body" }, 400);
    // Write-once: a media id authorizes *reading* a blob, so an unconditional
    // PUT would let anyone holding the id overwrite (vandalize) the author's
    // ciphertext. `etagDoesNotMatch: "*"` puts only if no object exists; R2
    // returns null when that precondition fails → the id is already taken.
    const stored = await bucket.put(id, request.body, {
      onlyIf: { etagDoesNotMatch: "*" },
    });
    return stored
      ? json({ ok: true }, 201)
      : json({ error: "already_exists" }, 409);
  }
  if (request.method === "GET") {
    const object = await bucket.get(id);
    if (!object) return json({ error: "not_found" }, 404);
    return new Response(object.body, {
      headers: {
        "content-type": "application/octet-stream",
        "content-length": String(object.size),
        // The blob is opaque ciphertext, but it's per-request and ephemeral —
        // never let an intermediary cache a delivered E2EE payload.
        "cache-control": "no-store",
      },
    });
  }
  if (request.method === "DELETE") {
    await bucket.delete(id);
    return new Response(null, {
      status: 204,
      headers: { "cache-control": "no-store" },
    });
  }
  return json({ error: "method_not_allowed" }, 405);
}
