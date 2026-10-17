// Fotografens lås mot mäklarskrivningar (docs/reel-spec-v1.md avsnitt 2).
// Mäklarens webbeditor (web/reel/src/regi.ts) respekterar låsen; servern kontrollerar
// samma sak så att en annan klient inte kan ändra dem. Ren funktion utan databas.
//
// Mäklaren får flytta, ta bort och lägga till klipp, ändra olåsta längder och förval,
// låta automatiska övergångar räknas om, släppa en pinning (borttaget pinnat klipp)
// och släppa en uteslutning (aktivt tillagd utesluten bild). Mäklaren får inte ändra
// style, editor.tempo, editor.orderLocked, lägga till pinningar eller uteslutningar,
// ändra en låst övergång eller en egen rörelse ("custom") på en bild som finns kvar.
// Rutklipp (version 2, fit "panels": kollage och montage) är fotografens regi (beslut 4):
// ett rutklipp som fanns i fotografens version får bara finnas kvar med oförändrade fit,
// layout, panels, gutter och entrance (matchat på första rutans sha256, rutornas bilder
// jämförda som sha256). Mäklaren får flytta, ändra längd på och ta bort det, men inte
// skapa ett nytt rutklipp eller ändra rutorna.
// Klipp matchas på bildens sha256, eftersom asset-id kan numreras om. En pinning som
// fotografen hade i sin senaste revision får läggas tillbaka (webben återställer den när
// en borttagen pinnad bild läggs till igen). En låst bild får inte läggas till en gång till.

import type { Clip, ReelSpec } from "../../web/reel/src/reelSpec.ts";

const EPS = 1e-9;

/** Jämför två JSON-värden; tal med tolerans. Saknade nycklar och `undefined` räknas lika. */
export function jsonNear(a: unknown, b: unknown): boolean {
  if (typeof a === "number" && typeof b === "number") return a === b || Math.abs(a - b) <= EPS;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return a === b;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    const bb = b as unknown[];
    return a.length === bb.length && a.every((x, i) => jsonNear(x, bb[i]));
  }
  const ao = a as Record<string, unknown>, bo = b as Record<string, unknown>;
  const keys = new Set([...Object.keys(ao), ...Object.keys(bo)]);
  for (const k of keys) if (!jsonNear(ao[k], bo[k])) return false;
  return true;
}

const json = (v: unknown): unknown => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

type Placed = { clip: Clip; index: number };

/** Alla klipp per bild (sha256), i tidslinjens ordning. Samma bild kan förekomma flera gånger. */
function clipsBySha(spec: ReelSpec): Map<string, Placed[]> {
  const shaOf = new Map(spec.assets.map((a) => [a.id, a.sha256]));
  const m = new Map<string, Placed[]>();
  spec.timeline.forEach((clip, index) => {
    const sha = shaOf.get(clip.asset);
    if (!sha) return;
    const l = m.get(sha);
    if (l) l.push({ clip, index }); else m.set(sha, [{ clip, index }]);
  });
  return m;
}

const isLocked = (c: Clip) => c.transitionLocked === true || c.motionPreset === "custom";
const transitionOk = (old: Clip, now: Clip) =>
  old.transitionLocked !== true || (now.transitionLocked === true && jsonNear(old.transitionIn, now.transitionIn));
const motionOk = (old: Clip, now: Clip) =>
  old.motionPreset !== "custom" || (now.motionPreset === "custom" && now.fit === old.fit && jsonNear(old.motion, now.motion));
const fits = (old: Clip, now: Clip) => transitionOk(old, now) && motionOk(old, now);

/** Finns en parning där varje klipp i `now` motsvarar ett eget klipp i `old` vars lås det håller? */
function matchable(old: Clip[], now: Clip[]): boolean {
  const used = new Array<boolean>(old.length).fill(false);
  const go = (k: number): boolean => {
    if (k === now.length) return true;
    for (let i = 0; i < old.length; i++) {
      if (used[i] || !fits(old[i], now[k])) continue;
      used[i] = true;
      if (go(k + 1)) return true;
      used[i] = false;
    }
    return false;
  };
  return go(0);
}

const isPanelsClip = (c: Clip) => c.fit === "panels" || c.panels !== undefined;

/** Rutklippets utformning med bilderna som sha256 (asset-id kan numreras om), för jämförelse. */
function panelsForm(spec: ReelSpec, c: Clip): unknown {
  const shaOf = new Map(spec.assets.map((a) => [a.id, a.sha256]));
  return {
    fit: c.fit, layout: c.layout, gutter: c.gutter, entrance: c.entrance,
    panels: Array.isArray(c.panels)
      ? c.panels.map((p) => ({ ...p, asset: shaOf.get(p.asset) ?? `?${p.asset}` }))
      : c.panels,
  };
}

