// R5: webben respekterar fotografens lås (custom, transitionLocked, durationLocked,
// editor {pinnedAssets, excludedAssets, orderLocked, tempo}). Fixturen
// test/fixtures/reel-locks-v1.json är handskriven efter Swift-kodningen i ReelSpec.swift.
// Samma fixtur läses av PhotoFlow/Tests/ReelWebParityTests.swift (Swift-sidan av rundturen).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { parseReelSpec } from "../src/reelSpec.ts";
import type { Clip, ReelSpec } from "../src/reelSpec.ts";
import { approvedCopy, editedCopy, sortKeys } from "../src/approve.ts";
import {
  CUSTOM, MAX_CLIPS, automaticTransition, panSign, planClip, tempoFactor, tempoOf,
} from "../src/motionPresets.ts";
import * as regi from "../src/regi.ts";

const here = dirname(fileURLToPath(import.meta.url));
const raw = readFileSync(join(here, "fixtures/reel-locks-v1.json"), "utf8");
const load = (): ReelSpec => parseReelSpec(raw);
const ASPECT = 1080 / 1920;
const near = (a: number, b: number, what: string): void => assert.ok(Math.abs(a - b) < 1e-9, `${what}: ${a} != ${b}`);
const byAsset = (s: ReelSpec, id: string): Clip => s.timeline.find((c) => c.asset === id)!;
const order = (s: ReelSpec): string[] => s.timeline.map((c) => c.asset);

// ------------------------------------------------------------ rundtur

test("rundtur: alla nya fält bevaras genom parse → editedCopy → sortKeys → JSON → parse", () => {
  const original = JSON.parse(raw);
  const spec = load();
  const out = editedCopy(spec, ["duration"], "Maja", "2026-10-17T08:00:00Z");
  const back = parseReelSpec(JSON.stringify(sortKeys(out), null, 2));
  assert.deepEqual(back.editor, original.editor);
  assert.deepEqual(back.timeline, original.timeline);
  assert.deepEqual(back.assets, original.assets);
  assert.deepEqual(back.style, original.style);
  // Bara metadata om ändringen skiljer.
  const strip = (s: Record<string, unknown>) => {
    const { updatedAt, updatedBy, provenance, ...rest } = s;
    return rest;
  };
  assert.deepEqual(strip(back as Record<string, unknown>), strip(original));
  const approved = parseReelSpec(JSON.stringify(sortKeys(approvedCopy(spec, [], "", "2026-10-17T08:00:00Z"))));
  assert.deepEqual(approved.editor, original.editor);
  assert.deepEqual(approved.timeline, original.timeline);
});

test("rundtur: fixturen har alla låsfält", () => {
  const s = load();
  assert.equal(byAsset(s, "a2").motionPreset, CUSTOM);
  assert.equal(byAsset(s, "a2").transitionLocked, true);
  assert.deepEqual(byAsset(s, "a2").transitionIn, { type: "cut", duration: 0 });
  assert.equal(byAsset(s, "a3").transitionLocked, true);
  assert.equal(byAsset(s, "a3").transitionIn, undefined);
  assert.equal(byAsset(s, "a3").durationLocked, true);
  const e = regi.editorOf(s);
  assert.equal(e.orderLocked, true);
  assert.equal(e.tempo, "calm");
  assert.equal(e.pinned.size, 1);
  assert.equal(e.excluded.size, 1);
});

test("redigering rör inte editor-objektet eller låsta fält i övrigt", () => {
  const s = load();
  const editor = structuredClone(s.editor);
  const a2 = structuredClone(byAsset(s, "a2"));
  const a3 = structuredClone(byAsset(s, "a3"));
  regi.moveClip(s, 4, 0, ASPECT);
  regi.setDuration(s, 0, 2.2, 10);
  regi.addClip(s, "a7", ASPECT);
  regi.moveClip(s, 5, 1, ASPECT);
  regi.removeClip(s, s.timeline.findIndex((c) => c.asset === "a1"), ASPECT);
  assert.deepEqual(s.editor, editor);
  const n2 = byAsset(s, "a2"), n3 = byAsset(s, "a3");
  assert.deepEqual(n2.motion, a2.motion);
  assert.equal(n2.fit, a2.fit);
  assert.equal(n2.motionPreset, CUSTOM);
  assert.deepEqual(n2.transitionIn, a2.transitionIn);
  assert.equal(n2.transitionLocked, true);
  assert.deepEqual(n3, a3); // låst längd, låst övergång, oförändrad rörelse (bytte inte roll med låst längd)
  // Och det överlever serialiseringen.
  const back = parseReelSpec(JSON.stringify(sortKeys(editedCopy(s, [], "", "2026-10-17T08:00:00Z"))));
  assert.deepEqual(back.editor, editor);
  assert.deepEqual(byAsset(back, "a2").transitionIn, a2.transitionIn);
});

