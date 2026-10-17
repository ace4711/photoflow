// ReelSpec v1/v2: TypeScript-typer och inläsning. Motsvarar
// PhotoFlow/Sources/Shared/ReelSpec.swift; den normativa beskrivningen finns i
// docs/reel-spec-v1.md (rutor, version 2: docs/reel-spec-v2.md). Läsare ska ignorera okända fält, så typerna är
// strukturella och `parseReelSpec` returnerar det inlästa objektet som det är
// (okända fält bevaras, så att en redigerare kan skriva tillbaka dem).
//
// Bara "erasable" TypeScript (inga enums/namespaces/parameter properties), så
// att Node kan köra filen direkt.

export const SCHEMA_NAME = "photoflow.reel";
/** Den högsta schemaversion den här koden förstår (2 = rutor, docs/reel-spec-v2.md). */
export const CURRENT_VERSION = 2;

export type Easing = "linear" | "easeInOut";
export type TransitionType = "crossfade" | "cut" | "fadeThroughBlack" | "push";
export type Direction = "left" | "right" | "up" | "down";
export type Fit = "cover" | "contain-blur" | "panels";
export type PanelLayout = "stack" | "side" | "sequence";
export type EntranceType = "slide" | "fade" | "none";

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
  /** Montage (R6b): källrektanglar för de två stående halvorna; saknas/tom = ingen montage. */
  panels?: UnitRect[];
  /** Rumstyp per halva (samma ordning som `panels`). */
  panelRooms?: string[];
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

/** Rektangel i normaliserade bildkoordinater. */
export interface UnitRect { x: number; y: number; w: number; h: number }
/** En ruta i ett rutklipp (version 2): en bild, eller en del av den (`source`), med egen rörelse. */
export interface Panel { asset: string; source?: UnitRect | null; motion: Motion }
export interface Entrance { type: EntranceType; stagger?: number; duration?: number }

export const DEFAULT_GUTTER = 0.006;
export const DEFAULT_ENTRANCE_STAGGER = 0.3;
export const DEFAULT_ENTRANCE_DURATION = 0.6;

export interface Clip {
  asset: string;
  duration: number;
  fit: Fit;
  motion: Motion;
  transitionIn?: Transition;
  /** Förval eller "custom" (fotografens egna start/slut, se motionPresets.ts). */
  motionPreset?: string;
  durationLocked?: boolean;
  /** Övergången är satt för hand och följer klippet; saknas `transitionIn` gäller `style.defaultTransition`. */
  transitionLocked?: boolean;
  /** Fotografens oklampade egna start/slut (bara när klampning mot formatet ändrat dem), se docs/reel-spec-v1.md 2.3. */
  customMotion?: Motion;
  /** Bara för fit "panels" (version 2). */
  layout?: PanelLayout;
  panels?: Panel[];
  /** Avstånd mellan rutorna som andel av ramens kortsida (stack/side). */
  gutter?: number;
  entrance?: Entrance;
}

/** Redigerarens val (fotografens), bara metadata: renderare ignorerar det. Se docs/reel-spec-v1.md. */
export interface EditorState {
  /** sha256 för bilder som alltid ska vara med vid ett nytt förslag. */
  pinnedAssets?: string[];
  /** sha256 för bilder som aldrig ska föreslås. */
  excludedAssets?: string[];
  orderLocked?: boolean;
  /** "calm" | "normal" | "fast"; okänt värde räknas som normal. */
  tempo?: string;
  /** Fotografens exakta antal bilder (3–12); saknas = automatiskt. Bara metadata, webben ändrar det inte. */
  fixedCount?: number;
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
  /** `slot`: "opening", "closing" eller rumstypen ("vardagsrum", "kök", ...). */
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
  editor?: EditorState;
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
const FITS = ["cover", "contain-blur", "panels"];
const LAYOUTS = ["stack", "side", "sequence"];
const ENTRANCES = ["slide", "fade", "none"];

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

/** Rutklipp (fit "panels", version 2): layout, rutor, källrektanglar, gutter och ingång. */
function checkPanels(c: Obj, where: string, ids: Set<string>): void {
  need(typeof c.layout === "string" && LAYOUTS.includes(c.layout),
    `${where}: rutklipp saknar giltig layout (väntade ${LAYOUTS.join(", ")}).`);
  need(Array.isArray(c.panels), `${where}: rutklipp saknar panels.`);
  const n = c.panels.length;
  need(c.layout === "sequence" ? n >= 2 : n === 2,
    `${where}: layout ${c.layout} kräver ${c.layout === "sequence" ? "minst två" : "exakt två"} rutor (fick ${n}).`);
  c.panels.forEach((p: unknown, k: number) => {
    const w = `${where} ruta ${k + 1}`;
    need(isObj(p), `${w}: måste vara ett objekt.`);
    need(typeof p.asset === "string" && ids.has(p.asset), `${w}: pekar på en bild (${String(p.asset)}) som inte finns i assets.`);
    need(isObj(p.motion), `${w}: saknar motion.`);
    checkKey(p.motion.from, `${w} motion.from`);
    checkKey(p.motion.to, `${w} motion.to`);
    if (p.source !== undefined && p.source !== null) {
      const s = p.source;
      need(isObj(s) && isNum(s.x) && isNum(s.y) && isNum(s.w) && isNum(s.h)
        && s.w > 0 && s.h > 0 && s.x >= 0 && s.y >= 0 && s.x + s.w <= 1 + 1e-9 && s.y + s.h <= 1 + 1e-9,
        `${w}: source måste vara {x, y, w, h} inom bilden med positiv bredd och höjd.`);
    }
  });
  need(c.panels[0].asset === c.asset, `${where}: klippets asset måste vara första rutans bild.`);
  if (c.gutter !== undefined && c.gutter !== null) need(isNum(c.gutter) && c.gutter >= 0, `${where}: gutter måste vara ett tal ≥ 0.`);
  if (c.entrance !== undefined && c.entrance !== null) {
    const e = c.entrance;
    need(isObj(e) && typeof e.type === "string" && ENTRANCES.includes(e.type),
      `${where}: okänd ingång (entrance.type), väntade ${ENTRANCES.join(", ")}.`);
    for (const k of ["stagger", "duration"]) {
      need(e[k] === undefined || e[k] === null || (isNum(e[k]) && e[k] >= 0), `${where}: entrance.${k} måste vara ett tal ≥ 0.`);
    }
  }
}

/** Alla bilder (asset-id) ett klipp visar: klippets egen och rutornas. */
export function referencedAssetIds(c: Clip): string[] {
  const ids = [c.asset];
  for (const p of c.panels ?? []) if (!ids.includes(p.asset)) ids.push(p.asset);
  return ids;
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
      `${where}: okänt fit "${String(c.fit)}" (väntade cover, contain-blur eller panels).`);
    need(isObj(c.motion), `${where}: saknar motion.`);
    checkKey(c.motion.from, `${where} motion.from`);
    checkKey(c.motion.to, `${where} motion.to`);
    if (c.transitionIn !== undefined && c.transitionIn !== null) checkTransition(c.transitionIn, `${where} transitionIn`);
    if (c.fit === "panels") checkPanels(c, where, ids);
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
