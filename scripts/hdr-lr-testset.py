#!/usr/bin/env python3
"""Väljer 20 bracket-grupper för jämförelsen PhotoFlow HDR mot Lightroom HDR
(docs/plan-hdr-jamforelse.md, avsnitt 2), kopierar deras NEF-filer och
fotografens referensbilder lokalt och skriver manifest.json.

REGEL: /Users/fredrik/Desktop/ptohotagraphy-test och /Volumes/photo-ingestion
läses bara. Inget skrivs dit (alla målvägar kontrolleras med assert i `skydda`).

Urvalet är deterministiskt (ingen slumpning) och bygger på bildmått från
scripts/window-testset.py (klippta ytor, små klippta fläckar, rörelse):

  8 från Chronas väg 7 (alla med fotografreferens i "Chronas väg 7 red"):
      2 exteriör (mest blå himmel i övre delen av bilden), 4 interiör med
      fönster (störst fönsterliknande klippt yta), 2 mörka rum (lägst
      medelljushet).  Chronas saknar ai_tags.json, så exteriör avgörs ur bilden.
  12 från /Volumes/photo-ingestion/PhotoFlow/output, spridda över adresserna
      (round-robin): 2 med rörelse (träd/moln), 3 exteriör (taggen Exteriör,
      mest klippt = himmel/motljus), 5 interiör med fönster, 2 mörka rum.

Alla ramar i gruppen kopieras (samma ramlista går till båda motorerna).

Användning:
    scripts/hdr-lr-testset.py [--dry-run] [--dest ~/PhotoFlowBenchmark/hdr-lr]
"""
import argparse
import importlib.util
import json
import unicodedata
import os
import re
import shutil
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("window_testset", os.path.join(HERE, "window-testset.py"))
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)

VOL = "/Volumes/photo-ingestion"
OUT = VOL + "/PhotoFlow/output"
INP = VOL + "/PhotoFlow/input"
CHRONAS = "/Users/fredrik/Desktop/ptohotagraphy-test/Chronas väg 7"
CHRONAS_REF = CHRONAS + "/Chronas väg 7 red"
CHRONAS_PROC = CHRONAS + "/processed"
SKYDDADE = [VOL, "/Users/fredrik/Desktop/ptohotagraphy-test"]


def skydda(path):
    """Vägrar skriva under testdatamapparna (även via symlänkar)."""
    p = os.path.realpath(os.path.expanduser(path))
    for rot in SKYDDADE:
        r = os.path.realpath(rot)
        assert not (p == r or p.startswith(r + os.sep) or p.startswith("/private" + r + os.sep)), \
            f"Vägrar skriva under {rot}: {path}"
    return p


def profil(jpg, tmp):
    """Medelljushet och andel blå himmel (övre 40 %) ur en nedskalad bild."""
    b = wt.las_bmp(jpg, tmp)
    if not b:
        return None
    w, h, rader = b
    tot = sum(0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] for r in rader for p in r) / (w * h)
    ovre = rader[: max(1, int(h * 0.4))]
    himmel = sum(1 for r in ovre for (rr, gg, bb) in r if bb > rr + 12 and bb >= gg and max(rr, gg, bb) > 110)
    return {"medelljus": round(tot, 1), "himmel": round(himmel / (len(ovre) * w), 4)}


def slug(text):
    t = unicodedata.normalize("NFC", text).lower().translate(str.maketrans("åäöéü", "aaoeu"))
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def sprid(lista, n):
    """Round-robin över adresser; `lista` är redan rankad (bäst först)."""
    per = defaultdict(list)
    for k in lista:
        per[k["adress"]].append(k)
    adr = sorted(per, key=lambda a: lista.index(per[a][0]))
    ut = []
    while len(ut) < n and any(per.values()):
        for a in adr:
            if per[a] and len(ut) < n:
                ut.append(per[a].pop(0))
    return ut


def valj(kandidater, anvanda, kategori, filt, nyckel, n, sprida=False):
    lst = sorted([k for k in kandidater if k["key"] not in anvanda and filt(k)], key=nyckel)
    vald = sprid(lst, n) if sprida else lst[:n]
    for k in vald:
        k["category"] = kategori
        anvanda.add(k["key"])
    if len(vald) < n:
        print(f"Obs: bara {len(vald)} av {n} för {kategori}")
    return vald


