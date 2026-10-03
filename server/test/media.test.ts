import { test, afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { call, fakeMp4, link, makeLink, pf, rk, seedObject, startServer, type TestEnv } from "./helpers.ts";

let env: TestEnv;
beforeEach(async () => { env = await startServer(); });
afterEach(async () => { await env.close(); });

async function shareWithRender(): Promise<{ token: string; mp4: Buffer; videoUrl: string; imageUrl: string }> {
  const id = await seedObject(env);
  const { token } = await makeLink(env, id);
  await call(env, "POST", "/api/v1/share/approve", { auth: link(token), body: { revision: 1 } });
  const c = await call(env, "POST", "/api/v1/render-jobs/claim", { auth: rk(env) });
  const mp4 = fakeMp4(10_000);
  await call(env, "PUT", `/api/v1/render-jobs/${c.json.jobId}/output`, { auth: rk(env), raw: mp4, type: "video/mp4" });
  const share = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json;
  return { token, mp4, videoUrl: share.renders[0].url, imageUrl: share.pool[0].thumbUrl };
}

test("signerad media-URL: giltig, manipulerad och utgången", async () => {
  const { imageUrl } = await shareWithRender();
  const ok = await call(env, "GET", imageUrl);
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get("content-type"), "image/jpeg");
  assert.match(ok.headers.get("cache-control")!, /private/);
  // manipulerad signatur, manipulerad nyckel och manipulerad utgång
  const [, , exp, sig, ...key] = imageUrl.split("/");
  assert.equal((await call(env, "GET", `/media/${exp}/${sig.slice(0, -2)}AA/${key.join("/")}`)).status, 403);
  assert.equal((await call(env, "GET", `/media/${exp}/${sig}/${key.join("/").replace("w480", "w1600")}`)).status, 403);
  assert.equal((await call(env, "GET", `/media/${Number(exp) + 99999}/${sig}/${key.join("/")}`)).status, 403);
  assert.equal((await call(env, "GET", `/media/abc/${sig}/${key.join("/")}`)).status, 403);
  assert.equal((await call(env, "GET", "/media/")).status, 404);
  // utgången efter en timme
  env.clock.ms += 3600_000 + 5000;
  const old = await call(env, "GET", imageUrl);
  assert.equal(old.status, 410);
  assert.equal(old.json.error.code, "media_expired");
  // en signatur från en annan server med annan nyckel duger inte
  env.clock.ms -= 3600_000 + 5000;
  const { signedMediaPath } = await import("../src/crypto.ts");
  const forged = signedMediaPath("x".repeat(40), key.join("/"), Math.floor(env.clock.ms / 1000) + 600);
  assert.equal((await call(env, "GET", forged)).status, 403);
  // signerad men okänd bild
  const missing = signedMediaPath(env.cfg.signingKey, `img/${"0".repeat(64)}/w480`, Math.floor(env.clock.ms / 1000) + 600);
  assert.equal((await call(env, "GET", missing)).status, 404);
});

test("Range-stöd för MP4 (206, suffix, öppen ände, 416) och HEAD", async () => {
  const { mp4, videoUrl } = await shareWithRender();
  const full = await call(env, "GET", videoUrl);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get("accept-ranges"), "bytes");
  assert.equal(full.headers.get("content-length"), String(mp4.length));
  assert.deepEqual(full.buf, mp4);
  assert.match(full.headers.get("content-disposition")!, /inline; filename="Objektfilm.mp4"/);

  const r1 = await call(env, "GET", videoUrl, { headers: { Range: "bytes=0-1" } }); // som iOS Safari frågar
  assert.equal(r1.status, 206);
  assert.equal(r1.headers.get("content-range"), `bytes 0-1/${mp4.length}`);
  assert.deepEqual(r1.buf, mp4.subarray(0, 2));

  const r2 = await call(env, "GET", videoUrl, { headers: { Range: "bytes=100-199" } });
  assert.equal(r2.status, 206);
  assert.equal(r2.headers.get("content-range"), `bytes 100-199/${mp4.length}`);
  assert.deepEqual(r2.buf, mp4.subarray(100, 200));

  const r3 = await call(env, "GET", videoUrl, { headers: { Range: "bytes=9000-" } });
  assert.equal(r3.status, 206);
  assert.deepEqual(r3.buf, mp4.subarray(9000));

  const r4 = await call(env, "GET", videoUrl, { headers: { Range: "bytes=-500" } });
  assert.equal(r4.status, 206);
  assert.deepEqual(r4.buf, mp4.subarray(mp4.length - 500));

  const r5 = await call(env, "GET", videoUrl, { headers: { Range: "bytes=5000-99999" } });
  assert.equal(r5.status, 206);
  assert.equal(r5.headers.get("content-range"), `bytes 5000-${mp4.length - 1}/${mp4.length}`);

  const bad = await call(env, "GET", videoUrl, { headers: { Range: "bytes=20000-30000" } });
  assert.equal(bad.status, 416);
  assert.equal(bad.headers.get("content-range"), `bytes */${mp4.length}`);

  const head = await fetch(env.url + videoUrl, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("content-length"), String(mp4.length));
});

test("Range gäller även mäklarens autentiserade nedladdning", async () => {
  const { token, mp4 } = await shareWithRender();
  const share = (await call(env, "GET", "/api/v1/share", { auth: link(token) })).json;
  const r = await call(env, "GET", `/api/v1/share/renders/${share.renders[0].renderId}`, { auth: link(token), headers: { Range: "bytes=10-19" } });
  assert.equal(r.status, 206);
  assert.deepEqual(r.buf, mp4.subarray(10, 20));
  // en annan fotografs/objekts render syns inte
  assert.equal((await call(env, "GET", `/api/v1/share/renders/00000000-0000-4000-8000-000000000000`, { auth: link(token) })).status, 404);
});

test("assets/check och variantuppladdning: hash, missing och integritetshash", async () => {
  const { sha256hex } = await import("../src/crypto.ts");
  const { fakeJpeg } = await import("./helpers.ts");
  const orig = sha256hex("original-x");
  const c1 = await call(env, "POST", "/api/v1/assets/check", { auth: pf(env), body: { sha256: [orig] } });
  assert.deepEqual(c1.json.missing, [orig]);
  const img = fakeJpeg(1600, 1067);
  const up = await call(env, "PUT", `/api/v1/assets/${orig}/w1600`, { auth: pf(env), raw: img, type: "image/jpeg" });
  assert.equal(up.status, 200);
  assert.equal(up.json.variantSha256, sha256hex(img));
  assert.equal(up.json.width, 1600);
  // bara en av två varianter: fortfarande "missing"
  assert.deepEqual((await call(env, "POST", "/api/v1/assets/check", { auth: pf(env), body: { sha256: [orig] } })).json.missing, [orig]);
  await call(env, "PUT", `/api/v1/assets/${orig}/w480`, { auth: pf(env), raw: fakeJpeg(480, 320), type: "image/jpeg" });
  assert.deepEqual((await call(env, "POST", "/api/v1/assets/check", { auth: pf(env), body: { sha256: [orig] } })).json.missing, []);
  assert.equal((await call(env, "POST", "/api/v1/assets/check", { auth: pf(env), body: { sha256: ["nej"] } })).status, 422);
});
