import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const base = "https://relay";

describe("media", () => {
  it("stores, serves, and destroys an opaque blob", async () => {
    const blob = new Uint8Array([1, 2, 3, 4, 5]);

    const put = await SELF.fetch(`${base}/media/m1`, {
      method: "PUT",
      body: blob,
    });
    expect(put.status).toBe(201);

    const get = await SELF.fetch(`${base}/media/m1`);
    expect(get.status).toBe(200);
    expect(get.headers.get("cache-control")).toBe("no-store");
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(blob);

    const del = await SELF.fetch(`${base}/media/m1`, { method: "DELETE" });
    expect(del.status).toBe(204);
    expect(del.headers.get("cache-control")).toBe("no-store");

    const gone = await SELF.fetch(`${base}/media/m1`);
    expect(gone.status).toBe(404);
  });

  it("404s an unknown blob", async () => {
    expect((await SELF.fetch(`${base}/media/missing`)).status).toBe(404);
  });

  it("is write-once: a second PUT to the same id is rejected, original kept", async () => {
    const first = new Uint8Array([1, 2, 3]);
    const put = await SELF.fetch(`${base}/media/once`, {
      method: "PUT",
      body: first,
    });
    expect(put.status).toBe(201);

    // A different uploader (only needs the id) tries to overwrite the blob.
    const attacker = new Uint8Array([9, 9, 9, 9]);
    const overwrite = await SELF.fetch(`${base}/media/once`, {
      method: "PUT",
      body: attacker,
    });
    expect(overwrite.status).toBe(409);
    expect(((await overwrite.json()) as { error: string }).error).toBe(
      "already_exists",
    );

    // The original ciphertext must be untouched.
    const get = await SELF.fetch(`${base}/media/once`);
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(first);
  });

  it("dynamic responses are no-store (404 and the delivered blob)", async () => {
    const missing = await SELF.fetch(`${base}/media/missing`); // 404 JSON
    expect(missing.headers.get("cache-control")).toBe("no-store");

    await SELF.fetch(`${base}/media/cacheproof`, {
      method: "PUT",
      body: new Uint8Array([7, 7, 7]),
    });
    const get = await SELF.fetch(`${base}/media/cacheproof`);
    expect(get.status).toBe(200);
    // The actual E2EE payload response must also be uncacheable.
    expect(get.headers.get("cache-control")).toBe("no-store");
  });
});
