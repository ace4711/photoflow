// Exakt port av PhotoFlow/Sources/Shared/ReelTimeline.swift: ren tidslinjematematik
// (klippstarter, easing, utsnitt, lagerstatus vid tid t). Ingen DOM. Den
// normativa beskrivningen är docs/reel-spec-v1.md och, för rutor,
// docs/reel-spec-v2.md; testas mot
// PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json (tolerans 1e-9).
//
// Alla utsnitt är normaliserade bildkoordinater [0,1]² (y neråt) och alla
// förskjutningar normaliserade ramkoordinater.

import { DEFAULT_ENTRANCE_DURATION, DEFAULT_ENTRANCE_STAGGER, DEFAULT_GUTTER } from "./reelSpec.ts";
import type { Easing, Fit, Motion, MotionKey, PanelLayout, ReelSpec, Transition, UnitRect } from "./reelSpec.ts";

export interface Rect { x: number; y: number; w: number; h: number }
export interface Size { width: number; height: number }

export interface Backdrop { crop: Rect; sigma: number }

/** Rutans egna värden inom klippgruppen (version 2). */
export interface PanelInfo { index: number; opacity: number; offset: { x: number; y: number } }

export interface LayerState {
  asset: string;
  fit: Fit;
  crop: Rect;
  dest: Rect;
  opacity: number;
  offset: { x: number; y: number };
  z: number;
  backdrop: Backdrop | null;
  /**
   * Bara rutlager (fit "panels"): `opacity` och `offset` ovan gäller då hela klippets grupp (alla
   * rutor med samma `z` ritas först på en svart ram och blandas sedan); rutans egen ingång ligger här.
   */
  panel?: PanelInfo | null;
}

const clamp = (v: number, lo: number, hi: number): number => Math.min(Math.max(v, lo), hi);

/** Övergången in till klipp `index` (längd begränsad till det kortaste klippet), eller null. */
export function transition(spec: ReelSpec, index: number): Transition | null {
  if (!(index > 0 && index < spec.timeline.length)) return null;
  const base = spec.timeline[index].transitionIn ?? spec.style.defaultTransition;
  if (base.type === "cut") return null;
  const limit = Math.min(spec.timeline[index - 1].duration, spec.timeline[index].duration);
  const duration = Math.min(Math.max(base.duration, 0), limit);
  return duration > 0 ? { ...base, duration } : null;
}

export function clipStarts(spec: ReelSpec): number[] {
  const starts: number[] = [];
  for (let i = 0; i < spec.timeline.length; i++) {
    if (i === 0) {
      starts.push(0);
    } else {
      const d = transition(spec, i)?.duration ?? 0;
      starts.push(starts[i - 1] + spec.timeline[i - 1].duration - d);
    }
  }
  return starts;
}

export function totalDuration(spec: ReelSpec): number {
  if (spec.timeline.length === 0) return 0;
  const starts = clipStarts(spec);
  return starts[starts.length - 1] + spec.timeline[spec.timeline.length - 1].duration;
}

/** easeInOut = smoothstep p²(3−2p), linear = p. Indata klampas till [0,1]. */
export function easing(kind: Easing, p: number): number {
  const q = clamp(p, 0, 1);
  return kind === "linear" ? q : q * q * (3 - 2 * q);
}

/** Mittpunkt linjärt, zoom geometriskt: z = z0·(z1/z0)^e. */
export function interpolate(motion: Motion, e: number): MotionKey {
  const a = motion.from, b = motion.to;
  return {
    cx: a.cx + (b.cx - a.cx) * e,
    cy: a.cy + (b.cy - a.cy) * e,
    zoom: a.zoom * Math.pow(b.zoom / a.zoom, e),
  };
}

/** Cover-utsnitt (reel-spec 5.1). */
export function cropRect(imageSize: Size, frameAspect: number, center: { x: number; y: number }, zoom: number): Rect {
  const imageAspect = imageSize.width / imageSize.height;
  let baseW: number, baseH: number;
  if (imageAspect >= frameAspect) {
    baseW = frameAspect / imageAspect;
    baseH = 1;
  } else {
    baseW = 1;
    baseH = imageAspect / frameAspect;
  }
  const z = Math.max(zoom, 1);
  const w = baseW / z, h = baseH / z;
  return {
    x: Math.min(Math.max(center.x - w / 2, 0), 1 - w),
    y: Math.min(Math.max(center.y - h / 2, 0), 1 - h),
    w, h,
  };
}

/** Contain-rutan (ramkoordinater) för contain-blur. */
export function containRect(imageSize: Size, frameAspect: number): Rect {
  const imageAspect = imageSize.width / imageSize.height;
  let w: number, h: number;
  if (imageAspect >= frameAspect) {
    w = 1;
    h = frameAspect / imageAspect;
  } else {
    h = 1;
    w = imageAspect / frameAspect;
  }
  return { x: (1 - w) / 2, y: (1 - h) / 2, w, h };
}

