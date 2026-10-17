// Mäklarens regi: urval, ordning och längd, utan DOM, så att det går att testa i Node.
// Webben redigerar inte övergångar eller egna panoreringar (plan, beslut 4) men
// respekterar fotografens lås och förstör dem aldrig i tysthet:
//
//  - `transitionLocked`: klippets övergång följer med klippet och rörs aldrig, inte ens
//    på plats 0. Övriga övergångar räknas om efter varje ändring med samma regel som
//    `ReelMotionPlanner.automaticTransition` (push efter panorering, längre tona in sist).
//  - `motionPreset: "custom"`: fit och motion behålls vid omordning, längdändring,
//    tillägg och borttagning, och kan inte bytas mot ett förval i webben (menyn är låst;
//    servern vägrar också en ändrad egen rörelse, se server/src/locks.ts).
//  - `durationLocked`: längden behålls. Andra längder räknas om med filmens tempo när ett
//    klipp byter roll (första, mitten, sista), som Swift `rebuild` gör.
//  - `editor`: bevaras. Uteslutna bilder (`excludedAssets`) går bara att lägga till efter
//    ett aktivt val; då släpps uteslutningen (op "unexclude"), som Swift `togglePinned`.
//    Tar mäklaren bort en pinnad bild (`pinnedAssets`) släpps pinningen i samma ändring
//    (op "unpin"), så att filmen och metadatan säger samma sak och fotografens nästa
//    "Föreslå igen" inte tvingar tillbaka bilden (den kan ändå väljas automatiskt; den
//    utesluts inte). editor.ts frågar först (`removalWarning`).
//  - Borttagning: ett borttaget klipps lås (egen rörelse, låst övergång och längd,
//    pinning) sparas under sessionen i `RemovedClips`, så att `addClip` av samma bild
//    återställer dem i stället för att planera ett nytt klipp.
//
// Funktionerna ändrar `spec` på plats och returnerar de op-namn som ska loggas i
// provenance.edits.

import type { Asset, Clip, EditorState, ReelSpec } from "./reelSpec.ts";
import {
  CUSTOM, MAX_CLIPS, PRESETS, automaticDuration, automaticTransition, customKind, isCustom, panSign,
  planClip, tempoFactor, tempoOf, TEMPO_LABELS, transitionLabel,
} from "./motionPresets.ts";
import type { Preset, Tempo } from "./motionPresets.ts";

export class RegiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RegiError";
  }
}

// ------------------------------------------------------------ editor-objektet

/** Tolerant läsning av `spec.editor`: fel typ ignoreras (parseReelSpec validerar det inte). */
export interface EditorView {
  pinned: Set<string>;
  excluded: Set<string>;
  orderLocked: boolean;
  tempo: Tempo;
  /** Om fotografen uttryckligen satt ett tempo. */
  tempoSet: boolean;
}

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
}

export function editorOf(spec: ReelSpec): EditorView {
  const e = (spec.editor && typeof spec.editor === "object" ? spec.editor : {}) as EditorState;
  return {
    pinned: new Set(strings(e.pinnedAssets)),
    excluded: new Set(strings(e.excludedAssets)),
    orderLocked: e.orderLocked === true,
    tempo: tempoOf(e.tempo),
    tempoSet: typeof e.tempo === "string",
  };
}

/** Tar bort `sha` ur en av listorna och normaliserar som Swift `EditorState.normalized`. */
function dropFromEditor(spec: ReelSpec, list: "pinnedAssets" | "excludedAssets", sha: string): boolean {
  const e = spec.editor;
  if (!e || !Array.isArray(e[list]) || !e[list]!.includes(sha)) return false;
  const rest = e[list]!.filter((x) => x !== sha);
  if (rest.length) e[list] = rest;
  else delete e[list];
  if (Object.keys(e).length === 0) delete spec.editor;
  return true;
}

function assetOf(spec: ReelSpec, id: string): Asset | undefined {
  return spec.assets.find((a) => a.id === id);
}

export function isPinned(spec: ReelSpec, clip: Clip): boolean {
  const a = assetOf(spec, clip.asset);
  return !!a && editorOf(spec).pinned.has(a.sha256);
}

export function isExcluded(spec: ReelSpec, asset: Asset): boolean {
  return editorOf(spec).excluded.has(asset.sha256);
}

// ------------------------------------------------------------ omplanering

type Role = "first" | "middle" | "last";
function roleOf(i: number, n: number): Role {
  return i === 0 ? "first" : i === n - 1 && n > 1 ? "last" : "middle";
}

