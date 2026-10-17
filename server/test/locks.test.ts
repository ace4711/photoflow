// Regi R5: servern skyddar fotografens lås mot mäklarskrivningar.
// Rena tester av lockViolations, webbens regi-operationer på fixturen och HTTP-flödet.

import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { lockFieldErrors, lockViolations } from "../src/locks.ts";
import { parseReelSpec } from "../../web/reel/src/reelSpec.ts";
import type { ReelSpec } from "../../web/reel/src/reelSpec.ts";
import * as regi from "../../web/reel/src/regi.ts";
import { call, link, makeLink, pf, seedObject, SHAS, specBody, startServer, type TestEnv } from "./helpers.ts";

const here = dirname(fileURLToPath(import.meta.url));
const raw = readFileSync(join(here, "../../web/reel/test/fixtures/reel-locks-v1.json"), "utf8");
const load = (): ReelSpec => parseReelSpec(raw);
/** Som servern ser den: JSON-rundtur. */
const wire = (s: ReelSpec): ReelSpec => parseReelSpec(JSON.parse(JSON.stringify(s)));
const ASPECT = 1080 / 1920;
const idx = (s: ReelSpec, id: string) => s.timeline.findIndex((c) => c.asset === id);
const SHA = (ch: string) => ch.repeat(64);
// Fixturen: a2 custom + låst cut, a3 låst övergång (utan transitionIn) + låst längd + pinnad,
// a6 utesluten, tempo calm, orderLocked.

// ------------------------------------------------------------ rena regler

test("en oförändrad spec och en spec utan lås bryter inget", () => {
  assert.deepEqual(lockViolations(load(), load()), []);
  const free = load();
  delete free.editor;
  for (const c of free.timeline) { delete c.transitionLocked; delete c.motionPreset; }
  const n = structuredClone(free);
  n.timeline.reverse();
  n.timeline[0].motion.to.zoom = 1.3;
  n.timeline[1].transitionIn = { type: "push", direction: "left", duration: 0.7 };
  n.timeline[2].fit = "contain-blur";
  assert.deepEqual(lockViolations(free, n), []);
});

test("regel 1: style får inte ändras", () => {
  const n = load();
  n.style.background.amount = 0.9;
  assert.equal(lockViolations(load(), n).length, 1);
  const m = load();
  m.style.defaultTransition = { type: "cut", duration: 0 };
  assert.match(lockViolations(load(), m)[0], /stil/);
});

test("regel 2: tempo, orderLocked och nya pinningar/uteslutningar vägras; borttagning tillåts", () => {
  const tempo = load(); tempo.editor!.tempo = "fast";
  assert.match(lockViolations(load(), tempo).join(), /tempo/);
  const noTempo = load(); delete noTempo.editor!.tempo;
  assert.match(lockViolations(load(), noTempo).join(), /tempo/);
  const order = load(); order.editor!.orderLocked = false;
  assert.match(lockViolations(load(), order).join(), /ordningslås/);
  const pin = load(); pin.editor!.pinnedAssets!.push(SHA("a"));
  assert.match(lockViolations(load(), pin).join(), /låsa bilder/);
  const excl = load(); excl.editor!.excludedAssets!.push(SHA("b"));
  assert.match(lockViolations(load(), excl).join(), /utesluta/);
  // unpin/unexclude: listorna krymper, eller editor försvinner nästan helt
  const drop = load(); delete drop.editor!.pinnedAssets; drop.editor!.excludedAssets = [];
  assert.deepEqual(lockViolations(load(), drop), []);
  // utan editor i föregående revision: mäklaren får inte införa en
  const prev = load(); delete prev.editor;
  const add = load(); add.editor = { tempo: "fast" };
  assert.equal(lockViolations(prev, add).length, 1);
});

test("regel 3: låst övergång är fast så länge bilden finns kvar", () => {
  const changed = load(); changed.timeline[1].transitionIn = { type: "crossfade", duration: 0.5 };
  assert.match(lockViolations(load(), changed).join(), /Bild 2.*övergången/);
  const unlocked = load(); delete unlocked.timeline[1].transitionLocked;
  assert.equal(lockViolations(load(), unlocked).length, 1);
  const filled = load(); filled.timeline[2].transitionIn = { type: "crossfade", duration: 0.5 }; // a3 saknade transitionIn
  assert.equal(lockViolations(load(), filled).length, 1);
  const tiny = load(); tiny.timeline[1].transitionIn!.duration = 1e-12; // inom toleransen
  assert.deepEqual(lockViolations(load(), tiny), []);
  // olåst övergång (a4) får räknas om
  const auto = load(); auto.timeline[3].transitionIn = { type: "push", direction: "right", duration: 0.7 };
  assert.deepEqual(lockViolations(load(), auto), []);
});

