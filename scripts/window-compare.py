#!/usr/bin/env python3
# scripts/window-compare.py -- statisk jämförelsesida för "window pull" i PhotoFlows HDR.
#
# Läser två körningar av `photoflow-cli run ... --hdr-debug` (--window-pull on respektive off),
# testsetet (kategorier) och eventuellt den levererade v2-HDR:en, och bygger en mapp med
# index.html (öppnas lokalt via file://), bilder, 100 %-utsnitt, maskoverlays och summary.json.
#
# Användning:
#   scripts/window-compare.py --on DIR --off DIR [--testset FIL] [--legacy-root DIR] [--out DIR]
#
# Bara standardbibliotek. Skalning/beskärning/formatbyte görs med `sips`; maskanalys och
# overlay-PNG med ett litet Swift-program som kompileras (swiftc) in i arbetsmappen under --out.
# ABSOLUT REGEL: ingenting skrivs någonstans under /Volumes/photo-ingestion/ (bara läsning).
import argparse
import datetime
import glob
import html
import json
import os
import re
import shutil
import statistics
import subprocess
import sys

FORBJUDET = "/Volumes/photo-ingestion"
LANGSIDA = 2000
UTSNITT_B, UTSNITT_H = 700, 450
KATEGORIER = [("fonster", "fönster"), ("rorelse", "rörelse"), ("exterior_lampor", "exteriör, lampor"), ("okand", "okänd")]

OUT_ROOT = None  # sätts i main(); alla skrivningar måste hamna under den


def sakra_mal(sokvag):
    """Assert: målvägen ligger under --out och aldrig under /Volumes/photo-ingestion."""
    p = os.path.realpath(os.path.abspath(sokvag))
    assert not (p == FORBJUDET or p.startswith(FORBJUDET + "/")), f"förbjuden målväg: {p}"
    assert OUT_ROOT and (p == OUT_ROOT or p.startswith(OUT_ROOT + os.sep)), f"målväg utanför --out: {p}"
    return p


