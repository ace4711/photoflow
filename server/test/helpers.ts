// Gemensam testutrustning: temporär datakatalog, server på slumpad port och små fixturer.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig, type Config } from "../src/config.ts";
import { createApp, type App } from "../src/app.ts";
import { createKey } from "../src/cli.ts";
import { sha256hex } from "../src/crypto.ts";
import { setLogSink } from "../src/log.ts";

setLogSink(() => {}); // tysta servern i testerna

export interface TestEnv {
  app: App;
  cfg: Config;
  url: string;
  dir: string;
  clock: { ms: number };
  photographerKey: string;
  renderKey: string;
  photographerId: string;
  close(): Promise<void>;
}

export async function startServer(over: (cfg: Config) => void = () => {}): Promise<TestEnv> {
  const dir = mkdtempSync(join(tmpdir(), "objektfilm-test-"));
  const cfg = loadConfig({
    OBJEKTFILM_ENV: "test", OBJEKTFILM_DATA_DIR: dir, OBJEKTFILM_PORT: "0", OBJEKTFILM_METRICS_PORT: "0",
    OBJEKTFILM_HOST: "127.0.0.1", OBJEKTFILM_METRICS_HOST: "127.0.0.1", OBJEKTFILM_MIN_FREE_BYTES: "0",
    OBJEKTFILM_INVALID_AUTH_DELAY_MS: "0",
    OBJEKTFILM_STATIC_DIR: join(dir, "static"),
  });
  const clock = { ms: Date.parse("2026-10-03T10:00:00Z") };
  cfg.now = () => clock.ms;
  cfg.rate.perMinute = 100000; cfg.rate.globalPerMinute = 1000000; cfg.rate.specPerHour = 100000;
  over(cfg);
  const app = createApp(cfg);
  const { port } = await app.start();
  const pk = createKey(app.d.db, "Testfotograf", "photographer", "test");
  const rk = createKey(app.d.db, "Testfotograf", "render", "worker");
  return {
    app, cfg, url: `http://127.0.0.1:${port}`, dir, clock,
    photographerKey: pk.key, renderKey: rk.key, photographerId: pk.photographerId,
    async close() { await app.stop(); rmSync(dir, { recursive: true, force: true }); },
  };
}

export interface Res { status: number; headers: Headers; json: any; text: string; buf: Buffer }

export async function call(env: TestEnv, method: string, path: string, opts: { auth?: string; body?: unknown; raw?: Uint8Array | string; headers?: Record<string, string>; type?: string } = {}): Promise<Res> {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.auth) headers.Authorization = opts.auth;
  let body: any;
  if (opts.body !== undefined) { body = JSON.stringify(opts.body); headers["Content-Type"] = "application/json"; }
  else if (opts.raw !== undefined) { body = opts.raw; headers["Content-Type"] = opts.type ?? "application/octet-stream"; }
  const r = await fetch(env.url + path, { method, headers, body });
  const buf = Buffer.from(await r.arrayBuffer());
  const text = buf.toString("utf8");
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* inte JSON */ }
  return { status: r.status, headers: r.headers, json, text, buf };
}

export const pf = (env: TestEnv) => `Bearer ${env.photographerKey}`;
export const rk = (env: TestEnv) => `Bearer ${env.renderKey}`;
export const link = (token: string) => `Link ${token}`;