test("regel 4: egen rörelse (custom) är fast så länge bilden finns kvar", () => {
  const motion = load(); motion.timeline[1].motion.from.cx = 0.6;
  assert.match(lockViolations(load(), motion).join(), /Bild 2.*egen rörelse/);
  const fit = load(); fit.timeline[1].fit = "contain-blur";
  assert.equal(lockViolations(load(), fit).length, 1);
  const preset = load(); preset.timeline[1].motionPreset = "zoomIn";
  assert.equal(lockViolations(load(), preset).length, 1);
  const near = load(); near.timeline[1].motion.to.cx += 1e-12;
  assert.deepEqual(lockViolations(load(), near), []);
  // längden på ett custom-klipp är inte låst av custom
  const dur = load(); dur.timeline[1].duration = 2.5;
  assert.deepEqual(lockViolations(load(), dur), []);
  // olåst klipps rörelse får ändras
  const other = load(); other.timeline[0].motion.to.zoom = 1.2;
  assert.deepEqual(lockViolations(load(), other), []);
});

test("matchning på sha256: omnumrerade asset-id och flyttade klipp", () => {
  const n = load();
  // byt id på alla bilder (a1→x6, a2→x5, …) och vänd ordningen på assets och tidslinjen
  const map = new Map(n.assets.map((a, i) => [a.id, `x${n.assets.length - i}`]));
  for (const a of n.assets) a.id = map.get(a.id)!;
  n.assets.reverse();
  for (const c of n.timeline) c.asset = map.get(c.asset)!;
  n.timeline.reverse();
  assert.deepEqual(lockViolations(load(), n), []);
  // samma omnumrering men a2:s rörelse ändrad: hittas ändå
  const m = structuredClone(n);
  m.timeline.find((c) => c.asset === map.get("a2"))!.motion.to.zoom = 1.2;
  assert.equal(lockViolations(load(), m).length, 1);
  // klippet pekar på en annan bild med samma id: låset följer bilden, inte id:t
  const swap = load();
  const [a2, a4] = [swap.assets[1], swap.assets[3]];
  [a2.sha256, a4.sha256] = [a4.sha256, a2.sha256]; // nu visar "a2" bild d och "a4" bild b
  assert.ok(lockViolations(load(), swap).length >= 1);
});

test("låst klipp får tas bort helt (både custom och låst övergång)", () => {
  const n = load();
  n.timeline.splice(1, 2); // a2 och a3
  n.editor!.pinnedAssets = []; // unpin av a3
  assert.deepEqual(lockViolations(load(), n), []);
});

// ------------------------------------------------------------ webbens regi på fixturen

test("webbens regi-operationer på reel-locks-v1.json godtas av servern", () => {
  const prev = load();
  const s = load();
  const removed: regi.RemovedClips = new Map();
  const ops: string[] = [];
  ops.push(...regi.moveClip(s, idx(s, "a2"), 0, ASPECT));            // custom + låst övergång först
  ops.push(...regi.moveClip(s, idx(s, "a5"), 1, ASPECT));
  ops.push(...regi.setDuration(s, idx(s, "a1"), 2.2, 10));
  ops.push(...regi.setPreset(s, idx(s, "a4"), "panLeft", ASPECT));   // olåst förval
  ops.push(...regi.addClip(s, "a6", ASPECT, { allowExcluded: true })); // unexclude
  ops.push(...regi.removeClip(s, idx(s, "a3"), ASPECT, removed));    // pinnad + låst övergång: unpin
  assert.ok(ops.includes("unexclude") && ops.includes("unpin"), ops.join());
  assert.deepEqual(lockViolations(prev, wire(s)), []);
  // återställ a3 under sessionen: låsen kommer tillbaka och servern godtar det
  ops.push(...regi.addClip(s, "a3", ASPECT, { removed }));
  ops.push(...regi.moveClip(s, idx(s, "a3"), 2, ASPECT));
  assert.deepEqual(lockViolations(prev, wire(s)), []);
  // och tar bort custom-klippet helt
  regi.removeClip(s, idx(s, "a2"), ASPECT);
  assert.deepEqual(lockViolations(prev, wire(s)), []);
});

