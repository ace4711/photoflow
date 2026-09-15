# Förbättringar

## Fas 0 – Grund

Utfört autonomt på branchen `forbattringar` medan användaren sov. Alla steg byggdes
grönt (`xcodebuild ... build`) före varje commit, och testmålet gick grönt
(`xcodebuild ... test`) innan sista committen. Se `git log --oneline` för
commit-för-commit-historik.

### 1. Synkat project.yml med pbxproj
`INFOPLIST_KEY_NSMicrophoneUsageDescription` och
`INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` fanns bara i den genererade
`project.pbxproj` (troligen tillagda direkt i Xcode någon gång) och saknades i
`project.yml`. Lades till i yml. Jämförde i övrigt alla build settings mellan
yml och pbxproj — inga andra skillnader hittades (resten av settings i pbxproj
är antingen xcodegen-genererade standardvärden på projektnivå eller redan
speglade i yml).

### 2. Deployment target höjd till macOS 26.0
`options.deploymentTarget.macOS` och `MACOSX_DEPLOYMENT_TARGET` höjda från
14.0 till 26.0. `SWIFT_VERSION` behålls på 5.9 (Swift 6-migrering är en egen,
större insats som görs senare).

Höjningen exponerade nya deprecation-varningar som **inte** är åtgärdade i
denna fas (se "Kvarstående" nedan):
- `CalendarService.swift`: `CLGeocoder` och `geocodeAddressString` deprecated
  till förmån för MapKit / `MKGeocodingRequest`.
- `AddressBanner.swift`: `CLPlacemark.placemark`-relaterad API deprecated till
  förmån för `location`/`address`/`addressRepresentations`.

Detta är en riktig API-migrering (inte en varningsundertryckning) och bedömdes
vara utanför scopet för "grund och städning" — dokumenteras här som
kvarstående arbete för en kommande fas.

### 3. Död kod borttagen
Verifierat med `grep` i hela `Sources/` innan borttagning att inget annat
refererade koden. Appen startar alltid direkt i `DashboardView`
(`PhotoFlowApp` → `ContentView` → `DashboardView`), så launcher-/watch-läget
var redan helt bortkopplat:

- `Views/LaunchModeView.swift` (`LaunchModeView`, `DirectoryRow`, `ModeCard`)
- `Views/WatchView.swift`
- `Views/PipelineProgressView.swift` (bara omnämnd i en kommentar i
  `AudioService`)
- `Models/AppMode.swift` och `PipelineState.appMode` (sattes bara av de
  borttagna vyerna)
- `SidebarView` och `DoneView` i `Views/ContentView.swift` (oanvända, byggde
  på `appMode`)
- `PipelineRunner`: `runPhotoshopHDRSingleGroup(...)` och
  `photoshopHDRSingleGroupScript()` — HDR-sammanslagning görs numera med
  Mertens fusion (Python), inte Photoshop
- `DependencyManager`: "Adobe Photoshop 2025"-verktygsposten och dess
  specialkontroll av `Merge To HDR.jsx`