// ------------------------------------------------------------ custom

test("custom bevaras vid omordning och längdändring", () => {
  const s = load();
  const before = structuredClone(byAsset(s, "a2"));
  regi.moveClip(s, 1, 3, ASPECT);
  assert.deepEqual(byAsset(s, "a2").motion, before.motion);
  assert.equal(byAsset(s, "a2").motionPreset, CUSTOM);
  regi.setDuration(s, 3, 5.0, 10);
  const c = byAsset(s, "a2");
  assert.deepEqual(c.motion, before.motion);
  assert.equal(c.fit, before.fit);
  assert.equal(c.motionPreset, CUSTOM);
  assert.equal(c.duration, 5);
  assert.equal(c.durationLocked, true);
});

test("custom sist: olåst längd räknas om (pan, sista, lugnt), rörelsen behålls", () => {
  const s = load();
  const before = structuredClone(byAsset(s, "a2"));
  regi.moveClip(s, 1, 4, ASPECT);
  const c = byAsset(s, "a2");
  assert.deepEqual(c.motion, before.motion);
  near(c.duration, 3.4 * 1.2, "längd");
});

test("planClip med auto behåller en egen rörelse; ett aktivt förval ersätter den", () => {
  const s = load();
  const c = byAsset(s, "a2");
  const asset = s.assets.find((a) => a.id === "a2")!;
  const p = planClip({ asset, frameAspect: ASPECT, preset: "auto", index: 1, count: 5, current: c, lockedDuration: 3 });
  assert.deepEqual(p.motion, c.motion);
  assert.equal(p.fit, c.fit);
  assert.equal(p.duration, 3);
  // setPreset med CUSTOM gör ingenting (inget menyval).
  assert.deepEqual(regi.setPreset(s, 1, CUSTOM, ASPECT), []);
  assert.equal(byAsset(s, "a2").motionPreset, CUSTOM);
  // Mäklarens aktiva val av förval ersätter.
  assert.deepEqual(regi.setPreset(s, 1, "zoomIn", ASPECT), ["motion"]);
  const z = byAsset(s, "a2");
  assert.equal(z.motionPreset, "zoomIn");
  assert.ok(z.motion.to.zoom > z.motion.from.zoom);
  assert.deepEqual(z.transitionIn, { type: "cut", duration: 0 }, "den låsta övergången rörs inte av förvalet");
});

test("Automatisk på ett custom-klipp släpper fotografens rörelse aktivt", () => {
  const s = load();
  regi.setPreset(s, 1, "auto", ASPECT);
  const c = byAsset(s, "a2");
  assert.equal(c.motionPreset, undefined);
  assert.notDeepEqual(c.motion, JSON.parse(raw).timeline[1].motion);
});

// ------------------------------------------------------------ övergångar

