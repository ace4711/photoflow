// Godkännande: en uppdaterad kopia av specen (ingen backend i prototypen).

import type { ReelSpec } from "./reelSpec.ts";

/** Den uppdaterade specen (kopia): revision +1, status "approved", mäklaren som senaste ändrare. */
export function approvedCopy(src: ReelSpec, ops: string[], name: string, at: string): ReelSpec {
  const out = structuredClone(src);
  out.revision = src.revision + 1;
  out.status = "approved";
  out.updatedAt = at;
  out.updatedBy = name ? { role: "agent", name } : { role: "agent" };
  out.provenance ??= { generator: "okänd" };
  const edits = out.provenance.edits ?? [];
  for (const op of ops.length ? ops : ["approve"]) edits.push({ at, by: "agent", op });
  if (ops.length) edits.push({ at, by: "agent", op: "approve" });
  out.provenance.edits = edits;
  return out;
}
