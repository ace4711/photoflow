import { test, afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { call, fakeMp4, link, makeLink, pf, rk, seedObject, specBody, startServer, type TestEnv } from "./helpers.ts";

let env: TestEnv;
beforeEach(async () => { env = await startServer(); });
afterEach(async () => { await env.close(); });

const claim = (wait = 0) => call(env, "POST", `/api/v1/render-jobs/claim?wait=${wait}`, { auth: rk(env) });
const output = (jobId: string, body: Buffer = fakeMp4(), type = "video/mp4") =>
  call(env, "PUT", `/api/v1/render-jobs/${jobId}/output`, { auth: rk(env), raw: body, type });

async function approved(): Promise<{ id: string; token: string }> {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  const r = await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  assert.equal(r.status, 200);
  return { id, token };
}

test("long-poll utan jobb ger 204 efter väntetiden och uppdaterar workers", async () => {
  const t0 = Date.now();
  const r = await claim(0.4);
  const dt = Date.now() - t0;
  assert.equal(r.status, 204);
  assert.ok(dt >= 350 && dt < 3000, `väntade ${dt} ms`);
  const w = env.app.d.db.prepare("SELECT COUNT(*) AS n FROM workers").get() as { n: number };
  assert.equal(w.n, 1);
});

test("long-poll vaknar direkt när ett jobb godkänns", async () => {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  const waiting = claim(10);
  await new Promise((r) => setTimeout(r, 150));
  const t0 = Date.now();
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  const r = await waiting;
  assert.equal(r.status, 200);
  assert.ok(Date.now() - t0 < 1500);
  assert.equal(r.json.objectId, id);
  assert.equal(r.json.revision, 1);
  assert.equal(r.json.spec.status, "approved");
  assert.equal(r.json.spec.assets[0].sources[0].kind, "store");
  assert.ok(Date.parse(r.json.leaseUntil) > env.clock.ms);
  await call(env, "POST", `/api/v1/render-jobs/${r.json.jobId}/fail`, { auth: rk(env), body: { message: "städ" } });
  // wait klampas till 25 s (kontrolleras via konfigurationen, inte genom att vänta)
  assert.equal(env.cfg.maxClaimWaitSeconds, 25);
});

test("renderflöde: claim → heartbeat → output → rendered, MP4 går att hämta", async () => {
  const { id, token } = await approved();
  const c = await claim();
  assert.equal(c.status, 200);
  assert.equal(c.json.objectId, id);
  const hb = await call(env, "POST", `/api/v1/render-jobs/${c.json.jobId}/heartbeat`, { auth: rk(env) });
  assert.equal(hb.status, 200);
  const mp4 = fakeMp4(5000);
  const up = await output(c.json.jobId, mp4);
  assert.equal(up.status, 201, up.text);
  assert.equal(up.json.status, "rendered");
  const d = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json;
  assert.equal(d.status, "rendered");
  assert.equal(d.renders.length, 1);
  assert.equal(d.renders[0].bytes, 5000);
  assert.equal(d.renders[0].current, true);
  assert.equal(d.jobs[0].status, "done");
  // mäklaren hämtar via Authorization och via signerad URL
  const share = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json;
  assert.equal(share.object.status, "rendered");
  assert.equal(share.renders.length, 1);
  const viaAuth = await call(env, "GET", `/api/v1/share/renders/${share.renders[0].renderId}`, { auth: link(token) });
  assert.equal(viaAuth.status, 200);
  assert.deepEqual(viaAuth.buf, mp4);
  assert.match(viaAuth.headers.get("content-disposition")!, /inline; filename="Objektfilm.mp4"/);
  assert.ok(!viaAuth.headers.get("content-disposition")!.includes("Lindv"));
  const viaUrl = await call(env, "GET", share.renders[0].url);
  assert.equal(viaUrl.status, 200);
  assert.equal(viaUrl.headers.get("content-type"), "video/mp4");
  // en ändring tar tillbaka till proposed men MP4:n står kvar som tidigare version
  const sp = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;
  sp.timeline.pop();
  await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: sp, headers: { "If-Match": '"1"' } });
  const d2 = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json;
  assert.equal(d2.status, "proposed");
  assert.equal(d2.renders.length, 1);
  assert.equal(d2.renders[0].current, false);
});

