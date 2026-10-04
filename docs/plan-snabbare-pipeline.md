# Plan: snabbare PhotoFlow genom att låta stegen överlappa, styrt av resurserna

Detta är bara en plan. Jag har inte ändrat några filer och inte kört något som skriver i sessionen.

Märkning i texten:
- **[V]** = verifierat i koden.
- **[R]** = räknat fram ur dina mätningar.
- **[A]** = antagande som behöver mätas.

---

## 0. Sammanfattning

1. **Den största vinsten är att sluta skriva samma stora fil flera gånger, inte parallellism.** Varje HDR-TIFF och varje förbättrad TIFF skrivs i dag **tre gånger**:
   - först av `HDRWriter.write`,
   - sedan helt om av `HDRWriter.copyEXIF` (exiftool),
   - och en gång till av `writeIPTCMetadata` (`-overwrite_original_in_place`) [V].
   
   Metadatasteget går med ungefär **270 MB/s** sammanlagd läsning och skrivning på T5:an. Det betyder att steget är **diskbundet**, inte bundet av processor eller exiftool [R, se 1.3].
2. **HDR och Förbättra binds av processorn och använder i dag bara en del av M3 Max** (12 P-kärnor + 4 E-kärnor, 128 GB, kontrollerat med `sysctl`). HDR körs en grupp i taget [V]. Exposure fusion är till stor del enkeltrådade skalära loopar [V, `ExposureFusion.computeWeight/extractChannel`, `HDRWriter.makeRGB16CGImage`]. Förbättra har `maxConcurrent = min(3, cores/3)` = 3 [V].
3. **Flera beroenden som stegordningen antyder finns inte i koden:**
   - Bracket-analysen läser EXIF ur **NEF-filerna** (`ExifReader.readAll(nefFiles:)`) och behöver alltså inte DNG [V].
   - HDR använder varken AI-taggar eller kalendern [V].
   - Förbättring av **enskilda bilder** (515 av 612) behöver bara DNG + AI-taggar, inte HDR [V, `enhanceJobs`].
4. **När fas 1 är klar blir T5:an golvet.** Det skrivs och läses runt 340 GB, vilket vid cirka 270 MB/s blir ungefär 20 minuter [R]. Den viktigaste öppna frågan är därför om arbetsmappen ska ligga på den interna disken.
5. **Grov prognos, 912 NEF på T5 med 5 Gb/s:**

   | Läge | Tid |
   |---|---|
   | I dag, steg för steg | ~84 min (uppskattning) |
   | Efter fas 1 | ~35–45 min |
   | Efter fas 2 | ~25–32 min |
   | Teoretiskt golv på T5 | ~20 min |
   | Arbetsmapp på intern disk | ~15–20 min |

---

## 1. Flaskhalsanalys per steg

### 1.1 Stegordning i dag (`PipelineRunner.startPipeline`) [V]

Kopiering (görs innan, i `ContentView.copyFromSDCardAndStart`) → DNG → bracket-analys → förhandsbilder → kalender → AI (Vision-taggning → Foundation Models-texter → kvalitetsanalys, i följd) → HDR → `loadBracketGroups` → Förbättra → Sortera → Metadata.

Det går att pausa och avbryta mellan stegen (`checkCancellationAndWaitIfPaused`) och inne i loopar. Kortkopieringen och pipelinen har varsitt `beginActivity`-skydd mot App Nap.

### 1.2 Resurser och verkliga beroenden

| Steg (fil/funktion) | Binds av | Verkligt beroende | Granularitet | Status |
|---|---|---|---|---|
| Kortkopiering (`ContentView.copyFromSDCardAndStart`, `/usr/bin/rsync` = **openrsync**) | Kortläsare och skrivning till målvolymen | Ingen | Per fil | [V] openrsync; 15 min på USB 2.0 ≈ 29 GB / 33 MB/s [R] |
| DNG (`runDNGConversion`, partier om 50, `Adobe DNG Converter -c -d`) | På USB 2.0: **skrivningen** (50 GB DNG / 1642 s ≈ 30 MB/s, NEF-läsningen kom ur sidcachen efter kopieringen) [R]. På intern disk: processorn, 0,13 s/bild. På T5 med 5 Gb/s: ungefär lika mycket av båda (50 GB / ~400 MB/s ≈ 125 s ≈ 0,14 s/bild) [R/A] | En NEF, helt kopierad | Per fil | [V]. Konverteraren skriver direkt i `dng/`, och hoppa-över-logiken räknar varje befintlig `.dng` som klar, så **en halvskriven DNG efter avbrott räknas som klar** [V] |
| Bracket-analys (`runBracketAnalysis` → `ExifReader.readAll`, 8 samtidiga, + `BracketAnalyzer.analyze`) | Lite läsning av NEF-huvuden | EXIF från alla NEF i filnamnsordning. En grupp är slutgiltig när tidsluckan till nästa bild är större än `maxTimeGap` eller bländare/ISO byts (`phase1GroupByTimeAndSettings`). Fas 2 delar bara inom en råa grupp [V]. Grupp-id är löpnummer i filnamnsordning [V] | Inkrementell per tidsserie | [V] |
| Förhandsbilder (`runPreviewGeneration`, ett exiftool-anrop `-JpgFromRaw` + rotation) | En exiftool-process, lite I/O | En NEF | Per fil | [V] |
| Kalender (`matchCalendarBookings`) | EventKit, försumbart | Alla fotodatum ur `bracket_groups.json` (fingerprint på filen) | Global (billig) | [V]. **Geokodningen sker först i Sortera** (`exportToAddressFolders`) och ännu en gång i `writeIPTCMetadata` [V] |
| AI: Vision-taggning (`VisionTaggingService.tagPhotos`, upp till 8 samtidiga) | Neural Engine / GPU | En förhandsbild | Per fil | [V] |
| AI: bildtexter (`runPhotoDescriptions`, `PhotoDescriptionService` actor) | Foundation Models, **i följd** | Förhandsbilder + grupp-id (en bild per grupp) | Per grupp | [V]. Troligen huvuddelen av de 8 minuterna [A] |
| AI: kvalitet (`PhotoQualityService.analyzeSession`, 6 samtidiga) | Neural Engine / GPU + processor | Mätning per fil; **dubblettklustringen är global** och körs efter alla mätningar [V] | Per fil + globalt slutsteg | [V] |
| HDR (`runHDRMerge` → `HDREngine.merge`, `@concurrent`) | Processor (fusion och 16-bitarspackning enkeltrådade; vImage delvis flertrådad), GPU (`CIRAWFilter`, `CIUnsharpMask`), minne 4,4 GB toppfotavtryck per grupp vid 6000 px (FORBATTRINGAR). Disk: TIFF + copyEXIF-omskrivning | Gruppens valda DNG:er (`suggested_hdr_indices`). **Faller tillbaka på NEF om DNG saknas** [V], så strömning måste vänta på DNG annars blir utdata annorlunda | Per grupp, en i taget [V] | Kärnor per grupp okänt, troligen 1,5–3 [A] |
| Förbättra (`runEnhancePhotos` → `EnhancementEngine.enhance`, 3 samtidiga) | HDR-jobb: avkodning av LZW-TIFF (enkeltrådad, kodkommentaren säger "~6 s"). Enskilda bilder: `RAWRenderer.render` av DNG. Alla: LZW-TIFF-kodning + `copyEXIF`-omskrivning | Källa (HDR-TIFF eller DNG) + **AI-taggar** (`isExterior` styr horisonträtning och ingår i fingerprintet) [V]. FM-särdrag slås in i `aiTags` (`mergeMLDescription`) [V], så "Exteriör" kan komma från FM [A] | Per bild/grupp | [V] |
| Sortera (`exportToAddressFolders`) | Symlänkar + flytt, försumbart; geokodning (nätverk) | Adress per bild, HDR och förbättrade filer finns | Per fil (+ geokodning per adress) | [V] |
| Metadata (`writeIPTCMetadata`, argfiler om 100 filer, **en exiftool-process i taget**) | **Disk**: skriver om DNG (via symlänk, in place), förhandsbilder, HDR-TIFF/JPEG, förbättrade TIFF/JPEG och XMP för NEF | Adress + GPS + AI-taggar + filen på plats | Per fil | [V] |

