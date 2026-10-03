// Exakt port av PhotoFlow/Sources/Shared/ReelTimeline.swift: ren tidslinjematematik
// (klippstarter, easing, utsnitt, lagerstatus vid tid t). Ingen DOM. Den
// normativa beskrivningen är docs/reel-spec-v1.md; testas mot
// PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json (tolerans 1e-9).
//
// Alla utsnitt är normaliserade bildkoordinater [0,1]² (y neråt) och alla
// förskjutningar normaliserade ramkoordinater.

import type { Easing, Fit, Motion, MotionKey, ReelSpec, Transition } from "./reelSpec.ts";

export interface Rect { x: number; y: number; w: number; h: number }
export interface Size { width: number; height: number }

export interface Backdrop { crop: Rect; sigma: number }

export interface LayerState {
  asset: string;
  fit: Fit;
  crop: Rect;
  dest: Rect;
  opacity: number;
  offset: { x: number; y: number };
  z: number;
  backdrop: Backdrop | null;
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

/** Lagren som syns vid tid t (klampas till [0, total]), lägst z först. */
export function state(t: number, spec: ReelSpec, outputSize: Size): LayerState[] {
  if (spec.timeline.length === 0) return [];
  const starts = clipStarts(spec);
  t = Math.min(Math.max(t, 0), totalDuration(spec));
  let i = 0;
  for (let k = 0; k < spec.timeline.length; k++) if (starts[k] <= t) i = k;

  const frameAspect = outputSize.width / outputSize.height;
  const layer = (clip: number, opacity: number, offset: { x: number; y: number }, z: number): LayerState | null =>
    opacity > 0
      ? makeLayer(spec, clip, starts[clip], t, frameAspect, outputSize.height, opacity, offset, z)
      : null;
  const some = (...l: (LayerState | null)[]): LayerState[] => l.filter((x): x is LayerState => x !== null);
  const zero = { x: 0, y: 0 };

  const tr = transition(spec, i);
  if (tr && t < starts[i] + tr.duration) {
    const e = easing(spec.style.easing, (t - starts[i]) / tr.duration);
    switch (tr.type) {
      case "crossfade":
        return some(layer(i - 1, 1, zero, 0), layer(i, e, zero, 1));
      case "push": {
        const dir = tr.direction ?? "left";
        const dx = dir === "left" ? -1 : dir === "right" ? 1 : 0;
        const dy = dir === "up" ? -1 : dir === "down" ? 1 : 0;
        return some(
          layer(i - 1, 1, { x: dx * e, y: dy * e }, 0),
          layer(i, 1, { x: dx * (e - 1), y: dy * (e - 1) }, 1),
        );
      }
      case "fadeThroughBlack": {
        const q = (t - starts[i]) / tr.duration;
        if (q < 0.5) return some(layer(i - 1, 1 - easing(spec.style.easing, 2 * q), zero, 0));
        return some(layer(i, easing(spec.style.easing, 2 * q - 1), zero, 1));
      }
      default:
        break;
    }
  }
  return some(layer(i, 1, zero, 1));
}
