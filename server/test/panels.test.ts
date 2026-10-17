// Regi R6e: servern godtar spec version 2 (rutklipp: kollage och montage), validerar rutfälten
// och skyddar fotografens rutklipp mot mäklaren. Fixturen delas med webben
// (web/reel/test/fixtures/reel-panels-v2.json): a1 cover, a2+a3 kollage (stack),
// a4 montage (sequence), a5 cover, a6 cover.

import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { lockFieldErrors, lockViolations } from "../src/locks.ts";
import { parseReelSpec } from "../../web/reel/src/reelSpec.ts";
import type { ReelSpec } from "../../web/reel/src/reelSpec.ts";
import * as regi from "../../web/reel/src/regi.ts";
import { call, link, makeLink, pf, seedObject, specBody, startServer, type TestEnv } from "./helpers.ts";

const here = dirname(fileURLToPath(import.meta.url));
const raw = readFileSync(join(here, "../../web/reel/test/fixtures/reel-panels-v2.json"), "utf8");
const load = (): ReelSpec => parseReelSpec(raw);
const wire = (s: ReelSpec): ReelSpec => parseReelSpec(JSON.parse(JSON.stringify(s)));
const ASPECT = 1080 / 1920;
const idx = (s: ReelSpec, id: string) => s.timeline.findIndex((c) => c.asset === id);

// ------------------------------------------------------------ rena regler

test("rutklipp: oförändrade, flyttade och omlängdsatta rutklipp bryter inget", () => {
  const prev = load();
  const n = load();
  n.timeline.reverse();
  n.timeline.find((c) => c.asset === "a2")!.duration = 5;
  n.timeline.find((c) => c.asset === "a4")!.durationLocked = true;
  assert.deepEqual(lockViolations(prev, n), []);
});

test("rutklipp: omnumrerade asset-id matchas på sha256", () => {
  const prev = load();
  const n = load();
  const map = new Map(n.assets.map((a, i) => [a.id, `x${n.assets.length - i}`]));
  const remap = (id: string) => map.get(id)!;
  for (const a of n.assets) a.id = remap(a.id);
  for (const c of n.timeline) {
    c.asset = remap(c.asset);
    for (const p of c.panels ?? []) p.asset = remap(p.asset);
  }
  assert.deepEqual(lockViolations(prev, n), []);
});

test("rutklipp: ändrad layout, gutter, entrance, ruta, source, fit eller rörelse bryter låset", () => {
  const cases: Array<[string, (s: ReelSpec) => void]> = [
    ["layout", (s) => { s.timeline[1].layout = "side"; }],
    ["gutter", (s) => { s.timeline[1].gutter = 0.02; }],
    ["entrance", (s) => { s.timeline[1].entrance = { type: "fade" }; }],
    ["entrance borttagen", (s) => { delete s.timeline[1].entrance; }],
    ["ruta bytt bild", (s) => { s.timeline[1].panels![1].asset = "a5"; }],
    ["rutornas ordning", (s) => { s.timeline[1].panels!.reverse(); }],
    ["source", (s) => { s.timeline[2].panels![0].source = { x: 0, y: 0, w: 0.4, h: 1 }; }],
    ["ruta motion", (s) => { s.timeline[1].panels![0].motion.to.zoom = 1.2; }],
    ["fit", (s) => { s.timeline[1].fit = "cover"; }],
  ];
  for (const [name, f] of cases) {
    const n = load();
    f(n);
    const v = lockViolations(load(), n);
    assert.ok(v.length >= 1, name);
    assert.match(v.join(), /fotografens/, name);
  }
});

