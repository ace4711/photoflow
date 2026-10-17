// Webbredigerare för ReelSpec v1. Mobil först. Två lägen:
//  - Mäklarläge: finns en token i URL-fragmentet (/m#<token>) hämtas filmen från
//    servern (GET /api/v1/share), ändringar sparas med PUT /api/v1/share/spec
//    (If-Match) och "Godkänn" anropar POST /api/v1/share/approve.
//  - Lokalt reservläge utan fragment: reel.json och bilder läses lokalt
//    (mapp/filer/släpp) eller via ?spec=<url>, och "Godkänn" laddar bara ner
//    en uppdaterad reel.json.

import { parseReelSpec, ReelSpecError } from "./reelSpec.ts";
import type { Asset, Clip, ReelSpec } from "./reelSpec.ts";
import { clipStarts, totalDuration, transition } from "./reelTimeline.ts";
import { renderFrame } from "./canvasRenderer.ts";
import type { DrawableImage } from "./canvasRenderer.ts";
import { approvedCopy, editedCopy, sortKeys } from "./approve.ts";
import { ShareClient, ShareError, STATUS_TEXT, tokenFromHash } from "./shareApi.ts";
import type { ShareView } from "./shareApi.ts";
import { matchAssets } from "./assetMatcher.ts";
import { CUSTOM, CUSTOM_LABEL, MAX_CLIPS, PRESETS, PRESET_LABELS } from "./motionPresets.ts";
import type { Preset } from "./motionPresets.ts";
import * as regi from "./regi.ts";
import { LOCKED_BY_PHOTOGRAPHER, RegiError } from "./regi.ts";

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;

// ---------------------------------------------------------------- tillstånd

let spec: ReelSpec | null = null;
const images = new Map<string, DrawableImage>();
const thumbs = new Map<string, string>();
const fileNames = new Map<string, string>();
let selected = 0;
let time = 0;
let playing = false;
let playStartedAt = 0;
let pendingOps: string[] = [];
let sizeW = 540, sizeH = 960;

/** Mäklarläge (token i fragmentet). `null` i det lokala reservläget. */
interface ShareState {
  token: string;
  client: ShareClient;
  view: ShareView;
  /** Revisionen på servern som den lokala specen utgår från. */
  revision: number;
  dirty: boolean;
  /** sha256 → signerade URL:er. */
  urls: Map<string, { full: string | null; thumb: string | null }>;
  /** Tillgångar där fullstorleksvarianten (w1600) är inläst. */
  fullLoaded: Set<string>;
  poll?: number;
}
let share: ShareState | null = null;
const MAX_CLIP_SECONDS = (): number => (share ? 10 : 15);

const canvas = $<HTMLCanvasElement>("canvas");
const ctx = canvas.getContext("2d")!;
const sv = (n: number): string => n.toFixed(1).replace(".", ",");

function message(text: string, kind: "info" | "err" = "info"): void {
  const el = $("msg");
  el.textContent = text;
  el.className = "msg" + (kind === "err" ? " err" : "");
  el.hidden = text === "";
}

function output() { return spec!.outputs[0]; }
function frameAspect(): number { return output().width / output().height; }
function assetOf(id: string): Asset | undefined { return spec!.assets.find((a) => a.id === id); }

// ------------------------------------------------------------ bildladdning

const MAX_EDGE = 2600;

async function decode(blob: Blob): Promise<ImageBitmap> {
  let bmp = await createImageBitmap(blob);
  const long = Math.max(bmp.width, bmp.height);
  if (long > MAX_EDGE) {
    const k = MAX_EDGE / long;
    const small = await createImageBitmap(bmp, {
      resizeWidth: Math.round(bmp.width * k), resizeHeight: Math.round(bmp.height * k), resizeQuality: "high",
    });
    bmp.close();
    bmp = small;
  }
  return bmp;
}

