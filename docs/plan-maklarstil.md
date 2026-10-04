# Mäklarstil: härma redigerarens leveranser

Status: genomförd 2026-10-04 (Förbättra v3: `BrokerLook.swift`, `VerticalCorrection.swift`). Analysskript i `scripts/maklarstil/`, jämförelsesida i `~/PhotoFlowBenchmark/results/pilvinge-2026-10-04/index.html`.

## Underlag

Fem adresser, bara grupper som har en leverans (kopior i `~/PhotoFlowBenchmark/pilvinge/` och `~/PhotoFlowBenchmark/shoots/<adress>/`, `groups.csv` = skickad/levererad per NEF för framtida gallring):

| Adress | Roll | Par | Karaktär |
|---|---|---|---|
| Pilvingegatan 77 | 16 träning + 7 test | 23 | interiörer, 4 balkonger |
| Bergstigen 105 | träning | 6 | 3 interiörer, 3 trädgård |
| Pilottorget 3 | träning | 8 | balkonger/gård (exteriör) |
| Ballonggatan 7 | träning | 6 | interiörer |
| Varmfrontsgatan 11 | **hållen adress** (test) | 8 | interiörer |

Flödet hos redigeraren (XMP-historiken): fotografen konverterar 2–3 ramar per bracket till DNG i Lightroom (standardinställningar, inga crs-justeringar), redigeraren öppnar dem i Camera Raw → TIFF → Photoshop (manuell blandning/retusch) → JPEG → sista Camera Raw-pass (Transform/Upright; alla reglage nollade vid export). Parametrarna går alltså inte att läsa ut — receptet är skattat ur pixlarna efter homografiregistrering (SIFT + MAGSAC, rms 0,3–1,3 px på 1600 px).

## Receptet (leveranserna, median och spridning)

| Egenskap | Interiör | Exteriör | Konsekvens |
|---|---|---|---|
| Ljushet (gammakodad luma) | p1 0,095 · p5 0,21 · p25 0,48 · median 0,685 · p75 0,80 · p95 0,905 · p99 0,963 | p5 0,13 · median 0,57 · p95 0,89 · p99 0,957 | taket mycket stabilt (IQR 0,02–0,03), median IQR 0,10; per adress median 0,66–0,70 |
| Vita väggar | L* 85–88, b* +1,1…+2,1 (nästan neutralt, svagt varmt) | L* ≈ 90 | stabilt mellan alla adresser |
| Mättnad | ~20 % under neutral RAW-rendering, gult/orange mest dämpat | 40–60 % mer krominans än neutral rendering, lila dämpat | två olika recept |
| Lokal kontrast | textur +10–20 %, clarity ±0 | textur +20–30 %, stor skala −8 % | måttligt |
| Brus | luminans 0,17–0,34 L* (vår HDR 0,42), krominansbrus ≈ 0 | ingen NR, skarpare (+40 %) | stabilt inne |
| Vinjettering | ingen | ingen | |
| Lodlinjer | rätade: 0,28° kvar (vår 0,65°) | delvis | |
| Beskärning | 3:2, ~4,5 % av ytan (≈ 2 % per sida) | ~3,5 % | |

Vårt nuvarande Automatisk ligger mörkt (väggar L* 66 mot 86), för mättat (krominans 16 mot 11) och med varierande färgstick (väggars b* −10…+20).

## Implementering

- **`BrokerLook`** (profil `maklarstil`, "Mäklarstil"): vitbalans som gör neutrala ytor neutrala (+0,12 varmt, gav väggarnas b* som leveransernas), luminans-NR (`CINoiseReduction`) + krominans-NR (oskärpa på Cb/Cr), tonkurva genom bildens luma-percentiler mot målpercentilerna (monoton kubisk, lyft ≤ 0,30, tak 0,97, verkar på luminansen med bevarade färgförhållanden), mättnad per nyans i Lab, allt som 65³-LUT. Clarity 0,10, textur 0,15. Exteriörvikt 0…1 (AI-taggen exteriör, annars andel grönska/himmel 0,08→0,25) blandar mot exteriörreceptet. I fönstermasken: kurva 70 % mot målet och mättnad × 0,8.
- **`VerticalCorrection`** ("Räta lodlinjer", alla profiler, standard på): kantsegment (Sobel, NMS, komponenter, PCA), flyktpunkt (minsta egenvektor, bort med segment > 1,5° fel), virtuell lutning/rotation `K·R·K⁻¹` med brännvidd ur EXIF, högst 8° lutning / 3° rotation, minst 4 segment med sammanlagd längd ≥ 0,6 × höjden, under 0,15° görs inget; beskärning till största 3:2-rektangel utan tomma hörn. Linsdistortion korrigeras redan i `RAWRenderer` (`CIRAWFilter.isLensCorrectionEnabled`).
- `EnhancementEngine.version = 3`, `upright` i fingerprintet, `--enhance-profile`/`--upright` i CLI, inställningar i Förbättra-sektionen.

