import { test } from "node:test";
import assert from "node:assert/strict";
import { ShareClient, ShareError, tokenFromHash } from "../src/shareApi.ts";
import { editedCopy } from "../src/approve.ts";
import type { ReelSpec } from "../src/reelSpec.ts";

const TOKEN = "A".repeat(43);

function fakeFetch(status: number, body: unknown, calls: { url: string; init: RequestInit }[] = []): typeof fetch {
  return (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ETag: '"3"' } });
  }) as unknown as typeof fetch;
}

test("tokenFromHash godtar bara en rimlig token i fragmentet", () => {
  assert.equal(tokenFromHash(`#${TOKEN}`), TOKEN);
  assert.equal(tokenFromHash(""), null);
  assert.equal(tokenFromHash("#kort"), null);
  assert.equal(tokenFromHash(`#${TOKEN}&x=1`), null);
});

test("klienten skickar Authorization: Link och If-Match, aldrig token i URL:en", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const c = new ShareClient(TOKEN, fakeFetch(200, { revision: 4, status: "proposed", changed: true }, calls));
  await c.get();
  const r = await c.saveSpec({ id: "x" } as unknown as ReelSpec, 3);
  assert.equal(r.revision, 4);
  await c.approve(4);
  assert.deepEqual(calls.map((x) => [x.init.method, x.url]), [["GET", "/api/v1/share"], ["PUT", "/api/v1/share/spec"], ["POST", "/api/v1/share/approve"]]);
  for (const x of calls) {
    assert.equal((x.init.headers as Record<string, string>).Authorization, `Link ${TOKEN}`);
    assert.ok(!x.url.includes(TOKEN));
  }
  assert.equal((calls[1].init.headers as Record<string, string>)["If-Match"], '"3"');
  assert.equal(calls[2].init.body, JSON.stringify({ revision: 4 }));
});

test("felmeddelanden på svenska: 412, 410, 401, 429 och nätverksfel", async () => {
  const err = async (status: number, code = "x") => {
    try { await new ShareClient(TOKEN, fakeFetch(status, { error: { code, message: "engelska" } })).get(); } catch (e) { return e as ShareError; }
    throw new Error("väntade fel");
  };
  assert.equal((await err(412, "revision_conflict")).message, "Fotografen har ändrat, ladda om.");
  assert.match((await err(410, "link_expired")).message, /Kontakta fotografen/);
  assert.match((await err(401)).message, /Be fotografen om en ny/);
  assert.match((await err(429)).message, /För många anrop/);
  assert.match((await err(409, "revision_mismatch")).message, /Ladda om och godkänn igen/);
  assert.equal((await err(412)).status, 412);
  const net = new ShareClient(TOKEN, (async () => { throw new TypeError("fail"); }) as unknown as typeof fetch);
  await assert.rejects(() => net.get(), (e: ShareError) => e.code === "network" && /Ingen kontakt/.test(e.message));
});

test("editedCopy loggar ändringarna utan att röra revision och status", () => {
  const src = { revision: 2, status: "proposed", updatedAt: "a", updatedBy: { role: "photographer" }, provenance: { generator: "g" } } as unknown as ReelSpec;
  const out = editedCopy(src, ["reorder", "duration"], "Mia", "2026-10-03T10:00:00Z");
  assert.equal(out.revision, 2);
  assert.equal(out.status, "proposed");
  assert.deepEqual(out.updatedBy, { role: "agent", name: "Mia" });
  assert.deepEqual(out.provenance.edits?.map((e) => e.op), ["reorder", "duration"]);
  assert.equal(src.provenance.edits, undefined, "originalet är orört");
});