function makeThumb(bmp: ImageBitmap): string {
  const k = 160 / Math.max(bmp.width, bmp.height);
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(bmp.width * k));
  c.height = Math.max(1, Math.round(bmp.height * k));
  c.getContext("2d")!.drawImage(bmp, 0, 0, c.width, c.height);
  return c.toDataURL("image/jpeg", 0.75);
}

async function addImage(assetId: string, blob: Blob, name: string): Promise<void> {
  const bmp = await decode(blob);
  images.set(assetId, bmp);
  thumbs.set(assetId, makeThumb(bmp));
  fileNames.set(assetId, name);
}

function reset(): void {
  stop();
  for (const i of images.values()) (i as ImageBitmap).close?.();
  images.clear(); thumbs.clear(); fileNames.clear();
  spec = null; selected = 0; time = 0; pendingOps = [];
  if (share?.poll) clearInterval(share.poll);
}

// ------------------------------------------------------------------ inläsning

async function loadFromFiles(files: File[]): Promise<void> {
  message("Läser in…");
  const jsons = files.filter((f) => /\.json$/i.test(f.name))
    .sort((a, b) => Number(/reel\.json$/i.test(b.name)) - Number(/reel\.json$/i.test(a.name)));
  if (jsons.length === 0) { message("Hittade ingen reel.json bland filerna.", "err"); return; }
  let parsed: ReelSpec | null = null;
  let firstError = "";
  for (const j of jsons) {
    try { parsed = parseReelSpec(await j.text()); break; }
    catch (e) { firstError ||= `${j.name}: ${(e as Error).message}`; }
  }
  if (!parsed) { message(firstError, "err"); return; }
  reset();
  spec = parsed;
  const m = await matchAssets(spec.assets, files);
  for (const [id, f] of m.matched) {
    try { await addImage(id, f, f.name); }
    catch { m.missing.push(id); }
  }
  const bySha = [...m.how.values()].filter((h) => h === "sha256").length;
  start(m.missing, bySha);
}

async function loadFromUrl(url: string): Promise<void> {
  message("Hämtar reel.json…");
  let parsed: ReelSpec;
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    parsed = parseReelSpec(await r.text());
  } catch (e) {
    message(e instanceof ReelSpecError ? e.message : `Kunde inte hämta ${url} (${(e as Error).message}).`, "err");
    return;
  }
  reset();
  spec = parsed;
  const base = new URL(url, location.href);
  const missing: string[] = [];
  await Promise.all(spec.assets.map(async (a) => {
    for (const s of a.sources) {
      const href = s.kind === "url" && s.url ? s.url : s.kind === "local" && s.path ? s.path : null;
      if (!href) continue;
      try {
        const u = new URL(href, base);
        const r = await fetch(u);
        if (!r.ok) continue;
        await addImage(a.id, await r.blob(), decodeURIComponent(u.pathname.split("/").pop() ?? a.id));
        return;
      } catch { /* prova nästa källa */ }
    }
    missing.push(a.id);
  }));
  start(missing, 0);
}

function start(missing: string[], bySha: number): void {
  if (!spec) return;
  const s = spec;
  const used = new Set(s.timeline.map((c) => c.asset));
  const missingUsed = missing.filter((id) => used.has(id));
  const parts: string[] = [];
  if (missingUsed.length) parts.push(`Hittade inte bilderna för: ${missingUsed.join(", ")}. De visas som svart.`);
  if (bySha) parts.push(`${bySha} bild(er) hittades via sha256 eftersom filnamnet inte stämde.`);
  message(parts.join(" "), missingUsed.length ? "err" : "info");
  $("loader").hidden = true;
  $("editor").hidden = false;
  document.documentElement.style.setProperty("--arn", String(frameAspect()));
  resizeCanvas();
  selected = 0; time = 0;
  renderAll();
}

// ------------------------------------------------------------------ uppspelning

function total(): number { return spec ? totalDuration(spec) : 0; }

