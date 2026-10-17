// Fotografens lås mot mäklarskrivningar (docs/reel-spec-v1.md avsnitt 2).
// Mäklarens webbeditor (web/reel/src/regi.ts) respekterar låsen; servern kontrollerar
// samma sak så att en annan klient inte kan ändra dem. Ren funktion utan databas.
//
// Mäklaren får flytta, ta bort och lägga till klipp, ändra olåsta längder och förval,
// låta automatiska övergångar räknas om, släppa en pinning (borttaget pinnat klipp)
// och släppa en uteslutning (aktivt tillagd utesluten bild). Mäklaren får inte ändra
// style, editor.tempo, editor.orderLocked, lägga till pinningar eller uteslutningar,
// ändra en låst övergång eller en egen rörelse ("custom") på en bild som finns kvar.
// Klipp matchas på bildens sha256, eftersom asset-id kan numreras om.

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

function clipsBySha(spec: ReelSpec): Map<string, { clip: Clip; index: number }> {
  const shaOf = new Map(spec.assets.map((a) => [a.id, a.sha256]));
  const m = new Map<string, { clip: Clip; index: number }>();
  spec.timeline.forEach((clip, index) => {
    const sha = shaOf.get(clip.asset);
    if (sha && !m.has(sha)) m.set(sha, { clip, index });
  });
  return m;
}

/**
 * Lås som `next` bryter jämfört med föregående sparade revision `prev`, som svenska
 * meningar (tom lista: inget brott). Används bara för mäklarens skrivningar.
 */
export function lockViolations(prev: ReelSpec, next: ReelSpec): string[] {
  const out: string[] = [];
  const p = json(prev) as ReelSpec, n = json(next) as ReelSpec;

  if (!jsonNear(p.style, n.style)) out.push("Filmens stil (övergångar, rörelsekurva och bakgrund) är fotografens val och kan inte ändras här.");

  const pe = (p.editor ?? {}) as Record<string, unknown>, ne = (n.editor ?? {}) as Record<string, unknown>;
  if (pe.tempo !== ne.tempo) out.push("Filmens tempo är fotografens val och kan inte ändras här.");
  if (pe.orderLocked !== ne.orderLocked) out.push("Fotografens ordningslås kan inte ändras här.");
  const added = (key: string) => { const had = new Set(strings(pe[key])); return strings(ne[key]).filter((s) => !had.has(s)); };
  if (added("pinnedAssets").length) out.push("Bara fotografen kan låsa bilder så att de alltid är med.");
  if (added("excludedAssets").length) out.push("Bara fotografen kan utesluta bilder.");

  const before = clipsBySha(p), after = clipsBySha(n);
  for (const [sha, { clip: old, index }] of before) {
    const now = after.get(sha)?.clip;
    if (!now) continue; // borttaget klipp: tillåtet
    const name = `Bild ${index + 1} (i fotografens version)`;
    if (old.transitionLocked === true && (now.transitionLocked !== true || !jsonNear(old.transitionIn, now.transitionIn))) {
      out.push(`${name}: fotografen har valt övergången, den kan inte ändras här.`);
    }
    if (old.motionPreset === "custom" &&
      (now.motionPreset !== "custom" || now.fit !== old.fit || !jsonNear(old.motion, now.motion))) {
      out.push(`${name}: fotografen har gjort en egen rörelse, den kan inte ändras här.`);
    }
  }
  return out;
}
