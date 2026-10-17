// Pixeltester för rutklipp (spec v2) i canvasRenderer.ts, mot en liten programvarucanvas (bara det
// renderaren använder: fillRect, drawImage, translate, clip mot rektangel, globalAlpha, save/restore).
// Speglar PhotoFlow/Tests/ReelPanelsRenderTests.swift: samma specar, samma tider, samma pixlar.

import { test } from "node:test";
import assert from "node:assert/strict";
import { renderFrame } from "../src/canvasRenderer.ts";
import type { DrawableImage, Scratch } from "../src/canvasRenderer.ts";
import { parseReelSpec } from "../src/reelSpec.ts";
import type { ReelSpec } from "../src/reelSpec.ts";

type RGB = [number, number, number];

/** En bild som är en funktion av (u, v) i bildens egna normaliserade koordinater. */
class FakeImage {
  width: number; height: number; color: (u: number, v: number) => RGB;
  constructor(width: number, height: number, color: (u: number, v: number) => RGB) {
    this.width = width; this.height = height; this.color = color;
  }
}
const solid = (w: number, h: number, c: RGB): FakeImage => new FakeImage(w, h, () => c);

/** Programvarucanvas: RGBA som flyttal 0..255, bara översättning som transform. */
class SoftCanvas {
  width = 1; height = 1;
  data = new Float64Array(4);
  globalAlpha = 1;
  filter = "none";
  fillStyle = "#000";
  private tx = 0; private ty = 0;
  private clipRect: [number, number, number, number] | null = null;
  private pending: [number, number, number, number] | null = null;
  private stack: { tx: number; ty: number; clip: [number, number, number, number] | null; alpha: number }[] = [];
  get source(): SoftCanvas { return this; }
  get ctx(): CanvasRenderingContext2D { return this as unknown as CanvasRenderingContext2D; }

  resize(w: number, h: number): void {
    if (this.width === w && this.height === h) return;
    this.width = w; this.height = h; this.data = new Float64Array(w * h * 4);
  }
  save(): void { this.stack.push({ tx: this.tx, ty: this.ty, clip: this.clipRect, alpha: this.globalAlpha }); }
  restore(): void {
    const s = this.stack.pop()!;
    this.tx = s.tx; this.ty = s.ty; this.clipRect = s.clip; this.globalAlpha = s.alpha;
  }
  setTransform(): void { this.tx = 0; this.ty = 0; }
  translate(x: number, y: number): void { this.tx += x; this.ty += y; }
  clearRect(): void { this.data.fill(0); }
  beginPath(): void { this.pending = null; }
  rect(x: number, y: number, w: number, h: number): void { this.pending = [x + this.tx, y + this.ty, x + this.tx + w, y + this.ty + h]; }
  clip(): void {
    const p = this.pending!;
    const c = this.clipRect;
    this.clipRect = c ? [Math.max(c[0], p[0]), Math.max(c[1], p[1]), Math.min(c[2], p[2]), Math.min(c[3], p[3])] : p;
  }
  private put(px: number, py: number, rgb: RGB, a: number): void {
    const c = this.clipRect;
    if (px < 0 || py < 0 || px >= this.width || py >= this.height) return;
    if (c && (px + 0.5 < c[0] || px + 0.5 >= c[2] || py + 0.5 < c[1] || py + 0.5 >= c[3])) return;
    const i = (py * this.width + px) * 4;
    const alpha = a * this.globalAlpha;
    // Källan är alltid helt täckande (a = 1) utom när en hjälpcanvas ritas; då räknas dess alfa med.
    for (let k = 0; k < 3; k++) this.data[i + k] = (1 - alpha) * this.data[i + k] + alpha * rgb[k];
    this.data[i + 3] = alpha + (1 - alpha) * this.data[i + 3];
  }
  fillRect(x: number, y: number, w: number, h: number): void {
    const rgb: RGB = this.fillStyle === "#000" ? [0, 0, 0] : [255, 255, 255];
    for (let py = Math.floor(y + this.ty); py < Math.ceil(y + this.ty + h); py++) {
      for (let px = Math.floor(x + this.tx); px < Math.ceil(x + this.tx + w); px++) this.put(px, py, rgb, 1);
    }
  }
  drawImage(img: FakeImage | SoftCanvas, ...a: number[]): void {
    if (img instanceof SoftCanvas) {
      const [x, y] = a;
      for (let py = 0; py < img.height; py++) {
        for (let px = 0; px < img.width; px++) {
          const i = (py * img.width + px) * 4;
          if (img.data[i + 3] <= 0) continue;
          this.put(px + Math.round(x + this.tx), py + Math.round(y + this.ty), [img.data[i], img.data[i + 1], img.data[i + 2]], img.data[i + 3]);
        }
      }
      return;
    }
    const [sx, sy, sw, sh, dx, dy, dw, dh] = a;
    const x0 = dx + this.tx, y0 = dy + this.ty;
    for (let py = Math.floor(y0); py < Math.ceil(y0 + dh); py++) {
      for (let px = Math.floor(x0); px < Math.ceil(x0 + dw); px++) {
        const u = (sx + ((px + 0.5 - x0) / dw) * sw) / img.width;
        const v = (sy + ((py + 0.5 - y0) / dh) * sh) / img.height;
        this.put(px, py, img.color(u, v), 1);
      }
    }
  }
  px(x: number, y: number): RGB {
    const i = (y * this.width + x) * 4;
    return [this.data[i], this.data[i + 1], this.data[i + 2]];
  }
}