/** Klippens roller före en ändring (per klippobjekt, så att de följer med vid omordning). */
function roles(spec: ReelSpec): Map<Clip, Role> {
  const n = spec.timeline.length;
  return new Map(spec.timeline.map((c, i) => [c, roleOf(i, n)]));
}

/** Förvalet som ger samma sorts rörelse som klippet redan har (för automatiska klipp). */
function equivalentPreset(clip: Clip): Preset {
  if (clip.fit === "contain-blur") return "contain";
  const { from, to } = clip.motion;
  if (Math.abs(to.zoom - from.zoom) >= 1e-9) return to.zoom >= from.zoom ? "zoomIn" : "zoomOut";
  return to.cx >= from.cx ? "panRight" : "panLeft";
}

/**
 * Räknar om det som inte är låst efter en ändring:
 *  - klipp som bytt roll (eller är nya) och saknar låst längd får automatisk längd med
 *    tempo; deras motion planeras om för den nya rollen (sista klippet rör sig lugnare),
 *    med samma sorts rörelse och riktning som förut. Egen rörelse behåller fit och motion.
 *  - alla övergångar utan `transitionLocked` sätts med `automaticTransition`.
 * Klipp som inte bytt roll behåller sin motion och längd.
 */
export function retime(spec: ReelSpec, frameAspect: number, before: Map<Clip, Role>): void {
  const n = spec.timeline.length;
  const tempo = tempoFactor(spec.editor?.tempo);
  spec.timeline.forEach((clip, i) => {
    if (before.get(clip) === roleOf(i, n) || clip.durationLocked === true) return;
    if (isCustom(clip)) {
      clip.duration = automaticDuration(customKind(clip), i, n, tempo);
      return;
    }
    const asset = assetOf(spec, clip.asset);
    if (!asset) return;
    const preset = clip.motionPreset && (PRESETS as readonly string[]).includes(clip.motionPreset) && clip.motionPreset !== "auto"
      ? (clip.motionPreset as Preset) : equivalentPreset(clip);
    const p = planClip({ asset, frameAspect, preset, index: i, count: n, current: clip, tempo });
    clip.fit = p.fit; clip.motion = p.motion; clip.duration = p.duration;
  });
  spec.timeline.forEach((clip, i) => {
    if (clip.transitionLocked === true) return;
    if (i === 0) { delete clip.transitionIn; return; }
    clip.transitionIn = automaticTransition(panSign(spec.timeline[i - 1]), i === n - 1 && n > 1, spec.style.defaultTransition);
  });
}

// ------------------------------------------------------------ redigering

export function moveClip(spec: ReelSpec, from: number, to: number, frameAspect: number): string[] {
  const n = spec.timeline.length;
  if (to < 0 || to >= n || from < 0 || from >= n || from === to) return [];
  const before = roles(spec);
  const [c] = spec.timeline.splice(from, 1);
  spec.timeline.splice(to, 0, c);
  retime(spec, frameAspect, before);
  return ["reorder"];
}

/**
 * Borttagna klipp under sessionen (asset-id → klippet som det var, och om bilden var
 * pinnad). Lever bara i webbläsaren; `addClip` återställer fotografens lås ur den.
 */
export type RemovedClips = Map<string, { clip: Clip; pinned: boolean }>;

/** Om klippet bär något av fotografens lås som en borttagning skulle ta bort. */
function hasPhotographerLock(spec: ReelSpec, c: Clip): boolean {
  return isCustom(c) || c.transitionLocked === true || isPinned(spec, c);
}

/**
 * Text för bekräftelsen innan klipp `i` tas bort, eller null om klippet inte bär något
 * av fotografens lås (pinning, egen rörelse, låst övergång).
 */
export function removalWarning(spec: ReelSpec, i: number): string | null {
  const c = spec.timeline[i];
  if (!c || !hasPhotographerLock(spec, c)) return null;
  const what: string[] = [];
  const pinned = isPinned(spec, c);
  if (pinned) what.push("låst bilden så att den alltid är med");
  if (isCustom(c)) what.push("gjort en egen rörelse för bilden");
  if (c.transitionLocked === true) what.push("valt övergången till bilden");
  const list = what.length > 1 ? `${what.slice(0, -1).join(", ")} och ${what[what.length - 1]}` : what[0];
  let text = `Fotografen har ${list}. Ta bort den ändå? Lägger du tillbaka bilden innan du lämnar sidan återställs fotografens val.`;
  const lost: string[] = [];
  if (isCustom(c)) lost.push("den egna rörelsen");
  if (c.transitionLocked === true) lost.push("den valda övergången");
  if (lost.length) text += ` Annars försvinner ${lost.join(" och ")} ur filmen när du sparar.`;
  if (pinned) text += " Låsningen släpps, så bilden är inte längre garanterad en plats vid ett nytt förslag.";
  return text;
}

