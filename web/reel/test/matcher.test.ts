import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { matchAssets } from "../src/assetMatcher.ts";
import type { Asset } from "../src/reelSpec.ts";

function file(name: string, content: string) {
  const buf = new TextEncoder().encode(content);
  return { name, arrayBuffer: async () => buf.buffer.slice(0) as ArrayBuffer };
}
const sha = (s: string) => createHash("sha256").update(s).digest("hex");
const asset = (id: string, path: string, content: string): Asset =>
  ({ id, sha256: sha(content), width: 10, height: 10, sources: [{ kind: "local", path }] });

test("matchar på filnamn (NFD/NFC, versaler) och sedan på sha256", async () => {
  const assets = [
    asset("a1", "../Lindvägen FÄRDIGA/DSC_1.JPG", "ett"),
    asset("a2", "../x/gammalt-namn.jpg", "tva"),
    asset("a3", "../x/saknas.jpg", "tre"),
  ];
  const files = [file("DSC_1.jpg", "ett"), file("annat-namn.jpg", "tva"), file("readme.txt", "tre")];
  const r = await matchAssets(assets, files);
  assert.equal(r.matched.get("a1")?.name, "DSC_1.jpg");
  assert.equal(r.how.get("a1"), "namn");
  assert.equal(r.matched.get("a2")?.name, "annat-namn.jpg");
  assert.equal(r.how.get("a2"), "sha256");
  assert.deepEqual(r.missing, ["a3"]);
});

import { approvedCopy } from "../src/approve.ts";
import { parseReelSpec } from "../src/reelSpec.ts";
import { readFileSync } from "node:fs";

test("approvedCopy: revision +1, approved, agent, edits", () => {
  const src = parseReelSpec(readFileSync(new URL("../../../PhotoFlow/Tests/Fixtures/Reel/example-v1.json", import.meta.url), "utf8"));
  const out = approvedCopy(src, ["reorder", "duration"], "Maja", "2026-10-03T10:00:00Z");
  assert.equal(out.revision, src.revision + 1);
  assert.equal(out.status, "approved");
  assert.deepEqual(out.updatedBy, { role: "agent", name: "Maja" });
  assert.deepEqual(out.provenance.edits!.slice(-3).map((e) => e.op), ["reorder", "duration", "approve"]);
  assert.equal(src.status, "draft");
});
