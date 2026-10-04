#!/usr/bin/env bash
# scripts/benchmark.sh -- repeterbart riktmärke av PhotoFlows pipeline (fas 1a i
# docs/plan-snabbare-pipeline.md, avsnitt 5.2).
#
# Vad det gör:
#   1. (en gång) Kopierar en FAST testmängd (~20 bracket-grupper + ~70 enskilda NEF, jämnt
#      utspridda över dagens session) ur en riktig indatamapp till en lokal kopia
#      (standard ~/PhotoFlowBenchmark/input, ca 5 GB). Urvalet görs med bracket_groups.json
#      och sparas i testset.json bredvid kopian, så samma filer används varje gång.
#      Källan öppnas bara för läsning.
#   2. Kör `photoflow-cli run --input <kopia> --output <ny mapp> --no-calendar --json` med
#      AI-bildtexter (Foundation Models, icke-deterministiska) avstängda: en uppvärmning
#      (kastas, fyller Metal-shadercachen) och sedan N mätta körningar.
#   3. Sparar per körning i resultatkatalogen: JSON-sammanfattning, timings.jsonl,
#      pipeline.log (med resursrad per steg), step_timings.jsonl (med resursfälten) och
#      tid från skalet. Skriver till sist en sammanfattning (median/min per steg).
#
# Användning:
#   scripts/benchmark.sh --label baslinje [--runs 2] [--warmup 1] [--output-root DIR]
#                        [--cli PATH] [--keep 2] [--prepare-only]
#
#   --label NAME        Namn på uppsättningen (t.ex. baslinje, efter). Krävs.
#   --output-root DIR   Var körningarnas outputmappar skrivs. Standard ~/PhotoFlowBenchmark/out
#                       (intern disk). Ange en mapp på T5:an för att mäta mot den.
#   --cli PATH          photoflow-cli-binär (standard: den senast byggda Debug-binären).
#   --runs N            Antal mätta körningar (standard 2; planen säger 3).
#   --warmup N          Antal uppvärmningskörningar (standard 1).
#   --keep N            Behåll outputmapparna för de N sista körningarna (standard 2) så att
#                       scripts/compare-outputs.sh kan jämföra dem; äldre raderas.
#   --protect-history   För äldre photoflow-cli-binärer som inte förstår PHOTOFLOW_SUPPORT_DIR:
#                       säkerhetskopiera användarens step_timings.jsonl/sessions.json före körningarna
#                       och återställ dem efteråt (annars hamnar benchmarkets poster i appens historik).
#   --prepare-only      Kopiera testmängden och avsluta.
#
# Miljövariabler:
#   BENCH_HOME          Rot (standard ~/PhotoFlowBenchmark): input/, out/, results/.
#   BENCH_SOURCE_INPUT  Källmapp med NEF (standard /Volumes/photo-ingestion/PhotoFlow/input/114NCZ_8).
#   BENCH_SOURCE_GROUPS bracket_groups.json för källan
#                       (standard /Volumes/photo-ingestion/PhotoFlow/output/bracket_groups.json).
#   BENCH_BRACKETS / BENCH_SINGLES   Antal grupper/enskilda i urvalet (standard 20 / 70).
#
# Körningarna använder egen historikmapp (PHOTOFLOW_SUPPORT_DIR) så att användarens riktiga
# step_timings.jsonl/sessions.json inte påverkas. AI-bildtexter stängs av via
# `defaults write photoflow-cli aiDescriptionsEnabled -bool false` (CLI:ns egen domän, inte appens).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BENCH_HOME="${BENCH_HOME:-$HOME/PhotoFlowBenchmark}"
SOURCE_INPUT="${BENCH_SOURCE_INPUT:-/Volumes/photo-ingestion/PhotoFlow/input/114NCZ_8}"
SOURCE_GROUPS="${BENCH_SOURCE_GROUPS:-/Volumes/photo-ingestion/PhotoFlow/output/bracket_groups.json}"
N_BRACKETS="${BENCH_BRACKETS:-20}"
N_SINGLES="${BENCH_SINGLES:-70}"

