// FALLBACK WORKER — the "never show a raw Cloudflare error" safety net for tunnel-backed hosts.
// Sits on your dynamic hostnames (api.example.com, app.example.com, ...) and:
//   1. Passes every request straight through while your origin is healthy (zero overhead you can see).
//   2. Snapshots healthy ANONYMOUS html pages into the edge cache (a privacy-safe "last good copy").
//   3. On an outage (tunnel down = Cloudflare 521/522/523/530, or fetch throw), serves the visitor
//      their last-good page — bannered, auto-reloading — before falling to the maintenance page.
//   4. API callers (/api/*) get an honest JSON 503 with Retry-After instead of an HTML error page.
//   5. WebSocket upgrades pass through UNTOUCHED (wrapping an upgrade kills it).
//
// Configure SERVICE below, deploy with `wrangler deploy`, and list every hostname you want covered
// in wrangler.toml routes. A HOST NOT LISTED THERE GETS CLOUDFLARE'S RAW ERROR PAGE when your
// tunnel is down — when you add a public hostname to the tunnel, add it to the routes too.

const SERVICE = {
  name: "My Service",                     // shown on the maintenance page + JSON errors
  accent: "#5ad1ff",                      // maintenance page accent color
  staticFallback: "https://example.github.io",  // your always-up static site (GitHub Pages)
};

const REQUEST_TIMEOUT_MS = 30000;
const SNAPSHOT_TTL_S = 7 * 24 * 3600;

function snapshotKey(url) {
  return new Request("https://" + url.hostname + url.pathname, { method: "GET" });
}

function snapshotStorable(request, response) {
  if (request.method !== "GET") return false;
  if (request.headers.get("cookie") || request.headers.get("authorization")) return false;
  if (!response || response.status !== 200) return false;
  if (response.headers.get("set-cookie")) return false;
  const cc = (response.headers.get("cache-control") || "").toLowerCase();
  if (cc.includes("private") || cc.includes("no-store")) return false;
  return (response.headers.get("content-type") || "").includes("text/html");
}

const BANNER =
  '<div style="position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#eee;' +
  'font:13px/1.5 system-ui,sans-serif;text-align:center;padding:8px 14px;">' +
  "⚡ Live service is briefly unreachable — this is the last good copy of this page. It reconnects automatically.</div>" +
  '<script>setInterval(function(){fetch(location.href,{method:"HEAD",cache:"no-store"})' +
  '.then(function(r){if(r.ok&&!r.headers.get("x-stale"))location.reload()}).catch(function(){})},30000)</script>';

async function serveSnapshot(request, url) {
  if (request.method !== "GET") return null;
  if (request.headers.get("cookie") || request.headers.get("authorization")) return null;
  let hit = null;
  try { hit = await caches.default.match(snapshotKey(url)); } catch (_) { return null; }
  if (!hit) return null;
  const out = new Response(hit.body, hit);
  out.headers.set("Cache-Control", "no-store");
  out.headers.set("x-stale", "1");
  out.headers.set("Retry-After", "120");
  try {
    return new HTMLRewriter().on("body", { element(el) { el.prepend(BANNER, { html: true }); } }).transform(out);
  } catch (_) { return out; }
}

function maintenancePage(hostname) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${SERVICE.name} — be right back</title>
<style>html,body{margin:0;height:100%;background:#0b0b12;color:#dfe3ea;font-family:system-ui,sans-serif}
.wrap{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;text-align:center;padding:24px}
h1{font-size:28px;margin:0 0 8px}h1 b{color:${SERVICE.accent}}p{max-width:520px;opacity:.8;line-height:1.6}
a{color:${SERVICE.accent}}</style></head><body><div class="wrap">
<h1><b>${SERVICE.name}</b> is catching its breath</h1>
<p>${hostname} is briefly offline. This page will reconnect automatically the moment it's back.</p>
<p><a href="${SERVICE.staticFallback}">Our static site stays up here →</a></p></div>
<script>setInterval(function(){fetch(location.href,{method:"HEAD",cache:"no-store"})
.then(function(r){if(r.ok)location.reload()}).catch(function(){})},20000)</script></body></html>`;
}

function fallbackResponse(request, url) {
  if (url.pathname.startsWith("/api/")) {
    return new Response(JSON.stringify({
      error: "Service Unavailable", service: SERVICE.name, host: url.hostname,
      message: `${SERVICE.name} is temporarily offline and restarting. Retry shortly.`,
      static_site: SERVICE.staticFallback,
    }), { status: 503, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "Retry-After": "120" } });
  }
  const accept = request.headers.get("accept") || "";
  if (request.method === "GET" && accept.includes("text/html")) {
    return new Response(maintenancePage(url.hostname), {
      status: 503, headers: { "Content-Type": "text/html;charset=UTF-8", "Cache-Control": "no-store", "Retry-After": "120" } });
  }
  return new Response("Origin unavailable", { status: 503, headers: { "Cache-Control": "no-store", "Retry-After": "120" } });
}

async function staleOrFallback(request, url) {
  const snap = await serveSnapshot(request, url);
  return snap || fallbackResponse(request, url);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // WebSockets: hand straight to the origin, untouched.
    if ((request.headers.get("upgrade") || "").toLowerCase() === "websocket") return fetch(request);

    try {
      const controller = new AbortController();
      const t = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
      const response = await fetch(request, { signal: controller.signal });
      clearTimeout(t);

      // 521/522/523/530 only ever come from Cloudflare when the tunnel/origin is dead.
      if ([521, 522, 523, 530].includes(response.status)) return staleOrFallback(request, url);

      // Healthy anonymous HTML → refresh the last-good snapshot.
      if (snapshotStorable(request, response)) {
        try {
          const copy = new Response(response.clone().body, response);
          copy.headers.set("Cache-Control", "s-maxage=" + SNAPSHOT_TTL_S);
          copy.headers.delete("set-cookie");
          ctx.waitUntil(caches.default.put(snapshotKey(url), copy));
        } catch (_) { /* never break the live path */ }
      }
      return response;
    } catch (_) {
      return staleOrFallback(request, url);
    }
  },
};
