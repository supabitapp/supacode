import { webcrypto } from "node:crypto";
import test from "node:test";
import assert from "node:assert/strict";
import worker from "./public/_worker.js";

if (!globalThis.crypto) {
  globalThis.crypto = webcrypto;
}

const text = new TextEncoder();
const releaseManifestUrl =
  "https://github.com/supabitapp/supacode/releases/download/v1.0.0/checksums.json";
const releaseDMGUrl =
  "https://github.com/supabitapp/supacode/releases/download/v1.0.0/supacode.dmg";
const latestAppcastUrl =
  "https://github.com/supabitapp/supacode/releases/latest/download/appcast.xml";

const sha256 = async (value) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", text.encode(value))))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");

const installCache = () => {
  const store = new Map();
  globalThis.caches = {
    default: {
      match: async (request) => store.get(request.url)?.clone(),
      put: async (request, response) => {
        store.set(request.url, response.clone());
      },
    },
  };
  return store;
};

const fetchWorker = (path, init) =>
  worker.fetch(new Request(`https://supacode.sh${path}`, init), {
    ASSETS: {
      fetch: () => new Response("asset"),
    },
  });

test("valid versioned download is cached after checksum validation", async () => {
  installCache();
  const body = "verified asset";
  const digest = await sha256(body);
  let fetchCount = 0;
  globalThis.fetch = async (url) => {
    fetchCount += 1;
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: digest, size: text.encode(body).byteLength },
        },
      });
    }
    assert.equal(url, releaseDMGUrl);
    return new Response(body);
  };

  const first = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("x-supacode-cache"), "validated");
  assert.equal(await first.text(), body);

  globalThis.fetch = async () => {
    throw new Error("cache hit should not fetch");
  };
  const second = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(second.status, 200);
  assert.equal(second.headers.get("x-supacode-cache"), "hit");
  assert.equal(await second.text(), body);
  assert.equal(fetchCount, 2);
});

test("stale raw cache entries are ignored", async () => {
  const store = installCache();
  store.set("https://supacode.sh/download/v1.0.0/supacode.dmg", new Response("poison"));
  const body = "verified asset";
  const digest = await sha256(body);
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: digest, size: text.encode(body).byteLength },
        },
      });
    }
    assert.equal(url, releaseDMGUrl);
    return new Response(body);
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-supacode-cache"), "validated");
  assert.equal(await response.text(), body);
  assert.equal(
    await store.get("https://supacode.sh/download/v1.0.0/supacode.dmg").clone().text(),
    "poison",
  );
  assert.equal(
    await store.get("https://supacode.sh/download/v1.0.0/supacode.dmg?__supacode_cache=2").text(),
    body,
  );
});

test("cache API failures do not block verified downloads", async () => {
  const body = "verified asset";
  const digest = await sha256(body);
  globalThis.caches = {
    default: {
      match: async () => {
        throw new Error("cache failed");
      },
      put: async () => {
        throw new Error("cache failed");
      },
    },
  };
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: digest, size: text.encode(body).byteLength },
        },
      });
    }
    assert.equal(url, releaseDMGUrl);
    return new Response(body);
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-supacode-cache"), "validated");
  assert.equal(await response.text(), body);
});

test("range downloads are rejected until a verified asset is cached", async () => {
  const store = installCache();
  globalThis.fetch = async () => {
    throw new Error("range miss should not fetch");
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg", {
    headers: { range: "bytes=0-" },
  });
  assert.equal(response.status, 416);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-supacode-cache"), "range-miss");
  assert.equal(store.size, 0);
});

test("range downloads are served from verified cache", async () => {
  installCache();
  const body = "verified asset";
  const digest = await sha256(body);
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: digest, size: text.encode(body).byteLength },
        },
      });
    }
    assert.equal(url, releaseDMGUrl);
    return new Response(body);
  };

  await fetchWorker("/download/v1.0.0/supacode.dmg");

  globalThis.fetch = async () => {
    throw new Error("range hit should not fetch");
  };
  const response = await fetchWorker("/download/v1.0.0/supacode.dmg", {
    headers: { range: "bytes=0-7" },
  });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("content-length"), "8");
  assert.equal(response.headers.get("content-range"), `bytes 0-7/${text.encode(body).byteLength}`);
  assert.equal(response.headers.get("x-supacode-cache"), "hit");
  assert.equal(await response.text(), "verified");
});

