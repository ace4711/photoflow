// Ritar en bildruta av en reel på en 2D-canvas från `state(at:)`. All geometri
// och opacitet kommer från reelTimeline.ts; här översätts den bara till
// canvasanrop (samma arbetsfördelning som ReelRenderer.swift).
//
// Färg: specen kräver blandning i sRGB-kodade värden. Canvas 2D blandar
// `globalAlpha` på de gammakodade värdena i canvasens färgrymd (sRGB som
// standard), alltså (1−a)·under + a·över utan konvertering till linjärt ljus.
// Skapa därför canvasens kontext utan `colorSpace: "display-p3"`.
//
// contain-blur ritas som en grupp (bakgrund + förgrund) på en hjälpcanvas som
// sedan blandas med lagrets opacitet och förskjutning, så att gruppen får en
// enda alfa (precis som Swift-renderaren).

import { state } from "./reelTimeline.ts";
import type { LayerState, Rect } from "./reelTimeline.ts";
import type { ReelSpec } from "./reelSpec.ts";

/** Allt som går att rita med drawImage och som vet sin storlek. */
export type DrawableImage = CanvasImageSource & { width: number; height: number };

export type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export interface Scratch {
  ctx: Ctx2D;
  /** Samma objekt som kan skickas som källa till drawImage. */
  source: CanvasImageSource;
  resize(width: number, height: number): void;
}

/** Skapar en hjälpcanvas. Standard: OffscreenCanvas, annars ett canvaselement. */
export function createScratch(): Scratch {
  if (typeof OffscreenCanvas !== "undefined") {
    const c = new OffscreenCanvas(1, 1);
    const ctx = c.getContext("2d")!;
    return { ctx, source: c, resize: (w, h) => { if (c.width !== w || c.height !== h) { c.width = w; c.height = h; } } };
  }
  const c = document.createElement("canvas");
  const ctx = c.getContext("2d")!;
  return { ctx, source: c, resize: (w, h) => { if (c.width !== w || c.height !== h) { c.width = w; c.height = h; } } };
}

export interface RenderOptions {
  /** asset-id → laddad bild. Saknad bild ger inget lager (som Swift). */
  images: ReadonlyMap<string, DrawableImage>;
  /** Hjälpcanvaser (återanvänds mellan bildrutor). */
  scratch?: Scratch;
  backdropScratch?: Scratch;
}

/** Ritar `crop` (normaliserat i bilden) så att det fyller `dest` (pixlar). */
function drawCrop(ctx: Ctx2D, img: DrawableImage, crop: Rect, dx: number, dy: number, dw: number, dh: number): void {
  ctx.drawImage(img, crop.x * img.width, crop.y * img.height, crop.w * img.width, crop.h * img.height, dx, dy, dw, dh);
}

/**
 * Bakgrunden för contain-blur: cover-utsnittet över hela ramen, suddat med
 * `sigma` (utpixlar). Swift klampar kanten före suddningen (clampedToExtent);
 * canvasens filter ger annars transparenta kanter. Därför ritas bilden först
 * på en marginal (3σ) runt ramen, och där utsnittet når bildens kant fylls
 * marginalen med den yttersta pixelraden/-kolumnen utsträckt (samma sak som
 * klampning).
 */
