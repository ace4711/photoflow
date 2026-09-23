#!/usr/bin/env bash
# scripts/smoke-run.sh -- headless rök-test av HELA PhotoFlow-pipelinen
# (NEF -> DNG -> previews -> bracket-analys -> [HDR] -> [AI-taggning] ->
# adressmappar -> metadata) mot en KOPIA av en riktig NEF-mapp, via
# `photoflow-cli` (se FORBATTRINGAR.md, "Rök-test via CLI", för bakgrund:
# `PipelineSmokeTest` under `xcodebuild test` hänger i DNG-konverteringssteget
# eftersom Adobe DNG Converter startas som barnprocess till testvärden — det
# här scriptet kör helt utanför Xcodes testrunner och har inte det problemet).
#
# SÄKERT ATT KÖRA: skriver ALDRIG i källmappen ($1) — kopierar alltid NEF-
# filerna till en tillfällig arbetsmapp under $TMPDIR (eller $PHOTOFLOW_SMOKE_TMPDIR)
# först, och pipelinen jobbar bara i den kopian. Originalen verifieras dessutom
# bit-identiska (md5) före/efter.
#
# Användning:
#   scripts/smoke-run.sh <mapp-med-NEF-filer> [ytterligare photoflow-cli-flaggor...]
#
# Exempel:
#   scripts/smoke-run.sh ~/Pictures/2024/2024-04-07
#   scripts/smoke-run.sh ~/Pictures/2024/2024-04-07 --no-ai --no-hdr
#
# Kalendermatchning stängs ALLTID av (--no-calendar) eftersom en headless
# process saknar en interaktiv EventKit-behörighetssession.
#
# Miljövariabler:
#   PHOTOFLOW_CLI_BIN         Använd en redan byggd photoflow-cli-binär i
#                             stället för att bygga en ny (snabbare vid
#                             upprepade körningar under utveckling).
#   PHOTOFLOW_SMOKE_TMPDIR    Rot för arbetsmappen (default: $TMPDIR eller /tmp).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/PhotoFlow/PhotoFlow.xcodeproj"