test("automaticTransition och panSign som i ReelMotionPlanner", () => {
  const cf = { type: "crossfade" as const, duration: 0.5 };
  assert.deepEqual(automaticTransition(0, false, cf), { type: "crossfade", duration: 0.5 });
  assert.deepEqual(automaticTransition(1, false, cf), { type: "push", direction: "left", duration: 0.5 });
  assert.deepEqual(automaticTransition(-1, false, cf), { type: "push", direction: "right", duration: 0.5 });
  assert.deepEqual(automaticTransition(1, true, cf), { type: "crossfade", duration: 0.5 * (0.6 / 0.5) });
  assert.deepEqual(automaticTransition(0, true, { type: "crossfade", duration: 1.4 }), { type: "crossfade", duration: 1.5 });
  assert.deepEqual(automaticTransition(1, true, { type: "cut", duration: 0 }), { type: "cut", duration: 0 });
  assert.deepEqual(automaticTransition(1, false, { type: "fadeThroughBlack", duration: 0.8 }), { type: "fadeThroughBlack", duration: 0.8 });

  const m = (dx: number, dz = 0) => ({ from: { cx: 0.5, cy: 0.5, zoom: 1 }, to: { cx: 0.5 + dx, cy: 0.5, zoom: 1 + dz } });
  assert.equal(panSign({ fit: "cover", motion: m(0.2) }), 1);
  assert.equal(panSign({ fit: "cover", motion: m(-0.2) }), -1);
  assert.equal(panSign({ fit: "cover", motion: m(0.2, 0.1) }), 0, "zoom räknas inte som panorering");
  assert.equal(panSign({ fit: "contain-blur", motion: m(0.2) }), 0);
  assert.equal(panSign({ fit: "cover", motion: m(0.01, 0.1), motionPreset: CUSTOM }), 0, "custom under 0,02 i sidled");
  assert.equal(panSign({ fit: "cover", motion: m(-0.03, 0.1), motionPreset: CUSTOM }), -1, "custom med zoom och sidled");
});

test("transitionLocked följer klippet vid omordning; automatiska övergångar räknas om", () => {
  const s = load();
  regi.moveClip(s, 1, 0, ASPECT); // a2 (custom, panorerar vänster, låst cut) först
  assert.deepEqual(order(s), ["a2", "a1", "a3", "a4", "a5"]);
  assert.deepEqual(byAsset(s, "a2").transitionIn, { type: "cut", duration: 0 }, "låst övergång kvar även på plats 0");
  assert.deepEqual(byAsset(s, "a1").transitionIn, { type: "push", direction: "right", duration: 0.5 },
    "efter en panorering åt vänster: skjut åt höger");
  assert.equal(byAsset(s, "a3").transitionIn, undefined, "låst standardövergång förblir utan transitionIn");
  assert.equal(byAsset(s, "a3").transitionLocked, true);
  assert.deepEqual(byAsset(s, "a5").transitionIn, { type: "crossfade", duration: 0.5 * (0.6 / 0.5) });

  regi.moveClip(s, 2, 4, ASPECT); // a3 sist
  assert.deepEqual(order(s), ["a2", "a1", "a4", "a5", "a3"]);
  assert.equal(byAsset(s, "a3").transitionIn, undefined);
  assert.deepEqual(byAsset(s, "a5").transitionIn, { type: "crossfade", duration: 0.5 }, "inte längre sista: vanlig tona");
});

test("ett tidigare första klipp får automatisk övergång; nytt första klipp utan lås får ingen", () => {
  const s = load();
  regi.moveClip(s, 3, 0, ASPECT); // a4 (zoomIn) först
  assert.deepEqual(order(s), ["a4", "a1", "a2", "a3", "a5"]);
  assert.equal(byAsset(s, "a4").transitionIn, undefined);
  assert.deepEqual(byAsset(s, "a1").transitionIn, { type: "crossfade", duration: 0.5 });
  // Roller: a4 blev första (lugnt tempo), a1 blev mitten (zoom).
  near(byAsset(s, "a4").duration, 3.0 * 1.2, "a4");
  near(byAsset(s, "a1").duration, 2.5 * 1.2, "a1");
  assert.equal(byAsset(s, "a4").motionPreset, "zoomIn");
  assert.equal(byAsset(s, "a1").motionPreset, undefined);
});

// ------------------------------------------------------------ tempo

test("tempo skalar automatiska längder i planClip men inte låsta", () => {
  assert.equal(tempoOf("calm"), "calm");
  assert.equal(tempoOf("rapid"), "normal");
  assert.equal(tempoOf(undefined), "normal");
  assert.equal(tempoFactor("fast"), 0.85);
  const s = load();
  const asset = s.assets.find((a) => a.id === "a3")!; // smalt motiv: zoom
  const d = (tempo: number, index: number, lockedDuration?: number) =>
    planClip({ asset, frameAspect: ASPECT, preset: "zoomIn", index, count: 5, tempo, lockedDuration }).duration;
  near(d(1, 2), 2.5, "normal mitten");
  near(d(1.2, 2), 3.0, "lugnt mitten");
  near(d(0.85, 2), 2.125, "snabbt mitten");
  near(d(1.2, 0), 3.6, "lugnt först");
  near(d(0.85, 4), 3.4 * 0.85, "snabbt sist");
  assert.equal(d(1.2, 2, 2.0), 2.0, "låst längd påverkas inte");
  assert.equal(d(0.85, 4, 4.0), 4.0);
});

