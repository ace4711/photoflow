// SQLite via node:sqlite (inbyggd i Node 24/25, inga npm-beroenden). Schemat
// versioneras med PRAGMA user_version; varje migration körs i en transaktion.

import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

export type Db = DatabaseSync;

export const MIGRATIONS: string[] = [
  // 1: grundschemat enligt docs/plan-objektfilm-backend.md avsnitt 4
  `
  CREATE TABLE photographers(
    id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL, disabled_at TEXT);
  CREATE TABLE api_keys(
    id TEXT PRIMARY KEY,
    photographer_id TEXT NOT NULL REFERENCES photographers(id),
    key_hash TEXT NOT NULL UNIQUE,
    scope TEXT NOT NULL CHECK(scope IN ('photographer','render')),
    label TEXT, created_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
  CREATE TABLE objects(
    id TEXT PRIMARY KEY,
    photographer_id TEXT NOT NULL REFERENCES photographers(id),
    reel_id TEXT NOT NULL UNIQUE,
    address TEXT NOT NULL, session_id TEXT, kind TEXT,
    status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','proposed','approved','rendered')),
    current_revision INTEGER NOT NULL DEFAULT 0,
    approved_revision INTEGER,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    purge_after TEXT NOT NULL, deleted_at TEXT);
  CREATE INDEX objects_purge ON objects(purge_after);
  CREATE TABLE object_assets(
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL, sha256 TEXT NOT NULL,
    width INTEGER NOT NULL, height INTEGER NOT NULL,
    analysis_json TEXT, sort INTEGER NOT NULL,
    PRIMARY KEY(object_id, sha256), UNIQUE(object_id, asset_id));
  CREATE INDEX object_assets_sha ON object_assets(sha256);
  CREATE TABLE blobs(
    sha256_orig TEXT NOT NULL, variant TEXT NOT NULL CHECK(variant IN ('w1600','w480')),
    variant_sha256 TEXT NOT NULL, bytes INTEGER NOT NULL,
    width INTEGER NOT NULL, height INTEGER NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(sha256_orig, variant));
  CREATE TABLE spec_revisions(
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, spec_json TEXT NOT NULL, content_hash TEXT NOT NULL,
    author_role TEXT NOT NULL, author_ref TEXT, created_at TEXT NOT NULL,
    PRIMARY KEY(object_id, revision));
  CREATE TABLE links(
    id TEXT PRIMARY KEY,
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE, label TEXT,
    created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
  CREATE TABLE render_jobs(
    id TEXT PRIMARY KEY,
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, output_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('queued','claimed','done','failed','superseded')),
    worker_id TEXT, lease_until TEXT, attempts INTEGER NOT NULL DEFAULT 0, error TEXT,
    created_at TEXT NOT NULL, finished_at TEXT);
  CREATE INDEX render_jobs_status ON render_jobs(status, created_at);
  CREATE TABLE renders(
    id TEXT PRIMARY KEY,
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, output_id TEXT NOT NULL,
    sha256 TEXT NOT NULL, bytes INTEGER NOT NULL,
    width INTEGER, height INTEGER, duration REAL, created_at TEXT NOT NULL);
  CREATE INDEX renders_sha ON renders(sha256);
  CREATE TABLE workers(id TEXT PRIMARY KEY, label TEXT, last_seen_at TEXT NOT NULL);
  CREATE TABLE events(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    object_id TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    at TEXT NOT NULL, actor_role TEXT NOT NULL, actor_ref TEXT, type TEXT NOT NULL, data_json TEXT);
  CREATE INDEX events_object ON events(object_id, id);
  `,
];

export function dbPath(dataDir: string): string {
  return join(dataDir, "db", "objektfilm.db");
}

export function migrate(db: Db, migrations: string[] = MIGRATIONS): number {
  const current = (db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
  if (current > migrations.length) throw new Error(`Databasen är nyare (version ${current}) än koden (${migrations.length}).`);
  for (let v = current; v < migrations.length; v++) {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.exec(migrations[v]);
      db.exec(`PRAGMA user_version = ${v + 1}`);
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  }
  return migrations.length;
}

export function openDb(dataDir: string): Db {
  const path = dbPath(dataDir);
  mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA synchronous = NORMAL;");
  migrate(db);
  return db;
}

/** Kör `fn` i en omedelbar skrivtransaktion; rullar tillbaka vid undantag. */
export function tx<T>(db: Db, fn: () => T): T {
  db.exec("BEGIN IMMEDIATE");
  try {
    const r = fn();
    db.exec("COMMIT");
    return r;
  } catch (e) {
    try { db.exec("ROLLBACK"); } catch { /* redan återställd */ }
    throw e;
  }
}