if [ $# -lt 1 ]; then
    echo "Användning: $0 <mapp-med-NEF-filer> [ytterligare photoflow-cli-flaggor...]" >&2
    exit 2
fi
SRC_DIR="$1"
shift
EXTRA_ARGS=("$@")

if [ ! -d "$SRC_DIR" ]; then
    echo "Mappen finns inte: $SRC_DIR" >&2
    exit 2
fi

NEF_COUNT=$(find "$SRC_DIR" -iname "*.NEF" | wc -l | tr -d ' ')
if [ "$NEF_COUNT" -eq 0 ]; then
    echo "Inga NEF-filer hittades (rekursivt) i $SRC_DIR" >&2
    exit 2
fi
echo "Hittade $NEF_COUNT NEF-filer i $SRC_DIR"

TMP_ROOT="${PHOTOFLOW_SMOKE_TMPDIR:-${TMPDIR:-/tmp}}"
WORKDIR=$(mktemp -d "$TMP_ROOT/photoflow-smoke-XXXXXX")
INPUT_DIR="$WORKDIR/input"
OUTPUT_DIR="$WORKDIR/output"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
echo "Arbetsmapp: $WORKDIR (källan $SRC_DIR rörs aldrig — bara läst)"

# Kopiera NEF-filer (rekursivt, flattenat till en enda inputmapp — pipelinen
# letar rekursivt själv i outputfallet, men det här scriptets egen md5-
# bokföring blir enklast mot en platt mapp). `-n`: hoppa i stället för att
# skriva över vid namnkrock mellan undermappar med samma filnamn.
while IFS= read -r -d '' f; do
    cp -n "$f" "$INPUT_DIR/"
done < <(find "$SRC_DIR" -iname "*.NEF" -print0)

COPIED_COUNT=$(find "$INPUT_DIR" -iname "*.NEF" | wc -l | tr -d ' ')
echo "Kopierade $COPIED_COUNT NEF-filer till $INPUT_DIR"

echo "Hashar original (md5) innan körning..."
(cd "$INPUT_DIR" && md5 -r ./*.NEF | sort) > "$WORKDIR/md5_before.txt"

# Använd en redan byggd binär om PHOTOFLOW_CLI_BIN pekar på en, annars bygg
# (derivedData under repo-roten, redan gitignorad via "DerivedData/") — så
# upprepade körningar under utveckling kan återanvända inkrementella byggen.
if [ -n "${PHOTOFLOW_CLI_BIN:-}" ] && [ -x "${PHOTOFLOW_CLI_BIN}" ]; then
    CLI_BIN="$PHOTOFLOW_CLI_BIN"
else
    DERIVED_DATA="$REPO_ROOT/DerivedData/photoflow-cli-smoke"
    echo "Bygger photoflow-cli (derivedData: $DERIVED_DATA)..."
    if ! xcodebuild -project "$PROJECT" -scheme photoflow-cli -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" build \
        > "$WORKDIR/build.log" 2>&1; then
        echo "BYGGET MISSLYCKADES — se $WORKDIR/build.log" >&2
        tail -60 "$WORKDIR/build.log" >&2
        exit 1
    fi
    CLI_BIN="$DERIVED_DATA/Build/Products/Debug/photoflow-cli"
fi
echo "Använder photoflow-cli: $CLI_BIN"

echo ""
echo "=== Kör pipelinen ==="
RUN_LOG="$WORKDIR/run.log"
TIME_LOG="$WORKDIR/time.log"
/usr/bin/time -l "$CLI_BIN" run --input "$INPUT_DIR" --output "$OUTPUT_DIR" --no-calendar --json "${EXTRA_ARGS[@]}" \
    > "$RUN_LOG" 2> "$TIME_LOG"
CLI_EXIT=$?
cat "$RUN_LOG"
echo ""
echo "=== Minnesanvändning (/usr/bin/time -l) ==="
grep -E "real|maximum resident|peak memory" "$TIME_LOG" || cat "$TIME_LOG"

OVERALL_OK=1
if [ "$CLI_EXIT" -ne 0 ]; then
    echo "" >&2
    echo "FEL: photoflow-cli avslutade med kod $CLI_EXIT" >&2
    OVERALL_OK=0
fi

echo ""
echo "=== Verifiering: original bit-identiska efteråt ==="
(cd "$INPUT_DIR" && md5 -r ./*.NEF | sort) > "$WORKDIR/md5_after.txt"
if diff -q "$WORKDIR/md5_before.txt" "$WORKDIR/md5_after.txt" > /dev/null; then
    echo "OK: alla $COPIED_COUNT NEF-original bit-identiska."
else
    echo "FEL: NEF-original ÄNDRADES av pipelinen!" >&2
    diff "$WORKDIR/md5_before.txt" "$WORKDIR/md5_after.txt" >&2 || true
    OVERALL_OK=0
fi

echo ""
echo "=== Verifiering: previews ==="
PREVIEW_COUNT=$(find "$OUTPUT_DIR/previews" -iname "*.jpg" 2>/dev/null | wc -l | tr -d ' ')
echo "Previews skapade: $PREVIEW_COUNT / $COPIED_COUNT"

echo ""
echo "=== Verifiering: bracket_groups.json ==="
if [ -f "$OUTPUT_DIR/bracket_groups.json" ]; then
    python3 -c "
import json
d = json.load(open('$OUTPUT_DIR/bracket_groups.json'))
print('  total_images:', d.get('total_images'))
print('  total_groups:', d.get('total_groups'))
print('  bracket_groups_count:', d.get('bracket_groups_count'))
print('  single_groups_count:', d.get('single_groups_count'))
"
else
    echo "SAKNAS: bracket_groups.json" >&2
    OVERALL_OK=0
fi

echo ""
echo "=== Verifiering: symlänkar (adress-/Osorterade-mappar) ==="
SYMLINK_COUNT=$(find "$OUTPUT_DIR" -type l | wc -l | tr -d ' ')
echo "Symlänkar: $SYMLINK_COUNT"

echo ""
echo "=== Verifiering: metadata (exiftool-stickprov på en DNG) ==="
SAMPLE_DNG=$(find "$OUTPUT_DIR" -iname "*.dng" ! -type l | head -1)
if [ -n "$SAMPLE_DNG" ]; then
    echo "Fil: $SAMPLE_DNG"
    exiftool -s3 -IPTC:Keywords -GPSLatitude -GPSLongitude "$SAMPLE_DNG" 2>/dev/null | sed 's/^/  /'
else
    echo "Ingen DNG hittades för stickprov." >&2
fi

echo ""
echo "=== Verifiering: XMP-sidecar bredvid NEF-symlänkar ==="
XMP_COUNT=$(find "$OUTPUT_DIR" -iname "*.xmp" | wc -l | tr -d ' ')
echo "XMP-sidecars: $XMP_COUNT"

echo ""
echo "=== Verifiering: HDR-TIFF (16-bitars) ==="
HDR_TIFF=$(find "$OUTPUT_DIR" -iname "hdr_group_*.tiff" | head -1)
if [ -n "$HDR_TIFF" ]; then
    echo "Fil: $HDR_TIFF"
    exiftool -BitsPerSample "$HDR_TIFF" 2>/dev/null | sed 's/^/  /'
else
    echo "Inga HDR-brackets hittade i indatan (kräver minst AppSettings.minBracketSize"
    echo "unika exponeringsnivåer inom en tidsklustrad grupp, se BracketAnalyzer.classify) — inget att verifiera."
fi
ORPHAN_HDR=$(find "$OUTPUT_DIR/hdr" -iname "*.tiff" 2>/dev/null | wc -l | tr -d ' ')
if [ "$ORPHAN_HDR" -gt 0 ]; then
    echo "FEL: $ORPHAN_HDR HDR-TIFF kvar i hdr/-stagingmappen (borde ha flyttats till en Osorterade/adress-mapp)" >&2
    OVERALL_OK=0
fi

echo ""
echo "=== Resultat ==="
echo "Arbetsmapp (input+output sparas kvar för manuell inspektion): $WORKDIR"
if [ "$OVERALL_OK" -eq 1 ] && [ "$CLI_EXIT" -eq 0 ]; then
    echo "RÖKTEST GODKÄNT"
    exit 0
else
    echo "RÖKTEST MISSLYCKADES — se felmeddelanden ovan"
    exit 1
fi