function draw(): void {
  if (!spec) return;
  renderFrame(ctx, spec, time, canvas.width, canvas.height, { images, ...scratch });
}
const scratch: { scratch?: import("./canvasRenderer.ts").Scratch; backdropScratch?: import("./canvasRenderer.ts").Scratch } = {};

function updateTransport(): void {
  const t = total();
  const scrub = $<HTMLInputElement>("scrub");
  scrub.value = String(t > 0 ? Math.round((time / t) * 1000) : 0);
  $("time").textContent = `${sv(time)} / ${sv(t)} s`;
  $("play").textContent = playing ? "⏸" : "▶";
  $("play").setAttribute("aria-label", playing ? "Pausa" : "Spela");
  highlightSelected();
}

function tick(now: number): void {
  if (!playing) return;
  time = (now - playStartedAt) / 1000;
  if (time >= total()) { time = total(); playing = false; }
  draw(); updateTransport();
  if (playing) requestAnimationFrame(tick);
}
function play(): void {
  if (!spec || total() <= 0) return;
  if (time >= total() - 1e-6) time = 0;
  playing = true;
  playStartedAt = performance.now() - time * 1000;
  requestAnimationFrame(tick);
}
function stop(): void { playing = false; }
function seek(t: number): void { time = Math.min(Math.max(t, 0), total()); draw(); updateTransport(); }

function resizeCanvas(): void {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const cssW = canvas.getBoundingClientRect().width || 360;
  sizeW = Math.max(120, Math.min(1080, Math.round(cssW * dpr)));
  sizeH = Math.max(120, Math.round(sizeW / frameAspect()));
  if (canvas.width !== sizeW || canvas.height !== sizeH) { canvas.width = sizeW; canvas.height = sizeH; }
  draw();
}

// ------------------------------------------------------------------ redigering

function logEdit(op: string): void { if (pendingOps[pendingOps.length - 1] !== op) pendingOps.push(op); }

function changed(ops: string[]): void {
  if (ops.length === 0) return;
  ops.forEach(logEdit);
  if (share) { share.dirty = true; updateShareUi(); }
  time = Math.min(time, total());
  selected = Math.min(selected, Math.max(0, spec!.timeline.length - 1));
  renderAll();
}

// Själva ändringarna (och reglerna för fotografens lås) finns i regi.ts.

function attempt(f: () => string[]): string[] | null {
  try {
    return f();
  } catch (e) {
    if (e instanceof RegiError) { message(e.message, "err"); return null; }
    throw e;
  }
}

function moveClip(from: number, to: number): void {
  if (!spec) return;
  const ops = regi.moveClip(spec, from, to, frameAspect());
  if (!ops.length) return;
  selected = to;
  changed(ops);
  seekToClip(to);
}

function removeClip(i: number): void {
  if (!spec) return;
  const clip = spec.timeline[i];
  if (clip && spec.timeline.length > 1 && regi.isPinned(spec, clip) &&
      !confirm("Fotografen har låst bilden så att den alltid är med. Ta bort den ändå? Låsningen släpps då, så bilden kommer inte tillbaka vid ett nytt förslag.")) return;
  const ops = attempt(() => regi.removeClip(spec!, i, frameAspect()));
  if (!ops) return;
  changed(ops);
  if (ops.includes("unpin")) message("Bilden togs bort och fotografens låsning av den släpptes.");
}

function setDuration(i: number, d: number): void {
  if (!spec) return;
  changed(regi.setDuration(spec, i, d, MAX_CLIP_SECONDS()));
}

function setPreset(i: number, preset: Preset): void {
  if (!spec) return;
  const c = spec.timeline[i];
  if (c?.motionPreset === CUSTOM &&
      !confirm("Fotografen har gjort en egen rörelse för bilden. Vill du ersätta den med förvalet?")) {
    renderStrip(); // återställ menyn till "Egen rörelse"
    return;
  }
  changed(regi.setPreset(spec, i, preset, frameAspect()));
}