### 1.3 Varför metadatasteget är diskbundet [R]

- **Bara HDR, 8 min:** DNG 912 × 55 MB ≈ 50 GB + HDR-TIFF ~97 × 150 MB ≈ 15 GB. Läsning + skrivning ≈ 130 GB / 480 s ≈ **270 MB/s**.
- **Med 612 förbättrade, +15 min:** ~612 × 180 MB ≈ 110 GB, läsning + skrivning ≈ 220 GB / 900 s ≈ **245 MB/s**.

Samma genomströmning i båda fallen talar för att disken begränsar, inte Perl eller processtarter. Det stämmer med FORBATTRINGAR ("`-stay_open` … processtart … millisekunder").

**Följd:** fler samtidiga exiftool-processer hjälper inte på T5. Däremot hjälper det att låta bli att skriva om filerna.

### 1.4 Fler fynd i koden som påverkar överlapp

- **16-bitars LZW ger större filer än okomprimerat.** 6000 × 4000 × 3 × 2 B = 144 MB okomprimerat, men du mäter cirka 180 MB. LZW-kodning och -avkodning är enkeltrådad [V, `HDRWriter.writeTIFFDirect` med `Compression: 5`]. Att avkodningen är flaskhalsen i Förbättra hänger ihop med detta [A, mät storlek och tid].
- **Förbättra på T5 kan redan vara delvis diskbundet.** TIFF-skrivning (~110 GB) + copyEXIF-omskrivning (~220 GB) under 29 min ≈ 190 MB/s [R/A]. Då hjälper fler samtidiga jobb föga förrän omskrivningen är borta.
- **`syncManifest` skriver `photoflow_session.json` och historikregistret synkront på MainActor vid varje `updateStep`/`updateStepProgress`** [V, `PipelineState.syncManifest`]. Med flera steg som rapporterar samtidigt blir det tusentals JSON-skrivningar.
- **`pipelineLog` gör `synchronizeFile()` (fsync) på varje rad** [V].
- **Global UI-status är envärd:** `state.progress`, `statusMessage`, `currentStep`, `currentFileIndex`, `totalFiles` och `currentMergeGroupId/InputURLs` [V]. Två steg samtidigt skriver över varandra.
- **`currentTask` är en enda `Process`** [V]. `cancel()` dödar bara den senast startade. Själva avbrytningen fungerar ändå via `ProcessCancellationBox` per anrop [V].
- **`runProcess` blockerar en tråd i `DispatchQueue.global` per process** [V]. Det går bra för ett fåtal processer, men det bör finnas ett tak.
- **openrsync** (kontrollerat): förloppsutdatan ser annorlunda ut än i GNU rsync, och nuvarande tolkning räknar filnamnsrader, inte färdiga filer [V]. Strömning från kopieringen kräver alltså en säkrare signal för "filen är klar".

---

## 2. Möjliga överlapp, med uppskattad vinst

Utgångsläge på T5 med 5 Gb/s (uppskattat):

| Steg | Tid |
|---|---|
| Kopiering | 1,5 min |
| DNG | 2,5 min |
| Förhandsbilder + bracket + kalender | ~1 min |
| AI | 8 min |
| HDR | 19 min |
| Förbättra | 29 min |
| Sortera | 0 min |
| Metadata | 23 min |
| **Summa** | **≈ 84 min** |

### 2.1 Skriv metadata när filen skapas (undvik dubbelskrivning)

