// Domänlogik: objekt, pool, specrevisioner, länkar, godkännande, renderkö och gallring.
// Allt är synkront mot SQLite; skrivningar går i BEGIN IMMEDIATE-transaktioner.

import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { rmSync, openSync, readSync, closeSync } from "node:fs";
import type { Config } from "./config.ts";
import type { Counters } from "./metrics.ts";
import { type Db, tx } from "./db.ts";
import { ApiError } from "./errors.ts";
import { BlobStore, VARIANTS, type Variant } from "./store.ts";
import { canonicalJson, hashSecret, newToken, sha256hex, signedMediaPath } from "./crypto.ts";
import { inspectJpeg, JpegError } from "./jpeg.ts";
import { parseReelSpec, ReelSpecError, CURRENT_VERSION } from "../../web/reel/src/reelSpec.ts";
import type { ReelSpec } from "../../web/reel/src/reelSpec.ts";
import { totalDuration } from "../../web/reel/src/reelTimeline.ts";

export type Status = "draft" | "proposed" | "approved" | "rendered";
export type Role = "photographer" | "agent";

export interface Deps {
  db: Db;
  cfg: Config;
  store: BlobStore;
  counters: Counters;
  bus: EventEmitter;
  baseUrl(): string;
  now(): number;
}

export interface Actor { role: Role; ref: string; name?: string }

export interface ObjectRow {
  id: string; photographer_id: string; reel_id: string; address: string; session_id: string | null; kind: string | null;
  status: Status; current_revision: number; approved_revision: number | null;
  created_at: string; updated_at: string; purge_after: string; deleted_at: string | null;
}
export interface PoolRow {
  object_id: string; asset_id: string; sha256: string; width: number; height: number; analysis_json: string | null; sort: number;
}
interface RevRow { object_id: string; revision: number; spec_json: string; content_hash: string; author_role: string; author_ref: string | null; created_at: string }
export interface JobRow {
  id: string; object_id: string; revision: number; output_id: string; status: string; worker_id: string | null;
  lease_until: string | null; attempts: number; error: string | null; created_at: string; finished_at: string | null;
}
export interface RenderRow {
  id: string; object_id: string; revision: number; output_id: string; sha256: string; bytes: number;
  width: number | null; height: number | null; duration: number | null; created_at: string;
}

