import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests run inside the real workerd runtime (via Miniflare), so Durable Object
// semantics — single-threaded execution, storage, alarms — are exercised for
// real rather than mocked.
export default defineConfig({
  plugins: [
    cloudflareTest({
      // Bindings (incl. the MEDIA R2 bucket) come from wrangler.jsonc, so the
      // test runtime mirrors the real deploy — no separate Miniflare overrides.
      wrangler: { configPath: "./wrangler.jsonc" },
    }),
  ],
});
