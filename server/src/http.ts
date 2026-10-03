// HTTP-hjälpare på Nodes inbyggda `http`: router, JSON, kroppsläsning med gräns,
// säkerhetsheaders och filservering med Range-stöd.

import type { IncomingMessage, ServerResponse } from "node:http";
import { createReadStream, statSync } from "node:fs";
import { ApiError } from "./errors.ts";

export const CSP = "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";

export function securityHeaders(res: ServerResponse): void {
  res.setHeader("Content-Security-Policy", CSP);
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  res.setHeader("Strict-Transport-Security", "max-age=31536000"); // medvetet utan includeSubDomains
  res.setHeader("X-Robots-Tag", "noindex, nofollow");
  res.setHeader("X-Objektfilm", "1");
}

export function sendJson(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": data.length, "Cache-Control": "no-store", ...headers });
  res.end(data);
}

export function sendText(res: ServerResponse, status: number, body: string, type = "text/plain; charset=utf-8", headers: Record<string, string> = {}): void {
  const data = Buffer.from(body);
  res.writeHead(status, { "Content-Type": type, "Content-Length": data.length, "Cache-Control": "no-store", ...headers });
  res.end(data);
}

export function sendError(res: ServerResponse, e: ApiError): void {
  const h: Record<string, string> = { ...e.headers };
  if (e.status === 413) h.Connection = "close";
  sendJson(res, e.status, { error: { code: e.code, message: e.message }, ...e.extra }, h);
}

export function declaredLength(req: IncomingMessage): number | null {
  const v = req.headers["content-length"];
  if (v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : NaN;
}

export function tooLarge(max: number, what: string): ApiError {
  const mb = max >= 1024 * 1024 ? `${Math.round(max / 1048576)} MB` : `${Math.round(max / 1024)} kB`;
  return new ApiError(413, "payload_too_large", `${what} är för stor (högst ${mb}).`);
}

/** Läser hela kroppen i minnet med hård gräns. */
export async function readBuffer(req: IncomingMessage, max: number, what: string): Promise<Buffer> {
  const len = declaredLength(req);
  if (len !== null && (Number.isNaN(len) || len > max)) throw tooLarge(max, what);
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    n += (c as Buffer).length;
    if (n > max) throw tooLarge(max, what);
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks);
}

export async function readJson(req: IncomingMessage, max: number): Promise<unknown> {
  const ct = String(req.headers["content-type"] ?? "");
  if (!/^application\/json\b/i.test(ct)) throw new ApiError(415, "unsupported_media_type", "Content-Type måste vara application/json.");
  const buf = await readBuffer(req, max, "JSON-kroppen");
  try { return JSON.parse(buf.toString("utf8")); } catch { throw new ApiError(400, "bad_json", "Kroppen är inte giltig JSON."); }
}

// ------------------------------------------------------------------ filservering

function parseRange(h: string, size: number): { start: number; end: number } | "bad" | null {
  const m = /^bytes=(\d*)-(\d*)$/.exec(h.trim());
  if (!m) return null; // okänt format: ignorera och skicka hela filen (RFC 9110)
  const [, a, b] = m;
  if (a === "" && b === "") return null;
  let start: number, end: number;
  if (a === "") { const n = Number(b); if (n === 0) return "bad"; start = Math.max(0, size - n); end = size - 1; }
  else { start = Number(a); end = b === "" ? size - 1 : Math.min(Number(b), size - 1); }
  if (start >= size || start > end) return "bad";
  return { start, end };
}

export function serveFile(req: IncomingMessage, res: ServerResponse, path: string, type: string, headers: Record<string, string> = {}): void {
  let size: number;
  try { size = statSync(path).size; } catch { throw new ApiError(404, "not_found", "Filen finns inte."); }
  const base = { "Content-Type": type, "Accept-Ranges": "bytes", ...headers };
  const rangeHdr = req.headers.range;
  const range = rangeHdr && size > 0 ? parseRange(rangeHdr, size) : null;
  if (range === "bad") {
    res.writeHead(416, { ...base, "Content-Range": `bytes */${size}`, "Content-Length": 0 });
    res.end();
    return;
  }
  const status = range ? 206 : 200;
  const start = range ? range.start : 0;
  const end = range ? range.end : size - 1;
  const len = size === 0 ? 0 : end - start + 1;
  res.writeHead(status, { ...base, "Content-Length": len, ...(range ? { "Content-Range": `bytes ${start}-${end}/${size}` } : {}) });
  if (req.method === "HEAD" || len === 0) { res.end(); return; }
  const rs = createReadStream(path, { start, end });
  rs.on("error", () => res.destroy());
  res.on("close", () => rs.destroy());
  rs.pipe(res);
}

// ------------------------------------------------------------------ router

export type AuthMode = "none" | "photographer" | "render" | "either" | "link";

export interface Route<C> {
  method: string;
  pattern: string;
  auth: AuthMode;
  handler: (c: C) => void | Promise<void>;
  /** Mönstret används som route-etikett i logg och mätvärden. */
  re: RegExp;
  keys: string[];
}

export function route<C>(method: string, pattern: string, auth: AuthMode, handler: (c: C) => void | Promise<void>): Route<C> {
  const keys: string[] = [];
  const re = new RegExp("^" + pattern.replace(/:([a-zA-Z]+)/g, (_m, k) => { keys.push(k); return "([^/]+)"; }) + "$");
  return { method, pattern, auth, handler, re, keys };
}

export function matchRoute<C>(routes: Route<C>[], method: string, path: string): { route?: Route<C>; params: Record<string, string>; pathMatched: boolean } {
  let pathMatched = false;
  for (const r of routes) {
    const m = r.re.exec(path);
    if (!m) continue;
    pathMatched = true;
    if (r.method !== method && !(method === "HEAD" && r.method === "GET")) continue;
    const params: Record<string, string> = {};
    r.keys.forEach((k, i) => { try { params[k] = decodeURIComponent(m[i + 1]); } catch { params[k] = m[i + 1]; } });
    return { route: r, params, pathMatched };
  }
  return { params: {}, pathMatched };
}
