# Plan: fönsterutsikt från mörkaste exponeringen (window pull)

Status: plan, inget implementerat. Lightroom behövs inte.

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