async function addClip(assetId: string): Promise<void> {
  if (!spec) return;
  const asset = assetOf(assetId);
  if (!asset) return;
  const excluded = regi.isExcluded(spec, asset);
  if (excluded && regi.canAddMore(spec) &&
      !confirm("Fotografen har uteslutit bilden ur filmen. Lägga till den ändå? Uteslutningen släpps då.")) return;
  if (share) await ensureFull(assetId);
  const ops = attempt(() => regi.addClip(spec!, assetId, frameAspect(), { allowExcluded: excluded }));
  if (!ops) return;
  const index = spec.timeline.length - 1;
  selected = index;
  changed(ops);
  seekToClip(index);
}

function seekToClip(i: number): void {
  if (!spec) return;
  selected = i;
  const starts = clipStarts(spec);
  const d = transition(spec, i)?.duration ?? 0;
  stop();
  seek(starts[i] + d + 0.05);
}

// ------------------------------------------------------------------ vy

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function renderAll(): void {
  if (!spec) return;
  renderStrip(); renderCandidates(); draw(); updateTransport();
  $("total").textContent = `${spec.timeline.length} klipp, ${sv(total())} s`;
  const film = regi.filmLocks(spec);
  const box = $("filmLocks");
  box.replaceChildren(...film.map((t) => lockBadge(t, `${t}. ${LOCKED_BY_PHOTOGRAPHER}.`)));
  box.hidden = film.length === 0;
}

function highlightSelected(): void {
  if (!spec) return;
  const starts = clipStarts(spec);
  let cur = 0;
  starts.forEach((s, k) => { if (s <= time) cur = k; });
  [...$("strip").children].forEach((c, k) => c.classList.toggle("sel", k === cur));
}

function thumbEl(assetId: string, onClick?: () => void): HTMLElement {
  const url = thumbs.get(assetId);
  if (!url) {
    const m = el("div", "thumb missing", "Saknas");
    return m;
  }
  const img = el("img", "thumb");
  img.src = url; img.alt = ""; img.draggable = false;
  if (onClick) img.addEventListener("click", onClick);
  return img;
}

const SVG_NS = "http://www.w3.org/2000/svg";

/** Liten låsikon (SVG, följer textfärgen). */
function lockIcon(): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("aria-hidden", "true");
  svg.classList.add("lock-icon");
  const body = document.createElementNS(SVG_NS, "rect");
  for (const [k, v] of [["x", "3"], ["y", "7"], ["width", "10"], ["height", "7"], ["rx", "1.5"], ["fill", "currentColor"]]) body.setAttribute(k, v);
  const shackle = document.createElementNS(SVG_NS, "path");
  for (const [k, v] of [["d", "M5.5 7V5a2.5 2.5 0 0 1 5 0v2"], ["fill", "none"], ["stroke", "currentColor"], ["stroke-width", "1.6"]]) shackle.setAttribute(k, v);
  svg.append(body, shackle);
  return svg;
}

/** Låsmärke: ikon och text, med en förklaring i title och för skärmläsare. */
function lockBadge(text: string, title: string): HTMLElement {
  const b = el("span", "lock");
  b.title = title;
  b.setAttribute("aria-label", title);
  b.append(lockIcon(), el("span", undefined, text));
  return b;
}

