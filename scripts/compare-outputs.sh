#!/usr/bin/env bash
# scripts/compare-outputs.sh -- jämför två PhotoFlow-outputmappar (fas 1a, plan avsnitt 6).
#
#   scripts/compare-outputs.sh <outputmapp A> <outputmapp B> [--no-metadata]
#
# Kontrollerar att bracket_groups.json / calendar_matches.json är byte-identiska, att
# enhancement.json har samma parametrar (tider ignoreras), att HDR- och förbättrade bilder har
# samma SHA-256 av AVKODADE pixlar (ImageIO, inte filbytes) och att metadata
# (`exiftool -j -G1 -a -struct`, flyktiga taggar bortfiltrerade) är identisk per fil.
# Skriver bara till ~/.cache/photoflow-compare (den kompilerade pixelhash-binären).
# Exit 0 = allt stämmer, 1 = skillnader, 2 = felaktig användning.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -lt 2 ] || [ ! -d "$1" ] || [ ! -d "$2" ]; then
    echo "Användning: $0 <outputmapp A> <outputmapp B> [--no-metadata]" >&2
    exit 2
fi
A="$1"; B="$2"; shift 2

CACHE="$HOME/.cache/photoflow-compare"
BIN="$CACHE/pixelhash"
mkdir -p "$CACHE"
if [ ! -x "$BIN" ] || [ "$SCRIPT_DIR/pixelhash.swift" -nt "$BIN" ]; then
    echo "Kompilerar pixelhash ..."
    swiftc -O "$SCRIPT_DIR/pixelhash.swift" -o "$BIN" || exit 2
fi
EXIFTOOL="$(command -v exiftool || echo /opt/homebrew/bin/exiftool)"
exec python3 "$SCRIPT_DIR/compare-outputs.py" "$A" "$B" --pixelhash "$BIN" --exiftool "$EXIFTOOL" "$@"