test("tillägg använder filmens tempo, och förra sista klippet får mittenlängd", () => {
  const s = load();
  assert.deepEqual(regi.addClip(s, "a7", ASPECT), ["add"]);
  const n = byAsset(s, "a7");
  near(n.duration, 3.4 * 1.2, "nytt sista");
  near(byAsset(s, "a5").duration, 2.6 * 1.2, "a5 (contain) i mitten");
  assert.equal(byAsset(s, "a5").fit, "contain-blur");
  assert.deepEqual(n.transitionIn, { type: "crossfade", duration: 0.5 * (0.6 / 0.5) });
  assert.deepEqual(byAsset(s, "a5").transitionIn, { type: "crossfade", duration: 0.5 });
});

test("setPreset använder tempot för olåst längd", () => {
  const s = load();
  regi.setPreset(s, 3, "panLeft", ASPECT); // a4, mitten, olåst
  near(byAsset(s, "a4").duration, 2.8 * 1.2, "panorering, lugnt");
  regi.setPreset(s, 2, "zoomOut", ASPECT); // a3, låst längd
  assert.equal(byAsset(s, "a3").duration, 4.0);
  // a4 panorerar nu åt vänster → a5:s automatiska övergång blir … fortfarande sista: lång tona.
  assert.deepEqual(byAsset(s, "a5").transitionIn, { type: "crossfade", duration: 0.5 * (0.6 / 0.5) });
});

// ------------------------------------------------------------ urval

test(`tak på ${MAX_CLIPS} klipp`, () => {
  const s = load();
  const base = s.assets[0];
  for (let k = 0; s.assets.length < MAX_CLIPS + 2; k++) {
    s.assets.push({ ...structuredClone(base), id: `x${k}`, sha256: `sha-x${k}` });
  }
  for (const a of s.assets) {
    if (!regi.canAddMore(s)) break;
    if (s.timeline.some((c) => c.asset === a.id) || regi.isExcluded(s, a)) continue;
    regi.addClip(s, a.id, ASPECT);
  }
  assert.equal(s.timeline.length, MAX_CLIPS);
  assert.equal(regi.canAddMore(s), false);
  const free = s.assets.find((a) => !s.timeline.some((c) => c.asset === a.id) && !regi.isExcluded(s, a))!;
  assert.throws(() => regi.addClip(s, free.id, ASPECT), /Högst 12 klipp/);
  // En film med fler (t.ex. många pinnade bilder) går ändå att läsa in.
  s.timeline.push({ ...structuredClone(s.timeline[1]), asset: free.id });
  assert.equal(parseReelSpec(JSON.stringify(s)).timeline.length, MAX_CLIPS + 1);
});

test("uteslutna bilder visas sist och kan inte läggas till utan aktivt val", () => {
  const s = load();
  const cands = regi.candidates(s, () => true);
  assert.deepEqual(cands.map((c) => [c.asset.id, c.excluded]), [["a7", false], ["a6", true]]);
  assert.throws(() => regi.addClip(s, "a6", ASPECT), /uteslutit/);
  assert.equal(s.timeline.length, 5);
  assert.deepEqual(regi.addClip(s, "a6", ASPECT, { allowExcluded: true }), ["add", "unexclude"]);
  assert.equal(s.editor?.excludedAssets, undefined, "uteslutningen släpps");
  assert.equal(s.editor?.pinnedAssets?.length, 1, "resten av editor kvar");
  assert.equal(s.editor?.tempo, "calm");
  assert.equal(s.editor?.orderLocked, true);
});

test("borttagning av en pinnad bild släpper pinningen (op unpin)", () => {
  const s = load();
  const i = s.timeline.findIndex((c) => c.asset === "a3");
  assert.equal(regi.isPinned(s, s.timeline[i]), true);
  assert.deepEqual(regi.removeClip(s, i, ASPECT), ["remove", "unpin"]);
  assert.equal(s.editor?.pinnedAssets, undefined);
  assert.equal(s.editor?.excludedAssets?.length, 1);
  assert.deepEqual(regi.removeClip(s, 0, ASPECT), ["remove"], "opinnad bild: bara remove");
});

