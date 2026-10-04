#!/usr/bin/env python3
# scripts/window-candidates.py -- jämförelsesida för kandidater av window pull (+ Förbättra).
#
# Komplement till window-compare.py (som jämför pull på/av). Här jämförs flera körningar av
# `photoflow-cli run ... --window-pull on --hdr-debug` (med Förbättra påslaget) mot en baslinje:
# reglage "före: baslinjen" / "efter: vald kandidat", växling mellan slutbild (efter Förbättra)
# och HDR (före Förbättra), mörk råbild, 100 %-utsnitt och mått per kandidat.
#
# Användning:
#   scripts/window-candidates.py --base 'nuvarande=DIR' --cand 'A=DIR' --cand 'B=DIR' [--out DIR]
#                                [--testset FIL] [--beskrivning 'A=text']
#
# Mått (inom fönstermasken, m ≥ 0,5, på maskens upplösning ~1500 px, inre masken 3 px in):
#   median    — medianluma (gammakodad) i slutbilden respektive HDR:en
#   klippt    — andel pixlar med någon kanal ≥ 0,98 (mål < 2 %)
#   struktur  — korrelation mellan gradientstyrkan i bilden och i mörka ramen (mål ≥ 0,8)
#   gain      — mörka ramens median/p99 och om p99-taket band (gain mot mål respektive tak)
# Slutbilden kan vara roterad/beskuren (horisonträtning) några px: masken jämförs då ungefärligt.
#
# Bara standardbibliotek + sips + swiftc. ABSOLUT REGEL: ingenting skrivs under /Volumes/photo-ingestion/.
import argparse
import datetime
import json
import os
import re
import shutil
import statistics
import subprocess

FORBJUDET = "/Volumes/photo-ingestion"
LANGSIDA = 2000
OUT_ROOT = None


def sakra_mal(sokvag):
    p = os.path.realpath(os.path.abspath(sokvag))
    assert not (p == FORBJUDET or p.startswith(FORBJUDET + "/")), f"förbjuden målväg: {p}"
    assert OUT_ROOT and (p == OUT_ROOT or p.startswith(OUT_ROOT + os.sep)), f"målväg utanför --out: {p}"
    return p


