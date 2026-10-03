import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { call, link, makeLink, pf, rk, seedObject, startServer, type TestEnv } from "./helpers.ts";

let env: TestEnv;
before(async () => { env = await startServer(); });
after(async () => { await env.close(); });

test("/healthz: fast kropp och X-Objektfilm, säkerhetsheaders överallt", async () => {
  const r = await call(env, "GET", "/healthz");
  assert.equal(r.status, 200);
  assert.equal(r.text, "objektfilm ok\n");
  assert.equal(r.headers.get("x-objektfilm"), "1");
  assert.match(r.headers.get("content-security-policy")!, /default-src 'self'.*frame-ancestors 'none'/);
  assert.equal(r.headers.get("referrer-policy"), "no-referrer");
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  assert.match(r.headers.get("permissions-policy")!, /camera=\(\)/);
  assert.equal(r.headers.get("strict-transport-security"), "max-age=31536000");
  assert.match(r.headers.get("x-robots-tag")!, /noindex/);
  assert.equal(r.headers.get("access-control-allow-origin"), null);
});

test("robots.txt, landningssida och statisk webbdel", async () => {
  assert.equal((await call(env, "GET", "/robots.txt")).text, "User-agent: *\nDisallow: /\n");
  const land = await call(env, "GET", "/");
  assert.equal(land.status, 200);
  assert.match(land.text, /Objektfilm/);
  // webbdelen saknas först
  assert.equal((await call(env, "GET", "/m")).status, 503);
  mkdirSync(join(env.dir, "static"), { recursive: true });
  writeFileSync(join(env.dir, "static", "index.html"), "<!doctype html><title>m</title>");
  writeFileSync(join(env.dir, "static", "editor.js"), "console.log(1)");
  assert.equal((await call(env, "GET", "/m")).status, 200);
  assert.equal((await call(env, "GET", "/editor.js")).headers.get("content-type"), "text/javascript; charset=utf-8");
  assert.equal((await call(env, "GET", "/index.html")).status, 404, "index.html serveras bara via /m");
  assert.equal((await call(env, "GET", "/..%2fetc")).status, 404);
});

test("API-nyckel: saknas, fel, rätt scope och fel scope", async () => {
  assert.equal((await call(env, "GET", "/api/v1/me")).status, 401);
  assert.equal((await call(env, "GET", "/api/v1/me", { auth: "Bearer pf_felfelfelfelfelfelfelfelfelfelfelfelfel" })).status, 401);
  const me = await call(env, "GET", "/api/v1/me", { auth: pf(env) });
  assert.equal(me.status, 200);
  assert.equal(me.json.scope, "photographer");
  assert.equal(me.json.photographer.name, "Testfotograf");
  const meR = await call(env, "GET", "/api/v1/me", { auth: rk(env) });
  assert.equal(meR.json.scope, "render");
  // renderscope får inte röra fotografens API, och tvärtom
  assert.equal((await call(env, "GET", "/api/v1/objects", { auth: rk(env) })).status, 403);
  assert.equal((await call(env, "POST", "/api/v1/render-jobs/claim", { auth: pf(env) })).status, 403);
  // en mäklartoken duger inte som API-nyckel
  assert.equal((await call(env, "GET", "/api/v1/me", { auth: "Bearer " + "x".repeat(40) })).status, 401);
});

test("återkallad nyckel ger 401", async () => {
  const { createKey } = await import("../src/cli.ts");
  const k = createKey(env.app.d.db, "Annan", "photographer");
  assert.equal((await call(env, "GET", "/api/v1/me", { auth: `Bearer ${k.key}` })).status, 200);
  env.app.d.db.prepare("UPDATE api_keys SET revoked_at = ? WHERE id = ?").run(new Date().toISOString(), k.keyId);
  assert.equal((await call(env, "GET", "/api/v1/me", { auth: `Bearer ${k.key}` })).status, 401);
});

test("nyckeln lagras bara som hash", () => {
  const rows = env.app.d.db.prepare("SELECT key_hash FROM api_keys").all() as { key_hash: string }[];
  for (const r of rows) {
    assert.match(r.key_hash, /^[0-9a-f]{64}$/);
    assert.notEqual(r.key_hash, env.photographerKey);
  }
});