## Mätning (nuvarande Automatisk v2 → Mäklarstil v3 + lodlinjer)

| Grupp | n | ΔE2000 median | ΔE p90 | Histogramavstånd | Lodlinje (leverans) | Brus L* (leverans) | Väggar L* (leverans) |
|---|---|---|---|---|---|---|---|
| Träning | 36 | 12,1 → 8,7 | 21,9 → 19,3 | 0,102 → 0,047 | 0,67° → 0,29° (0,30°) | 0,46 → 0,15 (0,29) | 72,9 → 83,6 (87,6) |
| **Test, alla** | 15 | **13,8 → 7,1** | 21,1 → 17,3 | 0,134 → 0,049 | 0,65° → 0,20° (0,28°) | 0,56 → 0,21 (0,25) | 69,8 → 84,4 (85,3) |
| Test Pilvingegatan (7) | 7 | 14,0 → 7,1 | 23,0 → 17,3 | 0,145 → 0,049 | 0,87° → 0,21° (0,33°) | 0,52 → 0,15 (0,25) | 69,8 → 84,4 (85,4) |
| Test Varmfrontsgatan 11 (hållen adress) | 8 | 13,7 → 7,1 | 20,6 → 17,2 | 0,123 → 0,048 | 0,61° → 0,19° (0,17°) | 0,65 → 0,45 (0,17) | 68,3 → 86,1 (84,7) |
| Interiörer | 36 | 14,0 → 7,5 | 21,4 → 16,2 | | 0,59° → 0,26° (0,29°) | 0,53 → 0,20 (0,26) | 65,7 → 83,9 (85,4) |
| Exteriörer | 15 | 11,1 → 10,2 | 23,5 → 20,9 | | 0,84° → 0,36° (0,42°) | | |

Bättre ΔE i 44 av 51 bilder. Som jämförelse ligger en neutral rendering av den ljusaste skickade DNG:n på ΔE ≈ 8 — resten är redigerarens lokala arbete. Sämre: Bergstigen 105 (9,5 → 10,1, främst trädgårdsbilder där redigeraren gjort en mycket mättad himmel/grönska).

## Fönstren hos redigeraren

26 bracketgrupper med fönstermask (masken flyttad till leveransen med homografin):

| Mått i fönstret | Leverans | Automatisk v2 | Vår HDR | Mäklarstil |
|---|---|---|---|---|
| Luma median / p99 | 0,86 / 0,99 | 0,71 / 0,90 | 0,74 / 0,96 | 0,84 / 0,96 |
| Relativt väggarna | 1,08 | 1,12 | 1,28 | 1,06 |
| Klippt andel | 5,6 % | 0 % | 0 % | 0,1 % |
| Kontrast (std L*) | 10,3 | 13,0 | 14,5 | 13,7 |
| Krominans | 7,9 | 14,1 | 8,8 | 6,7 |
| Andel blå himmel | 2 % | 22 % | 11 % | 6 % |
| b* (utsikt) | +2,2 | −3,1 | +0,3 | −0,4 |
| Glöd 4–10 px utanför (ΔL*) | 3,0 | 5,9 | 5,7 | 7,0 |

