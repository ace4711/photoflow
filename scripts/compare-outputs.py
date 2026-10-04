#!/usr/bin/env python3
"""Jämför två PhotoFlow-outputmappar (fas 1a, plan 6 "Verifiering").

  compare-outputs.py A B [--pixelhash BINÄR] [--exiftool PATH] [--no-metadata]

Kontrollerar:
  1. bracket_groups.json och calendar_matches.json: byte-identiska (calendar_matches.json bara om
     den finns i någon av mapparna).
  2. enhancement.json: parametrar och analys per bild identiska; tider/datum ignoreras
     (seconds, date, updatedAt).
  3. HDR- och förbättrade bilder (hdr_group_*.tiff/.jpg, *_enh.tiff/.jpg, var de än ligger):
     samma uppsättning och SHA-256 av AVKODADE pixlar (ImageIO via pixelhash), inte filbytes.
  4. Metadata: `exiftool -j -G1 -a -struct` på DNG, förhandsbilder, HDR/förbättrade filer och
     XMP-sidecars, med flyktiga taggar bortfiltrerade, per fil jämförda som tagg-mängder.
Avslutar med 0 om allt stämmer, annars 1.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VOLATILE_GROUPS = {"File", "System", "ExifTool", "SourceFile"}
# Flyktiga taggar: id:n och tidsstämplar som skrivs vid varje körning (XMP-id:n, MetadataDate,
# ModifyDate = skrivtidpunkten för DNG-omvandlaren och ImageIO) och tidsstämplar som Adobe DNG
# Converter bäddar in (PreviewDateTime, och Composite:SubSecModifyDate som räknas fram ur dem). Plus TIFF-formatets egen struktur (Compression/Strip*/RowsPerStrip), som
# ändras när komprimeringen byts men inte säger något om metadata eller pixlar.
VOLATILE_TAG_RE = re.compile(
    r"^(XMP-xmpMM:|XMP-xmp:(MetadataDate|ModifyDate)$|XMP-photoshop:DocumentAncestors|[A-Za-z0-9]+:ModifyDate$|"
    r"[A-Za-z0-9]+:(PreviewDateTime|PreviewImageStart)$|Composite:SubSecModifyDate$|"
    r"IFD0:(Compression|StripOffsets|StripByteCounts|RowsPerStrip)$)"
)
ENH_IGNORED_KEYS = {"seconds", "date", "updatedAt"}


def real_files(root: Path):
    """Alla vanliga filer (inte symlänkar) under root, som relativa sökvägar."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            p = Path(dirpath) / name
            if name.startswith(".") or p.is_symlink():
                continue
            out.append(p.relative_to(root))
    return sorted(out)


def is_result_image(rel: Path):
    n = rel.name
    return (re.fullmatch(r"hdr_group_\d+\.(tiff|jpg)", n) is not None
            or re.fullmatch(r".+_enh\.(tiff|jpg)", n) is not None)


def pixel_hashes(root: Path, rels, binary):
    proc = subprocess.run([binary], input="\n".join(str(root / r) for r in rels), capture_output=True, text=True)
    result = {}
    for line in proc.stdout.splitlines():
        h, _, path = line.partition("\t")
        result[str(Path(path).relative_to(root))] = h
    return result


def exif_tags(root: Path, rels, exiftool):
    """Relativ sökväg -> {tagg: värde} för de filer exiftool kan läsa, flyktiga taggar bortfiltrerade."""
    if not rels:
        return {}
    arg = "\n".join(str(root / r) for r in rels)
    proc = subprocess.run([exiftool, "-j", "-G1", "-a", "-struct", "-q", "-@", "-"], input=arg, capture_output=True, text=True)
    try:
        items = json.loads(proc.stdout) if proc.stdout.strip() else []
    except json.JSONDecodeError:
        items = []
    result = {}
    for item in items:
        src = item.get("SourceFile", "")
        key = str(Path(src).relative_to(root))
        tags = {}
        for tag, value in item.items():
            group = tag.split(":", 1)[0]
            if group in VOLATILE_GROUPS or VOLATILE_TAG_RE.match(tag):
                continue
            tags[tag] = value
        result[key] = tags
    return result


