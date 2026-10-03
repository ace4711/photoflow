// Blobblagring på disk under <data>/blobs. Bildvarianter lagras under
// ORIGINALETS sha256; MP4 under sin egen. Skrivning går via tmp + rename.

import { mkdirSync, renameSync, rmSync, writeFileSync, existsSync, readdirSync, statSync, rmdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

export const VARIANTS = ["w1600", "w480"] as const;
export type Variant = (typeof VARIANTS)[number];

export class BlobStore {
  readonly root: string;
  readonly tmpDir: string;
  constructor(dataDir: string) {
    this.root = join(dataDir, "blobs");
    this.tmpDir = join(dataDir, "tmp"); // på samma filsystem som blobs (rename), inte tmpfs i containern
    mkdirSync(join(this.root, "img"), { recursive: true });
    mkdirSync(join(this.root, "mp4"), { recursive: true });
    mkdirSync(this.tmpDir, { recursive: true });
  }

  imagePath(sha: string, variant: Variant): string {
    return join(this.root, "img", sha.slice(0, 2), sha, `${variant}.jpg`);
  }
  mp4Path(sha: string): string { return join(this.root, "mp4", `${sha}.mp4`); }
  newTmp(): string { return join(this.tmpDir, `${randomUUID()}.part`); }

  putImage(sha: string, variant: Variant, data: Uint8Array): void {
    const dest = this.imagePath(sha, variant);
    mkdirSync(join(dest, ".."), { recursive: true });
    const tmp = this.newTmp();
    writeFileSync(tmp, data);
    renameSync(tmp, dest);
  }

  commitMp4(tmp: string, sha: string): void {
    const dest = this.mp4Path(sha);
    if (existsSync(dest)) rmSync(tmp, { force: true });
    else renameSync(tmp, dest);
  }

  removeImages(sha: string): void {
    const dir = join(this.root, "img", sha.slice(0, 2), sha);
    rmSync(dir, { recursive: true, force: true });
    try { rmdirSync(join(this.root, "img", sha.slice(0, 2))); } catch { /* inte tom */ }
  }
  removeMp4(sha: string): void { rmSync(this.mp4Path(sha), { force: true }); }

  /** Städar övergivna delfiler äldre än `maxAgeMs`. */
  sweepTmp(nowMs: number, maxAgeMs = 3600_000): number {
    let n = 0;
    for (const f of readdirSync(this.tmpDir)) {
      const p = join(this.tmpDir, f);
      try {
        if (nowMs - statSync(p).mtimeMs > maxAgeMs) { rmSync(p, { force: true }); n++; }
      } catch { /* borta */ }
    }
    return n;
  }
}
