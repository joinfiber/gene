import { DurableObject } from "cloudflare:workers";

/**
 * A single-use pairing rendezvous (BACKEND.md §2).
 *
 * The relay is zero-knowledge: this slot only ever holds two opaque blobs —
 * the inviter's sealed payload and the redeemer's sealed response — neither of
 * which it can open (the link secret `S` lives in the URL fragment and never
 * reaches the server).
 *
 * Single-use must be atomic: if two parties race to redeem, exactly one wins
 * and the other must fail visibly. A Durable Object runs single-threaded and
 * input-gates concurrent requests around storage, so the redeem is a trivially
 * correct compare-and-set with no locks. The slot self-destructs after [ttlMs],
 * bounding both the interception window and storage.
 */
export class InviteSlot extends DurableObject {
  private static readonly ttlMs = 7 * 24 * 60 * 60 * 1000; // 7 days

  /** Inviter creates the slot. Returns `false` on a collision rather than
   *  overwriting an existing slot. */
  async create(payload: ArrayBuffer): Promise<boolean> {
    if (await this.ctx.storage.get("payload")) return false;
    await this.ctx.storage.put("payload", payload);
    await this.ctx.storage.setAlarm(Date.now() + InviteSlot.ttlMs);
    return true;
  }

  /** Redeemer fetches the inviter's sealed payload; does not consume the slot. */
  async payload(): Promise<ArrayBuffer | null> {
    return (await this.ctx.storage.get<ArrayBuffer>("payload")) ?? null;
  }

  /**
   * Redeemer claims the slot:
   *  - `"ok"` to the first caller;
   *  - `"taken"` to every caller after — so an attacker's later redemption is
   *    detectable (the real peer's redeem fails) rather than silent;
   *  - `"missing"` if no such slot exists.
   *
   * Single-use correctness rests entirely on the Durable Object input gate:
   * concurrent requests to one object are serialized around storage I/O, so this
   * read-then-write is an atomic compare-and-set with no lock. Do NOT "optimize"
   * any redeem-path handler with `allowConcurrency: true` — it lifts the gate and
   * lets two racing redemptions both observe an unredeemed slot and both win,
   * defeating single-use (and the detectability that protects against MITM).
   */
  async redeem(response: ArrayBuffer): Promise<"ok" | "taken" | "missing"> {
    if (!(await this.ctx.storage.get("payload"))) return "missing";
    if (await this.ctx.storage.get<boolean>("redeemed")) return "taken";
    await this.ctx.storage.put("redeemed", true);
    await this.ctx.storage.put("response", response);
    return "ok";
  }

  /** Inviter polls for the redeemer's sealed response. */
  async response(): Promise<ArrayBuffer | null> {
    return (await this.ctx.storage.get<ArrayBuffer>("response")) ?? null;
  }

  /** TTL elapsed — erase everything. */
  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
