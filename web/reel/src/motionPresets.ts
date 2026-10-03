// Rörelseförval för redigeraren. Port av de manuella förvalen i
// PhotoFlow/Sources/Services/Reel/ReelMotionPlanner.swift (zoomIn, zoomOut,
// panRight, panLeft, contain) så att en ändring i webben ger samma nyckelbilder
// som när Mac-appen planerar klippet. "Automatisk" ändrar inte klippets motion
// (utom för nya klipp, där `kindOf` väljer som Swift-sidan).
//
// Skillnad mot Swift: planeraren håller alternerande tillstånd (zoom in/ut,
// panorera höger/vänster, driftens riktning) över hela listan. Här finns inget
// sådant tillstånd, så alternering ersätts av klippets index (jämnt = in/höger).

import type { Asset, Clip, Fit, MotionKey } from "./reelSpec.ts";
import { containCrop, cropRect } from "./reelTimeline.ts";

export const PRESETS = ["auto", "zoomIn", "zoomOut", "panRight", "panLeft", "contain"] as const;
export type Preset = (typeof PRESETS)[number];

export const PRESET_LABELS: Record<Preset, string> = {
  auto: "Automatisk",
  zoomIn: "Zooma in",
  zoomOut: "Zooma ut",
  panRight: "Panorera →",
  panLeft: "Panorera ←",
  contain: "Hela bilden",
};

// Konstanter som i ReelMotionPlanner.
export const FIRST_DURATION = 3.0;
export const LAST_DURATION = 3.4;
export const PAN_DURATION = 2.8;
export const ZOOM_DURATION = 2.5;
export const CONTAIN_DURATION = 2.6;
export const ZOOM_AMOUNT = 1.12;
export const CONTAIN_ZOOM_AMOUNT = 1.06;
export const MAX_PAN_PER_SECOND = 0.10;
export const MIN_PAN_TRAVEL = 0.25;
export const MAX_ZOOM_PER_SECOND = 0.04;
export const WIDE_SUBJECT = 0.85;
export const CLOSING_MOTION_SCALE = 0.6;

type Kind = "zoom" | "pan" | "containBlur";

function visibleWidth(imageAspect: number, frameAspect: number): number {
  return Math.min(1, frameAspect / imageAspect);
}

/** Automatiskt val av rörelsetyp för en bild (ReelMotionPlanner.kind(of:)). */
export function kindOf(asset: Asset, frameAspect: number): Kind {
  const w = visibleWidth(asset.width / asset.height, frameAspect);
  const s = asset.analysis?.focusWidth ?? asset.analysis?.salientWidth ?? 0.5;
  if (s <= w || w >= WIDE_SUBJECT) return "zoom";
  if (s <= WIDE_SUBJECT) return "pan";
  return asset.analysis?.category === "Exteriör" ? "containBlur" : "pan";
}

function baseDuration(kind: Kind): number {
  return kind === "pan" ? PAN_DURATION : kind === "zoom" ? ZOOM_DURATION : CONTAIN_DURATION;
}

function endZoom(amount: number, scale: number, duration: number): number {
  const wanted = 1 + (amount - 1) * scale;
  return Math.min(wanted, Math.pow(1 + MAX_ZOOM_PER_SECOND, duration));
}

function clampedCenter(asset: Asset, frameAspect: number, fit: Fit, cx: number, cy: number, zoom: number) {
  if (fit === "cover") {
    const r = cropRect(asset, frameAspect, { x: cx, y: cy }, zoom);
    return { x: r.x + r.w / 2, y: r.y + r.h / 2 };
  }
  const r = containCrop({ x: cx, y: cy }, zoom);
  return { x: r.x + r.w / 2, y: r.y + r.h / 2 };
}

function key(asset: Asset, frameAspect: number, fit: Fit, cx: number, cy: number, zoom: number): MotionKey {
  const p = clampedCenter(asset, frameAspect, fit, cx, cy, zoom);
  return { cx: p.x, cy: p.y, zoom };
}

function panRange(asset: Asset, frameAspect: number, centerX: number, travel: number, sign: number): [number, number] {
  const r = cropRect(asset, frameAspect, { x: 0.5, y: 0.5 }, 1);
  const lo = r.w / 2, hi = 1 - r.w / 2;
  if (!(hi > lo)) return [0.5, 0.5];
  const t = Math.min(travel, hi - lo);
  const start = Math.min(Math.max(centerX - t / 2, lo), hi - t);
  const end = start + t;
  return sign > 0 ? [start, end] : [end, start];
}

export interface PlanOptions {
  asset: Asset;
  frameAspect: number;
  preset: Preset;
  /** Klippets längd om den är låst, annars räknas den ut som i Swift. */
  lockedDuration?: number;
  /** Plats i tidslinjen (för alternering och första/sista-längd). */
  index: number;
  count: number;
  /** Klippets nuvarande motion/zoomriktning (för "Hela bilden" och "Automatisk"). */
  current?: Clip;
}

/** Nytt `fit`, `motion` och `duration` för klippet med förvalet `preset`. */
export function planClip(o: PlanOptions): Pick<Clip, "fit" | "motion" | "duration"> {
  const { asset, frameAspect, index, count } = o;
  const isFirst = index === 0;
  const isLast = index === count - 1 && count > 1;
  const kind: Kind =
    o.preset === "zoomIn" || o.preset === "zoomOut" ? "zoom"
    : o.preset === "panRight" || o.preset === "panLeft" ? "pan"
    : o.preset === "contain" ? "containBlur"
    : kindOf(asset, frameAspect);
  const autoDuration = isFirst ? FIRST_DURATION : isLast ? LAST_DURATION : baseDuration(kind);
  const duration = o.lockedDuration ?? autoDuration;
  const scale = isLast ? CLOSING_MOTION_SCALE : 1;
  const focus = asset.analysis?.focus ?? { x: 0.5, y: 0.5 };
  const even = index % 2 === 0;

  if (kind === "pan") {
    const w = visibleWidth(asset.width / asset.height, frameAspect);
    const s = asset.analysis?.salientWidth ?? 1;
    const cap = MAX_PAN_PER_SECOND * duration * scale;
    const travel = Math.min(cap, Math.max(s - w, MIN_PAN_TRAVEL * scale));
    const sign = o.preset === "panRight" ? 1 : o.preset === "panLeft" ? -1 : even ? 1 : -1;
    const [a, b] = panRange(asset, frameAspect, focus.x, travel, sign);
    const y = clampedCenter(asset, frameAspect, "cover", focus.x, focus.y, 1).y;
    return { fit: "cover", duration, motion: { from: { cx: a, cy: y, zoom: 1 }, to: { cx: b, cy: y, zoom: 1 } } };
  }

  const fit: Fit = kind === "zoom" ? "cover" : "contain-blur";
  const amount = kind === "zoom" ? ZOOM_AMOUNT : CONTAIN_ZOOM_AMOUNT;
  const end = endZoom(amount, scale, duration);
  let goIn: boolean;
  if (o.preset === "zoomIn") goIn = true;
  else if (o.preset === "zoomOut") goIn = false;
  else if (o.preset === "contain" && o.current?.fit === "contain-blur") goIn = o.current.motion.to.zoom >= o.current.motion.from.zoom;
  else goIn = even;
  const [z0, z1] = goIn ? [1, end] : [end, 1];
  const drift = kind === "zoom" ? 0.01 * (even ? 1 : -1) : 0;
  return {
    fit, duration,
    motion: {
      from: key(asset, frameAspect, fit, focus.x - drift, focus.y, z0),
      to: key(asset, frameAspect, fit, focus.x + drift, focus.y, z1),
    },
  };
}
