import { test, afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { call, fakeMp4, link, makeLink, pf, rk, seedObject, startServer, type TestEnv } from "./helpers.ts";
import { backupDb, restoreDb, verifyBackup, createKey } from "../src/cli.ts";
import { purge } from "../src/domain.ts";
import { migrate, MIGRATIONS, openDb } from "../src/db.ts";
import { DatabaseSync } from "node:sqlite";

let env: TestEnv;
beforeEach(async () => { env = await startServer(); });
afterEach(async () => { await env.close(); });

test("gallring: objekt efter purge_after raderas med blobbar, MP4 och händelser; andra lämnas", async () => {
  const old = await seedObject(env);
  const { token } = await makeLink(env, old);
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  const c = await call(env, "POST", "/api/v1/render-jobs/claim", { auth: rk(env) });
  await call(env, "PUT", `/api/v1/render-jobs/${c.json.jobId}/output`, { auth: rk(env), raw: fakeMp4(), type: "video/mp4" });
  const mp4s = env.app.d.db.prepare("SELECT sha256 FROM renders WHERE object_id = ?").all(old) as { sha256: string }[];
  assert.ok(existsSync(env.app.d.store.mp4Path(mp4s[0].sha256)));

  // purge_after sätts 90 dagar fram och metrik visar inget försenat
  const row = env.app.d.db.prepare("SELECT purge_after, updated_at FROM objects WHERE id = ?").get(old) as { purge_after: string; updated_at: string };
  assert.equal(Math.round((Date.parse(row.purge_after) - env.clock.ms) / 86400_000), 90);
  assert.equal(purge(env.app.d).objects, 0);

  // 91 dagar senare: ett nytt objekt (aktivt) överlever, det gamla gallras
  env.clock.ms += 91 * 86400_000;
  const fresh = await call(env, "PUT", `/api/v1/objects/by-reel/${"11111111-2222-4333-8444-555555555555"}`, { auth: pf(env), body: { address: "Ny" } });
  const port = (env.app.metricsServer.address() as any).port;
  const before = await (await fetch(`http://127.0.0.1:${port}/metrics`)).text();
  assert.match(before, /objektfilm_purge_overdue 1\n/);
  const r = purge(env.app.d);
  assert.equal(r.objects, 1);
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM objects WHERE id = ?").get(old)!.n, 0);
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM objects WHERE id = ?").get(fresh.json.objectId)!.n, 1);
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM events WHERE object_id = ?").get(old)!.n, 0);
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM links").get()!.n, 0);
  assert.equal(env.app.d.db.prepare("SELECT COUNT(*) AS n FROM blobs").get()!.n, 0);
  assert.ok(!existsSync(env.app.d.store.mp4Path(mp4s[0].sha256)));
  assert.ok(!existsSync(env.app.d.store.imagePath("a".repeat(64), "w480")));
  const after = await (await fetch(`http://127.0.0.1:${port}/metrics`)).text();
  assert.match(after, /objektfilm_purge_overdue 0\n/);
  assert.equal((await call(env, "GET", "/api/v1/share", { auth: link(token) })).status, 401);
});

test("gallring: övergivna blobbar och delfiler äldre än ett dygn städas", async () => {
  const { sha256hex } = await import("../src/crypto.ts");
  const { fakeJpeg } = await import("./helpers.ts");
  const orphan = sha256hex("föräldralös");
  await call(env, "PUT", `/api/v1/assets/${orphan}/w480`, { auth: pf(env), raw: fakeJpeg(480, 300), type: "image/jpeg" });
  const stale = join(env.dir, "tmp", "gammal.part");
  writeFileSync(stale, "x");
  utimesSync(stale, new Date(Date.now() - 7200_000), new Date(Date.now() - 7200_000));
  assert.deepEqual({ ...purge(env.app.d) }, { objects: 0, orphanBlobs: 0, tmpFiles: 1 }, "färska orphans sparas ett dygn");
  env.clock.ms += 25 * 3600_000;
  const r = purge(env.app.d);
  assert.equal(r.orphanBlobs, 1);
  assert.ok(!existsSync(env.app.d.store.imagePath(orphan, "w480")));
});

test("backup och återställning: integrity_check ok, samma antal rader, nycklar överlever", async () => {
  const id = await seedObject(env);
  await makeLink(env, id);
  const out = join(env.dir, "backups", "b1.db");
  const b = backupDb(env.app.d.db, out);
  assert.equal(b.integrity, "ok");
  assert.equal(b.counts.objects, 1);
  assert.equal(b.counts.spec_revisions, 1);
  assert.equal(b.counts.links, 1);
  assert.equal(b.counts.blobs, 8);
  assert.throws(() => backupDb(env.app.d.db, out), /finns redan/);
  assert.equal(verifyBackup(out).integrity, "ok");

  // återställ till en ny, tom datakatalog och starta en server på den
  const dir2 = mkdtempSync(join(tmpdir(), "objektfilm-restore-"));
  try {
    restoreDb(dir2, out, false);
    assert.throws(() => restoreDb(dir2, out, false), /finns redan/);
    restoreDb(dir2, out, true);
    const db2 = openDb(dir2);
    const row = (db2.prepare("SELECT status, current_revision FROM objects").get()) as { status: string; current_revision: number };
    assert.deepEqual({ ...row }, { status: "proposed", current_revision: 1 });
    assert.equal((db2.prepare("PRAGMA integrity_check").get() as any).integrity_check, "ok");
    assert.equal((db2.prepare("PRAGMA user_version").get() as any).user_version, MIGRATIONS.length);
    db2.close();
  } finally { rmSync(dir2, { recursive: true, force: true }); }

  // trasig backup avvisas
  const bad = join(env.dir, "backups", "trasig.db");
  writeFileSync(bad, "detta är ingen databas");
  assert.throws(() => verifyBackup(bad));
  const dir3 = mkdtempSync(join(tmpdir(), "objektfilm-restore-"));
  try { assert.throws(() => restoreDb(dir3, bad, false)); } finally { rmSync(dir3, { recursive: true, force: true }); }
});

test("migrationer är versionerade och körs bara en gång; nyare databas vägras", () => {
  const db = new DatabaseSync(":memory:");
  assert.equal(migrate(db), MIGRATIONS.length);
  assert.equal(migrate(db), MIGRATIONS.length);
  const extra = [...MIGRATIONS, "CREATE TABLE ny_tabell(x INTEGER)"];
  assert.equal(migrate(db, extra), extra.length);
  assert.equal((db.prepare("SELECT COUNT(*) AS n FROM ny_tabell").get() as any).n, 0);
  assert.throws(() => migrate(db), /nyare/);
  // en misslyckad migration rullas tillbaka helt
  const db2 = new DatabaseSync(":memory:");
  assert.throws(() => migrate(db2, ["CREATE TABLE a(x); CREATE TABLE a(x);"]));
  assert.equal((db2.prepare("PRAGMA user_version").get() as any).user_version, 0);
});

test("CLI: create-key skapar fotograf och nyckel som fungerar", async () => {
  const k = createKey(env.app.d.db, "Ny Fotograf", "render", "Mac mini");
  assert.match(k.key, /^pf_[A-Za-z0-9_-]{43}$/);
  const me = await call(env, "GET", "/api/v1/me", { auth: `Bearer ${k.key}` });
  assert.equal(me.json.scope, "render");
  assert.equal(me.json.photographer.name, "Ny Fotograf");
  assert.throws(() => createKey(env.app.d.db, "X", "admin"), /scope/);
  // CLI som process
  const { execFileSync } = await import("node:child_process");
  const out = execFileSync(process.execPath, ["--disable-warning=ExperimentalWarning", join(import.meta.dirname, "../src/cli.ts"), "create-key", "--name", "Via CLI", "--scope", "photographer"], {
    env: { ...process.env, OBJEKTFILM_DATA_DIR: env.dir, OBJEKTFILM_ENV: "test" }, encoding: "utf8",
  });
  const key = /(pf_[A-Za-z0-9_-]+)/.exec(out)![1];
  assert.equal((await call(env, "GET", "/api/v1/me", { auth: `Bearer ${key}` })).status, 200);
});

test("JSON-loggen innehåller inga adresser, tokens eller nycklar", async () => {
  const { setLogSink } = await import("../src/log.ts");
  const lines: string[] = [];
  setLogSink((l) => lines.push(l));
  try {
    const id = await seedObject(env);
    const { token } = await makeLink(env, id);
    await call(env, "GET", "/api/v1/share", { auth: link(token) });
    await call(env, "GET", "/api/v1/share", { auth: link("Q".repeat(43)) });
  } finally { setLogSink(() => {}); }
  const all = lines.join("\n");
  assert.ok(lines.length > 5);
  for (const l of lines) JSON.parse(l);
  assert.ok(!all.includes("Lindvägen"));
  assert.ok(!all.includes(env.photographerKey));
  assert.ok(!all.includes("Q".repeat(43)));
  assert.ok(!/Mäklare Test/.test(all));
  assert.match(all, /"route":"\/api\/v1\/share"/);
});
