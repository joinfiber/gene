import { DurableObject } from "cloudflare:workers";

import { signedMessage } from "./codec";
import { verifyEd25519 } from "./crypto";

const ENTRY_PREFIX = "entry:";
// 16 digits holds Number.MAX_SAFE_INTEGER (9007199254740991), so seq keys sort
// lexicographically in the same order as numerically across the whole range.
const entryKey = (seq: number): string =>
  ENTRY_PREFIX + String(seq).padStart(16, "0");
const seqOf = (key: string): number => Number(key.slice(ENTRY_PREFIX.length));

// storage.list() caps at 1000 keys per call; a busy feed can exceed that, which
// would silently truncate reads, stall acks, and leave the queue undrained. Page
// through with this so every operation sees the whole range.
const PAGE = 1000;

// storage.delete([...]) takes at most 128 keys per call; chunk to stay under it.
const DELETE_CHUNK = 128;

interface StoredEntry {
  sig: Uint8Array;
  ct: Uint8Array;
  at: number;
}

export interface FeedEntry {
  seq: number;
  sig: Uint8Array;
  ct: Uint8Array;
}

export type AppendResult =
  | "ok"
  | "missing"
  | "bad_signature"
  | "duplicate"
  | "stale";

/**
 * One direction of a conversation: an append-only feed with a single author
 * (BACKEND.md §3).
 *
 *  - **Read** is a capability — holding the unguessable feed id (by which the
 *    Worker addresses this object) authorizes reading.
 *  - **Write** is a signature — the author's per-feed Ed25519 public key is
 *    pinned at creation, and every entry must carry a signature over
 *    `seq || ciphertext` that verifies against it. So even a leaked feed id
 *    cannot forge entries. It is a *per-feed* key, never the identity key, so
 *    the relay can't link an author's separate feeds (BACKEND.md §5).
 *
 * Entry ciphertext is sealed end-to-end; the relay never sees plaintext.
 * Delivered entries are destroyed on ack.
 */
export class FeedSlot extends DurableObject {
  /** Undelivered entries expire after this long, so an offline recipient's
   *  queue can't grow without bound; ack remains the prompt path. */
  private static readonly entryTtlMs = 30 * 24 * 60 * 60 * 1000; // 30 days
  private static readonly sweepIntervalMs = 24 * 60 * 60 * 1000; // daily

  /** Pin the author's per-feed public key. Rejects a re-bind. */
  async create(authorPublicKey: Uint8Array): Promise<boolean> {
    if (await this.ctx.storage.get("authorPublicKey")) return false;
    await this.ctx.storage.put("authorPublicKey", authorPublicKey);
    return true;
  }

  /**
   * Append a signed entry, verifying it against the pinned author key.
   *
   * `seq` must advance past the acked watermark: a captured, validly-signed
   * entry whose seq was already delivered-and-acked must not be replayable, and
   * an acked seq must never reappear. Such an append returns `"stale"`. A
   * still-pending seq that is re-sent returns `"duplicate"`.
   */
  async append(
    seq: number,
    sig: Uint8Array,
    ct: Uint8Array,
  ): Promise<AppendResult> {
    const authorPublicKey =
      await this.ctx.storage.get<Uint8Array>("authorPublicKey");
    if (!authorPublicKey) return "missing";
    if (!(await verifyEd25519(authorPublicKey, sig, signedMessage(seq, ct)))) {
      return "bad_signature";
    }
    if (seq <= (await this.ackedUpTo())) return "stale";
    const key = entryKey(seq);
    if (await this.ctx.storage.get(key)) return "duplicate";
    await this.ctx.storage.put(
      key,
      { sig, ct, at: Date.now() } satisfies StoredEntry,
    );
    // Keep a TTL sweep pending while anything is undelivered. Idempotent, so an
    // append racing the alarm can't leave the queue with no scheduled sweep.
    await this.ensureAlarm();
    return "ok";
  }

