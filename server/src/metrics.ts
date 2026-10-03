// Prometheus-mätvärden (textformat). Räknare ligger i minnet; mätare räknas ur databasen vid scrape.

import type { Db } from "./db.ts";

export class Counters {
  invalidAuth = 0;
  uploadsBytes = 0;
  rateLimited = 0;
  requests = new Map<string, number>();
  countRequest(route: string, status: number): void {
    const k = `${route}|${Math.floor(status / 100)}xx`;
    this.requests.set(k, (this.requests.get(k) ?? 0) + 1);
  }
}

export function renderMetrics(db: Db, c: Counters, nowMs: number): string {
  const iso = new Date(nowMs).toISOString();
  const out: string[] = [];
  const g = (name: string, help: string, type: string, lines: string[]) => {
    out.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`, ...lines);
  };

  const oldest = db.prepare("SELECT MIN(created_at) AS t FROM render_jobs WHERE status IN ('queued','claimed')").get() as { t: string | null };
  g("objektfilm_render_queue_oldest_seconds", "Ålder på äldsta renderjobb som väntar eller pågår (0 om kön är tom).", "gauge",
    [`objektfilm_render_queue_oldest_seconds ${oldest.t ? Math.max(0, Math.round((nowMs - Date.parse(oldest.t)) / 1000)) : 0}`]);

  const w = db.prepare("SELECT MAX(last_seen_at) AS t FROM workers").get() as { t: string | null };
  g("objektfilm_worker_last_seen_seconds", "Sekunder sedan någon renderworker senast hördes av (saknas om ingen har setts).", "gauge",
    w.t ? [`objektfilm_worker_last_seen_seconds ${Math.max(0, Math.round((nowMs - Date.parse(w.t)) / 1000))}`] : []);

  g("objektfilm_invalid_auth_total", "Antal anrop med ogiltig token eller nyckel sedan start.", "counter",
    [`objektfilm_invalid_auth_total ${c.invalidAuth}`]);
  g("objektfilm_uploads_bytes_total", "Antal uppladdade byte (bilder och MP4) sedan start.", "counter",
    [`objektfilm_uploads_bytes_total ${c.uploadsBytes}`]);
  g("objektfilm_rate_limited_total", "Antal anrop som svarat 429 sedan start.", "counter",
    [`objektfilm_rate_limited_total ${c.rateLimited}`]);

  const counts = new Map((db.prepare("SELECT status, COUNT(*) AS n FROM objects GROUP BY status").all() as { status: string; n: number }[]).map((r) => [r.status, r.n]));
  g("objektfilm_objects", "Antal objekt per status.", "gauge",
    ["draft", "proposed", "approved", "rendered"].map((s) => `objektfilm_objects{status="${s}"} ${counts.get(s) ?? 0}`));

  const od = db.prepare("SELECT COUNT(*) AS n FROM objects WHERE purge_after < ?").get(iso) as { n: number };
  g("objektfilm_purge_overdue", "Antal objekt vars gallringsdatum har passerat.", "gauge", [`objektfilm_purge_overdue ${od.n}`]);

  const failed = db.prepare("SELECT COUNT(*) AS n FROM render_jobs WHERE status = 'failed'").get() as { n: number };
  g("objektfilm_render_jobs_failed", "Antal renderjobb som har misslyckats slutgiltigt.", "gauge", [`objektfilm_render_jobs_failed ${failed.n}`]);

  g("objektfilm_http_requests_total", "Antal HTTP-anrop per route (mönster) och statusklass.", "counter",
    [...c.requests].map(([k, n]) => { const [r, s] = k.split("|"); return `objektfilm_http_requests_total{route="${r}",status="${s}"} ${n}`; }));
  return out.join("\n") + "\n";
}
