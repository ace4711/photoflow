#!/usr/bin/env python3
"""Sammanfattar en riktmärkesresultatkatalog (skapad av scripts/benchmark.sh).

Per steg: tid (median och min över de mätta körningarna `run*`), plus resursdata
(CPU, kärnor i snitt, disk läst/skriven, toppminne) från step_timings.jsonl. Därefter
de tyngsta delfaserna ur timings.jsonl (summerad tid per steg/fas, medel över körningarna).
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

results = Path(sys.argv[1])
runs = sorted(p for p in results.iterdir() if p.is_dir() and p.name.startswith("run"))
if not runs:
    print("Inga mätta körningar i", results)
    sys.exit(0)


def load_jsonl(path):
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


steps = defaultdict(list)       # stegnamn -> [sekunder per körning]
resources = defaultdict(list)   # stegnamn -> [post per körning]
totals = []
for run in runs:
    summary_file = run / "summary.json"
    if summary_file.exists():
        summary = json.loads(summary_file.read_text())
        totals.append(summary.get("totalSeconds", 0))
        for s in summary.get("steps", []):
            if s.get("durationSeconds") is not None:
                steps[s["step"]].append(s["durationSeconds"])
    for rec in load_jsonl(run / "support" / "step_timings.jsonl"):
        resources[rec["step"]].append(rec)



def mb(x):
    return f"{x / 1048576:,.0f}".replace(",", " ")


print(f"Resultat: {results.name}  ({len(runs)} mätta körningar)")
if totals:
    print(f"Total tid (CLI): median {statistics.median(totals):.1f} s, min {min(totals):.1f} s, körningar {[round(t, 1) for t in totals]}")
print()
print(f"{'Steg':<34}{'median s':>10}{'min s':>9}")
for name, values in steps.items():
    print(f"{name:<34}{statistics.median(values):>10.1f}{min(values):>9.1f}")

if resources:
    print()
    print("Resurser per steg (median över körningarna; disk = app + barnprocesser, se ChildDiskTracker)")
    print(f"{'Steg':<22}{'tid s':>8}{'CPU s':>9}{'kärnor':>8}{'läst MB':>10}{'skrivet MB':>12}{'minne MB':>10}")
    for key, recs in resources.items():
        def med(field):
            vals = [r[field] for r in recs if r.get(field) is not None]
            return statistics.median(vals) if vals else None
        secs, cpu = med("seconds"), med("cpuSeconds")
        if cpu is None:
            print(f"{key:<22}{secs:>8.1f}   (ingen resursdata)")
            continue
        cores = cpu / secs if secs else 0
        print(f"{key:<22}{secs:>8.1f}{cpu:>9.1f}{cores:>8.1f}{mb(med('diskReadBytes') or 0):>10}{mb(med('diskWriteBytes') or 0):>12}{med('peakMemoryMB') or 0:>10.0f}")

# Delfaser/jobb ur timings.jsonl: summerad tid per (steg, fas), medel över körningarna.
phase_totals = defaultdict(float)
phase_counts = defaultdict(int)
for run in runs:
    for rec in load_jsonl(run / "timings.jsonl"):
        key = (rec["step"], rec.get("phase") or "(jobb)")
        phase_totals[key] += rec["seconds"]
        phase_counts[key] += 1
if phase_totals:
    print()
    print("Summerad tid per steg/delfas (medel per körning; summan av alla jobb, överlappar inte med väggtid vid samtidighet)")
    print(f"{'Steg':<12}{'Delfas':<22}{'antal':>7}{'summa s':>10}{'s/st':>8}")
    for (step, phase), total in sorted(phase_totals.items(), key=lambda kv: (kv[0][0], -kv[1])):
        n = phase_counts[(step, phase)] / len(runs)
        print(f"{step:<12}{phase:<22}{n:>7.0f}{total / len(runs):>10.1f}{total / phase_counts[(step, phase)]:>8.2f}")
