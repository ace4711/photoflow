# Plan: HDR v8 – Lightroom-lik framkallning (alternativ A)

Status: implementerad 2026-10-18 som valbar metod `radiance-v8` (standard fortfarande `radiance` v7) — väntar på Fredriks bedömning i jämförelsefönstret. Bygger på jämförelsen i `docs/plan-hdr-jamforelse.md` (20 grupper,
`~/PhotoFlowBenchmark/hdr-lr/`), där Lightroom Classic (HDR + Auto Settings, `lr-auto`) bedömdes
klart bättre på alla bilder.

## 1. Diagnos

| Problem | Vår radians (v7) | + Förbättra | Lightroom |
|---|---|---|---|
| Fönster/himmel | utblåsta (median 93 % av fönstermasken klippt), frostat glas platt vitt | räddade men mjölkiga, cyan himmel, stor gul solhalo | utsikt kvar, glasets struktur, djupblå himmel, liten skarp sol |
| Svärta/kontrast | – | lyfta svarta (p5 0,20), platt | riktiga svarta (p5 0,09), mellantonskontrast |
| Färg | orange stick under varma lampor | grönaktig/cyan | neutral men lampornas värme kvar |
| Textur | – | – | mer mikrokontrast (glas, handdukar, sten) |

Lightrooms egen `-HDR.dng` renderad med vår Core Image-väg (`lr-dng`) ser lika dålig ut (50 %
fönster klippta, 16 % skuggor krossade): skillnaden sitter i **tonsättningen/framkallningen**, inte
i sammanslagningen. Därför behålls `RadianceMerge` och tonsättningen byts.

## 2. Lösning

Ny tonsättning `SceneLinearLocalTone` (HDR v8) för radiansbilden, vald med metoden
`radiance-v8` (`HDREngine.Method.radianceV8`). Standardmetoden `radiance` (v7, `SceneLinearTone`)
är oförändrad tills Fredrik godkänt v8.

1. **Lokal tonkompression** i log-luminans: bas = kantbevarande guided filter (räknat på ~1000 px,
   koefficienterna interpoleras till full upplösning — "fast guided filter"), detalj = resten.
   Basen trycks ihop (högdagrar över ≈ +0,7 EV närmar sig ett tak, skuggor lyfts mot ett golv),
   detaljen läggs tillbaka förstärkt (Texture/Clarity). Fönstren får utsikt utan masker och utan
   att hela bilden plattas till.
2. **Auto-exponering** mot Lightrooms medianluma (≈ 0,47), kalibrerad med bisektion genom samma kurvor.
3. **Svart- och vitpunkt** med liten klippning (LR: Blacks −22, Whites +15): mjuk tå, Reinhard-skuldra.
4. **Mild S-kurva**, **vibrance/mättnad** (LR: Vibrance +15, Saturation +3).
5. **Färg**: RGB skalas med samma faktor som luminansen (kulör och mättnad bevaras — himlen förblir
   blå), det som hamnar över 1 avmättas mot luminansen.
6. Förbättra (Enhancement) utvärderas både på och av för v8 (`pf-v8`, `pf-v8-enh`).

## 3. Utvärderingsslinga (headless)

- `photoflow-cli hdr --method radiance-v8 [--max-dimension px] [--radiance-cache fil] [--tone nyckel=värde,…]`:
  radianscachen (`RadianceCache`) sparar den scenlinjära sammanslagningen så att bara tonsättningen
  körs om; `--tone` överstyr parametrarna utan ombygge.
- `photoflow-cli hdr-compare --manifest <fil> [--variants a,b] [--against lr-auto] [--per-group]`:
  måtten ur `HDRCompareMetrics` (samma `metrics.json` som jämförelsefönstret, bara ändrade
  varianter räknas om) och en poängtabell (medianer) till terminalen och `score.txt`.
- `scripts/hdr-lr-contact.py`: kontaktark (varianterna sida vid sida, valfritt utsnitt) att titta på.

## 4. Resultat

Mätt med `photoflow-cli hdr-compare` på alla 20 grupper (full upplösning, 6000 px), medianer över
grupperna. ΔE2000 mot `lr-auto` efter registrering; fönstermåtten i masken "klippt i medianramen men
informativ i mörkaste ramen".