const SHA_RE = /^[0-9a-f]{64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const isSha = (s: unknown): s is string => typeof s === "string" && SHA_RE.test(s);
export const isUuid = (s: unknown): s is string => typeof s === "string" && UUID_RE.test(s);

export const iso = (d: Deps, ms = d.now()): string => new Date(ms).toISOString();
const addDays = (d: Deps, days: number): string => iso(d, d.now() + days * 86400_000);
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

// ------------------------------------------------------------------ hjälpare

export function addEvent(d: Deps, objectId: string, actor: { role: string; ref?: string }, type: string, data?: unknown): void {
  d.db.prepare("INSERT INTO events(object_id, at, actor_role, actor_ref, type, data_json) VALUES (?,?,?,?,?,?)")
    .run(objectId, iso(d), actor.role, actor.ref ?? null, type, data === undefined ? null : JSON.stringify(data));
}

/** Skrivande aktivitet skjuter fram gallringsdatumet. */
function touch(d: Deps, objectId: string): void {
  d.db.prepare("UPDATE objects SET updated_at = ?, purge_after = ? WHERE id = ?").run(iso(d), addDays(d, d.cfg.purgeDays), objectId);
}

function setStatus(d: Deps, o: ObjectRow, to: Status, actor: { role: string; ref?: string }): void {
  if (o.status === to) return;
  d.db.prepare("UPDATE objects SET status = ? WHERE id = ?").run(to, o.id);
  addEvent(d, o.id, actor, "status", { from: o.status, to });
  o.status = to;
}

export function getObject(d: Deps, id: string): ObjectRow | undefined {
  if (!isUuid(id)) return undefined;
  return d.db.prepare("SELECT * FROM objects WHERE id = ?").get(id) as ObjectRow | undefined;
}

export function getOwnedObject(d: Deps, id: string, photographerId: string): ObjectRow {
  const o = getObject(d, id);
  if (!o || o.photographer_id !== photographerId) throw new ApiError(404, "not_found", "Objektet finns inte.");
  return o;
}

function getRev(d: Deps, objectId: string, revision: number): RevRow | undefined {
  return d.db.prepare("SELECT * FROM spec_revisions WHERE object_id = ? AND revision = ?").get(objectId, revision) as RevRow | undefined;
}

export function poolOf(d: Deps, objectId: string): PoolRow[] {
  return d.db.prepare("SELECT * FROM object_assets WHERE object_id = ? ORDER BY sort").all(objectId) as unknown as PoolRow[];
}

/** Den lagrade (kanoniska, `store`) specen för en revision med objektets status inskriven. */
export function storedSpec(d: Deps, o: ObjectRow, revision = o.current_revision): ReelSpec | null {
  const r = getRev(d, o.id, revision);
  if (!r) return null;
  const spec = JSON.parse(r.spec_json) as ReelSpec;
  spec.status = revision === o.current_revision ? o.status : "superseded";
  return spec;
}

// ------------------------------------------------------------------ objekt

export function upsertObject(d: Deps, photographerId: string, reelId: string, body: unknown): { object: ObjectRow; created: boolean } {
  if (!/^[A-Za-z0-9-]{8,64}$/.test(reelId)) throw new ApiError(422, "bad_reel_id", "Ogiltigt reel-id.");
  if (!isObj(body)) throw new ApiError(422, "bad_body", "Kroppen måste vara ett JSON-objekt.");
  const address = body.address;
  if (typeof address !== "string" || address.trim() === "" || address.length > 200) throw new ApiError(422, "bad_address", "Adressen saknas eller är för lång (högst 200 tecken).");
  const sessionId = typeof body.sessionID === "string" ? body.sessionID.slice(0, 100) : null;
  const kind = typeof body.kind === "string" ? body.kind.slice(0, 40) : null;
  return tx(d.db, () => {
    const ex = d.db.prepare("SELECT * FROM objects WHERE reel_id = ?").get(reelId) as ObjectRow | undefined;
    if (ex) {
      if (ex.photographer_id !== photographerId) throw new ApiError(409, "reel_taken", "Reel-id används redan.");
      d.db.prepare("UPDATE objects SET address = ?, session_id = ?, kind = ? WHERE id = ?").run(address.trim(), sessionId, kind, ex.id);
      touch(d, ex.id);
      return { object: getObject(d, ex.id)!, created: false };
    }
    const id = randomUUID();
    const now = iso(d);
    d.db.prepare("INSERT INTO objects(id, photographer_id, reel_id, address, session_id, kind, status, current_revision, created_at, updated_at, purge_after) VALUES (?,?,?,?,?,?, 'draft', 0, ?,?,?)")
      .run(id, photographerId, reelId, address.trim(), sessionId, kind, now, now, addDays(d, d.cfg.purgeDays));
    addEvent(d, id, { role: "photographer" }, "created");
    return { object: getObject(d, id)!, created: true };
  });
}

export function listObjects(d: Deps, photographerId: string, status?: string, since?: string): Record<string, unknown>[] {
  if (status && !["draft", "proposed", "approved", "rendered"].includes(status)) throw new ApiError(422, "bad_status", "Okänd status.");
  if (since && Number.isNaN(Date.parse(since))) throw new ApiError(422, "bad_since", "since måste vara ett ISO-datum.");
  const rows = d.db.prepare(
    `SELECT o.*, (SELECT COUNT(*) FROM renders r WHERE r.object_id = o.id) AS render_count
       FROM objects o WHERE o.photographer_id = ? AND (? IS NULL OR o.status = ?) AND (? IS NULL OR o.updated_at > ?)
      ORDER BY o.updated_at DESC`).all(photographerId, status ?? null, status ?? null, since ?? null, since ?? null) as unknown as (ObjectRow & { render_count: number })[];
  return rows.map((o) => ({
    objectId: o.id, reelId: o.reel_id, address: o.address, status: o.status,
    currentRevision: o.current_revision, approvedRevision: o.approved_revision,
    updatedAt: o.updated_at, purgeAfter: o.purge_after, renderCount: o.render_count,
  }));
}

// ------------------------------------------------------------------ bilder

export function checkAssets(d: Deps, shas: unknown): string[] {
  if (!Array.isArray(shas) || shas.length > 500 || !shas.every(isSha)) throw new ApiError(422, "bad_sha", "sha256 måste vara en lista med högst 500 hex-strängar (64 tecken).");
  const have = d.db.prepare("SELECT COUNT(*) AS n FROM blobs WHERE sha256_orig = ?");
  return [...new Set(shas as string[])].filter((s) => (have.get(s) as { n: number }).n < VARIANTS.length);
}

const MAX_LONG_SIDE: Record<Variant, number> = { w1600: 2000, w480: 700 };

export function putVariant(d: Deps, sha: string, variant: string, data: Uint8Array): Record<string, unknown> {
  if (!isSha(sha)) throw new ApiError(422, "bad_sha", "Ogiltig sha256.");
  if (!(VARIANTS as readonly string[]).includes(variant)) throw new ApiError(422, "bad_variant", "Okänd variant (w1600 eller w480).");
  const v = variant as Variant;
  let info;
  try { info = inspectJpeg(data); } catch (e) {
    if (e instanceof JpegError) throw new ApiError(415, "bad_image", e.message);
    throw e;
  }
  if (info.hasGps) throw new ApiError(422, "gps_in_image", "Bilden innehåller GPS-data. Ta bort EXIF innan uppladdning.");
  if (Math.max(info.width, info.height) > MAX_LONG_SIDE[v]) throw new ApiError(422, "image_too_large", `Bilden är för stor för varianten ${v} (längsta sidan högst ${MAX_LONG_SIDE[v]} px).`);
  const vsha = sha256hex(data);
  d.store.putImage(sha, v, data);
  d.db.prepare(`INSERT INTO blobs(sha256_orig, variant, variant_sha256, bytes, width, height, created_at) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(sha256_orig, variant) DO UPDATE SET variant_sha256 = excluded.variant_sha256, bytes = excluded.bytes, width = excluded.width, height = excluded.height, created_at = excluded.created_at`)
    .run(sha, v, vsha, data.length, info.width, info.height, iso(d));
  d.counters.uploadsBytes += data.length;
  return { sha256: sha, variant: v, variantSha256: vsha, bytes: data.length, width: info.width, height: info.height };
}

export function setPool(d: Deps, o: ObjectRow, body: unknown): { count: number } {
  const list = isObj(body) ? body.assets : undefined;
  if (!Array.isArray(list)) throw new ApiError(422, "bad_body", "Kroppen måste vara {assets: [...]}.");
  if (list.length > d.cfg.limits.maxAssets) throw new ApiError(422, "too_many_assets", `Högst ${d.cfg.limits.maxAssets} bilder per objekt.`);
  const seenSha = new Set<string>();
  const seenId = new Set<string>();
  const rows = list.map((a, i) => {
    if (!isObj(a)) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: måste vara ett objekt.`);
    const id = a.assetId ?? a.id;
    if (typeof id !== "string" || !/^[\w.-]{1,64}$/.test(id)) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: assetId saknas eller är ogiltigt.`);
    if (!isSha(a.sha256)) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: sha256 måste vara 64 hex-tecken.`);
    const w = a.width, h = a.height;
    if (!Number.isInteger(w) || !Number.isInteger(h) || (w as number) < 1 || (h as number) < 1 || (w as number) > 100000 || (h as number) > 100000) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: width och height måste vara heltal.`);
    if (seenSha.has(a.sha256) || seenId.has(id)) throw new ApiError(422, "duplicate_asset", `Bild ${i + 1}: dubblett av id eller sha256.`);
    seenSha.add(a.sha256); seenId.add(id);
    let analysis: string | null = null;
    if (a.analysis !== undefined && a.analysis !== null) {
      if (!isObj(a.analysis)) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: analysis måste vara ett objekt.`);
      analysis = JSON.stringify(a.analysis);
      if (analysis.length > 2000) throw new ApiError(422, "bad_asset", `Bild ${i + 1}: analysis är för stor.`);
    }
    return { id, sha: a.sha256, w: w as number, h: h as number, analysis, sort: i };
  });
  return tx(d.db, () => {
    d.db.prepare("DELETE FROM object_assets WHERE object_id = ?").run(o.id);
    const ins = d.db.prepare("INSERT INTO object_assets(object_id, asset_id, sha256, width, height, analysis_json, sort) VALUES (?,?,?,?,?,?,?)");
    for (const r of rows) ins.run(o.id, r.id, r.sha, r.w, r.h, r.analysis, r.sort);
    touch(d, o.id);
    addEvent(d, o.id, { role: "photographer" }, "pool_set", { count: rows.length });
    return { count: rows.length };
  });
}

// ------------------------------------------------------------------ spec

const SERVER_FIELDS = ["revision", "updatedAt", "updatedBy", "status"];

function contentHash(spec: ReelSpec): string {
  const c: Record<string, unknown> = { ...spec };
  for (const k of SERVER_FIELDS) delete c[k];
  return sha256hex(canonicalJson(c));
}

/** Validerar och kanoniserar en inkommande spec. Kastar ApiError(422) med svenskt meddelande. */
function canonicalize(d: Deps, o: ObjectRow, input: unknown, actor: Actor, prev: ReelSpec | null): ReelSpec {
  let spec: ReelSpec;
  try { spec = parseReelSpec(structuredClone(input)); } catch (e) {
    if (e instanceof ReelSpecError) throw new ApiError(422, "invalid_spec", e.message);
    throw e;
  }
  const bad = (m: string) => new ApiError(422, "invalid_spec", m);
  if (spec.id !== o.reel_id) throw bad("Specens id stämmer inte med objektet.");
  if (spec.version > CURRENT_VERSION || spec.minReaderVersion > CURRENT_VERSION) throw bad("Specens version stöds inte.");
  if (spec.timeline.length < 1) throw bad("Filmen måste ha minst ett klipp.");
  if (spec.timeline.length > d.cfg.limits.maxClips) throw bad(`Högst ${d.cfg.limits.maxClips} klipp i en film.`);
  if (spec.assets.length > d.cfg.limits.maxAssets) throw bad(`Högst ${d.cfg.limits.maxAssets} bilder per objekt.`);
  for (const [i, c] of spec.timeline.entries()) {
    if (c.duration < 0.5 || c.duration > 10) throw bad(`Klipp ${i + 1}: längden måste vara mellan 0,5 och 10 sekunder.`);
  }
  if (spec.outputs.length > 4) throw bad("Högst 4 utbildsprofiler.");
  for (const out of spec.outputs) {
    if (out.width > 4096 || out.height > 4096 || out.fps > 60 || out.fps < 1) throw bad("Utbildsprofilen är utanför tillåtna gränser (högst 4096 px och 60 bilder/s).");
    if (typeof out.id !== "string" || !/^[\w.-]{1,40}$/.test(out.id)) throw bad("Utbildsprofilen saknar giltigt id.");
  }
  if (new Set(spec.outputs.map((x) => x.id)).size !== spec.outputs.length) throw bad("Utbildsprofilernas id måste vara unika.");
  if (actor.role === "agent" && prev && canonicalJson(prev.outputs) !== canonicalJson(spec.outputs)) throw bad("Mäklaren får inte ändra utbildsprofilerna.");

  const pool = new Map(poolOf(d, o.id).map((p) => [p.sha256, p]));
  for (const a of spec.assets) {
    const p = pool.get(a.sha256);
    if (!p) throw bad(`Bilden "${a.id}" finns inte i objektets bildpool.`);
    a.width = p.width; a.height = p.height; // poolen är auktoritativ för måtten
    a.sources = [{ kind: "store", key: `img/${a.sha256}` }];
  }
  // Servern äger objektets egenskaper och styr revision/status.
  spec.property = { address: o.address, ...(o.session_id ? { sessionID: o.session_id } : {}), ...(o.kind ? { kind: o.kind } : {}) };
  spec.schema = "photoflow.reel";
  spec.id = o.reel_id;
  const name = isObj(input) && isObj((input as Record<string, unknown>).updatedBy) && typeof ((input as Record<string, Record<string, unknown>>).updatedBy.name) === "string"
    ? String((input as Record<string, Record<string, unknown>>).updatedBy.name).slice(0, 80) : undefined;
  spec.updatedBy = name ? { role: actor.role, name } : { role: actor.role };
  if (typeof spec.createdAt !== "string" || Number.isNaN(Date.parse(spec.createdAt))) spec.createdAt = prev?.createdAt ?? iso(d);
  return spec;
}

export interface SaveResult { spec: ReelSpec; revision: number; changed: boolean }

export function parseIfMatch(h: string | undefined): number | null {
  if (h === undefined) return null;
  const m = /^\s*(?:W\/)?"?(\d{1,9})"?\s*$/.exec(h);
  return m ? Number(m[1]) : NaN;
}

/** Sparar en spec som ny revision. Idempotent på innehåll; 412 vid krock. */
export function saveSpec(d: Deps, objectId: string, input: unknown, ifMatch: number | null, actor: Actor): SaveResult {
  if (ifMatch === null) throw new ApiError(428, "precondition_required", "If-Match saknas (skicka den revision du utgick från, t.ex. If-Match: \"3\").");
  if (Number.isNaN(ifMatch)) throw new ApiError(400, "bad_if_match", "If-Match måste vara ett revisionsnummer i citattecken.");
  return tx(d.db, () => {
    const o = getObject(d, objectId)!;
    const prev = o.current_revision > 0 ? (JSON.parse(getRev(d, o.id, o.current_revision)!.spec_json) as ReelSpec) : null;
    const spec = canonicalize(d, o, input, actor, prev);
    const hash = contentHash(spec);
    const cur = o.current_revision > 0 ? getRev(d, o.id, o.current_revision) : undefined;
    if (cur && cur.content_hash === hash) {
      return { spec: storedSpec(d, o)!, revision: o.current_revision, changed: false };
    }
    if (ifMatch !== o.current_revision) {
      throw new ApiError(412, "revision_conflict", "Specen har ändrats av någon annan. Hämta den senaste versionen.",
        { currentRevision: o.current_revision, spec: storedSpec(d, o) }, { ETag: `"${o.current_revision}"` });
    }
    const rev = o.current_revision + 1;
    spec.revision = rev;
    spec.updatedAt = iso(d);
    spec.status = "draft"; // speglar objektets status vid läsning; lagras inte
    d.db.prepare("INSERT INTO spec_revisions(object_id, revision, spec_json, content_hash, author_role, author_ref, created_at) VALUES (?,?,?,?,?,?,?)")
      .run(o.id, rev, JSON.stringify(spec), hash, actor.role, actor.ref, iso(d));
    d.db.prepare("UPDATE objects SET current_revision = ? WHERE id = ?").run(rev, o.id);
    o.current_revision = rev;
    // En ändring gör tidigare köade/pågående renderjobb obsoleta och tar tillbaka objektet till "proposed".
    supersedeJobs(d, o.id);
    if (o.status === "approved" || o.status === "rendered") setStatus(d, o, "proposed", actor);
    addEvent(d, o.id, actor, "spec_saved", { revision: rev });
    touch(d, o.id);
    return { spec: storedSpec(d, o)!, revision: rev, changed: true };
  });
}

function supersedeJobs(d: Deps, objectId: string): void {
  d.db.prepare("UPDATE render_jobs SET status = 'superseded', finished_at = ? WHERE object_id = ? AND status IN ('queued','claimed')").run(iso(d), objectId);
}

// ------------------------------------------------------------------ godkännande

export function approve(d: Deps, objectId: string, revision: unknown, actor: Actor): { status: Status; revision: number; changed: boolean; jobs: number } {
  if (!Number.isInteger(revision)) throw new ApiError(422, "bad_revision", "revision måste vara ett heltal.");
  return tx(d.db, () => {
    const o = getObject(d, objectId)!;
    if (o.current_revision === 0) throw new ApiError(409, "no_spec", "Det finns ingen film att godkänna ännu.");
    if (revision !== o.current_revision) {
      throw new ApiError(409, "revision_mismatch", "Filmen har ändrats sedan du såg den. Ladda om och godkänn igen.", { currentRevision: o.current_revision });
    }
    if ((o.status === "approved" || o.status === "rendered") && o.approved_revision === revision) {
      return { status: o.status, revision: revision as number, changed: false, jobs: 0 };
    }
    const spec = JSON.parse(getRev(d, o.id, o.current_revision)!.spec_json) as ReelSpec;
    supersedeJobs(d, o.id);
    const ins = d.db.prepare("INSERT INTO render_jobs(id, object_id, revision, output_id, status, created_at) VALUES (?,?,?,?, 'queued', ?)");
    for (const out of spec.outputs) ins.run(randomUUID(), o.id, o.current_revision, out.id, iso(d));
    d.db.prepare("UPDATE objects SET approved_revision = ? WHERE id = ?").run(revision, o.id);
    setStatus(d, o, "approved", actor);
    addEvent(d, o.id, actor, "approved", { revision });
    touch(d, o.id);
    d.bus.emit("job");
    return { status: o.status, revision: revision as number, changed: true, jobs: spec.outputs.length };
  });
}

// ------------------------------------------------------------------ länkar

export interface LinkRow { id: string; object_id: string; token_hash: string; label: string | null; created_at: string; expires_at: string; revoked_at: string | null; last_used_at: string | null }

export function createLink(d: Deps, o: ObjectRow, body: unknown, actor: Actor): Record<string, unknown> {
  const b = isObj(body) ? body : {};
  const days = b.expiresInDays === undefined ? d.cfg.linkDefaultDays : b.expiresInDays;
  if (typeof days !== "number" || !Number.isFinite(days) || days <= 0 || days > d.cfg.linkMaxDays) throw new ApiError(422, "bad_expiry", `expiresInDays måste vara mellan 0 och ${d.cfg.linkMaxDays}.`);
  const label = typeof b.label === "string" ? b.label.trim().slice(0, 80) || null : null;
  return tx(d.db, () => {
    const cur = getObject(d, o.id)!;
    if (cur.current_revision === 0) throw new ApiError(409, "no_spec", "Skicka en spec innan du skapar en länk.");
    const token = newToken();
    const id = randomUUID();
    const expires = iso(d, d.now() + days * 86400_000);
    d.db.prepare("INSERT INTO links(id, object_id, token_hash, label, created_at, expires_at) VALUES (?,?,?,?,?,?)").run(id, o.id, hashSecret(token), label, iso(d), expires);
    addEvent(d, o.id, actor, "link_created", { linkId: id });
    if (cur.status === "draft") setStatus(d, cur, "proposed", actor);
    touch(d, o.id);
    const base = d.baseUrl();
    return { linkId: id, url: `${base}/m#${token}`, archiveUrl: `${base}/a#${token}`, expiresAt: expires, status: cur.status };
  });
}

