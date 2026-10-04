#!/bin/bash
# lr_compare.sh <LR-HDR.dng> <leverans.jpg> <vår-basram.tif|jpg> <ut.jpg>
# 2×2 registrerat mot leveransen: vår nya (basram) / LR-HDR neutral / LR-HDR + vår Mäklarstil / leverans.
# Kräver: photoflow-cli (env CLI), render-raw (env RENDER, CIRAWFilter-neutral), python med numpy/opencv (env PY),
# grid4.py (env GRID). Mellanfiler i $WORK (standard: <ut>-work/).
set -euo pipefail
LR=$1; DEL=$2; OURS=$3; OUT=$4
CLI=${CLI:-photoflow-cli}; RENDER=${RENDER:-render-raw}; PY=${PY:-python3}; GRID=${GRID:-grid4.py}
WORK=${WORK:-${OUT%.*}-work}; mkdir -p "$WORK"
stem=$(basename "${LR%.*}")
# 1. Neutral rendering av LR:s HDR-DNG (CIRAWFilter, linskorrigering, ingen egen look).
"$RENDER" 6000 "$LR" "$WORK/${stem}_neutral.tif" > "$WORK/render.log" 2>&1 || { echo "render-raw kunde inte läsa $LR"; cat "$WORK/render.log"; exit 1; }
# 2. Vårt Förbättra (Mäklarstil + lodlinjer) på samma DNG.
PHOTOFLOW_SUPPORT_DIR="$WORK/support" "$CLI" enhance --input "$LR" --output "$WORK" --enhance-profile maklarstil --upright on | tee "$WORK/enhance.log"
# 3. 2×2.
"$PY" "$GRID" "$OUT" "$DEL" "vår nya (basram)=$OURS" "LR-HDR neutral=$WORK/${stem}_neutral.tif" "LR-HDR + Mäklarstil=$WORK/${stem}_enh.tiff"