- **Varför det går:** all metadata finns redan innan HDR startar. Kalendern körs före HDR [V] och AI körs före HDR [V]. Det enda som saknas är GPS, eftersom geokodningen ligger i Sortera. Den flyttas till `matchCalendarBookings` (eller ett eget litet steg direkt efter).
- **Steg A (enkelt):** ersätt `HDRWriter.copyEXIF` med ett exiftool-anrop som gör både `-TagsFromFile` och IPTC/XMP/GPS (samma rader som `exiftoolArguments(for:meta:)` bygger). Då görs en omskrivning i stället för två. `writeIPTCMetadata` hoppar över filer som redan har rätt stämpel (se 3.5).
- **Steg B (bäst):** skriv EXIF + IPTC + XMP direkt i `CGImageDestinationAddImageAndMetadata` (källans `CGImageSourceCopyMetadataAtIndex` + egna taggar). Då blir det **noll** omskrivningar. Det kräver att taggarna stämmer exakt med exiftools (`IPTC:SpecialInstructions`, `XMP:Subject`, GPS-referenser).
- **Vinst [R]:**
  - Metadata: 23 → ~8 min (kvar blir DNG, förhandsbilder och XMP), alltså **−15 min**.
  - Inne i Förbättra/HDR, om copyEXIF försvinner (steg B): ~250 GB mindre disktrafik, ungefär **−3 till −10 min** beroende på hur diskbundet Förbättra är [A].
- **DNG kan inte undvikas.** Konverteraren tar inte emot metadata, och Lightroom läser inbäddad XMP för DNG [A]. Den enda omskrivningen (~100 GB ≈ 6 min) kan däremot **göras samtidigt** som det processorbundna HDR/Förbättra (se 2.6).

### 2.2 Kortkopiering → DNG / förhandsbild / EXIF per fil

- **Hur:** egen kopierare i stället för rsync (`copyfile`/`FileManager` i en TaskGroup med 2 strömmar, skriv till temporärfil och byt namn, händelse per färdig fil, hoppa över om storlek + mtime stämmer). Alternativt FSEvents på slutliga filnamn, eftersom openrsync byter namn på temporärfilen när den är klar [A, verifiera].
- **Vinst på T5:** kopiering + DNG är 4 min i följd. Med överlapp begränsas det av T5-skrivningen, 29 + 50 GB / ~400 MB/s ≈ 3,3 min, och NEF-läsningarna kommer ur sidcachen. Det sparar **~1 min** [R].
- **På USB 2.0** blir vinsten ingen, eftersom bussen är gemensam.
- **Huvudnyttan** är indirekt: HDR för tidiga grupper kan börja medan resten kopieras (2.3).

### 2.3 Bracket-gruppering inkrementellt + HDR per grupp när gruppens DNG finns

- **Hur:** gruppera spekulativt. När tidsluckan passerats är råa gruppen klar och `findBracketSubsequences` + `classify` kan köras. Filerna kommer från kopierarens sorterade ordning, men `BracketAnalyzer` sorterar på **filnamn över alla undermappar** [V], så ordningen kan skilja sig (flera kortmappar, nummer som börjar om på 9999 → 0001).
- **Lösning:** när allt är kopierat körs den fullständiga analysen igen (sekunder). Resultatet jämförs med de spekulativa grupperna, och HDR-jobb för grupper som ändrats görs om. Det blir sällan, och utdata blir identiskt.
- **Krav:** HDR-jobbet får bara starta när **alla valda DNG:er** finns, aldrig med NEF som reserv.
- **Vinst:** döljer kopiering + DNG (~3–4 min) under HDR, men bara om det finns ledig processorkapacitet. DNG-konverteringen tävlar om processorn. Netto **~2–3 min** [A].

### 2.4 AI parallellt med HDR (och inom AI)

- HDR behöver inte AI [V]. Om AI (Neural Engine/GPU) körs samtidigt med HDR (processor + lite GPU) döljs **~8 min**, minus GPU-konkurrens med `CIRAWFilter` [A].
- Inom AI kan kvalitetsanalysen köras samtidigt med de seriella FM-bildtexterna. Båda läser bara förhandsbilder. Vinst **~1–2 min** [A].

### 2.5 Förbättring per bild så fort källan finns

- **Enskilda bilder (515)** behöver DNG + Vision-taggar + gruppens FM-text, om bilden är gruppens urval [V/A]. De kan starta **under** HDR.
- **HDR-jobb (97)** startar när HDR-TIFF:en för gruppen är skriven.
- **Vinst:** HDR (19 min) och Förbättra (29 min) blir ungefär max(…) i stället för summan, om processor och disk räcker:
  - Processorarbete grovt: HDR ~97 × 11 s × ~2 kärnor ≈ 2 100 kärnsekunder, Förbättra ~612 × 9 s × ~1,3 ≈ 7 200 kärnsekunder → ~9 300 / ~10 användbara kärnor ≈ **15–16 min** [A].
  - Disk efter 2.1 och 2.7: ~155 GB ≈ 10 min.
  - Realistiskt **20–25 min för HDR + Förbättra tillsammans**, mot 48 i dag.

### 2.6 Metadata per fil så fort adress + taggar finns

- När varje DNG har adress + taggar körs en exiftool-omskrivning i disk-poolen, **men först när alla som läser just den DNG:n är klara** (HDR-gruppen respektive förbättringen av den enskilda bilden). `-overwrite_original_in_place` skriver om samma inod, och en samtidig `CIRAWFilter`-läsning kan då se en halvskriven fil [A, troligt].
- Disken används lite under HDR (~21 GB läsning under 19 min), så de ~100 GB för DNG kan **döljas nästan helt**. Vinst ytterligare **~5–6 min**. Förhandsbilder och XMP för NEF görs också per fil.

### 2.7 Snabbare TIFF-format

- Okomprimerad 16-bitars TIFF: 144 MB, troligen mindre än LZW-filen och mycket snabbare att koda och avkoda, eftersom läsningen i stort sett bara blir en kopiering [A].
- Påverkar avkodningen i HDR-jobben i Förbättra (~6 s → <1 s per jobb × 97) och kodningen i alla 709 TIFF-skrivningar. Uppskattning **−3 till −8 min** [A, mät].

---

## 3. Resursstyrd schemaläggning: en orkestrerare för pipelinen