/** Minimal JPEG (bara huvud; servern läser bara mått). `gps` lägger till ett EXIF-segment med GPS-pekare. */
export function fakeJpeg(w: number, h: number, opts: { gps?: boolean; pad?: number } = {}): Buffer {
  const parts: Buffer[] = [Buffer.from([0xff, 0xd8])];
  if (opts.gps) {
    // "Exif\0\0" + TIFF (II, 42, IFD0 vid 8) med en post: tagg 0x8825
    const tiff = Buffer.from([0x49, 0x49, 0x2a, 0, 8, 0, 0, 0, 1, 0, 0x25, 0x88, 4, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const body = Buffer.concat([Buffer.from("Exif\0\0", "latin1"), tiff]);
    parts.push(Buffer.from([0xff, 0xe1, (body.length + 2) >> 8, (body.length + 2) & 255]), body);
  }
  parts.push(Buffer.from([0xff, 0xc0, 0, 17, 8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]));
  parts.push(Buffer.from([0xff, 0xda, 0, 2]));
  parts.push(Buffer.alloc(opts.pad ?? 64, 7));
  parts.push(Buffer.from([0xff, 0xd9]));
  return Buffer.concat(parts);
}

export function fakeMp4(bytes = 2000): Buffer {
  const b = Buffer.alloc(bytes);
  b.writeUInt32BE(24, 0);
  b.write("ftypisom", 4, "latin1");
  for (let i = 24; i < bytes; i++) b[i] = (i * 31) & 255;
  return b;
}

import { randomUUID } from "node:crypto";
let reel = randomUUID();
/** Nytt reel-id för nästa objekt (specBody använder det senaste). */
export const newReel = (): string => (reel = randomUUID());
export const currentReel = (): string => reel;
export const SHAS = ["a", "b", "c", "d"].map((c) => sha256hex(`bild-${c}`));

export function poolBody(n = 4) {
  return { assets: SHAS.slice(0, n).map((sha256, i) => ({ assetId: `a${i + 1}`, sha256, width: 6000, height: 4000, analysis: { room: ["Fasad", "Kök", "Vardagsrum", "Sovrum"][i], category: "x" } })) };
}

export function specBody(clips = [0, 1, 2], extra: Record<string, unknown> = {}) {
  return {
    schema: "photoflow.reel", version: 1, minReaderVersion: 1, id: reel, revision: 0, status: "draft",
    createdAt: "2026-10-03T09:12:00Z", updatedAt: "2026-10-03T09:12:00Z", updatedBy: { role: "photographer", name: "Fredrik" },
    property: { address: "Lindvägen 12, Tyresö" },
    assets: SHAS.slice(0, 3).map((sha256, i) => ({
      id: `a${i + 1}`, sha256, width: 6000, height: 4000,
      sources: [{ kind: "local", path: `/Users/x/hemma/DSC_${i}.jpg` }],
    })),
    style: { defaultTransition: { type: "crossfade", duration: 0.5 }, easing: "easeInOut", background: { type: "blur", amount: 0.5 } },
    timeline: clips.map((i) => ({ asset: `a${i + 1}`, duration: 3, fit: "cover", motion: { from: { cx: 0.5, cy: 0.5, zoom: 1 }, to: { cx: 0.5, cy: 0.5, zoom: 1.1 } } })),
    outputs: [{ id: "9x16", aspect: "9:16", width: 1080, height: 1920, fps: 30 }],
    provenance: { generator: "test" },
    ...extra,
  };
}

/** Skapar objekt, pool, bilder och en första spec (revision 1). Returnerar id. */
export async function seedObject(env: TestEnv, opts: { images?: boolean } = {}): Promise<string> {
  const o = await call(env, "PUT", `/api/v1/objects/by-reel/${newReel()}`, { auth: pf(env), body: { address: "Lindvägen 12, Tyresö", sessionID: "S1", kind: "house" } });
  const id: string = o.json.objectId;
  if (opts.images !== false) {
    for (const sha of SHAS) for (const v of ["w1600", "w480"]) {
      const r = await call(env, "PUT", `/api/v1/assets/${sha}/${v}`, { auth: pf(env), raw: fakeJpeg(v === "w1600" ? 1600 : 480, v === "w1600" ? 1067 : 320), type: "image/jpeg" });
      if (r.status !== 200) throw new Error("bilduppladdning misslyckades: " + r.text);
    }
  }
  const p = await call(env, "PUT", `/api/v1/objects/${id}/pool`, { auth: pf(env), body: poolBody() });
  if (p.status !== 200) throw new Error("pool: " + p.text);
  const s = await call(env, "PUT", `/api/v1/objects/${id}/spec`, { auth: pf(env), body: specBody(), headers: { "If-Match": '"0"' } });
  if (s.status !== 200) throw new Error("spec: " + s.text);
  return id;
}

export async function makeLink(env: TestEnv, id: string, body: unknown = { label: "Mäklare Test", expiresInDays: 30 }): Promise<{ token: string; linkId: string; res: Res }> {
  const r = await call(env, "POST", `/api/v1/objects/${id}/links`, { auth: pf(env), body });
  if (r.status !== 201) throw new Error("länk: " + r.text);
  return { token: String(r.json.url).split("#")[1], linkId: r.json.linkId, res: r };
}