test("webbens aktiva byte från egen rörelse till förval vägras av servern (regel 4)", () => {
  const prev = load();
  const s = load();
  assert.deepEqual(regi.setPreset(s, idx(s, "a2"), "zoomIn", ASPECT), ["motion"]);
  assert.match(lockViolations(prev, wire(s)).join(), /egen rörelse/);
});


test("fynd: en pinnad bild som läggs tillbaka efter sparad borttagning får sin pinning igen", () => {
  const photographer = load();
  const pins = photographer.editor!.pinnedAssets!;
  const s = load();
  const removed: regi.RemovedClips = new Map();
  assert.ok(regi.removeClip(s, idx(s, "a3"), ASPECT, removed).includes("unpin"));
  const saved = wire(s);
  assert.deepEqual(lockViolations(photographer, saved, { restorablePins: pins }), []);
  // samma session: webbens `removed` finns kvar, a3 läggs tillbaka med pinningen
  assert.ok(regi.addClip(s, "a3", ASPECT, { removed }).includes("pin"));
  assert.deepEqual(lockViolations(saved, wire(s), { restorablePins: pins }), []);
  // en bild fotografen aldrig pinnade får fortfarande inte pinnas
  const other = wire(s); other.editor!.pinnedAssets!.push(SHA("a"));
  assert.match(lockViolations(saved, other, { restorablePins: pins }).join(), /låsa bilder/);
});

test("fynd: en oförändrad kopia av ett låst klipp skyddar inte en ändrad", () => {
  // kopia av a2 (custom + låst övergång) först, och det riktiga klippet ändras
  const decoy = load();
  const real = decoy.timeline[idx(decoy, "a2")];
  decoy.timeline.unshift({ ...structuredClone(real), duration: 0.5 });
  real.transitionIn = { type: "crossfade", duration: 0.5 };
  real.motionPreset = "zoomIn";
  const v = lockViolations(load(), decoy);
  assert.ok(v.length >= 1, v.join());
  // samma bild via ett andra asset-id med samma sha256
  const alias = load();
  alias.assets.push({ ...structuredClone(alias.assets.find((a) => a.id === "a2")!), id: "a2b" });
  alias.timeline.unshift({ ...structuredClone(alias.timeline[idx(alias, "a2")]), asset: "a2b", duration: 0.5 });
  alias.timeline[idx(alias, "a2")].motion.to.zoom = 1.4;
  assert.ok(lockViolations(load(), alias).length >= 1);
  // en ren kopia (utan ändring) är också ett tillägg av en låst bild
  const copy = load();
  copy.timeline.push(structuredClone(copy.timeline[idx(copy, "a2")]));
  assert.match(lockViolations(load(), copy).join(), /en gång till/);
  // fotografens version har bilden två gånger, båda låsta: den andra skyddas också
  const prev2 = load();
  const second = { ...structuredClone(prev2.timeline[idx(prev2, "a2")]), duration: 1 };
  second.motion.to.zoom = 1.2;
  prev2.timeline.push(second);
  const n2 = structuredClone(prev2);
  n2.timeline[n2.timeline.length - 1].motion.to.zoom = 1.3;
  assert.match(lockViolations(prev2, n2).join(), /egen rörelse/);
  // flytt av dubbletterna och borttagning av den ena är tillåtet
  const n3 = structuredClone(prev2);
  n3.timeline.reverse();
  assert.deepEqual(lockViolations(prev2, n3), []);
  const n4 = structuredClone(prev2);
  n4.timeline.splice(idx(n4, "a2"), 1);
  assert.deepEqual(lockViolations(prev2, n4), []);
});

// ------------------------------------------------------------ HTTP

let env: TestEnv;
before(async () => { env = await startServer(); });
after(async () => { await env.close(); });

const put = (id: string, body: unknown, rev: number) =>
  call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body, headers: { "If-Match": `"${rev}"` } });
const share = (token: string, body: unknown, rev: number) =>
  call(env, "PUT", "/api/v1/share/spec", { auth: link(token), body, headers: { "If-Match": `"${rev}"` } });