export function revokeLink(d: Deps, linkId: string, photographerId: string, actor: Actor): void {
  const l = isUuid(linkId) ? (d.db.prepare("SELECT l.*, o.photographer_id AS pid FROM links l JOIN objects o ON o.id = l.object_id WHERE l.id = ?").get(linkId) as (LinkRow & { pid: string }) | undefined) : undefined;
  if (!l || l.pid !== photographerId) throw new ApiError(404, "not_found", "Länken finns inte.");
  if (!l.revoked_at) {
    d.db.prepare("UPDATE links SET revoked_at = ? WHERE id = ?").run(iso(d), l.id);
    addEvent(d, l.object_id, actor, "link_revoked", { linkId: l.id });
  }
}

export function linksOf(d: Deps, objectId: string): Record<string, unknown>[] {
  return (d.db.prepare("SELECT * FROM links WHERE object_id = ? ORDER BY created_at").all(objectId) as unknown as LinkRow[]).map((l) => ({
    linkId: l.id, label: l.label, createdAt: l.created_at, expiresAt: l.expires_at, revokedAt: l.revoked_at, lastUsedAt: l.last_used_at,
  }));
}

// ------------------------------------------------------------------ vyer

export function mediaUrl(d: Deps, key: string): string {
  return signedMediaPath(d.cfg.signingKey, key, Math.floor(d.now() / 1000) + d.cfg.mediaTtlSeconds);
}