### 3.1 Byggstenar (Swift 6, `nonisolated` utom UI-bryggan)

```swift
nonisolated enum Resource: Hashable, Sendable {
    case cpu                       // tokens ≈ P-kärnor (sysctl hw.perflevel0.physicalcpu = 12)
    case memoryMB                  // budget, t.ex. 50 % av ProcessInfo.physicalMemory
    case neural                    // Vision-jobb (tak ~8)
    case foundationModel           // FM, tak 1
    case gpuRender                 // CIRAWFilter-tunga jobb, tak ~3 [A]
    case externalProcess           // exiftool/DNG Converter, tak ~4
    case diskIO(volumeID: String)  // per volym (URLResourceKey.volumeIdentifierKey)
}

nonisolated struct JobID: Hashable, Sendable { let stage: Stage; let unit: String }  // "DSC_1234", "group:17", "global"

nonisolated struct JobSpec: Sendable {
    let id: JobID
    let deps: Set<JobID>
    let demand: [Resource: Int]        // HDR: [.cpu: 2, .memoryMB: 5000, .gpuRender: 1, .diskIO(t5): 1]
    let priority: Int                  // högre = först (se 3.2)
    let run: @Sendable () async throws -> JobResult
}

actor ResourceBroker {
    func acquire(_ demand: [Resource: Int], priority: Int) async throws -> Lease  // allt eller inget, avbrytbar
    func release(_ lease: Lease)
    func setCapacity(_ r: Resource, _ n: Int)                                     // anpassas av regulatorn
    func setPaused(_ paused: Bool)                                                // paus = ingen ny tilldelning
}

@MainActor final class PipelineOrchestrator {
    // Dynamisk DAG: jobb läggs till när enheter blir kända (fil kopierad → DNG/preview/EXIF-jobb;
    // grupp stängd → HDR-jobb; taggar + källa klara → förbättringsjobb; läsare klara → metadatajobb).
    // Kör allt i en withThrowingTaskGroup under pipelineTask; skickar PipelineEvent via AsyncStream.
}
```

- **Allt eller inget** i `acquire` gör att inga baklås uppstår.
- **Minnet räknas i MB:** HDR ~5 000 vid 6000 px, Förbättra ~1 000 [A]. På 128 GB får 2–3 HDR och 5–6 förbättringar plats samtidigt. På 16 GB ger samma regler automatiskt en i taget.
- **Mottryck (backpressure):** begränsade köer mellan stegen. Till exempel startar ingen DNG-konvertering om mer än N färdiga DNG väntar på en blockerad konsument. Minnes-poolen sätter ett tak för samtidiga tunga jobb.

### 3.2 Prioritet

Det som blockerar mest nedströms går först.

- **Statisk grundordning:** DNG för filer i bracket-grupper > övriga DNG. HDR > Förbättra (HDR) > Förbättra (enskild bild) > DNG-metadata > metadata för förhandsbilder och XMP.
- **Plus "antal jobb som låses upp":** en DNG som fullbordar en grupp får bonus.
- **Lokalitet:** gör klart en påbörjad grupp innan nästa börjar, så att sidcachen träffas.

### 3.3 Mätning och anpassning medan körningen pågår

- **Minnestryck:** `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`.
  - `.warning`: minnesbudget × 0,6 och inga nya HDR-jobb.
  - `.critical`: högst ett tungt jobb.
  - Pågående jobb får bli klara.
- **Värme:** `ProcessInfo.thermalStateDidChangeNotification`. `.serious` ger processortak −25 %, `.critical` ger −50 %.
- **Diskgenomströmning:** `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)` (`ri_diskio_bytesread/written`) + `RUSAGE_CHILDREN` var 5:e sekund. AIMD på disk-tokens: öka så länge genomströmningen stiger, halvera när den planar ut eller väntetiderna växer.
- **Processorutnyttjande:** `getrusage` (själv + barnprocesser) delat med väggtid ger effektiva kärnor. Under ~80 % utan tryck på disk eller minne: +1 processor-token till de tunga poolerna.
- **Startvärden** kommer från `StepTiming` (s/bild per steg) och nya tider per enhet (se 5).

### 3.4 Avbryt och paus

- Orkestreraren är ett barn till `pipelineTask`, så `cancel()` sprids och `acquire` kastar `CancellationError`.
- `runProcess` dödar redan sin process via `ProcessCancellationBox` [V].
- `currentTask` ändras till en mängd, eller tas bort.
- `markActiveStepsCancelled` fungerar som förut eftersom faser per steg redan stöds [V].
- **Paus:** brokern slutar dela ut resurser och pågående jobb blir klara. Det är samma beteende som HDR har i dag (paus mellan grupper) [V]. Avfrågningen var 200 ms i `waitIfPaused` kan ersättas med en continuation-grind.

### 3.5 Fingerprints, manifest och hoppa-över per enhet

- **Varje enhet har en `isDone`-kontroll** som körs innan jobbet köas. Den återanvänder befintlig logik: `existingDNGNames`, förhandsbilder som finns, `AddressFolderLayout.locateHDRFiles`, `EnhancementLog`-fingerprint per jobb [V].
- **Nytt för metadata:** `metadata_stamps.json` med fingerprint per fil (adress, GPS, taggar, beskrivning, `metadataMarkerVersion`). Ersätter den globala `metadata_written.json` som bara jämför antal. Behövs för att filer som stämplats när de skapades ska hoppas över. `correctAddress` → `invalidateWrittenMetadataIfNeeded` ogiltigförklarar stämplarna för den adressen [V, finns i dag för markören].
- **Stegets fingerprint** (`setPendingFingerprint`) beräknas när steget är klart, det vill säga när alla enheter uppströms är kända och alla egna enheter klara. Därefter körs `completeStep` → `syncManifest`.
- **Atomiska utdata är ett krav:**
  - DNG Converter skriver till `dng/.partial/` och filen flyttas när processen avslutats.
  - Förhandsbilder skrivs till en temporärmapp.
  - HDR-TIFF görs redan atomiskt [V, `writeTIFF` .partial].
  - Konsumenter startas bara av orkestrerarens händelser, aldrig av att någon tittar i mappen.

