import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { call, link, makeLink, newReel, pf, poolBody, seedObject, SHAS, specBody, startServer, type TestEnv } from "./helpers.ts";

let env: TestEnv;
before(async () => { env = await startServer(); });
after(async () => { await env.close(); });

const put = (id: string, body: unknown, rev: number | string) =>
  call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body, headers: { "If-Match": typeof rev === "number" ? `"${rev}"` : rev } });

test("upsert av objekt är idempotent; reel-id kan inte kapas av annan fotograf", async () => {
  const REEL = newReel();
  const a = await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: pf(env), body: { address: "Lindvägen 12", kind: "house" } });
  assert.equal(a.status, 201);
  assert.equal(a.json.status, "draft");
  assert.equal(a.json.currentRevision, 0);
  const b = await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: pf(env), body: { address: "Lindvägen 12B", kind: "house" } });
  assert.equal(b.status, 200);
  assert.equal(b.json.objectId, a.json.objectId);
  const { createKey } = await import("../src/cli.ts");
  const other = createKey(env.app.d.db, "Konkurrent", "photographer");
  const c = await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: `Bearer ${other.key}`, body: { address: "x" } });
  assert.equal(c.status, 409);
  assert.equal((await call(env, "GET", `/api/v1/objects/${a.json.objectId}`, { auth: `Bearer ${other.key}` })).status, 404);
  assert.equal((await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: pf(env), body: {} })).status, 422);
});

test("spec: If-Match krävs, store-referenser, servern äger revision/status/property", async () => {
  const REEL = newReel();
  const o = await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: pf(env), body: { address: "Lindvägen 12, Tyresö", sessionID: "S9" } });
  const id = o.json.objectId;
  assert.equal((await call(env, "PUT", `/api/v1/objects/${id}/pool`, { auth: pf(env), body: poolBody() })).status, 200);
  const noHeader = await call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body: specBody() });
  assert.equal(noHeader.status, 428);
  const r = await put(id, specBody([0, 1], { revision: 99, status: "approved", property: { address: "Fel adress" } }), 0);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.revision, 1);
  assert.equal(r.headers.get("etag"), '"1"');
  const s = r.json.spec;
  assert.equal(s.revision, 1);
  assert.equal(s.status, "draft");
  assert.equal(s.property.address, "Lindvägen 12, Tyresö");
  assert.equal(s.property.sessionID, "S9");
  assert.deepEqual(s.assets[0].sources, [{ kind: "store", key: `img/${SHAS[0]}` }]);
  assert.ok(!JSON.stringify(s).includes("/Users/x"), "lokala sökvägar lagras aldrig");
  assert.equal(s.updatedBy.role, "photographer");
  const get = await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) });
  assert.equal(get.headers.get("etag"), '"1"');
  assert.equal(get.json.spec.timeline.length, 2);
});

test("412 vid krock med aktuell spec; idempotent omförsök ger ingen ny revision", async () => {
  const id = await seedObject(env);
  // första skrivningen (revision 1) gjordes av seedObject. Två skrivare utgår från revision 1.
  const a = await put(id, specBody([0, 1]), 1);
  assert.equal(a.status, 200);
  assert.equal(a.json.revision, 2);
  assert.equal(a.json.changed, true);
  // omförsök av exakt samma anrop (svaret kom aldrig fram): ingen ny revision, 200
  const retry = await put(id, specBody([0, 1]), 1);
  assert.equal(retry.status, 200);
  assert.equal(retry.json.revision, 2);
  assert.equal(retry.json.changed, false);
  // en annan ändring från samma gamla revision: 412 med aktuell spec
  const conflict = await put(id, specBody([2, 1]), 1);
  assert.equal(conflict.status, 412);
  assert.equal(conflict.json.currentRevision, 2);
  assert.equal(conflict.json.spec.revision, 2);
  assert.equal(conflict.json.spec.timeline.length, 2);
  assert.equal(conflict.headers.get("etag"), '"2"');
  // med rätt revision går det igenom
  const ok = await put(id, specBody([2, 1]), 2);
  assert.equal(ok.status, 200);
  assert.equal(ok.json.revision, 3);
  const n = env.app.d.db.prepare("SELECT COUNT(*) AS n FROM spec_revisions WHERE object_id = ?").get(id) as { n: number };
  assert.equal(n.n, 3);
  assert.equal((await put(id, specBody([2, 1]), "abc")).status, 400);
});

