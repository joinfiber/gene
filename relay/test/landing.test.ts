import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const base = "https://relay";

describe("invite landing page", () => {
  it("serves an HTML page at /i/:id", async () => {
    const res = await SELF.fetch(`${base}/i/abc123`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const body = await res.text();
    expect(body).toContain("gene");
    expect(body).toContain("I have a link");
  });

  it("is zero-knowledge: the fragment secret never reaches the server", async () => {
    // A browser strips the #fragment before sending, so the relay can't see it
    // and the rendered page carries no per-invite secret.
    const res = await SELF.fetch(`${base}/i/abc123#supersecret`);
    expect(await res.text()).not.toContain("supersecret");
  });

  it("is GET-only (405 on other methods)", async () => {
    const res = await SELF.fetch(`${base}/i/abc123`, { method: "POST" });
    expect(res.status).toBe(405);
    expect(((await res.json()) as { error: string }).error).toBe(
      "method_not_allowed",
    );
  });

  it("is cacheable and hardened: long-lived cache, ETag, CSP, no-referrer", async () => {
    const res = await SELF.fetch(`${base}/i/abc123`);
    expect(res.headers.get("cache-control")).toBe(
      "public, max-age=86400, immutable",
    );
    expect(res.headers.get("etag")).toMatch(/^".+"$/);
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    const csp = res.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("base-uri 'none'");
    expect(csp).toContain("form-action 'none'");
  });
});
