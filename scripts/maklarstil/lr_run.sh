#!/bin/bash
# lr_run.sh — kör lr_compare.sh för alla Lightroom-HDR-DNG:er i ~/PhotoFlowBenchmark/lr-hdr/.
# Gruppen känns igen på något av NEF-numren i filnamnet (LR döper t.ex. "DSC_9051-HDR.dng").
# Resultat: ~/PhotoFlowBenchmark/lr-hdr/jamforelse/<namn>.jpg
set -uo pipefail
B=$HOME/PhotoFlowBenchmark
HERE=$(cd "$(dirname "$0")" && pwd)
OURS_LABEL=${OURS_LABEL:-v2f}
export CLI=${CLI:-$B/lr-hdr/bin/photoflow-cli} RENDER=${RENDER:-$B/lr-hdr/bin/render-raw}
export PY=${PY:-/private/tmp/claude-501/-Users-fredrik-Developer-photo-preprocesser/e36137de-b877-43e6-956a-7990453eec94/scratchpad/venv/bin/python}
export GRID=${GRID:-$HERE/grid4.py}
mkdir -p "$B/lr-hdr/jamforelse"
shopt -s nullglob nocaseglob
for lr in "$B"/lr-hdr/*.dng; do
  n=$(basename "$lr")
  case "$n" in
    *905[1-4]*) del="$B/pilvinge/red/DSC_9053.JPG"; ours="$B/pilvinge/out-$OURS_LABEL/Osorterade FÖRBÄTTRADE/hdr_group_3_enh.tiff" ;;
    *638[3-7]*) del="$B/shoots/varmfrontsgatan-11/red/DSC_6385.jpg"; ours="$B/shoots/varmfrontsgatan-11/out-$OURS_LABEL/Osorterade FÖRBÄTTRADE/hdr_group_10_enh.tiff" ;;
    *) echo "okänd grupp: $n"; continue ;;
  esac
  WORK="$B/lr-hdr/jamforelse/${n%.*}-work" "$HERE/lr_compare.sh" "$lr" "$del" "$ours" "$B/lr-hdr/jamforelse/${n%.*}.jpg"
done