function renderStrip(): void {
  const strip = $("strip");
  strip.replaceChildren();
  const s = spec!;
  s.timeline.forEach((clip, i) => {
    const asset = assetOf(clip.asset)!;
    const li = el("li", "clip");
    const grip = el("div", "grip", "⋮⋮");
    grip.title = "Dra för att flytta";
    grip.addEventListener("pointerdown", (e) => startDrag(e, li, grip, i));

    const locks = regi.clipLocks(s, i);
    const info = el("div", "info");
    info.append(el("div", "name", `${i + 1}. ${asset.analysis?.room ?? asset.id}`),
      el("div", "sub", fileNames.get(clip.asset) ?? "bilden saknas"));
    // Övergången in visas men går inte att ändra här (fotografen styr övergångar i Mac-appen).
    if (locks.transition) {
      const t = el("div", "trans", `In: ${locks.transition}`);
      if (locks.transitionLocked) {
        t.append(" ", lockBadge(LOCKED_BY_PHOTOGRAPHER, "Övergången är vald av fotografen och följer med klippet."));
      }
      info.append(t);
    }
    if (locks.pinned) {
      info.append(lockBadge(`Alltid med · ${LOCKED_BY_PHOTOGRAPHER.toLowerCase()}`,
        "Fotografen har låst bilden så att den alltid är med i filmen."));
    }

    const controls = el("div", "controls");
    const sel = el("select");
    sel.setAttribute("aria-label", "Rörelse");
    const current: string = locks.customMotion ? CUSTOM
      : (PRESETS as readonly string[]).includes(clip.motionPreset ?? "") ? clip.motionPreset! : "auto";
    if (locks.customMotion) {
      // Egen rörelse är inget menyval: visas bara för klippet som har den.
      const o = el("option", undefined, CUSTOM_LABEL); o.value = CUSTOM; o.selected = true; sel.append(o);
    }
    for (const p of PRESETS) {
      const o = el("option", undefined, PRESET_LABELS[p]); o.value = p; o.selected = p === current; sel.append(o);
    }
    sel.addEventListener("change", () => { if (sel.value !== CUSTOM) setPreset(i, sel.value as Preset); });
    const motionBox = el("div", "motion");
    motionBox.append(sel);
    if (locks.customMotion) {
      motionBox.append(lockBadge(LOCKED_BY_PHOTOGRAPHER,
        "Fotografen har gjort en egen rörelse för bilden. Den behålls tills du väljer ett annat förval."));
    }

    const dur = el("span", "dur");
    const minus = el("button", "btn small", "−"); minus.setAttribute("aria-label", "Kortare");
    const plus = el("button", "btn small", "+"); plus.setAttribute("aria-label", "Längre");
    const input = el("input"); input.type = "number"; input.step = "0.1"; input.min = "0.5"; input.max = String(MAX_CLIP_SECONDS());
    input.inputMode = "decimal"; input.value = clip.duration.toFixed(1); input.setAttribute("aria-label", "Längd i sekunder");
    minus.addEventListener("click", () => setDuration(i, clip.duration - 0.5));
    plus.addEventListener("click", () => setDuration(i, clip.duration + 0.5));
    input.addEventListener("change", () => setDuration(i, parseFloat(input.value.replace(",", "."))));
    dur.append(minus, input, el("span", "muted", "s"), plus);
    if (locks.durationLocked) {
      const l = el("span", "lock icon-only");
      l.title = "Längden är låst och räknas inte om automatiskt.";
      l.setAttribute("aria-label", l.title);
      l.append(lockIcon());
      dur.append(l);
    }

    const up = el("button", "btn small", "↑"); up.setAttribute("aria-label", "Flytta upp"); up.disabled = i === 0;
    const down = el("button", "btn small", "↓"); down.setAttribute("aria-label", "Flytta ner"); down.disabled = i === s.timeline.length - 1;
    const del = el("button", "btn small", "✕"); del.setAttribute("aria-label", "Ta bort");
    up.addEventListener("click", () => moveClip(i, i - 1));
    down.addEventListener("click", () => moveClip(i, i + 1));
    del.addEventListener("click", () => removeClip(i));
    controls.append(motionBox, dur, el("span", "spacer"), up, down, del);

    li.append(grip, thumbEl(clip.asset, () => seekToClip(i)), info, controls);
    strip.append(li);
  });
}