test("appcast is proxied without checksum validation", async () => {
  installCache();
  const seen = [];
  globalThis.fetch = async (url) => {
    seen.push(url);
    assert.equal(url, latestAppcastUrl);
    return new Response("appcast");
  };

  const response = await fetchWorker("/download/latest/appcast.xml");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "public, max-age=300");
  assert.equal(response.headers.get("x-supacode-cache"), "bypass");
  assert.equal(await response.text(), "appcast");
  assert.deepEqual(seen, [latestAppcastUrl]);
});

test("appcast range requests are proxied", async () => {
  installCache();
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push([url, init.headers.get("range")]);
    return new Response("appcast range", { status: 206 });
  };

  const response = await fetchWorker("/download/latest/appcast.xml", {
    headers: { range: "bytes=0-3" },
  });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("cache-control"), "public, max-age=300");
  assert.equal(response.headers.get("x-supacode-cache"), "bypass");
  assert.equal(await response.text(), "appcast range");
  assert.deepEqual(seen, [[latestAppcastUrl, "bytes=0-3"]]);
});

test("checksum mismatch is blocked and not cached", async () => {
  const store = installCache();
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: "0".repeat(64), size: 5 },
        },
      });
    }
    return new Response("wrong");
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 502);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-supacode-cache"), "checksum-mismatch");
  assert.equal(store.size, 0);
});

test("upstream failures are passed through without caching", async () => {
  const store = installCache();
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: "0".repeat(64), size: 5 },
        },
      });
    }
    return new Response("failed", { status: 500 });
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 500);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-supacode-cache"), "bypass");
  assert.equal(store.size, 0);
});

test("upstream fetch errors are blocked without caching", async () => {
  const store = installCache();
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({
        assets: {
          "supacode.dmg": { sha256: "0".repeat(64), size: 5 },
        },
      });
    }
    throw new Error("network failed");
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 502);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-supacode-cache"), "bypass");
  assert.equal(store.size, 0);
});

test("missing manifest entry is served without caching", async () => {
  const store = installCache();
  globalThis.fetch = async (url) => {
    if (url === releaseManifestUrl) {
      return Response.json({ assets: {} });
    }
    return new Response("available");
  };

  const response = await fetchWorker("/download/v1.0.0/supacode.dmg");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-supacode-cache"), "bypass");
  assert.equal(await response.text(), "available");
  assert.equal(store.size, 0);
});

test("latest and tip resolve their checksum manifests", async () => {
  installCache();
  const body = "asset";
  const digest = await sha256(body);
  const seen = [];
  globalThis.fetch = async (url) => {
    seen.push(url);
    if (url.endsWith("/checksums.json")) {
      return Response.json({
        assets: {
          "supacode.app.zip": { sha256: digest, size: text.encode(body).byteLength },
        },
      });
    }
    return new Response(body);
  };

  await fetchWorker("/download/latest/supacode.app.zip");
  await fetchWorker("/download/tip/supacode.app.zip");
  assert.deepEqual(seen, [
    "https://github.com/supabitapp/supacode/releases/latest/download/checksums.json",
    "https://github.com/supabitapp/supacode/releases/latest/download/supacode.app.zip",
    "https://github.com/supabitapp/supacode/releases/download/tip/checksums.json",
    "https://github.com/supabitapp/supacode/releases/download/tip/supacode.app.zip",
  ]);
});

const searchPage = `<!DOCTYPE html><html><head><title>Supacode</title><script>self.__next_f.push("pricing payload")</script></head><body>
<h1>Run coding agents in parallel</h1><p>Native macOS terminal built on Ghostty.</p>
<div data-search-block><span>Git</span><h3>Worktrees</h3><p>One worktree per agent.</p></div>
<div data-search-block><span>Scale</span><h3>50+ agents</h3><p>Run many at once.</p></div>
<section id="pricing"><h2 id="pricing-heading">Buy once</h2><p>One person on one Mac &amp; free updates.</p>
<h3>Team</h3><p>One Mac per seat, minimum 3 seats.</p>
<details><summary>Can I work offline?</summary><p>Activation needs an internet connection.</p></details>
</section><footer>Terms pricing</footer>
</body></html>`;