- Utsikten är **ljus**: ungefär som eller lite ljusare än de vita väggarna, med lite klippning tillåten — inte den mörka, dramatiska utsikten.
- **Låg kontrast och dämpad färg**, vitbalans som interiören (ingen blå dagsljuston).
- **Strukturen kommer från mörkaste exponeringen** i 21 av 26 grupper (gradientkorrelation 0,64 mot 0,62 för näst mörkaste) — samma källa som vår window pull.
- Mindre glöd vid karmarna än vår (3 mot 6–7 L* i bandet 4–10 px).
- Vår window pull ger ibland felträffar på ljusa tak nära lampor/fönster (t.ex. Pilvingegatan DSC_9053: en mörkgrå fläck i taket, både i Automatisk och Mäklarstil) — redigeraren har inga sådana.

**Rekommendation: behåll approachen** (fönster från mörkaste exponeringen, maskmedveten Förbättra), men **justera målet**: slutlig utsiktsmedian ≈ 0,85 (≈ 1,05–1,1 × väggarna, inte 0,66–0,72 i HDR-steget), låt p99 nå 0,99 (lite klippning ok), sänk kontrasten i utsikten (~25 %) och mättnaden (~×0,6 mot nu), behåll interiörens vitbalans i utsikten (inte dagsljus) och minska glöden 4–10 px vid karmen. Mäklarstil gör redan ljusheten och färgen i Förbättra-steget; kontrast och glöd återstår (WindowPull, inte ändrat här).

## Går inte att härma automatiskt

- Photoshop-arbetet: manuella fönstermasker/blandning per fönster, retusch (sladdar, fläckar, reflexer), lokala dodge/burn och färgjusteringar per yta (t.ex. starka gardiner i en annars dämpad bild) — det mesta av kvarvarande ΔE (p90 ≈ 17).
- Större lokal tonutjämning (tak och hörn ljusare än en global kurva ger; prövat med negativ storskalig kontrast utan säker vinst).
- Bildval och beskärningskomposition utöver upright-beskärningen.
- Exteriörernas mycket mättade himmel/grönska varierar mellan adresser (Pilottorget/Bergstigen) — ett fast recept träffar inte alla.

## v2 (2026-10-04): standard, basram och hela fönsterrutor

**Mäklarstil är standardprofil** (`EnhancementProfile.defaultID`, app och CLI; okänt profil-id → Mäklarstil). `@AppStorage` sparar bara aktiva val: den som aldrig valt profil får Mäklarstil, ett sparat val (även "auto") behålls — ett aktivt "auto" går inte att skilja från ett gammalt standardvärde och migreras inte.

Mått: `ev.py` (scratch) = `analyze.py` på alla 51 par + fönstermått i en fast mask (out-base-masken via HDR:ens homografi). Brus/skärpa mäts nu efter areanedskalning till leveransens upplösning (förut jämfördes 6000 px mot 2048–5315 px — vårt brus såg för högt ut). Krominansbruset i leveranserna (0,003–0,05) är lägre än i någon 16-bit-version av våra bilder: 8-bit-kvantisering + 4:4:4-JPEG ger ~0,03, så måttet är inte jämförbart rakt av (leveranserna är 4:4:4, ingen subsampling).

| Grupp | n | ΔE median nuv. → v1 → **v2** | ΔE p90 | Hist.avst. | Väggar L* (lev.) | Brus L* (lev.) | Glöd 4–10 px vid fönster (lev.) |
|---|---|---|---|---|---|---|---|
| Träning | 36 | 12,15 → 8,82 → **7,97** | 21,9 → 19,3 → 19,6 | 0,102 → 0,047 → 0,044 | 72,8 → 83,6 → 84,3 (87,6) | 0,30 → 0,11 → 0,07 (0,30) | 6,1 → 8,2 → 0,8 (3,8) |
| **Test, alla** | 15 | 13,93 → 7,05 → **6,54** | 21,1 → 17,2 → **15,3** | 0,134 → 0,049 → 0,052 | 69,8 → 84,4 → 84,8 (85,2) | 0,25 → 0,19 → 0,08 (0,25) | 5,6 → 5,0 → 0,4 (1,6) |
| Test Pilvingegatan | 7 | 13,97 → 7,05 → 6,69 | 23,1 → 17,2 → 17,3 | | 83,3 (85,4) | | |
| Test Varmfrontsgatan (hållen) | 8 | 13,75 → 7,07 → **6,31** | 20,6 → 17,3 → 15,3 | | 85,9 (84,7) | | |
| Interiörer | 36 | 13,96 → 7,54 → **6,22** | 21,4 → 16,3 → 15,1 | | | | |
| Exteriörer | 15 | 11,12 → 10,22 → 10,75 | 23,5 → 20,9 → 21,2 | | | | |

