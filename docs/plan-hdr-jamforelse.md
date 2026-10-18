# Plan: jämför PhotoFlows HDR med Lightrooms (≈ 20 bracket-grupper)

Status: beslut tagna 2026-10-18 (avsnitt 8), fas 1–4 påbörjas. Syftet är att mäta och visuellt bedöma hur vår inbyggda HDR (`Services/HDR/`) står sig mot Lightroom Classics Photo Merge > HDR på samma ramar, och att kunna göra jämförelsen i appen.

## 1. Utgångsläge (vad som finns i dag)

**Vår motor** (`HDREngine.merge`, version 7, `nonisolated`, `@concurrent`):
- Metoder (`HDREngine.Method`): `radiance` (standard sedan v7: `RadianceMerge` → scenlinjär radiansbild med spökskydd, tonsatt med `SceneLinearTone`, inga fönstermasker), `base` (`BaseFrameMerge`: ljus basram + pixelvis högdageråtervinning + `WindowPull`), `fusion` (Mertens, `ExposureFusion` + `WindowPull`). Den äldre OpenCV/Python-vägen (`hdrEngine = "opencv"`) finns kvar som reserv men tas inte med.
- Indata: `[Frame(url, exposureSeconds)]` + valfri `windowSource` (mörkaste ramen). `runHDRMerge` läser `bracket_groups.json`, använder `suggested_hdr_indices` (alla ramar om fältet saknas, som i Chronas väg 7) och skickar alltid mörkaste ramen som fönsterkälla.
- Utdata: `hdr/hdr_group_<id>.tiff` + `.jpg` (JPEG ≤ 4000 px, kvalitet 0,92), `hdr.json` (motorversion, fingerprint, radiansstatistik inkl. `ghostFraction`), med `--hdr-debug` även `hdr_debug/` och `hdr_metrics.json` (`WindowPullMetrics`).
- Inställningar (`AppSettings`): `hdrEngine`, `hdrMaxDimension` (6000), `hdrAlignEnabled`, `hdrSharpenEnabled`, `hdrMethod`, window pull (på/styrka 85/ljushet/lampor+himmel).
- **CLI:** `photoflow-cli` (`PhotoFlow/SourcesCLI/PhotoFlowCLI.swift`, target i `project.yml`) har `run`, `verify`, `reel`, `reel-panels`, `enhance`. `run --input <mapp> --output <mapp> --no-calendar --no-ai --no-enhance --no-reel --hdr-method radiance|base|fusion [--window-pull on|off] [--hdr-debug]` kör HDR headless, men för en hel mapp med ny bracket-detektering. **Det finns inget kommando som slår ihop en enskild given grupp/ramlista** — det läggs till (fas 1).

**Lightroom-bryggan** (`PipelineRunner+Lightroom.swift` + `PhotoFlowLR.lrplugin`):
- Appen skriver `~/Library/Application Support/PhotoFlow/lr_trigger.json` (`{groups:[{group_id, files, output_dir}]}`, `files` = alla *accepterade* ramar i gruppen, inte `suggested_hdr_indices`), pluginet pollar var 5:e s (`InitPlugin.lua` → `HDRMergeCore.runOnce`), skriver `lr_status.json` och `lr_done.json`.
- Per grupp: `catalog:addPhoto` (importerar NEF:erna till den **aktiva katalogen**), `setSelectedPhotos`, `osascript` Ctrl+H (öppnar HDR-dialogen), väntar 5 s, Return, väntar 8 s. Fasta väntetider, ingen kontroll av att sammanslagningen faktiskt blev klar.
- Utfall: Lightroom skriver `<första ramen>-HDR.dng` (scenlinjär float-DNG) **i källmappen** och lägger den i katalogen. `output_dir` skickas men används inte av pluginet. Resultatets sökväg rapporteras inte tillbaka.
- Sammanslagningsalternativen (Auto Align, Auto Settings/Auto Tone, Deghost Amount, Create Stack) går inte att sätta via SDK:t — dialogen minns senast använda val. SDK:t saknar Photo Merge-API helt.
- Kräver Accessibility-behörighet för Lightroom/osascript och att Lightroom ligger i förgrunden. Styr användarens skärm.