test("editor tas bort helt när det blir tomt", () => {
  const s = load();
  s.editor = { pinnedAssets: [s.assets.find((a) => a.id === "a3")!.sha256] };
  regi.removeClip(s, s.timeline.findIndex((c) => c.asset === "a3"), ASPECT);
  assert.equal("editor" in s, false);
});

test("felaktigt editor-objekt kraschar inte", () => {
  const s = load();
  (s as Record<string, unknown>).editor = { pinnedAssets: "fel", excludedAssets: [1, null], tempo: 3 };
  const e = regi.editorOf(s);
  assert.equal(e.pinned.size, 0);
  assert.equal(e.excluded.size, 0);
  assert.equal(e.tempo, "normal");
  assert.equal(regi.candidates(s, () => true).every((c) => !c.excluded), true);
  assert.deepEqual(regi.removeClip(s, 2, ASPECT), ["remove"]);
});

// ------------------------------------------------------------ visning

test("lås beskrivs för mäklaren", () => {
  const s = load();
  assert.deepEqual(regi.clipLocks(s, 0), {
    customMotion: false, durationLocked: false, transitionLocked: false, pinned: false, transition: null, transitionText: null,
  });
  assert.deepEqual(regi.clipLocks(s, 1), {
    customMotion: true, durationLocked: false, transitionLocked: true, pinned: false, transition: "Hårt klipp", transitionText: "In: Hårt klipp",
  });
  assert.deepEqual(regi.clipLocks(s, 2), {
    customMotion: false, durationLocked: true, transitionLocked: true, pinned: true, transition: "Mjuk tona 0,5 s (filmens standard)",
    transitionText: "In: Mjuk tona 0,5 s (filmens standard)",
  });
  assert.equal(regi.clipLocks(s, 4).transition, "Mjuk tona 0,6 s");
  assert.deepEqual(regi.filmLocks(s), ["Tempo: lugnt", "Ordningen är låst för nya förslag"]);
  delete s.editor;
  assert.deepEqual(regi.filmLocks(s), []);
  assert.equal(regi.LOCKED_BY_PHOTOGRAPHER, "Låst av fotografen");
});

// ------------------------------------------------------------ granskningsfynd R5

test("fixturen följer Swift-kodningen av låsen (nil skrivs inte, editor normaliserad)", () => {
  const j = JSON.parse(raw);
  j.timeline.forEach((c: Record<string, unknown>, i: number) => {
    for (const k of ["durationLocked", "transitionLocked"]) {
      assert.ok(!(k in c) || c[k] === true || c[k] === false, `${k} på klipp ${i} är Bool eller saknas`);
      assert.notEqual(c[k], null, `${k} skrivs inte som null`);
    }
    assert.notEqual(c.transitionIn, null, "transitionIn utelämnas i stället för null");
    assert.notEqual(c.motionPreset, null);
  });
  const e = j.editor as Record<string, unknown>;
  for (const k of ["pinnedAssets", "excludedAssets"]) {
    assert.ok(!(k in e) || (Array.isArray(e[k]) && (e[k] as unknown[]).length > 0), `${k} tom lista skrivs inte`);
  }
  assert.ok(!("orderLocked" in e) || e.orderLocked === true, "orderLocked skrivs bara som true");
  assert.ok(!("tempo" in e) || e.tempo !== "normal", "tempo normal skrivs inte");
  // Testnamnen påstår inte en Swift-täckning som inte finns.
  const src = readFileSync(fileURLToPath(import.meta.url), "utf8");
  assert.equal(/så att Swift-testet täcker/.test(src.replace(/assert[^\n]*Swift-testet[^\n]*/g, "")), false);
});