function lockedBody() {
  const b = specBody([0, 1, 2], { editor: { pinnedAssets: [SHAS[1]], excludedAssets: [SHAS[3]], orderLocked: true, tempo: "calm" } });
  const tl = b.timeline as any[];
  Object.assign(tl[1], {
    motionPreset: "custom", transitionLocked: true, transitionIn: { type: "cut", duration: 0 },
    motion: { from: { cx: 0.62, cy: 0.55, zoom: 1.05 }, to: { cx: 0.33, cy: 0.52, zoom: 1.05 } },
  });
  Object.assign(tl[2], { transitionLocked: true });
  return b;
}

async function lockedObject(): Promise<{ id: string; token: string }> {
  const id = await seedObject(env);
  const w = await put(id, lockedBody(), 1);
  assert.equal(w.status, 200, w.text);
  const { token } = await makeLink(env, id);
  return { id, token };
}

const current = async (token: string) => (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json.spec;

test("HTTP: mäklarens brott mot låsen ger 422 invalid_spec med svenskt meddelande, inget sparas", async () => {
  const { id, token } = await lockedObject();
  const cases: Array<(s: any) => void> = [
    (s) => { s.style.easing = "linear"; },
    (s) => { s.editor.tempo = "fast"; },
    (s) => { s.editor.orderLocked = false; },
    (s) => { s.editor.pinnedAssets.push(SHAS[0]); },
    (s) => { s.editor.excludedAssets.push(SHAS[0]); },
    (s) => { s.timeline[1].transitionIn = { type: "crossfade", duration: 0.5 }; },
    (s) => { delete s.timeline[2].transitionLocked; },
    (s) => { s.timeline[1].motion.to.cx = 0.4; },
    (s) => { s.timeline[1].motionPreset = "zoomIn"; },
  ];
  for (const [i, f] of cases.entries()) {
    const s = await current(token);
    f(s);
    const r = await share(token, s, 2);
    assert.equal(r.status, 422, `fall ${i}: ${r.text}`);
    assert.equal(r.json.error.code, "invalid_spec");
    assert.match(r.json.error.message, /^Mäklaren får inte ändra fotografens lås\./);
    assert.ok(Array.isArray(r.json.lockViolations) && r.json.lockViolations.length >= 1);
  }
  const o = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json;
  assert.equal(o.spec.revision, 2);
});

test("HTTP: mäklaren får flytta, ta bort låsta klipp med unpin, ändra olåst och omnumrera id", async () => {
  const { id, token } = await lockedObject();
  // flytta och ändra olåst klipp
  let s = await current(token);
  s.timeline = [s.timeline[1], s.timeline[0], s.timeline[2]];
  s.timeline[1].duration = 2.2; s.timeline[1].durationLocked = true;
  s.timeline[1].motion.to.zoom = 1.2;
  s.timeline[1].transitionIn = { type: "crossfade", duration: 0.5 };
  let r = await share(token, s, 2);
  assert.equal(r.status, 200, r.text);
  // omnumrera asset-id (a1↔a3 byter id)
  s = await current(token);
  const ren: Record<string, string> = { a1: "a3", a2: "a2", a3: "a1" };
  for (const a of s.assets) a.id = ren[a.id] ?? a.id;
  for (const c of s.timeline) c.asset = ren[c.asset];
  r = await share(token, s, 3);
  assert.equal(r.status, 200, r.text);
  // ta bort custom-klippet (pinnat, låst övergång) och släpp pinningen; släpp uteslutningen
  s = await current(token);
  s.timeline = s.timeline.filter((c: any) => c.motionPreset !== "custom");
  s.editor = { orderLocked: true, tempo: "calm" };
  r = await share(token, s, 4);
  assert.equal(r.status, 200, r.text);
  const stored = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json.spec;
  assert.equal(stored.revision, 5);
  assert.deepEqual(stored.editor, { orderLocked: true, tempo: "calm" });
});

test("HTTP: fotografen får ändra allt, även låsta fält", async () => {
  const { id } = await lockedObject();
  const s = lockedBody() as any;
  s.style.easing = "linear";
  s.editor = { pinnedAssets: [SHAS[0], SHAS[2]], excludedAssets: [SHAS[1]], orderLocked: false, tempo: "fast" };
  s.timeline[1].motion.to.cx = 0.4;
  s.timeline[1].motionPreset = "zoomIn";
  s.timeline[1].transitionIn = { type: "crossfade", duration: 0.5 };
  delete s.timeline[2].transitionLocked;
  const r = await put(id, s, 2);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.revision ?? 3, 3);
});