### 3.6 App Nap

En enda `beginActivity` som täcker både kortkopieringen och pipelinen, och som ägs av orkestreraren, eftersom pipelinen kan starta under kopieringen. QoS `.userInitiated` behålls för de tunga jobben.

### 3.7 ETA och stegtider (som i dag förutsätter steg i följd)

- `PipelineState.eta` summerar återstående tid per steg [V]. Det blir fel när stegen överlappar.
- **Ny modell:** återstående arbete per resurs = Σ (återstående enheter × kostnad per enhet) / kapacitet. ETA = max över resurserna, plus svansen (sista HDR → sista förbättringen → metadata).
- **`StepTiming.Record`** får fälten `mode` ("sequential"/"overlapped"), `busySeconds`, `cpuSeconds` och `units`. `expectedDuration` filtrerar på `mode` så att gammal historik inte blandas in. `recordTiming` loggar väggtid per steg från första start till sista klar enhet, plus kostnad per enhet.

### 3.8 Gränssnittet

- Flera stegkort kan vara `.active` samtidigt (`StepPhase` per steg) [V]. Varje kort har redan egen räknare via `updateStepProgress` [V].
- **Ändras:**
  - `statusMessage` blir en sammanställning, till exempel "HDR 34/97 · Förbättra 120/612 · AI 400/912".
  - `currentMergeGroupId/InputURLs/OutputURL` blir listor eller "senaste".
  - `state.progress` beräknas som viktad totalsumma.
- **`syncManifest` debouncas** till högst 1 gång/s, plus tvingad skrivning vid `completeStep` och fel. `pipelineLog` buffras och fsync görs varje sekund.
- **UI-uppdateringar** från många jobb strypes till cirka 4 Hz per steg.

---

## 4. Snabba vinster utan ny orkestrerare (rangordnade efter vinst och risk)

| # | Åtgärd | Var | Vinst (T5) | Risk |
|---|---|---|---|---|
| 1 | Metadata skrivs när filen skapas för HDR och förbättrade filer (steg A: slå ihop copyEXIF + IPTC till ett exiftool-anrop). Geokodningen flyttas till kalendersteget. Stämplar per fil i `writeIPTCMetadata` | `HDRWriter.copyEXIF`, `HDREngine.merge`, `EnhancementEngine.enhance`, `PipelineRunner+Calendar/SortFolders/Metadata` | −15 min (metadata) | Medel: taggarna måste stämma, `reMergeHDR` måste stämpla likadant |
| 2 | Mät TIFF-storlek och -tid. Byt till okomprimerad 16-bitars TIFF om den är mindre eller snabbare | `HDRWriter.writeTIFFDirect` | −3 till −8 min [A] | Låg (filformat; fingerprints påverkas inte) |
| 3 | HDR 2–3 grupper samtidigt (TaskGroup enligt mönstret i `runEnhancePhotos`). Taket räknas på `ProcessInfo.physicalMemory` (≤16 GB → 1) | `PipelineRunner+HDR.runHDRMerge` | −8 till −11 min [A] | Låg–medel (minne; UI-fälten för aktuell grupp) |
| 4 | AI samtidigt med HDR (`async let` i `startPipeline`). Kvalitetsanalys samtidigt med FM-texter | `PipelineRunner.startPipeline`, `+AITagging.runAITagging` | −8 min + −1–2 min [A] | Medel (delad `state.progress/statusMessage`, felhantering för båda) |
| 5 | Förbättra: `maxConcurrent` 3 → 5–6 på 128 GB, **efter** #1 och #2 (annars disken) | `+Enhance.runEnhancePhotos` | −5 till −8 min [A] | Låg |
| 6 | Debounce av `syncManifest`, buffrad `pipelineLog` | `PipelineState.syncManifest`, `PipelineRunner.pipelineLog` | Sekunder till en minut; förutsättning för parallellism | Låg |
| 7 | DNG: atomisk utdata (`.partial`-mapp). 2–3 parallella partier, eller `-mp` | `+DNG.runDNGConversion` | Korrekthet; ~−1 min på intern disk, ~0 på T5 | Låg |
| 8 | Metadata för HDR/förbättrade utan någon omskrivning (steg B: `CGImageDestinationAddImageAndMetadata`) | `HDRWriter` | −3 till −10 min till [A] | Medel–hög (taggparitet) |
| 9 | Parallella exiftool-partier / `-stay_open` | `+Metadata` | ~0 på T5 (diskbundet [R]); liten på intern disk | Låg/medel. Låg prioritet, samma slutsats som FORBATTRINGAR |

Uppskattad tid efter #1–#7: kopiering 1,5 + DNG 2,5 + 1 + max(AI 8, HDR ~8) + Förbättra ~13–16 + metadata ~6–7 ≈ **~35–40 min**.

---

## 5. Mät först

### 5.1 Instrumentering (bör vara på plats före allt annat utom #6)

- **`OSSignposter`** (kategori "pipeline", ett intervall per jobb med steg och enhet) samt delfaser:
  - `HDREngine.merge`: readWhiteBalance, render × N, align, fuse (vikter, pyramider, kanaler), sharpen, makeRGB16, writeTIFF, writeJPEG, copyEXIF.
  - `EnhancementEngine.enhance`: loadImage/decode, analys, horisont, render, write, exif.
  - DNG-parti, exiftool-parti, Vision/FM/kvalitet per bild.
  - Kan ses i Instruments (Points of Interest + System Trace).
- **`timings.jsonl` i outputmappen:** steg, enhet, start, slut, sekunder, bytes in/ut (filstorlekar).
- **Resursräknare per steg:**
  - Processortid för appen och barnprocesserna: `getrusage(RUSAGE_SELF/RUSAGE_CHILDREN)`.
  - Disk: `proc_pid_rusage(RUSAGE_INFO_V4)`.
  - Toppminne: `task_info` phys_footprint, samplat 1 Hz.
  - Loggas per steg i `pipeline.log` och `StepTiming`. Eftersom stegen i dag körs i följd blir uppdelningen per steg ren.
