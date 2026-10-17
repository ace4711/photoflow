// R6e: mäklarens regi med rutklipp (kollage och montage, spec v2). Fixturen
// test/fixtures/reel-panels-v2.json: a1 cover, a2+a3 kollage (stack), a4 montage
// (sequence, två halvor), a5 cover, a6 cover (sist). Servern kontrollerar samma
// operationer mot fixturen i server/test/panels.test.ts.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { parseReelSpec } from "../src/reelSpec.ts";
import type { Clip, ReelSpec } from "../src/reelSpec.ts";
import { editedCopy, sortKeys } from "../src/approve.ts";
import { panSign } from "../src/motionPresets.ts";
import * as regi from "../src/regi.ts";

const here = dirname(fileURLToPath(import.meta.url));
const rawPanels = readFileSync(join(here, "fixtures/reel-panels-v2.json"), "utf8");
const rawV1 = readFileSync(join(here, "fixtures/reel-locks-v1.json"), "utf8");
const loadPanels = (): ReelSpec => parseReelSpec(rawPanels);
const ASPECT = 1080 / 1920;
const byAsset = (s: ReelSpec, id: string): Clip => s.timeline.find((c) => c.asset === id)!;

test("rutklipp: rundtur bevarar rutor, layout, gutter och entrance", () => {
  const original = JSON.parse(rawPanels);
  const out = editedCopy(loadPanels(), ["duration"], "Maja", "2026-10-17T08:00:00Z");
  const back = parseReelSpec(JSON.stringify(sortKeys(out), null, 2));
  assert.deepEqual(back.timeline, original.timeline);
  assert.equal(back.minReaderVersion, 2);
});

test("rutklipp: flytta och retime rör inte rutorna eller längden, övriga klipp räknas om", () => {
  const s = loadPanels();
  const strip = (c: Clip) => ({ ...c, transitionIn: undefined });
  const before = s.timeline.filter(regi.isPanelsClip).map((c) => strip(structuredClone(c)));
  regi.moveClip(s, 1, 4, ASPECT); // kollaget sist
  regi.moveClip(s, 1, 0, ASPECT); // montaget först
  assert.deepEqual(s.timeline.filter(regi.isPanelsClip).map(strip).sort((x, y) => x.asset.localeCompare(y.asset)), before);
  assert.equal(s.timeline[0].asset, "a4");
  assert.equal(s.timeline[0].transitionIn, undefined); // första klippet har ingen övergång
  assert.notEqual(byAsset(s, "a1").duration, 3.0);      // a1 var första klippet och är nu mitten
  assert.equal(byAsset(s, "a2").duration, 3.4);
});

test("rutklipp: längd kan ändras och låses, förval kan inte sättas", () => {
  const s = loadPanels();
  assert.deepEqual(regi.setDuration(s, 1, 4.5, 10), ["duration"]);
  assert.equal(byAsset(s, "a2").durationLocked, true);
  assert.deepEqual(regi.setPreset(s, 1, "panLeft", ASPECT), []);
  assert.equal(byAsset(s, "a2").fit, "panels");
});

test("rutklipp: rutornas bilder räknas som i filmen (candidates, addClip)", () => {
  const s = loadPanels();
  assert.deepEqual(regi.candidates(s, () => true), []);
  assert.throws(() => regi.addClip(s, "a3", ASPECT), /redan med/);
  assert.throws(() => regi.addClip(s, "a4", ASPECT), /redan med/);
});

test("rutklipp: borttagning och tillbakaläggning återställer hela klippet", () => {
  const s = loadPanels();
  const orig = structuredClone(byAsset(s, "a2"));
  const removed: regi.RemovedClips = new Map();
  assert.ok(regi.removalWarning(s, 1)?.includes("Kollage: Kök och Matplats"));
  assert.deepEqual(regi.removeClip(s, 1, ASPECT, removed), ["remove"]);
  assert.deepEqual(regi.candidates(s, () => true).map((c) => c.asset.id), ["a2", "a3"]);
  regi.addClip(s, "a2", ASPECT, { removed });
  const back = byAsset(s, "a2");
  assert.equal(back.fit, "panels");
  assert.deepEqual(back.panels, orig.panels);
  assert.equal(back.layout, "stack");
  assert.equal(back.duration, orig.duration);
  assert.deepEqual(regi.candidates(s, () => true), []);
});

test("rutklipp: läggs andra rutans bild till först blir första bilden ett vanligt klipp", () => {
  const s = loadPanels();
  const removed: regi.RemovedClips = new Map();
  regi.removeClip(s, 1, ASPECT, removed);
  regi.addClip(s, "a3", ASPECT, { removed });
  regi.addClip(s, "a2", ASPECT, { removed });
  assert.notEqual(byAsset(s, "a2").fit, "panels");
  assert.equal(s.timeline.filter(regi.isPanelsClip).length, 1);
});

test("rutklipp: clipLocks ger titel och bilder; panSign är 0", () => {
  const s = loadPanels();
  assert.deepEqual(regi.clipLocks(s, 1).panels, { title: "Kollage: Kök och Matplats", assets: ["a2", "a3"] });
  assert.deepEqual(regi.clipLocks(s, 2).panels, { title: "Montage", assets: ["a4"] });
  assert.equal(regi.clipLocks(s, 0).panels, undefined);
  assert.equal(panSign(s.timeline[2]), 0);
  assert.deepEqual(regi.filmLocks(s), []);
});

test("v1 utan rutor beter sig som förut", () => {
  const s = parseReelSpec(rawV1);
  assert.ok(s.timeline.every((c) => !regi.isPanelsClip(c)));
  assert.equal(regi.clipLocks(s, 0).panels, undefined);
  const on = new Set(s.timeline.map((c) => c.asset));
  assert.deepEqual(regi.candidates(s, () => true).map((c) => c.asset.id).sort(),
    s.assets.filter((a) => !on.has(a.id)).map((a) => a.id).sort());
});