def chronas_grupper(tmp):
    d = json.load(open(CHRONAS_PROC + "/bracket_groups.json"))["groups"]
    refs = {f[:-4]: f for f in os.listdir(CHRONAS_REF) if f.upper().startswith("DSC_") and f.lower().endswith(".jpg")}
    ut = []
    for g in d:
        if not g.get("is_bracket"):
            continue
        stems = [f.rsplit(".", 1)[0] for f in g["files"]]
        ref = next((refs[s] for s in stems if s in refs), None)
        if not ref:
            continue
        ex = [wt.exp_sek(e) for e in g["exposures"]]
        ordn = sorted(range(len(ex)), key=lambda i: ex[i])
        prev = f"{CHRONAS_PROC}/previews/{stems[ordn[len(ordn) // 2]]}.jpg"
        m = wt.bildmatt(prev, tmp)
        p = profil(prev, tmp)
        if not m or not p:
            continue
        ut.append({"key": ("c", g["group_id"]), "source": "Chronas väg 7", "adress": "Chronas väg 7",
                   "group_id": g["group_id"], "files": g["files"], "exposures": ex,
                   "dir": CHRONAS, "ref": ref, "matt": m, "profil": p})
    return ut


def volym_grupper(tmp):
    grupper = json.load(open(OUT + "/bracket_groups.json"))["groups"]
    tags = json.load(open(OUT + "/ai_tags.json"))["photos"]
    hdr = {}
    for d in sorted(os.listdir(OUT)):
        if d.endswith(" TITTBILDER"):
            for f in os.listdir(f"{OUT}/{d}"):
                if f.startswith("hdr_group_") and f.endswith(".jpg"):
                    hdr[int(f[10:-4])] = (f"{OUT}/{d}/{f}", d[: -len(" TITTBILDER")])
    ut = []
    for g in grupper:
        gid = g["group_id"]
        if not g.get("is_bracket") or len(g["files"]) < 2 or gid not in hdr:
            continue
        ex = [wt.exp_sek(e) for e in g["exposures"]]
        stems = [f.rsplit(".", 1)[0] for f in g["files"]]
        kat = Counter(tags.get(s, {}).get("category") for s in stems).most_common(1)[0][0]
        gtags = sorted({t for s in stems for t in tags.get(s, {}).get("tags", [])})
        m = wt.bildmatt(hdr[gid][0], tmp)
        p = profil(hdr[gid][0], tmp)
        if not m or not p:
            continue
        ordn = sorted(range(len(ex)), key=lambda i: ex[i])
        pa, pb = f"{OUT}/previews/{stems[ordn[0]]}.jpg", f"{OUT}/previews/{stems[ordn[1]]}.jpg"
        rm = None
        if ("Växter" in gtags or "Utsikt" in gtags or "Trädgård" in gtags) and m["clip_frac"] >= 0.01 \
                and os.path.exists(pa) and os.path.exists(pb):
            rm = wt.rorelsematt(pa, pb, tmp)
        m["rorelse"] = rm
        ut.append({"key": ("v", gid), "source": hdr[gid][1], "adress": hdr[gid][1], "group_id": gid,
                   "files": g["files"], "exposures": ex, "dir": None, "ref": None, "kategori": kat,
                   "tags": gtags, "matt": m, "profil": p})
    return ut


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="visa bara urvalet")
    ap.add_argument("--dest", default="~/PhotoFlowBenchmark/hdr-lr")
    a = ap.parse_args()
    dest = skydda(a.dest)

    tmp = tempfile.mkdtemp(prefix="hdr-lr-testset-")
    try:
        chronas = chronas_grupper(tmp)
        volym = volym_grupper(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"Kandidater: {len(chronas)} Chronas med referens, {len(volym)} från volymen")

    valda = []
    an = set()
    # Chronas: exteriör först (knappast), därefter fönster, därefter mörka rum.
    valda += valj(chronas, an, "exterior", lambda k: True, lambda k: -k["profil"]["himmel"], 2)
    valda += valj(chronas, an, "interior-window", lambda k: k["matt"]["big_frac"] >= 0.01,
                  lambda k: -k["matt"]["big_frac"], 4)
    valda += valj(chronas, an, "dark-room", lambda k: True, lambda k: k["profil"]["medelljus"], 2)
    # Volymen: rörelse först (knappast), exteriör, fönster, mörka rum.
    inne = lambda k: k["kategori"] != "Exteriör" and "Exteriör" not in k["tags"]
    valda += valj(volym, an, "motion", lambda k: k["matt"]["rorelse"] is not None,
                  lambda k: -k["matt"]["rorelse"], 2, sprida=True)
    valda += valj(volym, an, "exterior", lambda k: k["kategori"] == "Exteriör",
                  lambda k: -k["matt"]["clip_frac"], 3, sprida=True)
    valda += valj(volym, an, "interior-window",
                  lambda k: inne(k) and k["matt"]["big_frac"] >= 0.01 and k["matt"]["stor_blob_max"] <= 0.35,
                  lambda k: -k["matt"]["big_frac"], 5, sprida=True)
    valda += valj(volym, an, "dark-room", inne, lambda k: k["profil"]["medelljus"], 2, sprida=True)

    # Stabila id:n: chronas-01…, <adress>-gNNN
    chron_sorted = sorted([k for k in valda if k["source"] == "Chronas väg 7"], key=lambda k: k["group_id"])
    for i, k in enumerate(chron_sorted, 1):
        k["id"] = f"chronas-{i:02d}"
    for k in valda:
        if "id" not in k:
            k["id"] = f"{slug(k['source'])}-g{k['group_id']:03d}"
    valda.sort(key=lambda k: (k["source"] != "Chronas väg 7", k["id"]))

    for k in valda:
        m = k["matt"]
        print(f"  {k['id']:<28} {k['category']:<16} ramar={len(k['files']):>2} big={m['big_frac']:.3f} "
              f"clip={m['clip_frac']:.3f} ljus={k['profil']['medelljus']:>5} himmel={k['profil']['himmel']:.2f} "
              f"rörelse={m.get('rorelse')} ref={k['ref']}")
    print(f"Totalt {len(valda)} grupper, {sum(len(k['files']) for k in valda)} NEF-filer")
    if a.dry_run:
        print("(--dry-run: inget kopierat)")
        return

    index = {}
    for rot, _, fl in os.walk(INP):
        for f in fl:
            if f.upper().endswith(".NEF"):
                index.setdefault(f, os.path.join(rot, f))

    def kopiera(src, mal):
        mal = skydda(mal)
        os.makedirs(os.path.dirname(mal), exist_ok=True)
        if os.path.exists(mal) and os.path.getsize(mal) == os.path.getsize(src):
            return 0
        shutil.copyfile(src, mal)
        return os.path.getsize(mal)

    byte = 0
    grupper = []
    for k in valda:
        frames = []
        for f, e in zip(k["files"], k["exposures"]):
            src = os.path.join(k["dir"], f) if k["dir"] else index.get(f)
            assert src and os.path.exists(src), f"saknas: {f}"
            byte += kopiera(src, f"{dest}/nef/{k['id']}/{f}")
            frames.append({"file": f"nef/{k['id']}/{f}", "exposureSeconds": round(e, 6)})
        g = {"id": k["id"], "source": k["source"], "groupId": k["group_id"], "category": k["category"],
             "frames": frames, "photographerReference": None, "variants": {}}
        if k["ref"]:
            byte += kopiera(os.path.join(CHRONAS_REF, k["ref"]), f"{dest}/ref/{k['id']}/{k['ref']}")
            g["photographerReference"] = f"ref/{k['id']}/{k['ref']}"
        grupper.append(g)

    mpath = skydda(os.path.join(dest, "manifest.json"))
    gammal = json.load(open(mpath)) if os.path.exists(mpath) else {}
    # Behåll redan registrerade varianter vid omkörning.
    gv = {g["id"]: g.get("variants", {}) for g in gammal.get("groups", [])}
    for g in grupper:
        g["variants"] = gv.get(g["id"], {})
    manifest = {"version": 1, "created": gammal.get("created") or datetime.now().isoformat(timespec="seconds"),
                "groups": grupper}
    with open(mpath, "w") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
    print(f"Kopierade {byte / 1e9:.2f} GB nytt. Skrev {mpath}")


if __name__ == "__main__":
    sys.exit(main())