Lodlinjer oförändrade (test 0,22°, leverans 0,28°; Pilottorget fortfarande 0,84°, inte åtgärdat).

### Per förbättring (helkörningar, test / träning ΔE median)

| Steg | Test | Träning | Behållen? |
|---|---|---|---|
| Mäklarstil v1 (utgångsläge) | 7,05 | 8,82 | |
| Window pull: släta ytor/ljusfall bort (HDR v5) — grå fläcken i taket i DSC_9053 borta (fönster-ΔE där 15,5 → 5,3) | 7,07 | 8,82 | ja (visuellt) |
| Fönstervariant: kontrast × 0,8 kring median, +0,02, b* +2, tak 0,99 | 7,06 | 8,81 | kontrasten **nej** (visuellt sämre: utsikten ska vara klar), värme/tak ja |
| Ljusa ytor avmättade × 0,8 (L* ≥ 85, interiörer) | 7,06 (int. 6,86) | 8,67 (int. 7,23) | ja |
| **HDR v6 "basram"** (ljus exponering + pixelvis högdageråtervinning i stället för Mertens) | 6,73 | 7,92 | ja — tak/väggar jämnt ljusa, ingen fusionsskugga |
| Utsikt ur mörka ramen med RAW-kurva, mål 0,62, mättnad × 1,5, rektangulära rutor (v2f) | **6,54** | **7,97** | ja |

### Prövat och förkastat

- Lokal tonutjämning (guided-filter-bas, kompression 0,5–0,7, radie 20–80 px, med histogramåtermatchning) i prototyp på v1: ±0,0–0,3 ΔE, oftast sämre på test → inte infört. Basramen gav i stället jämnt ljusa tak.
- Ljusberoende mättnad (mellantoner × 1,15) och "dra varmt stick i ljusa ytor mot neutralt": sämre eller lika på test.
- Global mättnad × 1,1–1,4 på v2 (exteriörerna har klart mer krominans i leveranserna): ± 0,05 test, sämre träning.
- EV-baserad exteriörvikt (scenljus ur EXIF): hjälper exteriör-träningen, men DSC_9160 (test) blir sämre → inte infört.
- Fönster: slöjborttagning (mörka kanalen) i hela rutor, mask från slöjvikten in i Förbättra (karmarna mörknade), fyllning utanför rutans rektangel (läckte ut på karmar/pampas), krav på färg i mörka ramen (fläckig ruta).
- "Blå himmel" (`SkyReplacement`): redigeraren har blå himmel i alla 15 exteriörer, vi vit. Implementerat men **av som standard** — syntetisk himmel, inte ur fotografens exponeringar; ljusa tak i interiörer kan likna himmel.

### Kvar / kända brister

- Fönster där utsikten inte är klippt i mellanexponeringen (mörka träd lika ljusa som väggen) dras bara delvis in: ljusa remsor och en rand i DSC_6385. Lightrooms HDR-sammanslagning ger här klart renare rutor (`results/pilvinge-mellan/11-lr-hdr-DSC_6385.jpg`); `photoflow-cli enhance` + `scripts/maklarstil/lr_run.sh` jämför LR-HDR + vår Mäklarstil. LR-DNG:n saknar tonkurva och behöver en exponeringshöjning före Mäklarstilens kurva (annars orange stick/brus i mörka hörn).
- Exteriörer blev något sämre med basram (10,22 → 10,75): himlen och himmelsbytet (se ovan) dominerar.
- Krominansbrus/skärpa: inte justerat (måttet se ovan); lodlinjer i Pilottorget inte åtgärdade.
- Jämförelsebilder: `~/PhotoFlowBenchmark/results/pilvinge-mellan/` (löpande, `status.md`) och `~/PhotoFlowBenchmark/results/pilvinge-2026-10-04-v2/mobil/`.
