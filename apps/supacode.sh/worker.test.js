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
