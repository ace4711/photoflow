// Konfiguration via miljövariabler. Allt har förnuftiga standardvärden utom
// signeringsnyckeln, som krävs i produktion (OBJEKTFILM_ENV=production, standard).

import { randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export interface Config {
  env: "production" | "dev" | "test";
  dataDir: string;
  host: string;
  port: number;
  metricsHost: string;
  metricsPort: number;
  /** Publik bas-URL (utan avslutande snedstreck). Saknas den används serverns egen adress. */
  publicBaseUrl?: string;
  /** Extra tillåtna Origin för mäklarens anrop (utöver publicBaseUrl). */
  extraOrigins: string[];
  signingKey: string;
  staticDir: string;
  limits: { jsonBytes: number; imageBytes: number; mp4Bytes: number; maxAssets: number; maxClips: number };
  rate: { perMinute: number; specPerHour: number; photographerSpecPerHour: number; globalPerMinute: number; invalidDelayMs: number; invalidWarnPer5Min: number };
  minFreeBytes: number;
  purgeDays: number;
  linkDefaultDays: number;
  linkMaxDays: number;
  mediaTtlSeconds: number;
  leaseSeconds: number;
  maxClaimWaitSeconds: number;
  maxAttempts: number;
  /** Klocka (millisekunder sedan epok); byts ut i tester. */
  now: () => number;
}

const here = dirname(fileURLToPath(import.meta.url));

function num(env: NodeJS.ProcessEnv, name: string, def: number): number {
  const v = env[name];
  if (v === undefined || v === "") return def;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`${name} måste vara ett tal (fick "${v}").`);
  return n;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = (env.OBJEKTFILM_ENV ?? "production") as Config["env"];
  if (!["production", "dev", "test"].includes(e)) throw new Error(`OBJEKTFILM_ENV måste vara production, dev eller test.`);
  let signingKey = env.OBJEKTFILM_SIGNING_KEY ?? "";
  if (!signingKey) {
    if (e === "production") throw new Error("OBJEKTFILM_SIGNING_KEY saknas (minst 32 tecken). Skapa en med: openssl rand -base64 48");
    signingKey = randomBytes(32).toString("base64url"); // tillfällig i dev/test: signerade URL:er gäller bara till omstart
  }
  if (signingKey.length < 32) throw new Error("OBJEKTFILM_SIGNING_KEY är för kort (minst 32 tecken).");
  const publicBaseUrl = env.OBJEKTFILM_PUBLIC_URL?.replace(/\/+$/, "") || undefined;
  return {
    env: e,
    dataDir: resolve(env.OBJEKTFILM_DATA_DIR ?? "./data"),
    host: env.OBJEKTFILM_HOST ?? "0.0.0.0",
    port: num(env, "OBJEKTFILM_PORT", 8080),
    metricsHost: env.OBJEKTFILM_METRICS_HOST ?? "0.0.0.0",
    metricsPort: num(env, "OBJEKTFILM_METRICS_PORT", 9471),
    publicBaseUrl,
    extraOrigins: (env.OBJEKTFILM_EXTRA_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean),
    signingKey,
    staticDir: resolve(env.OBJEKTFILM_STATIC_DIR ?? resolve(here, "../../web/reel/dist")),
    limits: {
      jsonBytes: num(env, "OBJEKTFILM_MAX_JSON_BYTES", 256 * 1024),
      imageBytes: num(env, "OBJEKTFILM_MAX_IMAGE_BYTES", 4 * 1024 * 1024),
      mp4Bytes: num(env, "OBJEKTFILM_MAX_MP4_BYTES", 300 * 1024 * 1024),
      maxAssets: 40,
      maxClips: 30,
    },
    rate: {
      perMinute: num(env, "OBJEKTFILM_RATE_PER_MINUTE", 120),
      specPerHour: num(env, "OBJEKTFILM_RATE_SPEC_PER_HOUR", 30),
      photographerSpecPerHour: num(env, "OBJEKTFILM_RATE_PHOTOGRAPHER_SPEC_PER_HOUR", 600),
      globalPerMinute: num(env, "OBJEKTFILM_RATE_GLOBAL_PER_MINUTE", 1200),
      invalidDelayMs: num(env, "OBJEKTFILM_INVALID_AUTH_DELAY_MS", 300),
      invalidWarnPer5Min: 50,
    },
    minFreeBytes: num(env, "OBJEKTFILM_MIN_FREE_BYTES", 5 * 1024 ** 3),
    purgeDays: num(env, "OBJEKTFILM_PURGE_DAYS", 90),
    linkDefaultDays: 30,
    linkMaxDays: 90,
    mediaTtlSeconds: 3600,
    leaseSeconds: 600,
    maxClaimWaitSeconds: 25,
    maxAttempts: 3,
    now: () => Date.now(),
  };
}
