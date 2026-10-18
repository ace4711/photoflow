#!/usr/bin/env python3
"""Kontaktark för HDR-jämförelsen (docs/plan-hdr-v8-framkallning.md): per grupp en rad med
varianterna sida vid sida (t.ex. pf-v8 | lr-auto), nedskalade JPEG:ar att titta på.

  scripts/hdr-lr-contact.py --manifest ~/PhotoFlowBenchmark/hdr-lr/manifest.json \\
      --variants pf-radiance,pf-v8,lr-auto --out $TMPDIR/sheets [--groups id1,id2] [--width 800]
      [--crop 0.3,0.1,0.4,0.4]

--crop x,y,b,h (andelar av bilden) lägger till ett utsnitt (t.ex. ett fönster) i större skala
under raden. Sökvägar i manifestet kan vara relativa (mot manifestets mapp) eller absoluta.
Kräver ImageMagick (`magick`). Skriver aldrig under testdatamapparna.
"""
import argparse
import json
import os
import subprocess
import sys

SKYDDADE = ["/Volumes/photo-ingestion", "/Users/fredrik/Desktop/ptohotagraphy-test"]


def skydda(path):
    p = os.path.realpath(os.path.expanduser(path))
    for rot in SKYDDADE:
        r = os.path.realpath(rot)
        assert not (p == r or p.startswith(r + os.sep)), f"Vägrar skriva under {rot}: {path}"
    return p


def bild(root, path):
    return path if path.startswith("/") else os.path.join(root, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--variants", default="pf-radiance,pf-radiance-enh,lr-auto")
    ap.add_argument("--out", required=True)
    ap.add_argument("--groups", default="")
    ap.add_argument("--width", type=int, default=800)
    ap.add_argument("--crop", default="", help="x,y,b,h som andelar, valfritt")
    a = ap.parse_args()
    mpath = os.path.realpath(os.path.expanduser(a.manifest))
    root = os.path.dirname(mpath)
    out = skydda(a.out)
    os.makedirs(out, exist_ok=True)
    manifest = json.load(open(mpath))
    varianter = [v for v in a.variants.split(",") if v]
    urval = set(filter(None, a.groups.split(",")))
    crop = [float(v) for v in a.crop.split(",")] if a.crop else None

    for g in manifest["groups"]:
        if urval and g["id"] not in urval:
            continue
        alla = dict(g.get("variants", {}))
        if "ref" not in alla and g.get("photographerReference"):
            alla["ref"] = g["photographerReference"]
        tiles, crops = [], []
        for v in varianter:
            if v not in alla or not os.path.exists(bild(root, alla[v])):
                continue
            src = bild(root, alla[v])
            tile = os.path.join(out, f".{g['id']}-{v}.jpg")
            cmd = ["magick", src + "[0]", "-quiet", "-colorspace", "sRGB", "-resize", f"{a.width}x{a.width}",
                   "-depth", "8", "-gravity", "NorthWest", "-fill", "yellow", "-undercolor", "#00000080",
                   "-pointsize", str(max(14, a.width // 40)), "-annotate", "+6+6", v, tile]
            subprocess.run(cmd, check=True, capture_output=True)
            tiles.append(tile)
            if crop:
                c = os.path.join(out, f".{g['id']}-{v}-crop.jpg")
                x, y, w, h = crop
                size = subprocess.run(["magick", "identify", "-quiet", "-format", "%w %h", src + "[0]"],
                                      capture_output=True, text=True).stdout.split()
                W, H = int(size[0]), int(size[1])
                geo = f"{int(w * W)}x{int(h * H)}+{int(x * W)}+{int(y * H)}"
                subprocess.run(["magick", src + "[0]", "-quiet", "-colorspace", "sRGB", "-crop", geo, "+repage",
                                "-resize", f"{a.width}x{a.width}", "-depth", "8", c], check=False, capture_output=True)
                if os.path.exists(c):
                    crops.append(c)
        if not tiles:
            continue
        sheet = os.path.join(out, f"{g['id']}.jpg")
        cmd = ["magick", *tiles, "+append"]
        if crops:
            cmd = ["magick", "(", *tiles, "+append", ")", "(", *crops, "+append", ")", "-append"]
        subprocess.run(cmd + ["-quality", "88", sheet], check=True, capture_output=True)
        for t in tiles + crops:
            os.remove(t)
        print(sheet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