def kor(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def las_json(p, standard=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return standard


# ---------- sips ----------
_dim_cache = {}


def dimensioner(p):
    if p in _dim_cache:
        return _dim_cache[p]
    r = kor(["sips", "-g", "pixelWidth", "-g", "pixelHeight", p])
    w = re.search(r"pixelWidth:\s*(\d+)", r.stdout)
    h = re.search(r"pixelHeight:\s*(\d+)", r.stdout)
    d = (int(w.group(1)), int(h.group(1))) if w and h else None
    _dim_cache[p] = d
    return d


def sips_jpeg(src, dst, langsida=None, kvalitet=85):
    """Konverterar/skalar src till JPEG (skalar bara ner)."""
    dst = sakra_mal(dst)
    cmd = ["sips"]
    d = dimensioner(src)
    if langsida and d and max(d) > langsida:
        cmd += ["-Z", str(langsida)]
    cmd += [src, "-s", "format", "jpeg", "-s", "formatOptions", str(kvalitet), "--out", dst]
    r = kor(cmd)
    return r.returncode == 0 and os.path.exists(dst)


def sips_utsnitt(src, dst, x0, y0, b, h, uppskala_till=None):
    dst = sakra_mal(dst)
    r = kor(["sips", "-c", str(h), str(b), "--cropOffset", str(y0), str(x0), src,
             "-s", "format", "jpeg", "-s", "formatOptions", "90", "--out", dst])
    if r.returncode != 0 or not os.path.exists(dst):
        return False
    if uppskala_till:
        ub, uh = uppskala_till
        r = kor(["sips", "-z", str(uh), str(ub), dst, "-s", "format", "jpeg", "-s", "formatOptions", "90", "--out", dst])
        return r.returncode == 0
    return True


# ---------- Swift-hjälpare (maskanalys + overlay) ----------
SWIFT_KALLA = r'''
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Läser jobb (JSON-lista) från argv[1]; skriver JSON-resultat till stdout.
// Jobb: {mask, overlay, maskOut, langsida}. Resultat: {mask, tomt, punkter:[{x,y,art,poang}], bredd, hojd}.
func gra(_ path: String) -> (Int, Int, [UInt8])? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let im = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    let w = im.width, h = im.height
    var buf = [UInt8](repeating: 0, count: w * h)
    let ok: Bool = buf.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        c.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
    }
    return ok ? (w, h, buf) : nil
}

func skriv(_ im: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, im, nil); CGImageDestinationFinalize(d)
}

func skalad(_ src: [UInt8], _ w: Int, _ h: Int, _ w2: Int, _ h2: Int) -> [UInt8] {
    var tmp = src
    var out = [UInt8](repeating: 0, count: w2 * h2)
    tmp.withUnsafeMutableBytes { raw in
        guard let c0 = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let im = c0.makeImage() else { return }
        out.withUnsafeMutableBytes { r2 in
            guard let c = CGContext(data: r2.baseAddress, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            c.interpolationQuality = .high
            c.draw(im, in: CGRect(x: 0, y: 0, width: w2, height: h2))
        }
    }
    return out
}

func analysera(_ w: Int, _ h: Int, _ m: [UInt8]) -> [[String: Any]] {
    var lab = [Int32](repeating: 0, count: w * h)
    var areor: [Int] = [0]
    var stack: [Int] = []
    for i in 0..<(w * h) where m[i] >= 128 && lab[i] == 0 {
        let id = Int32(areor.count); areor.append(0); lab[i] = id; stack.append(i)
        while let p = stack.popLast() {
            areor[Int(id)] += 1
            let x = p % w, y = p / w
            if x > 0, m[p - 1] >= 128, lab[p - 1] == 0 { lab[p - 1] = id; stack.append(p - 1) }
            if x < w - 1, m[p + 1] >= 128, lab[p + 1] == 0 { lab[p + 1] = id; stack.append(p + 1) }
            if y > 0, m[p - w] >= 128, lab[p - w] == 0 { lab[p - w] = id; stack.append(p - w) }
            if y < h - 1, m[p + w] >= 128, lab[p + w] == 0 { lab[p + w] = id; stack.append(p + w) }
        }
    }
    let totalt = areor.reduce(0, +)
    if totalt < 30 { return [] }
    // De tre största områdena
    let topp = (1..<areor.count).sorted { areor[$0] > areor[$1] }.prefix(3).filter { areor[$0] >= 20 }
    let tillat = Set(topp.map { Int32($0) })
    // Kantmarkeringar: lodrät (vänster/höger kant) och vågrät (över-/underkant)
    var vm = [UInt8](repeating: 0, count: w * h), hm = [UInt8](repeating: 0, count: w * h)
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let p = y * w + x, l = lab[p]
        if l == 0 || !tillat.contains(l) { continue }
        if lab[p - 1] != l || lab[p + 1] != l { vm[p] = 1 }
        if lab[p - w] != l || lab[p + w] != l { hm[p] = 1 }
    } }
    // Poäng = antal kantpixlar i ett smalt band (±2) längs kanten, ±fönster
    let f = max(8, min(w, h) / 25)
    var kand: [(Int, Int, Int, String)] = []
    // lodrät: prefix över y per kolumn
    var pre = [Int32](repeating: 0, count: (h + 1) * w)
    for y in 0..<h { for x in 0..<w { pre[(y + 1) * w + x] = pre[y * w + x] + Int32(vm[y * w + x]) } }
    for y in 0..<h { for x in 0..<w where vm[y * w + x] == 1 {
        let a = max(0, y - f), b = min(h, y + f + 1); var s = 0
        for xx in max(0, x - 2)...min(w - 1, x + 2) { s += Int(pre[b * w + xx] - pre[a * w + xx]) }
        kand.append((s, x, y, "lodrat"))
    } }
    var preH = [Int32](repeating: 0, count: h * (w + 1))
    for y in 0..<h { for x in 0..<w { preH[y * (w + 1) + x + 1] = preH[y * (w + 1) + x] + Int32(hm[y * w + x]) } }
    for y in 0..<h { for x in 0..<w where hm[y * w + x] == 1 {
        let a = max(0, x - f), b = min(w, x + f + 1); var s = 0
        for yy in max(0, y - 2)...min(h - 1, y + 2) { s += Int(preH[yy * (w + 1) + b] - preH[yy * (w + 1) + a]) }
        kand.append((s, x, y, "vagrat"))
    } }
    kand.sort { $0.0 > $1.0 }
    guard let a = kand.first, a.0 >= 5 else { return [] }
    let minAvst = 0.15 * Double(max(w, h))
    func avst(_ p: (Int, Int, Int, String)) -> Double { hypot(Double(p.1 - a.1), Double(p.2 - a.2)) }
    var b = kand.first { $0.3 != a.3 && $0.0 >= 5 && avst($0) >= minAvst }
    if b == nil { b = kand.first { $0.0 >= 5 && avst($0) >= minAvst } }
    var res: [[String: Any]] = [["x": Double(a.1) / Double(w), "y": Double(a.2) / Double(h), "art": a.3, "poang": a.0]]
    if let b = b { res.append(["x": Double(b.1) / Double(w), "y": Double(b.2) / Double(h), "art": b.3, "poang": b.0]) }
    return res
}

let jobb = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))) as? [[String: Any]] ?? []
var alla: [[String: Any]] = []
for j in jobb {
    let mp = j["mask"] as! String
    var r: [String: Any] = ["mask": mp]
    guard let (w, h, m) = gra(mp) else { r["fel"] = "kunde inte läsa"; alla.append(r); continue }
    r["bredd"] = w; r["hojd"] = h
    let punkter = analysera(w, h, m)
    r["punkter"] = punkter
    r["tomt"] = punkter.isEmpty
    if !punkter.isEmpty {
        let ls = j["langsida"] as? Int ?? 2000
        let s = Double(ls) / Double(max(w, h))
        let w2 = max(1, Int((Double(w) * s).rounded())), h2 = max(1, Int((Double(h) * s).rounded()))
        let m2 = skalad(m, w, h, w2, h2)
        var rgba = [UInt8](repeating: 0, count: w2 * h2 * 4)
        for i in 0..<(w2 * h2) {
            let a = Double(m2[i]) / 255.0 * 0.55
            rgba[i * 4] = UInt8(255.0 * a); rgba[i * 4 + 1] = UInt8(30.0 * a); rgba[i * 4 + 2] = UInt8(30.0 * a); rgba[i * 4 + 3] = UInt8(255.0 * a)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { raw in
            if let c = CGContext(data: raw.baseAddress, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2 * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let im = c.makeImage() { skriv(im, j["overlay"] as! String) }
        }
        var g2 = m2
        g2.withUnsafeMutableBytes { raw in
            if let c = CGContext(data: raw.baseAddress, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let im = c.makeImage() { skriv(im, j["maskOut"] as! String) }
        }
        r["overlayBredd"] = w2; r["overlayHojd"] = h2
    }
    alla.append(r)
}
let d = try! JSONSerialization.data(withJSONObject: alla)
FileHandle.standardOutput.write(d)
'''


def kor_swift(jobb, arbetsmapp):
    arbetsmapp = sakra_mal(arbetsmapp)
    os.makedirs(arbetsmapp, exist_ok=True)
    kalla = os.path.join(arbetsmapp, "maskhjalp.swift")
    binar = os.path.join(arbetsmapp, "maskhjalp")
    jobbfil = os.path.join(arbetsmapp, "jobb.json")
    for p in (kalla, binar, jobbfil):
        sakra_mal(p)
    with open(kalla, "w", encoding="utf-8") as f:
        f.write(SWIFT_KALLA)
    with open(jobbfil, "w", encoding="utf-8") as f:
        json.dump(jobb, f)
    c = kor(["swiftc", "-O", kalla, "-o", binar])
    if c.returncode == 0:
        r = kor([binar, jobbfil])
    else:
        print("  swiftc misslyckades, provar `swift` (långsammare):", c.stderr.strip()[:200])
        r = kor(["swift", kalla, jobbfil])
    if r.returncode != 0:
        print("  Swift-hjälparen misslyckades:", r.stderr.strip()[:400])
        return []
    return json.loads(r.stdout)


# ---------- indata ----------
def indexera_hdr(rot):
    """Index {filnamn: sökväg} över hdr_group_*-filer, rekursivt (utan hdr_debug/hdr_masks)."""
    idx = {}
    for d, dirs, files in os.walk(rot):
        dirs[:] = [x for x in dirs if x not in ("hdr_debug", "hdr_masks")]
        for fn in files:
            if fn.startswith("hdr_group_") and fn.lower().endswith((".jpg", ".jpeg", ".tif", ".tiff")):
                idx.setdefault(fn, os.path.join(d, fn))
    return idx


def hitta(idx, gnamn, tiff):
    for ext in ((".tiff", ".tif") if tiff else (".jpg", ".jpeg")):
        if gnamn + ext in idx:
            return idx[gnamn + ext]
    return None


def las_korning(rot):
    rot = os.path.abspath(os.path.expanduser(rot))
    bg = las_json(os.path.join(rot, "bracket_groups.json"), {}) or {}
    hdr = las_json(os.path.join(rot, "hdr.json"), {}) or {}
    grupper = {}
    for g in bg.get("groups", []):
        grupper[g["group_id"]] = g
    poster = {}
    for namn, e in (hdr.get("entries") or {}).items():
        m = re.match(r"hdr_group_(\d+)$", namn)
        if not m:
            continue
        gid = int(m.group(1))
        filer = (grupper.get(gid) or {}).get("files") or e.get("frames") or []
        poster[gid] = {"namn": namn, "entry": e, "files": frozenset(filer), "filer": list(filer),
                       "grupp": grupper.get(gid) or {}}
    return {"rot": rot, "poster": poster, "idx": indexera_hdr(rot)}


def matcha(filer, kandidater):
    """kandidater: {id: frozenset}. Exakt filmängd först, sedan störst överlapp (Jaccard >= 0,5)."""
    for k, v in kandidater.items():
        if v == filer:
            return k
    bast, bv = None, 0.0
    for k, v in kandidater.items():
        u = len(filer | v)
        j = len(filer & v) / u if u else 0
        if j > bv:
            bast, bv = k, j
    return bast if bv >= 0.5 else None


def hitta_legacy(legacy_root, orig_id, adress):
    if not legacy_root or orig_id is None or not os.path.isdir(legacy_root):
        return None
    namn = f"hdr_group_{orig_id}.jpg"
    for kand in (os.path.join(legacy_root, "hdr", namn),
                 os.path.join(legacy_root, f"{adress} TITTBILDER", namn) if adress else None):
        if kand and os.path.isfile(kand):
            return kand
    traffar = glob.glob(os.path.join(glob.escape(legacy_root), "* TITTBILDER", namn))
    return traffar[0] if len(traffar) == 1 else None


# ---------- mått ----------
def sida(m, nyckel, vilken):
    v = (m or {}).get(nyckel)
    if isinstance(v, dict):
        v = v.get(vilken)
    elif vilken == "utan":
        v = None
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


# (nyckel, etikett, format, riktning, mål, måltext)
MATT = [
    ("clippedInMask", "Klippt i mask", "pct", "lagre", 0.02, "< 2 %"),
    ("structureVsDark", "Struktur vs mörk ram", "n2", "hogre", 0.8, "≥ 0,8"),
    ("lumaSpread", "Lumaspridning", "n3", None, None, ""),
    ("chroma", "Kroma", "n3", None, None, ""),
    ("pullHaloWidthPx", "Pullens halo utanför masken (px)", "n1", "lagre", 8, "< 8 px"),
    ("haloWidthPx", "Halobredd mot referensramen (px, grovt)", "n1", None, None, ""),
    ("haloAmplitude", "Haloamplitud", "n3", None, None, ""),
    ("residualShiftPx", "Kvarvarande förskjutning (px)", "n2", "lagre_lika", 1, "≤ 1 px"),
    ("seconds", "Tid per grupp (s)", "n1", None, None, ""),
    ("pullSeconds", "Pull-tid, extra (s)", "n2", "lagre", 2.5, "< 2,5 s"),
]


def bra(v, rikt, mal):
    if v is None or rikt is None:
        return None
    if rikt == "lagre":
        return v < mal
    if rikt == "lagre_lika":
        return v <= mal
    return v >= mal


def matt_for_grupp(m_on, sek_off):
    rader = []
    for nyckel, etikett, fmt, rikt, mal, maltext in MATT:
        if nyckel == "seconds":
            med, utan = sida(m_on, "seconds", "med"), sek_off
        elif nyckel == "pullHaloWidthPx":
            v = (m_on or {}).get(nyckel)
            med, utan = (v if isinstance(v, (int, float)) else None), None
        elif nyckel == "pullSeconds":
            med, utan = sida(m_on, "pullSeconds", "med"), None
        elif nyckel == "residualShiftPx":
            med, utan = sida(m_on, nyckel, "withPull"), sida(m_on, nyckel, "withoutPull")
            if med is None:
                med = (m_on or {}).get(nyckel) if isinstance((m_on or {}).get(nyckel), (int, float)) else None
        else:
            med, utan = sida(m_on, nyckel, "withPull"), sida(m_on, nyckel, "withoutPull")
        rader.append({"nyckel": nyckel, "etikett": etikett, "fmt": fmt, "mal": maltext,
                      "med": med, "utan": utan, "medOk": bra(med, rikt, mal), "utanOk": bra(utan, rikt, mal)})
    return rader


def sammanfatta(grupper):
    """Median och värsta fall över grupper där pull kördes."""
    ut = []
    for i, (nyckel, etikett, fmt, rikt, mal, maltext) in enumerate(MATT):
        rad = {"nyckel": nyckel, "etikett": etikett, "fmt": fmt, "mal": maltext}
        for sidan, fält in (("med", "med"), ("utan", "utan")):
            vals = [g["matt"][i][fält] for g in grupper if g["applied"] and g["matt"][i][fält] is not None]
            if vals:
                varst = min(vals) if rikt == "hogre" else max(vals)
                rad[sidan] = {"median": statistics.median(vals), "varst": varst, "n": len(vals),
                              "medianOk": bra(statistics.median(vals), rikt, mal), "varstOk": bra(varst, rikt, mal)}
            else:
                rad[sidan] = None
        ut.append(rad)
    return ut


# ---------- HTML ----------
def bygg_html(data):
    mall = HTML_MALL
    js = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    return mall.replace("__DATA__", js)


def main():
    global OUT_ROOT
    ap = argparse.ArgumentParser(description="Bygger jämförelsesida för window pull.")
    ap.add_argument("--on", required=True, help="outputmapp från körning med --window-pull on --hdr-debug")
    ap.add_argument("--off", required=True, help="outputmapp från körning med --window-pull off")
    ap.add_argument("--testset", default="~/PhotoFlowBenchmark/windows/testset.json")
    ap.add_argument("--legacy-root", default="/Volumes/photo-ingestion/PhotoFlow/output")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    ut = a.out or f"~/PhotoFlowBenchmark/results/windows-{datetime.date.today().isoformat()}/"
    ut = os.path.realpath(os.path.abspath(os.path.expanduser(ut)))
    assert not (ut == FORBJUDET or ut.startswith(FORBJUDET + "/")), "--out får inte ligga under /Volumes/photo-ingestion"
    OUT_ROOT = ut
    for sub in ("images", "crops", ".arbete"):
        os.makedirs(sakra_mal(os.path.join(ut, sub)), exist_ok=True)

    on = las_korning(a.on)
    off = las_korning(a.off)
    testset = las_json(os.path.expanduser(a.testset), []) or []
    ts_kand = {i: frozenset(t.get("files", [])) for i, t in enumerate(testset)}
    legacy_root = os.path.expanduser(a.legacy_root) if a.legacy_root else None
    print(f"På: {len(on['poster'])} grupper, av: {len(off['poster'])} grupper, testset: {len(testset)} poster")
    off_kand = {gid: p["files"] for gid, p in off["poster"].items()}

    grupper = []
    maskjobb = []
    for gid in sorted(on["poster"]):
        p = on["poster"][gid]
        gnamn = p["namn"]
        dbg = os.path.join(on["rot"], "hdr_debug", gnamn)
        m = las_json(os.path.join(dbg, "hdr_metrics.json"))
        e = p["entry"]
        fonster = (m or {}).get("window") or e.get("window") or {}
        ti = matcha(p["files"], ts_kand)
        t = testset[ti] if ti is not None else {}
        kat = t.get("category") or "okand"
        if kat not in dict(KATEGORIER):
            kat = "okand"
        oid = matcha(p["files"], off_kand)
        off_p = off["poster"].get(oid) if oid is not None else None
        sek_off = (off_p["entry"].get("seconds") if off_p else None)
        filer = sorted(p["filer"])
        ar = {
            "id": gnamn, "gid": gid, "category": kat,
            "filnamn": (filer[0].rsplit(".", 1)[0] + "–" + filer[-1].rsplit(".", 1)[0]) if len(filer) > 1 else (filer[0] if filer else gnamn),
            "files": filer, "frames": e.get("frames") or [], "windowSource": e.get("windowSource") or (m or {}).get("windowSource"),
            "applied": bool(fonster.get("applied")), "reason": fonster.get("reason"),
            "gainEV": fonster.get("gainEV"), "maskFraction": fonster.get("maskFraction", (m or {}).get("maskFraction")),
            "origId": t.get("group_id"), "adress": t.get("adress"),
            "komponenter": [], "matt": matt_for_grupp(m, sek_off),
            "bilder": {}, "utsnitt": [], "harMetrics": m is not None,
        }
        for c in (m or {}).get("components") or []:
            ar["komponenter"].append({"verdict": c.get("verdict"), "fraction": c.get("fraction")})

        # --- bilder ---
        gk = f"g{gid}"
        b = ar["bilder"]
        jpg_on = hitta(on["idx"], gnamn, False)
        jpg_off = hitta(off["idx"], off_p["namn"], False) if off_p else None
        for nyckel, kalla in (("on", jpg_on), ("off", jpg_off), ("dark", os.path.join(dbg, "dark_raw.jpg"))):
            if kalla and os.path.isfile(kalla):
                dst = os.path.join(ut, "images", f"{gk}_{nyckel}.jpg")
                if sips_jpeg(kalla, dst, LANGSIDA):
                    b[nyckel] = f"images/{gk}_{nyckel}.jpg"
                    d = dimensioner(dst)
                    if d:
                        b["w"], b["h"] = d
        lg = hitta_legacy(legacy_root, t.get("group_id"), t.get("adress"))
        if lg:
            dst = os.path.join(ut, "images", f"{gk}_legacy.jpg")
            if sips_jpeg(lg, dst, LANGSIDA):
                b["legacy"] = f"images/{gk}_legacy.jpg"
        maskf = os.path.join(dbg, "mask.png")
        if os.path.isfile(maskf):
            maskjobb.append({"mask": maskf, "overlay": sakra_mal(os.path.join(ut, "images", f"{gk}_overlay.png")),
                             "maskOut": sakra_mal(os.path.join(ut, "images", f"{gk}_mask.png")), "langsida": LANGSIDA, "_g": len(grupper)})
        ar["_tiff_on"] = hitta(on["idx"], gnamn, True) or jpg_on
        ar["_tiff_off"] = (hitta(off["idx"], off_p["namn"], True) or jpg_off) if off_p else None
        ar["_dbg"] = dbg
        grupper.append(ar)
        print(f"  {gnamn}: kategori {kat}, pull {'ja' if ar['applied'] else 'nej'}")

    # --- masker: analys och overlays ---
    if maskjobb:
        res = kor_swift([{k: v for k, v in j.items() if k != "_g"} for j in maskjobb], os.path.join(ut, ".arbete"))
        for j, r in zip(maskjobb, res):
            g = grupper[j["_g"]]
            if r.get("tomt", True):
                continue
            gk = f"g{g['gid']}"
            g["bilder"]["overlay"] = f"images/{gk}_overlay.png"
            g["bilder"]["mask"] = f"images/{gk}_mask.png"
            # --- 100 %-utsnitt ---
            dark = os.path.join(g["_dbg"], "dark_raw.jpg")
            for n, pt in enumerate(r["punkter"][:2], 1):
                u = {"x": pt["x"], "y": pt["y"], "art": pt["art"], "n": n}
                for nyckel, kalla in (("off", g["_tiff_off"]), ("on", g["_tiff_on"]), ("dark", dark if os.path.isfile(dark) else None)):
                    if not kalla:
                        continue
                    d = dimensioner(kalla)
                    if not d:
                        continue
                    bf, hf = d
                    ref = dimensioner(g["_tiff_on"] or kalla) or d
                    # Utsnittsposition i fullupplösning (enligt on-körningens TIFF), omräknad till källans storlek.
                    s = bf / ref[0]
                    cb, ch = round(UTSNITT_B * s), round(UTSNITT_H * s)
                    x0 = max(0, min(bf - cb, round(pt["x"] * bf - cb / 2)))
                    y0 = max(0, min(hf - ch, round(pt["y"] * hf - ch / 2)))
                    dst = os.path.join(ut, "crops", f"{gk}_{n}_{nyckel}.jpg")
                    upp = (UTSNITT_B, UTSNITT_H) if cb != UTSNITT_B else None
                    if sips_utsnitt(kalla, dst, x0, y0, cb, ch, upp):
                        u[nyckel] = f"crops/{gk}_{n}_{nyckel}.jpg"
                        if nyckel == "dark" or s != 1:
                            u[nyckel + "Pct"] = round(s * 100)
                g["utsnitt"].append(u)

    for g in grupper:
        for k in ("_tiff_on", "_tiff_off", "_dbg"):
            g.pop(k, None)
    kat_antal = {k: sum(1 for g in grupper if g["category"] == k) for k, _ in KATEGORIER}
    sammanf = sammanfatta(grupper)
    run_id = os.path.basename(ut.rstrip("/"))
    data = {"runId": run_id, "skapad": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "kategorier": KATEGORIER,
            "katAntal": kat_antal, "sammanfattning": sammanf, "grupper": grupper,
            "antalPull": sum(1 for g in grupper if g["applied"])}
    with open(sakra_mal(os.path.join(ut, "index.html")), "w", encoding="utf-8") as f:
        f.write(bygg_html(data))

    # summary.json
    sj = {"skapad": data["skapad"], "antalGrupper": len(grupper), "antalPullKord": data["antalPull"],
          "grupperPerKategori": kat_antal,
          "sammanfattning": {r["nyckel"]: {"etikett": r["etikett"], "mal": r["mal"], "med": r["med"], "utan": r["utan"]} for r in sammanf},
          "grupper": {g["id"]: {"kategori": g["category"], "filer": g["filnamn"], "pullKord": g["applied"], "orsak": g["reason"],
                                "fonsterkalla": g["windowSource"], "gainEV": g["gainEV"], "maskandel": g["maskFraction"],
                                "komponenter": [c["verdict"] for c in g["komponenter"]],
                                "matt": {r["nyckel"]: {"med": r["med"], "utan": r["utan"], "medOk": r["medOk"]} for r in g["matt"]}}
                      for g in grupper}}
    with open(sakra_mal(os.path.join(ut, "summary.json")), "w", encoding="utf-8") as f:
        json.dump(sj, f, ensure_ascii=False, indent=1)
    shutil.rmtree(sakra_mal(os.path.join(ut, ".arbete")), ignore_errors=True)
    print(f"Klart: {os.path.join(ut, 'index.html')}  ({len(grupper)} grupper, pull kördes i {data['antalPull']})")


HTML_MALL = r'''<!doctype html>
<html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Window pull – jämförelse</title>
<style>
:root{--bg:#f6f6f4;--kort:#fff;--text:#1d1d1f;--dim:#6b6b70;--linje:#d8d8d4;--acc:#2563eb;--bra:#15803d;--bra-bg:#dcfce7;--sam:#b91c1c;--sam-bg:#fee2e2;--chip:#ececE8}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--kort:#1f1f23;--text:#ececf0;--dim:#9a9aa3;--linje:#34343a;--acc:#60a5fa;--bra:#4ade80;--bra-bg:#14351f;--sam:#f87171;--sam-bg:#401818;--chip:#2c2c32}}
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
button,.knapp{font:inherit;color:var(--text);background:var(--kort);border:1px solid var(--linje);border-radius:6px;padding:4px 10px;cursor:pointer}
button.aktiv{background:var(--acc);border-color:var(--acc);color:#fff}
button.bra.aktiv{background:var(--bra);border-color:var(--bra);color:#fff}
button.sam.aktiv{background:var(--sam);border-color:var(--sam);color:#fff}
.kort{background:var(--kort);border:1px solid var(--linje);border-radius:10px;padding:14px;margin:16px 0}
.kort h3{margin:0 0 6px;font-size:17px}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 10px}
.chip{background:var(--chip);border-radius:99px;padding:1px 10px;font-size:13px}
.rad{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
.jamfor{flex:1 1 640px;min-width:0}
.reglage{position:relative;width:100%;overflow:hidden;user-select:none;touch-action:pan-y;cursor:ew-resize;background:#000;border-radius:6px}
.reglage img{display:block;width:100%;height:100%;position:absolute;inset:0;object-fit:fill}
.reglage .over{clip-path:inset(0 0 0 50%)}
.reglage .ov{pointer-events:none;display:none}
.reglage.maskpa .ov{display:block}
.delare{position:absolute;top:0;bottom:0;width:3px;margin-left:-1px;background:#fff;box-shadow:0 0 4px #000;left:50%;pointer-events:none}
.delare::after{content:"↔";position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);background:#fff;color:#000;border-radius:50%;width:26px;height:26px;text-align:center;line-height:26px;box-shadow:0 0 4px #000}
.etikett{position:absolute;top:8px;background:rgba(0,0,0,.6);color:#fff;padding:1px 8px;border-radius:4px;font-size:12px;pointer-events:none}
.etikett.v{left:8px}.etikett.h{right:8px}
.sidokolumn{flex:0 1 360px;min-width:260px}
.sidokolumn img.mini{width:100%;border-radius:6px;cursor:zoom-in;display:block}
.verktyg{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0}
.utsnitt{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:12px}
.utsnitt figure{margin:0}.utsnitt img{width:100%;display:block;border-radius:4px;background:#000;cursor:zoom-in}
.utsnitt figcaption{font-size:12px;color:var(--dim)}
.matt{margin-top:10px;font-size:13px}
.bedom{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:12px}
.bedom textarea{flex:1 1 260px;min-height:34px;font:inherit;background:var(--bg);color:var(--text);border:1px solid var(--linje);border-radius:6px;padding:4px 8px}
#ljus{position:fixed;inset:0;background:rgba(0,0,0,.88);display:none;align-items:center;justify-content:center;z-index:50;cursor:zoom-out}
#ljus img{max-width:96vw;max-height:96vh}
@media (max-width:700px){.utsnitt{grid-template-columns:1fr}}
</style></head><body>
<header>
<h1>Window pull – jämförelse</h1>
<div class="dim" id="meta"></div>
<h2>Sammanfattning</h2>
<div id="katsammanfattning" class="chips"></div>
<div class="tabellram"><table id="sammanTabell"></table></div>
<p class="dim" id="sammanNot"></p>
</header>
<main>
<div class="kontroller" id="kontroller"></div>
<div id="kort"></div>
</main>
<div id="ljus"><img alt=""></div>
<script>
"use strict";
const DATA = __DATA__;
const NYCKEL = "windowpull:" + DATA.runId + ":";
const $ = (s, r) => (r || document).querySelector(s);
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const katNamn = {}; DATA.kategorier.forEach(k => katNamn[k[0]] = k[1]);
function lasLagring(k){ try { return JSON.parse(localStorage.getItem(NYCKEL + k) || "null"); } catch (e) { return null; } }
function skrivLagring(k, v){ try { localStorage.setItem(NYCKEL + k, JSON.stringify(v)); } catch (e) {} }
function fmt(v, f){
  if (v == null || isNaN(v)) return "–";
  if (f === "pct") return (v * 100).toFixed(2).replace(".", ",") + " %";
  const d = {n1:1, n2:2, n3:3}[f] || 2;
  return v.toFixed(d).replace(".", ",");
}
function cls(ok){ return ok === true ? "ok" : ok === false ? "fel" : ""; }

// ---- sammanfattning ----
$("#meta").textContent = "Körning " + DATA.runId + " · skapad " + DATA.skapad + " · " + DATA.grupper.length + " grupper, pull kördes i " + DATA.antalPull;
$("#katsammanfattning").innerHTML = DATA.kategorier.map(k => '<span class="chip">' + esc(k[1]) + ": " + (DATA.katAntal[k[0]] || 0) + "</span>").join("");
(function(){
  let h = "<tr><th>Mått</th><th>Mål</th><th>Utan pull: median</th><th>Utan: värsta</th><th>Med pull: median</th><th>Med: värsta</th></tr>";
  DATA.sammanfattning.forEach(r => {
    const u = r.utan, m = r.med;
    h += "<tr><td>" + esc(r.etikett) + "</td><td>" + esc(r.mal || "–") + "</td>" +
      "<td class='" + cls(u && u.medianOk) + "'>" + (u ? fmt(u.median, r.fmt) : "–") + "</td>" +
      "<td class='" + cls(u && u.varstOk) + "'>" + (u ? fmt(u.varst, r.fmt) : "–") + "</td>" +
      "<td class='" + cls(m && m.medianOk) + "'>" + (m ? fmt(m.median, r.fmt) : "–") + "</td>" +
      "<td class='" + cls(m && m.varstOk) + "'>" + (m ? fmt(m.varst, r.fmt) : "–") + "</td></tr>";
  });
  $("#sammanTabell").innerHTML = h;
  $("#sammanNot").textContent = "Median och värsta fall räknas över de " + DATA.antalPull + " grupper där pull kördes. Värsta fall = högsta värdet (lägsta för struktur). \"Tid per grupp\" är hela HDR-steget (med respektive utan pull); pull-tiden är merkostnaden.";
})();

// ---- filter ----
const filter = {kat: "alla", bara: false};
function byggKontroller(){
  const k = $("#kontroller");
  let h = '<button data-kat="alla" class="aktiv">Alla (' + DATA.grupper.length + ')</button>';
  DATA.kategorier.forEach(c => { if (DATA.katAntal[c[0]]) h += '<button data-kat="' + c[0] + '">' + esc(c[1]) + " (" + DATA.katAntal[c[0]] + ")</button>"; });
  h += '<label><input type="checkbox" id="barapull"> visa bara grupper där pull kördes</label>';
  h += '<span style="flex:1"></span><span id="raknare" class="chip"></span><button id="exportera">Exportera bedömningar (JSON)</button>';
  k.innerHTML = h;
  k.addEventListener("click", e => {
    const b = e.target.closest("button[data-kat]"); if (!b) return;
    filter.kat = b.dataset.kat; k.querySelectorAll("button[data-kat]").forEach(x => x.classList.toggle("aktiv", x === b)); visa();
  });
  $("#barapull").addEventListener("change", e => { filter.bara = e.target.checked; visa(); });
  $("#exportera").addEventListener("click", exportera);
}
function visa(){
  document.querySelectorAll(".kort").forEach(el => {
    const g = el._g;
    el.style.display = ((filter.kat === "alla" || g.category === filter.kat) && (!filter.bara || g.applied)) ? "" : "none";
  });
}
function raknaOm(){
  let b = 0, s = 0, l = 0;
  DATA.grupper.forEach(g => { const v = lasLagring(g.id); if (v && v.verdict === "battre") b++; else if (v && v.verdict === "samre") s++; else if (v && v.verdict === "lika") l++; });
  $("#raknare").textContent = "Bättre " + b + " · Sämre " + s + " · Lika " + l + " · av " + DATA.grupper.length;
}
function exportera(){
  const ut = {};
  DATA.grupper.forEach(g => { const v = lasLagring(g.id); if (v && (v.verdict || v.comment)) ut[g.id] = {verdict: v.verdict || null, comment: v.comment || "", category: g.category}; });
  const blob = new Blob([JSON.stringify(ut, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "bedomningar-" + DATA.runId + ".json";
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---- kort ----
function kortHtml(g){
  const b = g.bilder, ratio = (b.w && b.h) ? b.w + " / " + b.h : "3 / 2";
  const beslut = {}; g.komponenter.forEach(c => { beslut[c.verdict || "?"] = (beslut[c.verdict || "?"] || 0) + 1; });
  const beslutTxt = Object.keys(beslut).map(k => beslut[k] + " " + k).join(", ") || "inga komponenter";
  let h = "<h3>" + esc(katNamn[g.category]) + " · " + esc(g.filnamn) + ' <span class="dim">(' + esc(g.id) + ")</span></h3>";
  h += '<div class="chips"><span class="chip">pull: ' + (g.applied ? "kördes" : "kördes inte" + (g.reason ? " (" + esc(g.reason) + ")" : "")) + "</span>" +
    '<span class="chip">fönsterkälla: ' + esc(g.windowSource || "–") + "</span>" +
    '<span class="chip">gain: ' + (g.gainEV == null ? "–" : fmt(g.gainEV, "n2") + " EV") + "</span>" +
    '<span class="chip">maskandel: ' + (g.maskFraction == null ? "–" : fmt(g.maskFraction, "pct")) + "</span>" +
    '<span class="chip">komponenter: ' + esc(beslutTxt) + "</span>" +
    (g.origId != null ? '<span class="chip">original-id: ' + g.origId + "</span>" : "") + "</div>";
  h += '<div class="rad"><div class="jamfor">';
  if (b.on && (b.off || b.legacy)) {
    h += '<div class="reglage" style="aspect-ratio:' + ratio + '">' +
      '<img class="under" loading="lazy" src="' + esc(b.off || b.legacy) + '" alt="utan pull">' +
      '<img class="over" loading="lazy" src="' + esc(b.on) + '" alt="med pull">' +
      (b.overlay ? '<img class="ov" loading="lazy" src="' + esc(b.overlay) + '" alt="mask">' : "") +
      '<div class="delare"></div><span class="etikett v under-etikett">utan pull</span><span class="etikett h">med pull</span></div>';
    h += '<div class="verktyg">';
    if (b.off && b.legacy) h += '<button class="fore aktiv" data-fore="off">Före: off-körning</button><button class="fore" data-fore="legacy">Före: nuvarande v2</button>';
    if (b.overlay) h += '<button class="maskknapp">Maskoverlay: av</button>';
    h += "</div>";
  } else h += '<p class="dim">Bilder saknas för jämförelsen.</p>';
  h += "</div>";
  h += '<div class="sidokolumn">';
  if (b.dark) h += '<div class="dim">Mörkaste råbilden (klicka för stor)</div><img class="mini" loading="lazy" src="' + esc(b.dark) + '" data-stor="' + esc(b.dark) + '" alt="mörkaste exponeringen">';
  h += '<div class="matt"><div class="tabellram"><table><tr><th>Mått</th><th>Mål</th><th>Utan</th><th>Med</th></tr>';
  g.matt.forEach(r => { h += "<tr><td>" + esc(r.etikett) + "</td><td>" + esc(r.mal || "") + "</td><td class='" + cls(r.utanOk) + "'>" + fmt(r.utan, r.fmt) + "</td><td class='" + cls(r.medOk) + "'>" + fmt(r.med, r.fmt) + "</td></tr>"; });
  h += "</table></div></div></div></div>";
  if (g.utsnitt.length) {
    h += '<div class="utsnitt">';
    g.utsnitt.forEach(u => {
      [["off", "Utan pull (100 %)"], ["on", "Med pull (100 %)"], ["dark", "Mörkaste råbild"]].forEach(p => {
        if (!u[p[0]]) { h += "<figure></figure>"; return; }
        const pct = u[p[0] + "Pct"], txt = p[0] === "dark" ? "Mörkaste råbild (" + (pct || 100) + " %" + (pct && pct !== 100 ? ", uppskalad" : "") + ")" : p[1];
        h += '<figure><img loading="lazy" src="' + esc(u[p[0]]) + '" data-stor="' + esc(u[p[0]]) + '" alt=""><figcaption>Utsnitt ' + u.n + " (" + (u.art === "lodrat" ? "lodrät" : "vågrät") + " kant): " + txt + "</figcaption></figure>";
      });
    });
    h += "</div>";
  } else h += '<p class="dim">Inga fönsterkanter att visa (tom mask).</p>';
  h += '<div class="bedom"><button class="bra" data-v="battre">Bättre</button><button class="sam" data-v="samre">Sämre</button><button data-v="lika">Lika</button><textarea placeholder="Kommentar (valfri)" rows="1"></textarea></div>';
  return h;
}
function kopplaReglage(el){
  const rg = $(".reglage", el); if (!rg) return;
  const over = $(".over", rg), del = $(".delare", rg);
  let drar = false;
  function satt(x){ const r = rg.getBoundingClientRect(); const p = Math.max(0, Math.min(100, (x - r.left) / r.width * 100)); over.style.clipPath = "inset(0 0 0 " + p + "%)"; del.style.left = p + "%"; }
  // "med pull" visas till höger om delaren, "utan pull" till vänster
  over.style.clipPath = "inset(0 0 0 50%)";
  const lbl = $(".etikett.v", rg); lbl.textContent = "utan pull";
  rg.addEventListener("pointerdown", e => { drar = true; rg.setPointerCapture(e.pointerId); satt(e.clientX); e.preventDefault(); });
  rg.addEventListener("pointermove", e => { if (drar) satt(e.clientX); });
  rg.addEventListener("pointerup", () => { drar = false; });
  rg.addEventListener("pointercancel", () => { drar = false; });
  el.querySelectorAll(".fore").forEach(b => b.addEventListener("click", () => {
    const g = el._g; $(".under", rg).src = g.bilder[b.dataset.fore];
    lbl.textContent = b.dataset.fore === "legacy" ? "nuvarande v2" : "utan pull";
    el.querySelectorAll(".fore").forEach(x => x.classList.toggle("aktiv", x === b));
  }));
  const mk = $(".maskknapp", el);
  if (mk) mk.addEventListener("click", () => { const pa = rg.classList.toggle("maskpa"); mk.textContent = "Maskoverlay: " + (pa ? "på" : "av"); mk.classList.toggle("aktiv", pa); });
}
function kopplaBedom(el){
  const g = el._g, ta = $("textarea", el), knappar = el.querySelectorAll(".bedom button");
  const v = lasLagring(g.id) || {};
  ta.value = v.comment || "";
  function ritaKnappar(){ const cur = (lasLagring(g.id) || {}).verdict; knappar.forEach(b => b.classList.toggle("aktiv", b.dataset.v === cur)); }
  knappar.forEach(b => b.addEventListener("click", () => {
    const n = lasLagring(g.id) || {}; n.verdict = (n.verdict === b.dataset.v) ? null : b.dataset.v; skrivLagring(g.id, n); ritaKnappar(); raknaOm();
  }));
  ta.addEventListener("input", () => { const n = lasLagring(g.id) || {}; n.comment = ta.value; skrivLagring(g.id, n); });
  ritaKnappar();
}
function bygg(){
  const rot = $("#kort");
  DATA.grupper.forEach(g => {
    const el = document.createElement("section"); el.className = "kort"; el.id = g.id; el._g = g; el.innerHTML = kortHtml(g);
    rot.appendChild(el); kopplaReglage(el); kopplaBedom(el);
  });
  document.addEventListener("click", e => {
    const i = e.target.closest("img[data-stor]"); if (!i) return;
    $("#ljus img").src = i.dataset.stor; $("#ljus").style.display = "flex";
  });
  $("#ljus").addEventListener("click", () => { $("#ljus").style.display = "none"; });
  document.addEventListener("keydown", e => { if (e.key === "Escape") $("#ljus").style.display = "none"; });
}
byggKontroller(); bygg(); raknaOm(); visa();
</script></body></html>
'''

if __name__ == "__main__":
    main()