- `PreviewCullView`: oanvända `skipPhoto()`, `togglePhoto()`, `actionButton(...)`,
  samt `StatBadge` (ersatt av `StatPill`, hade kommentaren "Keep backward
  compat" men inga anropare kvar)
- `scripts/process-nef.sh` — föråldrad fristående kopia av pipelinen;
  `scripts/`-mappen togs bort eftersom den blev tom

### 4. Kompilatorvarningar fixade
- **`makeIterator` unavailable from asynchronous contexts** (PipelineRunner,
  två ställen): brutit ut `FileManager`-enumereringen till en synkron,
  statisk hjälpfunktion `PipelineRunner.findFiles(withExtension:in:)` som
  anropas från de async-funktionerna istället för att iterera enumeratorn
  direkt i async-kontext.
- **Captured var `results`** (DependencyManager.runChecks): infört en
  explicit `let results = mutableResults`-kopia innan den skickas in i
  `MainActor.run`-closuren.
- **Oanvänd `oldAddress`** (PipelineState.correctAddress): borttagen (togs
  bort helt i samband med döda-kod-städningen).

Resultat: 0 varningar från egen kod, förutom de nya
CLGeocoder/placemark-deprecations som beskrivs i punkt 2 (dessa fanns inte
innan höjningen till macOS 26 och kräver en riktig migrering).

### 5. Enhetstestmål `PhotoFlowTests`
Nytt target (`bundle.unit-test`) i `project.yml`, med `dependencies: [target:
PhotoFlow]` så att XcodeGen automatiskt sätter `TEST_HOST`/`BUNDLE_LOADER` för
`@testable import PhotoFlow`. Lagt till `GENERATE_INFOPLIST_FILE: YES` och
tillåtande kodsignering (samma som app-targetet) — annars vägrar xcodebuild
köra testet ("Cannot code sign because the target does not have an
Info.plist file"). Definierat ett delat schema `PhotoFlow` som bygger och kör
båda targets.

Tester skrivna med Swift Testing (`import Testing`), i `PhotoFlow/Tests/`:

- **CalendarServiceTests** (`@MainActor`, eftersom `CalendarService` är det):
  - `extractAddress(from:)` mot alla tre exempel i doc-kommentaren:
    - "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik:0701234567" →
      "Lindvägen 12, Tyresö"
    - "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67" →
      "Almstigen 9, Handen"
    - "Kastanjevägen 60 bv, Fjälling 070-765 43 21" →
      "Kastanjevägen 60 bv, Fjälling"
    - **Ingen bugg hittades** — alla tre gav redan exakt förväntat resultat
      vid manuell spårning och vid testkörning, så inga tester behövde
      markeras `.disabled`.
  - `extractBookingInfo(from:)` mot samma exempel (ett med bokningsinfo, två
    utan eftersom de saknar den andra kommadelen som krävs för att skilja
    stad från extra info).
- **StepStatusTests**: `durationText` (sekunder, minuter+sekunder, nil) och
  `statusText` för idle/active (med/utan totalCount)/complete (med/utan
  varaktighet)/error/watching.

18 tester, alla gröna (`xcodebuild ... test`).

### Kvarstående (inte gjort i Fas 0, med motivering)
- **CLGeocoder → MapKit/MKGeocodingRequest-migrering** i `CalendarService.swift`
  och `AddressBanner.swift`. Kräver att förstå hur `MKGeocodingRequest`s
  async-API och resultatformat skiljer sig från `CLGeocoder`/`CLPlacemark`,
  samt regressionstesta geokodning och adressvisning. För stort för "grund
  och städning" — separat fas.
- **Swift 6-strict concurrency-migrering** (SWIFT_VERSION → 6): medvetet
  uppskjutet enligt uppgiftsbeskrivningen.
- Inga fler döda-kod-kandidater utöver de som listas ovan hittades vid
  grep-genomgång av Views/Services/Models, men täckningen är inte
  100 % garanterad för väldigt indirekt använd kod (t.ex. via
  `@ViewBuilder`-closures som grep kan missa) — en framtida "riktig"
  död-kod-analys (t.ex. Periphery) kan hitta mer.

## Fas 1a – Kritiska pipelinebuggar

Utfört autonomt på branchen `forbattringar` medan användaren sov, en punkt i
taget med bygge + tester (`xcodebuild ... build` / `... test`) gröna före
varje commit. Se `git log --oneline` för commit-för-commit-historik (en
commit per punkt nedan). 37 tester totalt efter denna fas, alla gröna.

### 1. Metadatasteget förstörde NEF-symlänkar
`writeIPTCMetadata` körde `-overwrite_original` på alla filer i
adressmapparna. På en symlänk gör exiftool då om länken till en full kopia
av målet (verifierat) — dubblerar diskanvändning och metadatan hamnar på en
ny fil, inte på det staging-original resten av pipelinen refererar. NEF-
filerna i `<adress> ÖVRIGA` är symlänkar till användarens ORIGINAL-filer,
så det här var även en risk att i praktiken "smygkopiera" originalen.

- DNG, preview-JPEG och HDR-filer (egna staging-filer): `-overwrite_original_in_place`
  (bevarar symlänken, skriver igenom till målet — verifierat).
- NEF: rörs aldrig. I stället skrivs/uppdateras en XMP-sidecar bredvid
  länken (`<basnamn>.xmp`) med `-o` och XMP-varianterna av taggarna
  (`XMP:Title`, `XMP-iptcCore:Location`/`Sublocation`, `XMP:Description`,
  `XMP:Subject`, GPS via `XMP:GPSLatitude`/`GPSLongitude` + refs). Finns
  sidecaren redan uppdateras den direkt med `-overwrite_original` (den är
  en vanlig fil, ingen symlänk).
- Argfil-byggandet är utbrutet till en ren, testad funktion:
  `PipelineRunner.exiftoolArguments(for:meta:)` med `IPTCFileMetadata`
  (adress/titel/beskrivning är optional så AI-bara filer i "Osorterade" kan
  taggas utan tomma adressfält).
- `.xmp`-filer hoppas över när mappar listas för taggning.

### 2. DNG-filer fick aldrig metadata
`writeIPTCMetadata` letade i `<adress> TITTBILDER` / `<adress> DNG` /
`<adress> ÖVRIGA`, men `exportToAddressFolders` lägger DNG-symlänkar direkt
i `<adress>` (utan suffix) — DNG fick alltså aldrig GPS/IPTC/AI-metadata.
Samma bugg fanns i "Osorterade"-hanteringen, som dessutom gated hela
AI-taggningsblocket på att en mapp med fel namn skulle existera.

- Ny `Services/AddressFolderLayout.swift`: enda källan för mappsuffixen
  (DNG = inget suffix, TITTBILDER, ÖVRIGA). Används i
  `exportToAddressFolders`, `writeIPTCMetadata` och `deleteRejectedFiles`.
- `metadata_written.json` har nu `"version": 2`. Markörer utan matchande
  version litas inte på, så **en befintlig session får korrekt metadata på
  DNG och NEF (som sidecar) automatiskt vid nästa körning av metadatasteget**
  — se "Manuell testning" nedan.

### 3. Bracket-inställningarna ignorerades
`runBracketAnalysis` skickade hårdkodat `"15", "3"` till python-skriptet
oavsett `AppSettings.maxTimeGap`/`minBracketSize`. Fixat: skickar de riktiga
inställningarna, skriver dem som `"params"` i `bracket_groups.json`, och
skip-kontrollen kräver nu att både antal bilder OCH params matchar aktuella
inställningar (annars körs analysen om).

### 4. Alla bilder i en grupp fick gruppens starttid
En bracket/single-grupp kan spänna över flera minuter, men varje foto fick
samma `dateTime` (gruppens `date_start`) — kunde ge fel adress för bilder
nära en bokningsgräns. Python-skriptet skriver nu per-fil `"datetimes"`
(samma ordning som `"files"`), som `loadBracketGroups` och
`matchCalendarBookings` använder när de finns (gamla `bracket_groups.json`
utan fältet fortsätter fungera via fallback till `date_start`). Fixade även
`precise_ts`: `SubSecTimeOriginal` kan ha 1–3 siffror och tolkades som ett
helt antal centisekunder (fel för allt utom exakt 2 siffror) — tolkas nu
som decimaler efter "0.".

### 5. Hoppa-över-logik jämförde antal i stället för namn
- `runPreviewGeneration` hoppade över om `existingPreviews >= nefFiles.count`
  — ren antalsjämförelse som kan stämma trots att filerna inte matchar.
  Jämför nu mängden bas-namn.
- `runDNGConversion` räknade DNG i hela outputDir inklusive adressmappars
  symlänkar. Begränsat till `dng/`-staging-mappen, bara vanliga filer (inte
  symlänkar). `finalDNGFiles`-filtreringen är gjord case-insensitive
  (`.DNG`).

### 6. Hårdkodade verktygssökvägar
`/opt/homebrew/bin/exiftool`, `/opt/homebrew/bin/python3`,
`/usr/bin/python3` var hårdkodade på sju ställen — bryter på Intel-Mac
(Homebrew i `/usr/local/bin`) eller om verktyget saknas.

- Ny `Services/ToolLocator.swift`: `exiftool`, `python3ForAnalysis`,
  `python3WithOpenCV` (den sistnämnda kör faktiskt `import cv2, numpy` och
  cachar resultatet). Alla sju anropsställen i `PipelineRunner` använder nu
  denna, med tydliga svenska `PipelineError.toolNotFound(...)`-meddelanden
  när ett verktyg saknas (t.ex. "installera med: brew install exiftool").
- `DependencyManager`: ny rad "OpenCV (python3 + cv2/numpy)" (optional),
  vars status kontrolleras via samma logik.

### 7. Loggning
- Global logg flyttad från `~/Desktop/photoflow.log` till
  `~/Library/Logs/PhotoFlow/photoflow.log` (standardplatsen för apploggar
  på macOS). Öppen `FileHandle` och statiska formatters/loggers i stället
  för att öppna/skapa nya per rad.
- `stepStatuses[step].logEntries` begränsas till senaste 1000 raderna
  (tar bort äldsta 200 vid gränsen).
- `os.Logger` (subsystem `com.photoflow.app`, kategori = steg-namnet för
  `appendStepLog`, `"general"` för `appendLog`) parallellt med
  fil-loggningen, så loggar syns i Console.app.
- Grep-verifierat att ingen UI-text refererade den gamla Desktop-sökvägen.

### Beslut/avgränsningar i denna fas
- Punkt 3 (bracket-inställningar) fick inga nya Swift-tester eftersom
  logiken bara är process-anrop-wiring (skickar värden vidare till ett
  externt python-skript) — verifierat manuellt genom att extrahera och köra
  det inbäddade python-skriptet mot syntetiska EXIF-CSV:er i scratchpad
  (både `params`-fältet och SubSecTimeOriginal-fixen i punkt 4).
- `PipelineRunner.pipelineLog`/`logDecision` (per-körnings-loggen i
  `outputDir/pipeline.log`) rördes inte — de använder redan en öppen
  `FileHandle` och är utanför det som efterfrågades (bara den globala
  Desktop-loggen). De skapar fortfarande en formatter per rad, vilket är en
  billig framtida städning men inte en datakorruptionsbugg.
- `WatchService`s eget `photoflow.log` (i output-/tmp-mappen, en per-session
  bevaknings-logg) är en annan fil än den globala Desktop-loggen som denna
  fas adresserar och lämnades orörd.

### Manuell testning användaren bör göra
1. **Kör om metadatasteget på en befintlig session** (en mapp som redan
   kördes igenom pipelinen innan denna fas): tryck "Kör om" på
   "Skriv metadata"-steget, eller radera `metadata_written.json` i
   outputmappen och kör om. Eftersom markören nu kräver `"version": 2`
   körs steget om automatiskt ändå — DNG-filer och NEF (som XMP-sidecar)
   ska nu få adress/GPS/IPTC.
2. **Kontrollera att symlänkar är intakta efter körningen** (inga NEF ska
   ha blivit ersatta av kopior):
   `find <outputmapp> -type l | wc -l`
   Jämför gärna antalet symlänkar före/efter — det ska vara oförändrat
   (eller högre om nya foton tillkommit), aldrig lägre, och inga `.NEF`-
   filer i `<adress> ÖVRIGA` ska ha blivit vanliga filer:
   `find <outputmapp> -name "*.NEF" ! -type l`  (ska ge tom output)
3. Kontrollera att varje NEF i en adressmapp har fått en `<basnamn>.xmp`
   bredvid sig i `<adress> ÖVRIGA`, med rätt adress/GPS (öppna med
   `exiftool -G1 -a <fil>.xmp` eller i Lightroom/Bridge).
4. Testa HDR-sammanslagning på en maskin utan OpenCV installerat och
   verifiera att felmeddelandet är tydligt ("installera med: pip3 install
   opencv-python numpy") i stället för ett kryptiskt process-fel.
5. Öppna Console.app, filtrera på subsystem `com.photoflow.app`, och
   verifiera att loggrader för pipeline-steg syns med rätt kategori.
6. Kontrollera att `~/Library/Logs/PhotoFlow/photoflow.log` skapas och
   växer under en körning (den gamla `~/Desktop/photoflow.log` skapas inte
   längre av nya körningar).

### Kvarstående / inte gjort i Fas 1a
- `PipelineRunner.pipelineLog`/`logDecision`s per-rad-formatters (se
  "Beslut" ovan) — kosmetisk prestandastädning, ingen datapåverkan.
- Bracket-inställningarnas python-wiring har ingen Swift-enhetstest, bara
  manuell verifiering av det extraherade python-skriptet (se "Beslut"
  ovan) — ett riktigt test hade krävt att mocka `runProcess`/`Process`,
  vilket bedömdes vara för stort ingrepp för denna fas.

## Fas 1b – Tillstånd, avbrytning och bevakning

Utfört autonomt på branchen `forbattringar` medan användaren sov, en punkt i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik (en commit per punkt nedan). 60 tester totalt
efter denna fas, alla gröna.

### 0. exiftool-argument: fel GPS-taggar för NEF, dubblerade nyckelord
Verifierat med exiftool 13.50 via kommandoradsexperiment i scratchpad innan
fix (se commit för de exakta kommandona):

- `XMP:GPSLatitudeRef`/`XMP:GPSLongitudeRef` finns inte som skrivbara taggar
  ("doesn't exist or isn't writable" — bekräftat). `exiftoolArguments`
  skriver nu i stället ett signerat värde direkt på
  `XMP:GPSLatitude`/`XMP:GPSLongitude`, t.ex. `-XMP:GPSLatitude=59.33 N` —
  verifierat att exiftool tolkar detta korrekt (läses tillbaka som rätt
  gradminutsekund + väderstreck). Icke-NEF-filer (DNG/preview/HDR) var
  redan korrekta (de har riktiga `GPSLatitudeRef`/`GPSLongitudeRef`-taggar)
  och rördes inte.
- `Keywords+=`/`Subject+=` dubblerade nyckelordet varje gång
  metadatasteget kördes om (verifierat: två körningar gav `"tagA, tagA"`).
  Använder nu exiftools `-=tag` följt av `+=tag`-idiom (både
  `IPTC:Keywords` och `XMP:Subject`), som är dedupe-säkert vid upprepade
  körningar.

### 1. Gallringsbeslut fanns i två separata kopior
`BracketGroup` hade en egen `[PhotoItem]`-kopia (`photos`), skild från
`PipelineState.allPhotos`. `BracketReviewView` ändrade bara gruppens kopia,
`PreviewCullView` bara `allPhotos`, `deleteRejectedFiles` läste bara
`allPhotos`, och `saveCullDecisions` fick manuellt slå ihop båda — två
sanningar som kunde gå isär (ett beslut satt i ena vyn syntes inte
garanterat i den andra, eller föll bort helt vid save/load).

- `BracketGroup` lagrar nu bara `photoIDs: [String]`, aldrig egna
  `PhotoItem`-kopior.
- Ny `PipelineState`-API: `photos(in:)` löser upp en grupps foton från
  `allPhotos` via ett O(1) id→index-register (byggs om i `allPhotos`s
  `didSet`), plus `setDecision(photoID:accepted:rejected:)`,
  `setAlgorithmSuggested(photoID:suggested:)`, `selectedCount(in:)`,
  `allReviewed(_:)`, `label(for:)` — ersätter de gamla
  `BracketGroup`-beräknade egenskaperna.
- `PipelineRunner` (`loadBracketGroups`, `exportToAddressFolders`,
  `reMergeHDR`, `sendToLightroom`) och `BracketReviewView` uppdaterade till
  den nya API:n. `DashboardView.clearAllReviewData` behöver bara nollställa
  `allPhotos` nu (ingen andra kopia att synka).
- `saveCullDecisions` läser bara `allPhotos` (den enda sanningen).

### 2. Avbryt/Pausa gjorde ingenting på riktigt
`cancel()` terminerade bara den enskilda `Process` som råkade köra just då,
och `startPipeline` fortsatte oavbrutet till nästa steg. Paus kontrollerades
dessutom bara inuti HDR-loopen.

- `PipelineRunner` äger nu pipelinens `Task` (`pipelineTask`) via en ny
  `func start(inputDir:outputDir:)` — `RunnerWrapper.start`
  (`ContentView.swift`) delegerar till den i stället för att skapa en egen,
  ospårbar `Task`. `cancel()` anropar `pipelineTask?.cancel()`.
- `runProcess` ombyggd med `withTaskCancellationHandler` + en ny
  `ProcessCancellationBox`: när `Task` cancelleras terminerar den processen
  som körs (eller vägrar starta nästa om den redan cancellerats innan den
  hunnit skapas), och kastar `CancellationError`.
- `Task.checkCancellation()` + `waitIfPaused()` (paus-loopen bryter nu även
  vid cancellering, i stället för att snurra för evigt om man avbryter
  medan pausad) mellan varje steg i `startPipeline`, samt inuti
  DNG-chunk-loopen, exiftool-chunk-loopen (`writeIPTCMetadata`),
  HDR-loopen och symlink-sorteringsloopen (var 50:e fil i
  `exportToAddressFolders`).
- Vid avbrott: aktiva steg markeras `.idle` med loggraden "Avbrutet",
  `isRunning`/`isPaused` nollställs, inga "klar"-ljud spelas.

### 3. Bevakningen kände bara igen filer på namn
`WatchService.processedFiles` var en `Set<String>` av `lastPathComponent`.
En Nikon som formaterats om (eller ett återanvänt kort) börjar om på
DSC_0001 — samma namn som en redan bearbetad bild men helt annat innehåll —
så nya bilder ignorerades tyst för alltid.

- Filer identifieras nu via `WatchService.fileKey(for:)`
  (`"filnamn|storlek|mtime"`, via `URLResourceValues` — inget EXIF-läsning
  behövs).
- Redan hanterade nycklar persisteras per källmapp i
  `~/Library/Application Support/PhotoFlow/processed_files.json` (ny
  `ProcessedFilesStore`-klass, begränsad till senaste 50 000 posterna
  totalt), så att en omstart av appen inte glömmer och triggar om ett helt
  redan hanterat kort.
- `AppSettings.sdCardSearchPaths` exkluderade bara volymen med namnet
  "Macintosh HD" (trasigt för en annorlunda namngiven bootvolym eller andra
  icke-kort-diskar under `/Volumes`). Filtrerar nu på riktiga
  volymegenskaper: utesluter root-filsystemet (`volumeIsRootFileSystem`)
  och kräver att volymen är removable/ejectable OCH har en DCIM-mapp
  (`AppSettings.isCandidateSDCardVolume(...)`).

### 4. Manuellt rättade koordinater sparades inte
`correctAddress` lagrade den rättade koordinaten bara i minnet
(`correctedCoordinates`), och `saveCalendarMatches` skrev bara adressfältet
till `calendar_matches.json`. Vid omladdning (`matchCalendarBookings`
skip-grenen) geokodades adressen alltså på nytt — och eftersom rättelsen
görs just för att den automatiska geokodningen blev fel, kastades
korrigeringen bort och samma fel-GPS kom tillbaka.
`exportToAddressFolders`/`writeIPTCMetadata` geokodade dessutom alltid på
nytt själva och brydde sig aldrig om `correctedCoordinates`.

- `saveCalendarMatches` skriver nu `"latitude"`/`"longitude"`/
  `"corrected": true` per post när en rättning finns för adressen.
- `matchCalendarBookings` skip-grenen läser tillbaka de fälten: rättade
  poster fyller `correctedCoordinates`/`allMatchedAddresses` direkt och
  geokodas aldrig om.
- `exportToAddressFolders` och `writeIPTCMetadata` kollar
  `state.correctedCoordinates[adress]` först och använder den koordinaten
  i stället för att geokoda på nytt.
- `correctAddress` tar nu bort en redan skriven `metadata_written.json` (om
  den finns) och loggar det, så `writeIPTCMetadata` körs om nästa gång i
  stället för att låta fel-GPS/adress stå kvar permanent i redan taggade
  filer.

### Beslut/avgränsningar i denna fas
- Punkt 4: `calendarMappings` (den privata listan i `PipelineRunner` som
  styr adressmappnamn och foto-till-bokning-matchning) uppdateras inte
  förrän kalenderstegets skip-gren läser om `calendar_matches.json` — en
  adressrättning under samma session ändrar alltså GPS direkt men
  mappnamnet uppdateras först vid nästa "kör om"/omstart av kalenderteget.
  Detta gäller adress-**texten** (mappnamnet), inte koordinaten som denna
  punkt handlar om, och bedömdes vara utanför scope (en större
  om-sortering av redan placerade filer mitt i en session).
- `matchCalendarBookings`s skip-grens geokodnings-hoppa-över-logik (punkt
  4) och `exportToAddressFolders`/`writeIPTCMetadata`s
  `correctedCoordinates`-användning har ingen direkt Swift-enhetstest på
  `PipelineRunner`-nivå — de kräver kalenderåtkomst/riktig geokodning för
  att köra. Verifierat i stället genom `PipelineStateAddressCorrectionTests`
  (persistensen i `PipelineState`, som är den delade sanningskällan båda
  kodvägarna läser) samt manuell kodgranskning av de nya grenarna.
- Ingen ny inställning lades till för någon av punkterna — alla fyra är
  buggfixar av avsett/redan existerande beteende (gallringsbeslut ska vara
  konsekventa, avbryt ska avbryta, bevakning ska inte tappa filer, en
  rättning ska hålla i sig), inte nya valfria funktioner som ändrar
  pipelinens beteende.

### Manuell testning användaren bör göra
1. **exiftool-GPS på NEF-sidecar**: kör metadatasteget på en session med
   GPS, öppna en `.xmp`-sidecar i `<adress> ÖVRIGA` med
   `exiftool -G1 -a <fil>.xmp` och kontrollera att GPS-latitud/longitud
   visas med rätt väderstreck (inga varningar om saknade Ref-taggar i
   loggen).
2. **Nyckelordsdubbletter**: kör AI-taggning + metadatasteget två gånger på
   samma session och kontrollera med
   `exiftool -IPTC:Keywords -XMP:Subject <fil>` att taggarna inte
   dubbleras.
3. **Gallring i båda vyerna**: acceptera/avvisa några bilder i
   bracket-granskningen, gå vidare till gallringsvyn och kontrollera att
   samma bilder redan är markerade där (och tvärtom).
4. **Avbryt mitt i en körning**: starta pipelinen på en större mapp, tryck
   "Avbryt" medan DNG-konvertering eller metadataskrivning pågår.
   Kontrollera att processen (`ps aux | grep -i "dng converter\|exiftool"`)
   faktiskt dör, att steget visar "Avbrutet" i loggen, och att inget
   klart-ljud spelas.
5. **Pausa/återuppta**: samma sak med "Pausa" — kontrollera att
   framstegsindikatorn fryser och att "Fortsätt" faktiskt fortsätter
   arbetet (inte bara händelsevis råkar se ut så).
6. **Bevakning med återanvänt SD-kort**: bearbeta ett kort, formatera om
   det (eller kopiera samma bilder till en tom mapp med samma filnamn men
   annat innehåll), koppla in igen och verifiera att bevakningen upptäcker
   det som nya filer. Kontrollera
   `~/Library/Application Support/PhotoFlow/processed_files.json` växer.
7. **Bevakning överlever omstart**: bearbeta ett kort, stäng appen helt,
   starta om den och koppla in samma (oförändrade) kort igen — det ska
   INTE trigga om bearbetning av samma bilder.
8. **SD-kortsfilter**: kontrollera att en icke-kort extern disk (t.ex. en
   vanlig USB-hårddisk utan DCIM-mapp) inte dyker upp i
   bevaknings-loggen som en kandidat.
9. **Adressrättning**: kör kalendermatchning, rätta en felaktig adress i
   adressbanderollen, kör om (eller starta om appen och ladda samma
   session), och kontrollera att den rättade GPS-positionen används i
   `<adress>`-mappens filer (inte den ursprungliga felaktiga geokodningen).
   Om metadata redan hunnit skrivas innan rättningen, kontrollera i loggen
   att `metadata_written.json` togs bort och att steget körs om.

### Kvarstående / inte gjort i Fas 1b
- Se "Beslut/avgränsningar" ovan för punkt 4:s begränsning kring
  `calendarMappings`/mappnamn inom samma session.
- Ingen direkt `PipelineRunner`-nivå-test för avbryt/pausa (kräver att
  mocka `Process`/externa verktyg som `Adobe DNG Converter`/`exiftool`,
  vilket bedömdes vara för stort ingrepp) — verifierat i stället med
  `ProcessCancellationBoxTests` (den isolerade cancellation-bryggan) och
  manuell testning (se ovan).

## Fas 2a – Swift i stället för Python

Utfört autonomt på branchen `forbattringar` medan användaren sov, en punkt i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik. 66 tester totalt efter denna fas, alla gröna.

Mål: ersätta `PipelineRunner.runBracketAnalysis`s kedja
exiftool → CSV → inbäddat Python-skript → `bracket_groups.json` → inbäddat
Python-skript (symlänkar) med ren Swift, utan att ändra
`bracket_groups.json`-formatet (gamla sessioner ska fortsätta fungera
oförändrat).

### 1. `Services/ExifReader.swift` — EXIF via ImageIO, med en dokumenterad reservlösning

Läser EXIF från NEF via `CGImageSourceCopyPropertiesAtIndex`
(`kCGImagePropertyExifDictionary`/`kCGImagePropertyTIFFDictionary`),
parallelliserat med en `TaskGroup` (max 8 samtidiga läsningar).

**Verifierat mot riktiga NEF-kopior i scratchpad** (142 bilder från en
riktig bracket-session, två kameramodeller): FNumber, ISO,
DateTimeOriginal, SubSecTimeOriginal och TIFF-orientering matchade
exiftool exakt på alla 142 filer. **ExposureTime gjorde det inte** — 17 av
142 filer (12 %) med sann exponeringstid i intervallet 0.3–0.4s (t.ex.
råvärdet 10/25 = 0.4s, verifierat med `exiftool -v3` mot den råa EXIF-
rationalen) lästes fel av `kCGImagePropertyExifExposureTime` som exakt
1/3 s (0.3333...) — en skillnad på ~0.3–0.4 EV, stor nog att ändra
bracket-klassificeringen (unika EV-nivåer, HDR-delmängd). ExposureTime
faller därför tillbaka till ett enda batchat
`exiftool -csv -FileName -ExposureTime -@ -`-anrop (samma stdin-teknik
som resten av pipelinen); alla andra fält läses via ImageIO. Dokumenterat
i doc-kommentaren på `ExifReader`.

### 2. `Services/BracketAnalyzer.swift` — ren Swift-port av algoritmen

Portar fas 1 (tid + samma bländare/ISO), fas 2 (dela vid glapp >6s,
upptäck upprepade 3/4/5-mönster) och fas 3 (klassificering, unika EV
kvantiserat till 1/3, exponeringsintervall >2.0, `find_best_hdr_subset`
inkl. att hoppa över mörkaste exponeringen om >2.5 EV under median) rakt
av från den inbäddade Python-strängen. Output är Codable-modeller
(`BracketAnalysisOutput`/`BracketGroupResult`) med exakt samma nycklar
`bracket_groups.json` alltid haft.

**Paritetstester** (`BracketAnalyzerParityTests`, 4 fixturer i
`Tests/Fixtures/BracketAnalysis/`): enkla singlar, 3-bracket med subsec i
1/2/3 siffror, 5-bracket där mörkaste exponeringen ska hoppas över, och
två 3-brackets direkt efter varandra plus ett internt glapp >6s som delar
en grupp. Facit genererades genom att extrahera Python-skriptet ordagrant
till en scratchpad-tempfil och köra det på samma CSV:er.

**Körde även jämförelsen mot riktig `exif_data.csv`** från två tidigare
testsessioner (`ptohotagraphy-test/Exempelgatan 7`: 142 bilder, 32 grupper;
`lint/INPUT`: 2117 bilder, 509 grupper) — körde det extraherade
Python-skriptet och den nya Swift-koden på exakt samma indata (samma CSV,
inte via ImageIO) och diffade JSON-utdatan fält för fält. Hittade en
skillnad: **Pythons `round()` använder round-half-to-even (banker's
rounding), Swifts `.rounded()` round-half-away-from-zero.** 29 av ~2250
grupper i lint/INPUT-sessionen låg exakt på en `.x5`-gräns för
`exposure_range_stops` och rundades olika (`X.2` i Python, `X.3` i Swift).
Fixat med `.rounded(.toNearestOrEven)` för både `exposure_range_stops` och
den kvantiserade unika EV-mängden. Efter fixen: **0 skillnader på båda
riktiga sessionerna** (bit-för-bit identisk JSON, bortsett från
nyckelordning som JSON inte definierar semantik för).

### 3. Inkopplat i pipelinen, Python borttaget

`runBracketAnalysis` använder nu `ExifReader` + `BracketAnalyzer` och
skriver `bracket_groups.json` via `JSONEncoder`. `exif_data.csv` skrivs
fortfarande (för felsökning, genererad direkt från de inlästa
`ExifRecord`) men har färre kolumner än förut
(`ExposureCompensation`/`ShutterCount` togs bort — de lästes aldrig av
algoritmen) och läses inte längre tillbaka av något.

`organizeGroupsPython` ersatt av `PipelineRunner.organizeGroupsIntoFolders`
(FileManager-symlänkar, samma mappnamn `bracket_NNN_HDR_Nexp`/
`single_NNN_Nimg`). **Fixar en bugg på samma gång**: Python-versionen
byggde NEF-källvägar som `source_dir/filnamn` (`os.path.join`), vilket tyst
gav ingen symlänk alls för NEF-filer i undermappar under indatamappen —
en riktig layout (SD-kort monterar t.ex. `101NCZ_8/DSC_1807.NEF`, sett i
en av testsessionerna ovan). Den nya versionen återanvänder samma
rekursiva filnamn→URL-lookup som `loadBracketGroups` redan byggde, så
undermappar fungerar. Testat både i `BracketOrganizeFoldersTests` och
end-to-end mot 6 riktiga NEF-kopior (ExifReader → BracketAnalyzer →
organizeGroupsIntoFolders producerade rätt gruppindelning — en 5-bilders
bracket + en ensam bild, pga ett verkligt glapp på 7s — med riktiga
symlänkar).

Borttaget: `bracketAnalysisPython()`, `organizeGroupsPython()`,
`ToolLocator.python3ForAnalysis`, samt DependencyManager-raden för det
obligatoriska "python3"-verktyget (bara bracket-analysen behövde den rena
python3-installationen). Python + OpenCV för Mertens HDR-sammanslagning
finns kvar oförändrat (valfritt verktyg, `python3WithOpenCV`).

### 4. Förhandsbilder — undersökt, INTE bytt

`runPreviewGeneration` använder fortfarande `exiftool -b -JpgFromRaw -W`.
Undersökte om `CGImageSourceCreateThumbnailAtIndex` med
`kCGImageSourceCreateThumbnailFromImageIfAbsent` +
`kCGImageSourceThumbnailMaxPixelSize: 10000` +
`kCGImageSourceCreateThumbnailWithTransform: true` kunde ersätta det, mätt
på 21 kopierade NEF (två kameramodeller, både liggande och stående bilder):

- **Upplösning**: matchade exiftools `JpgFromRaw` exakt i pixelantal för
  båda kameramodellerna (t.ex. 8256×5504 respektive 5152×3432 — det
  senare är kamerans faktiska inbäddade preview-storlek, INTE
  sensorupplösningen som `kCGImagePropertyPixelWidth/Height` rapporterar,
  vilket första mätomgången missade). För roterade bilder
  (TIFF-orientering 8) transponerar `withTransform: true` bredd/höjd
  (5504×8256 i stället för exiftools oroterade 8256×5504) — samma antal
  pixlar, bara redan upprätad i stället för att förlita sig på att
  visningsprogrammet respekterar orienteringstaggen.
- **Hastighet**: exiftool extraherar alla 21 förhandsbilder i **ett**
  batch-anrop (`-@ -`, rena byte-kopior, ingen avkodning) på **0.29s**
  totalt. ImageIO, parallelliserat med en `TaskGroup` (max 8 samtidiga,
  samma mönster som `ExifReader`), tog **0.70s** totalt — cirka **2.4x
  långsammare**, och roterade bilder var ~3x långsammare än oroterade
  inom ImageIO-mätningen själv (transformen tvingar fram en fullständig
  JPEG-avkodning+rotation+omkodning, en ren bytekopia räcker inte).
  Extrapolerat till en riktig fastighetsfotografering (300–1000+ bilder,
  ofta en stor andel stående) skulle det bli flera extra sekunders väntan
  jämfört med idag.

**Beslut**: behåller exiftool. Kriteriet i uppgiften ("byt bara om inte
märkbart långsammare") är inte uppfyllt — 2.4x långsammare för det här
steget räknas som märkbart för en pipeline som redan kör många steg i
sekvens. Ingen kodändring gjord för denna punkt.

### 5. exiftool `-stay_open` för metadataskrivning — hoppat över

Valfri punkt enligt uppgiften ("gör bara detta om du kan få det robust").
`writeIPTCMetadata` kör idag ett nytt `exiftool`-anrop per chunk om 100
filer (rimligt redan — inte per-fil), och att bygga en robust
`-stay_open`-actor (hantera timeouts per kommando, tolka `{readyN}`-
markörer tillförlitligt även om ett kommando kraschar exiftool-processen,
och stänga ner ordentligt vid `cancel()`/Task-cancellation utan att
läcka en hängande process) är ett större och mer riskfyllt ingrepp än vad
som är motiverat av vinsten (processtart-overhead för `exiftool` är i
storleksordningen millisekunder, och stegets flaskhals är ändå IPTC-
skrivning per fil, inte processstart). Skippat enligt uppgiftens egen
öppning för detta. Ingen kodändring gjord.

### Manuell testning användaren bör göra

1. **Kör bracket-analysen på en riktig SD-kortsmapp** och jämför resultatet
   (antal grupper, vilka som blir HDR/single, `suggested_hdr_indices`) mot
   vad du minns/förväntar dig från tidigare körningar med samma bilder.
2. **Kontrollera `bracket_groups/`-mappen**: rätt mappnamn
   (`bracket_NNN_HDR_Nexp`/`single_NNN_Nimg`), symlänkar till både NEF och
   (om DNG redan konverterats) DNG, inga trasiga länkar
   (`find <outputmapp>/bracket_groups -type l ! -exec test -e {} \; -print`
   ska ge tom output).
3. **Om dina NEF-filer ligger i undermappar** under indatamappen (t.ex.
   flera SD-kort-mappar i en batch-import): kontrollera att de FÅR
   symlänkar i `bracket_groups/` nu (den gamla Python-versionen gav tyst
   inga symlänkar alls för det fallet).
4. **En bracket med en exponering runt 0.3–0.4s** (t.ex. en HDR-serie där
   en av bilderna har exakt den exponeringstiden): kontrollera i
   `bracket_groups.json` att `exposures`-fältet visar rätt värde (inte
   "1/3") — annars är det ett tecken på att ImageIO-reservlösningen för
   ExposureTime inte fungerade som väntat på just den filen/kameran.
5. Kör om en befintlig session vars `bracket_groups.json` skrevs av den
   GAMLA Python-koden — skip-kontrollen (matchande `total_images` +
   `params`) ska känna igen den och hoppa över, precis som förut.

### Kvarstående / inte gjort i Fas 2a
- Punkt 4 (förhandsbilder) och punkt 5 (exiftool `-stay_open`): undersökta
  och avsiktligt inte implementerade, se ovan för mätningar/motivering.
- `exif_data.csv` har färre kolumner än den gamla filen
  (`ExposureCompensation`/`ShutterCount` borttagna) eftersom inget läste
  dem — om du vill ha dem tillbaka för manuell felsökning är det en liten
  utökning av `ExifReader`/`writeExifDebugCSV`.
- Ingen ny inställning lades till — bracket-parametrarna
  (`maxTimeGap`/`minBracketSize`) styrs fortfarande av samma
  `AppSettings` som förut, bara motorn under huven bytt ut.

## Fas 2b – Struktur och Swift 6

Utfört autonomt på branchen `forbattringar` medan användaren sov, ett steg i
taget med bygge + tester gröna före varje commit. Ren strukturell/verktygs-
uppgradering — **ingen avsiktlig beteendeändring**. Se `git log --oneline`
för commit-för-commit-historik. Alla 66 tester fortfarande gröna.

### 1. `PipelineRunner.swift` (~2460 rader) uppdelad i `Services/Pipeline/`

Delades upp i en klass + 10 `extension PipelineRunner`-filer per
ansvarsområde, plus en fristående hjälpfil:

```
Services/Pipeline/
  PipelineRunner.swift          klass, lagrade egenskaper, init,
                                 start/startPipeline, cancel/togglePause,
                                 rerunStep, pipelineLog/logDecision,
                                 cancellation-hjälpare, findNEFFiles/findFiles,
                                 PipelineError
  PipelineRunner+DNG.swift        runDNGConversion
  PipelineRunner+Brackets.swift   runBracketAnalysis, writeExifDebugCSV
  PipelineRunner+Calendar.swift   matchCalendarBookings
  PipelineRunner+SortFolders.swift  exportToAddressFolders,
                                     deleteRejectedFiles,
                                     organizeGroupsIntoFolders
  PipelineRunner+Metadata.swift   exiftoolArguments, writeIPTCMetadata,
                                   IPTCFileMetadata
  PipelineRunner+Previews.swift   runPreviewGeneration
  PipelineRunner+AITagging.swift  runAITagging
  PipelineRunner+HDR.swift        runHDRMerge, reMergeHDR, mertensFusionPython
  PipelineRunner+Lightroom.swift  sendToLightroom, waitForLightroomCompletion
  PipelineRunner+LoadSession.swift  loadExistingSession, loadBracketGroups
  ProcessRunner.swift             runProcess, ProcessCancellationBox
```

Verifierat rent mekaniskt (ingen logikändring): en sorterad content-diff
mellan den gamla filen och alla nya filer sammanslagna visade bara två typer
av skillnader — `private` → internal (utan modifierare) på det som nu
korsar filgränser, och ett par nya förklarande kommentarer.

Lagrade egenskaper (`state`, `audio`, `currentTask`, `pipelineLogHandle`,
`pipelineTask`, `calendarMappings`, `aiTagResults`) måste ligga kvar i
huvudklassen — extensions kan inte ha lagrade instansegenskaper — och är nu
`internal` i stället för `private` eftersom extension-filerna i andra filer
behöver komma åt dem. Funktioner som bara anropas inom sin egen nya fil
(`waitForLightroomCompletion`, `mertensFusionPython`) förblev `private`.

`project.yml`s `sources: [Sources]` täcker redan undermappar rekursivt, så
ingen ändring behövdes där — bara `xcodegen generate` för att plocka upp de
nya filerna.

**Inte gjort**: `Views/StepCardView.swift` (482 rader, 2 top-level-typer) och
`Views/SettingsView.swift` (460 rader, 9 top-level-typer) delades **inte**
upp — uppgiften märkte detta som valfritt ("bara om enkelt"), och båda
filerna är redan under 500 rader (långt under `PipelineRunner`s ~2460), så
vinsten bedömdes vara liten jämfört med den obligatoriska Swift 6-
migreringen nedan.

### 2. Swift 6-språkläge

`SWIFT_VERSION` satt till `"6.0"` i `project.yml` (`settings.base`, gäller
både `PhotoFlow`- och `PhotoFlowTests`-targeten).

En fullt manuell migrering (annotera vart och ett av de ~10
`ObservableObject`-singlarna — `AppSettings`, `AudioService`,
`CalendarService`, `DependencyManager`, `PipelineState`, `WatchService`
m.fl. — plus alla deras anropsställen) gav vid ett första försök en lång
svans av mekaniska "is not concurrency-safe"-fel utan verkligt värde:
PhotoFlow är i praktiken ett helt UI-drivet enfönsterverktyg där i princip
allt redan konceptuellt hör hemma på huvudtråden. Uppgiften öppnade
uttryckligen för detta scenario, så i stället användes Xcode 27:s
"default actor isolation"-inställningar:

```yaml
SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
SWIFT_APPROACHABLE_CONCURRENCY: YES
```

Verifierat innan användning att båda finns i denna toolchains `Swift.xcspec`
(`grep -rl SWIFT_DEFAULT_ACTOR_ISOLATION` i
`XCBBuildService.bundle/.../Swift.xcspec`, som listar `nonisolated`/
`MainActor` som giltiga värden och mappar `MainActor` till kompilatorflaggan
`-default-isolation=MainActor`) och att `swiftc -swift-version 6
-default-isolation MainActor` faktiskt accepteras av toolchainen.

Detta reducerade felen från en bred klass av fel över hela modulen till 6
konkreta ställen — kod som **medvetet** körs utanför huvudtråden och som
annars tyst skulle ha dragits tillbaka dit av default-isoleringen (vilket
hade varit en riktig beteendeändring, t.ex. bildavkodning på huvudtråden).
Dessa fick riktiga fixar, inte mekaniska:

- **`ExifReader`** (enum, helt rent/stateless): märkt `nonisolated` — läser
  EXIF parallellt över flera `Task`er i en `TaskGroup` för prestanda vid
  hundratals bilder.
- **`ImageLoader`** i `Views/LocalImageView.swift` (enum, rent/stateless):
  märkt `nonisolated` — RAW/JPEG-avkodning anropas medvetet från
  `DispatchQueue.global` för att inte blockera huvudtråden/UI:t.
- **`ToolLocator`** (enum): märkt `nonisolated` — anropas både från
  `@MainActor`-kod (`PipelineRunner`) och från `DependencyManager`s
  `Task.detached`-bakgrundskontroller. Dess memoiseringscache
  `cachedPython3WithOpenCV` märkt `nonisolated(unsafe)` med kommentar (en
  idempotent cache — en race innebär bara att två anropare båda startar
  python3 och räknar fram samma resultat, exakt vad som redan kunde hända
  ofarligt före Swift 6).
- **`ProcessCancellationBox`** (`ProcessRunner.swift`): märkt `nonisolated`
  — den är redan `@unchecked Sendable` och skyddad av en egen `NSLock`
  precis för att kunna anropas från vilken isoleringskontext som helst
  (bakgrundskön i `runProcess` + `withTaskCancellationHandler`s `onCancel`,
  som kan köra synkront på valfri tråd innan huvudoperationen ens startat).
- **`WatchService`**: `NSWorkspace`-notifikationscallbacken skickade en
  icke-`Sendable` `Notification` in i en `@MainActor`-`Task`. Fixat genom
  att plocka ut den (Sendable) `URL`:en i den icke-isolerade callbacken
  **innan** `Task`-hoppet, i stället för att fånga hela notifikationen.

Build grön i Swift 6-läge, inga fel eller nya varningar — bara de sedan
tidigare kända `CLGeocoder`/`placemark`-deprecationerna (se Fas 0, punkt 2;
rörs inte i denna fas). Alla 66 tester gröna, inklusive testmålet
`PhotoFlowTests` som verifierat bygger i Swift 6
(`EFFECTIVE_SWIFT_VERSION = 6` i `xcodebuild -showBuildSettings`).

### Manuell testning användaren bör göra
- Ingen — detta är en ren struktur-/verktygsuppgradering utan avsiktlig
  beteendeändring. Kör appen som vanligt; om något beter sig annorlunda är
  det en bugg i denna fas (jämför mot `git show <commit innan Fas 2b>` för
  att hitta rätt fil/rad).

### Kvarstående / inte gjort i Fas 2b
- `Views/StepCardView.swift`/`Views/SettingsView.swift` inte uppdelade, se
  motivering ovan under punkt 1.
- 0 varningar i egen kod uppnått, förutom de kända
  CLGeocoder/placemark-deprecationerna (åtgärdas i en senare fas, som
  tidigare faser också dokumenterat).

## Fas 3a – HDR på RAW-data

Utfört autonomt på branchen `forbattringar` medan användaren sov, ett steg i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik.

Mål: ersätta den gamla HDR-vägen (OpenCV/python3 `cv2.createMergeMertens` på
8-bitars **inbäddade JPEG-förhandsbilder** ur NEF, sparat som "16-bit TIFF"
men utan någon riktig RAW-dynamik) med riktig exposure fusion på RAW-data
(DNG/NEF) i ren Swift.

### 1–4. `Services/HDR/` — ny motor

- **`RAWRenderer.swift`**: renderar en DNG/NEF via `CIRAWFilter` till en
  RGBA float32-buffert. Verifierat i SDK:n (`CIRAWFilter.h`):
  `supportedDecoderVersions` är "sorted in increasingly newer order", så
  `.last` väljer alltid den nyaste decodern för filens bildtyp (RAW vs. DNG
  har separata versionslistor) — ingen hårdkodad versionssträng, plockar
  automatiskt upp macOS 27:s nya RAW-avkodare. Samma vitbalans (läst från
  mittexponeringen), `exposure=0`, `boostAmount=1`,
  `extendedDynamicRangeAmount=0` och lens correction (om filen stödjer det)
  sätts på alla bilder i en bracket för konsekvent avkodning.
  Renderas till `CIContext` med `extendedLinearSRGB` som working space och
  **sRGB** (inte scenlinjärt) som destination-färgrymd för `render(_:
  toBitmap:...)` — Mertens-vikterna (kontrast/mättnad/välexponering centrerad
  på 0.5) är definierade för display-referred bilder, precis som de gamla
  8-bitars JPEG-förhandsbilderna. `hdrMaxDimension` styr `CIRAWFilter.scaleFactor`
  (avkodaren gör mindre jobb direkt, inte en efterhandsskalning).
- **`ExposureFusion.swift`**: Mertens/Kautz/Van Reeth exposure fusion
  implementerad direkt (ingen OpenCV) — kontrast (`|Laplace|` av gråskala),
  mättnad (std över R/G/B), välexponering (produkt av Gaussianer centrerade
  på 0.5, σ=0.2), normaliserade vikter, Gaussisk vikt-pyramid + Laplace-
  bildpyramid (separabel 5-tap `[1,4,6,4,1]/16` via `vImageConvolve_PlanarF`,
  `kvImageEdgeExtend`), blandning per nivå, kollaps. Bearbetar en färgkanal i
  taget så bara en uppsättning Laplace-pyramider (inte alla tre) hålls i
  minnet samtidigt. Sex Swift Testing-tester (identiska/upprepade indata,
  välexponerad bild dominerar över utbränd, udda bildstorlekar 37×23, ren
  pyramid+kollaps återskapar bilden — algebraiskt garanterat, en bra
  sanity-check av reduce/expand oberoende av blandningslogiken).
- **`HDRAlignment.swift`**: justerar handhållna brackets. API-beslut
  (verifierat i SDK:n): macOS 26/27 Vision har både det nya Swift-API:t
  `TrackTranslationalImageRegistrationRequest` (byggt för att spåra
  *videoströmmar* bild-för-bild — `StatefulRequest`,
  `frameAnalysisSpacing: CMTime`) och det äldre
  `VNTranslationalImageRegistrationRequest`/`VNImageRequestHandler` (en
  enkel engångsförfrågan "justera flytande bild mot referensbild", verifierat
  i `VNImageRegistrationRequest.h`, inte avvecklad — bara ersatt för
  videofallet). En bracket är ett fåtal fristående stillbilder, så det äldre
  engångs-API:t användes. Körs på en nedskalad gråskalekopia (800px lång
  sida, `vImageScale_PlanarF`/`vImageConvert_PlanarFtoPlanar8`) mot
  mittexponeringen, resultatet skalas upp och appliceras med bilinjär
  interpolation direkt på den redan renderade full-upplösta bufferten
  (`RAWRenderer.shiftRGBA`) — enklare och mer korrekt än att gissa
  förskjutningen innan RAW-rendering och försöka bädda in den i
  `CIRAWFilter`s pipeline. Avstängningsbar via `hdrAlignEnabled`.
- **`HDRWriter.swift`**: skriver en riktig 16-bitars **RGB** (ingen
  onödig alfakanal) LZW-TIFF via `CGImageDestination` + en JPEG-förhandsbild
  (kvalitet 0.92, max 2400px, via `CIContext.writeJPEGRepresentation`).
  Kopierar EXIF (datum, kamera, bländare, ISO, brännvidd m.m.) från
  mittexponeringens RAW-fil med `exiftool -TagsFromFile` — enklare och mer
  robust än att bygga `CGImageDestination`-EXIF-dictionaries för hand, och
  konsekvent med hur resten av pipelinen redan skriver metadata.
  (Upptäckt under manuell verifiering: `CIContext.createCGImage` stödjer bara
  `.RGBA16`-formatet, dvs. med alfakanal — bytt till att bygga
  16-bitars-RGB-bufferten för hand direkt från float-pixlarna i stället.)
- **`HDREngine.swift`**: orkestrerar hela kedjan per bracket-grupp (läs
  vitbalans → rendera alla exponeringar → justera → fusionera → skriv).
  `nonisolated enum` — ett `await`-anrop från `PipelineRunner` (`@MainActor`
  under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`) hoppar automatiskt av
  huvudtråden för att köra en `nonisolated async`-funktion, så ingen manuell
  `Task.detached` behövs. Kontrollerar `Task.checkCancellation()` mellan varje
  bildrendering/justering och runt fusionen.

### 5. Inkoppling

Ny inställning i `AppSettings`: `hdrEngine` (`"coreImage"` standard /
`"opencv"`), `hdrMaxDimension` (standard 6000, `0` = full upplösning),
`hdrAlignEnabled` (standard på). Picker + förklarande text i
`SettingsView`s HDR-sektion. `BracketReviewView` visar nu rätt motornamn
("Exposure Fusion (Core Image RAW)" / "Mertens Exposure Fusion (OpenCV)")
i stället för det tidigare hårdkodade OpenCV-namnet.

`PipelineRunner+HDR.swift`: `runHDRMerge`/`reMergeHDR` väljer motor per
inställning. Core Image-vägen tar RAW-indata (DNG från `dng/`-staging,
NEF-fallback via samma rekursiva lookup som `loadBracketGroups` använder,
respektive `photo.dngURL`/`nefURL` i `reMergeHDR`) i stället för
preview-JPEG:ar. OpenCV-vägen är oförändrad och fungerar som förut (kräver
fortfarande `pip3 install opencv-python numpy`).

**Kända begränsningar i inkopplingen** (avsiktliga, dokumenterade i stället
för att över-engineera):
- Grupper körs strikt sekventiellt (samtidighet 1 — inom det efterfrågade
  intervallet 1–2). Minnestoppen för en enda grupp (se mätning nedan) gör
  parallella grupper riskabelt för minnet på en vanlig utvecklarmaskin.
- Paus (`isPaused`) kontrolleras mellan grupper, inte mitt i en enskild
  grupps sammanslagning — en paus tar alltså effekt först när den pågående
  gruppen är klar (kan ta upp till ~15–30s vid full upplösning). Avbrytning
  (`cancel()`) är däremot finkornig (kontrolleras mellan varje bild och runt
  fusionen inne i `HDREngine.merge`).
- Progress-callbacken i `HDREngine.merge` (0...1 per grupp) är inte
  kopplad till `PipelineState` — bara den befintliga grupp-nivå-progressen
  (som redan fanns i den gamla koden) uppdateras. Att koppla in den skulle
  kräva att hoppa tillbaka till `@MainActor` per delsteg (`Task { @MainActor
  in ... }`) för varje av de ~15 callbacken gör per grupp, vilket bedömdes
  vara mer risk (fler MainActor-hopp, mer kod) än värt för en detalj-progress
  inom en grupp som redan tar sekunder, inte minuter.

### 6. Mätning och visuell sanity-check

Kopierade en riktig 4-exponerings bracket-serie (Nikon Z8, ~45MP, f/11, ISO
320, exponeringar 0.6s/1/5s/0.6s/1.3s) från
`Exempelgatan 7/processed/dng/` + originalet `DSC_9402.NEF` till scratchpad
och körde `HDREngine.merge` fristående (kompilerad direkt med `swiftc` mot
`Services/HDR/*.swift`, utanför Xcode-projektet, se scratchpad-historiken för
den exakta kommandoraden) — testat med både DNG- och NEF-indata (båda
fungerar; NEF går via samma `CIRAWFilter`-väg som DNG).

- **Körtid**: 12.0s (`/usr/bin/time -l`) för 4 exponeringar vid
  `hdrMaxDimension=6000` (→ 4000×6000 utdata) med justering påslagen, på en
  Apple Silicon-Mac. Ett första körförsök vid samma inställningar tog
  påtagligt längre (avbröts efter ~6 minuter utan tydlig förklaring — troligen
  kall Metal-shader-cache för `CIContext`/`CIRAWFilter` första gången detta
  körs i processen; ett andra försök med identiska bilder och inställningar
  var klart på 12s). **Användaren bör notera detta**: om HDR-sammanslagningen
  känns ovanligt långsam på den *första* gruppen i en session men snabbar upp
  sig för resten, är det troligen samma engångs-uppvärmning, inte en bugg.
- **Minne**: 4.36 GB peak memory footprint / 4.80 GB maximum resident set
  size (`/usr/bin/time -l`) för samma körning (4×6000px-bilder hålls i minnet
  samtidigt som float32 RGBA + vikt-/Laplace-pyramider). Detta är
  anledningen till att grupper körs sekventiellt (se ovan) — flera samtidiga
  grupper vid `hdrMaxDimension=6000` skulle kunna pressa minnet hårt på en
  maskin med 8–16 GB RAM. Sänk `hdrMaxDimension` (t.ex. till 4000) om det blir
  ett problem i praktiken.
- **Visuell sanity-check**: JPEG-förhandsbilden för den fuserade bilden
  granskades visuellt (ett badrum, fönster med starkt motljus + mörka
  hörn) — väl avvägd exponering, inga utbrända höjdpunkter i fönsterpartiet,
  inga uppenbara spökartefakter (ghosting) trots att bracketen är handhållen.
  Kvantitativ jämförelse (egen liten ImageIO-baserad mätning, se
  scratchpad): den fuserade bildens medelljusstyrka (114) ligger mellan
  källbildernas (57–166), och andelen klippta högdagrar/skuggor i den
  fuserade bilden (0.72% / 0.52%) är **lägre** än i någon enskild
  källexponering (1.36–2.33% / 0.02–4.60%) — precis vad man förväntar sig av
  en fungerande exposure fusion: den återvinner detaljer från både skuggor
  och högdagrar i stället för att klippa dem.
- **Jämförelse mot OpenCV-motorn**: **inte möjlig i den här miljön** —
  `python3` här saknar `cv2`/`numpy` (`pip3 install opencv-python numpy` är
  inte installerat), så det gamla OpenCV-JPEG-baserade flödet kunde inte
  köras sida vid sida för en direkt bild-för-bild-jämförelse. Den nya motorns
  resultat bedömdes ändå vara korrekt baserat på ovanstående kvantitativa och
  visuella kontroller.

### Manuell testning användaren bör göra

1. **Jämför visuellt i appen**: kör samma bracket-serie genom pipelinen med
   `hdrEngine = coreImage` (standard) och sedan med `hdrEngine = opencv`
   (kräver `pip3 install opencv-python numpy`), och jämför resultaten i
   `BracketReviewView` — särskilt på svåra motiv (starkt fönsterljus, mörka
   hörn, blandad belysning). Den nya motorn bör bevara mer highlight-/
   skuggdetalj eftersom den arbetar på RAW-data i stället för 8-bitars
   JPEG-förhandsbilder.
2. **Handhållna brackets**: testa på en bracket som inte är stativfotograferad
   och kontrollera att `hdrAlignEnabled` faktiskt minskar spökartefakter
   jämfört med avstängt — leta efter dubbla konturer på kanter/text i
   resultatet.
3. **Minne på en riktig session**: kör en hel mapp med många bracket-grupper
   och håll ett öga på minnesanvändningen (Aktivitetsövervakaren) — sänk
   `hdrMaxDimension` om det blir problematiskt på din maskin.
4. **Kameramodeller**: testat här bara med Nikon Z8-DNG/NEF. Om andra
   kameramodeller/RAW-format används, verifiera att `CIRAWFilter` stödjer dem
   (`CIRAWFilter.supportedCameraModels`) och att resultatet ser rimligt ut.
5. **Avbrytning/paus** under en pågående HDR-sammanslagning — verifiera att
   avbryt stoppar inom rimlig tid (inom en bild/fusion-fas) och att paus tar
   effekt senast vid nästa grupp.

### Kvarstående / inte gjort i Fas 3a

- Ingen jämförelse mot OpenCV-motorn kunde köras i den här miljön (OpenCV
  saknas) — se punkt 6 ovan. Användaren bör göra den jämförelsen manuellt
  (se "Manuell testning", punkt 1).
- Progress-callbacken från `HDREngine.merge` är inte kopplad till
  `PipelineState` för finkornig UI-progress inom en grupp — se
  "Kända begränsningar" ovan.
- Paus tar effekt mellan grupper, inte mitt i en sammanslagning — se
  "Kända begränsningar" ovan.
- Ingen ny CLI/testtarget lades till i Xcode-projektet för RAW-baserade
  tester (`RAWRenderer.render`/`readWhiteBalance` kräver en riktig DNG/NEF,
  vilket testmålet inte har tillgång till) — verifierat manuellt i stället
  med kopierade testbilder i scratchpad (se punkt 6).

## Fas 3b – Vision-analys och beslutsstöd

Utfört autonomt på branchen `forbattringar` medan användaren sov, ett steg i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik.

Mål: modernisera Vision-användningen, lägga till Vision-baserat
kvalitetsbeslutsstöd (estetik, horisont, skärpa, dubbletter) i gallringen,
och återaktivera AI-taggningssteget som stod avstängt sedan tidigare.

### 1. Modernisering av `VisionTaggingService`

Verifierat i SDK:n (`grep` i
`Vision.framework/Modules/Vision.swiftmodule/*.swiftinterface`) att
`ClassifyImageRequest`, `CalculateImageAestheticsScoresRequest`,
`DetectHorizonRequest` och `GenerateImageFeaturePrintRequest` alla finns som
nya async Swift-API:er (macOS 15+, väl inom projektets macOS 26-mål).
`VisionTaggingService.tagPhoto` skrevs om från
`VNClassifyImageRequest`/`VNImageRequestHandler` (synkront, manuellt
GCD-dispatchat) till `try await ClassifyImageRequest().perform(on: url)` —
kortare kod, och `perform(on:)` är redan async/icke-blockerande så den
manuella `DispatchQueue.global()`-dispatchen och `loadCGImage`-hjälparen
kunde tas bort helt. Den svenska taggmappningstabellen (engelska
Vision-labels → svenska fastighetstermer) och all klassificeringslogik
lämnades oförändrad — den ersätts av Foundation Models i en senare fas,
inte den här.

### 2. Ny `Services/PhotoQualityService.swift`

Skriven som `nonisolated enum` (samma mönster som `HDREngine`/
`RAWRenderer`/`ExposureFusion`/`HDRAlignment`/`HDRWriter` från Fas 3a) i
stället för en `actor` som `VisionTaggingService` — ingen instansstatus att
skydda, och projektets `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` hade annars
tvingat `computeSharpness` (riktigt CPU-arbete: CGContext-ritning +
vImage-faltning) att seriealiseras på huvudtråden eller en enda
actor-executor i stället för att köra parallellt över TaskGroupens ~6
samtidiga jobb.

- **Estetik/kvalitet**: `CalculateImageAestheticsScoresRequest` →
  `overallScore` (Float, -1...1 enligt Apple — verifierat mot
  [createwithswift.com](https://www.createwithswift.com/scoring-the-aesthetics-of-an-image-with-the-vision-framework/)
  och Apples egen dokumentation) normaliseras till 0...1 för visning
  (`normalizedQualityScore`), plus `isUtility`.
- **Horisont**: `DetectHorizonRequest` → `HorizonObservation?` (nil om ingen
  horisontlinje kunde detekteras — vanligt för närbilder/interiörer, inte
  ett fel). `angle.converted(to: .radians).value` → `tiltDegrees(fromRadians:)`
  som konverterar till grader och viker in resultatet till (-90, 90] (en
  horisontlinje är oriktad — en 180°-rotation beskriver samma linje).
  Flaggas i UI när |vinkel| > 1.0°.
- **Skärpa**: egen metrik — varians av en 3×3 Laplace-faltning på en
  nedskalad (max 512px lång sida) gråskalebild, via
  `vImageConvert_Planar8toPlanarF` + `vImageConvolve_PlanarF` +
  `vDSP_meanv`/`vDSP_measqv` (verifierat mot en referensimplementation med
  manuell dubbel for-loop i kalibreringsskriptet — vImage-versionen matchade
  inom ~0.5%, skillnaden är bara kantutfyllnadens exakta hantering). Bara
  meningsfull relativt andra bilder i samma dubblettgrupp/session, inte som
  ett absolut mått.
- **Dubbletter/nästan-dubbletter**: `GenerateImageFeaturePrintRequest` +
  `distance(to:)`, klustrade med single-linkage (union-find) under ett
  tröskelvärde. Par inom samma HDR-bracket-grupp exkluderas alltid från
  klustring (de är avsiktligt olika exponeringar av samma motiv, inte
  oavsiktliga upprepningar, och hanteras redan av bracket-granskningen).
  **Kalibrering** (se punkt 5 nedan för fullständig data): ett första försök
  med tröskel 0.15 (baserat på enkla percentiler) visade sig i praktiken
  kedja ihop olika vykomponeringar i samma rum via single-linkage-klustringens
  kända "chaining"-problem — verifierat visuellt genom att läsa in JPEG-filer
  direkt och jämföra. Sänkt till **0.05** efter att ha jämfört
  klustringsresultat vid flera trösklar och granskat klustrens ändpunkter
  visuellt; vid 0.05 innehöll varje kluster uteslutande verifierat identiska
  kompositioner.
- **Orkestrering**: `analyzeSession()` kör en `TaskGroup` med max 6 samtidiga
  jobb (motsvarande `VisionTaggingService.tagPhotos`), rapporterar förlopp via
  en `@MainActor`-callback, och respekterar avbrytning
  (`Task.checkCancellation()` mellan varje slutfört jobb — strukturerad
  concurrency avbryter då automatiskt alla kvarvarande jobb i gruppen).
- **Persistens**: `photo_quality.json` i outputDir (Codable, versionerad via
  `PersistedFile.version`/`PhotoQualityService.currentVersion`) så analysen
  inte körs om i onödan — samma "hoppa över om redan sparat"-mönster som
  `ai_tags.json` sedan tidigare.

### 3. Datamodell + pipeline

`PhotoItem` fick fem nya fält: `qualityScore`, `isUtility`, `horizonAngle`,
`sharpness`, `duplicateGroupID` (valt i stället för en sidotabell i
`PipelineState` — minst ändring eftersom `PhotoItem` redan bär `aiTags`/
`aiDescription` från samma typ av Vision-analys).

`PipelineRunner.startPipeline`s TODO/avstängda AI-taggningsblock togs bort —
steget kördes tidigare **aldrig**, oavsett `AppSettings.aiTaggingEnabled`.
Steget körs nu och respekterar inställningen precis som de andra valfria
stegen (`findCalendarInfo`/`writeIPTCTags`/`createHDR`).
`DashboardStep.aiTagging`s undertext byttes till "Vision-analys" eftersom
steget nu gör mer än bara klassificering.

`PipelineRunner+AITagging.swift`s `runAITagging()` delades upp i
`runVisionTagging()` (den oförändrada AI-taggningslogiken) +
`runVisionQualityAnalysis()` (den nya kvalitetsanalysen), båda med samma
"hoppa över om redan sparat"-cache-mönster men separata JSON-filer
(`ai_tags.json` / `photo_quality.json`) så de kan cachas/köras om oberoende
av varandra. Bracket-gruppmedlemskap läses direkt från `bracket_groups.json`
(redan skrivet av det tidigare bracket-analyssteget) för att bygga
uteslutningslistan till dubblettklustringen.
`PipelineRunner+LoadSession.loadBracketGroups` laddar `photo_quality.json`
(i-minnet-först, disk-fallback — samma mönster som `aiTagResults`) och fyller
i `PhotoItem`s nya fält. `rerunStep(.aiTagging)` rensar nu både
`ai_tags.json` och `photo_quality.json`.

### 4. UI i gallringen (`PreviewCullView`)

- **Info-raden** visar kvalitetspoäng (⭐ 0.00–1.00) och varningschips:
  "Dubblett 2/3" (position/antal i dubblettgruppen), "Suddig?" (lägst
  skärpa i sin dubblettgrupp), "Skev horisont 2,3°" (>1° lutning, svensk
  decimalkomma), "Nyttobild" (Vision's `isUtility`).
- **Filmremsan** visar en liten ikon per dubblettgrupp (blå
  `square.on.square`) och för låg kvalitet (orange varningstriangel,
  tröskel 0.7 normaliserad — en grov, dokumenterad gissning baserad på den
  kalibrerade sessionens poängfördelning, inte lika hårt verifierad som
  dubblett-tröskeln).
- **`s` = "Föreslå gallring"**: `PhotoQualityService.suggestCulling()`
  markerar (sätter `rejected = true`, raderar aldrig direkt — radering sker
  som förut först i `finishCulling`) den sämsta bilden i varje
  dubblettgrupp (behåller den med högst kvalitet/skärpa) plus alla
  `isUtility`-bilder. Rör aldrig redan beslutade bilder. Visar en orange
  banner överst med hur många som föreslogs.
- **`z`** ångrar senaste `s`-omgång (enda-nivås undo-buffert med varje
  berörd bilds tidigare beslut).
- Beslut sparas fortfarande via `pipeline.saveCullDecisions()`, precis som
  manuell accept/reject.
- "Sortera efter kvalitet"/"Visa bara ogranskade" (steg 4:s valfria
  tilläggspunkt) gjordes **inte** — bedömdes som lägre prioritet än att få
  kärnfunktionerna (kalibrering, beslutsstöd, föreslå/ångra) rätt och väl
  testade inom den tillgängliga tiden.

### 5. Kalibrering och skarpt experiment mot en riktig session

Kopierade en riktig 142-bilders preview-session (`Exempelgatan 7/processed/
previews/`, Nikon Z8, 25 bracket-/singelgrupper) till scratchpad och körde ett
fristående Swift-skript (`swiftc` direkt mot Vision-ramverket, samma
metodik som HDREngine-testningen i Fas 3a) som beräknade riktiga
Vision-mätningar för alla 142 bilder.

**Dubblettkalibrering** (se punkt 2 ovan för själva beslutet): vid tröskel
0.05, exklusive par inom samma bracket-grupp, hittades **4 dubblettkluster**
om totalt **44/142 bilder (31%)**. Varje klusters ändpunkter granskades
visuellt (läste in JPEG-filerna direkt) — samtliga var bekräftat identiska
kompositioner som fotografen råkat bracketa två gånger i rad (t.ex.
`DSC_9440`/`DSC_9448`: pixel-för-pixel samma vy av ett elskåp, fotograferat
som två separata 4–5-exponeringars brackets). Vid tröskel 0.15 (det första,
icke-visuellt-verifierade försöket) kedjade single-linkage-klustringen ihop
**27 bilder** i ett enda kluster som vid granskning innehöll tydligt olika
vykomponeringar av samma vardagsrum — en viktig läxa: **percentilstatistik
över parvisa avstånd räcker inte för att kalibrera en tröskel som sedan
används med single-linkage-transitivitet; klustren måste också granskas
visuellt vid den valda tröskeln.**

**Horisont**: 12/142 bilder (8,5%) fick |lutning| > 1° — tre distinkta
grupper av bilder (samma rum fotograferat i en bracket-serie ger samma
lutning för alla exponeringar, som väntat): ~-1,0 till -1,13° (8 bilder),
-2,12° (1 bild), och 7,0–7,25° (3 bilder, den mest påtagligt skeva
gruppen).

**Estetik**: `overallScore` (rå Vision-skala -1...1) låg mellan 0,28 och
0,86 för hela sessionen (median 0,56) — aldrig negativt för dessa
fastighetsfoton, vilket är förväntat för välbelysta, komponerade bilder.

**Nyttobilder (`isUtility`)**: **48/142 (34%)** flaggades som nyttobilder av
Vision — **betydligt fler än väntat**, se "Manuell testning" nedan.

### Manuell testning användaren bör göra

1. **`isUtility`-andelen (34% i testsessionen) känns hög** för professionell
   fastighetsfotografering — Vision's estetikmodell är sannolikt tränad mest
   på personliga foton, där "nyttobild" betyder kvitton/skärmdumpar/dokument,
   och kan felaktigt klassificera enkla, symmetriska, jämnt belysta
   interiörbilder (precis vad bra fastighetsfoto ofta är!) som "nyttobilder".
   **Testa "Föreslå gallring" på en riktig session och kontrollera manuellt
   att den inte föreslår avvisning av fullt godkända rumsbilder** innan du
   litar på knappen rakt av. Om det visar sig vara ett systematiskt problem
   är den enklaste fixen att ta bort `isUtility`-villkoret ur
   `suggestCulling` (eller kräva `isUtility && qualityScore < X`) i en
   uppföljande fas.
2. **Dubblett-tröskeln (0.05) är kalibrerad mot en enda session** (142
   bilder, en fastighet, en fotograf). Testa på fler/olika sessioner
   (olika kameror, olika fotograferingsstilar) och granska filmremsans
   dubblett-ikoner — om tröskeln visar sig för sträng (missar riktiga
   dubbletter) eller för lös (kedjar ihop olika vyer igen), justera
   `PhotoQualityService.duplicateDistanceThreshold`.
3. **Låg-kvalitet-tröskeln i filmremsan (0.7 normaliserat)** är en grov
   gissning, inte lika hårt kalibrerad som dubblett-tröskeln — justera i
   `PreviewCullView.lowQualityThreshold` om den känns fel i praktiken.
4. **Prestanda på en stor session**: `analyzeSession` kör
   `CalculateImageAestheticsScoresRequest` + `DetectHorizonRequest` +
   `GenerateImageFeaturePrintRequest` + skärpeberäkning per bild, plus en
   O(n²) parvis dubblettklustring. 142 bilder tog ~21s i kalibreringsskriptet
   (fristående, ej i appen) — testa uppskalat på en session med flera hundra
   bilder och håll koll på att `.aiTagging`-steget fortfarande känns rimligt
   snabbt.
5. **Horisontflaggan** testades bara på en session utan extremt sneda
   bilder (max ~7°) — verifiera att riktigt sneda bilder (t.ex. handhållna
   externa/drönarbilder) ger rimliga gradvärden och inte falska nollor.

### Kvarstående / inte gjort i Fas 3b

- "Sortera efter kvalitet"/"Visa bara ogranskade"-filtret i gallringsvyn
  (valfri tilläggspunkt) gjordes inte — se punkt 4 ovan.
- Ingen ny inställning lades till för att stänga av enbart
  kvalitetsanalysen separat från AI-taggningen — den delar
  `AppSettings.aiTaggingEnabled` med taggningen (båda är del av samma
  `.aiTagging`-pipelinesteg, vilket redan var avstängningsbart).
- `isUtility`-andelen i kalibreringssessionen (34%) är hög nog att den bör
  ses som en öppen fråga, inte ett löst kalibreringsproblem — se "Manuell
  testning", punkt 1.
- Ingen jämförelse gjordes mot en andra riktig session (t.ex. någon av
  `lint/*/processed/previews/`-mapparna, som är betydligt större) på grund
  av tidsåtgången för Vision-analys av flera hundra/tusen bilder i den här
  miljön — kalibreringen vilar på en (visuellt väl verifierad) session.