function drawBackdrop(ctx: Ctx2D, img: DrawableImage, crop: Rect, sigma: number, w: number, h: number,
                      pad: Scratch): void {
  if (!(sigma > 0)) {
    drawCrop(ctx, img, crop, 0, 0, w, h);
    return;
  }
  const m = Math.ceil(sigma * 3);
  pad.resize(w + 2 * m, h + 2 * m);
  const p = pad.ctx;
  p.clearRect(0, 0, w + 2 * m, h + 2 * m);
  // Pixlar per bildenhet i utbilden.
  const sx = w / crop.w, sy = h / crop.h;
  // Utökat utsnitt (bildenheter), klampat till bilden.
  const ex0 = Math.max(0, crop.x - m / sx), ex1 = Math.min(1, crop.x + crop.w + m / sx);
  const ey0 = Math.max(0, crop.y - m / sy), ey1 = Math.min(1, crop.y + crop.h + m / sy);
  const dx0 = m + (ex0 - crop.x) * sx, dx1 = m + (ex1 - crop.x) * sx;
  const dy0 = m + (ey0 - crop.y) * sy, dy1 = m + (ey1 - crop.y) * sy;
  drawCrop(p, img, { x: ex0, y: ey0, w: ex1 - ex0, h: ey1 - ey0 }, dx0, dy0, dx1 - dx0, dy1 - dy0);
  const iw = img.width, ih = img.height;
  const W = w + 2 * m, H = h + 2 * m;
  const sy0 = ey0 * ih, sh = (ey1 - ey0) * ih, sx0 = ex0 * iw, sw = (ex1 - ex0) * iw;
  // Marginaler utanför bilden: sträck ut kantpixeln.
  if (dx0 > 0) p.drawImage(img, 0, sy0, 1, sh, 0, dy0, dx0, dy1 - dy0);
  if (dx1 < W) p.drawImage(img, iw - 1, sy0, 1, sh, dx1, dy0, W - dx1, dy1 - dy0);
  if (dy0 > 0) p.drawImage(img, sx0, 0, sw, 1, dx0, 0, dx1 - dx0, dy0);
  if (dy1 < H) p.drawImage(img, sx0, ih - 1, sw, 1, dx0, dy1, dx1 - dx0, H - dy1);
  if (dx0 > 0 && dy0 > 0) p.drawImage(img, 0, 0, 1, 1, 0, 0, dx0, dy0);
  if (dx1 < W && dy0 > 0) p.drawImage(img, iw - 1, 0, 1, 1, dx1, 0, W - dx1, dy0);
  if (dx0 > 0 && dy1 < H) p.drawImage(img, 0, ih - 1, 1, 1, 0, dy1, dx0, H - dy1);
  if (dx1 < W && dy1 < H) p.drawImage(img, iw - 1, ih - 1, 1, 1, dx1, dy1, W - dx1, H - dy1);

  ctx.save();
  ctx.beginPath();
  ctx.rect(0, 0, w, h);
  ctx.clip();
  ctx.filter = `blur(${sigma}px)`; // CSS blur-radien är standardavvikelsen, som CIGaussianBlur.sigma
  ctx.drawImage(pad.source, -m, -m);
  ctx.restore();
}

/** Ritar ett lager (inklusive bakgrund) utan opacitet och förskjutning, i rutan (0,0,w,h). */
function drawLayerContent(ctx: Ctx2D, layer: LayerState, img: DrawableImage, w: number, h: number,
                          pad: Scratch): void {
  if (layer.fit === "cover") {
    drawCrop(ctx, img, layer.crop, 0, 0, w, h);
    return;
  }
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, w, h);
  if (layer.backdrop) drawBackdrop(ctx, img, layer.backdrop.crop, layer.backdrop.sigma, w, h, pad);
  // Förgrunden: kanterna avrundas till heltalspixlar (som destinationRect i Swift).
  const x0 = Math.round(layer.dest.x * w), x1 = Math.round((layer.dest.x + layer.dest.w) * w);
  const y0 = Math.round(layer.dest.y * h), y1 = Math.round((layer.dest.y + layer.dest.h) * h);
  drawCrop(ctx, img, layer.crop, x0, y0, x1 - x0, y1 - y0);
}

/**
 * Ritar bildrutan vid tid `t` på `ctx` (storlek `width`×`height` pixlar).
 * Svart där inget lager täcker.
 */
export function renderFrame(ctx: Ctx2D, spec: ReelSpec, t: number, width: number, height: number,
                            opts: RenderOptions): void {
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.filter = "none";
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, width, height);

  const layers = state(t, spec, { width, height });
  let group: Scratch | undefined;
  let pad: Scratch | undefined;
  for (const layer of layers) {
    const img = opts.images.get(layer.asset);
    if (!img) continue;
    const ox = layer.offset.x * width, oy = layer.offset.y * height;
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, width, height);
    ctx.clip();
    ctx.globalAlpha = layer.opacity;
    if (layer.fit === "cover") {
      // Opacitet på ett enda, helt täckande lager: direkt ritning räcker.
      ctx.translate(ox, oy);
      drawLayerContent(ctx, layer, img, width, height, undefined as never);
    } else {
      group ??= (opts.scratch ??= createScratch());
      pad ??= (opts.backdropScratch ??= createScratch());
      group.resize(width, height);
      group.ctx.save();
      group.ctx.setTransform(1, 0, 0, 1, 0, 0);
      group.ctx.globalAlpha = 1;
      group.ctx.filter = "none";
      drawLayerContent(group.ctx, layer, img, width, height, pad);
      group.ctx.restore();
      ctx.drawImage(group.source, ox, oy);
    }
    ctx.restore();
  }
  ctx.restore();
}
