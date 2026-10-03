// Klient för mäklarens API (/api/v1/share). Token kommer ur URL-fragmentet
// (#<token>), som webbläsaren aldrig skickar till servern, och går som
// `Authorization: Link <token>`. Ingen DOM här, så att logiken går att testa i Node.

import type { ReelSpec } from "./reelSpec.ts";

export interface PoolItem {
  assetId: string;
  sha256: string;
  width: number;
  height: number;
  analysis: Record<string, unknown> | null;
  /** Signerad URL till w1600 (null om bilden inte är uppladdad). */
  url: string | null;
  /** Signerad URL till w480. */
  thumbUrl: string | null;
}

export interface RenderItem {
  renderId: string;
  revision: number;
  outputId: string;
  bytes: number;
  width: number | null;
  height: number | null;
  duration: number | null;
  createdAt: string;
  current: boolean;
  url: string;
}

export interface ShareView {
  object: { address: string; status: "draft" | "proposed" | "approved" | "rendered"; currentRevision: number; approvedRevision: number | null; updatedAt: string };
  link: { expiresAt: string; label: string | null };
  approval: { by: string; at: string } | null;
  spec: ReelSpec | null;
  pool: PoolItem[];
  renders: RenderItem[];
}

export class ShareError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "ShareError";
    this.status = status;
    this.code = code;
  }
}

/** Token ur `location.hash` (`#abc…`), eller null om fragmentet saknas eller inte ser ut som en token. */
export function tokenFromHash(hash: string): string | null {
  const m = /^#([A-Za-z0-9_-]{20,128})$/.exec(hash);
  return m ? m[1] : null;
}

export const STATUS_TEXT: Record<ShareView["object"]["status"], string> = {
  draft: "Utkast",
  proposed: "Väntar på ditt godkännande",
  approved: "Godkänd, filmen renderas",
  rendered: "Klar",
};

function messageFor(status: number, code: string, fallback: string): string {
  if (status === 410) return "Länken har gått ut eller återkallats. Kontakta fotografen.";
  if (status === 401) return "Länken stämmer inte. Be fotografen om en ny.";
  if (status === 412) return "Fotografen har ändrat, ladda om.";
  if (status === 409 && code === "revision_mismatch") return "Filmen har ändrats sedan du såg den. Ladda om och godkänn igen.";
  if (status === 429) return "För många anrop. Vänta en stund och försök igen.";
  if (status === 413) return "Det du försökte spara är för stort.";
  return fallback || `Något gick fel (${status}).`;
}

export class ShareClient {
  private token: string;
  private f: typeof fetch;
  constructor(token: string, fetchFn: typeof fetch = (...a) => fetch(...a)) {
    this.token = token;
    this.f = fetchFn;
  }

  private async req(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<{ json: any; etag: string | null }> {
    let r: Response;
    try {
      r = await this.f(path, {
        method,
        headers: { Authorization: `Link ${this.token}`, ...(body !== undefined ? { "Content-Type": "application/json" } : {}), ...headers },
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: "no-store",
        referrerPolicy: "no-referrer",
      });
    } catch {
      throw new ShareError(0, "network", "Ingen kontakt med servern. Kontrollera uppkopplingen.");
    }
    let json: any = null;
    try { json = await r.json(); } catch { /* ingen JSON-kropp */ }
    if (!r.ok) {
      const code = json?.error?.code ?? "error";
      throw new ShareError(r.status, code, messageFor(r.status, code, json?.error?.message ?? ""));
    }
    return { json, etag: r.headers.get("ETag") };
  }

  async get(): Promise<ShareView> {
    return (await this.req("GET", "/api/v1/share")).json as ShareView;
  }

  /** Sparar specen som ny revision. `revision` är den revision ändringen utgår från. */
  async saveSpec(spec: ReelSpec, revision: number): Promise<{ revision: number; status: string; changed: boolean }> {
    return (await this.req("PUT", "/api/v1/share/spec", spec, { "If-Match": `"${revision}"` })).json;
  }

  async approve(revision: number): Promise<{ status: string; revision: number; changed: boolean }> {
    return (await this.req("POST", "/api/v1/share/approve", { revision })).json;
  }
}