**Befintligt UI:** `BracketReviewView` har jämförelse sida vid sida (`ReviewCompareMode`: källexponering/HDR före förbättring ↔ slutbild, tangent X), `ReviewImageOverlays` med 100 %-zoom (`ReviewZoomView`), lupp, histogram och klippningsoverlay. Ingen synkad zoom/panorering, inget svepreglage, ingen blindtest. `scripts/window-testset.py` (urvalsheuristik, skrivskydd mot volymen) och `scripts/window-compare.py` (statisk jämförelsesida) kan återanvändas.

## 2. Testdata och urval

Tillgängliga bracket-grupper: **115**.
- `/Users/fredrik/Desktop/ptohotagraphy-test/Chronas väg 7`: 18 bracketgrupper (4–11 ramar, upp till 12 EV), 7 singlar. `Chronas väg 7 red` har fotografens färdiga Lightroom-JPEG:ar för **16 av 18** grupper (namngivna efter en ram, t.ex. `DSC_9398.jpg` ↔ grupp 1; grupp 8, 11 och 15 saknar).
- `/Volumes/photo-ingestion/PhotoFlow/output`: 97 bracketgrupper (223 grupper totalt; 912 NEF i `input/114NCZ_8`) från Svartskogsvägen 15 (≈ 63), Kyndelgränd 19 (≈ 20) och Lillvägen 24 (≈ 14). `ai_tags.json` ger kategori: ungefär 31 interiör med fönster, 23 interiör utan, 29 exteriör med fönster, 14 exteriör utan. Inga fotografreferenser här.

Båda platserna är **skrivskyddade**. Allt kopieras till `~/PhotoFlowBenchmark/hdr-lr/` (NEF-kopior, våra resultat, Lightrooms DNG/exporter, mått, betyg).

Urval (20 grupper, deterministiskt, `scripts/hdr-lr-testset.py` byggt på `window-testset.py`):
- 8 från Chronas väg 7 (alla med fotografreferens): 4 interiör med fönster, 2 mörka rum, 2 exteriör.
- 12 från volymen, spridda över de tre adresserna: 5 interiör med fönster (störst klippt fönsteryta), 2 mörka rum/lampor, 3 exteriör (himmel, motljus), 2 med rörelse (träd/moln, ghosting).

Manifest `~/PhotoFlowBenchmark/hdr-lr/manifest.json`:
```json
{ "version": 1, "created": "…", "groups": [ {
  "id": "chronas-01", "source": "Chronas väg 7", "groupId": 1, "category": "interior-window",
  "frames": [{"file": "nef/chronas-01/DSC_9396.NEF", "exposureSeconds": 0.1667}, …],
  "photographerReference": "ref/chronas-01/DSC_9398.jpg",
  "variants": { "pf-radiance": "out/chronas-01/pf-radiance.tiff", "pf-fusion": "…",
                "lr-auto": "out/chronas-01/lr-auto.tiff", "lr-dng": "out/chronas-01/lr.dng" } } ] }
```
Samma ramlista (alla ramar i gruppen) går till båda motorerna, så att jämförelsen är rättvis. En andra körning med `suggested_hdr_indices` kan läggas till som variant.

## 3. Varianter

| Id | Vad | Hur |
|---|---|---|
| `pf-radiance` | Vår standard (v7) | `photoflow-cli hdr` (fas 1) |
| `pf-base` | Basram + window pull | dito, `--method base` |
| `pf-fusion` | Mertens + window pull | dito, `--method fusion` |
| `pf-radiance-enh` (valfri) | Vår + Förbättra | `photoflow-cli enhance --input pf-radiance.tiff` |
| `lr-auto` | LR HDR, Auto Align + Auto Settings, exporterad av LR | plugin (fas 2) |
| `lr-plain` (valfri) | LR HDR utan Auto Settings | plugin, andra körning |
| `ref` | Fotografens färdiga bild (bara Chronas) | kopia ur `red` |

