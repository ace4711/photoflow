#!/usr/bin/env python3
"""Kör PhotoFlows egna HDR-varianter för alla grupper i hdr-lr-manifestet
(docs/plan-hdr-jamforelse.md, avsnitt 3) och för in sökvägar och tider i manifestet.

  pf-radiance      photoflow-cli hdr --method radiance
  pf-base          photoflow-cli hdr --method base
  pf-fusion        photoflow-cli hdr --method fusion
  pf-radiance-enh  photoflow-cli enhance på pf-radiance.tiff (Förbättra, standardprofilen)
  pf-v8            photoflow-cli hdr --method radiance-v8 (Lightroom-lik framkallning, docs/plan-hdr-v8-framkallning.md)
  pf-v8-enh        photoflow-cli enhance på pf-v8.tiff

Resultat: <root>/out/<id>/<variant>.tiff (+ .jpg). Alla ramar i gruppen används.
Redan klara varianter hoppas över (--force gör om). Manifestet skrivs om efter varje
variant, så en avbruten körning kan återupptas.

Användning:
    scripts/hdr-lr-run-ours.py --cli build-dd/Build/Products/Release/photoflow-cli \\
        [--root ~/PhotoFlowBenchmark/hdr-lr] [--variants pf-radiance,pf-base,...] \\
        [--groups id1,id2] [--force]

Skriver aldrig utanför --root.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ALLA = ["pf-radiance", "pf-base", "pf-fusion", "pf-radiance-enh", "pf-v8", "pf-v8-enh"]
METOD = {"pf-radiance": "radiance", "pf-base": "base", "pf-fusion": "fusion", "pf-v8": "radiance-v8"}
# Förbättra-varianter: källvarianten de bygger på.
KALLA = {"pf-radiance-enh": "pf-radiance", "pf-v8-enh": "pf-v8"}
SKYDDADE = ["/Volumes/photo-ingestion", "/Users/fredrik/Desktop/ptohotagraphy-test"]


def skydda(path):
    p = os.path.realpath(os.path.expanduser(path))
    for rot in SKYDDADE:
        r = os.path.realpath(rot)
        assert not (p == r or p.startswith(r + os.sep)), f"Vägrar skriva under {rot}: {path}"
    return p


def spara(manifest, path):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def kor(cmd):
    t = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r, time.time() - t


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cli", required=True, help="sökväg till photoflow-cli")
    ap.add_argument("--root", default="~/PhotoFlowBenchmark/hdr-lr")
    ap.add_argument("--variants", default=",".join(ALLA))
    ap.add_argument("--groups", default="", help="kommaseparerade id:n (standard: alla)")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    root = skydda(a.root)
    cli = os.path.abspath(a.cli)
    mpath = os.path.join(root, "manifest.json")
    varianter = [v for v in a.variants.split(",") if v]
    assert all(v in ALLA for v in varianter), f"okänd variant i {varianter}"
    urval = set(filter(None, a.groups.split(",")))

    manifest = json.load(open(mpath))
    totalt = {v: 0.0 for v in varianter}
    fel = 0
    for g in manifest["groups"]:
        if urval and g["id"] not in urval:
            continue
        ut = skydda(os.path.join(root, "out", g["id"]))
        os.makedirs(ut, exist_ok=True)
        frames = [os.path.join(root, f["file"]) for f in g["frames"]]
        g.setdefault("variants", {})
        tider = g.setdefault("timings", {})
        for v in varianter:
            tiff = os.path.join(ut, v + ".tiff")
            rel = f"out/{g['id']}/{v}.tiff"
            if os.path.exists(tiff) and g["variants"].get(v) == rel and not a.force:
                print(f"{g['id']:<28} {v:<16} (klar)")
                continue
            if v in METOD:
                cmd = [cli, "hdr", "--frames", *frames, "--method", METOD[v], "--out", tiff]
                r, sek = kor(cmd)
            else:
                kalla = os.path.join(ut, KALLA[v] + ".tiff")
                if not os.path.exists(kalla):
                    print(f"{g['id']:<28} {v:<16} SAKNAR {KALLA[v]}.tiff")
                    fel += 1
                    continue
                tmp = tempfile.mkdtemp(prefix="hdr-lr-enh-", dir=ut)
                r, sek = kor([cli, "enhance", "--input", kalla, "--output", tmp])
                if r.returncode == 0:
                    shutil.move(os.path.join(tmp, KALLA[v] + "_enh.tiff"), tiff)
                    shutil.move(os.path.join(tmp, KALLA[v] + "_enh.jpg"), os.path.join(ut, v + ".jpg"))
                shutil.rmtree(tmp, ignore_errors=True)
                # Förbättra-tiden läggs ovanpå HDR-tiden så att "total tid" blir rimlig.
            if r.returncode != 0 or not os.path.exists(tiff):
                print(f"{g['id']:<28} {v:<16} FEL ({r.returncode}): {(r.stderr or r.stdout).strip()[-300:]}")
                fel += 1
                continue
            g["variants"][v] = rel
            tider[v] = round(sek, 2)
            totalt[v] += sek
            print(f"{g['id']:<28} {v:<16} {sek:6.1f} s", flush=True)
            spara(manifest, mpath)
    print("\nSumma tid per variant (denna körning):")
    for v in varianter:
        print(f"  {v:<16} {totalt[v]:7.1f} s")
    print(f"Fel: {fel}")
    return 1 if fel else 0


if __name__ == "__main__":
    sys.exit(main())
