import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { renderFrame } from "../src/canvasRenderer.ts";
import type { Scratch } from "../src/canvasRenderer.ts";
import { parseReelSpec } from "../src/reelSpec.ts";
import { state } from "../src/reelTimeline.ts";

// En fejkad 2D-kontext som bara protokollerar anropen.
function fake(name: string, log: string[]) {
  const g: Record<string, unknown> = { globalAlpha: 1, filter: "none", fillStyle: "" };
  for (const m of ["save", "restore", "beginPath", "rect", "clip", "setTransform", "clearRect", "translate"]) g[m] = () => {};
  g.fillRect = (...a: number[]) => log.push(`${name}.fill ${a.join(",")}`);
  g.drawImage = (src: { id?: string }, ...a: number[]) =>
    log.push(`${name}.draw ${src.id ?? "?"} a=${g.globalAlpha} f=${g.filter} ${a.map((x) => +x.toFixed(2)).join(",")}`);
  return g as unknown as CanvasRenderingContext2D;
}
const scratch = (name: string, log: string[]): Scratch => {
  const ctx = fake(name, log);
  return { ctx, source: { id: name } as unknown as CanvasImageSource, resize: () => {} };
};

const spec = parseReelSpec(readFileSync(new URL("../../../PhotoFlow/Tests/Fixtures/Reel/example-v1.json", import.meta.url), "utf8"));
const img = (id: string) => ({ id, width: 6048, height: 4024 }) as unknown as import("../src/canvasRenderer.ts").DrawableImage;
const images = new Map(spec.assets.map((a) => [a.id, img(a.id)]));

test("cover ritas med utsnittet från state() i bildpixlar", () => {
  const log: string[] = [];
  renderFrame(fake("main", log), spec, 0.5, 540, 960, { images });
  const l = state(0.5, spec, { width: 540, height: 960 })[0];
  const draws = log.filter((s) => s.includes(".draw"));
  assert.equal(draws.length, 1);
  assert.match(draws[0], new RegExp(`^main.draw a1 a=1 f=none ${+(l.crop.x * 6048).toFixed(2)},0,`));
});

test("contain-blur: grupp på hjälpcanvas, bakgrund suddas, gruppen blandas med opacitet", () => {
  const log: string[] = [];
  const group = scratch("group", log), pad = scratch("pad", log);
  // Strax in i sista övergången (crossfade 8,7–9,3): inkommande a5 är contain-blur med opacitet < 1.
  renderFrame(fake("main", log), spec, 8.9, 540, 960, { images, scratch: group, backdropScratch: pad });
  assert.ok(log.some((s) => s.startsWith("pad.draw")), "bakgrunden ritas på marginalcanvasen");
  assert.ok(log.some((s) => s.startsWith("main.draw group") && /a=0\.\d+/.test(s) && s.includes("f=none")), log.join("\n"));
});