- **Under riktmärket (du kör manuellt):** `iostat -d -w 1`, `sudo powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000`, Instruments-mallarna Time Profiler + Disk I/O.

**Frågor mätningen ska besvara:**
- Hur många kärnor använder en HDR-grupp?
- Hur fördelas tiden i Förbättra mellan avkodning, kodning och copyEXIF, och är steget diskbundet på T5?
- Är LZW-TIFF större än 144 MB?
- Hur mycket processor och disk använder DNG Converter?
- Hur mycket bromsar AI HDR via GPU:n?

### 5.2 Riktmärke som går att upprepa

- **Fast testmängd:** cirka 150 NEF från dagens session (~20 bracket-grupper ≈ 80 filer + 70 enskilda, blandat inne/ute och porträtt), kopierade en gång till en skrivskyddad mapp.
- **Körning:** `photoflow-cli run --input … --output <ny mapp> --no-calendar --json`. CLI:t körs utan kalender och kör metadatasteget manuellt [V].
  - 1 uppvärmningskörning kastas (Metal-shadercache, enligt FORBATTRINGAR).
  - Därefter 3 körningar på intern disk och 3 på T5.
  - JSON-sammanfattning, `timings.jsonl` och iostat-logg sparas.
- **Determinism:** FM-texter är troligen inte deterministiska [A]. För jämförelser körs `aiDescriptionsEnabled = false`, eller en färdig `ai_tags.json` läggs in i förväg.
- **Referens:** kör den sekventiella versionen **två gånger** först, för att se vad som redan nu är deterministiskt (GPU-rendering, DNG Converter som kan bädda in tidsstämplar [A]).

---

## 6. Faser

### Fas 1: snabba vinster + mätning (1–2 veckor)

**Innehåll:** 5.1 och 5.2, därefter #6, #7 (atomisk DNG), #2, #1 (steg A), #3, #5, #4.

**Verifiering:**
- `bracket_groups.json`, `calendar_matches.json` och `enhancement.json` (parametrar) är byte-identiska med referensen.
- HDR och förbättrade filer: SHA-256 av avkodade pixelbuffertar (ImageIO) är identisk.
  - TIFF-formatbytet i #2 ändrar filbytes men inte pixlarna.
- Metadata: `exiftool -j -G1 -a -struct` med flyktiga taggar bortfiltrerade (File:*, eventuella XMP-id:n) ger samma taggmängd per fil.
- `photoflow-cli verify` godkänd. NEF-md5 oförändrad (som i rök-testet).
- Tider enligt 5.2.

**Risker:**
- Taggparitet vid metadata-vid-skapande.
- `reMergeHDR` och manuell adressrättning måste stämpla om.
- Minnestopp vid 3 HDR samtidigt i full upplösning (`hdrMaxDimension = 0`). Taket ska räkna på faktisk dimension.

### Fas 2: strömning mellan utvalda steg (2–3 veckor)

**Innehåll:**
- En liten `ResourceBroker` + jobbkö, men bara för blocket **HDR ∥ Förbättra ∥ AI ∥ DNG-metadata** (2.4–2.6), med läsarräknare per DNG.
- Stegen före (kopiering → DNG → förhandsbilder → bracket → kalender) körs som förut i följd. De tar ~5 min.
- UI: flera aktiva kort, sammanställt `statusMessage`, ETA per resurs, `StepTiming.mode`.

**Verifiering:**
- Samma jämförelser som fas 1.
- Plus avbrottstester: avbryt vid slumpvisa tidpunkter (10 körningar), starta om, och kontrollera att slutresultatet är identiskt med en körning utan avbrott (hoppa-över-logiken per enhet).
- Minnestest med `hdrMaxDimension = 0`.
- Tester i Swift Testing för `ResourceBroker` (allt eller inget, prioritet, avbrytning, paus) med påhittade jobb.

**Risker:**
- Kapplöpning mellan DNG-läsning och metadataskrivning (läsarräknaren).
- Förvirrande UI.
- ETA blir fel de första körningarna, innan tider per enhet finns.

### Fas 3: generell orkestrerare (2–4 veckor)

**Innehåll:**
- Hela DAG:en dynamisk: egen kopierare med händelser per fil, DNG per fil eller parti, inkrementell bracket-gruppering med kontroll efteråt (2.3), förhandsbilder och Vision per fil.
- Anpassning efter minnestryck, värme och diskgenomströmning (3.3).
- En gemensam `beginActivity`.
- Pipelinen startar under kortkopieringen.

**Verifiering:**
- Samma jämförelser.
- Plus test med nummerbyte (9999 → 0001) och flera kortmappar för den spekulativa grupperingen.
- Långtest med skärmlås (App Nap).
- Körning med en simulerad trög disk (USB 2.0 eller nätverksvolym) för att se att disk-AIMD stryper.

**Risker:**
- Komplexiteten (testbarhet). Mitigeras med en fristående `PipelineOrchestrator` som kan testas med påhittade jobb.
- Skillnader mellan spekulativ och slutlig gruppering.
- Ny kopierare i stället för rsync (återupptagning).

---

## 7. Öppna frågor (med min rekommendation)

1. **Ska arbetsmappen (`dng/`, `hdr/`, `enhanced/`) ligga på intern disk, med leverans till T5 när filerna blir klara?** På T5 blir pipelinen diskbunden (~340 GB ≈ 20 min golv). Intern disk gav DNG 0,13 s/bild mot 1,8.
   *Rekommendation: ja*, om det finns ~200 GB ledigt internt. Leveransen kan strömma i bakgrunden.
2. **Måste DNG:erna ha AI-taggar och adress inbäddade?** Det kostar en omskrivning på ~100 GB.
   *Rekommendation: behåll det* (Lightroom läser inbäddad XMP för DNG [A]), men gör det per fil medan HDR/Förbättra pågår, enligt fas 2.
