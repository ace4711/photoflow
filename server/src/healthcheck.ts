// Docker-healthcheck: anropar /healthz lokalt och avslutar med 0 vid 200.
const port = process.env.OBJEKTFILM_PORT ?? "8080";
try {
  const r = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(4000) });
  process.exit(r.status === 200 && r.headers.get("x-objektfilm") === "1" ? 0 : 1);
} catch {
  process.exit(1);
}