test("rutklipp: mäklaren får ta bort men inte skapa rutklipp", () => {
  const prev = load();
  const n = load();
  n.timeline.splice(1, 2); // kollaget och montaget borta
  assert.deepEqual(lockViolations(prev, n), []);
  // nytt kollage av bilder som inte var ett rutklipp
  const m = load();
  const c = m.timeline[3]; // a5
  Object.assign(c, { fit: "panels", layout: "stack", panels: structuredClone(m.timeline[1].panels), asset: "a5" });
  c.panels![0].asset = "a5"; c.panels![1].asset = "a6";
  assert.match(lockViolations(prev, m).join(), /bara fotografen kan göra kollage/i);
  // en kopia av ett befintligt rutklipp är också ett nytt
  const k = load();
  k.timeline.push(structuredClone(k.timeline[1]));
  assert.match(lockViolations(prev, k).join(), /fotografens/);
  // rutklipp i en fotografversion utan rutor kan inte heller läggas till
  const v1 = load();
  v1.timeline = v1.timeline.filter((x) => x.fit !== "panels");
  assert.match(lockViolations(v1, load()).join(), /bara fotografen/i);
});

test("rutklipp: en borttagen kollagebild får bli ett vanligt klipp", () => {
  const prev = load();
  const n = load();
  n.timeline.splice(1, 1);
  n.timeline.push({ ...structuredClone(prev.timeline[0]), asset: "a2" });
  n.timeline.push({ ...structuredClone(prev.timeline[0]), asset: "a3" });
  assert.deepEqual(lockViolations(prev, n), []);
});

test("rutfält: typkontroll av layout, panels, asset, source, gutter och entrance", () => {
  assert.deepEqual(lockFieldErrors(JSON.parse(raw)), []);
  const bad = (f: (s: any) => void) => { const s = JSON.parse(raw); f(s); return lockFieldErrors(s).join(" "); };
  assert.match(bad((s) => { s.timeline[1].layout = "grid"; }), /layout/);
  assert.match(bad((s) => { s.timeline[1].panels.pop(); }), /exakt två/);
  assert.match(bad((s) => { s.timeline[2].panels = [s.timeline[2].panels[0]]; }), /minst två/);
  assert.match(bad((s) => { s.timeline[1].panels[1].asset = "zzz"; }), /assets/);
  assert.match(bad((s) => { s.timeline[2].panels[0].source = { x: 0.8, y: 0, w: 0.5, h: 1 }; }), /source/);
  assert.match(bad((s) => { s.timeline[1].gutter = "bred"; }), /gutter/);
  assert.match(bad((s) => { s.timeline[1].entrance = { type: "spin" }; }), /entrance/);
  assert.match(bad((s) => { s.timeline[1].entrance = { type: "slide", stagger: "x" }; }), /stagger/);
  assert.match(bad((s) => { s.minReaderVersion = 1; }), /minReaderVersion 2/);
});

test("webbens regi-operationer på rutfixturen godtas av servern", () => {
  const prev = load();
  const s = load();
  const removed: regi.RemovedClips = new Map();
  regi.moveClip(s, idx(s, "a4"), 0, ASPECT);
  regi.moveClip(s, idx(s, "a2"), 3, ASPECT);
  regi.setDuration(s, idx(s, "a2"), 4.2, 10);
  regi.setPreset(s, idx(s, "a5"), "panLeft", ASPECT);
  assert.deepEqual(lockViolations(prev, wire(s)), []);
  regi.removeClip(s, idx(s, "a2"), ASPECT, removed);
  assert.deepEqual(lockViolations(prev, wire(s)), []);
  regi.addClip(s, "a2", ASPECT, { removed }); // hela kollaget tillbaka
  assert.deepEqual(lockViolations(prev, wire(s)), []);
  regi.removeClip(s, idx(s, "a4"), ASPECT, removed);
  regi.removeClip(s, idx(s, "a2"), ASPECT, removed);
  regi.addClip(s, "a3", ASPECT, { removed }); // rutornas bild som vanligt klipp
  assert.deepEqual(lockViolations(prev, wire(s)), []);
});

test("v1 utan rutor: samma regler som förut", () => {
  const v1 = parseReelSpec(readFileSync(join(here, "../../web/reel/test/fixtures/reel-locks-v1.json"), "utf8"));
  assert.deepEqual(lockViolations(v1, wire(v1)), []);
  assert.deepEqual(lockFieldErrors(JSON.parse(JSON.stringify(v1))), []);
});