| Variant | ΔE | ΔE p95 | Fönster klippt | Fönster struktur | Klippta högdagrar | Klippta skuggor | Medianluma | p5 | p95 | Lokal kontrast | a* | b* |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pf-radiance (v7) | 10,47 | 16,5 | 92,6 % | 0,69 | 5,7 % | 0,0 % | 0,509 | 0,167 | 0,931 | 0,047 | 0,47 | 1,60 |
| pf-radiance-enh | 12,59 | 20,7 | 1,2 % | 0,41 | 0,1 % | 0,1 % | 0,686 | 0,204 | 0,909 | 0,063 | 0,46 | 2,62 |
| **pf-v8** | **9,49** | 18,3 | 15,4 % | 0,63 | 1,5 % | 0,2 % | **0,470** | **0,101** | 0,833 | 0,053 | 0,73 | 2,01 |
| pf-v8-enh | 12,63 | 19,9 | 6,1 % | 0,39 | 0,5 % | 0,1 % | 0,686 | 0,205 | 0,907 | 0,066 | 0,49 | 3,00 |
| lr-auto (mål) | – | – | 4,8 % | 0,74 | 1,1 % | 0,8 % | 0,473 | 0,088 | 0,866 | 0,051 | 0,86 | 1,94 |

Tid: pf-v8 3,4 s/grupp (Release, 6000 px; radians v7 3,3 s) — tonsättningen själv < 0,5 s.

**Visuellt** (kontaktark pf-v8 | lr-auto för alla 20): v8 ligger nära Lightroom i ton och karaktär —
fönster med utsikt (träd, hus, solpaneler, blå himmel i bastun), riktiga svärtor, ingen slöja, ingen
stor solhalo, textur i handdukar/sten. De tydligaste kvarvarande skillnaderna:
- **Värme/färg**: Lightroom (Adobe Standard) är varmare och mättnare i trägolv och under varma lampor
  (g035, g126, g132); v8 är neutralare/kallare. En global värme (+0,01) och högre mättnad tar en del;
  mer gav fel stick i dagsljusrum. Riktig lösning: en kameraprofil närmare Adobe Standard (hue/sat-
  tabell per nyans) i stället för globala reglage.
- **Fönsterkanter**: en smal ljus kant innanför fönsterkarmen (guided filter-halo; fina basen gjorde den
  smal men inte borta).
- **Frostat glas/fönster nära vitt**: Lightroom visar mer glasstruktur; v8 något slätare.
- **Färgkanter**: svaga lila/röda kanter kvar runt trädtoppar mot utblåst himmel (objektivets CA; LR
  korrigerar CA i linsprofilen).
- Fönstermåttet (15 % klippt mot 5 %) domineras av grupper med mycket små masker (solen) och av
  himmel som är klippt i *alla* ramar — den görs avsiktligt vit (som i LR) i stället för grå.
- ΔE p95 är högre än v7 (18,3 mot 16,5): v8 har mer kontrast och mättnad, så felen i de mest avvikande
  pixlarna blir större när färgen skiljer sig.

**Förbättra efter v8 (pf-v8-enh)** gör om det v8 löste: medianluma 0,69, p5 0,21 (lyfta svärtor,
mjölkigt), fönsterstruktur 0,39. Rekommendation: hoppa över Förbättra för v8-HDR (eller en lätt profil
utan exponering/skugglyft — bara lodlinjer och ev. himmel).

**Vad som fungerade**: lokal kompression i log-luminans med stort eps (1 EV²) så att utsikten som
helhet hamnar i basen; asymmetrisk detalj i högdagrar (ljus detalj ×0,6, mörk detalj full — annars
gråa solpaneler/vit snö); mättnadsexponent 0,6 i sammanpressade högdagrar (annars neonfärgade grenar);
pixlar klippta i alla ramar → vitt; kantdämpning av magenta; kalibrering av medianen genom hela kedjan.

**Vad som inte fungerade**: dehaze ur v7 (mättade orange grenar); vitpunkt låst till kompressionstaket
(hårda vita fläckar i snö/fasader); för låg `highlightStart` (gråa väggar); avmättning mot max-kanalen
vid taket (vita fläckar) — ersatt med avmättning mot luminansen; global värme > 0,015 (fel stick).

**Bedömning**: välj A = `pf-v8`, B = `lr-auto` i Fönster > HDR-jämförelse (gärna blindläge).
Om v8 godkänns: gör `radiance-v8` till standard (höj `HDREngine.version` till 8) och stäng av eller
mildra Förbättra för radians-v8-HDR.

## 5. Nästa steg (om v8 godkänns)

1. Kameraprofil: hue/sat-justering per nyans (trä/hud varmare, grönt) mätt mot `lr-auto`.
2. Halo vid fönsterkarmar: rullande guided filter eller lokal Laplace-pyramid för basen.
3. CA-korrigering (lateral) före sammanslagningen, så att färgkantsdämpningen kan bli svagare.
4. Förbättra: profil "efter v8" utan ton/exponering.