export function rendersOf(d: Deps, o: ObjectRow): Record<string, unknown>[] {
  const rows = d.db.prepare("SELECT * FROM renders WHERE object_id = ? ORDER BY created_at DESC").all(o.id) as unknown as RenderRow[];
  return rows.map((r) => ({
    renderId: r.id, revision: r.revision, outputId: r.output_id, bytes: r.bytes, sha256: r.sha256,
    width: r.width, height: r.height, duration: r.duration, createdAt: r.created_at,
    current: o.approved_revision === r.revision && o.status === "rendered",
    url: mediaUrl(d, `render/${r.id}`),
  }));
}

export function poolView(d: Deps, o: ObjectRow): Record<string, unknown>[] {
  const have = new Set((d.db.prepare("SELECT sha256_orig AS s, variant AS v FROM blobs").all() as { s: string; v: string }[]).map((r) => `${r.s}/${r.v}`));
  return poolOf(d, o.id).map((p) => ({
    assetId: p.asset_id, sha256: p.sha256, width: p.width, height: p.height,
    analysis: p.analysis_json ? JSON.parse(p.analysis_json) : null,
    url: have.has(`${p.sha256}/w1600`) ? mediaUrl(d, `img/${p.sha256}/w1600`) : null,
    thumbUrl: have.has(`${p.sha256}/w480`) ? mediaUrl(d, `img/${p.sha256}/w480`) : null,
  }));
}

