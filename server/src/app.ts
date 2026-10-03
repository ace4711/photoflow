// Servern: routes, autentisering, takt, statiska sidor och mätvärdesporten.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { EventEmitter, once } from "node:events";
import { createWriteStream, existsSync, readFileSync, rmSync, statfsSync, statSync, writeFileSync, accessSync, constants } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { finished } from "node:stream/promises";
import type { Config } from "./config.ts";
import { type Db, openDb } from "./db.ts";
import { BlobStore } from "./store.ts";
import { Counters, renderMetrics } from "./metrics.ts";
import { RateLimiter } from "./ratelimit.ts";
import { ApiError } from "./errors.ts";
import { hashSecret, verifyMedia } from "./crypto.ts";
import { log } from "./log.ts";
import * as dom from "./domain.ts";
import type { Deps, LinkRow, ObjectRow, Role } from "./domain.ts";
import {
  type Route, declaredLength, matchRoute, readBuffer, readJson, route, securityHeaders, sendError, sendJson, sendText, serveFile, tooLarge,
} from "./http.ts";

interface PhotographerAuth { kind: "key"; keyId: string; photographerId: string; scope: "photographer" | "render"; label: string | null; name: string }
interface LinkAuth { kind: "link"; link: LinkRow; object: ObjectRow }

interface Ctx {
  req: IncomingMessage;
  res: ServerResponse;
  url: URL;
  params: Record<string, string>;
  key?: PhotographerAuth;
  link?: LinkAuth;
  fields: Record<string, unknown>;
}

const MEDIA_TYPES: Record<string, string> = {
  ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".map": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".html": "text/html; charset=utf-8",
};

const LANDING = `<!doctype html>
<html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>Objektfilm</title><link rel="stylesheet" href="/styles.css"></head>
<body><main><section class="card"><h1>Objektfilm</h1><p>Den här tjänsten kräver en länk från fotografen. Kontakta fotografen om du saknar den.</p></section></main></body></html>
`;

export interface App {
  d: Deps;
  server: Server;
  metricsServer: Server;
  limiter: RateLimiter;
  start(): Promise<{ port: number; metricsPort: number }>;
  stop(): Promise<void>;
  baseUrl(): string;
}