def strip_enh(obj):
    if isinstance(obj, dict):
        return {k: strip_enh(v) for k, v in obj.items() if k not in ENH_IGNORED_KEYS}
    if isinstance(obj, list):
        return [strip_enh(v) for v in obj]
    return obj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--pixelhash", default=str(Path(__file__).with_name("pixelhash")))
    ap.add_argument("--exiftool", default="exiftool")
    ap.add_argument("--no-metadata", action="store_true")
    ap.add_argument("--max-report", type=int, default=15)
    args = ap.parse_args()
    A, B = Path(args.a), Path(args.b)
    failures = []

    def report(title, ok, detail=""):
        print(f"[{'OK ' if ok else 'FEL'}] {title}" + (f" -- {detail}" if detail else ""))
        if not ok:
            failures.append(title)

    # 1. Byte-identiska JSON-filer
    for name in ("bracket_groups.json", "calendar_matches.json"):
        fa, fb = A / name, B / name
        if not fa.exists() and not fb.exists():
            print(f"[--] {name}: finns inte i någon av mapparna (hoppas över)")
            continue
        if fa.exists() != fb.exists():
            report(name, False, "finns bara i ena mappen")
            continue
        ba, bb = fa.read_bytes(), fb.read_bytes()
        if hashlib.sha256(ba).digest() == hashlib.sha256(bb).digest():
            report(f"{name} byte-identisk", True)
        else:
            # Skrivs med JSONSerialization utan .sortedKeys: nyckelordningen varierar mellan processer
            # (slumpad hash-ordning), så två identiska körningar ger olika bytes. Jämför värdena.
            try:
                same = json.loads(ba) == json.loads(bb)
            except json.JSONDecodeError:
                same = False
            report(f"{name} värdeidentisk (bytes skiljer: nyckelordning, JSONSerialization utan sortedKeys)" if same else f"{name} identisk", same)

    # 2. enhancement.json (parametrar, inte tider)
    ea, eb = A / "enhancement.json", B / "enhancement.json"
    if ea.exists() and eb.exists():
        ja, jb = strip_enh(json.loads(ea.read_text())), strip_enh(json.loads(eb.read_text()))
        entries_a, entries_b = ja.get("entries", {}), jb.get("entries", {})
        diff = sorted(k for k in set(entries_a) | set(entries_b) if entries_a.get(k) != entries_b.get(k))
        report(f"enhancement.json parametrar identiska ({len(entries_a)} resp. {len(entries_b)} poster)",
               not diff and ja == jb, ", ".join(diff[: args.max_report]))
    else:
        print("[--] enhancement.json saknas i någon mapp (hoppas över)")

    # 3. Pixlar i HDR- och förbättrade bilder
    files_a, files_b = real_files(A), real_files(B)
    imgs_a = [r for r in files_a if is_result_image(r)]
    imgs_b = [r for r in files_b if is_result_image(r)]
    # Sorteringen kan lägga filerna olika (adressmapp); jämför på filnamn.
    by_name_a = {r.name: r for r in imgs_a}
    by_name_b = {r.name: r for r in imgs_b}
    names_ok = set(by_name_a) == set(by_name_b)
    only_a = sorted(set(by_name_a) - set(by_name_b))
    only_b = sorted(set(by_name_b) - set(by_name_a))
    report(f"samma uppsättning HDR-/förbättrade bilder ({len(by_name_a)} resp. {len(by_name_b)})", names_ok,
           f"bara i A: {only_a[:5]} bara i B: {only_b[:5]}" if not names_ok else "")
    if not os.path.exists(args.pixelhash):
        print(f"[--] {args.pixelhash} saknas: pixeljämförelsen hoppas över", file=sys.stderr)
    else:
        common = sorted(set(by_name_a) & set(by_name_b))
        ha = pixel_hashes(A, [by_name_a[n] for n in common], args.pixelhash)
        hb = pixel_hashes(B, [by_name_b[n] for n in common], args.pixelhash)
        bad = [n for n in common if ha.get(str(by_name_a[n])) != hb.get(str(by_name_b[n])) or ha.get(str(by_name_a[n]), "OREAD") in ("OREAD", "NOCONTEXT")]
        report(f"avkodade pixlar identiska (SHA-256) för {len(common)} bilder", not bad, ", ".join(bad[: args.max_report]))

    # 4. Metadata
    if not args.no_metadata:
        meta_ext = {".dng", ".jpg", ".tiff", ".xmp"}
        # Nyckel: filnamn (adressmappar kan skilja), men dubbla namn (t.ex. samma DSC i dng/ och previews/) särskiljs med filtyp+mapp-roll.
        def keyed(files):
            out = {}
            for r in files:
                if r.suffix.lower() not in meta_ext:
                    continue
                role = "preview" if r.parts[0] == "previews" else ("dng" if r.suffix.lower() == ".dng" else "other")
                out[(role, r.name)] = r
            return out
        ka, kb = keyed(files_a), keyed(files_b)
        report(f"samma uppsättning metadatafiler ({len(ka)} resp. {len(kb)})", set(ka) == set(kb),
               f"skillnad: {sorted(set(ka) ^ set(kb))[:5]}" if set(ka) != set(kb) else "")
        common = sorted(set(ka) & set(kb))
        ta = exif_tags(A, [ka[k] for k in common], args.exiftool)
        tb = exif_tags(B, [kb[k] for k in common], args.exiftool)
        diffs = []
        tag_diff_counts = {}
        for k in common:
            x, y = ta.get(str(ka[k]), {}), tb.get(str(kb[k]), {})
            if x != y:
                changed = sorted(t for t in set(x) | set(y) if x.get(t) != y.get(t))
                diffs.append((k, changed))
                for t in changed:
                    tag_diff_counts[t] = tag_diff_counts.get(t, 0) + 1
        report(f"metadata (exiftool -j -G1 -a -struct, flyktiga taggar bortfiltrerade) identisk för {len(common)} filer",
               not diffs, f"{len(diffs)} filer skiljer; vanligaste taggar: {sorted(tag_diff_counts.items(), key=lambda kv: -kv[1])[:8]}" if diffs else "")
        for (role, name), changed in diffs[: args.max_report]:
            print(f"      {role}/{name}: {changed[:6]}")

    print()
    print("RESULTAT:", "ALLT STÄMMER" if not failures else f"{len(failures)} skillnad(er): {failures}")
    sys.exit(0 if not failures else 1)


main()