/** Specen som webben får: `store` blir signerade URL:er och poolbilder som saknas i specen läggs till. */
export function webSpec(d: Deps, o: ObjectRow): ReelSpec | null {
  const spec = storedSpec(d, o);
  if (!spec) return null;
  const known = new Set(spec.assets.map((a) => a.sha256));
  for (const p of poolOf(d, o.id)) {
    if (known.has(p.sha256)) continue;
    spec.assets.push({ id: p.asset_id, sha256: p.sha256, width: p.width, height: p.height, sources: [], ...(p.analysis_json ? { analysis: JSON.parse(p.analysis_json) } : {}) });
  }
  const have = new Set((d.db.prepare("SELECT sha256_orig AS s FROM blobs WHERE variant = 'w1600'").all() as { s: string }[]).map((r) => r.s));
  for (const a of spec.assets) a.sources = have.has(a.sha256) ? [{ kind: "url", url: mediaUrl(d, `img/${a.sha256}/w1600`) }] : [];
  return spec;
}

export function objectDetail(d: Deps, o: ObjectRow): Record<string, unknown> {
  const jobs = d.db.prepare("SELECT id, revision, output_id, status, attempts, error, created_at, finished_at FROM render_jobs WHERE object_id = ? ORDER BY created_at DESC LIMIT 20").all(o.id) as Record<string, unknown>[];
  return {
    objectId: o.id, reelId: o.reel_id, address: o.address, sessionID: o.session_id, kind: o.kind, status: o.status,
    currentRevision: o.current_revision, approvedRevision: o.approved_revision,
    createdAt: o.created_at, updatedAt: o.updated_at, purgeAfter: o.purge_after,
    spec: storedSpec(d, o), pool: poolOf(d, o.id).map((p) => ({
      assetId: p.asset_id, sha256: p.sha256, width: p.width, height: p.height, analysis: p.analysis_json ? JSON.parse(p.analysis_json) : null,
    })),
    links: linksOf(d, o.id), renders: rendersOf(d, o),
    jobs: jobs.map((j) => ({ jobId: j.id, revision: j.revision, outputId: j.output_id, status: j.status, attempts: j.attempts, error: j.error, createdAt: j.created_at, finishedAt: j.finished_at })),
  };
}