/**
 * Tar bort klipp `i`. Var bilden pinnad av fotografen släpps pinningen (op "unpin"),
 * annars skulle nästa "Föreslå igen" i Mac-appen tvinga tillbaka den utan att någon ser
 * varför. Klippet sparas i `removed` så att ett nytt tillägg av bilden återställer
 * fotografens lås. Anroparen ska ha frågat mäklaren först (`removalWarning`).
 */
export function removeClip(spec: ReelSpec, i: number, frameAspect: number, removed?: RemovedClips): string[] {
  if (i < 0 || i >= spec.timeline.length) return [];
  if (spec.timeline.length <= 1) throw new RegiError("Filmen måste ha minst ett klipp.");
  const before = roles(spec);
  const pinned = isPinned(spec, spec.timeline[i]);
  const [c] = spec.timeline.splice(i, 1);
  removed?.set(c.asset, { clip: structuredClone(c), pinned });
  const ops = ["remove"];
  const a = assetOf(spec, c.asset);
  if (a && dropFromEditor(spec, "pinnedAssets", a.sha256)) ops.push("unpin");
  retime(spec, frameAspect, before);
  return ops;
}

export function canAddMore(spec: ReelSpec): boolean {
  return spec.timeline.length < MAX_CLIPS;
}

/**
 * Lägger till bilden sist. Högst `MAX_CLIPS` klipp (en film med fler pinnade bilder
 * går att läsa in, men inte att växa). En utesluten bild kräver `allowExcluded`
 * (mäklarens aktiva val); uteslutningen släpps då (op "unexclude").
 * Togs bilden bort tidigare under sessionen (`removed`) återställs fotografens lås:
 * egen rörelse (fit, motion), låst övergång, låst längd och pinning (op "pin").
 */
export function addClip(
  spec: ReelSpec, assetId: string, frameAspect: number,
  opts: { allowExcluded?: boolean; removed?: RemovedClips } = {},
): string[] {
  const asset = assetOf(spec, assetId);
  if (!asset) throw new RegiError("Bilden finns inte i filmen.");
  if (spec.timeline.some((c) => c.asset === assetId)) throw new RegiError("Bilden är redan med i filmen.");
  if (!canAddMore(spec)) throw new RegiError(`Högst ${MAX_CLIPS} klipp i en film.`);
  const ops = ["add"];
  if (isExcluded(spec, asset)) {
    if (!opts.allowExcluded) throw new RegiError("Fotografen har uteslutit bilden.");
    dropFromEditor(spec, "excludedAssets", asset.sha256);
    ops.push("unexclude");
  }
  const before = roles(spec);
  const index = spec.timeline.length;
  const tempo = tempoFactor(spec.editor?.tempo);
  const p = planClip({ asset, frameAspect, preset: "auto", index, count: index + 1, tempo });
  const clip: Clip = { asset: assetId, ...p };
  const old = opts.removed?.get(assetId);
  if (old) {
    opts.removed!.delete(assetId);
    const o = old.clip;
    if (isCustom(o)) {
      clip.fit = o.fit; clip.motion = structuredClone(o.motion); clip.motionPreset = CUSTOM;
      clip.duration = automaticDuration(customKind(o), index, index + 1, tempo);
    }
    if (o.durationLocked === true) { clip.duration = o.duration; clip.durationLocked = true; }
    if (o.transitionLocked === true) {
      clip.transitionLocked = true;
      if (o.transitionIn) clip.transitionIn = structuredClone(o.transitionIn);
    }
    if (old.pinned && !isPinned(spec, clip)) {
      spec.editor ??= {};
      spec.editor.pinnedAssets = [...strings(spec.editor.pinnedAssets), asset.sha256];
      ops.push("pin");
    }
  }
  spec.timeline.push(clip);
  before.set(clip, roleOf(index, index + 1)); // redan planerat för sin plats
  retime(spec, frameAspect, before);
  return ops;
}

export function setDuration(spec: ReelSpec, i: number, d: number, maxSeconds: number): string[] {
  const c = spec.timeline[i];
  if (!c || !Number.isFinite(d)) return [];
  c.duration = Math.round(Math.min(Math.max(d, 0.5), maxSeconds) * 10) / 10;
  c.durationLocked = true;
  return ["duration"];
}