/** Förgrundens utsnitt för contain-blur (reel-spec 5.2). */
export function containCrop(center: { x: number; y: number }, zoom: number): Rect {
  const s = 1 / Math.max(zoom, 1);
  return {
    x: Math.min(Math.max(center.x - s / 2, 0), 1 - s),
    y: Math.min(Math.max(center.y - s / 2, 0), 1 - s),
    w: s, h: s,
  };
}

function makeLayer(spec: ReelSpec, index: number, start: number, t: number, frameAspect: number,
                   frameHeight: number, opacity: number, offset: { x: number; y: number }, z: number): LayerState | null {
  const clip = spec.timeline[index];
  const asset = spec.assets.find((a) => a.id === clip.asset);
  if (!asset) return null;
  const imageSize = { width: asset.width, height: asset.height };
  const p = clip.duration > 0 ? clamp((t - start) / clip.duration, 0, 1) : 1;
  const key = interpolate(clip.motion, easing(spec.style.easing, p));
  const center = { x: key.cx, y: key.cy };

  if (clip.fit === "cover") {
    return {
      asset: asset.id, fit: "cover",
      crop: cropRect(imageSize, frameAspect, center, key.zoom),
      dest: { x: 0, y: 0, w: 1, h: 1 },
      opacity, offset, z, backdrop: null,
    };
  }
  let backdrop: Backdrop | null = null;
  if (spec.style.background.type === "blur") {
    // σ = amount · 0,05 · ramens höjd i utpixlar.
    const sigma = (spec.style.background.amount ?? 0) * 0.05 * frameHeight;
    backdrop = { crop: cropRect(imageSize, frameAspect, center, 1), sigma };
  }
  return {
    asset: asset.id, fit: "contain-blur",
    crop: containCrop(center, key.zoom),
    dest: containRect(imageSize, frameAspect),
    opacity, offset, z, backdrop,
  };
}

// ---- Rutor (version 2, docs/reel-spec-v2.md) ----

/** Rutornas dest i ramkoordinater för stack och side. gutter = andel av ramens kortsida, klampad till [0, 0,1]. */
export function panelDests(layout: PanelLayout, frameAspect: number, gutter: number): Rect[] {
  const g = Math.min(Math.max(gutter, 0), 0.1);
  if (layout === "stack") {
    const gy = g * Math.min(frameAspect, 1);
    const h = (1 - gy) / 2;
    return [{ x: 0, y: 0, w: 1, h }, { x: 0, y: (1 + gy) / 2, w: 1, h }];
  }
  if (layout === "side") {
    const gx = g * Math.min(1, 1 / frameAspect);
    const w = (1 - gx) / 2;
    return [{ x: 0, y: 0, w, h: 1 }, { x: (1 + gx) / 2, y: 0, w, h: 1 }];
  }
  return [{ x: 0, y: 0, w: 1, h: 1 }];
}

/** Cover-utsnittet inom en rutas source mot en ruta med bildförhållandet destAspect, i hela bildens koordinater. */
export function panelCrop(imageSize: Size, source: UnitRect | null | undefined, destAspect: number,
                          center: { x: number; y: number }, zoom: number): Rect {
  if (!source || !(source.w > 0) || !(source.h > 0)) return cropRect(imageSize, destAspect, center, zoom);
  const s = source;
  const local = { x: (center.x - s.x) / s.w, y: (center.y - s.y) / s.h };
  const r = cropRect({ width: s.w * imageSize.width, height: s.h * imageSize.height }, destAspect, local, zoom);
  return { x: s.x + r.x * s.w, y: s.y + r.y * s.h, w: r.w * s.w, h: r.h * s.h };
}

/** Längden på en intern skjutning mellan två rutor i sequence: min(0,4, D / (2n)). */
export function sequencePushDuration(clipDuration: number, panelCount: number): number {
  return Math.min(0.4, clipDuration / (2 * Math.max(panelCount, 1)));
}