test("HTTP: utan lås beter sig mäklarens sparning som förut", async () => {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  const s = await current(token);
  s.timeline.reverse();
  s.timeline[0].motion.to.zoom = 1.3;
  s.timeline[1].transitionIn = { type: "push", direction: "left", duration: 0.7 };
  const r = await share(token, s, 1);
  assert.equal(r.status, 200, r.text);
});

test("fynd: inaktuell mäklarsparning ger 412 även när fotografen har lagt till lås", async () => {
  const { id, token } = await lockedObject();
  const stale = await current(token); // rev 2
  // fotografen ändrar tempo och låser övergången på klipp 1
  const pfSpec = lockedBody() as any;
  pfSpec.editor.tempo = "fast";
  Object.assign(pfSpec.timeline[0], { transitionLocked: true });
  pfSpec.timeline[0].motion.to.zoom = 1.25;
  assert.equal((await put(id, pfSpec, 2)).status, 200);
  stale.timeline[0].motion.to.zoom = 1.3;
  const r = await share(token, stale, 2);
  assert.equal(r.status, 412, r.text);
  assert.equal(r.json.error.code, "revision_conflict");
  // och en inaktuell ändring av utbildsprofilerna ger också 412
  stale.outputs[0].fps = 25;
  assert.equal((await share(token, stale, 2)).status, 412);
});

test("fynd: mäklaren kan lägga tillbaka en pinnad bild efter att borttagningen sparats", async () => {
  const { id, token } = await lockedObject();
  let s = await current(token);
  const kept = structuredClone(s.timeline[1]); // pinnad, custom, låst övergång
  s.timeline.splice(1, 1);
  s.editor.pinnedAssets = [];
  let r = await share(token, s, 2);
  assert.equal(r.status, 200, r.text);
  s = await current(token);
  s.timeline.splice(1, 0, kept);
  s.editor.pinnedAssets = [SHAS[1]];
  r = await share(token, s, 3);
  assert.equal(r.status, 200, r.text);
  // en bild som fotografen inte har pinnat får inte pinnas
  s = await current(token);
  s.editor.pinnedAssets.push(SHAS[0]);
  assert.equal((await share(token, s, 4)).status, 422);
  // tar fotografen bort pinningen kan mäklaren inte införa den igen
  const pfSpec = (await call(env, "GET", `/api/v1/objects/${id}`, { auth: pf(env) })).json.spec;
  pfSpec.editor.pinnedAssets = [];
  assert.equal((await put(id, pfSpec, 4)).status, 200);
  s = await current(token);
  s.editor.pinnedAssets = [SHAS[1]];
  r = await share(token, s, 5);
  assert.equal(r.status, 422, r.text);
  assert.match(r.json.error.message, /låsa bilder/);
});

test("fynd: redigerarens fält typkontrolleras för båda rollerna", async () => {
  const { id, token } = await lockedObject();
  const cases: Array<(s: any) => void> = [
    (s) => { s.editor.pinnedAssets = "x"; },
    (s) => { s.editor.excludedAssets = [1]; },
    (s) => { s.editor = "foo"; },
    (s) => { s.editor.orderLocked = "true"; },
    (s) => { s.editor.tempo = 2; },
    (s) => { s.timeline[0].transitionLocked = "yes"; },
    (s) => { s.timeline[0].durationLocked = 1; },
    (s) => { s.timeline[0].motionPreset = 3; },
  ];
  for (const [i, f] of cases.entries()) {
    const s = await current(token);
    f(s);
    const r = await share(token, s, 2);
    assert.equal(r.status, 422, `mäklare, fall ${i}: ${r.text}`);
    const p = lockedBody() as any;
    f(p);
    const q = await put(id, p, 2);
    assert.equal(q.status, 422, `fotograf, fall ${i}: ${q.text}`);
  }
  // null och saknade fält är tillåtna
  const ok = lockedBody() as any;
  ok.timeline[0].transitionLocked = null; ok.editor.tempo = null;
  assert.equal((await put(id, ok, 2)).status, 200);
  assert.deepEqual(lockFieldErrors({ editor: null, timeline: [{}] }), []);
});
