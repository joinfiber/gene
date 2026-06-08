/** Small response helpers — the relay's only "framework." */

// Every dynamic API response is per-request and ephemeral (a poll, a feed page,
// a sealed blob) — never cache it at the browser or any intermediary. The static
// landing page sets its own caching headers and does not go through these.
const NO_STORE = "no-store";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": NO_STORE },
  });
}

export function bytes(body: ArrayBuffer, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "application/octet-stream",
      "cache-control": NO_STORE,
    },
  });
}