export function createApp(cfg: Config, existingDb?: Db): App {
  const db = existingDb ?? openDb(cfg.dataDir);
  const store = new BlobStore(cfg.dataDir);
  const counters = new Counters();
  const limiter = new RateLimiter();
  const bus = new EventEmitter();
  bus.setMaxListeners(0);
  let listenPort = 0;
  const baseUrl = (): string => cfg.publicBaseUrl ?? `http://127.0.0.1:${listenPort}`;
  const d: Deps = { db, cfg, store, counters, bus, baseUrl, now: () => cfg.now() };

  const allowedOrigins = (): string[] => [new URL(baseUrl()).origin, ...cfg.extraOrigins];

  // ---------------------------------------------------------------- auth

  async function invalidAuth(c: Ctx): Promise<never> {
    counters.invalidAuth++;
    const n = limiter.hit("invalid", Infinity, 300_000, d.now());
    void n;
    const count = limiter.count("invalid");
    if (count === cfg.rate.invalidWarnPer5Min + 1) log("warn", "Många ogiltiga inloggningsförsök", { count, perMinutes: 5 });
    if (cfg.rate.invalidDelayMs > 0) await new Promise((r) => setTimeout(r, cfg.rate.invalidDelayMs));
    throw new ApiError(401, "unauthorized", "Ogiltig eller saknad behörighet.", {}, { "WWW-Authenticate": c.url.pathname.startsWith("/api/v1/share") ? "Link" : "Bearer" });
  }

  function limit(key: string, max: number, windowMs: number): void {
    const wait = limiter.hit(key, max, windowMs, d.now());
    if (wait > 0) {
      counters.rateLimited++;
      throw new ApiError(429, "rate_limited", "För många anrop. Vänta en stund och försök igen.", { retryAfterSeconds: wait }, { "Retry-After": String(wait) });
    }
  }

  async function authenticate(c: Ctx, mode: Route<Ctx>["auth"]): Promise<void> {
    if (mode === "none") return;
    const h = String(c.req.headers.authorization ?? "");
    if (mode === "link") {
      const origin = c.req.headers.origin;
      if (origin !== undefined && !allowedOrigins().includes(String(origin))) throw new ApiError(403, "bad_origin", "Anropet kommer från fel ursprung.");
      const m = /^Link\s+([A-Za-z0-9_-]{20,128})$/.exec(h);
      if (!m) { if (h) await invalidAuth(c); throw new ApiError(401, "unauthorized", "Länk saknas.", {}, { "WWW-Authenticate": "Link" }); }
      const link = db.prepare("SELECT * FROM links WHERE token_hash = ?").get(hashSecret(m[1])) as LinkRow | undefined;
      if (!link) return invalidAuth(c);
      if (link.revoked_at) throw new ApiError(410, "link_revoked", "Länken har återkallats. Kontakta fotografen.");
      if (link.expires_at <= dom.iso(d)) throw new ApiError(410, "link_expired", "Länken har gått ut. Kontakta fotografen.");
      const object = dom.getObject(d, link.object_id)!;
      c.link = { kind: "link", link, object };
      c.fields.linkId = link.id; c.fields.objectId = object.id; c.fields.role = "agent";
      limit(`l:${link.id}`, cfg.rate.perMinute, 60_000);
      if (!link.last_used_at || Date.parse(link.last_used_at) < d.now() - 60_000) {
        db.prepare("UPDATE links SET last_used_at = ? WHERE id = ?").run(dom.iso(d), link.id);
      }
      return;
    }
    const m = /^Bearer\s+(pf_[A-Za-z0-9_-]{20,128})$/.exec(h);
    if (!m) { if (h) await invalidAuth(c); throw new ApiError(401, "unauthorized", "API-nyckel saknas.", {}, { "WWW-Authenticate": "Bearer" }); }
    const row = db.prepare(
      `SELECT k.id, k.photographer_id, k.scope, k.label, k.revoked_at, k.last_used_at, p.name, p.disabled_at
         FROM api_keys k JOIN photographers p ON p.id = k.photographer_id WHERE k.key_hash = ?`).get(hashSecret(m[1])) as
      { id: string; photographer_id: string; scope: "photographer" | "render"; label: string | null; revoked_at: string | null; last_used_at: string | null; name: string; disabled_at: string | null } | undefined;
    if (!row || row.revoked_at || row.disabled_at) return invalidAuth(c);
    if (mode !== "either" && row.scope !== mode) throw new ApiError(403, "wrong_scope", `Nyckeln har inte behörighet (kräver scope ${mode}).`);
    c.key = { kind: "key", keyId: row.id, photographerId: row.photographer_id, scope: row.scope, label: row.label, name: row.name };
    c.fields.keyId = row.id; c.fields.role = row.scope;
    limit(`k:${row.id}`, cfg.rate.perMinute, 60_000);
    if (!row.last_used_at || Date.parse(row.last_used_at) < d.now() - 60_000) {
      db.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?").run(dom.iso(d), row.id);
    }
  }

  const K = (c: Ctx): PhotographerAuth => c.key!;
  const L = (c: Ctx): LinkAuth => c.link!;
  const ownObject = (c: Ctx): ObjectRow => {
    const o = dom.getOwnedObject(d, c.params.id, K(c).photographerId);
    c.fields.objectId = o.id;
    return o;
  };
  const photographerActor = (c: Ctx) => ({ role: "photographer" as Role, ref: K(c).keyId });
  const etag = (rev: number): Record<string, string> => ({ ETag: `"${rev}"` });

  // ---------------------------------------------------------------- statiskt

  function readStatic(name: string): Buffer | null {
    const p = join(cfg.staticDir, name);
    try { return existsSync(p) ? readFileSync(p) : null; } catch { return null; }
  }
  function sendPage(c: Ctx, file: string): void {
    const body = readStatic(file);
    if (!body) throw new ApiError(503, "web_missing", "Webbdelen är inte byggd (kör npm run build i web/reel).");
    c.res.writeHead(200, { "Content-Type": MEDIA_TYPES[".html"], "Content-Length": body.length, "Cache-Control": "no-cache" });
    c.res.end(c.req.method === "HEAD" ? undefined : body);
  }
  function sendStatic(c: Ctx): void {
    const name = c.params.name;
    const ext = /\.[a-z0-9]+$/.exec(name)?.[0] ?? "";
    if (!/^[A-Za-z0-9._-]+$/.test(name) || name.startsWith(".") || !MEDIA_TYPES[ext] || ext === ".html") throw new ApiError(404, "not_found", "Sidan finns inte.");
    const p = join(cfg.staticDir, name);
    if (!existsSync(p)) throw new ApiError(404, "not_found", "Sidan finns inte.");
    const st = statSync(p);
    const tag = `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`;
    if (c.req.headers["if-none-match"] === tag) { c.res.writeHead(304, { ETag: tag }); c.res.end(); return; }
    serveFile(c.req, c.res, p, MEDIA_TYPES[ext], { "Cache-Control": "no-cache", ETag: tag });
  }

  // ---------------------------------------------------------------- hälsa

  function health(c: Ctx): void {
    const fail = (what: string) => sendText(c.res, 503, `objektfilm fel: ${what}\n`);
    try { db.prepare("SELECT 1").get(); } catch { return fail("databas"); }
    try {
      accessSync(cfg.dataDir, constants.W_OK);
      const probe = join(store.tmpDir, ".healthz");
      writeFileSync(probe, "ok"); rmSync(probe, { force: true });
    } catch { return fail("skrivning"); }
    try {
      const s = statfsSync(cfg.dataDir);
      if (s.bavail * s.bsize < cfg.minFreeBytes) return fail("disk");
    } catch { return fail("disk"); }
    sendText(c.res, 200, "objektfilm ok\n");
  }

  // ---------------------------------------------------------------- media

  function media(c: Ctx): void {
    const rest = c.url.pathname.slice("/media/".length).split("/");
    const exp = Number(rest[0]);
    const sig = rest[1] ?? "";
    const key = rest.slice(2).join("/");
    if (!Number.isInteger(exp) || !sig || !key) throw new ApiError(403, "bad_signature", "Ogiltig mediadress.");
    const v = verifyMedia(cfg.signingKey, exp, sig, key, d.now());
    if (v === "bad") throw new ApiError(403, "bad_signature", "Ogiltig mediadress.");
    if (v === "expired") throw new ApiError(410, "media_expired", "Mediadressen har gått ut. Ladda om sidan.");
    const priv = { "Cache-Control": "private, max-age=3600" };
    let m = /^img\/([0-9a-f]{64})\/(w1600|w480)$/.exec(key);
    if (m) {
      if (!db.prepare("SELECT 1 FROM blobs WHERE sha256_orig = ? AND variant = ?").get(m[1], m[2])) throw new ApiError(404, "not_found", "Bilden finns inte.");
      return serveFile(c.req, c.res, store.imagePath(m[1], m[2] as "w1600" | "w480"), "image/jpeg", priv);
    }
    m = /^render\/([0-9a-f-]{36})$/.exec(key);
    if (m) {
      const r = db.prepare("SELECT sha256 FROM renders WHERE id = ?").get(m[1]) as { sha256: string } | undefined;
      if (!r) throw new ApiError(404, "not_found", "Filmen finns inte.");
      return serveFile(c.req, c.res, store.mp4Path(r.sha256), "video/mp4", { ...priv, "Content-Disposition": 'inline; filename="Objektfilm.mp4"' });
    }
    throw new ApiError(404, "not_found", "Okänd mediatyp.");
  }

  // ---------------------------------------------------------------- routes

  const routes: Route<Ctx>[] = [
    route("GET", "/", "none", (c) => sendText(c.res, 200, LANDING, "text/html; charset=utf-8", { "Cache-Control": "no-cache" })),
    route("GET", "/m", "none", (c) => sendPage(c, "index.html")),
    route("GET", "/a", "none", (c) => sendPage(c, "archive.html")),
    route("GET", "/robots.txt", "none", (c) => sendText(c.res, 200, "User-agent: *\nDisallow: /\n")),
    route("GET", "/healthz", "none", health),
    route("GET", "/favicon.ico", "none", (c) => { c.res.writeHead(204, { "Cache-Control": "public, max-age=86400" }); c.res.end(); }),
    route("GET", "/media/.+", "none", media),
    route("GET", "/:name", "none", sendStatic),

    // ---- fotograf
    route("GET", "/api/v1/me", "either", (c) => sendJson(c.res, 200, {
      apiVersion: 1, scope: K(c).scope, keyId: K(c).keyId, photographer: { id: K(c).photographerId, name: K(c).name }, serverTime: dom.iso(d),
    })),
    route("PUT", "/api/v1/objects/by-reel/:reelId", "photographer", async (c) => {
      const body = await readJson(c.req, cfg.limits.jsonBytes);
      const { object, created } = dom.upsertObject(d, K(c).photographerId, c.params.reelId, body);
      c.fields.objectId = object.id;
      sendJson(c.res, created ? 201 : 200, { objectId: object.id, status: object.status, currentRevision: object.current_revision }, etag(object.current_revision));
    }),
    route("POST", "/api/v1/assets/check", "photographer", async (c) => {
      const body = await readJson(c.req, cfg.limits.jsonBytes);
      const shas = typeof body === "object" && body !== null ? (body as Record<string, unknown>).sha256 : undefined;
      sendJson(c.res, 200, { missing: dom.checkAssets(d, shas) });
    }),
    route("PUT", "/api/v1/assets/:sha/:variant", "photographer", async (c) => {
      if (!/^image\/jpeg\b/i.test(String(c.req.headers["content-type"] ?? ""))) throw new ApiError(415, "unsupported_media_type", "Bara image/jpeg tillåts.");
      const buf = await readBuffer(c.req, cfg.limits.imageBytes, "Bilden");
      sendJson(c.res, 200, dom.putVariant(d, c.params.sha, c.params.variant, buf));
    }),
    route("PUT", "/api/v1/objects/:id/pool", "photographer", async (c) => {
      const o = ownObject(c);
      const body = await readJson(c.req, cfg.limits.jsonBytes);
      sendJson(c.res, 200, dom.setPool(d, o, body));
    }),
    route("GET", "/api/v1/objects", "photographer", (c) => {
      sendJson(c.res, 200, { objects: dom.listObjects(d, K(c).photographerId, c.url.searchParams.get("status") ?? undefined, c.url.searchParams.get("since") ?? undefined) });
    }),
    route("GET", "/api/v1/objects/:id", "photographer", (c) => {
      const o = ownObject(c);
      sendJson(c.res, 200, dom.objectDetail(d, o), etag(o.current_revision));
    }),
    route("PUT", "/api/v1/objects/:id/spec", "photographer", async (c) => {
      const o = ownObject(c);
      limit(`s:${K(c).keyId}`, cfg.rate.photographerSpecPerHour, 3600_000);
      const body = await readJson(c.req, cfg.limits.jsonBytes);
      const r = dom.saveSpec(d, o.id, body, dom.parseIfMatch(c.req.headers["if-match"]), photographerActor(c));
      const cur = dom.getObject(d, o.id)!;
      sendJson(c.res, 200, { objectId: o.id, revision: r.revision, status: cur.status, changed: r.changed, spec: r.spec }, etag(r.revision));
    }),
    route("POST", "/api/v1/objects/:id/links", "photographer", async (c) => {
      const o = ownObject(c);
      const raw = await readBuffer(c.req, cfg.limits.jsonBytes, "JSON-kroppen");
      let body: unknown = {};
      if (raw.length > 0) { try { body = JSON.parse(raw.toString("utf8")); } catch { throw new ApiError(400, "bad_json", "Kroppen är inte giltig JSON."); } }
      sendJson(c.res, 201, dom.createLink(d, o, body, photographerActor(c)));
    }),
    route("DELETE", "/api/v1/links/:id", "photographer", (c) => {
      dom.revokeLink(d, c.params.id, K(c).photographerId, photographerActor(c));
      sendJson(c.res, 200, { revoked: true });
    }),
    route("POST", "/api/v1/objects/:id/approve", "photographer", async (c) => {
      const o = ownObject(c);
      const body = await readJson(c.req, cfg.limits.jsonBytes) as Record<string, unknown> | null;
      sendJson(c.res, 200, dom.approve(d, o.id, body?.revision, photographerActor(c)));
    }),
    route("DELETE", "/api/v1/objects/:id", "photographer", (c) => {
      const o = ownObject(c);
      dom.deleteObject(d, o.id);
      sendJson(c.res, 200, { deleted: true });
    }),

    // ---- mäklare
    route("GET", "/api/v1/share", "link", (c) => {
      const { link } = L(c);
      const o = dom.getObject(d, link.object_id)!;
      sendJson(c.res, 200, dom.shareView(d, o, link), etag(o.current_revision));
    }),
    route("PUT", "/api/v1/share/spec", "link", async (c) => {
      const { link } = L(c);
      limit(`ls:${link.id}`, cfg.rate.specPerHour, 3600_000);
      const body = await readJson(c.req, cfg.limits.jsonBytes);
      const name = typeof body === "object" && body !== null && typeof (body as Record<string, any>).updatedBy?.name === "string" ? String((body as Record<string, any>).updatedBy.name) : undefined;
      const r = dom.saveSpec(d, link.object_id, body, dom.parseIfMatch(c.req.headers["if-match"]), { role: "agent", ref: link.id, name });
      const cur = dom.getObject(d, link.object_id)!;
      sendJson(c.res, 200, { revision: r.revision, status: cur.status, changed: r.changed }, etag(r.revision));
    }),
    route("POST", "/api/v1/share/approve", "link", async (c) => {
      const { link } = L(c);
      const body = await readJson(c.req, cfg.limits.jsonBytes) as Record<string, unknown> | null;
      sendJson(c.res, 200, dom.approve(d, link.object_id, body?.revision, { role: "agent", ref: link.id }));
    }),
    route("GET", "/api/v1/share/renders/:id", "link", (c) => {
      const { link } = L(c);
      const r = db.prepare("SELECT sha256 FROM renders WHERE id = ? AND object_id = ?").get(c.params.id, link.object_id) as { sha256: string } | undefined;
      if (!r) throw new ApiError(404, "not_found", "Filmen finns inte.");
      serveFile(c.req, c.res, store.mp4Path(r.sha256), "video/mp4", { "Cache-Control": "private, no-store", "Content-Disposition": 'inline; filename="Objektfilm.mp4"' });
    }),

    // ---- renderkö
    route("POST", "/api/v1/render-jobs/claim", "render", async (c) => {
      const k = K(c);
      const wait = Math.min(Math.max(Number(c.url.searchParams.get("wait") ?? 0) || 0, 0), cfg.maxClaimWaitSeconds);
      dom.touchWorker(d, k.keyId, k.label);
      let gone = false;
      c.res.on("close", () => { gone = true; });
      const deadline = Date.now() + wait * 1000;
      for (;;) {
        const job = dom.tryClaim(d, k.keyId, k.photographerId);
        if (job) { c.fields.objectId = job.objectId; return sendJson(c.res, 200, job); }
        const left = deadline - Date.now();
        if (gone) return;
        if (left <= 0) {
          dom.touchWorker(d, k.keyId, k.label);
          c.res.writeHead(204, { "Cache-Control": "no-store" });
          return void c.res.end();
        }
        await new Promise<void>((resolve) => {
          const t = setTimeout(done, Math.min(left, 1000));
          function done() { clearTimeout(t); bus.off("job", done); c.res.off("close", done); resolve(); }
          bus.once("job", done);
          c.res.once("close", done);
        });
      }
    }),
    route("POST", "/api/v1/render-jobs/:id/heartbeat", "render", (c) => {
      const j = dom.getJobFor(d, c.params.id, K(c).keyId, K(c).photographerId);
      c.fields.objectId = j.object_id;
      dom.touchWorker(d, K(c).keyId, K(c).label);
      sendJson(c.res, 200, { leaseUntil: dom.heartbeat(d, j, K(c).keyId) });
    }),
    route("PUT", "/api/v1/render-jobs/:id/output", "render", uploadOutput),
    route("POST", "/api/v1/render-jobs/:id/fail", "render", async (c) => {
      const j = dom.getJobFor(d, c.params.id, K(c).keyId, K(c).photographerId);
      c.fields.objectId = j.object_id;
      const body = await readJson(c.req, cfg.limits.jsonBytes) as Record<string, unknown> | null;
      sendJson(c.res, 200, dom.failJob(d, j, K(c).keyId, body?.message));
    }),
  ];

  async function uploadOutput(c: Ctx): Promise<void> {
    const k = K(c);
    const j = dom.getJobFor(d, c.params.id, k.keyId, k.photographerId);
    c.fields.objectId = j.object_id;
    dom.assertJobAcceptsOutput(d, j, k.keyId); // avvisa ersatta jobb innan kroppen läses
    if (!/^video\/mp4\b/i.test(String(c.req.headers["content-type"] ?? ""))) throw new ApiError(415, "unsupported_media_type", "Bara video/mp4 tillåts.");
    const max = cfg.limits.mp4Bytes;
    const len = declaredLength(c.req);
    if (len !== null && (Number.isNaN(len) || len > max)) throw tooLarge(max, "Filmen");
    const tmp = store.newTmp();
    const ws = createWriteStream(tmp);
    const hash = createHash("sha256");
    let n = 0;
    try {
      for await (const chunk of c.req) {
        n += (chunk as Buffer).length;
        if (n > max) throw tooLarge(max, "Filmen");
        hash.update(chunk as Buffer);
        if (!ws.write(chunk)) await once(ws, "drain");
      }
      ws.end();
      await finished(ws);
      if (n === 0) throw new ApiError(422, "empty_body", "Filmen är tom.");
      if (!dom.mp4Head(tmp)) throw new ApiError(415, "bad_mp4", "Filen är inte en MP4.");
    } catch (e) {
      ws.destroy();
      rmSync(tmp, { force: true });
      throw e;
    }
    counters.uploadsBytes += n;
    const q = c.url.searchParams;
    const dims = { width: Number(q.get("width")) || undefined, height: Number(q.get("height")) || undefined, duration: Number(q.get("duration")) || undefined };
    const r = dom.completeJob(d, j, k.keyId, tmp, hash.digest("hex"), n, dims);
    sendJson(c.res, 201, { renderId: r.renderId, status: r.status });
  }

  // ---------------------------------------------------------------- dispatch

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const t0 = process.hrtime.bigint();
    securityHeaders(res);
    const url = new URL(req.url ?? "/", "http://x");
    const method = req.method ?? "GET";
    const c: Ctx = { req, res, url, params: {}, fields: {} };
    let label = "unmatched";
    try {
      if (url.pathname !== "/healthz") limit("global", cfg.rate.globalPerMinute, 60_000);
      if (url.pathname === "/m/" || url.pathname === "/a/") { res.writeHead(308, { Location: url.pathname.slice(0, 2) }); return void res.end(); }
      const m = matchRoute(routes, method, url.pathname);
      if (!m.route) throw m.pathMatched ? new ApiError(405, "method_not_allowed", "Metoden stöds inte här.") : new ApiError(404, "not_found", "Sidan finns inte.");
      label = m.route.pattern;
      c.params = m.params;
      await authenticate(c, m.route.auth);
      await m.route.handler(c);
    } catch (e) {
      if (!res.headersSent) {
        if (e instanceof ApiError) sendError(res, e);
        else {
          log("error", "Internt fel", { route: label, err: e instanceof Error ? e.message : String(e) });
          sendJson(res, 500, { error: { code: "internal", message: "Något gick fel hos servern." } });
        }
      } else res.destroy();
    } finally {
      const ms = Number((process.hrtime.bigint() - t0) / 1_000_000n);
      counters.countRequest(label, res.statusCode);
      if (label !== "/healthz") log("info", "req", { route: label, method, status: res.statusCode, ms, ...c.fields });
    }
  }

  const server = createServer((req, res) => { void handle(req, res); });
  server.requestTimeout = 0; // långa MP4-uppladdningar; stora anrop begränsas av storleksgränsen
  server.headersTimeout = 20_000;
  server.keepAliveTimeout = 5_000;

  const metricsServer = createServer((req, res) => {
    if (req.url === "/metrics" && req.method === "GET") {
      sendText(res, 200, renderMetrics(db, counters, d.now()), "text/plain; version=0.0.4; charset=utf-8");
    } else sendText(res, 404, "inte hittad\n");
  });

  const listen = (s: Server, port: number, host: string): Promise<number> => new Promise((resolve, reject) => {
    s.once("error", reject);
    s.listen(port, host, () => { s.off("error", reject); resolve((s.address() as AddressInfo).port); });
  });

  return {
    d, server, metricsServer, limiter, baseUrl,
    async start() {
      listenPort = await listen(server, cfg.port, cfg.host);
      const metricsPort = await listen(metricsServer, cfg.metricsPort, cfg.metricsHost);
      return { port: listenPort, metricsPort };
    },
    async stop() {
      server.closeAllConnections();
      metricsServer.closeAllConnections();
      await Promise.all([server, metricsServer].map((s) => new Promise<void>((r) => (s.listening ? s.close(() => r()) : r()))));
      if (!existingDb) db.close();
    },
  };
}