**Äpplen mot äpplen:** Lightrooms `-HDR.dng` får inte renderas med Core Image (`RAWRenderer` klarar scenlinjär DNG, men ignorerar LR:s framkallningsinställningar/Auto Tone i katalogen och använder en annan tonkurva och färgprofil). Lightrooms resultat exporteras därför av Lightroom själv via `LrExportSession` (TIFF 16 bit, sRGB, ingen storleksbegränsning, ingen utskärpning, filnamn `lr-auto`). DNG:n sparas också för senare analys.

`pf-radiance-enh` jämförs rättvisast mot `lr-auto` (båda med automatisk ton), rå HDR mot `lr-plain`.

## 4. Lightroom-delen (pluginet)

Ändringar i `HDRMergeCore.lua` (bakåtkompatibelt, nya fält i triggern):
1. Trigger får `mode: "experiment"`, per grupp `id`, `export_dir`, `export_format` (`TIFF`/`JPEG`).
2. Före sammanslagning: lista `*-HDR*.dng` i källmappen; efter Ctrl+H/Return: polla (max 120 s) tills en ny DNG finns och `catalog:findPhotoByPath` hittar den — ersätter fast 8 s-väntan.
3. Pröva Ctrl+Shift+H (huvudlös sammanslagning med senaste inställningar, ingen dialog) som robustare alternativ; behåll Ctrl+H + Return som reserv.
4. Exportera fotot med `LrExportSession({photosToExport={photo}, exportSettings={LR_export_destinationType="specificFolder", LR_export_destinationPathPrefix=export_dir, LR_export_useSubfolder=false, LR_format="TIFF", LR_export_bitDepth=16, LR_export_colorSpace="sRGB", LR_size_doConstrain=false, LR_outputSharpeningOn=false, LR_renamingTokensOn=true, LR_tokens="lr-auto", LR_collisionHandling="overwrite"}})` + `doExportOnCurrentTask()`.
5. Läs `photo:getDevelopSettings()` och skriv de viktigaste (Exposure2012, Highlights2012, Shadows2012, Whites/Blacks, Temperature/Tint, profil) och DNG-sökvägen till `lr_status.json` per grupp → manifestet. Då syns om Auto Settings verkligen användes.
6. Status skrivs med en riktig JSON-kodare (dagens `writeStatus` escapar bara `"` och `\n`).

Förberedelser och begränsningar:
- **NEF:erna kopieras först** till `~/PhotoFlowBenchmark/hdr-lr/nef/<id>/`, annars skriver Lightroom `-HDR.dng` i testdatamapparna (förbjudet).
- Använd en **separat Lightroom-katalog** (`PhotoFlow-HDR-test.lrcat`) så att fotografens katalog inte fylls med testbilder.
- Alternativen i HDR-dialogen ställs in en gång för hand och noteras i manifestet (förslag: Auto Align på, Auto Settings på, Deghost Av eller Låg, Create Stack av).
- GUI-styrningen tar över skärm och tangentbord ≈ 30–60 s per grupp (≈ 15–20 min för 20 grupper). **Körs bara när Fredrik startar den själv eller är borta.** Får inte köras av agenter under ett autonomt pass utan uttryckligt klartecken.
- Lightrooms resultat kan vara beskuret av Auto Align och ha annan pixelstorlek; registreras före pixelmått (avsnitt 6).

## 5. Jämförelsefönstret i appen

Nytt fönster `HDRCompareWindow` (`WindowGroup("HDR-jämförelse", id: "hdr-compare")` i `PhotoFlowApp`), öppnas från menyn Fönster och från `BracketReviewView` (knapp bredvid "Lightroom HDR"). Läser `manifest.json`, eller en vanlig session (då `hdr_group_<id>` mot Lightroom-export om sådan finns).

