// Kommandorad: nycklar, backup, återställning och gallring. Kör mot samma datakatalog som servern.
//   node src/cli.ts create-key --name "Fredrik" --scope photographer [--label "Macen"]
//   node src/cli.ts list-keys | revoke-key --id <id>
//   node src/cli.ts backup --out <fil>
//   node src/cli.ts verify-backup --file <fil>
//   node src/cli.ts restore --from <fil> [--force]      (stoppa servern först)
//   node src/cli.ts purge

import { parseArgs } from "node:util";
import { randomUUID } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { loadConfig } from "./config.ts";
import { dbPath, migrate, openDb, type Db } from "./db.ts";
import { hashSecret, newApiKey } from "./crypto.ts";
import { BlobStore } from "./store.ts";
import { Counters } from "./metrics.ts";
import { EventEmitter } from "node:events";
import { purge, type Deps } from "./domain.ts";

export function createKey(db: Db, name: string, scope: string, label?: string, nowIso = new Date().toISOString()): { key: string; keyId: string; photographerId: string } {
  if (scope !== "photographer" && scope !== "render") throw new Error('--scope måste vara "photographer" eller "render".');
  if (!name.trim()) throw new Error("--name saknas.");
  let p = db.prepare("SELECT id FROM photographers WHERE name = ? AND disabled_at IS NULL").get(name) as { id: string } | undefined;
  if (!p) {
    p = { id: randomUUID() };
    db.prepare("INSERT INTO photographers(id, name, created_at) VALUES (?,?,?)").run(p.id, name, nowIso);
  }
  const key = newApiKey();
  const keyId = randomUUID();
  db.prepare("INSERT INTO api_keys(id, photographer_id, key_hash, scope, label, created_at) VALUES (?,?,?,?,?,?)").run(keyId, p.id, hashSecret(key), scope, label ?? null, nowIso);
  return { key, keyId, photographerId: p.id };
}

/** Konsistent kopia av databasen (VACUUM INTO) som sedan verifieras. Filen får inte finnas. */
export function backupDb(db: Db, out: string): { file: string; bytes: number; integrity: string; counts: Record<string, number> } {
  if (existsSync(out)) throw new Error(`${out} finns redan. Välj ett nytt filnamn.`);
  mkdirSync(dirname(out), { recursive: true });
  db.prepare("VACUUM INTO ?").run(out);
  const v = verifyBackup(out);
  return { file: out, bytes: statSync(out).size, ...v };
}

export function verifyBackup(file: string): { integrity: string; counts: Record<string, number> } {
  const b = new DatabaseSync(file, { readOnly: true });
  try {
    const integrity = (b.prepare("PRAGMA integrity_check").get() as { integrity_check: string }).integrity_check;
    const counts: Record<string, number> = {};
    for (const t of ["photographers", "api_keys", "objects", "object_assets", "spec_revisions", "links", "render_jobs", "renders", "blobs"]) {
      counts[t] = (b.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get() as { n: number }).n;
    }
    return { integrity, counts };
  } finally { b.close(); }
}

export function restoreDb(dataDir: string, from: string, force: boolean): void {
  const v = verifyBackup(from);
  if (v.integrity !== "ok") throw new Error(`Backupen klarar inte integrity_check (${v.integrity}). Avbryter.`);
  const dest = dbPath(dataDir);
  if (existsSync(dest) && !force) throw new Error(`${dest} finns redan. Stoppa servern och kör igen med --force (den gamla databasen sparas som .före-återställning).`);
  mkdirSync(dirname(dest), { recursive: true });
  if (existsSync(dest)) copyFileSync(dest, dest + ".före-återställning");
  for (const ext of ["-wal", "-shm"]) rmSync(dest + ext, { force: true });
  copyFileSync(from, dest);
  const db = new DatabaseSync(dest);
  try { migrate(db); } finally { db.close(); }
}

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv;
  const { values } = parseArgs({
    args: rest,
    options: { name: { type: "string" }, scope: { type: "string" }, label: { type: "string" }, id: { type: "string" }, out: { type: "string" }, file: { type: "string" }, from: { type: "string" }, force: { type: "boolean" } },
    allowPositionals: false,
  });
  const cfg = loadConfig({ ...process.env, OBJEKTFILM_ENV: process.env.OBJEKTFILM_ENV ?? "dev" });
  switch (cmd) {
    case "create-key": {
      if (!values.name || !values.scope) throw new Error('Användning: create-key --name "Namn" --scope photographer|render [--label "Macen"]');
      const db = openDb(cfg.dataDir);
      const r = createKey(db, values.name, values.scope, values.label);
      console.log(`Nyckel-id: ${r.keyId}\nScope:     ${values.scope}\n\nAPI-nyckel (visas bara nu, spara den i Keychain/lösenordshanteraren):\n${r.key}`);
      return 0;
    }
    case "list-keys": {
      const db = openDb(cfg.dataDir);
      for (const k of db.prepare("SELECT k.id, k.scope, k.label, k.created_at, k.revoked_at, k.last_used_at, p.name FROM api_keys k JOIN photographers p ON p.id = k.photographer_id ORDER BY k.created_at").all() as Record<string, string | null>[]) {
        console.log(`${k.id}  ${k.scope?.padEnd(12)} ${k.name}  ${k.label ?? ""}  skapad ${k.created_at}${k.revoked_at ? "  ÅTERKALLAD " + k.revoked_at : ""}  senast ${k.last_used_at ?? "aldrig"}`);
      }
      return 0;
    }
    case "revoke-key": {
      if (!values.id) throw new Error("Användning: revoke-key --id <nyckel-id>");
      const db = openDb(cfg.dataDir);
      const r = db.prepare("UPDATE api_keys SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL").run(new Date().toISOString(), values.id);
      console.log(r.changes ? "Nyckeln är återkallad." : "Ingen aktiv nyckel med det id:t.");
      return r.changes ? 0 : 1;
    }
    case "backup": {
      if (!values.out) throw new Error("Användning: backup --out <fil.db>");
      const r = backupDb(openDb(cfg.dataDir), values.out);
      console.log(`Backup skriven: ${r.file} (${r.bytes} byte)\nintegrity_check: ${r.integrity}\n${JSON.stringify(r.counts)}`);
      return r.integrity === "ok" ? 0 : 1;
    }
    case "verify-backup": {
      if (!values.file) throw new Error("Användning: verify-backup --file <fil.db>");
      const r = verifyBackup(values.file);
      console.log(`integrity_check: ${r.integrity}\n${JSON.stringify(r.counts)}`);
      return r.integrity === "ok" ? 0 : 1;
    }
    case "restore": {
      if (!values.from) throw new Error("Användning: restore --from <fil.db> [--force]");
      restoreDb(cfg.dataDir, values.from, values.force === true);
      console.log("Databasen är återställd. Blobbar återskapas av Macen (POST /assets/check) och renderingar köas om vid behov.");
      return 0;
    }
    case "purge": {
      const db = openDb(cfg.dataDir);
      const d: Deps = { db, cfg, store: new BlobStore(cfg.dataDir), counters: new Counters(), bus: new EventEmitter(), baseUrl: () => cfg.publicBaseUrl ?? "", now: () => Date.now() };
      console.log(JSON.stringify(purge(d)));
      return 0;
    }
    default:
      console.error("Kommandon: create-key, list-keys, revoke-key, backup, verify-backup, restore, purge");
      return 2;
  }
}

if (import.meta.main) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => { console.error(`Fel: ${e instanceof Error ? e.message : e}`); process.exit(1); });
}