export function shareView(d: Deps, o: ObjectRow, link: LinkRow): Record<string, unknown> {
  const appr = d.db.prepare("SELECT actor_role, at FROM events WHERE object_id = ? AND type = 'approved' ORDER BY id DESC LIMIT 1").get(o.id) as { actor_role: string; at: string } | undefined;
  return {
    object: { address: o.address, status: o.status, currentRevision: o.current_revision, approvedRevision: o.approved_revision, updatedAt: o.updated_at },
    link: { expiresAt: link.expires_at, label: link.label },
    approval: appr && o.approved_revision !== null && (o.status === "approved" || o.status === "rendered") ? { by: appr.actor_role, at: appr.at } : null,
    spec: webSpec(d, o),
    pool: poolView(d, o),
    renders: rendersOf(d, o),
  };
}

// ------------------------------------------------------------------ renderkö

export function touchWorker(d: Deps, keyId: string, label: string | null): void {
  d.db.prepare("INSERT INTO workers(id, label, last_seen_at) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at, label = excluded.label").run(keyId, label, iso(d));
}

export function tryClaim(d: Deps, keyId: string, photographerId: string): Record<string, unknown> | null {
  return tx(d.db, () => {
    const now = iso(d);
    // Utgångna lease: tillbaka i kön, eller misslyckade efter för många försök.
    d.db.prepare("UPDATE render_jobs SET status = 'failed', error = 'Leasen gick ut efter flera försök.', finished_at = ? WHERE status = 'claimed' AND lease_until < ? AND attempts >= ?").run(now, now, d.cfg.maxAttempts);
    d.db.prepare("UPDATE render_jobs SET status = 'queued', worker_id = NULL, lease_until = NULL WHERE status = 'claimed' AND lease_until < ?").run(now);
    const job = d.db.prepare(
      `SELECT j.* FROM render_jobs j JOIN objects o ON o.id = j.object_id
        WHERE j.status = 'queued' AND o.photographer_id = ? AND o.status = 'approved' AND j.revision = o.approved_revision
        ORDER BY j.created_at, j.rowid LIMIT 1`).get(photographerId) as JobRow | undefined;
    if (!job) return null;
    const lease = iso(d, d.now() + d.cfg.leaseSeconds * 1000);
    d.db.prepare("UPDATE render_jobs SET status = 'claimed', worker_id = ?, lease_until = ?, attempts = attempts + 1 WHERE id = ?").run(keyId, lease, job.id);
    const o = getObject(d, job.object_id)!;
    const spec = JSON.parse(getRev(d, o.id, job.revision)!.spec_json) as ReelSpec;
    spec.status = "approved";
    addEvent(d, o.id, { role: "render", ref: keyId }, "job_claimed", { jobId: job.id, attempt: job.attempts + 1 });
    return { jobId: job.id, objectId: o.id, reelId: o.reel_id, revision: job.revision, outputId: job.output_id, spec, leaseUntil: lease };
  });
}