- **Vänsterlista:** grupper med miniatyr, kategori, status (saknas variant/bedömd).
- **Varianter:** välj A och B ur varianterna (standard `pf-radiance` ↔ `lr-auto`), `ref` som valfri tredje.
- **Lägen:** sida vid sida med **synkad zoom/panorering** (gemensam `CompareViewport`-modell: skala + offset i normaliserade koordinater, MagnifyGesture/scroll/dra), **svepreglage** (en bild, delningslinje som dras, tangent S), **A/B-växling** (blinkning, mellanslag), 100 % (Z). Klippningsoverlay och histogram återanvänds från `ReviewImageOverlays`.
- **Blindläge** (B): etiketter döljs, ordningen A/B slumpas per grupp (seed sparas), bedömning före avslöjande.
- **Bedömning per grupp:** A bättre / lika / B bättre, plus kryssrutor för fönster, färg/vitbalans, skuggor, spöken, brus, naturlighet och en fritextkommentar. Sparas som `verdicts.json` bredvid manifestet (`{groupId, left, right, blind, seed, verdict, aspects, note, ratedAt}`), skrivs atomiskt efter varje betyg.
- **Sammanfattning:** vinst/oavgjort/förlust totalt och per kategori, aspekter som oftast fäller vår HDR, och tabell över mått (avsnitt 6) med medel/median. Exporteras som `summary.json` och en kort Markdown-rapport.

Bilder laddas nedskalade (≤ 3000 px) för visning och i full upplösning för 100 %-läget, via `ImageCache`.

## 6. Objektiva mått

Ny `Services/HDR/HDRCompareMetrics.swift` (ren `nonisolated enum`, testbar), körs av både fönstret och `photoflow-cli hdr-compare`; skriver `metrics.json` per grupp och variant.

- **Registrering:** varje variant mot referensramen (medianexponering, renderad av oss) med `VNHomographicImageRegistrationRequest` (klarar Lightrooms beskärning och fotografens beskärning/lodlinjer); transformen sparas och används för alla parvisa mått. Grupper med dålig registrering (residual > 2 px) flaggas och utesluts från ΔE.
- **Klippning:** andel pixlar med någon kanal ≥ 0,98 (högdagrar) resp. luma ≤ 0,02 (skuggor).
- **Fönsterdetalj:** mask = klippt i referensramen men informativ i mörkaste ramen (samma regler som `WindowPull`-detekteringen); i masken: klippt andel, lumaspridning p5–p95 och gradientkorrelation mot mörkaste ramen (som `WindowPullMetrics.structureVsDark`).
- **Spöken:** luma-matchad absolut skillnad mot referensramen i 32 px-rutor, andel rutor över tröskel; för oss även `ghostFraction` ur `hdr.json`.
- **Brus:** robust σ (MAD av Laplace) i släta, mörka rutor (luma 0,05–0,25).
- **Färg:** medel a*/b* i nära neutrala pixlar (färgstick), skattad vitbalansskillnad mot `lr-auto` och `ref` (K och tint).
- **Ton:** medianluma, p5/p95, lokal kontrast (σ av högpassfiltrerad luma).
- **ΔE2000** mot `lr-auto` och mot `ref`: medel och p95 efter registrering, även separat i och utanför fönstermasken.
- Tid per grupp för båda motorerna.

Mot `ref` är ΔE bara vägledande: fotografens bild har manuell framkallning, beskärning, lodlinjekorrigering och ibland retusch.

## 7. Faser (commit-stora steg)

**Fas 1 – underlag (headless, inget GUI)**
1. `photoflow-cli hdr --frames <nef…> --method radiance|base|fusion --out <tiff> [--jpeg <jpg>] [--window-source <nef>] [--hdr-debug <mapp>]` som anropar `HDREngine.merge` direkt (exponeringstid via `ExifReader`). Enhetstest av argumenttolkningen.
2. `scripts/hdr-lr-testset.py`: väljer 20 grupper enligt avsnitt 2, kopierar NEF:er och fotografreferenser, skriver `manifest.json` (assert att inget skrivs under testdatamapparna).
3. `scripts/hdr-lr-run-ours.sh`: kör `pf-*`-varianterna för alla grupper i manifestet och uppdaterar manifestet.

