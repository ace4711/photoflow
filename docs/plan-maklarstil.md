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