const fetchSearch = (path, init) =>
  worker.fetch(new Request(`https://supacode.sh${path}`, init), {
    ASSETS: {
      fetch: (request) => {
        assert.equal(new URL(request.url).pathname, "/");
        return new Response(searchPage, { headers: { "content-type": "text/html" } });
      },
    },
  });

test("search GET returns ranked markdown sections", async () => {
  const response = await fetchSearch("/.well-known/search?q=buy+seat");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "text/markdown; charset=utf-8");
  const body = await response.text();
  assert.match(body, /^# Search results for "buy seat"/);
  assert.ok(body.indexOf("## Buy once") < body.indexOf("## Team"));
  assert.match(body, /## Team\n\n- path: \/#pricing\n/);
  assert.doesNotMatch(body, /Terms/);
  assert.match(body, /One person on one Mac & free updates\./);
  assert.doesNotMatch(body, /payload/);
  assert.doesNotMatch(body, /Run coding agents/);
});

test("search QUERY accepts plain text and JSON bodies", async () => {
  const plain = await fetchSearch("/.well-known/search", { method: "QUERY", body: "ghostty terminal" });
  assert.equal(plain.status, 200);
  assert.match(await plain.text(), /## Run coding agents in parallel/);

  const json = await fetchSearch("/.well-known/search", {
    method: "QUERY",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ q: "seats" }),
  });
  assert.equal(json.status, 200);
  assert.match(await json.text(), /## Team/);

  const question = await fetchSearch("/.well-known/search", { method: "QUERY", body: "can I work offline?" });
  const answer = await question.text();
  assert.match(answer, /## Can I work offline\?\n\n- path: \/#pricing\n- score: 1\.000\n\nActivation needs/);
  assert.doesNotMatch(answer, /## Team/);
});

test("search reports empty results, missing queries, and bad methods", async () => {
  const empty = await fetchSearch("/.well-known/search?q=zzzz");
  assert.equal(empty.status, 200);
  assert.match(await empty.text(), /No results\./);

  assert.equal((await fetchSearch("/.well-known/search")).status, 400);
  assert.equal(
    (await fetchSearch("/.well-known/search", { method: "QUERY", headers: { "content-type": "application/json" }, body: "{" })).status,
    400,
  );

  const post = await fetchSearch("/.well-known/search", { method: "POST", body: "x" });
  assert.equal(post.status, 405);
  assert.equal(post.headers.get("allow"), "GET, HEAD, QUERY, OPTIONS");
});

test("search matches section anchors and keeps blocks separate", async () => {
  const pricing = await (await fetchSearch("/.well-known/search?q=pricing")).text();
  assert.match(pricing, /^# Search results for "pricing"\n\n## Buy once\n\n- path: \/#pricing\n- score: 1\.000/);

  const worktrees = await (await fetchSearch("/.well-known/search?q=worktrees")).text();
  assert.match(worktrees, /## Worktrees\n\n- path: \/\n- score: 1\.000\n\nOne worktree per agent\.\n/);
  assert.doesNotMatch(worktrees, /Scale/);
});

test("search rejects oversized QUERY bodies", async () => {
  const response = await fetchSearch("/.well-known/search", { method: "QUERY", body: "x".repeat(8193) });
  assert.equal(response.status, 413);

  const streamed = await fetchSearch("/.well-known/search", {
    method: "QUERY",
    duplex: "half",
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(text.encode("x".repeat(5000)));
        controller.enqueue(text.encode("x".repeat(5000)));
        controller.close();
      },
    }),
  });
  assert.equal(streamed.status, 413);
});

test("search QUERY rejects unsupported media types and answers CORS preflight", async () => {
  const xml = await fetchSearch("/.well-known/search", {
    method: "QUERY",
    headers: { "content-type": "application/xml" },
    body: "<q>offline</q>",
  });
  assert.equal(xml.status, 415);
  assert.equal(xml.headers.get("accept-query"), "text/plain, application/json");

  const form = await fetchSearch("/.well-known/search", {
    method: "QUERY",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "offline",
  });
  assert.equal(form.status, 200);

  const preflight = await fetchSearch("/.well-known/search", { method: "OPTIONS" });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-methods"), "GET, HEAD, QUERY");
  assert.equal(preflight.headers.get("access-control-allow-headers"), "content-type");
});