3. **Behövs DNG på den kritiska vägen alls?** `CIRAWFilter` läser NEF (HDR har NEF som reserv [V]), men stödet för HE*-NEF är inte bekräftat [A].
   *Rekommendation: testa en HE*-NEF i `RAWRenderer.render`.* Om det fungerar och ger samma resultat blir DNG ett leveransjobb med låg prioritet i bakgrunden. Det ändrar utdata, så det kräver ditt godkännande.
4. **TIFF-format för HDR och förbättrade filer:** okomprimerat (144 MB, snabbast), LZW (i dag) eller färre 16-bitars TIFF:er (till exempel bara JPEG för enskilda bilder)?
   *Rekommendation: okomprimerat*, om mätningen bekräftar att LZW är större och långsammare.
5. **Hur mycket av datorn får PhotoFlow ta?**
   *Rekommendation:* standard "lämna 2 P-kärnor och 25 % av minnet", plus ett läge "Full fart" när datorn står obevakad.
6. **Får pipelinen starta medan kortet kopieras?**
   *Rekommendation: ja i fas 3*, efter att egen kopierare och atomiska utdata är på plats.
7. **Vad räknas som "samma resultat"?**
   *Rekommendation:* identiska pixlar och JSON (med AI-taggar inlagda i förväg) och identisk taggmängd för metadata, men inte identiska filbytes (TIFF-format, tidsstämplar från DNG Converter).
8. **Ska förbättringen vänta på FM-texten för gruppen**, eftersom `isExterior` kan komma från FM-taggar?
   *Rekommendation: ja.* Behåll beroendet för korrekthetens skull. Det kostar lite när AI körs samtidigt med HDR.

---

## 8. Uppmätt (fas 1a)

Testmängd: 160 NEF (20 bracket-grupper, 70 enskilda; `scripts/benchmark.sh`, kopia i `~/PhotoFlowBenchmark/input`, 5,0 GB), M3 Max, **intern disk**, `--no-calendar`, AI-bildtexter av, en uppvärmning + 2 mätta körningar per version, Debug-bygge (optimerat). Baslinje = commit `f57c891`. Siffrorna är sekunder; T5 är **inte** mätt än.

| Steg | Baslinje | Efter fas 1a | Förändring |
|---|---|---|---|
| Konvertera DNG | 14,9 | 10,9 | −27 % (`-mp`) |
| Skapa previews | 3,2 | 3,2 | |
| AI-taggning (Vision + kvalitet) | 5,4 | 5,3 | |
| Skapa HDR (23 grupper) | 246,3 | 221,7 | −10 % (okomprimerad TIFF, ingen LZW-kodning) |
| Förbättra bilder (92 st) | 196,3 | 130,7 | −33 % (okomprimerad TIFF in och ut) |
| Skriv metadata | (ej tidtagen i CLI:t före fas 1a) | 28,9 | |
| **Hela körningen** | **496,3** (497,3 / 495,4) | **402,3** (402,7 / 401,9) | **−19 %** |