test("första klippet med låst övergång visas inte som en övergång in", () => {
  const s = load();
  regi.moveClip(s, 1, 0, ASPECT); // a2 (låst cut) först
  const l = regi.clipLocks(s, 0);
  assert.equal(l.transitionLocked, true, "låset syns fortfarande");
  assert.ok(l.transitionText && !l.transitionText.startsWith("In:"), `första klippet: ${l.transitionText}`);
  assert.match(l.transitionText!, /används inte på första klippet/i);
  assert.match(l.transitionText!, /Hårt klipp/);
  const t = load();
  regi.moveClip(t, 2, 0, ASPECT); // a3 (låst standardövergång) först
  assert.match(regi.clipLocks(t, 0).transitionText!, /^Låst övergång: Mjuk tona 0,5 s \(filmens standard\)\. Används inte/);
  assert.equal(regi.clipLocks(t, 1).transitionText?.startsWith("In: "), true);
});

test("borttagning av custom/låst övergång varnar, och tillägg av samma bild återställer låsen", () => {
  const s = load();
  const i = s.timeline.findIndex((c) => c.asset === "a2");
  const a2 = structuredClone(s.timeline[i]);
  const w = regi.removalWarning(s, i);
  assert.ok(w, "varning för custom och låst övergång även utan pinning");
  assert.match(w!, /egen rörelse/);
  assert.match(w!, /övergång/);
  assert.equal(regi.removalWarning(s, 0), null, "olåst klipp: ingen varning");
  const removed: regi.RemovedClips = new Map();
  assert.deepEqual(regi.removeClip(s, i, ASPECT, removed), ["remove"]);
  assert.deepEqual(regi.addClip(s, "a2", ASPECT, { removed }), ["add"]);
  const back = byAsset(s, "a2");
  assert.equal(back.motionPreset, CUSTOM);
  assert.equal(back.fit, a2.fit);
  assert.deepEqual(back.motion, a2.motion);
  assert.equal(back.transitionLocked, true);
  assert.deepEqual(back.transitionIn, { type: "cut", duration: 0 });
  assert.equal(removed.size, 0);
});

test("pinnad bild: varningen lovar inte att bilden aldrig kommer tillbaka, och tillägg pinnar igen", () => {
  const s = load();
  const i = s.timeline.findIndex((c) => c.asset === "a3");
  const w = regi.removalWarning(s, i)!;
  assert.doesNotMatch(w, /kommer inte tillbaka/);
  assert.match(w, /inte längre garanterad/);
  assert.match(w, /övergång/, "a3 har även låst övergång");
  const removed: regi.RemovedClips = new Map();
  assert.deepEqual(regi.removeClip(s, i, ASPECT, removed), ["remove", "unpin"]);
  assert.equal(s.editor?.excludedAssets?.includes(s.assets.find((a) => a.id === "a3")!.sha256), false,
    "bilden utesluts inte, så den kan väljas igen");
  assert.deepEqual(regi.addClip(s, "a3", ASPECT, { removed }), ["add", "pin"]);
  const back = byAsset(s, "a3");
  assert.equal(regi.isPinned(s, back), true);
  assert.equal(back.durationLocked, true);
  assert.equal(back.duration, 4);
  assert.equal(back.transitionLocked, true);
  assert.equal(back.transitionIn, undefined);
});

test("låst längd har synlig text, inte bara en ikon", () => {
  assert.equal(regi.DURATION_LOCK.text, "Låst längd");
  assert.match(regi.DURATION_LOCK.explanation, /räknas inte om/);
  const src = readFileSync(join(here, "../src/editor.ts"), "utf8");
  assert.equal(/icon-only/.test(src), false, "inget märke med bara ikon");
  assert.equal(/setAttribute\("aria-label", (title|l\.title)\)/.test(src), false, "ingen aria-label på span utan roll");
  assert.match(src, /sr-only/);
});

test("byte från egen rörelse tar bort fotografens oklampade nycklar (customMotion)", () => {
  const s = load();
  const c = byAsset(s, "a2");
  c.customMotion = { from: { cx: 0.62, cy: 0.6, zoom: 1.05 }, to: { cx: 0.33, cy: 0.6, zoom: 1.05 } };
  // Omordning och längd behåller fältet.
  regi.moveClip(s, 1, 3, ASPECT);
  assert.ok(byAsset(s, "a2").customMotion, "customMotion följer klippet vid omordning");
  const i = order(s).indexOf("a2");
  regi.setPreset(s, i, "panLeft", ASPECT);
  assert.equal(byAsset(s, "a2").customMotion, undefined);
});