/** Rutklipp som mäklaren har ändrat eller skapat (tom lista: inget brott). */
function panelsViolations(p: ReelSpec, n: ReelSpec): string[] {
  const shaOf = new Map(n.assets.map((a) => [a.id, a.sha256]));
  const olds = p.timeline.filter(isPanelsClip).map((c) => ({ sha: p.assets.find((a) => a.id === c.asset)?.sha256, form: panelsForm(p, c) }));
  const used = new Array<boolean>(olds.length).fill(false);
  const out: string[] = [];
  n.timeline.forEach((c, i) => {
    if (!isPanelsClip(c)) return;
    const sha = shaOf.get(c.asset);
    const form = panelsForm(n, c);
    // varje rutklipp måste motsvara ett eget, oförändrat rutklipp i fotografens version
    const k = olds.findIndex((o, j) => !used[j] && o.sha === sha && jsonNear(o.form, form));
    if (k >= 0) { used[k] = true; return; }
    const existed = olds.some((o) => o.sha === sha);
    out.push(existed
      ? `Klipp ${i + 1}: kollaget eller montaget är fotografens och kan inte ändras här.`
      : `Klipp ${i + 1}: bara fotografen kan göra kollage eller montage.`);
  });
  return out;
}

export interface LockOptions {
  /**
   * Pinningar (sha256) som mäklaren får lägga tillbaka: fotografens pinningar i den senaste
   * revision fotografen sparade. Webbeditorn återställer pinningen när en borttagen pinnad
   * bild läggs till igen, även om borttagningen redan har sparats.
   */
  restorablePins?: Iterable<string>;
}

/**
 * Lås som `next` bryter jämfört med föregående sparade revision `prev`, som svenska
 * meningar (tom lista: inget brott). Används bara för mäklarens skrivningar.
 */
export function lockViolations(prev: ReelSpec, next: ReelSpec, opts: LockOptions = {}): string[] {
  const out: string[] = [];
  const p = json(prev) as ReelSpec, n = json(next) as ReelSpec;

  if (!jsonNear(p.style, n.style)) out.push("Filmens stil (övergångar, rörelsekurva och bakgrund) är fotografens val och kan inte ändras här.");

  const pe = (p.editor ?? {}) as Record<string, unknown>, ne = (n.editor ?? {}) as Record<string, unknown>;
  if (pe.tempo !== ne.tempo) out.push("Filmens tempo är fotografens val och kan inte ändras här.");
  if (pe.orderLocked !== ne.orderLocked) out.push("Fotografens ordningslås kan inte ändras här.");
  const added = (key: string, allowed: Iterable<string> = []) => {
    const had = new Set([...strings(pe[key]), ...allowed]);
    return strings(ne[key]).filter((s) => !had.has(s));
  };
  if (added("pinnedAssets", opts.restorablePins).length) out.push("Bara fotografen kan låsa bilder så att de alltid är med.");
  if (added("excludedAssets").length) out.push("Bara fotografen kan utesluta bilder.");

  // Låst övergång och egen rörelse följer bilden så länge den finns kvar. Bilden kan stå
  // flera gånger; då måste varje kvarvarande klipp motsvara ett eget klipp i fotografens
  // version och hålla dess lås, så att en oförändrad kopia inte kan skydda en ändrad.
  out.push(...panelsViolations(p, n));

  const before = clipsBySha(p), after = clipsBySha(n);
  for (const [sha, olds] of before) {
    const locked = olds.filter((o) => isLocked(o.clip));
    if (!locked.length) continue;
    const nows = (after.get(sha) ?? []).map((x) => x.clip);
    if (!nows.length) continue; // borttaget klipp: tillåtet
    const name = (o: Placed) => `Bild ${o.index + 1} (i fotografens version)`;
    if (nows.length > olds.length) {
      out.push(`${name(locked[0])}: bilden har fotografens lås och kan inte läggas till en gång till.`);
      continue;
    }
    if (matchable(olds.map((o) => o.clip), nows)) continue;
    const before0 = out.length;
    for (const o of locked) {
      if (!nows.some((c) => transitionOk(o.clip, c))) out.push(`${name(o)}: fotografen har valt övergången, den kan inte ändras här.`);
      if (!nows.some((c) => motionOk(o.clip, c))) out.push(`${name(o)}: fotografen har gjort en egen rörelse, den kan inte ändras här.`);
    }
    if (out.length === before0) out.push(`${name(locked[0])}: fotografens lås på bilden kan inte ändras här.`);
  }
  return out;
}

const isRec = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const absent = (v: unknown) => v === undefined || v === null;

/**
 * Typkontroll av redigerarens fält (editor, transitionLocked, durationLocked, motionPreset),
 * som parseReelSpec inte kontrollerar. Fel typ gör att fotografens app inte kan läsa filmen.
 * Gäller alla skrivningar. Returnerar svenska meningar (tom lista: inget fel).
 */