const RED: RGB = [255, 0, 0], BLUE: RGB = [0, 0, 255], GREEN: RGB = [0, 255, 0], BLACK: RGB = [0, 0, 0];
const near = (p: RGB, q: RGB, tol = 3): boolean => p.every((v, k) => Math.abs(v - q[k]) <= tol);
const check = (p: RGB, q: RGB, what: string): void => assert.ok(near(p, q), `${what}: fick ${p.map(Math.round)} väntade ${q}`);

const still = { from: { cx: 0.5, cy: 0.5, zoom: 1 }, to: { cx: 0.5, cy: 0.5, zoom: 1 } };
const SHA = "0".repeat(64);

function makeSpec(assets: [string, number, number][], timeline: unknown[], width: number, height: number, easing = "linear"): ReelSpec {
  return parseReelSpec({
    schema: "photoflow.reel", version: 2, minReaderVersion: 2, id: "t", revision: 1, status: "draft",
    createdAt: "2026-10-17T09:00:00Z", updatedAt: "2026-10-17T09:00:00Z", updatedBy: { role: "photographer" },
    property: { address: "Test" },
    assets: assets.map(([id, w, h]) => ({ id, sha256: SHA, width: w, height: h, sources: [] })),
    style: { defaultTransition: { type: "crossfade", duration: 0.4 }, easing, background: { type: "blur", amount: 0.6 } },
    timeline, outputs: [{ id: "o", aspect: "x", width, height, fps: 30 }], provenance: { generator: "test" },
  });
}
const panelClip = (layout: string, panels: unknown[], duration: number, extra: Record<string, unknown> = {}) =>
  ({ asset: (panels[0] as { asset: string }).asset, duration, fit: "panels", motion: still, motionPreset: "custom", layout, panels, ...extra });

function render(spec: ReelSpec, images: Record<string, FakeImage>, t: number): SoftCanvas {
  const { width, height } = spec.outputs[0];
  const main = new SoftCanvas();
  main.resize(width, height);
  const scratch = (): Scratch => { const c = new SoftCanvas(); return { ctx: c.ctx, source: c as unknown as CanvasImageSource, resize: (w, h) => c.resize(w, h) }; };
  renderFrame(main.ctx, spec, t, width, height, {
    images: new Map(Object.entries(images).map(([k, v]) => [k, v as unknown as DrawableImage])),
    scratch: scratch(), backdropScratch: scratch(),
  });
  return main;
}

const montage = new FakeImage(800, 600, (u) => (u < 0.5 ? RED : BLUE));
const L = { x: 0, y: 0, w: 0.5, h: 1 }, R = { x: 0.5, y: 0, w: 0.5, h: 1 };