/**
 * Byter förval. "auto" behåller nuvarande motion, utom för ett klipp med egen rörelse:
 * där är "Automatisk" ett aktivt val att släppa fotografens rörelse, så klippet planeras
 * om automatiskt. Längden räknas om med tempo om den inte är låst.
 */
export function setPreset(spec: ReelSpec, i: number, preset: Preset | typeof CUSTOM, frameAspect: number): string[] {
  const c = spec.timeline[i];
  // Egen rörelse kan varken väljas eller bytas bort i webben: mäklarens regi omfattar inte
  // panorering (plan, beslut 4), och servern vägrar en ändrad egen rörelse (server/src/locks.ts).
  if (!c || preset === CUSTOM || isCustom(c)) return [];
  if (preset === "auto") {
    if (c.motionPreset === undefined) return [];
    delete c.motionPreset;
  } else {
    const asset = assetOf(spec, c.asset);
    if (!asset) return [];
    const p = planClip({
      asset, frameAspect, preset, index: i, count: spec.timeline.length,
      lockedDuration: c.durationLocked ? c.duration : undefined,
      current: c, tempo: tempoFactor(spec.editor?.tempo),
    });
    c.fit = p.fit; c.motion = p.motion; c.duration = p.duration;
    c.motionPreset = preset;
  }
  // Rörelsen kan ha ändrat nästa klipps automatiska övergång (push efter panorering).
  retime(spec, frameAspect, roles(spec));
  return ["motion"];
}

// ------------------------------------------------------------ visning

export const LOCKED_BY_PHOTOGRAPHER = "Låst av fotografen";

export interface ClipLocks {
  /** Egen rörelse: fit och motion är fotografens. */
  customMotion: boolean;
  durationLocked: boolean;
  transitionLocked: boolean;
  pinned: boolean;
  /** Övergången in till klippet ("Mjuk tona 0,5 s"), null för första klippet utan låst övergång. */
  transition: string | null;
  /**
   * Raden som visas för mäklaren: "In: Mjuk tona 0,5 s", eller för ett första klipp med
   * låst övergång en text som säger att den inte spelas där (filmen börjar utan övergång).
   */
  transitionText: string | null;
}

const sv = (n: number): string => n.toFixed(1).replace(".", ",");

export function clipLocks(spec: ReelSpec, i: number): ClipLocks {
  const c = spec.timeline[i];
  const locked = c.transitionLocked === true;
  let transition: string | null = null;
  if (i > 0 || locked) {
    const t = c.transitionIn ?? spec.style.defaultTransition;
    transition = t.type === "cut" ? transitionLabel(t) : `${transitionLabel(t)} ${sv(t.duration)} s`;
    if (locked && !c.transitionIn) transition += " (filmens standard)";
  }
  const transitionText = transition === null ? null
    : i > 0 ? `In: ${transition}`
    : `Låst övergång: ${transition}. Används inte på första klippet, bara om klippet flyttas.`;
  return {
    customMotion: isCustom(c),
    durationLocked: c.durationLocked === true,
    transitionLocked: locked,
    pinned: isPinned(spec, c),
    transition,
    transitionText,
  };
}

/** Märket för låst längd: synlig text (läses av skärmläsare, syns på pekskärm) och förklaring. */
export const DURATION_LOCK = {
  text: "Låst längd",
  explanation: "Längden är låst och räknas inte om automatiskt när filmen ändras.",
} as const;

/** Rader om filmen i stort som fotografen bestämt (tempo, låst ordning). */
export function filmLocks(spec: ReelSpec): string[] {
  const e = editorOf(spec);
  const out: string[] = [];
  if (e.tempoSet) out.push(`Tempo: ${TEMPO_LABELS[e.tempo]}`);
  if (e.orderLocked) out.push("Ordningen är låst för nya förslag");
  return out;
}

export interface Candidate { asset: Asset; excluded: boolean }

/** Bilder som inte är med i filmen; uteslutna sist. `available` = bilden går att visa. */
export function candidates(spec: ReelSpec, available: (id: string) => boolean): Candidate[] {
  const on = new Set(spec.timeline.map((c) => c.asset));
  const excl = editorOf(spec).excluded;
  const list = spec.assets
    .filter((a) => !on.has(a.id) && available(a.id))
    .map((asset) => ({ asset, excluded: excl.has(asset.sha256) }));
  return [...list.filter((c) => !c.excluded), ...list.filter((c) => c.excluded)];
}
