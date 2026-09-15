#!/usr/bin/env bash
set -euo pipefail

# PhotoFlow NEF Processing Pipeline
# Usage: process-nef.sh <input-dir> [output-dir]
#
# Steps:
#   1. Convert NEF -> DNG (Adobe DNG Converter)
#   2. Analyze EXIF to detect exposure bracket groups
#   3. Organize files into bracket groups (symlinks)
#   4. Generate JPEG previews for quick culling

# --- Configuration ---
MAX_TIME_GAP=15        # Max seconds between shots in same bracket group
MIN_BRACKET_SIZE=3     # Minimum images to be considered a bracket series
PREVIEW_QUALITY=85     # JPEG preview quality (1-100)
PREVIEW_MAX_DIM=2400   # Max dimension for preview images
DNG_CONVERTER="/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"

# --- Arguments ---
INPUT_DIR="${1:?Usage: process-nef.sh <input-dir> [output-dir]}"
OUTPUT_DIR="${2:-${INPUT_DIR}/processed}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory does not exist: $INPUT_DIR"
    exit 1
fi

# Count NEF files
NEF_COUNT=$(find "$INPUT_DIR" -maxdepth 1 \( -name "*.NEF" -o -name "*.nef" \) | wc -l | tr -d ' ')
if [ "$NEF_COUNT" -eq 0 ]; then
    echo "ERROR: No NEF files found in $INPUT_DIR"
    exit 1
fi

echo "=== PhotoFlow NEF Pipeline ==="
echo "Input:  $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "Found:  $NEF_COUNT NEF files"
echo ""

# Create output directories
DNG_DIR="$OUTPUT_DIR/dng"
PREVIEW_DIR="$OUTPUT_DIR/previews"
GROUPS_DIR="$OUTPUT_DIR/bracket_groups"
mkdir -p "$DNG_DIR" "$PREVIEW_DIR" "$GROUPS_DIR"

# ============================================================
# STEP 1: Convert NEF -> DNG (Adobe DNG Converter)
# ============================================================
echo "--- Step 1: Converting NEF -> DNG ---"

if [ ! -x "$DNG_CONVERTER" ]; then
    echo "  WARNING: Adobe DNG Converter not found at $DNG_CONVERTER"
    echo "  Skipping DNG conversion. Install from: brew install --cask adobe-dng-converter"
