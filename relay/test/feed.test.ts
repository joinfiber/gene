import { SELF, env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { fromB64, signedMessage, toB64 } from "../src/codec";
import type { FeedSlot } from "../src/feed_slot";
import type { Env } from "../src/index";

// The deprecated `env` export is typed `Cloudflare.Env`; this project's bindings
// live on `Env` (see test/env.d.ts), so view it through that for the FEED stub.
const feeds = (env as unknown as Env).FEED;

const base = "https://relay";

/** A feed author: an Ed25519 keypair plus a signer for the wire format. */
async function makeAuthor() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const publicKey = new Uint8Array(
    (await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer,
  );
  const sign = async (seq: number, ct: Uint8Array): Promise<Uint8Array> =>
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "Ed25519" },
        pair.privateKey,
        signedMessage(seq, ct),
      ),
    );
  return { publicKey, sign };
}

interface ReadBody {
  entries: { seq: number; sig: string; ct: string }[];
}

describe("feeds", () => {
  it("pins the author key and rejects a colliding feed id", async () => {
    const { publicKey } = await makeAuthor();
    const put = await SELF.fetch(`${base}/feed/f1`, {
      method: "PUT",
      body: publicKey,
    });
    expect(put.status).toBe(201);

    const dup = await SELF.fetch(`${base}/feed/f1`, {
      method: "PUT",
      body: publicKey,
    });
    expect(dup.status).toBe(409);
  });

  it("accepts a correctly-signed entry and serves it to a reader", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/f2`, { method: "PUT", body: publicKey });

    const ct = new Uint8Array([10, 20, 30]);
    const post = await SELF.fetch(`${base}/feed/f2/entry`, {
      method: "POST",
      body: JSON.stringify({ seq: 1, sig: toB64(await sign(1, ct)), ct: toB64(ct) }),
    });
    expect(post.status).toBe(201);

    const read = await SELF.fetch(`${base}/feed/f2?since=0`);
    const body = (await read.json()) as ReadBody;
    expect(body.entries).toHaveLength(1);
    expect(body.entries[0]!.seq).toBe(1);
    expect(fromB64(body.entries[0]!.ct)).toEqual(ct);
  });

  it("rejects an entry whose signature doesn't verify", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/f3`, { method: "PUT", body: publicKey });

    const ct = new Uint8Array([1, 2, 3]);
    const sig = await sign(1, ct); // valid signature over the real ct...
    const tampered = new Uint8Array([9, 9, 9]); // ...but a different ct is sent
    const post = await SELF.fetch(`${base}/feed/f3/entry`, {
      method: "POST",
      body: JSON.stringify({ seq: 1, sig: toB64(sig), ct: toB64(tampered) }),
    });
    expect(post.status).toBe(401);
  });

  it("destroys delivered entries on ack", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/f4`, { method: "PUT", body: publicKey });

    for (const seq of [1, 2, 3]) {
      const ct = new Uint8Array([seq]);
      await SELF.fetch(`${base}/feed/f4/entry`, {
        method: "POST",
        body: JSON.stringify({
          seq,
          sig: toB64(await sign(seq, ct)),
          ct: toB64(ct),
        }),
      });
    }
    expect(
      ((await (await SELF.fetch(`${base}/feed/f4?since=0`)).json()) as ReadBody)
        .entries,
    ).toHaveLength(3);

    const acked = await SELF.fetch(`${base}/feed/f4/ack`, {
      method: "POST",
      body: JSON.stringify({ upTo: 2 }),
    });
    expect(((await acked.json()) as { deleted: number }).deleted).toBe(2);

    const remaining = (
      (await (await SELF.fetch(`${base}/feed/f4?since=0`)).json()) as ReadBody
    ).entries;
    expect(remaining).toHaveLength(1);
    expect(remaining[0]!.seq).toBe(3);
  });

  it("404s an append to a feed that was never created", async () => {
    const post = await SELF.fetch(`${base}/feed/ghost/entry`, {
      method: "POST",
      body: JSON.stringify({
        seq: 1,
        sig: toB64(new Uint8Array(64)),
        ct: toB64(new Uint8Array([1])),
      }),
    });
    expect(post.status).toBe(404);
  });

  it("reads and acks past the old 1000-key list window", async () => {
    const { publicKey } = await makeAuthor();
    await SELF.fetch(`${base}/feed/big`, { method: "PUT", body: publicKey });

    // 1001 entries crosses the single storage.list() page (1000). Without
    // pagination the tail would vanish from reads and never drain on ack.
    // Driving 1001 signed appends over HTTP is needlessly slow, so seed storage
    // directly inside the DO, then exercise the real (paginating) since/ack.
    const total = 1001;
    const stub = feeds.get(feeds.idFromName("big"));
    await runInDurableObject(stub, async (_instance, state) => {
      const seed: Record<string, unknown> = {};
      for (let seq = 1; seq <= total; seq++) {
        // Mirror feed_slot's key scheme: "entry:" + 16-digit zero-padded seq.
        const key = "entry:" + String(seq).padStart(16, "0");
        seed[key] = { sig: new Uint8Array(64), ct: new Uint8Array([seq & 0xff]), at: Date.now() };
      }
      await state.storage.put(seed);
    });

    const all = await runInDurableObject(stub, (instance: FeedSlot) =>
      instance.since(0),
    );
    expect(all).toHaveLength(total);
    expect(all[total - 1]!.seq).toBe(total); // the entry past the old window

    const deleted = await runInDurableObject(stub, (instance: FeedSlot) =>
      instance.ack(total),
    );
    expect(deleted).toBe(total);

    const after = await runInDurableObject(stub, (instance: FeedSlot) =>
      instance.since(0),
    );
    expect(after).toHaveLength(0);
  });

  it("keeps a TTL sweep scheduled while entries remain (alarm robustness)", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/alarmed`, { method: "PUT", body: publicKey });

    const ct = new Uint8Array([1]);
    await SELF.fetch(`${base}/feed/alarmed/entry`, {
      method: "POST",
      body: JSON.stringify({ seq: 1, sig: toB64(await sign(1, ct)), ct: toB64(ct) }),
    });

    const stub = feeds.get(feeds.idFromName("alarmed"));
    // An undelivered entry must leave an alarm pending...
    const scheduled = await runInDurableObject(stub, (_i, state) =>
      state.storage.getAlarm(),
    );
    expect(scheduled).not.toBeNull();

    // ...and after the sweep runs with the (non-expired) entry still present,
    // a fresh alarm must be rescheduled rather than dropped.
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const rescheduled = await runInDurableObject(stub, (_i, state) =>
      state.storage.getAlarm(),
    );
    expect(rescheduled).not.toBeNull();
  });

  it("rejects a replayed/acked seq as stale (anti-replay)", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/replay`, { method: "PUT", body: publicKey });

    const ct = new Uint8Array([42]);
    const sig = toB64(await sign(1, ct)); // a genuine, captured signed entry
    const entry = JSON.stringify({ seq: 1, sig, ct: toB64(ct) });

    expect(
      (await SELF.fetch(`${base}/feed/replay/entry`, { method: "POST", body: entry }))
        .status,
    ).toBe(201);

    await SELF.fetch(`${base}/feed/replay/ack`, {
      method: "POST",
      body: JSON.stringify({ upTo: 1 }),
    });

    // Replaying the exact captured entry after ack must not re-deliver it.
    const replay = await SELF.fetch(`${base}/feed/replay/entry`, {
      method: "POST",
      body: entry,
    });
    expect(replay.status).toBe(409);
    expect(((await replay.json()) as { error: string }).error).toBe("stale_seq");
  });

  it("clamps the ack watermark so a reader can't brick the author", async () => {
    const { publicKey, sign } = await makeAuthor();
    await SELF.fetch(`${base}/feed/clamp`, { method: "PUT", body: publicKey });

    // Author appends seq 1; reader receives it.
    const ct1 = new Uint8Array([1]);
    expect(
      (
        await SELF.fetch(`${base}/feed/clamp/entry`, {
          method: "POST",
          body: JSON.stringify({ seq: 1, sig: toB64(await sign(1, ct1)), ct: toB64(ct1) }),
        })
      ).status,
    ).toBe(201);

    // A malicious reader acks far past anything stored, trying to push the
    // watermark to MAX_SAFE_INTEGER and reject every future append as stale.
    const ack = await SELF.fetch(`${base}/feed/clamp/ack`, {
      method: "POST",
      body: JSON.stringify({ upTo: Number.MAX_SAFE_INTEGER }),
    });
    expect(ack.status).toBe(200);
    // Only the single stored entry (seq 1) was actually destroyed.
    expect(((await ack.json()) as { deleted: number }).deleted).toBe(1);

    // The author's next legitimate append (seq 2) must still be accepted: the
    // watermark was clamped to the highest stored seq (1), not the raw upTo.
    const ct2 = new Uint8Array([2]);
    const next = await SELF.fetch(`${base}/feed/clamp/entry`, {
      method: "POST",
      body: JSON.stringify({ seq: 2, sig: toB64(await sign(2, ct2)), ct: toB64(ct2) }),
    });
    expect(next.status).toBe(201);

    // And it is readable by the (honest) reader.
    const read = (
      (await (await SELF.fetch(`${base}/feed/clamp?since=0`)).json()) as ReadBody
    ).entries;
    expect(read).toHaveLength(1);
    expect(read[0]!.seq).toBe(2);

    // The genuine anti-replay guarantee still holds: re-acking seq 2 then
    // replaying it is rejected stale.
    await SELF.fetch(`${base}/feed/clamp/ack`, {
      method: "POST",
      body: JSON.stringify({ upTo: 2 }),
    });
    const replay = await SELF.fetch(`${base}/feed/clamp/entry`, {
      method: "POST",
      body: JSON.stringify({ seq: 2, sig: toB64(await sign(2, ct2)), ct: toB64(ct2) }),
    });
    expect(replay.status).toBe(409);
    expect(((await replay.json()) as { error: string }).error).toBe("stale_seq");
  });

  it("rejects an oversized feed author key (before buffering) as bad_key", async () => {
    const put = await SELF.fetch(`${base}/feed/huge`, {
      method: "PUT",
      body: new Uint8Array(64), // far larger than a 32-byte key
    });
    expect(put.status).toBe(400);
    expect(((await put.json()) as { error: string }).error).toBe("bad_key");
  });

  it("treats a malformed author key as 400, not 500", async () => {
    const put = await SELF.fetch(`${base}/feed/badkey`, {
      method: "PUT",
      body: new Uint8Array(31), // not a 32-byte Ed25519 public key
    });
    expect(put.status).toBe(400);
  });

  it("yields bad_signature (not 500) when a pinned key is unusable", async () => {
    // A 32-byte key that is not a valid Ed25519 point: create succeeds (length
    // is right), but verify must fail closed rather than throw a 500.
    const bogus = new Uint8Array(32).fill(0xff);
    await SELF.fetch(`${base}/feed/bogus`, { method: "PUT", body: bogus });

    const ct = new Uint8Array([1, 2, 3]);
    const post = await SELF.fetch(`${base}/feed/bogus/entry`, {
      method: "POST",
      body: JSON.stringify({
        seq: 1,
        sig: toB64(new Uint8Array(64)),
        ct: toB64(ct),
      }),
    });
    expect(post.status).toBe(401);
    expect(((await post.json()) as { error: string }).error).toBe(
      "bad_signature",
    );
  });

  it("rejects invalid seq, since, and bodies with 400", async () => {
    const { publicKey } = await makeAuthor();
    await SELF.fetch(`${base}/feed/valid`, { method: "PUT", body: publicKey });

    const badEntry = async (body: unknown): Promise<number> =>
      (
        await SELF.fetch(`${base}/feed/valid/entry`, {
          method: "POST",
          body: JSON.stringify(body),
        })
      ).status;

    expect(await badEntry({ seq: -1, sig: "AA", ct: "AA" })).toBe(400);
    expect(await badEntry({ seq: 1.5, sig: "AA", ct: "AA" })).toBe(400);
    expect(
      await badEntry({ seq: Number.MAX_SAFE_INTEGER + 1, sig: "AA", ct: "AA" }),
    ).toBe(400);
    expect(await badEntry({ seq: 1, ct: "AA" })).toBe(400); // missing sig
    expect(await badEntry({ seq: 1, sig: 5, ct: "AA" })).toBe(400); // sig wrong type
    expect(await badEntry({ seq: 1, sig: "!!!!", ct: "AA" })).toBe(400); // sig not base64

    // ack body must carry a valid upTo
    expect(
      (
        await SELF.fetch(`${base}/feed/valid/ack`, {
          method: "POST",
          body: JSON.stringify({ upTo: -3 }),
        })
      ).status,
    ).toBe(400);

    // since must be parseable
    expect((await SELF.fetch(`${base}/feed/valid?since=abc`)).status).toBe(400);
  });

  it("404s an ack to a feed that was never created", async () => {
    const ack = await SELF.fetch(`${base}/feed/noack/ack`, {
      method: "POST",
      body: JSON.stringify({ upTo: 1 }),
    });
    expect(ack.status).toBe(404);
  });
});
