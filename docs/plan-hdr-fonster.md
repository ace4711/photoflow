# Plan: fönsterutsikt från mörkaste exponeringen (window pull)

Status: fas 0 och fas 1 implementerade (HDREngine v3, se "Genomfört" sist). Lightroom behövs inte.

## Sammanfattning

Huvudorsaken till utfrätta fönster är urvalet, inte algoritmen: **i 49 av 97 riktiga bracket-grupper följer den mörkaste exponeringen aldrig med i HDR:en** (`BracketAnalyzer.findBestHDRSubset` tar bort ramar > 2,5 EV under medianen). Därtill ger ren Mertens-fusion gråa fönster och haloer, och Förbättra-steget kan klippa fönstren igen.

Rekommendation: egen window pull *efter* fusionen — luminansbaserad fönstermask, kantmedvetet förfinad mot mörkaste exponeringen, hela fönstret från en enda exponeringsmatchad ram — plus en maskmedveten Förbättra.

## 1. Brister i dag

### A. Flödesfel (rättas direkt)
1. Mörkaste ramen sorteras bort i 49/97 grupper; mörkaste använda ram är då 1,3–2,3 EV ljusare och fönstret klippt i alla ramar fusionen ser.
2. `reMergeHDR` skickar ramarna i tagningsordning men `HDREngine.merge` tar `count/2` som referens → fel vitbalans/registreringsreferens vid Nikons 0/−/+-ordning.
3. Omgjord HDR syns inte om förbättrad bild finns (`finalPreviewURL` väljer den förbättrade, och omsammanslagning kör inte Förbättra).
4. Att höja `HDREngine.version` gör inte om HDR: `runHDRMerge` hoppar över grupper vars TIFF finns. "Kör om steget" raderar bara `hdr/`, sorterade filer hoppas över.

### B. Mertens-fusionens begränsningar (`ExposureFusion.swift`)
- Välexponeringsvikt (gauss 0,5, σ 0,2, produkt över kanaler) fungerar bara om mörk ram finns; annars snitt av klippta ramar → grått.
- Delvis klippta pixlar får hög mättnadsvikt → cyan/gul nyans.
- Kontrastvikt 3×3 Laplace på full upplösning mäter mest brus.
- 8 pyramidnivåer: grova nivåer blandar fönstrets låga frekvenser med interiörens → glöd, mörk ring runt karm, gråslöja.
- `boostAmount = 1.0` komprimerar högdagrar redan före fusion.
- Rörelse (träd, moln) → spöken; global translation på 8-bit gråskala av olika exponerade ramar kan misslyckas.
- En vitbalans för alla ramar → blå utsikt mot varm interiör.

### C. Förbättra-steget
- Gray-world-vitbalansen (luma 0,20–0,85) påverkas av utdragen utsikt.
- Exponering (+0,9 EV) och vitpunkt (p99,9) kan klippa fönstren igen.
- Clarity (radie ≈ 60 px) ger haloer vid karmar.

## 2. Lösning

Ny `Services/HDR/WindowPull.swift` (ren `nonisolated enum`), anropas i `HDREngine.merge` efter fusion, före skärpning.

**0. Förutsättningar**
- Mörkaste ramen skickas alltid som `windowSourceURL` (fusionen använder fortfarande `suggested_hdr_indices`; `bracket_groups.json` oförändrad).
- `merge` får exponeringstider, sorterar själv, referens = median (rättar A2).
- Registrering efter exponeringsmatchning (gain/histogram) eller på gradientbilder; verifiera med fasskorrelation.

**a) Detektering** (≈ 1500 px)
- Referensen klippt (max-kanal ≥ 0,96), mörka ramen informativ (max ≤ 0,95, luma ≥ 0,08), scenluminans ≥ ~4 × interiörmedian.
- Morfologi: öppning ~3 px, stängning ~9 px.
- Komponenter: släng < 0,05 % av ytan; lampor (små, platt vita även i mörk ram) separat; stor region mot överkant = himmel (exteriör) → låg/ingen styrka.
- AI-taggar Interiör/Exteriör styr standardläge. ML-segmentering (ADE20K "windowpane") som fas 5.

**b) Kantmedveten mask**
- Uppskalning + guided filter med mörka ramens luma som guide (radie ≈ 0,2 % av långsidan, eps ≈ 1e‑3), vImage-boxfilter. Dilatera 1–2 px för att ersätta överstrålning.