test("mäklarens 412 och idempotens via /share/spec", async () => {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  const share = await call(env, "GET", "/api/v1/share", { auth: link(token) });
  assert.equal(share.headers.get("etag"), '"1"');
  const spec = share.json.spec;
  // webbens specar har signerade URL:er, inga store-nycklar
  assert.match(spec.assets[0].sources[0].url, /^\/media\/\d+\/[A-Za-z0-9_-]+\/img\/[0-9a-f]{64}\/w1600$/);
  // poolen innehåller bild 4 som inte ligger i specen; webben får den som kandidat
  assert.equal(spec.assets.length, 4);
  assert.equal(share.json.pool.length, 4);
  spec.timeline.pop();
  const hdr = { "If-Match": '"1"' };
  const a = await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: spec, headers: hdr });
  assert.equal(a.status, 200, a.text);
  assert.equal(a.json.revision, 2);
  assert.equal(a.json.status, "proposed");
  const again = await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: spec, headers: hdr });
  assert.equal(again.status, 200);
  assert.equal(again.json.revision, 2);
  // fotografen ändrar, mäklaren sparar från gammal revision: 412
  await put(id, specBody([2]), 2);
  spec.timeline.reverse();
  const stale = await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: spec, headers: { "If-Match": '"2"' } });
  assert.equal(stale.status, 412);
  assert.equal(stale.json.error.code, "revision_conflict");
  assert.equal(stale.json.currentRevision, 3);
});

test("statusflöde: draft → proposed → approved → rendered, tillbaka till proposed vid ändring", async () => {
  const id = await seedObject(env);
  const st = async () => (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json;
  assert.equal((await st()).status, "draft");
  const { token } = await makeLink(env, id);
  assert.equal((await st()).status, "proposed");

  // fel revision vid godkännande: 409
  const bad = await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 5 } });
  assert.equal(bad.status, 409);
  assert.equal(bad.json.currentRevision, 1);
  const ok = await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.status, "approved");
  assert.equal(ok.json.jobs, 1);
  const again = await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  assert.equal(again.json.changed, false, "godkännande är idempotent");
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM render_jobs WHERE object_id = ?").get(id)!.n, 1);
  let d = await st();
  assert.equal(d.status, "approved");
  assert.equal(d.approvedRevision, 1);
  assert.equal(d.jobs[0].status, "queued");

  // ändring i approved går tillbaka till proposed och ersätter det köade jobbet
  const sp = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;
  sp.timeline.pop();
  assert.equal((await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: sp, headers: { "If-Match": '"1"' } })).status, 200);
  d = await st();
  assert.equal(d.status, "proposed");
  assert.equal(d.jobs[0].status, "superseded");

  // godkänn rev 2 → approved med nytt jobb
  assert.equal((await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 2 } })).status, 200);
  assert.equal((await st()).status, "approved");

  // events finns för varje övergång och saknar personuppgifter
  const ev = env.app.d.db.prepare("SELECT type, data_json, actor_ref FROM events WHERE object_id = ?").all(id) as any[];
  const transitions = ev.filter((e) => e.type === "status").map((e) => JSON.parse(e.data_json).to);
  assert.deepEqual(transitions, ["proposed", "approved", "proposed", "approved"]);
  assert.ok(!JSON.stringify(ev).includes("Lindvägen"));
});

test("fotografen kan godkänna på mäklarens uppdrag (loggas som photographer)", async () => {
  const id = await seedObject(env);
  const r = await call(env, "POST", `/api/v1/objects/${id}/approve`, { auth: pf(env), body: { revision: 1 } });
  assert.equal(r.status, 200);
  const ev = env.app.d.db.prepare("SELECT actor_role FROM events WHERE object_id = ? AND type = 'approved'").get(id) as { actor_role: string };
  assert.equal(ev.actor_role, "photographer");
  const { token } = await makeLink(env, id);
  const share = await call(env, "GET", "/api/v1/share", { auth: link(token) });
  assert.equal(share.json.approval.by, "photographer");
});

test("länk kräver en spec; spec kräver poolbilder", async () => {
  const REEL = newReel();
  const o = await call(env, "PUT", `/api/v1/objects/by-reel/${REEL}`, { auth: pf(env), body: { address: "Ny" } });
  const id = o.json.objectId;
  assert.equal((await call(env, "POST", `/api/v1/objects/${id}/links`, { auth: pf(env), body: {} })).status, 409);
  // tom pool: specens bilder finns inte i poolen
  const r = await put(id, specBody(), 0);
  assert.equal(r.status, 422);
  assert.match(r.json.error.message, /bildpool/);
});