test("stack: första bilden uppe, andra nere, svart gutter mitt emellan (9:16)", () => {
  const spec = makeSpec([["a1", 600, 400], ["a2", 600, 400]],
    [panelClip("stack", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 2, { gutter: 0.04 })], 270, 480);
  const c = render(spec, { a1: solid(600, 400, RED), a2: solid(600, 400, BLUE) }, 1);
  check(c.px(135, 100), RED, "uppe"); check(c.px(5, 5), RED, "uppe hörn"); check(c.px(265, 225), RED, "uppe nere");
  check(c.px(135, 380), BLUE, "nere"); check(c.px(5, 474), BLUE, "nere hörn");
  check(c.px(135, 240), BLACK, "gutter"); check(c.px(10, 238), BLACK, "gutter vänster"); check(c.px(260, 242), BLACK, "gutter höger");
  check(c.px(135, 230), RED, "strax ovanför"); check(c.px(135, 251), BLUE, "strax under");
});

test("side: första bilden till vänster, andra till höger, svart gutter (16:9)", () => {
  const spec = makeSpec([["a1", 400, 600], ["a2", 400, 600]],
    [panelClip("side", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 2, { gutter: 0.04 })], 480, 270);
  const c = render(spec, { a1: solid(400, 600, RED), a2: solid(400, 600, BLUE) }, 1);
  check(c.px(100, 135), RED, "vänster"); check(c.px(2, 2), RED, "vänster hörn");
  check(c.px(380, 135), BLUE, "höger"); check(c.px(477, 267), BLUE, "höger hörn");
  check(c.px(240, 100), BLACK, "gutter"); check(c.px(236, 5), BLACK, "gutter uppe"); check(c.px(244, 260), BLACK, "gutter nere");
  check(c.px(232, 100), RED, "strax vänster"); check(c.px(249, 100), BLUE, "strax höger");
});

test("source: montagehalvorna visas var för sig, mittpunkt utanför source klampas", () => {
  const farRight = { from: { cx: 0.9, cy: 0.5, zoom: 1 }, to: { cx: 0.9, cy: 0.5, zoom: 1 } };
  const spec = makeSpec([["m", 800, 600]],
    [panelClip("side", [{ asset: "m", source: L, motion: farRight }, { asset: "m", source: R, motion: still }], 2, { gutter: 0.02 })], 480, 270);
  const c = render(spec, { m: montage }, 1);
  for (const [x, y] of [[2, 2], [120, 135], [232, 267], [100, 5]]) check(c.px(x, y), RED, `röd ${x},${y}`);
  for (const [x, y] of [[248, 2], [360, 135], [477, 267], [400, 5]]) check(c.px(x, y), BLUE, `blå ${x},${y}`);
});

test("sequence: vänster halva först, sedan skjuts den högra in (intern push)", () => {
  const spec = makeSpec([["m", 800, 600]],
    [panelClip("sequence", [{ asset: "m", source: L, motion: still }, { asset: "m", source: R, motion: still }], 4)], 270, 480);
  const early = render(spec, { m: montage }, 0.5);
  check(early.px(135, 240), RED, "tidigt mitt"); check(early.px(5, 5), RED, "tidigt hörn"); check(early.px(265, 475), RED, "tidigt hörn 2");
  const mid = render(spec, { m: montage }, 2.0); // e = 0,5: röd −135 px, blå +135 px
  check(mid.px(60, 240), RED, "mitt i skjutningen röd"); check(mid.px(200, 240), BLUE, "mitt i skjutningen blå");
  const late = render(spec, { m: montage }, 3.5);
  check(late.px(135, 240), BLUE, "sent"); check(late.px(5, 475), BLUE, "sent hörn");
});

test("slide: ruta 1 glider in från vänster (stack) vid en given tid, ruta 2 startar senare", () => {
  const spec = makeSpec([["a1", 600, 400], ["a2", 600, 400]],
    [panelClip("stack", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 3,
      { gutter: 0.006, entrance: { type: "slide", stagger: 0.3, duration: 0.6 } })], 270, 480);
  const imgs = { a1: solid(600, 400, RED), a2: solid(600, 400, BLUE) };
  const a = render(spec, imgs, 0.3);
  check(a.px(60, 100), RED, "ruta 1 halvvägs"); check(a.px(200, 100), BLACK, "till höger om rutan");
  check(a.px(135, 380), BLACK, "ruta 2 utanför"); check(a.px(265, 380), BLACK, "ruta 2 utanför höger");
  const b = render(spec, imgs, 0.6);
  check(b.px(5, 100), RED, "ruta 1 på plats"); check(b.px(265, 100), RED, "ruta 1 på plats höger");
  check(b.px(200, 380), BLUE, "ruta 2 halvvägs"); check(b.px(60, 380), BLACK, "vänster om ruta 2");
  const c = render(spec, imgs, 1.2);
  check(c.px(5, 100), RED, "klart uppe"); check(c.px(265, 380), BLUE, "klart nere");
});

