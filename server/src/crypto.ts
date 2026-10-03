// Hashar, token- och nyckelgenerering och HMAC-signering av media-URL:er.

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export function sha256hex(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

/** Mäklarlänkens token: 32 slumpbyte (256 bitar), base64url. Bara sha256(token) lagras. */
export function newToken(): string { return randomBytes(32).toString("base64url"); }

/** API-nyckel: `pf_` + 32 slumpbyte base64url. */
export function newApiKey(): string { return "pf_" + randomBytes(32).toString("base64url"); }

export const hashSecret = (s: string): string => sha256hex(s);

/** JSON med sorterade nycklar (kanonisk form för content_hash). */
export function canonicalJson(v: unknown): string {
  return JSON.stringify(sortKeys(v));
}
function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, sortKeys(o[k])]));
  }
  return v;
}

function mediaMac(secret: string, exp: number, key: string): string {
  return createHmac("sha256", secret).update(`${exp}\n${key}`).digest("base64url");
}

/** Signerad relativ media-URL: /media/<exp>/<sig>/<key>. `exp` är sekunder sedan epok. */
export function signedMediaPath(secret: string, key: string, expSeconds: number): string {
  return `/media/${expSeconds}/${mediaMac(secret, expSeconds, key)}/${key}`;
}

export type MediaCheck = "ok" | "expired" | "bad";
export function verifyMedia(secret: string, exp: number, sig: string, key: string, nowMs: number): MediaCheck {
  const want = Buffer.from(mediaMac(secret, exp, key));
  const got = Buffer.from(sig);
  if (want.length !== got.length || !timingSafeEqual(want, got)) return "bad";
  return exp * 1000 < nowMs ? "expired" : "ok";
}