test("mäklarlänk: giltig, okänd (401), utgången (410), återkallad (410), fel Origin (403)", async () => {
  const id = await seedObject(env);
  const { token, linkId, res } = await makeLink(env, id);
  assert.match(res.json.url, /\/m#[A-Za-z0-9_-]{43}$/);
  assert.match(res.json.archiveUrl, /\/a#/);
  // token lagras bara som hash
  const rows = env.app.d.db.prepare("SELECT token_hash FROM links").all() as { token_hash: string }[];
  assert.ok(rows.every((r) => r.token_hash !== token && /^[0-9a-f]{64}$/.test(r.token_hash)));

  const ok = await call(env, "GET", "/api/v1/share", { auth: link(token) });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.object.address, "Lindvägen 12, Tyresö");
  assert.equal(ok.json.object.status, "proposed");

  assert.equal((await call(env, "GET", "/api/v1/share", { auth: link("A".repeat(43)) })).status, 401);
  assert.equal((await call(env, "GET", "/api/v1/share")).status, 401);
  assert.equal((await call(env, "GET", "/api/v1/share", { auth: link(token), headers: { Origin: "https://elak.example" } })).status, 403);
  assert.equal((await call(env, "GET", "/api/v1/share", { auth: link(token), headers: { Origin: env.url } })).status, 200);

  // utgången
  const { token: t2, linkId: l2 } = await makeLink(env, id, { label: "Kort", expiresInDays: 1 });
  env.clock.ms += 2 * 86400_000;
  const exp = await call(env, "GET", "/api/v1/share", { auth: link(t2) });
  assert.equal(exp.status, 410);
  assert.equal(exp.json.error.code, "link_expired");
  assert.match(exp.json.error.message, /Kontakta fotografen/);
  env.clock.ms -= 2 * 86400_000;
  void l2;

  // återkallad
  const rev = await call(env, "DELETE", `/api/v1/links/${linkId}`, { auth: pf(env) });
  assert.equal(rev.status, 200);
  const gone = await call(env, "GET", "/api/v1/share", { auth: link(token) });
  assert.equal(gone.status, 410);
  assert.equal(gone.json.error.code, "link_revoked");
});

test("länkens utgång: högst 90 dagar, standard 30", async () => {
  const id = await seedObject(env);
  assert.equal((await call(env, "POST", `/api/v1/objects/${id}/links`, { auth: pf(env), body: { expiresInDays: 91 } })).status, 422);
  const r = await call(env, "POST", `/api/v1/objects/${id}/links`, { auth: pf(env), body: {} });
  assert.equal(r.status, 201);
  const days = (Date.parse(r.json.expiresAt) - env.clock.ms) / 86400_000;
  assert.equal(Math.round(days), 30);
  // tom kropp går också bra
  const r2 = await call(env, "POST", `/api/v1/objects/${id}/links`, { auth: pf(env) });
  assert.equal(r2.status, 201);
});

test("ogiltig auth räknas och syns i /metrics (separat port)", async () => {
  const before = env.app.d.counters.invalidAuth;
  await call(env, "GET", "/api/v1/share", { auth: link("B".repeat(43)) });
  await call(env, "GET", "/api/v1/me", { auth: "Bearer pf_" + "z".repeat(43) });
  assert.equal(env.app.d.counters.invalidAuth, before + 2);
  const port = (env.app.metricsServer.address() as any).port;
  const m = await (await fetch(`http://127.0.0.1:${port}/metrics`)).text();
  for (const name of ["objektfilm_render_queue_oldest_seconds", "objektfilm_invalid_auth_total", "objektfilm_uploads_bytes_total", 'objektfilm_objects{status="proposed"}', "objektfilm_purge_overdue"]) {
    assert.ok(m.includes(name), `saknar ${name}`);
  }
  // mätvärden finns inte på huvudporten
  assert.equal((await call(env, "GET", "/metrics")).status, 404);
});

test("takt per nyckel ger 429 med Retry-After", async () => {
  const e2 = await startServer((c) => { c.rate.perMinute = 5; });
  try {
    let last = 0;
    let retry: string | null = null;
    for (let i = 0; i < 8; i++) {
      const r = await call(e2, "GET", "/api/v1/me", { auth: pf(e2) });
      last = r.status;
      retry = r.headers.get("retry-after");
    }
    assert.equal(last, 429);
    assert.ok(Number(retry) >= 1);
    // en annan nyckel påverkas inte
    assert.equal((await call(e2, "GET", "/api/v1/me", { auth: rk(e2) })).status, 200);
  } finally { await e2.close(); }
});

test("spec-skrivningar per länk begränsas per timme", async () => {
  const e2 = await startServer((c) => { c.rate.specPerHour = 2; });
  try {
    const { REEL, specBody } = await import("./helpers.ts");
    void REEL;
    const id = await seedObject(e2);
    const { token } = await makeLink(e2, id);
    const codes: number[] = [];
    for (let i = 0; i < 4; i++) {
      const r = await call(e2, "PUT", "/api/v1/share/spec", { auth: link(token), body: specBody([0, 1, 2]), headers: { "If-Match": '"1"' } });
      codes.push(r.status);
    }
    assert.deepEqual(codes.slice(0, 2), [200, 200]);
    assert.equal(codes[3], 429);
  } finally { await e2.close(); }
});