**c) Blandning**
- Gain så att fönstrets median ≈ 0,62–0,72 (inställning "Fönsterljushet"), p99 i masken < 0,97; mörk ram ev. renderad med `boostAmount` ≈ 0,5.
- Efter fusion: `ut = (1 − m·s)·fusion + m·s·mörkMatchad`. Pyramidvariant bara för A/B.

**d) Spökskydd**
- Hela fönstret från en ram; spökkarta i band ±32 px kring maskkanten drar in masken där referens och mörk ram skiljer sig.

**e) Färg**
- "Fönsterfärg": som interiören / dagsljus (standard, omrendering ~5500 K, ~2 s) / halvvägs.
- Masken sparas (`hdr_masks/hdr_group_N.png`, i outputroten) och Förbättra utesluter den ur statistiken, dämpar exponering/högdagrar och clarity i/vid masken; masken följer rotation/beskärning.

### Alternativ
| Alternativ | Bedömning |
|---|---|
| Bias i Mertens-vikter | Komplement (straff för delvis klippta pixlar), löser inte haloer |
| Debevec-radiansmerge + lokal tonmappning | Långsiktigt (fas 5), stor insats |
| Apples API:er | Byggstenar (CIRAWFilter, morfologi), ingen färdig HDR/fönstersegmentering |
| Lightroom Classic | SDK saknar Photo Merge-API, GUI-styrning skör, ingen automatisk window pull — rekommenderas inte |
| Externa verktyg/tjänster | Endast som referens |

## 3. Mätplan
- `scripts/window-testset.py` väljer ~30 grupper (20 med fönster, 5 med rörelse, 5 exteriör/lampor) **skrivskyddat** från `/Volumes/photo-ingestion/PhotoFlow/output` och kopierar till `~/PhotoFlowBenchmark/windows/`.
- `photoflow-cli run --hdr-debug --window-pull on|off --window-strength N`; A/B med `benchmark.sh --label` och `compare-outputs.sh`.
- Mått: klippt andel i masken (< 2 %), struktur vs mörk ram (≥ 0,8), gråslöja (p5–p95, mättnad), halobredd (< 8 px, < 3 %), spöken, kvarvarande förskjutning (> 1 px flaggas), maskkvalitet (manuellt), fönsterkroma, tid (< 2,5 s/grupp med extra rendering) och minne (+0,4 GB).
- `scripts/window-compare.py` → statisk sida med före/efter-reglage, maskoverlay, mörk råbild, 100 %-utsnitt, mått och bättre/sämre/lika-knappar.

## 4. Versionering och inställningar
- Ny `hdr.json` per session (motorversion, fingerprint, fönsterstatistik); grupper görs om när fingerprint ändras. "Kör om steget" rensar loggen.
- `HDREngine.version = 3` (gör även om Förbättra). Inställning "Gör om befintliga HDR när motorn uppdaterats": Fråga (standard) / Alltid / Aldrig.
- Inställningar: fönster från mörkaste (på), styrka (85 %), ljushet (0), fönsterfärg (dagsljus), även lampor/himmel (av / på / bara exteriör).
- Per grupp i `hdr_overrides.json`: läge, källram, styrka, ljushet — ingår i fingerprint.

## 5. Granska-läget
- Fönsterpanel: Auto / Av / Från exponering X (miniatyrer efter EV), reglage för styrka och ljushet med snabb förhandsvisning (cache ~1500 px).
- "Visa mask" (M), före/efter (håll B), knapp "Gör om HDR" som kedjar HDR + Förbättra.
- Varningsmärken: fönster fortfarande klippta, rörelse i utsikten, osäker registrering.

## 6. Faser
| Fas | Innehåll | Insats |
|---|---|---|
| 0 | Rätta flödet: mörkaste ram som fönsterkälla, EV-sortering/medianreferens, `hdr.json`, omsammanslagning kedjad till Förbättra | 1–1,5 d |
| 1 | `WindowPull.swift`, straff för delvis klippta pixlar, exponeringsnormaliserad registrering, `--hdr-debug`, tester | 3–4 d |
| 2 | Maskmedveten Förbättra (`EnhancementEngine.version = 2`) | 1,5–2 d |
| 3 | Mätning och jämförelsesida (parallellt med 1–2) | 2 d |
| 4 | Inställningar och granska-UI | 2–3 d |
| 5 | Valfritt: dagsljusomrendering, spökborttagning i fusion, ML-segmentering, radiansmerge | 3–10 d |

