// Enkel fast-fönster-begränsning i minnet. Nycklar är token-/nyckel-id (aldrig IP).

export class RateLimiter {
  private w = new Map<string, { start: number; n: number }>();
  private lastPrune = 0;

  /** Räknar ett anrop. Returnerar sekunder att vänta (0 = släpp igenom). */
  hit(key: string, limit: number, windowMs: number, nowMs: number): number {
    if (nowMs - this.lastPrune > 60_000) this.prune(nowMs);
    const e = this.w.get(key);
    if (!e || nowMs - e.start >= windowMs) {
      this.w.set(key, { start: nowMs, n: 1 });
      return 0;
    }
    e.n++;
    return e.n > limit ? Math.max(1, Math.ceil((e.start + windowMs - nowMs) / 1000)) : 0;
  }

  /** Antal träffar i nuvarande fönster (för varning vid ogiltig auth). */
  count(key: string): number { return this.w.get(key)?.n ?? 0; }

  private prune(nowMs: number): void {
    this.lastPrune = nowMs;
    for (const [k, e] of this.w) if (nowMs - e.start > 3600_000) this.w.delete(k);
  }
}
