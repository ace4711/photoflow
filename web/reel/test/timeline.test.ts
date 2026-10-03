import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { clipStarts, totalDuration, easing, cropRect, state } from "../src/reelTimeline.ts";
import type { Rect } from "../src/reelTimeline.ts";
import { parseReelSpec, ReelSpecError } from "../src/reelSpec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "../../../PhotoFlow/Tests/Fixtures/Reel");
const vectors = JSON.parse(readFileSync(join(fixtures, "timeline-vectors.json"), "utf8"));
const tol: number = vectors.tolerance;

function near(a: number, b: number, what: string): void {
  assert.ok(Math.abs(a - b) <= tol, `${what}: ${a} != ${b} (tolerans ${tol})`);
}
function nearRect(a: Rect, b: Rect, what: string): void {
  near(a.x, b.x, `${what}.x`); near(a.y, b.y, `${what}.y`);
  near(a.w, b.w, `${what}.w`); near(a.h, b.h, `${what}.h`);
}

test("easing", () => {
  for (const c of vectors.easing) near(easing(c.type, c.p), c.expected, `easing ${c.type}(${c.p})`);
});

test("cover-utsnitt", () => {
  for (const c of vectors.cropRects) {
    const r = cropRect({ width: c.imageSize[0], height: c.imageSize[1] }, c.frameAspect,
      { x: c.center[0], y: c.center[1] }, c.zoom);
    nearRect(r, c.expected, `crop ${JSON.stringify(c)}`);
  }
});

for (const tl of vectors.timelines) {
  test(`tidslinje ${tl.name}`, () => {
    const spec = parseReelSpec(tl.specFile
      ? readFileSync(join(fixtures, tl.specFile), "utf8")
      : tl.spec);
    const starts = clipStarts(spec);
    assert.equal(starts.length, tl.clipStarts.length);
    starts.forEach((s, i) => near(s, tl.clipStarts[i], `clipStart[${i}]`));
    near(totalDuration(spec), tl.totalDuration, "totalDuration");

    for (const s of tl.states) {
      const where = `${tl.name} t=${s.t}`;
      const layers = state(s.t, spec, { width: s.outputSize[0], height: s.outputSize[1] });
      assert.equal(layers.length, s.layers.length, `${where}: antal lager`);
      layers.forEach((l, k) => {
        const e = s.layers[k];
        assert.equal(l.asset, e.asset, `${where}: asset`);
        assert.equal(l.fit, e.fit, `${where}: fit`);
        assert.equal(l.z, e.z, `${where}: z`);
        near(l.opacity, e.opacity, `${where}: opacity`);
        near(l.offset.x, e.offset.x, `${where}: offset.x`);
        near(l.offset.y, e.offset.y, `${where}: offset.y`);
        nearRect(l.crop, e.crop, `${where}: crop`);
        nearRect(l.dest, e.dest, `${where}: dest`);
        assert.equal(l.backdrop === null, e.backdrop === null, `${where}: backdrop finns`);
        if (l.backdrop && e.backdrop) {
          nearRect(l.backdrop.crop, e.backdrop.crop, `${where}: backdrop.crop`);
          near(l.backdrop.sigma, e.backdrop.sigma, `${where}: backdrop.sigma`);
        }
      });
    }
  });
}

test("example-v1.json ger 12,1 s", () => {
  const spec = parseReelSpec(readFileSync(join(fixtures, "example-v1.json"), "utf8"));
  near(totalDuration(spec), 12.1, "total");
  const exp = [0, 2.5, 4.6, 6.7, 8.7];
  clipStarts(spec).forEach((s, i) => near(s, exp[i], `start[${i}]`));
});

test("parseReelSpec: begripliga fel", () => {
  const ok = readFileSync(join(fixtures, "example-v1.json"), "utf8");
  assert.throws(() => parseReelSpec("{inte json"), ReelSpecError);
  assert.throws(() => parseReelSpec({ schema: "annat" }), /inte en reel-fil/);
  const nyare = JSON.parse(ok); nyare.minReaderVersion = 2;
  assert.throws(() => parseReelSpec(nyare), /nyare läsare/);
  const sak = JSON.parse(ok); sak.timeline[0].asset = "x9";
  assert.throws(() => parseReelSpec(sak), /Klipp 1.*x9/);
  const typ = JSON.parse(ok); typ.timeline[1].transitionIn.type = "wipe";
  assert.throws(() => parseReelSpec(typ), /okänd övergångstyp/);
  // Okända fält ignoreras och bevaras.
  const extra = JSON.parse(ok); extra.nyttFalt = { a: 1 }; extra.timeline[0].annat = 5;
  const spec = parseReelSpec(extra);
  assert.deepEqual(spec.nyttFalt, { a: 1 });
});