**Fas 2 – Lightroom-resultat (kräver Fredrik)**
4. Plugin: experimentläge, väntan på ny DNG, export via `LrExportSession`, framkallningsinställningar i status (avsnitt 4). Versionen höjs till 1.4.
5. Appen/CLI: `photoflow-cli lr-trigger --manifest <fil>` skriver triggern och väntar på `lr_done.json`, för in sökvägar och inställningar i manifestet.
6. **Fredrik:** skapar testkatalogen, ställer in HDR-dialogen, startar körningen (eller lämnar datorn). Kontrollerar 2–3 grupper manuellt i Lightroom.

**Fas 3 – mått**
7. `HDRCompareMetrics` (registrering, klippning, brus, färg, ΔE) med tester på syntetiska bilder. **Klar** (`HDRCompareMetrics.swift`; inläsning och `metrics.json` i `HDRCompareRunner.swift`). Kvar: vitbalans i K/tint (bara a*/b* för nu), och Visions homografi kräver lika stora bilder så en beskuren Lightroom-bild sträcks först.
8. `photoflow-cli hdr-compare --manifest <fil>` → `metrics.json` + `summary.json`.

**Fas 4 – jämförelsefönstret**
9. `CompareViewport` + sida vid sida med synkad zoom/panorering. **Klar** (`Views/HDRCompare/`).
10. Svepreglage och A/B-växling, tangentbordsgenvägar. **Klar** (S, mellanslag, Z, B).
11. Blindläge, bedömningspanel, `verdicts.json`. **Klar.**
12. Sammanfattningsvy med mått och betyg, Markdown-export. **Klar** (`summary.md` + `summary.json`). Knappen "Starta Lightroom-körning…" visar bara instruktioner och kommandot `photoflow-cli lr-trigger`; den startar inget.
13. Ingång från `BracketReviewView` för vanliga sessioner (vår HDR ↔ Lightroom-export för samma grupp).

**Fas 5 – utvärdering**
14. **Fredrik** bedömer alla 20 grupper i blindläge (≈ 30–45 min). Resultat och slutsatser förs in i den här planen; konkreta förbättringar av motorn blir egna planer.

## 8. Beslut (Fredrik, 2026-10-18)

1. Lightroom körs **som fotografen kör**: Auto Align på, Auto Settings på, Deghost Låg, Create Stack av. Bara varianten `lr-auto` (ingen `lr-plain`).
2. **Separat testkatalog** `PhotoFlow-HDR-test.lrcat`.
3. **Fredrik startar Lightroom-körningen själv** (knapp i jämförelsefönstret / `photoflow-cli lr-trigger`), aldrig agenter.
4. Vår HDR jämförs **både före och efter Förbättra** (`pf-radiance` och `pf-radiance-enh`).
5. (Standard) Alla ramar till båda motorerna.
6. (Standard) Fotografreferens bara för Chronas väg 7 tills vidare.

### Ursprungliga öppna frågor

1. Vilka Lightroom-inställningar gäller som "Lightrooms HDR": Auto Settings på eller av (eller båda varianterna), och Deghost Av/Låg/Medel?
2. Separat Lightroom-katalog för testet (rekommenderas) eller den vanliga?
3. När får Lightroom-körningen ske — startar du den själv, eller får den köras automatiskt när du är borta?
4. Ska vår HDR jämföras rå (före Förbättra), efter Förbättra, eller båda?
5. Samma ramar till båda motorerna (alla ramar, föreslaget) eller vårt urval `suggested_hdr_indices`?
6. Räcker 8 grupper med fotografreferens (Chronas väg 7), eller finns färdiga bilder även för volymens adresser?