test("superseded: uppladdning efter ändring avvisas med 409 och filen kastas", async () => {
  const { id, token } = await approved();
  const c = await claim();
  assert.equal(c.json.objectId, id);
  // mäklaren ändrar efter att jobbet hämtats
  const sp = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;
  sp.timeline.pop();
  assert.equal((await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: sp, headers: { "If-Match": '"1"' } })).status, 200);
  const hb = await call(env, "POST", `/api/v1/render-jobs/${c.json.jobId}/heartbeat`, { auth: rk(env) });
  assert.equal(hb.status, 409);
  assert.equal(hb.json.error.code, "superseded");
  const up = await output(c.json.jobId);
  assert.equal(up.status, 409);
  assert.equal(up.json.error.code, "superseded");
  const job = env.app.d.db.prepare("SELECT status FROM render_jobs WHERE id = ?").get(c.json.jobId) as { status: string };
  assert.equal(job.status, "superseded");
  assert.equal((env.app.d.db.prepare("SELECT COUNT(*) AS n FROM renders WHERE object_id = ?").get(id) as { n: number }).n, 0);
  const { readdirSync } = await import("node:fs");
  assert.equal(readdirSync(`${env.dir}/tmp`).filter((f) => f.endsWith(".part")).length, 0, "inga kvarglömda delfiler");
  // godkänn rev 2 och rendera klart
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 2 } });
  const c2 = await claim();
  assert.equal(c2.json.revision, 2);
  assert.equal((await output(c2.json.jobId)).status, 201);
});

test("jobb av en annan fotograf är osynliga; fail ger omförsök och sedan failed efter 3", async () => {
  const { id } = await approved();
  const { createKey } = await import("../src/cli.ts");
  const other = createKey(env.app.d.db, "Annan fotograf", "render");
  const none = await call(env, "POST", "/api/v1/render-jobs/claim?wait=0", { auth: `Bearer ${other.key}` });
  assert.equal(none.status, 204);
  let jobId = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    const c = await claim();
    assert.equal(c.status, 200);
    assert.equal(c.json.objectId, id);
    jobId = c.json.jobId;
    const f = await call(env, "POST", `/api/v1/render-jobs/${jobId}/fail`, { auth: rk(env), body: { message: "ffmpeg dog" } });
    assert.equal(f.json.status, attempt < 3 ? "queued" : "failed");
  }
  assert.equal((await claim()).status, 204);
  const d = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json;
  assert.equal(d.jobs[0].status, "failed");
  assert.equal(d.jobs[0].error, "ffmpeg dog");
  assert.equal(d.status, "approved");
  // fel nyckel får inte röra jobbet
  assert.equal((await call(env, "POST", `/api/v1/render-jobs/${jobId}/heartbeat`, { auth: `Bearer ${other.key}` })).status, 404);
});

test("utgången lease: jobbet går tillbaka i kön", async () => {
  const { id } = await approved();
  const c = await claim();
  assert.equal(c.json.objectId, id);
  assert.equal((await claim()).status, 204);
  env.clock.ms += 11 * 60_000;
  const again = await claim();
  assert.equal(again.status, 200);
  assert.equal(again.json.jobId, c.json.jobId);
  // gamla hämtningen kan inte längre ladda upp som någon annan; samma nyckel är dock ok
  assert.equal((await output(again.json.jobId)).status, 201);
  env.clock.ms -= 11 * 60_000;
});

test("output kräver video/mp4 med giltigt innehåll och ofullständiga jobb ger inte rendered", async () => {
  const { id } = await approved();
  const c = await claim();
  assert.equal((await output(c.json.jobId, fakeMp4(), "application/octet-stream")).status, 415);
  assert.equal((await output(c.json.jobId, Buffer.from("detta är ingen mp4 alls"))).status, 415);
  assert.equal((await output(c.json.jobId, Buffer.alloc(0))).status, 422);
  assert.equal((await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json.status, "approved");
  assert.equal((await output(c.json.jobId)).status, 201);
});

test("flera utbildsprofiler: rendered först när alla är klara", async () => {
  const id = await seedObject(env);
  const two = specBody([0, 1, 2]);
  (two.outputs as any[]).push({ id: "1x1", aspect: "1:1", width: 1080, height: 1080, fps: 30 });
  assert.equal((await call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body: two, headers: { "If-Match": '"1"' } })).status, 200);
  const { token } = await makeLink(env, id);
  const a = await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 2 } });
  assert.equal(a.json.jobs, 2);
  const c1 = await claim(); const c2 = await claim();
  assert.notEqual(c1.json.outputId, c2.json.outputId);
  assert.equal((await output(c1.json.jobId)).json.status, "approved");
  assert.equal((await output(c2.json.jobId, fakeMp4(3000))).json.status, "rendered");
});