Risker: felträffar (lampor, blanka golv), onaturlig himmel i exteriörer, brus i mörk ram (välj näst mörkaste vid gain > 1,5 EV), dubbla karmar vid dålig registrering, att levererade sessioner skrivs över (Fråga), +2 s per grupp i 49/97 grupper.

Kritiska filer: `Services/HDR/HDREngine.swift`, `ExposureFusion.swift`, nya `WindowPull.swift`, `PipelineRunner+HDR.swift`, `Enhancement/EnhancementEngine.swift`, `Views/BracketReviewView.swift`, `BracketAnalyzer.swift:220`, `HDRAlignment.swift`, `RAWRenderer.swift`, `AppSettings.swift`, `SettingsView.swift`, `PhotoFlowCLI.swift`.

## Genomfört (fas 0–1, 2026-10-04)

- `HDREngine.merge(frames:windowSource:)`: exponeringar med exponeringstid, sorterade mörkast först, referens = medianen. Gruppens mörkaste exponering skickas som fönsterkälla (renderas extra när förslaget sorterat bort den). `HDREngine.version = 3`.
- `hdr.json` (`HDRLog`): motorversion, fingerprint (NEF-namn + storlek, HDR- och fönsterinställningar), fönsterstatistik, `mergedAt`, granskningens urval (`manualSelection`). HDR-steget gör om vid saknad fil eller ändrat fingerprint och skriver där filen ligger (även sorterade adressmappar). **Befintliga HDR utan post adopteras** med motorversion 2 och görs inte om. Inställningen "Gör om befintliga HDR när motorn uppdaterats": **Aldrig (standard)** / Alltid. Fråga planeras som standard när dialogen finns (fas 4); värdet `ask` beter sig till dess som Aldrig. "Kör om steget" rensar loggen och gör om alla grupper.
- Omsammanslagning i granskningen förbättrar gruppen direkt (`reEnhanceHDRGroup`), och Förbättra-steget gör om en förbättring som är äldre än HDR:en (`mergedAt`).
- Registrering: histogrammatchning före Vision, **rättat tecken på den lodräta förskjutningen** (den gick åt fel håll sedan justeringen infördes — 2 px blev 4 px), och förskjutningar > 3 px verifieras genom ommätning (avvisar felregistreringar på 18 px för ramar 6–7 EV under referensen).
- `WindowPull.swift` enligt 2 a–d plus: hålfyllnad, tillväxt in i fönsterpartier som är klippta även i mörka ramen, bortsortering av släta ytor (textur < 0,02, färgstarka < 0,045) och golv/reflexer (överkant under 55 % av höjden), lampor kräver låg textur (< 0,09), maskens spridning högst 4 px utanför detekteringen. Straff för klippta pixlar i Mertens-vikterna.
- CLI: `--window-pull on|off`, `--window-strength N`, `--hdr-debug` (mask, mörkMatchad, fusion utan pull, `hdr_metrics.json` per grupp i `hdr_debug/`). Skript: `window-testset.py`, `window-compare.py`.

### Mätning (30 grupper, `~/PhotoFlowBenchmark/results/windows-2026-10-04/`)

Pull kördes i 22 av 30 grupper (8: inga fönster — oftast när mörkaste ramen bara är 1–2 EV mörkare, eller släta ytor). Median (värsta) över de 22:

| Mått | Utan pull | Med pull | Mål |
|---|---|---|---|
| Klippt i mask | 46 % (98 %) | 0,3 % (5,2 %) | < 2 % |
| Struktur vs mörk ram | 0,65 (0,33) | 0,985 (0,93) | ≥ 0,8 |
| Pullens halo utanför masken | – | 6 px (12 px) | < 8 px |
| Pull-tid | – | 0,49 s (0,56 s) | < 2,5 s |
| HDR-tid per grupp (inkl. extra rendering och felsökningsfiler) | 11,8 s | 15,1 s | |

Kända brister: fönster mot mulen himmel blir grå (textur för låg för att sorteras bort, men inget att hämta); reflexer i TV-skärm/spegel dras in; klippta partier som även är klippta i mörka ramen blir jämngrå när gain < 1; halo-måttet mot referensramen är grovt.