export function getJobFor(d: Deps, jobId: string, keyId: string, photographerId: string): JobRow {
  const j = isUuid(jobId) ? (d.db.prepare("SELECT j.*, o.photographer_id AS pid FROM render_jobs j JOIN objects o ON o.id = j.object_id WHERE j.id = ?").get(jobId) as (JobRow & { pid: string }) | undefined) : undefined;
  if (!j || j.pid !== photographerId) throw new ApiError(404, "not_found", "Jobbet finns inte.");
  return j;
}

function requireActiveJob(d: Deps, j: JobRow, keyId: string): void {
  if (j.status === "superseded") throw new ApiError(409, "superseded", "Filmen har ändrats efter godkännandet. Jobbet är ersatt och ska avbrytas.");
  if (j.status !== "claimed" || j.worker_id !== keyId) throw new ApiError(409, "not_claimed", `Jobbet är inte hämtat av dig (status ${j.status}).`);
}

export function heartbeat(d: Deps, j: JobRow, keyId: string): string {
  return tx(d.db, () => {
    const cur = d.db.prepare("SELECT * FROM render_jobs WHERE id = ?").get(j.id) as unknown as JobRow;
    requireActiveJob(d, cur, keyId);
    const lease = iso(d, d.now() + d.cfg.leaseSeconds * 1000);
    d.db.prepare("UPDATE render_jobs SET lease_until = ? WHERE id = ?").run(lease, j.id);
    return lease;
  });
}

export function failJob(d: Deps, j: JobRow, keyId: string, message: unknown): { status: string } {
  const msg = typeof message === "string" ? message.slice(0, 500) : "okänt fel";
  return tx(d.db, () => {
    const cur = d.db.prepare("SELECT * FROM render_jobs WHERE id = ?").get(j.id) as unknown as JobRow;
    requireActiveJob(d, cur, keyId);
    const status = cur.attempts >= d.cfg.maxAttempts ? "failed" : "queued";
    d.db.prepare("UPDATE render_jobs SET status = ?, error = ?, worker_id = NULL, lease_until = NULL, finished_at = ? WHERE id = ?")
      .run(status, msg, status === "failed" ? iso(d) : null, j.id);
    addEvent(d, cur.object_id, { role: "render", ref: keyId }, status === "failed" ? "job_failed" : "job_retry", { jobId: j.id, attempts: cur.attempts });
    if (status === "queued") d.bus.emit("job");
    return { status };
  });
}

/** Kontroll före uppladdning (så att en ersatt render kan avvisas utan att läsa kroppen). */
export function assertJobAcceptsOutput(d: Deps, j: JobRow, keyId: string): void {
  const cur = d.db.prepare("SELECT * FROM render_jobs WHERE id = ?").get(j.id) as unknown as JobRow;
  requireActiveJob(d, cur, keyId);
  const o = getObject(d, cur.object_id)!;
  if (o.status !== "approved" || o.approved_revision !== cur.revision) throw new ApiError(409, "superseded", "Filmen har ändrats efter godkännandet. Jobbet är ersatt.");
}

export function mp4Head(path: string): boolean {
  const fd = openSync(path, "r");
  try {
    const b = Buffer.alloc(12);
    const n = readSync(fd, b, 0, 12, 0);
    return n >= 12 && b.toString("latin1", 4, 8) === "ftyp";
  } finally { closeSync(fd); }
}

