// Matchar reelens assets mot filer användaren valt (mapp, flera filer eller
// släpp). Först på filnamn från `sources[].path` (utan skillnad på stora/små
// bokstäver och Unicode-normalisering; macOS lagrar å/ä/ö i NFD), därefter på
// SHA-256 om `crypto.subtle` finns. Ren logik utan DOM utom `File`/crypto, så
// att den går att testa i Node.

import type { Asset } from "./reelSpec.ts";

export interface NamedFile { name: string; size?: number; arrayBuffer(): Promise<ArrayBuffer> }

export function normName(s: string): string {
  const base = s.split(/[\\/]/).pop() ?? s;
  return base.normalize("NFC").toLowerCase();
}

export const IMAGE_EXT = /\.(jpe?g|png|webp|gif|avif|heic)$/i;

export async function sha256Hex(data: ArrayBuffer): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

export interface MatchResult<F> {
  /** asset-id → fil */
  matched: Map<string, F>;
  /** asset-id som saknar fil */
  missing: string[];
  /** Hur varje asset hittades (för visning). */
  how: Map<string, "namn" | "sha256">;
}

export async function matchAssets<F extends NamedFile>(assets: Asset[], files: F[]): Promise<MatchResult<F>> {
  const images = files.filter((f) => IMAGE_EXT.test(f.name));
  const byName = new Map<string, F>();
  for (const f of images) if (!byName.has(normName(f.name))) byName.set(normName(f.name), f);

  const matched = new Map<string, F>();
  const how = new Map<string, "namn" | "sha256">();
  const used = new Set<F>();
  for (const a of assets) {
    for (const s of a.sources) {
      if (s.kind !== "local" || !s.path) continue;
      const f = byName.get(normName(s.path));
      if (f) { matched.set(a.id, f); how.set(a.id, "namn"); used.add(f); break; }
    }
  }

  const rest = assets.filter((a) => !matched.has(a.id));
  if (rest.length > 0 && typeof crypto !== "undefined" && crypto.subtle) {
    const hashes = new Map<string, F>();
    for (const f of images) {
      if (used.has(f)) continue;
      hashes.set(await sha256Hex(await f.arrayBuffer()), f);
    }
    for (const a of rest) {
      const f = hashes.get(a.sha256.toLowerCase());
      if (f) { matched.set(a.id, f); how.set(a.id, "sha256"); }
    }
  }
  return { matched, missing: assets.filter((a) => !matched.has(a.id)).map((a) => a.id), how, };
}
