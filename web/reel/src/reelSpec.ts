// ReelSpec v1: TypeScript-typer och inläsning. Motsvarar
// PhotoFlow/Sources/Shared/ReelSpec.swift; den normativa beskrivningen finns i
// docs/reel-spec-v1.md. Läsare ska ignorera okända fält, så typerna är
// strukturella och `parseReelSpec` returnerar det inlästa objektet som det är
// (okända fält bevaras, så att en redigerare kan skriva tillbaka dem).
//
// Bara "erasable" TypeScript (inga enums/namespaces/parameter properties), så
// att Node kan köra filen direkt.

export const SCHEMA_NAME = "photoflow.reel";
/** Den schemaversion den här koden förstår. */
export const CURRENT_VERSION = 1;

export type Easing = "linear" | "easeInOut";
export type TransitionType = "crossfade" | "cut" | "fadeThroughBlack" | "push";
export type Direction = "left" | "right" | "up" | "down";
export type Fit = "cover" | "contain-blur";

export interface UpdatedBy { role: string; name?: string }
export interface Property { address: string; sessionID?: string; kind?: string }
export interface Point { x: number; y: number }

export interface Source {
  kind: "local" | "url" | "store";
  path?: string;
  url?: string;
  key?: string;
}

export interface Analysis {
  room?: string;
  category?: string;
  focus?: Point;
  salientWidth?: number;
  focusWidth?: number;
}

export interface Asset {
  id: string;
  sha256: string;
  width: number;
  height: number;
  sources: Source[];
  analysis?: Analysis;
}

export interface Transition { type: TransitionType; direction?: Direction; duration: number }
export interface Background { type: string; amount?: number }
export interface Style { defaultTransition: Transition; easing: Easing; background: Background }
export interface MotionKey { cx: number; cy: number; zoom: number }
export interface Motion { from: MotionKey; to: MotionKey }

export interface Clip {
  asset: string;
  duration: number;
  fit: Fit;
  motion: Motion;
  transitionIn?: Transition;
  motionPreset?: string;
  durationLocked?: boolean;
}

export interface Output {
  id: string;
  aspect: string;
  width: number;
  height: number;
  fps: number;
  encoding?: { codec: string; bitrateMbps?: number; audio?: string };
}

export interface Edit { at: string; by: string; op: string }
export interface Provenance {
  generator: string;
  autoSelection?: { asset: string; slot: string; reason: string }[];
  edits?: Edit[];
}

export interface ReelSpec {
  schema: string;
  version: number;
  minReaderVersion: number;
  id: string;
  revision: number;
  status: string;
  createdAt: string;
  updatedAt: string;
  updatedBy: UpdatedBy;
  property: Property;
  assets: Asset[];
  style: Style;
  timeline: Clip[];
  audio?: unknown;
  overlays?: { type: string; [k: string]: unknown }[];
  brand?: unknown;
  outputs: Output[];
  provenance: Provenance;
  [extra: string]: unknown;
}

/** Fel med ett begripligt svenskt meddelande. */
export class ReelSpecError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReelSpecError";
  }
}

const TRANSITION_TYPES = ["crossfade", "cut", "fadeThroughBlack", "push"];
const DIRECTIONS = ["left", "right", "up", "down"];
const FITS = ["cover", "contain-blur"];