/** Registrerar en färdig MP4 (redan på disk i tmp) för jobbet. Returnerar render-id eller kastar 409 om jobbet blivit ersatt. */
export function completeJob(d: Deps, j: JobRow, keyId: string, tmpPath: string, sha: string, bytes: number, dims: { width?: number; height?: number; duration?: number }): { renderId: string; status: Status } {
  try {
    const r = tx(d.db, () => {
      assertJobAcceptsOutput(d, j, keyId);
      const o = getObject(d, j.object_id)!;
      const spec = JSON.parse(getRev(d, o.id, j.revision)!.spec_json) as ReelSpec;
      const out = spec.outputs.find((x) => x.id === j.output_id);
      const id = randomUUID();
      d.db.prepare("INSERT INTO renders(id, object_id, revision, output_id, sha256, bytes, width, height, duration, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)")
        .run(id, o.id, j.revision, j.output_id, sha, bytes, dims.width ?? out?.width ?? null, dims.height ?? out?.height ?? null, dims.duration ?? Math.round(totalDuration(spec) * 100) / 100, iso(d));
      d.db.prepare("UPDATE render_jobs SET status = 'done', lease_until = NULL, finished_at = ? WHERE id = ?").run(iso(d), j.id);
      addEvent(d, o.id, { role: "render", ref: keyId }, "render_uploaded", { renderId: id, revision: j.revision, outputId: j.output_id });
      const open = d.db.prepare("SELECT COUNT(*) AS n FROM render_jobs WHERE object_id = ? AND revision = ? AND status IN ('queued','claimed')").get(o.id, j.revision) as { n: number };
      const failed = d.db.prepare("SELECT COUNT(*) AS n FROM render_jobs WHERE object_id = ? AND revision = ? AND status = 'failed'").get(o.id, j.revision) as { n: number };
      if (open.n === 0 && failed.n === 0) setStatus(d, o, "rendered", { role: "render", ref: keyId });
      touch(d, o.id);
      d.store.commitMp4(tmpPath, sha); // flytta in först när allt annat gick bra (rename kan inte rullas tillbaka, men filen är oskyldig om raden uteblir)
      return { renderId: id, status: o.status };
    });
    return r;
  } catch (e) {
    rmSync(tmpPath, { force: true });
    throw e;
  }
}

// ------------------------------------------------------------------ radering och gallring

export function deleteObject(d: Deps, objectId: string): void {
  const renders = d.db.prepare("SELECT sha256 FROM renders WHERE object_id = ?").all(objectId) as { sha256: string }[];
  const shas = (d.db.prepare("SELECT sha256 FROM object_assets WHERE object_id = ?").all(objectId) as { sha256: string }[]).map((r) => r.sha256);
  tx(d.db, () => {
    d.db.prepare("DELETE FROM objects WHERE id = ?").run(objectId); // kaskad: pool, revisioner, länkar, jobb, renderingar, händelser
    const refAsset = d.db.prepare("SELECT COUNT(*) AS n FROM object_assets WHERE sha256 = ?");
    for (const s of shas) {
      if ((refAsset.get(s) as { n: number }).n === 0) d.db.prepare("DELETE FROM blobs WHERE sha256_orig = ?").run(s);
    }
  });
  const refAsset = d.db.prepare("SELECT COUNT(*) AS n FROM object_assets WHERE sha256 = ?");
  for (const s of shas) if ((refAsset.get(s) as { n: number }).n === 0) d.store.removeImages(s);
  const refRender = d.db.prepare("SELECT COUNT(*) AS n FROM renders WHERE sha256 = ?");
  for (const r of renders) if ((refRender.get(r.sha256) as { n: number }).n === 0) d.store.removeMp4(r.sha256);
}

export interface PurgeResult { objects: number; orphanBlobs: number; tmpFiles: number }

export function purge(d: Deps): PurgeResult {
  const due = d.db.prepare("SELECT id FROM objects WHERE purge_after < ?").all(iso(d)) as { id: string }[];
  for (const o of due) deleteObject(d, o.id);
  // Blobbar som aldrig kopplades till ett objekt (eller vars objekt är borta) och är äldre än ett dygn.
  const cutoff = iso(d, d.now() - 86400_000);
  const orphans = d.db.prepare("SELECT DISTINCT sha256_orig AS s FROM blobs b WHERE created_at < ? AND NOT EXISTS (SELECT 1 FROM object_assets a WHERE a.sha256 = b.sha256_orig)").all(cutoff) as { s: string }[];
  for (const { s } of orphans) {
    d.db.prepare("DELETE FROM blobs WHERE sha256_orig = ?").run(s);
    d.store.removeImages(s);
  }
  const tmpFiles = d.store.sweepTmp(Date.now()); // filernas mtime är verklig tid
  return { objects: due.length, orphanBlobs: orphans.length, tmpFiles };
}