else
    EXISTING_DNG=$(find "$DNG_DIR" -maxdepth 1 -name "*.dng" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$EXISTING_DNG" -eq "$NEF_COUNT" ]; then
        echo "  All $NEF_COUNT DNG files already exist, skipping conversion."
    else
        echo "  Converting $NEF_COUNT NEF files to DNG (this may take a while)..."
        # Adobe DNG Converter needs individual file paths
        find "$INPUT_DIR" -maxdepth 1 \( -name "*.NEF" -o -name "*.nef" \) -print0 | \
            xargs -0 "$DNG_CONVERTER" -c -d "$DNG_DIR" 2>&1 | \
            while IFS= read -r line; do [ -n "$line" ] && echo "  $line"; done
        DNG_COUNT=$(find "$DNG_DIR" -maxdepth 1 -name "*.dng" 2>/dev/null | wc -l | tr -d ' ')
        echo "  Converted: $DNG_COUNT DNG files created."
    fi
fi
echo ""

# ============================================================
# STEP 2: Analyze EXIF & detect bracket groups
# ============================================================
echo "--- Step 2: Analyzing EXIF data & detecting brackets ---"

# Extract EXIF data to CSV directly from NEF files
EXIF_CSV="$OUTPUT_DIR/exif_data.csv"
exiftool -csv \
    -FileName \
    -ExposureTime \
    -FNumber \
    -ISO \
    -DateTimeOriginal \
    -SubSecTimeOriginal \
    -ExposureCompensation \
    -ShutterCount \
    "$INPUT_DIR"/*.NEF > "$EXIF_CSV" 2>/dev/null || \
exiftool -csv \
    -FileName \
    -ExposureTime \
    -FNumber \
    -ISO \
    -DateTimeOriginal \
    -SubSecTimeOriginal \
    -ExposureCompensation \
    -ShutterCount \
    "$INPUT_DIR"/*.nef > "$EXIF_CSV" 2>/dev/null

echo "  EXIF data extracted to exif_data.csv"

# Parse EXIF and group brackets
GROUPS_JSON="$OUTPUT_DIR/bracket_groups.json"
PYTHON_EXIF_CSV="$EXIF_CSV" PYTHON_GROUPS_JSON="$GROUPS_JSON" PYTHON_MAX_GAP="$MAX_TIME_GAP" PYTHON_MIN_SIZE="$MIN_BRACKET_SIZE" python3 << 'PYTHON_SCRIPT'
import csv
import json
import os
import math
from datetime import datetime

exif_csv = os.environ['PYTHON_EXIF_CSV']
output_json = os.environ['PYTHON_GROUPS_JSON']
max_time_gap = int(os.environ['PYTHON_MAX_GAP'])
min_bracket_size = int(os.environ['PYTHON_MIN_SIZE'])

def parse_exposure(exp_str):
    exp_str = exp_str.strip()
    if '/' in exp_str:
        parts = exp_str.split('/')
        return float(parts[0]) / float(parts[1])
    return float(exp_str)

def parse_datetime(dt_str):
    try:
        return datetime.strptime(dt_str.strip(), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None

def ev(exp):
    if exp <= 0: return 0
    return math.log2(exp)

# Read EXIF data
images = []
with open(exif_csv, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        dt = parse_datetime(row.get('DateTimeOriginal', ''))
        if dt is None:
            continue
        try:
            exp = parse_exposure(row.get('ExposureTime', '0'))
        except (ValueError, ZeroDivisionError):
            exp = 0
        try:
            fnumber = float(row.get('FNumber', '0'))
        except ValueError:
            fnumber = 0
        try:
            iso = int(row.get('ISO', '0'))
        except ValueError:
            iso = 0

        subsec = row.get('SubSecTimeOriginal', '0')
        try:
            subsec_val = int(subsec)
        except ValueError:
            subsec_val = 0
        precise_ts = dt.timestamp() + subsec_val / 100.0

        images.append({
            'filename': row['FileName'],
            'datetime': dt,
            'exposure': exp,
            'fnumber': fnumber,
            'iso': iso,
            'exposure_str': row.get('ExposureTime', ''),
            'precise_ts': precise_ts,
        })

# Sort by filename (DSC_XXXX sequence order)
images.sort(key=lambda x: x['filename'])

# Phase 1: Group by time proximity + same aperture/ISO
raw_groups = []
current_group = [images[0]] if images else []

for i in range(1, len(images)):
    prev = images[i - 1]
    curr = images[i]
    time_diff = curr['precise_ts'] - prev['precise_ts']
    same_settings = (curr['fnumber'] == prev['fnumber'] and curr['iso'] == prev['iso'])

    if time_diff <= max_time_gap and same_settings:
        current_group.append(curr)
    else:
        raw_groups.append(current_group)
        current_group = [curr]

if current_group:
    raw_groups.append(current_group)

# Phase 2: Split groups that contain multiple bracket sub-sequences
def find_bracket_subsequences(group):
    """Split a group if it contains multiple bracket takes (detected by time gaps
    or repeating exposure patterns)."""
    if len(group) <= 3:
        return [group]

    n = len(group)
    exps = [img['exposure'] for img in group]
    evs = [ev(e) for e in exps]

    # Detect time gaps within the group - a gap >6s suggests a new bracket take
    sub_seqs = []
    current_seq = [0]
    for i in range(1, n):
        gap = group[i]['precise_ts'] - group[i-1]['precise_ts']
        if gap > 6.0:
            sub_seqs.append(current_seq)
            current_seq = [i]
        else:
            current_seq.append(i)
    sub_seqs.append(current_seq)

    if len(sub_seqs) > 1:
        return [[group[i] for i in seq] for seq in sub_seqs]

    # Look for repeating bracket patterns (e.g. two 3-shot brackets)
    for pat_len in [3, 4, 5]:
        if n >= pat_len * 2 and n <= pat_len * 2 + 2:
            first_evs = sorted(evs[:pat_len])
            second_evs = sorted(evs[pat_len:pat_len*2])
            if len(second_evs) >= pat_len:
                spread1 = first_evs[-1] - first_evs[0]
                spread2 = second_evs[-1] - second_evs[0]
                if spread1 > 1.0 and spread2 > 1.0 and abs(spread1 - spread2) < 2.0:
                    result = [group[:pat_len], group[pat_len:pat_len*2]]
                    if n > pat_len * 2:
                        result.append(group[pat_len*2:])
                    return result

    return [group]

groups = []
for rg in raw_groups:
    groups.extend(find_bracket_subsequences(rg))

# Phase 3: Classify groups and find optimal HDR subsets
def find_best_hdr_subset(group):
    """Select the optimal photos for HDR: one per unique EV level, sorted dark to bright."""
    exps = [(i, img['exposure']) for i, img in enumerate(group)]
    if len(exps) <= 1:
        return list(range(len(group)))

    # Remove duplicate exposures (keep first of each unique EV level, within 0.3 EV)
    unique = []
    for idx, exp_val in exps:
        ev_val = ev(exp_val)
        is_dup = False
        for uidx, uexp in unique:
            if abs(ev(uexp) - ev_val) < 0.3:
                is_dup = True
                break
        if not is_dup:
            unique.append((idx, exp_val))

    # Sort by exposure value (dark to bright)
    unique.sort(key=lambda x: x[1])
    return [u[0] for u in unique]

output = {
    'total_images': len(images),
    'total_groups': len(groups),
    'groups': []
}

for i, group in enumerate(groups):
    exposures = [img['exposure'] for img in group]
    exp_range = max(exposures) / max(min(exposures), 0.0001) if min(exposures) > 0 else 0

    # Better bracket detection: require min unique EV levels
    unique_evs = set()
    for e in exposures:
        ev_val = round(ev(e) * 3) / 3  # quantize to 1/3 EV
        unique_evs.add(ev_val)

    has_enough_unique = len(unique_evs) >= min_bracket_size
    has_range = exp_range > 2.0
    is_bracket = has_enough_unique and has_range

    hdr_indices = find_best_hdr_subset(group) if is_bracket else []

    files_nef = []
    for img in group:
        name = img['filename']
        base = name.rsplit('.', 1)[0]
        files_nef.append(base + '.NEF')

    group_info = {
        'group_id': i + 1,
        'is_bracket': is_bracket,
        'image_count': len(group),
        'files': files_nef,
        'exposures': [img['exposure_str'] for img in group],
        'fnumber': group[0]['fnumber'],
        'iso': group[0]['iso'],
        'time_start': group[0]['datetime'].strftime('%H:%M:%S'),
        'time_end': group[-1]['datetime'].strftime('%H:%M:%S'),
        'exposure_range_stops': round(exp_range, 1),
        'suggested_hdr_indices': hdr_indices,
        'unique_exposure_levels': len(unique_evs),
    }
    output['groups'].append(group_info)

# Summary
bracket_groups = [g for g in output['groups'] if g['is_bracket']]
single_groups = [g for g in output['groups'] if not g['is_bracket']]
output['bracket_groups_count'] = len(bracket_groups)
output['single_groups_count'] = len(single_groups)

with open(output_json, 'w') as f:
    json.dump(output, f, indent=2)

# Print summary
print(f"  Total images: {output['total_images']}")
print(f"  Groups found: {output['total_groups']}")
print(f"  Bracket groups (HDR candidates): {len(bracket_groups)}")
print(f"  Single/non-bracket groups: {len(single_groups)}")
print()

for g in output['groups']:
    marker = " [HDR BRACKET]" if g['is_bracket'] else ""
    first = g['files'][0].replace('.NEF','')
    last = g['files'][-1].replace('.NEF','')
    files_short = f"{first}..{last}" if len(g['files']) > 1 else g['files'][0]
    sel = ""
    if g['suggested_hdr_indices']:
        sel_files = [g['files'][j].replace('.NEF','') for j in g['suggested_hdr_indices']]
        sel_exps = [g['exposures'][j] for j in g['suggested_hdr_indices']]
        sel = f" -> HDR: {', '.join(sel_exps)}"
    print(f"  Group {g['group_id']:3d}: {g['image_count']:2d} imgs ({g['unique_exposure_levels']} unika EV) | f/{g['fnumber']} ISO{g['iso']} | {g['time_start']}-{g['time_end']} | {files_short} | exp: {', '.join(g['exposures'])}{marker}{sel}")

PYTHON_SCRIPT

echo ""

# ============================================================
# STEP 3: Organize files into bracket group folders (symlinks)
# ============================================================
echo "--- Step 3: Organizing bracket groups ---"

PYTHON_GROUPS_JSON="$GROUPS_JSON" PYTHON_SOURCE_DIR="$INPUT_DIR" PYTHON_DNG_DIR="$DNG_DIR" PYTHON_GROUPS_DIR="$GROUPS_DIR" python3 << 'PYTHON_SCRIPT'
import json
import os

groups_json = os.environ['PYTHON_GROUPS_JSON']
source_dir = os.environ['PYTHON_SOURCE_DIR']
dng_dir = os.environ['PYTHON_DNG_DIR']
groups_dir = os.environ['PYTHON_GROUPS_DIR']

with open(groups_json, 'r') as f:
    data = json.load(f)

for group in data['groups']:
    gid = group['group_id']
    is_bracket = group['is_bracket']

    if is_bracket:
        folder_name = f"bracket_{gid:03d}_HDR_{group['image_count']}exp"
    else:
        folder_name = f"single_{gid:03d}_{group['image_count']}img"

    group_folder = os.path.join(groups_dir, folder_name)
    os.makedirs(group_folder, exist_ok=True)

    linked = 0
    for filename in group['files']:
        # Symlink NEF
        src_nef = os.path.join(source_dir, filename)
        dst_nef = os.path.join(group_folder, filename)
        if os.path.exists(src_nef) and not os.path.exists(dst_nef):
            os.symlink(os.path.abspath(src_nef), dst_nef)
            linked += 1

        # Symlink DNG if it exists
        dng_name = filename.rsplit('.', 1)[0] + '.dng'
        src_dng = os.path.join(dng_dir, dng_name)
        dst_dng = os.path.join(group_folder, dng_name)
        if os.path.exists(src_dng) and not os.path.exists(dst_dng):
            os.symlink(os.path.abspath(src_dng), dst_dng)

    print(f"  {folder_name}: {len(group['files'])} files")

PYTHON_SCRIPT

echo ""

# ============================================================
# STEP 4: Generate JPEG previews from NEF files
# ============================================================
echo "--- Step 4: Generating JPEG previews ---"

# Use exiftool to extract the embedded JPEG preview from NEF files
# This is MUCH faster than decoding the RAW data
PREVIEW_COUNT=0
SKIP_COUNT=0

for nef_file in "$INPUT_DIR"/*.NEF "$INPUT_DIR"/*.nef; do
    [ -f "$nef_file" ] || continue

    basename_noext=$(basename "$nef_file" | sed 's/\.[^.]*$//')
    preview_file="$PREVIEW_DIR/${basename_noext}.jpg"

    if [ -f "$preview_file" ]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Extract embedded JPEG preview (fast - no RAW decode needed)
    exiftool -b -JpgFromRaw "$nef_file" > "$preview_file" 2>/dev/null

    # Copy orientation from NEF to preview JPEG so rotated images display correctly
    if [ -s "$preview_file" ]; then
        exiftool -TagsFromFile "$nef_file" -Orientation -overwrite_original "$preview_file" 2>/dev/null || true
    fi

    # If no embedded preview, fall back to sips
    if [ ! -s "$preview_file" ]; then
        sips -s format jpeg \
             -s formatOptions "$PREVIEW_QUALITY" \
             --resampleHeightWidthMax "$PREVIEW_MAX_DIM" \
             "$nef_file" --out "$preview_file" > /dev/null 2>&1 || true
    fi

    if [ -s "$preview_file" ]; then
        PREVIEW_COUNT=$((PREVIEW_COUNT + 1))
    else
        rm -f "$preview_file"
    fi

    # Progress every 10 files
    if [ $((PREVIEW_COUNT % 10)) -eq 0 ] && [ "$PREVIEW_COUNT" -gt 0 ]; then
        echo "  Generated $PREVIEW_COUNT previews..."
    fi
done

echo "  Generated $PREVIEW_COUNT new previews ($SKIP_COUNT already existed)"
echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Pipeline Complete ==="
echo "  Original NEFs:   $INPUT_DIR"
echo "  Bracket groups:  $GROUPS_DIR"
echo "  JPEG previews:   $PREVIEW_DIR"
echo "  EXIF data:       $EXIF_CSV"
echo "  Group analysis:  $GROUPS_JSON"
echo ""
echo "Next steps:"
echo "  - Review bracket groups in $GROUPS_DIR"
echo "  - Use PhotoFlow app to cull previews in $PREVIEW_DIR"
echo "  DNG files:       $DNG_DIR"
echo "  - HDR merge bracket groups in Lightroom"