  /** Entries with `seq` greater than [since], in order. */
  async since(since: number): Promise<FeedEntry[]> {
    const entries: FeedEntry[] = [];
    // Range-bounded: start just past `since` instead of scanning from zero.
    for await (const [key, value] of this.pages<StoredEntry>(
      entryKey(since + 1),
    )) {
      entries.push({ seq: seqOf(key), sig: value.sig, ct: value.ct });
    }
    return entries;
  }

  /**
   * Destroy delivered entries (`seq` ≤ [upTo]); returns how many were removed,
   * or `"missing"` if the feed was never created (symmetry with `append`).
   *
   * Advances the acked watermark so those seqs can't be replayed — but **clamps
   * it to the highest seq that actually existed at/below [upTo]**, never to the
   * raw [upTo]. A read-capability holder could otherwise ack an arbitrary future
   * seq (e.g. MAX_SAFE_INTEGER) and permanently brick the author, whose every
   * later append would then be rejected `stale`. An honest reader only ever acks
   * ≤ what it received, so the clamp is invisible to it.
   */
  async ack(upTo: number): Promise<number | "missing"> {
    if (!(await this.ctx.storage.get("authorPublicKey"))) return "missing";
    const end = entryKey(upTo); // inclusive upper bound (lexicographic == numeric)
    const keys: string[] = [];
    let highestAcked = await this.ackedUpTo();
    for await (const [key] of this.pages(ENTRY_PREFIX, end + "\0")) {
      // `end + "\0"` makes the exclusive `end` bound include `end` itself.
      keys.push(key);
      highestAcked = Math.max(highestAcked, seqOf(key));
    }
    const deleted = await this.deleteKeys(keys);
    if (highestAcked > (await this.ackedUpTo())) {
      await this.ctx.storage.put("ackedUpTo", highestAcked);
    }
    return deleted;
  }

  /**
   * Backstop sweep: drop entries older than the TTL and reschedule while any
   * remain. Ack is the prompt destroy-after-delivery path; this only catches
   * entries a recipient never collected.
   */
  override async alarm(): Promise<void> {
    const now = Date.now();
    const expired: string[] = [];
    let remaining = 0;
    for await (const [key, entry] of this.pages<StoredEntry>(ENTRY_PREFIX)) {
      if (now - entry.at > FeedSlot.entryTtlMs) expired.push(key);
      else remaining++;
    }
    await this.deleteKeys(expired);
    // Re-check after deletes; only reschedule if something is still pending, and
    // do it idempotently so we never clobber or drop a concurrently-set alarm.
    if (remaining > 0) await this.ensureAlarm();
  }

  /** The highest acked seq; `-1` before the first ack (so seq 0 is valid). */
  private async ackedUpTo(): Promise<number> {
    return (await this.ctx.storage.get<number>("ackedUpTo")) ?? -1;
  }

  /** Delete keys in batches (storage.delete caps at 128/call); returns the
   *  total removed. One round-trip per chunk instead of one per key. */
  private async deleteKeys(keys: string[]): Promise<number> {
    let deleted = 0;
    for (let i = 0; i < keys.length; i += DELETE_CHUNK) {
      deleted += await this.ctx.storage.delete(keys.slice(i, i + DELETE_CHUNK));
    }
    return deleted;
  }

  /** Schedule a TTL sweep iff none is pending. Idempotent. */
  private async ensureAlarm(): Promise<void> {
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + FeedSlot.sweepIntervalMs);
    }
  }

  /**
   * Iterate every entry in `[start, end)` a page at a time, so a feed larger
   * than the 1000-key list cap is fully covered. Advances `start` past the last
   * key each round and stops on a short page.
   */
  private async *pages<T = unknown>(
    start: string,
    end?: string,
  ): AsyncGenerator<[string, T]> {
    let cursor = start;
    for (;;) {
      const page = await this.ctx.storage.list<T>({
        start: cursor,
        end,
        prefix: ENTRY_PREFIX,
        limit: PAGE,
      });
      let last: string | undefined;
      for (const pair of page) {
        yield pair;
        last = pair[0];
      }
      if (page.size < PAGE || last === undefined) return;
      cursor = last + "\0"; // resume strictly after the last key seen
    }
  }
}
