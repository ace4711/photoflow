# Plan: HDR v8 – Lightroom-lik framkallning (alternativ A)

Status: påbörjad 2026-10-18. Bygger på jämförelsen i `docs/plan-hdr-jamforelse.md` (20 grupper,
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

(fylls i under arbetet)