function renderCandidates(): void {
  const s = spec!;
  const box = $("candidates");
  box.replaceChildren();
  // Uteslutna bilder visas sist och gråade; de kan bara läggas till efter en fråga.
  const rest = regi.candidates(s, (id) => images.has(id));
  $("candWrap").hidden = rest.length === 0;
  const full = !regi.canAddMore(s);
  const note = $("candFull");
  note.hidden = !full;
  note.textContent = `Högst ${MAX_CLIPS} klipp i en film. Ta bort ett klipp för att lägga till en annan bild.`;
  for (const { asset: a, excluded } of rest) {
    const c = el("div", excluded ? "cand excluded" : "cand");
    const b = el("button", "btn small", excluded ? "Lägg till ändå" : "Lägg till");
    b.disabled = full;
    b.addEventListener("click", () => void addClip(a.id));
    c.append(thumbEl(a.id), el("div", undefined, a.analysis?.room ?? a.id));
    if (excluded) c.append(el("div", "why", "Utesluten av fotografen"));
    c.append(b);
    box.append(c);
  }
}

// Dra för att ordna om (pekare: fungerar med mus och touch; greppet har touch-action: none).
function startDrag(e: PointerEvent, li: HTMLElement, grip: HTMLElement, from: number): void {
  e.preventDefault();
  grip.setPointerCapture(e.pointerId);
  const items = [...$("strip").children] as HTMLElement[];
  const rects = items.map((c) => c.getBoundingClientRect());
  const startY = e.clientY;
  let to = from;
  li.classList.add("dragging");
  const move = (ev: PointerEvent): void => {
    const dy = ev.clientY - startY;
    li.style.transform = `translateY(${dy}px)`;
    const center = rects[from].top + rects[from].height / 2 + dy;
    to = rects.findIndex((r) => center < r.bottom);
    if (to < 0) to = rects.length - 1;
    items.forEach((c, k) => {
      c.classList.toggle("drop-before", k === to && to < from);
      c.classList.toggle("drop-after", k === to && to > from);
    });
  };
  const end = (ev: PointerEvent): void => {
    grip.removeEventListener("pointermove", move);
    grip.removeEventListener("pointerup", end);
    grip.removeEventListener("pointercancel", end);
    li.classList.remove("dragging"); li.style.transform = "";
    items.forEach((c) => c.classList.remove("drop-before", "drop-after"));
    if (ev.type === "pointerup") moveClip(from, to);
  };
  grip.addEventListener("pointermove", move);
  grip.addEventListener("pointerup", end);
  grip.addEventListener("pointercancel", end);
}

// ------------------------------------------------------------------ mäklarläge

function fatal(text: string): void {
  reset();
  $("loader").hidden = true;
  $("editor").hidden = true;
  $("reload").hidden = true;
  message(text, "err");
}