type Obj = Record<string, unknown>;
function isObj(v: unknown): v is Obj {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function isNum(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function need(cond: boolean, message: string): asserts cond {
  if (!cond) throw new ReelSpecError(message);
}

function checkTransition(t: unknown, where: string): void {
  need(isObj(t), `${where}: övergången måste vara ett objekt.`);
  need(typeof t.type === "string" && TRANSITION_TYPES.includes(t.type),
    `${where}: okänd övergångstyp "${String(t.type)}" (väntade ${TRANSITION_TYPES.join(", ")}).`);
  need(isNum(t.duration), `${where}: övergången saknar längd (duration).`);
  if (t.direction !== undefined && t.direction !== null) {
    need(typeof t.direction === "string" && DIRECTIONS.includes(t.direction),
      `${where}: okänd riktning "${String(t.direction)}".`);
  }
}

function checkKey(k: unknown, where: string): void {
  need(isObj(k) && isNum(k.cx) && isNum(k.cy) && isNum(k.zoom),
    `${where}: rörelsens nyckelbild måste ha cx, cy och zoom (tal).`);
}

/**
 * Läser och validerar en reel. Tar en JSON-sträng eller ett redan inläst
 * objekt. Kastar `ReelSpecError` med svenskt meddelande vid fel. Okända fält
 * ignoreras. Valideringen täcker det en renderare behöver: schema, version,
 * assets, stil, tidslinje och utbildsprofiler.
 */
export function parseReelSpec(json: unknown): ReelSpec {
  let raw: unknown = json;
  if (typeof json === "string") {
    try {
      raw = JSON.parse(json);
    } catch (e) {
      throw new ReelSpecError(`Filen är inte giltig JSON (${(e as Error).message}).`);
    }
  }
  need(isObj(raw), "Filen innehåller inte ett JSON-objekt.");
  need(raw.schema === SCHEMA_NAME,
    `Det här är inte en reel-fil (schema är "${String(raw.schema)}", väntade "${SCHEMA_NAME}").`);
  need(isNum(raw.version), "Reelen saknar versionsnummer (version).");
  need(isNum(raw.minReaderVersion), "Reelen saknar minReaderVersion.");
  need(raw.minReaderVersion <= CURRENT_VERSION,
    `Reelen kräver en nyare läsare (minReaderVersion ${raw.minReaderVersion}, den här förstår ${CURRENT_VERSION}). Uppdatera appen.`);
  need(typeof raw.id === "string", "Reelen saknar id.");
  need(isNum(raw.revision), "Reelen saknar revision.");

  need(Array.isArray(raw.assets), "Reelen saknar listan assets (bilder).");
  const ids = new Set<string>();
  raw.assets.forEach((a: unknown, i: number) => {
    const where = `Bild ${i + 1}`;
    need(isObj(a), `${where}: måste vara ett objekt.`);
    need(typeof a.id === "string" && a.id !== "", `${where}: saknar id.`);
    need(!ids.has(a.id), `${where}: id "${a.id}" förekommer flera gånger.`);
    ids.add(a.id);
    need(isNum(a.width) && a.width > 0 && isNum(a.height) && a.height > 0,
      `Bild "${a.id}": width och height måste vara positiva tal.`);
    need(Array.isArray(a.sources), `Bild "${a.id}": saknar sources.`);
  });

  need(isObj(raw.style), "Reelen saknar style.");
  checkTransition(raw.style.defaultTransition, "style.defaultTransition");
  need(raw.style.easing === "linear" || raw.style.easing === "easeInOut",
    `style.easing måste vara "linear" eller "easeInOut" (fick "${String(raw.style.easing)}").`);
  need(isObj(raw.style.background) && typeof raw.style.background.type === "string",
    "style.background saknas eller saknar type.");

  need(Array.isArray(raw.timeline), "Reelen saknar tidslinjen (timeline).");
  raw.timeline.forEach((c: unknown, i: number) => {
    const where = `Klipp ${i + 1}`;
    need(isObj(c), `${where}: måste vara ett objekt.`);
    need(typeof c.asset === "string", `${where}: saknar asset.`);
    need(ids.has(c.asset), `${where}: pekar på en bild (${c.asset}) som inte finns i assets.`);
    need(isNum(c.duration) && c.duration > 0, `${where}: duration måste vara ett tal större än 0.`);
    need(typeof c.fit === "string" && FITS.includes(c.fit),
      `${where}: okänt fit "${String(c.fit)}" (väntade cover eller contain-blur).`);
    need(isObj(c.motion), `${where}: saknar motion.`);
    checkKey(c.motion.from, `${where} motion.from`);
    checkKey(c.motion.to, `${where} motion.to`);
    if (c.transitionIn !== undefined && c.transitionIn !== null) checkTransition(c.transitionIn, `${where} transitionIn`);
  });

  need(Array.isArray(raw.outputs), "Reelen saknar outputs.");
  need(raw.outputs.length > 0, "Reelen har ingen utbildsprofil (outputs är tom).");
  raw.outputs.forEach((o: unknown, i: number) => {
    need(isObj(o) && isNum(o.width) && o.width > 0 && isNum(o.height) && o.height > 0 && isNum(o.fps),
      `Utbildsprofil ${i + 1}: width, height och fps måste vara tal.`);
  });

  // Valfria fält får saknas i äldre filer; normalisera så att resten av koden slipper kontrollera.
  const spec = raw as unknown as ReelSpec;
  if (!isObj(spec.provenance)) spec.provenance = { generator: "okänd" };
  if (!isObj(spec.updatedBy)) spec.updatedBy = { role: "photographer" };
  if (typeof spec.status !== "string") spec.status = "draft";
  return spec;
}
