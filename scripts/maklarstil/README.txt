Analysskript för Mäklarstil (docs/plan-maklarstil.md). Kräver en venv med numpy, opencv-python-headless,
scipy, pillow. Läser bara från /Volumes (pair_shoot.py kopierar till ~/PhotoFlowBenchmark/...).

  pair_shoot.py     parar red-leveranser med NEF-bracketgrupper och kopierar grupp + skicka-DNG + leverans
  render-raw.swift  neutral CIRAWFilter-rendering (linskorrigering på), swiftc -O render-raw.swift -o render-raw
  build_pairs.py    pairs.json: leverans ↔ skicka-rendering, vår HDR (före Förbättra), vår förbättrade bild
  analyze.py        homografiregistrering (SIFT + MAGSAC) och mått per par (tonkurva, väggar, HSL,
                    bandpass, brus, skärpa, vinjettering, lodlinjer, beskärning, ΔE2000)
  groupstats.py     receptet per grupp (interiör/exteriör) med spridning
  proto.py/proto4.py  prototyp av looken i Python (val av konstanter, träning/test)
  extdet.py         utomhuspoäng (grönska + himmel) per bild
  compare.py        nuvarande vs ny mot leveransen per grupp
  windows.py/winsum.py  fönsteranalys: ljushet, kontrast, färg, halo, vilken exponering utsikten liknar
Sökvägarna (resultatfiler i arbetskatalogen, ~/PhotoFlowBenchmark/...) är hårdkodade för körningen 2026-10-04.