Körningarna varierar mindre än 1 s, så skillnaderna är verkliga. Debounce av manifest/logg (#6) ger inget mätbart i det här körläget (få steg rapporterar samtidigt); den är en förutsättning för fas 2.

**Resurser per steg (efter, medianer; disk = appen + barnprocesser):**

| Steg | tid s | CPU s | kärnor i snitt | läst MB | skrivet MB | toppminne MB |
|---|---|---|---|---|---|---|
| DNG | 10,9 | 139,2 | 12,8 | 529 | 7 364 | 9 |
| Förhandsbilder | 3,2 | 3,2 | 1,0 | 0 | 602 | 17 |
| AI | 5,3 | 23,5 | 4,4 | 0 | 3 | 154 |
| HDR | 221,7 | 204,0 | **0,9** | 0 | 6 025 | 6 303 |
| Förbättra | 130,7 | 202,7 | **1,6** | 1 | 23 790 | 10 044 |
| Metadata | 28,9 | 28,8 | 1,0 | 261 | 15 648 | 4 690 |

Svar på planens frågor, så långt de går att läsa av:
- **HDR använder i snitt 0,9 kärnor** av 16 (en grupp i taget), Förbättra 1,6 (tre samtidiga jobb). Det är den största kvarvarande processorreserven (fas 1b/1c).
- **Tid inne i HDR-gruppen (`timings.jsonl`):** RAW-rendering av varje exponering 2,08 s/st (78 st = 162 s av 222 s, alltså 73 %), fusion 0,53 + 3 × 0,37 s per grupp, `copyEXIF` 0,33 s, TIFF-skrivning 0,05 s. Fusionen är alltså **inte** flaskhalsen; `CIRAWFilter`-renderingen är det.
- **Inne i Förbättra (per bild, summerat över 3 samtidiga):** `load` 3,27 s (för DNG-bilder är det den RAW-rendering som `loadImage` gör direkt; för HDR-TIFF ~0), `copyEXIF` 0,37 s, nedskalning/analys 0,27 + 0,06 s, slutrendering 0,11 s, TIFF-skrivning 0,05 s. RAW-renderingen av enskilda bilder dominerar.
- **Metadatasteget** skriver 15,6 GB för 160 bilder (DNG skrivs om): disken är relevant där.
- **DNG Converter** använder 12,8 kärnor med `-mp` på intern disk (CPU-bundet), skriver 7,4 GB.

### TIFF-format (#2)

Tre riktiga HDR-bilder (`hdr_group_96/126/130.tiff`, 6000 × 4000, 16 bpc RGB), tre upprepningar, `-O`-kompilerat mätprogram med samma `CGImageDestination`-väg som `HDRWriter`:

| | Storlek | Kodning | Avkodning (ImageIO + ritning till 16-bitarsbuffert) |
|---|---|---|---|
| LZW (före) | 172–177 MB | 1,07–1,12 s | 0,33 s |
| Okomprimerad | 137 MB | 0,05–0,06 s | 0,07 s |

LZW var alltså **20 % större** och ~20 gånger långsammare att koda; planens antagande (1.4) stämde. Avkodade pixlar är bit-för-bit identiska (SHA-256 på rå 16-bitars RGBX, samma hash för alla tre bilder i båda formaten). **Beslut: okomprimerad** (`HDRWriter.tiffCompression = 1`); `HDREngine.version`/`EnhancementEngine.version` bumpas inte eftersom pixlarna är desamma. Kommentaren "~6 s avkodning" i `runEnhancePhotos` stämde inte för ImageIO (0,33 s).

### DNG-konverterarens `-mp` (#7)

150 NEF, intern disk: en process utan flaggan 13,1 s; fyra egna samtidiga processer 8,8 s; två 9,7 s; **en process med `-mp` 8,8 s** (−33 %). Metadata (inkl. `RawImageDigest`) är identisk med och utan `-mp`. Därför `-mp` med oförändrad partistorlek (50); egna parallella partier gav inget extra. Förväntad vinst på T5: ~0 (diskbundet). Utdata skrivs nu till `dng/.partial/` och flyttas när processen lyckats.

### Verifiering mot baslinjen (`scripts/compare-outputs.sh`)

Baslinje körning 2 mot efter körning 2 (och körning 1 mot körning 1): `bracket_groups.json` värdeidentisk (bytes skiljer p.g.a. slumpad nyckelordning, `JSONSerialization` utan `sortedKeys`, även mellan två baslinjekörningar), `enhancement.json` identisk (92 poster), 230 HDR-/förbättrade bilder med identiska avkodade pixlar, metadata (`exiftool -j -G1 -a -struct`) identisk för 710 filer. Flyktiga taggar som filtreras: `File/System/ExifTool`, XMP-id:n och `MetadataDate`, alla `ModifyDate`, DNG:s `PreviewDateTime`/`PreviewImageStart` och `Composite:SubSecModifyDate`, samt TIFF-strukturtaggarna `Compression`/`StripOffsets`/`StripByteCounts`/`RowsPerStrip`. Två baslinjekörningar mot varandra är identiska med samma filter, så filtret döljer inget som skiljer versionerna åt.


## 8b. Uppmätt (fas 1b: metadata när HDR- och förbättrade filer skapas)

Samma testmängd och maskin (intern disk, AI-bildtexter av). Baslinje = commit `81bde1f` (+ samma testväg `--calendar-matches` i CLI:t), efter = fas 1b. Två lägen:
- **Utan kalender** (`--no-calendar`, som 1a): ingen adress/GPS, så HDR-/förbättrade filer får ingen IPTC och ändringen ska inte märkas.
- **Med kalender** (`benchmark.sh --calendar-matches`): sessionens riktiga `calendar_matches.json` med koordinater angivna som manuellt rättade. MapKit-geokodningen svarar inte headless, och utan testvägen frågade CLI:t EventKit och hängde (manifestmigreringen skapar ett kalender-record utan fingerprint).

Sekunder. Baslinjen med kalender är medianen av tre körningar (47,3 / 47,7 / 54,5 för metadatasteget), efter är en körning. Datorn gick på batteri under en del av baslinjekörningarna och en mätserie kastades när batteriet tog slut, så räkna med några procents brus i HDR och Förbättra.

| Steg | Baslinje utan kal. | Efter utan kal. | Baslinje med kal. | Efter med kal. |
|---|---|---|---|---|
| Skapa HDR | 221,7 | 224,5 | 222,8 | 234,7 |
| Förbättra bilder | 133,9 | 131,5 | 131,3 | 124,3 |
| Skriv metadata | 29,1 | 31,5 | **47,5** | **30,0 (−37 %)** |
| Metadata, skrivet till disk | 15,6 GB | 15,7 GB | **44,1 GB** | **14,5 GB** |
| Hela körningen | 405,9 | 409,6 | 422,7 | 412,1 |

- Metadatasteget hoppade över 212 av 659 filer tack vare stämplarna (alla HDR- och förbättrade filer i adressmappar). Det som återstår är DNG (in place), förhandsbilder och XMP för NEF: 14,5 GB, lika mycket som utan kalender.
- Kostnaden i HDR/Förbättra: exiftool-anropet tar 0,37–0,39 s per HDR-grupp (förut `copyEXIF` 0,33 s) och 0,40 s per förbättrad bild (förut 0,38 s). Det blir ungefär +1,5 s HDR och +2 s Förbättra i hela körningen, mot −17 s i metadatasteget. På T5 (diskbundet metadatasteg) bör vinsten bli större, i proportion till de ~30 GB mindre som skrivs.
- **Verifiering** (`scripts/compare-outputs.sh`): med kalender (baslinje mot efter, två par) är `bracket_groups.json` värdeidentisk, `calendar_matches.json` byte-identisk, `enhancement.json` identisk, 230 bilder har identiska pixlar och metadata är identisk för 699 filer (adress, GPS, IPTC/XMP på HDR, förbättrade, DNG, förhandsbilder och sidecars). Utan kalender: identiskt för 230 bilder och 710 metadatafiler.
- **Fynd:** `Process` skickar argumenten i filsystemets representation (NFD), så "ä" hade skrivits som "a" + kombinerande trema i IPTC om taggarna gått som processargument. `HDRWriter.writeMetadata` går därför via en argfil, som metadatasteget. Pipelinen skriver IPTC som UTF-8 utan `CodedCharacterSet` (som förut), så verktyg som läser IPTC som Latin-1 visar "LindvÃ¤gen".

---

### Critical Files for Implementation
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/HDR/HDRWriter.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+Metadata.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+HDR.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Models/PipelineState.swift

Andra filer som också berörs:
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+Enhance.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Enhancement/EnhancementEngine.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+DNG.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+Calendar.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Pipeline/PipelineRunner+AITagging.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/StepTiming.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Views/ContentView.swift
- /Users/fredrik/Developer/photo-preprocesser/PhotoFlow/SourcesCLI/PhotoFlowCLI.swift