test("slide i side kommer ovanifrån respektive underifrån", () => {
  const spec = makeSpec([["a1", 400, 600], ["a2", 400, 600]],
    [panelClip("side", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 3,
      { gutter: 0.006, entrance: { type: "slide", stagger: 0, duration: 0.6 } })], 480, 270);
  const c = render(spec, { a1: solid(400, 600, RED), a2: solid(400, 600, BLUE) }, 0.3); // e = 0,5: ±135 px i höjd
  check(c.px(100, 50), RED, "vänster ruta har kommit halvvägs ovanifrån"); check(c.px(100, 200), BLACK, "tomt under den inglidande rutan");
  check(c.px(380, 200), BLUE, "höger ruta har kommit halvvägs underifrån"); check(c.px(380, 50), BLACK, "tomt ovanför den inglidande rutan");
});

test("fade: rutorna tonar in var för sig mot svart", () => {
  const spec = makeSpec([["a1", 600, 400], ["a2", 600, 400]],
    [panelClip("stack", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 3,
      { entrance: { type: "fade", stagger: 0.4, duration: 0.8 } })], 270, 480);
  const c = render(spec, { a1: solid(600, 400, [255, 255, 255]), a2: solid(600, 400, [255, 255, 255]) }, 0.4);
  check(c.px(135, 100), [128, 128, 128], "uppe halv"); check(c.px(135, 380), BLACK, "nere ännu osynlig");
});

test("övergång in i ett rutklipp: hela gruppen (inkl. svart gutter) blandas med det utgående", () => {
  const spec = makeSpec([["g", 600, 400], ["a1", 600, 400], ["a2", 600, 400]], [
    { asset: "g", duration: 2, fit: "cover", motion: still },
    panelClip("stack", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 2,
      { gutter: 0.04, transitionIn: { type: "crossfade", duration: 0.5 } }),
  ], 270, 480);
  const c = render(spec, { g: solid(600, 400, GREEN), a1: solid(600, 400, RED), a2: solid(600, 400, RED) }, 1.75);
  check(c.px(135, 100), [128, 128, 0], "ruta blandad med grönt");
  check(c.px(135, 240), [0, 128, 0], "gutter: svart gruppbotten, inte grönt rakt igenom");
});

test("push ut ur ett rutklipp flyttar hela gruppen, gutterbandet följer med", () => {
  const spec = makeSpec([["a1", 600, 400], ["a2", 600, 400], ["g", 600, 400]], [
    panelClip("side", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 2, { gutter: 0.04 }),
    { asset: "g", duration: 2, fit: "cover", motion: still, transitionIn: { type: "push", direction: "left", duration: 0.5 } },
  ], 270, 480);
  const c = render(spec, { a1: solid(600, 400, RED), a2: solid(600, 400, RED), g: solid(600, 400, GREEN) }, 1.75);
  check(c.px(60, 100), RED, "rutgruppen flyttad åt vänster"); check(c.px(200, 100), GREEN, "grönt skjuts in");
  check(c.px(2, 100), BLACK, "gutterbandet har följt med till vänsterkanten");
});

test("crossfade mellan två rutklipp blandar grupperna (inte rutorna var för sig)", () => {
  const spec = makeSpec([["a1", 600, 400], ["a2", 600, 400]], [
    panelClip("stack", [{ asset: "a1", motion: still }, { asset: "a2", motion: still }], 2, { gutter: 0.04 }),
    panelClip("side", [{ asset: "a2", motion: still }, { asset: "a1", motion: still }], 2,
      { gutter: 0.04, transitionIn: { type: "crossfade", duration: 0.5 } }),
  ], 270, 480);
  const c = render(spec, { a1: solid(600, 400, RED), a2: solid(600, 400, BLUE) }, 1.75);
  // Övre vänstra hörnet: utgående stack har röd (uppe), inkommande side har blå (vänster): 50/50.
  check(c.px(10, 10), [128, 0, 128], "hörn uppe till vänster");
  // Nere till höger: utgående blå, inkommande röd.
  check(c.px(260, 470), [128, 0, 128], "hörn nere till höger");
});