LABEL=""
RUNS=2
WARMUP=1
KEEP=2
OUTPUT_ROOT="$BENCH_HOME/out"
CLI="${PHOTOFLOW_CLI_BIN:-}"
PREPARE_ONLY=0
PROTECT_HISTORY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
        --cli) CLI="$2"; shift 2 ;;
        --protect-history) PROTECT_HISTORY=1; shift ;;
        --prepare-only) PREPARE_ONLY=1; shift ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "Okänd flagga: $1" >&2; exit 2 ;;
    esac
done

INPUT_COPY="$BENCH_HOME/input"

# --- 1. Testmängden ----------------------------------------------------------
prepare_input() {
    if [ -f "$INPUT_COPY/testset.json" ]; then
        echo "Testmängden finns redan: $INPUT_COPY ($(find "$INPUT_COPY" -iname '*.NEF' | wc -l | tr -d ' ') NEF)"
        return 0
    fi
    if [ ! -d "$SOURCE_INPUT" ] || [ ! -f "$SOURCE_GROUPS" ]; then
        echo "Källan saknas ($SOURCE_INPUT / $SOURCE_GROUPS) och ingen kopia finns i $INPUT_COPY" >&2
        return 1
    fi
    mkdir -p "$INPUT_COPY"
    SELECTION="$INPUT_COPY/.selection.txt"
    python3 - "$SOURCE_GROUPS" "$N_BRACKETS" "$N_SINGLES" "$INPUT_COPY/testset.json" > "$SELECTION" <<'PY'
import json, sys
groups_file, n_brackets, n_singles, out_file = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
groups = json.load(open(groups_file))["groups"]
brackets = [g for g in groups if g.get("is_bracket")]
single_files = [f for g in groups if not g.get("is_bracket") for f in g["files"]]

def spread(items, n):
    # n jämnt utspridda element (deterministiskt), eller alla om det är färre.
    if len(items) <= n:
        return list(items)
    return [items[int(i * len(items) / n)] for i in range(n)]

chosen_brackets = spread(brackets, n_brackets)
chosen_singles = spread(single_files, n_singles)
files = sorted({f for g in chosen_brackets for f in g["files"]} | set(chosen_singles))
json.dump({
    "source_groups": groups_file,
    "bracket_group_ids": [g["group_id"] for g in chosen_brackets],
    "single_files": chosen_singles,
    "files": files,
}, open(out_file, "w"), indent=1, ensure_ascii=False)
print("\n".join(files))
PY
    [ $? -eq 0 ] || return 1
    echo "Kopierar $(wc -l < "$SELECTION" | tr -d ' ') NEF från $SOURCE_INPUT till $INPUT_COPY ..."
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        cp -p "$SOURCE_INPUT/$f" "$INPUT_COPY/$f" || { echo "Kopiering misslyckades: $f" >&2; return 1; }
    done < "$SELECTION"
    rm -f "$SELECTION"
    echo "Klart: $(find "$INPUT_COPY" -iname '*.NEF' | wc -l | tr -d ' ') NEF, $(du -sh "$INPUT_COPY" | cut -f1) i $INPUT_COPY"
}

prepare_input || exit 1
[ "$PREPARE_ONLY" -eq 1 ] && exit 0

if [ -z "$LABEL" ]; then echo "--label krävs" >&2; exit 2; fi

# --- CLI-binär ----------------------------------------------------------------
if [ -z "$CLI" ]; then
    PRODUCTS=$(xcodebuild -project "$REPO_ROOT/PhotoFlow/PhotoFlow.xcodeproj" -scheme photoflow-cli -configuration Debug -showBuildSettings 2>/dev/null \
        | awk '/^ *BUILT_PRODUCTS_DIR =/ {print $3; exit}')
    CLI="$PRODUCTS/photoflow-cli"
fi
if [ ! -x "$CLI" ]; then echo "Hittar ingen photoflow-cli-binär ($CLI). Bygg med: xcodebuild -scheme photoflow-cli build" >&2; exit 2; fi

# --- 2. Körningar ------------------------------------------------------------
STAMP=$(date +%Y-%m-%d_%H%M%S)
RESULTS="$BENCH_HOME/results/${STAMP}_${LABEL}"
OUT_BASE="$OUTPUT_ROOT/${STAMP}_${LABEL}"
mkdir -p "$RESULTS" "$OUT_BASE"

