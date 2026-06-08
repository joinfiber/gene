/**
 * The page a shared invite link opens to (`…/i/:id#secret`).
 *
 * The secret lives in the URL fragment, which a browser never sends to the
 * server — so rendering this page reveals nothing to the relay. The browser
 * keeps the full URL, and the copy button hands the recipient the *complete*
 * link (fragment included) to paste into the app.
 */
const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>gene · you've been invited</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100dvh; display: grid; place-items: center;
    background: #000; color: #fff; padding: 24px;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  main { width: 100%; max-width: 460px; }
  .wordmark { font-size: 15px; letter-spacing: .35em; text-transform: uppercase; color: #64ffda; margin: 0 0 28px; }
  h1 { font-size: 28px; font-weight: 600; margin: 0 0 12px; }
  p { color: rgba(255,255,255,.7); margin: 0 0 16px; }
  ol { color: rgba(255,255,255,.7); padding-left: 20px; margin: 0 0 24px; }
  li { margin: 6px 0; }
  b { color: #fff; font-weight: 600; }
  button {
    width: 100%; padding: 14px; border: 0; border-radius: 12px;
    background: #64ffda; color: #00120c; font-size: 16px; font-weight: 700; cursor: pointer;
  }
  button:active { opacity: .85; }
  .link {
    display: none; margin-top: 16px; padding: 12px; border-radius: 10px;
    background: rgba(255,255,255,.06); font-family: ui-monospace, monospace;
    font-size: 12px; word-break: break-all; color: rgba(255,255,255,.55);
  }
  .hint { font-size: 13px; color: rgba(255,255,255,.45); margin-top: 14px; text-align: center; }
</style>
</head>
<body>
  <main>
    <p class="wordmark">gene</p>
    <h1>You've been invited.</h1>
    <p>gene is for slow, high-quality video missives — one friend at a time. Someone made this single-use link to connect with you.</p>
    <ol>
      <li>Tap <b>Copy link</b> below.</li>
      <li>Open the <b>gene</b> app → <b>Connect</b> → <b>I have a link</b>.</li>
      <li><b>Paste</b> it, and you're connected.</li>
    </ol>
    <button id="copy">Copy link</button>
    <div class="link" id="link"></div>
    <p class="hint">The link works once, and only the two of you can read what you send.</p>
  </main>
  <script>
    var url = location.href;
    var btn = document.getElementById('copy');
    var box = document.getElementById('link');
    function reveal() { box.textContent = url; box.style.display = 'block'; }
    btn.addEventListener('click', function () {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(url).then(function () {
          btn.textContent = 'Copied ✓'; reveal();
          setTimeout(function () { btn.textContent = 'Copy link'; }, 2000);
        }).catch(function () { reveal(); btn.textContent = 'Copy it manually ↑'; });
      } else {
        reveal(); btn.textContent = 'Copy it manually ↑';
      }
    });
  </script>
</body>
</html>`;

// A stable ETag for this static page. Derived once from the markup with a tiny
// FNV-1a hash so it changes iff `HTML` does — no manual version bumping. The page
// is immutable per deploy, so a long max-age + a validator is safe and lets a
// returning recipient skip the re-download.
const ETAG = `"${fnv1a(HTML)}"`;

// Strict CSP for a self-contained page: only the one inline <script>/<style> are
// permitted; no network origins, no framing/forms, no base-tag hijack. Nothing
// here is dynamic or per-invite (the secret lives in the never-sent #fragment),
// so this is purely belt-and-suspenders hardening.
const HEADERS: Record<string, string> = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "public, max-age=86400, immutable",
  etag: ETAG,
  "content-security-policy":
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
  "referrer-policy": "no-referrer",
};

export function landingPage(): Response {
  return new Response(HTML, { headers: HEADERS });
}

/** FNV-1a (32-bit), hex — a stable, dependency-free content fingerprint. */
function fnv1a(text: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