export function lockFieldErrors(spec: unknown): string[] {
  const out: string[] = [];
  if (!isRec(spec)) return out;
  const ed = spec.editor;
  if (!absent(ed)) {
    if (!isRec(ed)) out.push("editor måste vara ett objekt.");
    else {
      for (const k of ["pinnedAssets", "excludedAssets"]) {
        const v = ed[k];
        if (!absent(v) && !(Array.isArray(v) && v.every((x) => typeof x === "string"))) out.push(`editor.${k} måste vara en lista med sha256-strängar.`);
      }
      if (!absent(ed.orderLocked) && typeof ed.orderLocked !== "boolean") out.push("editor.orderLocked måste vara true eller false.");
      if (!absent(ed.tempo) && typeof ed.tempo !== "string") out.push("editor.tempo måste vara en sträng.");
      if (!absent(ed.fixedCount) && !(typeof ed.fixedCount === "number" && Number.isInteger(ed.fixedCount))) out.push("editor.fixedCount måste vara ett heltal.");
    }
  }
  const tl = Array.isArray(spec.timeline) ? spec.timeline : [];
  const ids = new Set((Array.isArray(spec.assets) ? spec.assets : []).map((a) => (isRec(a) ? a.id : undefined)));
  tl.forEach((c, i) => {
    if (!isRec(c)) return;
    for (const k of ["transitionLocked", "durationLocked"]) {
      if (!absent(c[k]) && typeof c[k] !== "boolean") out.push(`Klipp ${i + 1}: ${k} måste vara true eller false.`);
    }
    if (!absent(c.motionPreset) && typeof c.motionPreset !== "string") out.push(`Klipp ${i + 1}: motionPreset måste vara en sträng.`);
    out.push(...panelFieldErrors(c, `Klipp ${i + 1}`, ids));
    if (c.fit === "panels" && !(typeof spec.minReaderVersion === "number" && spec.minReaderVersion >= 2)) {
      out.push(`Klipp ${i + 1}: rutklipp kräver minReaderVersion 2.`);
    }
  });
  return out;
}

const LAYOUTS = ["stack", "side", "sequence"];
const ENTRANCES = ["slide", "fade", "none"];
const num = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** Typkontroll av ett klipps rutfält (version 2). Gäller alla skrivningar, även fält på klipp som inte är rutklipp. */
function panelFieldErrors(c: Record<string, unknown>, where: string, ids: Set<unknown>): string[] {
  const out: string[] = [];
  const has = c.fit === "panels" || !absent(c.panels) || !absent(c.layout);
  if (!has && absent(c.gutter) && absent(c.entrance)) return out;
  if (!absent(c.layout) && !(typeof c.layout === "string" && LAYOUTS.includes(c.layout))) out.push(`${where}: layout måste vara stack, side eller sequence.`);
  if (c.fit === "panels" && absent(c.layout)) out.push(`${where}: rutklipp saknar layout.`);
  if (!absent(c.panels) || c.fit === "panels") {
    if (!Array.isArray(c.panels)) out.push(`${where}: panels måste vara en lista.`);
    else {
      const n = c.panels.length;
      if (c.layout === "sequence" ? n < 2 : (c.layout === "stack" || c.layout === "side") && n !== 2) {
        out.push(`${where}: layout ${String(c.layout)} kräver ${c.layout === "sequence" ? "minst två" : "exakt två"} rutor (fick ${n}).`);
      }
      c.panels.forEach((p, k) => {
        const w = `${where} ruta ${k + 1}`;
        if (!isRec(p)) { out.push(`${w}: måste vara ett objekt.`); return; }
        if (typeof p.asset !== "string" || !ids.has(p.asset)) out.push(`${w}: asset måste vara en bild som finns i assets.`);
        const s = p.source;
        if (!absent(s)) {
          const ok = isRec(s) && num(s.x) && num(s.y) && num(s.w) && num(s.h) && s.w > 0 && s.h > 0
            && s.x >= 0 && s.y >= 0 && s.x + s.w <= 1 + 1e-9 && s.y + s.h <= 1 + 1e-9;
          if (!ok) out.push(`${w}: source måste ligga inom bilden (x, y, w, h mellan 0 och 1).`);
        }
      });
    }
  }
  if (!absent(c.gutter) && !(num(c.gutter) && c.gutter >= 0 && c.gutter <= 1)) out.push(`${where}: gutter måste vara ett tal mellan 0 och 1.`);
  if (!absent(c.entrance)) {
    const e = c.entrance;
    if (!isRec(e) || typeof e.type !== "string" || !ENTRANCES.includes(e.type)) out.push(`${where}: entrance.type måste vara slide, fade eller none.`);
    else for (const k of ["stagger", "duration"]) {
      if (!absent(e[k]) && !(num(e[k]) && (e[k] as number) >= 0)) out.push(`${where}: entrance.${k} måste vara ett tal ≥ 0.`);
    }
  }
  return out;
}