defaults write photoflow-cli aiDescriptionsEnabled -bool false
{
    echo "etikett: $LABEL"
    echo "startad: $STAMP"
    echo "cli: $CLI"
    echo "cli-commit: $(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null)"
    echo "output-rot: $OUTPUT_ROOT ($(df -h "$OUTPUT_ROOT" 2>/dev/null | awk 'NR==2 {print $1}'))"
    echo "indata: $INPUT_COPY ($(find "$INPUT_COPY" -iname '*.NEF' | wc -l | tr -d ' ') NEF)"
    echo "runs: $RUNS, warmup: $WARMUP"
    echo "maskin: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.physicalcpu) kärnor, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
    echo "--- defaults read photoflow-cli ---"
    defaults read photoflow-cli
} > "$RESULTS/environment.txt"
cp "$INPUT_COPY/testset.json" "$RESULTS/testset.json"

if [ "$PROTECT_HISTORY" -eq 1 ]; then
    SUPPORT="$HOME/Library/Application Support/PhotoFlow"
    mkdir -p "$RESULTS/history-backup"
    for f in step_timings.jsonl sessions.json; do
        if [ -f "$SUPPORT/$f" ]; then cp -p "$SUPPORT/$f" "$RESULTS/history-backup/$f"; else touch "$RESULTS/history-backup/$f.absent"; fi
    done
    restore_history() {
        for f in step_timings.jsonl sessions.json; do
            if [ -f "$RESULTS/history-backup/$f" ]; then cp -p "$RESULTS/history-backup/$f" "$SUPPORT/$f"; else rm -f "$SUPPORT/$f"; fi
        done
        echo "Appens historik (step_timings.jsonl, sessions.json) återställd."
    }
    trap restore_history EXIT
fi

TOTAL=$((WARMUP + RUNS))
for ((i = 1; i <= TOTAL; i++)); do
    if [ "$i" -le "$WARMUP" ]; then NAME="warmup$i"; else NAME="run$((i - WARMUP))"; fi
    RUN_RESULTS="$RESULTS/$NAME"
    OUT="$OUT_BASE/$NAME/output"
    mkdir -p "$RUN_RESULTS/support" "$OUT"
    echo "=== $NAME ($LABEL) -> $OUT"
    T0=$(date +%s)
    PHOTOFLOW_SUPPORT_DIR="$RUN_RESULTS/support" "$CLI" run --input "$INPUT_COPY" --output "$OUT" --no-calendar --json \
        > "$RUN_RESULTS/cli.stdout" 2> "$RUN_RESULTS/cli.stderr"
    STATUS=$?
    T1=$(date +%s)
    echo "$((T1 - T0))" > "$RUN_RESULTS/wall_seconds.txt"
    echo "exit=$STATUS wall=$((T1 - T0)) s"
    sed -n '/PHOTOFLOW_CLI_JSON_SUMMARY_BEGIN/,/PHOTOFLOW_CLI_JSON_SUMMARY_END/p' "$RUN_RESULTS/cli.stdout" \
        | sed '1d;$d' > "$RUN_RESULTS/summary.json"
    for f in timings.jsonl pipeline.log decision_log.jsonl enhancement.json; do
        [ -f "$OUT/$f" ] && cp "$OUT/$f" "$RUN_RESULTS/$f"
    done
    # Äldre körningars output raderas (de är 20-30 GB styck); de $KEEP sista behålls för jämförelse.
    OLD=$((i - KEEP))
    if [ "$OLD" -ge 1 ]; then
        if [ "$OLD" -le "$WARMUP" ]; then OLDNAME="warmup$OLD"; else OLDNAME="run$((OLD - WARMUP))"; fi
        rm -rf "$OUT_BASE/$OLDNAME"
    fi
    if [ "$STATUS" -ne 0 ]; then echo "Körningen misslyckades, se $RUN_RESULTS/cli.stdout" >&2; fi
done

# --- 3. Sammanfattning --------------------------------------------------------
python3 "$SCRIPT_DIR/benchmark-summary.py" "$RESULTS" | tee "$RESULTS/summary.txt"
echo
echo "Resultat: $RESULTS"
echo "Outputmappar (för compare-outputs.sh): $OUT_BASE/<körning>/output"