async function fetchBlob(url: string): Promise<Blob> {
  const r = await fetch(url, { referrerPolicy: "no-referrer" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.blob();
}

/** Läser in fullstorleksvarianten för en bild som hittills bara finns som miniatyr. */
async function ensureFull(assetId: string): Promise<void> {
  if (!share || share.fullLoaded.has(assetId)) return;
  const a = assetOf(assetId);
  const full = a ? share.urls.get(a.sha256)?.full : null;
  if (!a || !full) return;
  try {
    const bmp = await decode(await fetchBlob(full));
    (images.get(assetId) as ImageBitmap | undefined)?.close?.();
    images.set(assetId, bmp);
    share.fullLoaded.add(assetId);
  } catch {
    message("Kunde inte hämta bilden i full storlek. Försök igen.", "err");
  }
}

function describeError(e: unknown): string {
  return e instanceof ShareError ? e.message : `Något gick fel (${(e as Error).message}).`;
}

function applyView(view: ShareView): void {
  if (!share) return;
  share.view = view;
  updateShareUi();
}

function updateShareUi(): void {
  if (!share) return;
  const v = share.view;
  const status = share.dirty ? "Osparade ändringar" : STATUS_TEXT[v.object.status];
  $("badge").textContent = `${v.object.address} · ${status}`;
  $("badge").title = "";
  const save = $<HTMLButtonElement>("save");
  save.hidden = false;
  save.disabled = !share.dirty;
  const rendered = v.renders.length > 0;
  const link = $<HTMLAnchorElement>("archiveLink");
  link.hidden = !rendered;
  link.href = `/a#${share.token}`;
  const approved = v.object.status === "approved" && !share.dirty;
  const done = v.object.status === "rendered" && !share.dirty;
  $<HTMLButtonElement>("approve").disabled = approved || done;
  $("approve").textContent = approved ? "Godkänd, renderas" : done ? "Godkänd och klar" : "Godkänn";
  if (approved && !share.poll) {
    share.poll = window.setInterval(() => void pollStatus(), 6000);
  } else if (!approved && share.poll) {
    clearInterval(share.poll);
    share.poll = undefined;
  }
}

/** Uppdaterar bara status och renderingar medan filmen renderas (ersätter inte det du redigerar). */
async function pollStatus(): Promise<void> {
  if (!share || share.dirty) return;
  try {
    const v = await share.client.get();
    if (v.object.currentRevision !== share.revision) return; // någon har ändrat: låt mäklaren välja att ladda om
    applyView(v);
    if (v.object.status === "rendered") message("Filmen är klar och finns i arkivet.");
  } catch { /* nästa varv */ }
}

async function loadShare(token: string): Promise<void> {
  message("Hämtar filmen…");
  const client = new ShareClient(token);
  let view: ShareView;
  try { view = await client.get(); } catch (e) { fatal(describeError(e)); return; }
  if (!view.spec) { fatal("Fotografen har inte skickat någon film än. Kom tillbaka senare."); return; }
  let parsed: ReelSpec;
  try { parsed = parseReelSpec(view.spec); } catch (e) { fatal(e instanceof ReelSpecError ? e.message : "Filmen går inte att läsa."); return; }
  reset();
  spec = parsed;
  const urls = new Map(view.pool.map((p) => [p.sha256, { full: p.url, thumb: p.thumbUrl }]));
  share = { token, client, view, revision: view.object.currentRevision, dirty: false, urls, fullLoaded: new Set() };
  $("reload").hidden = true;
  const onTimeline = new Set(spec.timeline.map((c) => c.asset));
  const missing: string[] = [];
  await Promise.all(spec.assets.map(async (a) => {
    const u = urls.get(a.sha256);
    const wantFull = onTimeline.has(a.id);
    const href = wantFull ? (u?.full ?? u?.thumb) : (u?.thumb ?? u?.full);
    if (!href) { missing.push(a.id); return; }
    try {
      await addImage(a.id, await fetchBlob(href), a.analysis?.room ?? a.id);
      if (wantFull && href === u?.full) share!.fullLoaded.add(a.id);
    } catch { missing.push(a.id); }
  }));
  start(missing, 0);
  $("loader").hidden = true;
  $("note").textContent = "Ändringar sparas när du trycker Spara eller Godkänn. Fotografen ser dem direkt.";
  updateShareUi();
  if (view.object.status === "rendered") message("Filmen är klar och finns i arkivet.");
}

async function saveShare(): Promise<boolean> {
  if (!share || !spec) return false;
  if (!share.dirty && pendingOps.length === 0) return true;
  const out = editedCopy(spec, pendingOps, $<HTMLInputElement>("who").value.trim(), isoNow());
  try {
    const r = await share.client.saveSpec(out, share.revision);
    out.revision = r.revision;
    spec = out;
    share.revision = r.revision;
    share.dirty = false;
    pendingOps = [];
    share.view = { ...share.view, object: { ...share.view.object, status: r.status as ShareView["object"]["status"], currentRevision: r.revision } };
    updateShareUi();
    message("Sparat.");
    return true;
  } catch (e) {
    $("reload").hidden = !(e instanceof ShareError && e.status === 412);
    message(describeError(e), "err");
    return false;
  }
}

async function approveShare(): Promise<void> {
  if (!share) return;
  if (!(await saveShare())) return;
  try {
    const r = await share.client.approve(share.revision);
    message(r.changed ? "Godkänt! Filmen renderas och dyker upp i arkivet." : "Filmen är redan godkänd.");
    applyView(await share.client.get());
  } catch (e) {
    $("reload").hidden = !(e instanceof ShareError && (e.status === 412 || e.code === "revision_mismatch"));
    message(describeError(e), "err");
  }
}

// ------------------------------------------------------------------ godkänn

const isoNow = (): string => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

function approve(): void {
  if (share) { void approveShare(); return; }
  if (!spec) return;
  const out = approvedCopy(spec, pendingOps, $<HTMLInputElement>("who").value.trim(), isoNow());
  const blob = new Blob([JSON.stringify(sortKeys(out), null, 2) + "\n"], { type: "application/json" });
  const a = el("a");
  a.href = URL.createObjectURL(blob);
  a.download = "reel.json";
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
  message(`Laddade ner reel.json (revision ${out.revision}, status approved). Lokal prototyp: inget skickades.`);
}

// ------------------------------------------------------------------ uppstart

async function filesFromDrop(dt: DataTransfer): Promise<File[]> {
  const out: File[] = [];
  const walk = async (entry: FileSystemEntry): Promise<void> => {
    if (entry.isFile) {
      out.push(await new Promise<File>((res, rej) => (entry as FileSystemFileEntry).file(res, rej)));
    } else if (entry.isDirectory) {
      const reader = (entry as FileSystemDirectoryEntry).createReader();
      for (;;) {
        const batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
        if (batch.length === 0) break;
        for (const b of batch) await walk(b);
      }
    }
  };
  const entries = [...dt.items].map((i) => i.webkitGetAsEntry?.()).filter((x): x is FileSystemEntry => !!x);
  if (entries.length) for (const e of entries) await walk(e);
  else out.push(...dt.files);
  return out;
}

function init(): void {
  const drop = $("drop");
  for (const ev of ["dragenter", "dragover"]) drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("over"); });
  for (const ev of ["dragleave", "drop"]) drop.addEventListener(ev, () => drop.classList.remove("over"));
  drop.addEventListener("drop", async (e) => {
    e.preventDefault();
    if (e.dataTransfer) await loadFromFiles(await filesFromDrop(e.dataTransfer));
  });
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => e.preventDefault());
  for (const id of ["pickDir", "pickFiles"]) {
    const input = $<HTMLInputElement>(id);
    input.addEventListener("change", async () => { if (input.files) await loadFromFiles([...input.files]); input.value = ""; });
  }
  $("urlForm").addEventListener("submit", (e) => { e.preventDefault(); void loadFromUrl($<HTMLInputElement>("urlInput").value.trim()); });

  $("play").addEventListener("click", () => (playing ? stop() : play()));
  $("scrub").addEventListener("input", () => { stop(); seek((Number($<HTMLInputElement>("scrub").value) / 1000) * total()); });
  $("approve").addEventListener("click", approve);
  $("save").addEventListener("click", () => void saveShare());
  $("reload").addEventListener("click", () => { const t = share?.token ?? tokenFromHash(location.hash); if (t) void loadShare(t); });
  window.addEventListener("hashchange", () => location.reload());
  new ResizeObserver(() => { if (spec) resizeCanvas(); }).observe(canvas);
  document.addEventListener("keydown", (e) => {
    if (e.code === "Space" && spec && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement || e.target instanceof HTMLButtonElement)) {
      e.preventDefault(); playing ? stop() : play();
    }
  });

  const token = tokenFromHash(location.hash);
  if (token) {
    $("loader").hidden = true;
    void loadShare(token);
    return;
  }
  if (location.hash.length > 1) message("Länken ser inte komplett ut. Be fotografen skicka den igen.", "err");

  const url = new URLSearchParams(location.search).get("spec");
  if (url) { $<HTMLInputElement>("urlInput").value = url; void loadFromUrl(url); }
}

init();
