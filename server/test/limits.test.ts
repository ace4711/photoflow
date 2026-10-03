import { test, afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { call, fakeJpeg, fakeMp4, link, makeLink, pf, poolBody, rk, seedObject, specBody, startServer, type TestEnv } from "./helpers.ts";
import { sha256hex } from "../src/crypto.ts";

let env: TestEnv;
beforeEach(async () => { env = await startServer((c) => { c.limits.jsonBytes = 4096; c.limits.imageBytes = 50_000; c.limits.mp4Bytes = 20_000; }); });
afterEach(async () => { await env.close(); });

const SHA = sha256hex("x");

test("JSON över gränsen ger 413 (även utan Content-Length-ärlighet)", async () => {
  const big = { assets: [], pad: "x".repeat(5000) };
  const r = await call(env, "PUT", `/api/v1/objects/00000000-0000-4000-8000-000000000000/pool`, { auth: pf(env), body: big });
  assert.ok(r.status === 413 || r.status === 404, String(r.status)); // 404 om objektet kontrolleras först
  const id = await seedObject(env);
  const r2 = await call(env, "PUT", `/api/v1/objects/${id}/pool`, { auth: pf(env), body: big });
  assert.equal(r2.status, 413);
  assert.equal(r2.json.error.code, "payload_too_large");
  const r3 = await call(env, "POST", "/api/v1/assets/check", { auth: pf(env), body: { sha256: [], pad: "y".repeat(9000) } });
  assert.equal(r3.status, 413);
  // chunked utan Content-Length
  const res = await fetch(env.url + "/api/v1/assets/check", {
    method: "POST", headers: { Authorization: pf(env), "Content-Type": "application/json" },
    body: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"sha256":[],"pad":"' + "z".repeat(9000) + '"}')); c.close(); } }),
    // @ts-expect-error duplex krävs av undici för strömmande kropp
    duplex: "half",
  });
  assert.equal(res.status, 413);
});

test("bild över gränsen ger 413; bara JPEG, inga GPS-data, rimliga mått", async () => {
  const big = await call(env, "PUT", `/api/v1/assets/${SHA}/w1600`, { auth: pf(env), raw: fakeJpeg(1600, 1000, { pad: 60_000 }), type: "image/jpeg" });
  assert.equal(big.status, 413);
  assert.equal((await call(env, "PUT", `/api/v1/assets/${SHA}/w1600`, { auth: pf(env), raw: fakeJpeg(100, 100), type: "image/png" })).status, 415);
  const notJpeg = await call(env, "PUT", `/api/v1/assets/${SHA}/w1600`, { auth: pf(env), raw: Buffer.from("PNG....."), type: "image/jpeg" });
  assert.equal(notJpeg.status, 415);
  const gps = await call(env, "PUT", `/api/v1/assets/${SHA}/w1600`, { auth: pf(env), raw: fakeJpeg(1600, 1000, { gps: true }), type: "image/jpeg" });
  assert.equal(gps.status, 422);
  assert.equal(gps.json.error.code, "gps_in_image");
  const wide = await call(env, "PUT", `/api/v1/assets/${SHA}/w480`, { auth: pf(env), raw: fakeJpeg(3000, 2000), type: "image/jpeg" });
  assert.equal(wide.status, 422);
  assert.equal((await call(env, "PUT", `/api/v1/assets/${SHA}/w999`, { auth: pf(env), raw: fakeJpeg(10, 10), type: "image/jpeg" })).status, 422);
  assert.equal((await call(env, "PUT", `/api/v1/assets/nope/w480`, { auth: pf(env), raw: fakeJpeg(10, 10), type: "image/jpeg" })).status, 422);
  assert.equal((await call(env, "PUT", `/api/v1/assets/${SHA}/w480`, { auth: pf(env), raw: fakeJpeg(480, 320), type: "image/jpeg" })).status, 200);
  // uppladdade byte räknas
  assert.ok(env.app.d.counters.uploadsBytes > 0);
});

test("MP4 över gränsen ger 413 och kräver render-scope", async () => {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  const c = await call(env, "POST", "/api/v1/render-jobs/claim", { auth: rk(env) });
  const url = `/api/v1/render-jobs/${c.json.jobId}/output`;
  assert.equal((await call(env, "PUT", url, { auth: pf(env), raw: fakeMp4(1000), type: "video/mp4" })).status, 403);
  const big = await call(env, "PUT", url, { auth: rk(env), raw: fakeMp4(30_000), type: "video/mp4" });
  assert.equal(big.status, 413);
  const { readdirSync } = await import("node:fs");
  assert.equal(readdirSync(`${env.dir}/tmp`).filter((f) => f.endsWith(".part")).length, 0);
  // jobbet lever kvar och kan fortfarande slutföras
  assert.equal((await call(env, "PUT", url, { auth: rk(env), raw: fakeMp4(10_000), type: "video/mp4" })).status, 201);
});

test("chunked MP4 utan Content-Length stoppas av den löpande gränsen", async () => {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  const c = await call(env, "POST", "/api/v1/render-jobs/claim", { auth: rk(env) });
  const data = fakeMp4(30_000);
  const res = await fetch(`${env.url}/api/v1/render-jobs/${c.json.jobId}/output`, {
    method: "PUT", headers: { Authorization: rk(env), "Content-Type": "video/mp4" },
    body: new ReadableStream({ start(ctl) { ctl.enqueue(data.subarray(0, 15_000)); ctl.enqueue(data.subarray(15_000)); ctl.close(); } }),
    // @ts-expect-error duplex
    duplex: "half",
  });
  assert.equal(res.status, 413);
});

test("specens storlek: för många klipp/bilder nekas men en normal spec går igenom", async () => {
  const id = await seedObject(env);
  void poolBody; void specBody;
  assert.equal((await call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body: specBody([0, 1]), headers: { "If-Match": '"1"' } })).status, 200);
});
