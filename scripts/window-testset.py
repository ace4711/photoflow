#!/usr/bin/env python3
"""Väljer ett testset av bracket-grupper för "window pull" (fönsterutsikt från
mörkaste exponeringen i HDR) och kopierar deras NEF-filer lokalt.

REGEL: /Volumes/photo-ingestion/ läses bara. Inget skrivs dit (alla målvägar
kontrolleras med assert). Bilder läses via `sips` -> BMP i en temporär mapp.

Heuristik (deterministisk, ingen slumpning):
  Bildmått: HDR-JPEG:en (hdr_group_<group_id>.jpg i "<adress> TITTBILDER"),
  annars förhandsbilden av median-exponeringen, skalas ned till 160 px.
    clip_frac    andel pixlar med max-kanal >= 245
    blob_frac    andel i sammanhängande ytor (>= 0,3 % av bilden vardera)
    big_frac     andel i ytor mellan 1 % och 35 % (fönster-liknande)
    small_blobs  antal små klippta fläckar (< 0,3 % vardera) = lampor
    small_frac   deras sammanlagda andel
  Taggar: gruppens kategori = majoritet av filernas ai_tags-kategori.

  fonster          Interiör (ej Exteriör), big_frac >= 1 %, störst klippt yta
                   <= 35 %. Rankas: mörkaste exponeringen saknas i suggested
                   först (+1), därefter big_frac. Sprids över adresser (round-robin).
  rorelse          Taggarna Växter/Utsikt/Trädgård finns och ljusa områden
                   finns (clip_frac >= 1 %). Rörelsemått: medelvärde av
                   absolut skillnad mellan luma-normaliserade förhandsbilder
                   av två intilliggande exponeringar, endast i ljusa områden
                   (masken = pixlar > 60 % ljushet i den ljusare bilden).
                   Högst rörelsemått först.
  exterior_lampor  Exteriör (tagg) eller interiör med >= 2 små klippta fläckar
                   (small_blobs), rankas efter antal små fläckar.
  Inga dubbletter mellan kategorierna (fönster väljs först, sedan rörelse,
  sedan exteriör/lampor).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from fractions import Fraction

SRC = "/Volumes/photo-ingestion"
OUT = SRC + "/PhotoFlow/output"
INP = SRC + "/PhotoFlow/input"
SIDE = 160


def skydda(path):
    p = os.path.realpath(os.path.expanduser(path))
    assert not (p == SRC or p.startswith(SRC + "/") or
                p.startswith("/private" + SRC + "/")), \
        f"Vägrar skriva under {SRC}: {path}"
    return p


def exp_sek(s):
    try:
        return float(Fraction(str(s)))
    except Exception:
        return float(s)


def las_bmp(jpg, tmpdir):
    """Läser en JPEG nedskalad via sips -> 24-bitars BMP. Returnerar (w,h,rader)
    där rader är lista av bytes (RGB) uppifrån och ned."""
    ut = os.path.join(tmpdir, "x.bmp")
    r = subprocess.run(["sips", "-Z", str(SIDE), "-s", "format", "bmp", jpg,
                        "--out", ut], capture_output=True)
    if r.returncode != 0 or not os.path.exists(ut):
        return None
    d = open(ut, "rb").read()
    off = int.from_bytes(d[10:14], "little")
    w = int.from_bytes(d[18:22], "little", signed=True)
    h = int.from_bytes(d[22:26], "little", signed=True)
    bpp = int.from_bytes(d[28:30], "little")
    assert bpp in (24, 32), bpp
    bpx = bpp // 8
    toppnerifran = h < 0
    h = abs(h)
    rad = (w * bpx + 3) // 4 * 4
    rader = []
    for y in range(h):
        sy = y if toppnerifran else h - 1 - y
        raw = d[off + sy * rad: off + sy * rad + w * bpx]
        rader.append([(raw[i * bpx + 2], raw[i * bpx + 1], raw[i * bpx])
                      for i in range(w)])
    os.remove(ut)
    return w, h, rader


def klippkarta(bild, tr=245):
    w, h, rader = bild
    return w, h, [[max(p) >= tr for p in r] for r in rader]


def blobbar(w, h, m):
    sett = [[False] * w for _ in range(h)]
    storlekar = []
    for y in range(h):
        for x in range(w):
            if m[y][x] and not sett[y][x]:
                st = [(y, x)]
                sett[y][x] = True
                n = 0
                while st:
                    cy, cx = st.pop()
                    n += 1
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < h and 0 <= nx < w and m[ny][nx] and not sett[ny][nx]:
                            sett[ny][nx] = True
                            st.append((ny, nx))
                storlekar.append(n / (w * h))
    return storlekar


def luma(bild):
    return [[0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] for p in r] for r in bild[2]]


def bildmatt(jpg, tmpdir):
    b = las_bmp(jpg, tmpdir)
    if not b:
        return None
    w, h, m = klippkarta(b)
    clip = sum(sum(r) for r in m) / (w * h)
    bl = blobbar(w, h, m)
    stora = [s for s in bl if 0.01 <= s <= 0.35]
    sma = [s for s in bl if s < 0.003]
    return {
        "clip_frac": round(clip, 4),
        "stor_blob_max": round(max(bl), 4) if bl else 0.0,
        "big_frac": round(sum(stora), 4),
        "small_blobs": len(sma),
        "small_frac": round(sum(sma), 4),
    }


def rorelsematt(jpg_a, jpg_b, tmpdir):
    a, b = las_bmp(jpg_a, tmpdir), las_bmp(jpg_b, tmpdir)
    if not a or not b or a[0] != b[0] or a[1] != b[1]:
        return None
    la, lb = luma(a), luma(b)
    w, h = a[0], a[1]
    ma = sum(map(sum, la)) / (w * h) or 1
    mb = sum(map(sum, lb)) / (w * h) or 1
    tot, n = 0.0, 0
    for y in range(h):
        for x in range(w):
            va, vb = la[y][x] / ma, lb[y][x] / mb
            if max(la[y][x], lb[y][x]) > 153:
                tot += abs(va - vb)
                n += 1
    return round(tot / n, 4) if n >= 20 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="visa bara urvalet")
    ap.add_argument("--dest", default="~/PhotoFlowBenchmark/windows")
    ap.add_argument("--count-windows", type=int, default=20)
    ap.add_argument("--count-motion", type=int, default=5)
    ap.add_argument("--count-exterior", type=int, default=5)
    a = ap.parse_args()
    dest = skydda(a.dest)

    grupper = json.load(open(OUT + "/bracket_groups.json"))["groups"]
    tags = json.load(open(OUT + "/ai_tags.json"))["photos"]

    # hdr_group_N.jpg och adress via mappnamn
    hdr = {}
    for d in sorted(os.listdir(OUT)):
        if d.endswith(" TITTBILDER"):
            for f in os.listdir(f"{OUT}/{d}"):
                if f.startswith("hdr_group_") and f.endswith(".jpg"):
                    hdr[int(f[10:-4])] = (f"{OUT}/{d}/{f}", d[:-len(" TITTBILDER")])

    kandidater = []
    tmp = tempfile.mkdtemp(prefix="window-testset-", dir=os.environ.get("TMPDIR", "/tmp"))
    try:
        for g in grupper:
            if not g.get("is_bracket") or len(g["files"]) < 2:
                continue
            gid = g["group_id"]
            ex = [exp_sek(e) for e in g["exposures"]]
            stems = [f.rsplit(".", 1)[0] for f in g["files"]]
            kat = Counter(tags.get(s, {}).get("category") for s in stems)
            kategori = kat.most_common(1)[0][0] if kat else None
            gtags = sorted({t for s in stems for t in tags.get(s, {}).get("tags", [])})
            sugg = g["suggested_hdr_indices"]
            minst = min(range(len(ex)), key=lambda i: ex[i])
            median_i = sorted(range(len(ex)), key=lambda i: ex[i])[len(ex) // 2]
            if gid in hdr:
                bild, adress = hdr[gid][0], hdr[gid][1]
                kalla = "hdr"
            else:
                bild, adress, kalla = f"{OUT}/previews/{stems[median_i]}.jpg", "okand", "preview"
            if not os.path.exists(bild):
                continue
            m = bildmatt(bild, tmp)
            if not m:
                continue
            m["bildkalla"] = kalla
            # rörelse: två intilliggande exponeringar (de två ljusaste ej-klippta)
            ordn = sorted(range(len(ex)), key=lambda i: ex[i])
            pa = f"{OUT}/previews/{stems[ordn[0]]}.jpg"
            pb = f"{OUT}/previews/{stems[ordn[1]]}.jpg"
            rm = None
            if ("Växter" in gtags or "Utsikt" in gtags or "Trädgård" in gtags) \
                    and m["clip_frac"] >= 0.01 and os.path.exists(pa) and os.path.exists(pb):
                rm = rorelsematt(pa, pb, tmp)
            m["rorelse"] = rm
            kandidater.append({
                "group_id": gid, "files": g["files"], "exposures": g["exposures"],
                "suggested_hdr_indices": sugg,
                "darkest_in_suggested": minst in sugg,
                "tags": gtags, "kategori": kategori, "adress": adress,
                "matt": m,
            })
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    def sprid(lista, n):
        """Round-robin över adresser, listan är redan rankad."""
        per = defaultdict(list)
        for k in lista:
            per[k["adress"]].append(k)
        adr = sorted(per, key=lambda x: per[x][0]["_rank"])
        ut = []
        while len(ut) < n and any(per.values()):
            for ad in adr:
                if per[ad] and len(ut) < n:
                    ut.append(per[ad].pop(0))
        return ut

    valda, anvanda = [], set()

    def valj(kat, filt, nyckel, n):
        lst = sorted([k for k in kandidater if k["group_id"] not in anvanda and filt(k)],
                     key=nyckel)
        for i, k in enumerate(lst):
            k["_rank"] = i
        for k in sprid(lst, n):
            k["category"] = kat
            valda = k
            valj.res.append(valda)
            anvanda.add(k["group_id"])
    valj.res = valda_lista = []

    interior = lambda k: k["kategori"] != "Exteriör" and "Exteriör" not in k["tags"]
    valj("fonster",
         lambda k: interior(k) and k["matt"]["big_frac"] >= 0.01 and k["matt"]["stor_blob_max"] <= 0.35,
         lambda k: (k["darkest_in_suggested"], -k["matt"]["big_frac"]), a.count_windows)
    # Reserv: för få grupper med 1-35 %-ytor -> släpp kravet till >= 0,3 % största yta
    saknas_f = a.count_windows - len(valda_lista)
    if saknas_f > 0:
        print(f"Obs: bara {len(valda_lista)} grupper uppfyller 1-35 %-kravet, "
              f"fyller på {saknas_f} med lägre krav (största klippta yta >= 0,3 %).")
        valj("fonster",
             lambda k: interior(k) and 0.003 <= k["matt"]["stor_blob_max"] <= 0.35,
             lambda k: (k["darkest_in_suggested"], -k["matt"]["stor_blob_max"]), saknas_f)
    valj("rorelse", lambda k: k["matt"]["rorelse"] is not None,
         lambda k: -k["matt"]["rorelse"], a.count_motion)
    valj("exterior_lampor",
         lambda k: k["kategori"] == "Exteriör" or k["matt"]["small_blobs"] >= 2,
         lambda k: (k["kategori"] != "Exteriör", -k["matt"]["small_blobs"]), a.count_exterior)

    for k in valda_lista:
        k.pop("_rank", None)

    # Utskrift
    for kat in ("fonster", "rorelse", "exterior_lampor"):
        rader = [k for k in valda_lista if k["category"] == kat]
        print(f"\n== {kat}: {len(rader)} grupper ==")
        for k in rader:
            m = k["matt"]
            print(f"  grupp {k['group_id']:>3} {k['adress']:<22} {k['kategori']:<9} "
                  f"filer={len(k['files'])} mörkast_i_sugg={k['darkest_in_suggested']!s:<5} "
                  f"big={m['big_frac']:.3f} clip={m['clip_frac']:.3f} "
                  f"små={m['small_blobs']} rörelse={m['rorelse']}")
    nef = [f for k in valda_lista for f in k["files"]]
    print(f"\nTotalt {len(valda_lista)} grupper, {len(nef)} NEF-filer")
    if a.dry_run:
        print("(--dry-run: inget kopierat)")
        return

    # Hitta NEF-filer (läsning) och kopiera
    index = {}
    for rot, _, fl in os.walk(INP):
        for f in fl:
            if f.upper().endswith(".NEF"):
                index.setdefault(f, os.path.join(rot, f))
    os.makedirs(dest, exist_ok=True)
    kopierat = hoppat = saknas = 0
    byte = 0
    for f in nef:
        src = index.get(f)
        if not src:
            print(f"  SAKNAS: {f}")
            saknas += 1
            continue
        mal = skydda(os.path.join(dest, f))
        if os.path.exists(mal) and os.path.getsize(mal) == os.path.getsize(src):
            hoppat += 1
            continue
        shutil.copyfile(src, mal)
        kopierat += 1
        byte += os.path.getsize(mal)
    ts = skydda(os.path.join(dest, "testset.json"))
    with open(ts, "w") as fh:
        json.dump([{"group_id": k["group_id"], "category": k["category"],
                    "files": k["files"], "exposures": k["exposures"],
                    "suggested_hdr_indices": k["suggested_hdr_indices"],
                    "darkest_in_suggested": k["darkest_in_suggested"],
                    "tags": k["tags"], "adress": k["adress"],
                    "matt": k["matt"]} for k in valda_lista],
                  fh, ensure_ascii=False, indent=1)
    print(f"Kopierade {kopierat} filer ({byte / 1e9:.2f} GB), hoppade över {hoppat}, saknas {saknas}")
    print(f"Skrev {ts}")


if __name__ == "__main__":
    sys.exit(main())