// ------------------------------------------------------------ HTTP

let env: TestEnv;
before(async () => { env = await startServer(); });
after(async () => { await env.close(); });

const put = (id: string, body: unknown, rev: number) =>
  call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body, headers: { "If-Match": `"${rev}"` } });
const share = (token: string, body: unknown, rev: number) =>
  call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body, headers: { "If-Match": `"${rev}"` } });
const current = async (token: string) => (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;

const pm = { from: { cx: 0.5, cy: 0.5, zoom: 1 }, to: { cx: 0.5, cy: 0.5, zoom: 1.04 } };
/** a1 cover, a2+a3 kollage (stack), a1 igen är inte med: poolen har a1..a3. */
function panelsBody() {
  const b = specBody([0, 1], { version: 2, minReaderVersion: 2 });
  const tl = b.timeline as any[];
  Object.assign(tl[1], {
    fit: "panels", layout: "stack", gutter: 0.006, entrance: { type: "slide", stagger: 0.3 }, motion: pm,
    panels: [{ asset: "a2", source: null, motion: pm }, { asset: "a3", source: null, motion: pm }],
  });
  return b;
}

test("HTTP: fotografen sparar v2 med rutklipp; mäklaren läser, flyttar, ändrar längd och tar bort", async () => {
  const id = await seedObject(env);
  const w = await put(id, panelsBody(), 1);
  assert.equal(w.status, 200, w.text);
  assert.equal(w.json.spec.timeline[1].layout, "stack");
  assert.equal(w.json.spec.minReaderVersion, 2);
  const { token } = await makeLink(env, id);
  let s = await current(token);
  assert.equal(s.timeline[1].panels.length, 2);
  // alla rutornas bilder har en källa mäklaren kan hämta
  for (const a of s.assets) assert.equal(a.sources.length, 1, a.id);
  s.timeline = [s.timeline[1], s.timeline[0]];
  s.timeline[0].duration = 4;
  let r = await share(token, s, 2);
  assert.equal(r.status, 200, r.text);
  assert.equal((await current(token)).timeline[0].panels[1].asset, "a3");
  // ändrade rutor vägras och sparas inte
  s = await current(token);
  s.timeline[0].gutter = 0.05;
  r = await share(token, s, 3);
  assert.equal(r.status, 422);
  assert.equal(r.json.error.code, "invalid_spec");
  assert.match(r.json.error.message, /^Mäklaren får inte ändra fotografens lås\./);
  // nytt rutklipp vägras
  s = await current(token);
  s.timeline.push({ ...structuredClone(s.timeline[1]), asset: "a1", fit: "panels", layout: "side", panels: [
    { asset: "a1", motion: pm }, { asset: "a3", motion: pm }] });
  r = await share(token, s, 3);
  assert.equal(r.status, 422);
  // ta bort rutklippet är tillåtet
  s = await current(token);
  s.timeline = s.timeline.filter((c: any) => c.fit !== "panels");
  r = await share(token, s, 3);
  assert.equal(r.status, 200, r.text);
});

test("HTTP: ogiltiga rutfält ger 422 invalid_spec för fotografen", async () => {
  const id = await seedObject(env);
  const cases: Array<(b: any) => void> = [
    (b) => { b.timeline[1].layout = "grid"; },
    (b) => { b.timeline[1].panels.pop(); },
    (b) => { b.timeline[1].panels[1].asset = "a9"; },
    (b) => { b.timeline[1].panels[0].source = { x: 0.6, y: 0, w: 0.6, h: 1 }; },
    (b) => { b.timeline[1].gutter = "x"; },
    (b) => { b.timeline[1].entrance = { type: "spin" }; },
    (b) => { b.minReaderVersion = 1; },
  ];
  for (const [i, f] of cases.entries()) {
    const b = panelsBody();
    f(b);
    const r = await put(id, b, 1);
    assert.equal(r.status, 422, `fall ${i}: ${r.text}`);
    assert.equal(r.json.error.code, "invalid_spec");
  }
});