test("poolvalidering: dubbletter, max 40, ogiltig hash och specens id/duration/utbildsprofiler", async () => {
  const id = await seedObject(env);
  const pool = (assets: unknown[]) => call(env, "PUT", `/api/v1/objects/${id}/pool`, { auth: pf(env), body: { assets } });
  const a = poolBody().assets;
  assert.equal((await pool([a[0], { ...a[1], sha256: a[0].sha256 }])).status, 422);
  assert.equal((await pool([a[0], { ...a[1], assetId: "a1" }])).status, 422);
  assert.equal((await pool([{ ...a[0], sha256: "xyz" }])).status, 422);
  assert.equal((await pool([{ ...a[0], width: 0 }])).status, 422);
  const many = Array.from({ length: 41 }, (_, i) => ({ assetId: `p${i}`, sha256: (i.toString(16).padStart(2, "0")).repeat(32), width: 10, height: 10 }));
  const r41 = await pool(many);
  assert.equal(r41.status, 422);
  assert.equal(r41.json.error.code, "too_many_assets");
  assert.equal((await pool(many.slice(0, 40))).status, 200);
  // återställ poolen
  assert.equal((await pool(poolBody().assets)).status, 200);

  // spec: tidslinjens bild måste finnas i poolen; okänd bild
  const unknown = specBody([0]);
  (unknown.assets as any[])[0].sha256 = "f".repeat(64);
  const u = await put(id, unknown, 1);
  assert.equal(u.status, 422);
  // klippets längd 0,5..10
  const long = specBody([0, 1]);
  (long.timeline as any[])[0].duration = 11;
  const l = await put(id, long, 1);
  assert.equal(l.status, 422);
  assert.match(l.json.error.message, /0,5 och 10/);
  // för många klipp
  const clips = specBody(Array.from({ length: 31 }, () => 0));
  assert.equal((await put(id, clips, 1)).status, 422);
  // minReaderVersion 2 vägras
  assert.equal((await put(id, specBody([0], { minReaderVersion: 2 }), 1)).status, 422);
  // fel reel-id
  assert.equal((await put(id, specBody([0], { id: "annat" }), 1)).status, 422);
  // mäklaren får inte ändra utbildsprofiler men fotografen får
  const { token } = await makeLink(env, id);
  const sp = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;
  sp.outputs[0].width = 2160;
  const m = await call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body: sp, headers: { "If-Match": '"1"' } });
  assert.equal(m.status, 422);
  assert.match(m.json.error.message, /utbildsprofilerna/);
  const ph = specBody([0, 1, 2]);
  (ph as any).outputs[0].width = 720;
  assert.equal((await put(id, ph, 1)).status, 200);
  // okända fält bevaras
  const withExtra = specBody([0, 1, 2], { framtid: { x: 1 } });
  (withExtra as any).outputs[0].width = 720;
  const e = await put(id, withExtra, 2);
  assert.deepEqual(e.json.spec.framtid, { x: 1 });
});

test("DELETE /objects/{id} raderar rader och blobbar som inte längre refereras", async () => {
  const e2 = await startServer();
  try {
    const id = await seedObject(e2);
    const q = (sql: string) => (e2.app.d.db.prepare(sql).get(id) as { n: number }).n;
    assert.equal((e2.app.d.db.prepare("SELECT COUNT(*) AS n FROM blobs").get() as { n: number }).n, 8);
    const { readdirSync } = await import("node:fs");
    assert.ok(readdirSync(`${e2.dir}/blobs/img`).length > 0);
    const r = await call(e2, "DELETE", `/api/v1/objects/${id}`, { auth: pf(e2) });
    assert.equal(r.status, 200);
    assert.equal(q("SELECT COUNT(*) AS n FROM objects WHERE id = ?"), 0);
    assert.equal(q("SELECT COUNT(*) AS n FROM spec_revisions WHERE object_id = ?"), 0);
    assert.equal(q("SELECT COUNT(*) AS n FROM events WHERE object_id = ?"), 0);
    assert.equal((e2.app.d.db.prepare("SELECT COUNT(*) AS n FROM blobs").get() as { n: number }).n, 0);
    assert.equal(readdirSync(`${e2.dir}/blobs/img`).length, 0, "bildfilerna är borta från disk");
    assert.equal((await call(e2, "GET", `/api/v1/objects/${id}`, { auth: pf(e2) })).status, 404);
  } finally { await e2.close(); }
});

test("GET /objects med status och since", async () => {
  const id = await seedObject(env);
  const all = await call(env, "GET", "/api/v1/objects", { auth: pf(env) });
  assert.ok(all.json.objects.some((o: any) => o.objectId === id));
  const prop = await call(env, "GET", "/api/v1/objects?status=proposed", { auth: pf(env) });
  assert.ok(!prop.json.objects.some((o: any) => o.objectId === id));
  assert.equal((await call(env, "GET", "/api/v1/objects?status=nonsens", { auth: pf(env) })).status, 422);
  const future = await call(env, "GET", `/api/v1/objects?since=${encodeURIComponent("2030-01-01T00:00:00Z")}`, { auth: pf(env) });
  assert.equal(future.json.objects.length, 0);
});
