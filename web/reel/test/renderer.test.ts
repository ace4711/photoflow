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

test("rutklipp: rutorna ritas som en grupp på hjälpcanvasen (svart botten, dest i heltalspixlar) och gruppen blandas med opacitet", () => {
  const panelSpec = parseReelSpec({
    ...JSON.parse(JSON.stringify(spec)),
    version: 2, minReaderVersion: 2,
    timeline: [
      spec.timeline[0],
      {
        asset: "a2", duration: 3, fit: "panels", layout: "stack", motionPreset: "custom", gutter: 0.04,
        motion: spec.timeline[1].motion,
        panels: [{ asset: "a2", motion: spec.timeline[1].motion }, { asset: "a3", motion: spec.timeline[2].motion }],
        transitionIn: { type: "crossfade", duration: 0.5 },
      },
    ],
  });
  const log: string[] = [];
  const group = scratch("group", log), pad = scratch("pad", log);
  // Övergången börjar vid 2,5 s: t = 2,75 → gruppen har opacitet 0,5 (easeInOut av 0,5).
  renderFrame(fake("main", log), panelSpec, 2.75, 540, 960, { images, scratch: group, backdropScratch: pad });
  assert.ok(log.some((s) => s.startsWith("group.fill 0,0,540,960")), "gruppens svarta botten");
  const panelDraws = log.filter((s) => s.startsWith("group.draw"));
  assert.equal(panelDraws.length, 2, "två rutor");
  // dest avrundas till heltalspixlar: ruta 1 får höjden round(dest.h · 960).
  const dest = state(2.75, panelSpec, { width: 540, height: 960 }).filter((l) => l.panel)[0].dest;
  assert.ok(panelDraws[0].endsWith(`,0,0,540,${Math.round(dest.h * 960)}`), panelDraws[0]);
  assert.ok(log.some((s) => s.startsWith("main.draw group") && /a=0\.\d+/.test(s)), log.join("\n"));
});
