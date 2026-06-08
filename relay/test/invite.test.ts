import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const base = "https://relay";

function u8(...bytes: number[]): Uint8Array {
  return new Uint8Array(bytes);
}

describe("pairing rendezvous", () => {
  it("stores and returns the inviter's sealed payload", async () => {
    const payload = u8(1, 2, 3, 4);
    const put = await SELF.fetch(`${base}/invite/alpha`, {
      method: "PUT",
      body: payload,
    });
    expect(put.status).toBe(201);

    const get = await SELF.fetch(`${base}/invite/alpha`);
    expect(get.status).toBe(200);
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(payload);
  });

  it("rejects a colliding invite id rather than overwriting", async () => {
    await SELF.fetch(`${base}/invite/beta`, { method: "PUT", body: u8(1) });
    const dup = await SELF.fetch(`${base}/invite/beta`, {
      method: "PUT",
      body: u8(2),
    });
    expect(dup.status).toBe(409);
  });

  it("redeems exactly once — a second redemption fails visibly", async () => {
    await SELF.fetch(`${base}/invite/gamma`, { method: "PUT", body: u8(1) });

    const first = await SELF.fetch(`${base}/invite/gamma/redeem`, {
      method: "POST",
      body: u8(7),
    });
    expect(first.status).toBe(200);

    const second = await SELF.fetch(`${base}/invite/gamma/redeem`, {
      method: "POST",
      body: u8(8),
    });
    expect(second.status).toBe(409);
  });

  it("delivers the redeemer's sealed response back to the inviter", async () => {
    await SELF.fetch(`${base}/invite/delta`, { method: "PUT", body: u8(1) });

    const before = await SELF.fetch(`${base}/invite/delta/redeem`);
    expect(before.status).toBe(204); // nothing redeemed yet

    const response = u8(5, 6, 7, 8);
    await SELF.fetch(`${base}/invite/delta/redeem`, {
      method: "POST",
      body: response,
    });

    const after = await SELF.fetch(`${base}/invite/delta/redeem`);
    expect(after.status).toBe(200);
    expect(new Uint8Array(await after.arrayBuffer())).toEqual(response);
  });

  it("404s an unknown invite and rejects redeeming one", async () => {
    expect((await SELF.fetch(`${base}/invite/ghost`)).status).toBe(404);
    const redeem = await SELF.fetch(`${base}/invite/ghost/redeem`, {
      method: "POST",
      body: u8(0),
    });
    expect(redeem.status).toBe(404);
  });

  it("rejects an oversized invite payload with 413", async () => {
    const tooBig = new Uint8Array(8 * 1024 + 1); // just over the 8 KB cap
    const put = await SELF.fetch(`${base}/invite/huge`, {
      method: "PUT",
      body: tooBig,
    });
    expect(put.status).toBe(413);
    expect(((await put.json()) as { error: string }).error).toBe("too_large");
  });

  it("dynamic responses are no-store", async () => {
    const put = await SELF.fetch(`${base}/invite/nostore`, {
      method: "PUT",
      body: u8(1),
    });
    expect(put.headers.get("cache-control")).toBe("no-store");

    const get = await SELF.fetch(`${base}/invite/nostore`); // bytes() path
    expect(get.headers.get("cache-control")).toBe("no-store");
  });
});