def kor(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def las_json(p, standard=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return standard


def dimensioner(p):
    r = kor(["sips", "-g", "pixelWidth", "-g", "pixelHeight", p])
    w = re.search(r"pixelWidth:\s*(\d+)", r.stdout)
    h = re.search(r"pixelHeight:\s*(\d+)", r.stdout)
    return (int(w.group(1)), int(h.group(1))) if w and h else None


def sips_jpeg(src, dst, langsida=LANGSIDA):
    dst = sakra_mal(dst)
    r = kor(["sips", "-Z", str(langsida), src, "-s", "format", "jpeg", "-s", "formatOptions", "85", "--out", dst])
    return r.returncode == 0 and os.path.exists(dst)


def sips_utsnitt(src, dst, fx, fy, b=700, h=450):
    """Utsnitt b×h px i full upplösning kring (fx, fy) i andelar av bilden."""
    dst = sakra_mal(dst)
    d = dimensioner(src)
    if not d:
        return False
    W, H = d
    x0 = max(0, min(W - b, round(fx * W - b / 2)))
    y0 = max(0, min(H - h, round(fy * H - h / 2)))
    r = kor(["sips", "-c", str(h), str(b), "--cropOffset", str(y0), str(x0), src,
             "-s", "format", "jpeg", "-s", "formatOptions", "90", "--out", dst])
    return r.returncode == 0 and os.path.exists(dst)


SWIFT_KALLA = r'''
import Foundation
import ImageIO
import CoreGraphics

// Jobb (JSON-lista i argv[1]): {mask, dark, bilder: {nyckel: sökväg}}. Resultat per jobb:
// {mork: {median, p99, malEV, takEV, band}, ruta: [x0,y0,x1,y1], matt: {nyckel: {median, klippt, struktur}}}
func las(_ path: String, _ w: Int, _ h: Int, gra: Bool) -> [Float]? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let im = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    let kanaler = gra ? 1 : 4
    var buf = [UInt8](repeating: 0, count: w * h * kanaler)
    let ok: Bool = buf.withUnsafeMutableBytes { raw in
        let cs = gra ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gra ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * kanaler,
                                space: cs, bitmapInfo: info) else { return false }
        c.interpolationQuality = .high
        c.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
    }
    return ok ? buf.map { Float($0) / 255 } : nil
}
func storlek(_ path: String) -> (Int, Int)? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let im = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    return (im.width, im.height)
}
func percentil(_ v: [Float], _ q: Float) -> Float {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted(); return s[min(s.count - 1, max(0, Int(Float(s.count - 1) * q)))]
}
func tillLinjar(_ v: Float) -> Float { let c = min(max(v, 0), 1); return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
func luma(_ p: [Float], _ i: Int) -> Float { 0.2126 * p[i * 4] + 0.7152 * p[i * 4 + 1] + 0.0722 * p[i * 4 + 2] }
func maxk(_ p: [Float], _ i: Int) -> Float { max(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) }
func erodera(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
    var ut = m
    for y in 0..<h { for x in 0..<w where m[y * w + x] {
        loop: for dy in -r...r { for dx in -r...r {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= w || ny >= h || !m[ny * w + nx] { ut[y * w + x] = false; break loop }
        } }
    } }
    return ut
}
func gradient(_ p: [Float], _ w: Int, _ h: Int) -> [Float] {
    var g = [Float](repeating: 0, count: w * h)
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let i = y * w + x
        let gx = luma(p, i + 1) - luma(p, i - 1), gy = luma(p, i + w) - luma(p, i - w)
        g[i] = sqrtf(gx * gx + gy * gy)
    } }
    return g
}
func korrelation(_ a: [Float], _ b: [Float], _ m: [Bool]) -> Double {
    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, k = 0.0
    for i in 0..<m.count where m[i] {
        let x = Double(a[i]), y = Double(b[i])
        sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; k += 1
    }
    guard k > 10 else { return 0 }
    let cov = sxy / k - sx / k * sy / k, va = sxx / k - sx * sx / k / k, vb = syy / k - sy * sy / k / k
    return va > 1e-12 && vb > 1e-12 ? cov / (va * vb).squareRoot() : 0
}

let jobb = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))) as? [[String: Any]] ?? []
var alla: [[String: Any]] = []
for j in jobb {
    var r: [String: Any] = [:]
    guard let mp = j["mask"] as? String, let (w, h) = storlek(mp), let mg = las(mp, w, h, gra: true) else { alla.append(r); continue }
    let mask = mg.map { $0 >= 0.5 }
    let antal = mask.filter { $0 }.count
    guard antal >= 50 else { alla.append(r); continue }
    let inre = erodera(mask, w, h, 3)
    var x0 = w, y0 = h, x1 = 0, y1 = 0
    for y in 0..<h { for x in 0..<w where mask[y * w + x] { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    r["ruta"] = [Double(x0) / Double(w), Double(y0) / Double(h), Double(x1 + 1) / Double(w), Double(y1 + 1) / Double(h)]
    // Tyngdpunkt för utsnittet: mitt i den största sammanhängande delen vore bäst; vi tar
    // maskpixeln närmast maskens tyngdpunkt.
    var cx = 0.0, cy = 0.0
    for y in 0..<h { for x in 0..<w where mask[y * w + x] { cx += Double(x); cy += Double(y) } }
    cx /= Double(antal); cy /= Double(antal)
    var bast = (Double.infinity, 0, 0)
    for y in 0..<h { for x in 0..<w where inre[y * w + x] {
        let d = hypot(Double(x) - cx, Double(y) - cy); if d < bast.0 { bast = (d, x, y) }
    } }
    if bast.0.isFinite { r["centrum"] = [Double(bast.1) / Double(w), Double(bast.2) / Double(h)] }
    var morkGrad: [Float]? = nil
    if let dp = j["dark"] as? String, let d = las(dp, w, h, gra: false) {
        var lumor: [Float] = [], maxar: [Float] = []
        for i in 0..<(w * h) where mask[i] && maxk(d, i) <= 0.95 { lumor.append(luma(d, i)); maxar.append(maxk(d, i)) }
        if lumor.count >= 20 {
            let med = max(tillLinjar(percentil(lumor, 0.5)), 1e-5), p99 = max(tillLinjar(percentil(maxar, 0.99)), 1e-5)
            let mal = log2(tillLinjar(0.66) / med), tak = log2(tillLinjar(0.97) / p99)
            r["mork"] = ["median": percentil(lumor, 0.5), "p99": percentil(maxar, 0.99), "malEV": mal, "takEV": tak, "band": tak < mal]
        }
        morkGrad = gradient(d, w, h)
    }
    var matt: [String: Any] = [:]
    for (nyckel, sv) in (j["bilder"] as? [String: String]) ?? [:] {
        guard let p = las(sv, w, h, gra: false) else { continue }
        var lumor: [Float] = []; var klippta = 0
        for i in 0..<(w * h) where inre[i] { lumor.append(luma(p, i)); if maxk(p, i) >= 0.98 { klippta += 1 } }
        var m: [String: Any] = ["median": percentil(lumor, 0.5), "klippt": Double(klippta) / Double(max(lumor.count, 1)),
                                "p95": percentil(lumor, 0.95)]
        if let mg = morkGrad { m["struktur"] = korrelation(gradient(p, w, h), mg, inre) }
        matt[nyckel] = m
    }
    r["matt"] = matt
    alla.append(r)
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: alla))
'''


def kor_swift(jobb, arbetsmapp):
    os.makedirs(sakra_mal(arbetsmapp), exist_ok=True)
    kalla, binar, jobbfil = (sakra_mal(os.path.join(arbetsmapp, n)) for n in ("matt.swift", "matt", "jobb.json"))
    with open(kalla, "w", encoding="utf-8") as f:
        f.write(SWIFT_KALLA)
    with open(jobbfil, "w", encoding="utf-8") as f:
        json.dump(jobb, f)
    c = kor(["swiftc", "-O", kalla, "-o", binar])
    if c.returncode != 0:
        raise SystemExit("swiftc misslyckades: " + c.stderr[:500])
    r = kor([binar, jobbfil])
    if r.returncode != 0:
        raise SystemExit("mäthjälparen misslyckades: " + r.stderr[:500])
    return json.loads(r.stdout)


def las_korning(rot):
    rot = os.path.abspath(os.path.expanduser(rot))
    hdr = las_json(os.path.join(rot, "hdr.json"), {}) or {}
    poster = {}
    for namn, e in (hdr.get("entries") or {}).items():
        if re.match(r"hdr_group_\d+$", namn):
            poster[namn] = e
    enh = {}
    hdrbilder = {}
    for d, dirs, files in os.walk(rot):
        dirs[:] = [x for x in dirs if x not in ("hdr_debug", "hdr_masks", "previews", "dng")]
        for fn in files:
            m = re.match(r"(hdr_group_\d+)(_enh)?\.jpe?g$", fn)
            if m:
                (enh if m.group(2) else hdrbilder).setdefault(m.group(1), os.path.join(d, fn))
    return {"rot": rot, "poster": poster, "enh": enh, "hdr": hdrbilder}


def namn_och_mapp(s):
    if "=" not in s:
        raise SystemExit(f"väntade NAMN=MAPP, fick {s}")
    n, d = s.split("=", 1)
    return n.strip(), d.strip()


def main():
    global OUT_ROOT
    ap = argparse.ArgumentParser(description="Jämförelsesida för window pull-kandidater (slutbild efter Förbättra).")
    ap.add_argument("--base", required=True, help="NAMN=MAPP för baslinjen (\"före\")")
    ap.add_argument("--cand", action="append", default=[], help="NAMN=MAPP, upprepas")
    ap.add_argument("--beskrivning", action="append", default=[], help="NAMN=text om kandidaten")
    ap.add_argument("--standard", default=None, help="kandidaten som valdes som standard (markeras)")
    ap.add_argument("--testset", default="~/PhotoFlowBenchmark/windows/testset.json")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    ut = a.out or f"~/PhotoFlowBenchmark/results/windows-ljusare-{datetime.date.today().isoformat()}/"
    ut = os.path.realpath(os.path.abspath(os.path.expanduser(ut)))
    assert not (ut == FORBJUDET or ut.startswith(FORBJUDET + "/"))
    OUT_ROOT = ut
    for sub in ("images", "crops", ".arbete"):
        os.makedirs(sakra_mal(os.path.join(ut, sub)), exist_ok=True)

    bas_namn, bas_mapp = namn_och_mapp(a.base)
    korningar = [(bas_namn, las_korning(bas_mapp))] + [(n, las_korning(d)) for n, d in map(namn_och_mapp, a.cand)]
    beskr = dict(namn_och_mapp(s) for s in a.beskrivning)
    testset = las_json(os.path.expanduser(a.testset), []) or []
    bas = korningar[0][1]

    def kategori(filer):
        fs = set(filer)
        for t in testset:
            if set(t.get("files", [])) == fs:
                return t.get("category") or "okand"
        return "okand"

    grupper, jobb = [], []
    for gnamn in sorted(bas["poster"], key=lambda s: int(s.rsplit("_", 1)[1])):
        e = bas["poster"][gnamn]
        dbg = os.path.join(bas["rot"], "hdr_debug", gnamn)
        if not (e.get("window") or {}).get("applied"):
            continue
        mask = os.path.join(dbg, "mask.png")
        dark = os.path.join(dbg, "dark_raw.jpg")
        if not (os.path.isfile(mask) and os.path.isfile(dark)):
            continue
        gk = gnamn.replace("hdr_group_", "g")
        frames = e.get("frames") or []
        g = {"id": gnamn, "gk": gk, "kategori": kategori(frames), "filer": frames, "bilder": {}, "kand": {}}
        bilder = {}
        for kn, k in korningar:
            kd = {"gainEV": ((k["poster"].get(gnamn) or {}).get("window") or {}).get("gainEV")}
            for typ, kalla in (("enh", k["enh"].get(gnamn)), ("hdr", k["hdr"].get(gnamn))):
                if kalla:
                    dst = os.path.join(ut, "images", f"{gk}_{kn}_{typ}.jpg")
                    if sips_jpeg(kalla, dst):
                        kd[typ] = os.path.relpath(dst, ut)
                    bilder[f"{kn}|{typ}"] = kalla
                    kd["_" + typ] = kalla
            g["kand"][kn] = kd
        if sips_jpeg(dark, os.path.join(ut, "images", f"{gk}_dark.jpg")):
            g["bilder"]["dark"] = f"images/{gk}_dark.jpg"
        d = dimensioner(os.path.join(ut, "images", f"{gk}_{bas_namn}_enh.jpg")) or (3, 2)
        g["w"], g["h"] = d
        jobb.append({"mask": mask, "dark": dark, "bilder": bilder})
        grupper.append(g)
        print(f"  {gnamn}: {len(bilder)} bilder")

    res = kor_swift(jobb, os.path.join(ut, ".arbete"))
    for g, r in zip(grupper, res):
        g["mork"] = r.get("mork")
        matt = r.get("matt") or {}
        for kn, kd in g["kand"].items():
            kd["matt"] = {typ: matt.get(f"{kn}|{typ}") for typ in ("enh", "hdr")}
        c = r.get("centrum")
        if c:
            for kn, kd in g["kand"].items():
                for typ in ("enh", "hdr"):
                    src = kd.get("_" + typ)
                    dst = os.path.join(ut, "crops", f"{g['gk']}_{kn}_{typ}.jpg")
                    if src and sips_utsnitt(src, dst, c[0], c[1]):
                        kd["utsnitt_" + typ] = os.path.relpath(dst, ut)
        for kd in g["kand"].values():
            for typ in ("enh", "hdr"):
                kd.pop("_" + typ, None)

    # Sammanfattning per kandidat: median och värsta över grupperna.
    namn = [kn for kn, _ in korningar]
    sammanf = {}
    for kn in namn:
        rad = {}
        for typ in ("enh", "hdr"):
            for m in ("median", "klippt", "struktur"):
                v = [g["kand"][kn]["matt"][typ][m] for g in grupper
                     if (g["kand"].get(kn) or {}).get("matt", {}).get(typ) and g["kand"][kn]["matt"][typ].get(m) is not None]
                if v:
                    varst = min(v) if m in ("struktur", "median") else max(v)
                    rad[f"{typ}_{m}"] = {"median": statistics.median(v), "varst": varst, "n": len(v)}
        rad["gainEV"] = statistics.median([g["kand"][kn]["gainEV"] for g in grupper if g["kand"][kn].get("gainEV") is not None] or [0])
        sammanf[kn] = rad
    band = [g for g in grupper if (g.get("mork") or {}).get("band")]
    data = {"skapad": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "bas": bas_namn, "namn": namn,
            "beskrivning": beskr, "standard": a.standard, "sammanfattning": sammanf, "grupper": grupper,
            "takBand": len(band), "antal": len(grupper)}
    with open(sakra_mal(os.path.join(ut, "index.html")), "w", encoding="utf-8") as f:
        f.write(HTML.replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/")))
    with open(sakra_mal(os.path.join(ut, "summary.json")), "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in data.items() if k != "grupper"} | {
            "grupper": {g["id"]: {"kategori": g["kategori"], "mork": g.get("mork"),
                                  "kand": {kn: {"gainEV": kd.get("gainEV"), "matt": kd.get("matt")} for kn, kd in g["kand"].items()}}
                        for g in grupper}}, f, ensure_ascii=False, indent=1)
    shutil.rmtree(sakra_mal(os.path.join(ut, ".arbete")), ignore_errors=True)
    print(f"Klart: {os.path.join(ut, 'index.html')} ({len(grupper)} grupper med pull, p99-taket band i {len(band)})")
    for kn in namn:
        s = sammanf[kn]
        f = lambda k, x: f"{s[k][x]:.3f}" if k in s else "–"
        print(f"  {kn:12s} slutbild median {f('enh_median','median')} (lägst {f('enh_median','varst')}), "
              f"klippt {f('enh_klippt','median')} (värst {f('enh_klippt','varst')}), struktur {f('enh_struktur','median')} "
              f"(värst {f('enh_struktur','varst')}) | HDR median {f('hdr_median','median')}, klippt {f('hdr_klippt','varst')} värst, "
              f"struktur {f('hdr_struktur','varst')} värst | gain {s['gainEV']:+.2f} EV")


HTML = r'''<!doctype html>
<html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ljusare fönster</title>
<style>
:root{--bg:#f6f6f4;--kort:#fff;--text:#1d1d1f;--dim:#6b6b70;--linje:#d8d8d4;--acc:#2563eb;--bra:#15803d;--bra-bg:#dcfce7;--sam:#b91c1c;--sam-bg:#fee2e2;--chip:#ececE8}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#141416;--kort:#1f1f23;--text:#ececf0;--dim:#9a9aa3;--linje:#34343a;--acc:#60a5fa;--bra:#4ade80;--bra-bg:#14351f;--sam:#f87171;--sam-bg:#401818;--chip:#2c2c32}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header,main{max-width:1500px;margin:0 auto;padding:0 16px}
h1{margin:20px 0 4px;font-size:24px}h2{font-size:18px;margin:24px 0 8px}
.dim{color:var(--dim)}
table{border-collapse:collapse;width:100%}
th,td{text-align:right;padding:4px 8px;border-bottom:1px solid var(--linje);white-space:nowrap}
th:first-child,td:first-child{text-align:left}
.tabellram{overflow-x:auto;background:var(--kort);border:1px solid var(--linje);border-radius:8px}
td.ok{background:var(--bra-bg);color:var(--bra)}td.fel{background:var(--sam-bg);color:var(--sam)}
.kontroller{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:12px 0;position:sticky;top:0;background:var(--bg);padding:8px 0;z-index:5}
button{font:inherit;color:var(--text);background:var(--kort);border:1px solid var(--linje);border-radius:6px;padding:4px 10px;cursor:pointer}
button.aktiv{background:var(--acc);border-color:var(--acc);color:#fff}
.kort{background:var(--kort);border:1px solid var(--linje);border-radius:10px;padding:14px;margin:16px 0}
.kort h3{margin:0 0 6px;font-size:17px}
.chip{background:var(--chip);border-radius:99px;padding:1px 10px;font-size:13px;margin-right:6px}
.rad{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
.jamfor{flex:1 1 640px;min-width:0}
.reglage{position:relative;width:100%;overflow:hidden;user-select:none;touch-action:pan-y;cursor:ew-resize;background:#000;border-radius:6px}
.reglage img{display:block;width:100%;height:100%;position:absolute;inset:0;object-fit:fill}
.reglage .over{clip-path:inset(0 0 0 50%)}
.delare{position:absolute;top:0;bottom:0;width:3px;margin-left:-1px;background:#fff;box-shadow:0 0 4px #000;left:50%;pointer-events:none}
.etikett{position:absolute;top:8px;background:rgba(0,0,0,.6);color:#fff;padding:1px 8px;border-radius:4px;font-size:12px;pointer-events:none}
.etikett.v{left:8px}.etikett.h{right:8px}
.sidokolumn{flex:0 1 380px;min-width:260px}
.sidokolumn img{width:100%;border-radius:6px;display:block;cursor:zoom-in}
.utsnitt{display:grid;grid-template-columns:repeat(2,1fr);gap:6px;margin-top:10px}
.utsnitt figure{margin:0}.utsnitt figcaption{font-size:12px;color:var(--dim)}
.matt{margin-top:10px;font-size:13px}
#ljus{position:fixed;inset:0;background:rgba(0,0,0,.88);display:none;align-items:center;justify-content:center;z-index:50;cursor:zoom-out}
#ljus img{max-width:96vw;max-height:96vh}
@media (max-width:700px){.utsnitt{grid-template-columns:1fr}}
</style></head><body>
<header>
<h1>Ljusare fönster – kandidater</h1>
<div class="dim" id="meta"></div>
<h2>Sammanfattning (median över grupper med pull; värst inom parentes)</h2>
<div class="tabellram"><table id="summa"></table></div>
<div class="kontroller">
 <span>Efter:</span><span id="kandknappar"></span>
 <span class="dim">|</span>
 <button data-typ="enh" class="typ aktiv">Slutbild (efter Förbättra)</button><button data-typ="hdr" class="typ">HDR (före Förbättra)</button>
</div>
</header>
<main id="grupper"></main>
<div id="ljus"><img alt=""></div>
<script>
const D = __DATA__;
let kand = D.standard || D.namn[D.namn.length - 1], typ = "enh";
const pct = v => v == null ? "–" : (v * 100).toFixed(1).replace(".", ",") + " %";
const n2 = v => v == null ? "–" : v.toFixed(3).replace(".", ",");
const ev = v => v == null ? "–" : (v >= 0 ? "+" : "") + v.toFixed(2).replace(".", ",") + " EV";
document.getElementById("meta").textContent =
  `${D.antal} grupper med window pull · skapad ${D.skapad} · före = ${D.bas} · p99-taket (nuvarande) band i ${D.takBand} av ${D.antal}`;
function summa() {
  const s = D.sammanfattning;
  let h = "<tr><th>Kandidat</th><th>Fönstermedian slutbild</th><th>Klippt slutbild (mål < 2 %)</th><th>Struktur slutbild (≥ 0,8)</th><th>Fönstermedian HDR</th><th>Klippt HDR</th><th>Struktur HDR</th><th>Gain (median)</th><th>Beskrivning</th></tr>";
  for (const k of D.namn) {
    const r = s[k], c = (key, f, ok) => {
      const v = r[key]; if (!v) return "<td>–</td>";
      const cls = ok ? (ok(v.varst) ? "ok" : "fel") : "";
      return `<td class="${cls}">${f(v.median)} (${f(v.varst)})</td>`; };
    h += `<tr><td><b>${k}</b>${k === D.standard ? " ★ standard" : ""}${k === D.bas ? " (före)" : ""}</td>` +
      c("enh_median", n2) + c("enh_klippt", pct, v => v < 0.02) + c("enh_struktur", n2, v => v >= 0.8) +
      c("hdr_median", n2) + c("hdr_klippt", pct, v => v < 0.02) + c("hdr_struktur", n2, v => v >= 0.8) +
      `<td>${ev(r.gainEV)}</td><td style="text-align:left;white-space:normal">${D.beskrivning[k] || ""}</td></tr>`;
  }
  document.getElementById("summa").innerHTML = h;
}
function knappar() {
  const el = document.getElementById("kandknappar");
  el.innerHTML = D.namn.filter(k => k !== D.bas).map(k => `<button data-k="${k}" class="kand${k === kand ? " aktiv" : ""}">${k}</button>`).join(" ");
  el.querySelectorAll("button").forEach(b => b.onclick = () => { kand = b.dataset.k; knappar(); rita(); });
}
document.querySelectorAll("button.typ").forEach(b => b.onclick = () => {
  typ = b.dataset.typ; document.querySelectorAll("button.typ").forEach(x => x.classList.toggle("aktiv", x === b)); rita(); });
function reglage(el) {
  const over = el.querySelector(".over"), del = el.querySelector(".delare");
  const satt = x => { const r = el.getBoundingClientRect(); const f = Math.min(1, Math.max(0, (x - r.left) / r.width));
    over.style.clipPath = `inset(0 0 0 ${f * 100}%)`; del.style.left = f * 100 + "%"; };
  let drar = false;
  el.addEventListener("pointerdown", e => { drar = true; el.setPointerCapture(e.pointerId); satt(e.clientX); });
  el.addEventListener("pointermove", e => { if (drar) satt(e.clientX); });
  el.addEventListener("pointerup", () => drar = false);
}
function rita() {
  const main = document.getElementById("grupper");
  main.innerHTML = "";
  for (const g of D.grupper) {
    const b = g.kand[D.bas], k = g.kand[kand];
    const fore = b[typ], efter = k[typ];
    const mb = (b.matt || {})[typ] || {}, mk = (k.matt || {})[typ] || {};
    const m = g.mork || {};
    const kort = document.createElement("section");
    kort.className = "kort";
    let rader = "";
    for (const nn of D.namn) {
      const x = g.kand[nn], me = (x.matt || {}).enh || {}, mh = (x.matt || {}).hdr || {};
      rader += `<tr><td>${nn}</td><td>${n2(me.median)}</td><td class="${me.klippt < 0.02 ? "ok" : "fel"}">${pct(me.klippt)}</td>` +
        `<td class="${me.struktur >= 0.8 ? "ok" : "fel"}">${n2(me.struktur)}</td><td>${n2(mh.median)}</td><td>${pct(mh.klippt)}</td><td>${n2(mh.struktur)}</td><td>${ev(x.gainEV)}</td></tr>`;
    }
    kort.innerHTML = `<h3>${g.id} <span class="dim">${g.filer.join(", ")}</span></h3>
      <div><span class="chip">${g.kategori}</span>${m.band ? '<span class="chip">p99-taket band (nuvarande)</span>' : ""}
      <span class="dim">mörk ram: median ${n2(m.median)}, p99 ${n2(m.p99)}, gain mot mål ${ev(m.malEV)}, tak ${ev(m.takEV)}</span></div>
      <div class="rad"><div class="jamfor">
        <div class="reglage" style="aspect-ratio:${g.w}/${g.h}">
          <img src="${fore || ""}" alt="före"><img class="over" src="${efter || ""}" alt="efter">
          <div class="delare"></div><span class="etikett v">före: ${D.bas}</span><span class="etikett h">efter: ${kand}</span>
        </div></div>
        <div class="sidokolumn">
          <div class="dim">Mörk ram (rå, registrerad)</div>${g.bilder.dark ? `<img src="${g.bilder.dark}" alt="mörk ram">` : ""}
          <div class="utsnitt">
            <figure>${b["utsnitt_" + typ] ? `<img src="${b["utsnitt_" + typ]}" alt="">` : ""}<figcaption>100 % · ${D.bas}</figcaption></figure>
            <figure>${k["utsnitt_" + typ] ? `<img src="${k["utsnitt_" + typ]}" alt="">` : ""}<figcaption>100 % · ${kand}</figcaption></figure>
          </div>
        </div></div>
      <div class="matt tabellram"><table><tr><th>Kandidat</th><th>Median slutbild</th><th>Klippt slutbild</th><th>Struktur slutbild</th><th>Median HDR</th><th>Klippt HDR</th><th>Struktur HDR</th><th>Gain</th></tr>${rader}</table></div>`;
    main.appendChild(kort);
    reglage(kort.querySelector(".reglage"));
    kort.querySelectorAll(".sidokolumn img").forEach(im => im.onclick = () => {
      const l = document.getElementById("ljus"); l.querySelector("img").src = im.src; l.style.display = "flex"; });
  }
}
document.getElementById("ljus").onclick = e => e.currentTarget.style.display = "none";
summa(); knappar(); rita();
</script></body></html>
'''

if __name__ == "__main__":
    main()
