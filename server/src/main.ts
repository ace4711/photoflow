// Startpunkt: läser konfiguration, startar servern och schemalägger daglig gallring kl. 03:30.

import { loadConfig } from "./config.ts";
import { createApp } from "./app.ts";
import { log } from "./log.ts";
import { purge } from "./domain.ts";

const cfg = loadConfig();
const app = createApp(cfg);
const { port, metricsPort } = await app.start();
log("info", "Objektfilm-servern startad", { port, metricsPort, env: cfg.env, dataDir: cfg.dataDir });
if (cfg.env !== "production") log("warn", "Körs i dev-läge (tillfällig signeringsnyckel kan förekomma).");

function msUntilNextRun(now: Date): number {
  const next = new Date(now);
  next.setHours(3, 30, 0, 0);
  if (next <= now) next.setDate(next.getDate() + 1);
  return next.getTime() - now.getTime();
}

function schedule(): void {
  const timer = setTimeout(() => {
    try { log("info", "Gallring klar", { ...purge(app.d) }); } catch (e) { log("error", "Gallring misslyckades", { err: String(e) }); }
    schedule();
  }, msUntilNextRun(new Date()));
  timer.unref();
}
schedule();

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.on(sig, () => {
    log("info", "Stänger ner", { sig });
    void app.stop().then(() => process.exit(0));
  });
}