function panelLayers(spec: ReelSpec, index: number, start: number, t: number, frameAspect: number,
                     opacity: number, offset: { x: number; y: number }, z: number): LayerState[] {
  const clip = spec.timeline[index];
  const panels = clip.panels;
  const layout = clip.layout;
  if (clip.fit !== "panels" || !layout || !panels || panels.length < 2 || !(clip.duration > 0)) return [];
  const d = clip.duration;
  const tau = clamp(t - start, 0, d);

  const make = (k: number, dest: Rect, motionP: number, panelOpacity: number, panelOffset: { x: number; y: number }): LayerState | null => {
    if (!(panelOpacity > 0)) return null;
    const asset = spec.assets.find((a) => a.id === panels[k].asset);
    if (!asset) return null;
    const key = interpolate(panels[k].motion, easing(spec.style.easing, motionP));
    const destAspect = dest.w * frameAspect / dest.h;
    const crop = panelCrop({ width: asset.width, height: asset.height }, panels[k].source, destAspect,
      { x: key.cx, y: key.cy }, key.zoom);
    return {
      asset: asset.id, fit: "panels", crop, dest, opacity, offset, z, backdrop: null,
      panel: { index: k, opacity: panelOpacity, offset: panelOffset },
    };
  };
  const some = (...l: (LayerState | null)[]): LayerState[] => l.filter((x): x is LayerState => x !== null);

  if (layout === "stack" || layout === "side") {
    if (panels.length !== 2) return [];
    const dests = panelDests(layout, frameAspect, clip.gutter ?? DEFAULT_GUTTER);
    const p = clamp(tau / d, 0, 1);
    const din = clamp(clip.entrance?.duration ?? DEFAULT_ENTRANCE_DURATION, 0, d / 2);
    const stagger = clamp(clip.entrance?.stagger ?? DEFAULT_ENTRANCE_STAGGER, 0, d / 2);
    const type = clip.entrance?.type;
    return some(...[0, 1].map((k) => {
      let o = 1;
      let off = { x: 0, y: 0 };
      if (type === "fade" || type === "slide") {
        const q = din > 0 ? clamp((tau - k * stagger) / din, 0, 1) : 1;
        const e = easing(spec.style.easing, q);
        if (type === "fade") {
          o = e;
        } else {
          const sign = k === 0 ? -1 : 1;
          off = layout === "stack" ? { x: sign * (1 - e), y: 0 } : { x: 0, y: sign * (1 - e) };
        }
      }
      return make(k, dests[k], p, o, off);
    }));
  }

  // sequence
  const n = panels.length;
  const seg = d / n;
  const dp = sequencePushDuration(d, n);
  const full = { x: 0, y: 0, w: 1, h: 1 };
  const progress = (k: number): number => clamp((tau - k * seg) / seg, 0, 1);
  for (let k = 1; k < n; k++) {
    const from = k * seg - dp / 2;
    if (!(tau >= from && tau < from + dp)) continue;
    const e = easing(spec.style.easing, (tau - from) / dp);
    return some(
      make(k - 1, full, progress(k - 1), 1, { x: -e, y: 0 }),
      make(k, full, progress(k), 1, { x: 1 - e, y: 0 }),
    );
  }
  let current = 0;
  for (let k = 1; k < n; k++) if (tau >= k * seg + dp / 2) current = k;
  return some(make(current, full, progress(current), 1, { x: 0, y: 0 }));
}

/** Lagren som syns vid tid t (klampas till [0, total]), lägst z först. */
export function state(t: number, spec: ReelSpec, outputSize: Size): LayerState[] {
  if (spec.timeline.length === 0) return [];
  const starts = clipStarts(spec);
  t = Math.min(Math.max(t, 0), totalDuration(spec));
  let i = 0;
  for (let k = 0; k < spec.timeline.length; k++) if (starts[k] <= t) i = k;

  const frameAspect = outputSize.width / outputSize.height;
  const layer = (clip: number, opacity: number, offset: { x: number; y: number }, z: number): LayerState[] => {
    if (!(opacity > 0)) return [];
    if (spec.timeline[clip].fit === "panels") return panelLayers(spec, clip, starts[clip], t, frameAspect, opacity, offset, z);
    const l = makeLayer(spec, clip, starts[clip], t, frameAspect, outputSize.height, opacity, offset, z);
    return l ? [l] : [];
  };
  const zero = { x: 0, y: 0 };

  const tr = transition(spec, i);
  if (tr && t < starts[i] + tr.duration) {
    const e = easing(spec.style.easing, (t - starts[i]) / tr.duration);
    switch (tr.type) {
      case "crossfade":
        return [...layer(i - 1, 1, zero, 0), ...layer(i, e, zero, 1)];
      case "push": {
        const dir = tr.direction ?? "left";
        const dx = dir === "left" ? -1 : dir === "right" ? 1 : 0;
        const dy = dir === "up" ? -1 : dir === "down" ? 1 : 0;
        return [
          ...layer(i - 1, 1, { x: dx * e, y: dy * e }, 0),
          ...layer(i, 1, { x: dx * (e - 1), y: dy * (e - 1) }, 1),
        ];
      }
      case "fadeThroughBlack": {
        const q = (t - starts[i]) / tr.duration;
        if (q < 0.5) return layer(i - 1, 1 - easing(spec.style.easing, 2 * q), zero, 0);
        return layer(i, easing(spec.style.easing, 2 * q - 1), zero, 1);
      }
      default:
        break;
    }
  }
  return layer(i, 1, zero, 1);
}
