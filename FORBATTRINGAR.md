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

## Fas 3c – Tal, översättning och geokodning på enheten

Utfört autonomt på branchen `forbattringar` medan användaren sov, ett steg i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik. 108 tester totalt efter denna fas, alla gröna.

Mål: modernisera de tre sista stora deprecerade/tredjeparts-API:erna i
appen — Google Translate-anropet i `TranslationService`, `SFSpeechRecognizer`
i `DictationService`, och `CLGeocoder`/`MKMapItem.placemark` i
`CalendarService`/`AddressBanner` — samt en liten justering av
"Föreslå gallring" från Fas 3b.

### 0. "Föreslå gallring" föreslår bara dubbletter som standard

Fas 3b:s kalibrering visade att Vision flaggade **34 %** av en riktig
fastighetssession som `isUtility` — för högt för att automatiskt föreslå
gallring av dem. Ny inställning `AppSettings.cullSuggestUtility` (standard
**av**) styr om `s`-förslaget i `PreviewCullView` även tar med
`isUtility`-bilder. Dubbletter (behåll bästa i varje grupp) föreslås alltid,
oavsett inställningen.

`PhotoQualityService.suggestCulling` returnerar nu en `CullSuggestion`
(`duplicates`/`utility`, uppdelat) i stället för en platt `Set<String>`, så
bekräftelsebannern i gallringsvyn kan visa exakt vad som föreslogs
("Föreslog 3 bilder för gallring (3 dubbletter)" eller "... (2 dubbletter,
1 nyttobild)"). Ny toggle + förklarande text i `SettingsView`s
AI-taggning-sektion.

### 1. Översättning på enheten (`TranslationService`)

Ersätter POST till Googles inofficiella `translate.googleapis.com` med
Apples on-device Translation-ramverk. **Google-anropet är helt borttaget**
— ingen anteckningstext lämnar enheten längre, och inget tyst
fallback-till-Google om något går fel.

- `TranslationSession` skapas via SwiftUI-modifieraren
  `.translationTask(configuration:action:)` i `DictationPanelView` (den
  enda vägen som kan trigga en riktig modellnedladdning via systemets UI —
  verifierat i SDK:n att den bor i cross-import-overlayen
  `_Translation_SwiftUI`, som blir tillgänglig automatiskt när `Translation`
  och `SwiftUI` importeras i samma fil). `TranslationService` äger en
  `@Published TranslationSession.Configuration?` som modifieraren
  observerar; `translate(_:from:to:)` sätter/`invalidate()`:ar
  configurationen och väntar på en `CheckedContinuation` som löses in av
  `performPendingTranslation(using:)` när SwiftUI levererar en session.
- `LanguageAvailability().status(from:to:)` kollas innan varje översättning:
  `.supported` (modellen finns men är inte nedladdad) visar "Laddar ner
  språkmodell (X)…" och triggar `session.prepareTranslation()`;
  `.unsupported` ger ett tydligt svenskt felmeddelande i panelen i stället
  för att tyst falla tillbaka på något annat. `TranslationError`-fallen
  (t.ex. `.unsupportedLanguagePairing`, `.notInstalled`) mappas till svensk
  text.
- Löste en Swift 6-concurrency-fälla: att skicka den icke-`Sendable`
  `TranslationSession` från `.translationTask`s closure till en
  `@MainActor`-metod gav "sending session risks causing data races" —
  löst genom att märka parametern `sending TranslationSession` i
  `performPendingTranslation(using:)`.
- **Tester** (`TranslationServiceTests`): `LanguageAvailability`s
  statusmaskin (körs i en `Task.detached` så den icke-`Sendable` typen
  aldrig behöver korsa en aktörsgräns) plus ett riktigt rundtrippstest via
  `TranslationSession(installedSource:target:)` (fungerar eftersom sv->en
  råkar redan vara nedladdat på utvecklingsmaskinen som denna fas kördes
  på) — översatte "Kylskåpet i köket är trasigt." till "The refrigerator in
  the kitchen is broken." Hoppar sig själv utan att fela om modellen saknas
  på maskinen som kör testet.

### 2. Diktering på enheten (`DictationService`)

Ersätter `SFSpeechRecognizer` med det nya `SpeechAnalyzer`-API:t.

**Viktigt SDK-fynd som INTE var uppenbart från dokumentationen** och som
krävde verklig testkörning (inte bara läsning av `.swiftinterface`) för att
upptäcka: `Speech.framework` har två olika "transcriber"-moduler för
`SpeechAnalyzer` — `SpeechTranscriber` (tänkt för
kvalitetstranskribering av inspelat/längre tal) och `DictationTranscriber`
(tänkt för live-diktering, samma användningsfall som appens gamla
`SFSpeechAudioBufferRecognitionRequest`). Testat i scratchpad:
`SpeechTranscriber.supportedLocales` innehåller **inte** svenska (45 språk,
inget `sv-SE`) i den här SDK-versionen, medan
`DictationTranscriber.supportedLocales` gör det (54 språk, inklusive
`sv-SE`, bekräftat via `supportedLocale(equivalentTo:)` ->
`sv_SE (fixed sv_SE)`). Appen dikterar i huvudsak svenska —
`DictationTranscriber` används, `SpeechTranscriber` hade tyst gjort svensk
diktering omöjlig.

- **Flöde**: `AVAudioEngine`s mikrofon-tapp konverterar varje buffert
  (`AVAudioConverter`) till `SpeechAnalyzer`s bästa kompatibla format och
  matar in dem i en `AsyncStream<AnalyzerInput>` som
  `SpeechAnalyzer.start(inputSequence:)` konsumerar.
  `DictationTranscriber(locale:contentHints:transcriptionOptions:
  reportingOptions:attributeOptions:)` konfigureras explicit med
  `.punctuation` (matchar gamla `addsPunctuation = true`),
  `.volatileResults` (löpande delresultat, matchar gamla
  `shouldReportPartialResults = true`) och `.frequentFinalization`
  (finaliserar oftare — snabbare "commit", mindre risk att tappa text vid
  ett avbrott mitt i en lång mening).
- **Textmodellen**: verifierat i scratchpad (syntetiskt svenskt tal via
  `say -v Alva`, matat genom EXAKT samma
  AVAudioConverter+AsyncStream-väg som produktionskoden, inte bara den
  enklare `inputAudioFile`-genvägen) att varje resultats `text` bara är den
  NYA textbiten sedan senaste finalisering — inte hela sessionens text om
  och om igen. `liveTranscript` byggs därför som
  `finalizedText (ackumulerad) + senaste flyktiga texten`
  (`DictationService.accumulate`, ren/testad funktion), samma
  "visa allt hittills"-modell `SFSpeechRecognitionResult.bestTranscription`
  gav förut.
- **Stoppordet** ("stopp"/"stop") upptäcks fortfarande snabbt: samma
  scratchpad-körning visade att "stopp" dyker upp i ett **flyktigt**
  resultat (`isFinal=false`) innan finalisering, inte fördröjt till nästa
  `isFinal`. Utbrutet till en ren funktion
  (`DictationService.stripTrailingStopWord`).
- **Modellnedladdning**: `AssetInventory.status(forModules:)` +
  `assetInstallationRequest(supporting:)` laddar ner språkmodellen om den
  saknas (samma mönster som `TranslationService`), med svensk statustext
  ("Laddar ner språkmodell (X)…") i `DictationPanelView`.
- **Behållet oförändrat**: publikt kontrakt (`liveTranscript`,
  `stoppedByVoice`, `isRecording`, `authorized`, `error`), så
  `DictationPanelView` inte behövde skrivas om i grunden.
  `SFSpeechRecognizer.requestAuthorization` behålls för
  behörighetsflödet (samma TCC-behörighet, kostar inget att fortsätta
  använda).
- **Tester** (`DictationServiceTests`): rena tester av
  `accumulate`/`stripTrailingStopWord`, plus ett riktigt integrationstest
  mot en committad ljudfixtur (`Tests/Fixtures/Dictation/
  kylskapet_trasigt_stopp_sv.m4a`, 17 KB, syntetiskt svenskt tal genererat
  med `say -v Alva`) som kör hela produktionsvägen genom `SpeechAnalyzer`
  och verifierar att transkriberingen faktiskt hittar texten och
  stoppordet. Hoppar sig själv utan att fela om `sv-SE` inte är
  tillgängligt på maskinen som kör testet.

### 3. Geokodning via MapKit (`CalendarService`/`AddressBanner`)

Ersätter deprecerade `CLGeocoder.geocodeAddressString` och
`MKMapItem.placemark` med `MKGeocodingRequest`/`MKMapItem.location`/
`.address`.

`MKGeocodingRequest`/`MKMapItem.location`/`.address` syns **inte** i
`MapKit.swiftinterface` — MapKit på macOS är i grunden ett
Objective-C-ramverk med en tunn Swift-overlay, så bara genuint
Swift-native symboler listas där. Verifierat direkt mot
Objective-C-headrarna (`MKGeocodingRequest.h`, `MKMapItem.h`,
`MKAddress.h`) och testat i scratchpad mot en riktig adress
("Lindvägen 12, Tyresö, Sverige") innan produktionskoden skrevs:
`MKGeocodingRequest(addressString:)?.mapItems` (async throws,
`NS_SWIFT_ASYNC_NAME(getter:mapItems())` — anropas som en async property,
inte en metod) gav samma koordinat som `CLGeocoder` gjorde.

- `CalendarService.geocodeAddress`: samma beteende som förut (", Sverige"
  läggs till om det saknas, cache per adress, `nil` vid miss/fel) — bara
  motorn under huven bytt.
- `AddressBanner.IdentifiableMapItem`: `.placemark.coordinate` ->
  `.location.coordinate`, `.placemark.title` -> `.address?.fullAddress`
  (närmaste motsvarighet — en fullständig, formaterad adressträng).
- **Resultat: 0 deprecationsvarningar i egen kod** på en fullständigt ren
  build (verifierat med `rm -rf` av derived-data-mappen + omkörd `build`) —
  de kvarstående CLGeocoder/placemark-varningarna som funnits sedan Fas 0
  är nu åtgärdade.
- **Tester** (`CalendarServiceTests`): två riktiga integrationstester mot
  en riktig svensk adress (geokodning ger en koordinat i
  Stockholmsregionen, andra anropet med samma adress återanvänder cachen i
  stället för att slå mot nätverket igen) — hoppar sig själva utan att
  fela om nätverket/Apple Maps inte är tillgängligt på maskinen som kör
  testet.

### Manuell testning användaren bör göra

1. **Diktering, första gången ett språk används på en ny maskin/efter en
   ren installation**: kontrollera att "Laddar ner språkmodell (Svenska)…"
   visas i `DictationPanelView` medan `DictationTranscriber`s språkmodell
   laddas ner, och att inspelningen sedan fungerar normalt efteråt. Testat
   här bara mot en maskin där modellen redan var tillgänglig (status
   `.supported`, men installation lyckades utan explicit nedladdningssteg)
   — en riktig "kall" nedladdning (status `.unsupported`/en maskin utan
   modellen alls) kunde inte framtvingas i den här miljön.
2. **Diktering, riktigt tal**: den här fasen verifierades grundligt med
   **syntetiskt** tal (`say`), inte en riktig mänsklig röst genom en riktig
   mikrofon. Testa särskilt: (a) att "stopp"/"stop" fortfarande avslutar
   inspelningen snabbt i praktiken (syntetisk taltest visade att ordet dyker
   upp i ett flyktigt resultat innan finalisering, men riktigt tal/en riktig
   mikrofon kan bete sig annorlunda), (b) längre, sammanhängande diktering
   över flera meningar med naturliga pauser (kontrollera att
   `finalizedText`-ackumuleringen inte tappar eller dubblerar text vid
   pauserna), (c) engelsk diktering (`en-US`, bara svenska testades i
   scratchpad-experimenten, om än `en-US` bekräftades finnas i
   `DictationTranscriber.supportedLocales`).
3. **Översättning, första gången ett språkpar används**: om `sv`->`en` inte
   redan är nedladdat på din maskin, kontrollera att "Laddar ner
   språkmodell (English)…" visas i panelen och att översättningen fungerar
   efteråt. Testat här bara med ett språkpar som redan var nedladdat på
   utvecklingsmaskinen — kunde inte framtvinga en riktig "kall" nedladdning
   i den här miljön.
4. **Översättningsfel**: testa gärna att koppla från nätverket helt inte
   är relevant längre (allt är on-device), men om Apples översättnings-
   ramverk av någon anledning inte kan slutföra en översättning, kontrollera
   att felmeddelandet i panelen är begripligt och att appen inte hänger
   kvar i "Översätter..."-läge.
5. **"Föreslå gallring" med `cullSuggestUtility` påslaget**: slå på
   inställningen och kör "Föreslå gallring" på en session med
   `isUtility`-flaggade bilder — kontrollera att bekräftelsetexten korrekt
   räknar upp både dubbletter och nyttobilder separat.
6. **Adressbanderollens kartvy** (`AddressCorrectionView`): kontrollera att
   sökresultatens underrubrik (tidigare `.placemark.title`, nu
   `.address?.fullAddress`) fortfarande visar en läsbar, fullständig adress
   för svenska sökträffar.

### Kvarstående / inte gjort i Fas 3c

- Ingen riktig "kall" modellnedladdning (varken tal eller översättning)
  kunde framtvingas i den här miljön — båda scratchpad-verifieringarna
  kördes på en maskin där språkmodellerna redan var (helt eller delvis)
  tillgängliga. Nedladdningskodvägarna (`AssetInventory`/
  `LanguageAvailability` + statustext) skrevs enligt SDK:ns dokumenterade
  kontrakt men är inte verifierade end-to-end mot en riktig nedladdning.
- Diktering testades bara med syntetiskt genererat tal (`say -v Alva`),
  aldrig en riktig mänsklig röst via en riktig mikrofon i den här GUI-lösa
  miljön — se "Manuell testning", punkt 2.
- `DictationTranscriber`s exakta finaliserings-/paus-beteende
  (hur ofta `.frequentFinalization` faktiskt finaliserar under en lång,
  sammanhängande, riktig diktering med naturliga pauser) är bara verifierat
  med korta, syntetiska testfraser — se "Manuell testning", punkt 2b.
- `MKReverseGeocodingRequest` (motsvarande reverse-geocoding-ersättning för
  `CLGeocoder.reverseGeocodeLocation`) undersöktes i SDK:n men används inte
  någonstans i appen idag (ingen kod reverse-geocodar) — inget att
  migrera, bara dokumenterat för fullständighetens skull.

## Fas 3d – Foundation Models på enheten

Utfört autonomt på branchen `forbattringar` medan användaren sov, ett steg i
taget med bygge + tester gröna före varje commit. Se `git log --oneline` för
commit-för-commit-historik. 119 tester totalt efter denna fas, alla gröna.

Mål: använda Apples nya `FoundationModels`-ramverk (on-device LLM,
`SystemLanguageModel`, macOS 26+) för två saker som tidigare löstes med ren
strängheuristik respektive inte alls: tolkning av kalendertitlar och
svenska bildbeskrivningar.

**Maskinen som körde detta har Apple Intelligence/Foundation Models
tillgängligt och redo** (`SystemLanguageModel.default.availability ==
.available`, verifierat i ett scratchpad-experiment innan något
produktionskod skrevs) — allt nedan är alltså verifierat skarpt mot den
riktiga modellen, inte bara skrivet enligt SDK:ns kontrakt.

### 0. Verifiering mot SDK:n innan produktionskod skrevs

`FoundationModels.framework` finns i macOS 27-SDK:t
(`$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework`).
Grep i `Modules/FoundationModels.swiftmodule/*.swiftinterface` bekräftade
de exakta signaturerna innan de användes (inga gissade API-namn):

- `SystemLanguageModel.default.availability` → `.available` /
  `.unavailable(UnavailableReason)` (`deviceNotEligible`/
  `appleIntelligenceNotEnabled`/`modelNotReady`) — tillgänglig från
  macOS 26.0.
- `LanguageModelSession(instructions:)` +
  `respond(to:generating:)`/`respond(to:schema:...)` — macOS 26.0.
- `@Generable`/`@Guide`/`GenerationGuide<[Element]>.count(_:)` — macros för
  strukturerad utdata, macOS 26.0.
- **Multimodal bildinmatning** (ny i WWDC26/macOS 27, fanns INTE i macOS
  26-SDK:t): `Attachment<ImageAttachmentContent>(_ cgImage: CGImage,
  orientation:)`, som är `PromptRepresentable` och kan blandas fritt med
  text i en `Prompt { "text"; Attachment(cgImage) }`-builder. Det finns
  också en parallell `Transcript.ImageAttachment`/`ImageReference`-väg för
  redan pågående sessioner, men `Attachment` + `PromptBuilder` var enklast
  för engångsanrop. Gated bakom `@available(macOS 27.0, *)` eftersom
  projektets deployment target är macOS 26.0.
- Felhantering: `LanguageModelSession.GenerationError` (deprecerad i
  macOS 27 till förmån för `LanguageModelError`, men fortfarande giltig
  vid target 26.0) och `SystemLanguageModel.Error.assetsUnavailable`. Båda
  ny-koderna fångar dock bara generiskt `catch { }` — se "Robusthet" nedan
  för resonemang.

Ett litet `swift -O`-experiment i scratchpad körde en enkel textprompt
(`"sax"` på ~2.4s) och en bild-genererande prompt mot
`/System/Library/CoreServices/DefaultBackground.jpg` (RoomTags-liknande
struct, ~2.4s) innan något av `BookingTitleParser`/`PhotoDescriptionService`
skrevs, för att bekräfta att modellen faktiskt svarar med rimligt innehåll
och rimlig latens på den här maskinen.

### 1. `BookingTitleParser` — kalendertitlar tolkas av modellen

Ersätter (som primär väg) den rena regex-/ordheuristiken i
`CalendarService.extractAddress`/`extractStreetAndCity`/`extractCityName`/
`extractBookingInfo` med en `@Generable BookingInfo`-struct
(`street`/`city`/`propertyType`/`areaSquareMeters`/`contactName`/
`contactPhone`) tolkad av `SystemLanguageModel`. Heuristiken finns kvar
**oförändrad** i `CalendarService` och används som fallback när modellen
inte är tillgänglig (`BookingTitleParser.heuristicParse`).

- **Adressformatet är identiskt** oavsett källa:
  `BookingTitleParser.addressString(from:)` bygger alltid
  "Gata Nummer, Ort" — samma form som gamla `extractAddress` — så
  adressmappnamn i pågående/tidigare sessioner inte ändras av den här
  fasen.
- **Cache**: resultat sparas per exakt titel-sträng i
  `~/Library/Application Support/PhotoFlow/booking_titles.json`
  (`JSONEncoder`/`JSONDecoder` på `[String: BookingInfo]`, `BookingInfo`
  är `Codable` utöver `@Generable`). En redan tolkad titel kostar alltså
  ett dictionary-lookup, inte ett nytt modellanrop, på efterföljande
  körningar (och inom samma körning — `matchCalendarBookings` och
  `writeIPTCMetadata`/`exportToAddressFolders` tolkar samma titlar utan
  att anropa modellen två gånger).
- **Uppmätt tid**: `BookingTitleParserTests.compareModelVsHeuristic_
  syntheticTitles` körde 14 titlar mot den riktiga modellen på **16.1s
  totalt ≈ 1.15s/titel** (`xcodebuild test`, se testloggen).
- `CalendarService.matchPhotosToAddresses` är nu `async` (anropar parsern);
  `extractBookingInfo`-anropen i `PipelineRunner+Metadata`/`+SortFolders`
  byts mot `BookingTitleParser.shared.parse(title:)` +
  `BookingTitleParser.bookingInfoText(from:)`.

#### Jämförelsetest: modell vs heuristik (14 syntetiska titlar)

EventKit-åtkomst till användarens **riktiga** kalender kräver ett
användargodkännande som inte kan ges i den här GUI-lösa, autonoma
körningen (ingen möjlighet att klicka "Tillåt" i en systemdialog), så
jämförelsen kördes i stället mot 14 påhittade men realistiska svenska
titlar (`BookingTitleParserTests.syntheticTitles` — testfixture, inga
riktiga personuppgifter) som täcker: med/utan komma, med postnummer,
våningssuffix ("bv"/"1 tr"/"nb"), bostadstyp+area, kontaktperson+telefon i
olika format, och prefix-brus ("Fotografering "/"Foto - "/"Fototid: ").
Resultat (utdrag, se testloggen för alla 14):

| Titel (förkortad) | Heuristik: street / city | Modell: street / city | Kommentar |
|---|---|---|---|
| "Fotografering Lindvägen 12, Stockholm" | "Fotografering Lindvägen 12" / Stockholm | "Lindvägen 12" / Stockholm | Modellen strippar prefixet |
| "Objektfoto: Ekvägen 3, bv, Lund" | "Objektfoto: Ekvägen 3" / **"bv"** | "Ekvägen 3, bv" / **Lund** | Heuristiken tolkar våningssuffixet som ort — fel. Modellen rätt |
| "...radhus Almvägen 19, 2 tr, Sollentuna, ca 120 kvm, Maria Nilsson: ..." | "Fotografering radhus Almvägen 19" / **(ingen ort)** | "Almvägen 19, 2 tr" / **Sollentuna** | Heuristiken missar orten helt när för många kommadelar finns |
| "Fototid Storgatan 12B lgh 1101, Malmö - Anna Karlsson 070-123 45 67" | kontakt: **(ingen)**, tel: **(ingen)** | kontakt: "Anna Karlsson", tel: "070-123 45 67" | Heuristikens namn-/telefonextraktion är svagare på den här formen |

**Slutsats**: för själva adressen (street+city — det som styr
mappnamnet) är modellen en tydlig förbättring, särskilt på att strippa
brus-prefix och hitta orten i längre, kommaseparerade titlar där
heuristiken förväxlar den med ett våningssuffix eller ger upp helt.
Kontaktnamn/telefon (bara IPTC-extratext, påverkar inga mappnamn) är också
klart bättre återgivna av modellen.

**Viktig brasklapp — modellen hittar ibland på `propertyType`/
`areaSquareMeters`** trots en explicit instruktion i prompten att
"Extrahera ENDAST det som faktiskt står i titeln — gissa aldrig...":
- "Ringvägen 14 611 32 Nyköping Peter Åberg 076-1112233" (ingen bostadstyp
  alls i titeln) → modellen svarade `propertyType="villa"`,
  `areaSquareMeters=0`.
- "Åkervägen 2 nb, 195 60 Arlandastad, Karin Ek 08-59512345" → modellen
  läste postnumret **195 60** som `areaSquareMeters=19560` och hittade
  samtidigt på `propertyType="bostadsrätt"`.
- "Trädgårdsgatan 5B, Visby - Sara Holm 070-2223344" → `propertyType=
  "radhus"`, `areaSquareMeters=0` påhittat.

Det här **påverkar inte adressmappnamnet** (bara `street`/`city` används
där), men gör att `bookingInfoText`/IPTC-extratexten ibland kan innehålla
en felaktig bostadstyp eller ett postnummer feltolkat som kvadratmeter.
Användaren bör stickprovskontrollera IPTC-beskrivningarna på riktiga
bokningar, särskilt titlar utan explicit bostadstyp/area, och överväga att
skärpa prompten ytterligare (t.ex. `@Guide`-beskrivningar med explicit
"null om inte angivet" på just de fälten) om detta visar sig vanligt i
praktiken.

### 2. `PhotoDescriptionService` — svenska bildbeskrivningar från pixlarna

`VisionTaggingService` (Fas 3b) klassificerar snabbt men grovt via Vision;
`PhotoDescriptionService` (ny) kompletterar med en riktig svensk
bildbeskrivning genom att skicka själva preview-JPEG:en till modellen som
multimodal bildinmatning (`Attachment<ImageAttachmentContent>`, macOS
27+ — se punkt 0 ovan). `@Generable RoomTags`: `room`/`category`
("Interiör"/"Exteriör")/`features` (0–4 särdrag)/`caption`
(kort svensk bildtext).

- **Körs bara på ett urval**: en representativ bild per bracket-/
  singelgrupp (första filen i gruppen), inte alla previews — se
  "Uppmätt tid" nedan för varför. Körs efter Vision-klassificeringen i
  samma `.aiTagging`-steg (`PipelineRunner+AITagging.runAITagging`):
  Vision ger snabb grovklassificering först, modellen ger text för
  urvalet därefter.
- **Uppmätt tid**: `PhotoDescriptionServiceTests` — en syntetisk 800×600-
  bild (genererad med Core Graphics i testet, inte en riktig fastighets-
  bild) tog **2.27–2.32s** per `describe()`-anrop, vilket är i linje med
  bildexperimentet i scratchpad (~2.4s mot en riktig JPEG). Med t.ex. 15
  bracket-/singelgrupper i en session ⇒ ~35s extra i AI-tagg-steget, vilket
  bedömdes acceptabelt för ett bakgrundssteg — därav urvalet i stället för
  alla bilder (skulle annars kunna bli flera minuter för en stor session).
- **Persistens**: `AITagsStore` (ny, i `VisionTaggingService.swift`) gör
  `ai_tags.json` versionerad (`version: 2`) med valfria `ml*`-fält
  (`mlRoom`/`mlCategory`/`mlFeatures`/`mlCaption`) ovanpå Fas 3b:s
  `tags`/`description`/`category`. **Läser äldre, oversionerade
  `ai_tags.json`-filer transparent** (`AITagsStore.load` provar det nya
  formatet först, faller tillbaka till den gamla platta formen) — inga
  befintliga sessioner behöver räknas om.
- **Sammanslagning**: Vision-taggarna + ML-särdragen slås ihop till en
  taggmängd (rummet först, sedan Vision-taggar, sedan nya ML-särdrag,
  dubbletter borttagna), och ML-bildtexten ersätter Vision's mallgenererade
  beskrivning när den finns — allt direkt i `aiTagResults` (samma dict
  `writeIPTCMetadata` redan läser via `photo.aiTags`/`photo.aiDescription`),
  så **ingen ändring behövdes i IPTC/XMP-skrivningen själv**
  (`PipelineRunner+Metadata.swift`) eller i `PipelineRunner+LoadSession`
  förutom att läsa via `AITagsStore` i stället för rå `JSONSerialization`.
- **Ny inställning** `AppSettings.aiDescriptionsEnabled` (standard `true`,
  men styrs i praktiken av `PhotoDescriptionService.isAvailable` — kan
  aldrig "tvinga på" bildbeskrivningar på en enhet utan stöd) + rad i
  `SettingsView`s AI-taggning-sektion, med olika förklaringstext beroende
  på om modellen faktiskt är tillgänglig på enheten som kör appen.

#### En verklig bugg hittad under testning

Första lydelsen av `@Guide`-beskrivningen för `features` var "... — tom
lista om inget särskilt sticker ut". Det körda testet
(`PhotoDescriptionServiceTests`) visade att modellen tolkade detta
**bokstavligt** och returnerade `features: ["tom lista"]` (en enda sträng
med det litterala innehållet "tom lista") i stället för en faktiskt tom
array, för en syntetisk bild utan tydliga särdrag. Fixat genom att:

1. Byta till `GenerationGuide<[Element]>.count(0...4)` för en riktig
   storleksbegränsning i stället för att beskriva "tomhet" i fritext.
2. Skriva om beskrivningen till "0 till 4 korta svenska särdrag ...
   Hitta inte på särdrag som inte syns." — utan ordet "tom"/`[]`.

Efter fixen gav samma syntetiska bild rimliga `features` (t.ex.
`["ljus blå bakgrund", "brun yta"]`). Ett bra exempel på varför
`@Guide`-texter bör verifieras mot riktiga modellanrop, inte bara läsas
som dokumentation — se "Manuell testning" nedan för vad som bör
stickprovskontrolleras på riktiga fastighetsbilder.

### 3. Robusthet — inget stoppar pipelinen, ingen nätverkstrafik

- `BookingTitleParser.runModel` och `PhotoDescriptionService.describe`
  fångar båda modellanrop med ett generiskt `catch { }` (kontextgräns,
  guardrail-avslag, otillgänglig modell, etc. — alla
  `LanguageModelSession`/`SystemLanguageModel`-fel ärver `Error`), loggar
  en svensk varning via `print(...)`, och returnerar `nil`/faller tillbaka
  på heuristiken. Ingen av de två höjer vidare — anroparen
  (`PipelineRunner+AITagging`/`CalendarService`) ser bara ett `nil`-
  resultat och fortsätter med nästa bild/titel.
- `runPhotoDescriptions` respekterar avbrytning
  (`shouldAbort()`/`markActiveStepsCancelled()`) mellan varje bild, precis
  som resten av AI-tagg-steget, och rapporterar förlopp via
  `state.updateStepProgress(.aiTagging, ...)`.
- **Ingen nätverkstrafik**: `SystemLanguageModel` kör helt on-device (Apple
  Intelligence-modellen är redan nedladdad till enheten av OS:et — appen
  gör inga egna nätverksanrop för vare sig text- eller bildinferens).

### Manuell testning användaren bör göra

1. **Riktiga kalendertitlar**: kör pipelinen mot en riktig session och
   jämför de resulterande adressmapparna mot vad de skulle blivit i en
   tidigare fas (samma mappnamn förväntas — bara källan till namnet har
   bytts). Kontrollera särskilt en titel med våningssuffix ("bv"/"X tr")
   följt av kommatecken och ort, där heuristiken visade sig kunna
   förväxla suffixet med orten (se jämförelsetabellen ovan).
2. **IPTC-extratext (`bookingInfoText`)** på ett gäng riktiga bokningar:
   leta efter påhittad bostadstyp/area på titlar som inte nämner det
   alls, och postnummer feltolkat som kvadratmeter (se brasklappen i
   avsnitt 1) — justera prompten i `BookingTitleParser.runModel` om det
   visar sig vanligt.
3. **AI-bildbeskrivningar på riktiga fastighetsfoton**: kontrollera att
   `caption`/`features` är sakligt korrekta (testat här bara mot en
   syntetisk genererad bild, aldrig ett riktigt foto av ett kök/badrum/
   fasad) och att de känns naturliga i en mäklarannons. Kontrollera också
   att steget inte tar orimligt lång tid på en stor session (uppskatta
   ~2.3s × antal bracket-/singelgrupper).
4. **`booking_titles.json`/`ai_tags.json` efter en körning**: inspektera
   `~/Library/Application Support/PhotoFlow/booking_titles.json` samt
   sessionens `ai_tags.json` för att se att cachningen/versioneringen ser
   rimlig ut. OBS: `BookingTitleParserTests`s jämförelsetest lägger även
   in 14 syntetiska testtitlar i den riktiga `booking_titles.json`-cachen
   varje gång testsviten körs (ofarligt — de matchar aldrig en riktig
   kalendertitel — men värt att veta om filen inspekteras).
5. **Inställningen `aiDescriptionsEnabled`**: slå av/på i `SettingsView`
   och kontrollera att steget faktiskt hoppas över/körs, samt att texten
   under togglen stämmer med om `PhotoDescriptionService.isAvailable` är
   sant på just den maskinen.

### Kvarstående / inte gjort i Fas 3d

- Ingen riktig EventKit-åtkomst till användarens kalender kunde begäras i
  den här autonoma, GUI-lösa körningen (kräver ett användargodkännande) —
  jämförelsetestet kör därför mot en syntetisk fixture i stället för
  riktiga bokningstitlar, se avsnitt 1.
- Bildbeskrivningarna är bara verifierade mot en syntetiskt genererad
  testbild (färgytor + en rektangel), aldrig ett riktigt fastighetsfoto —
  se "Manuell testning", punkt 3.
- Modellens tendens att hitta på `propertyType`/`areaSquareMeters` när de
  inte står i titeln (avsnitt 1) är dokumenterad men inte åtgärdad med en
  striktare prompt/efterhandsvalidering — bedömdes inte kritiskt eftersom
  det inte påverkar adressmappnamnet, bara en extra IPTC-textrad.
- Ingen UI-yta visar `BookingInfo`s nya fält (`propertyType`/
  `areaSquareMeters`/`contactName`/`contactPhone`) separat — de går bara
  in i samma fritextsträng (`bookingInfoText`) som tidigare. Skulle kunna
  brytas ut till egna, redigerbara fält i UI:t i en framtida fas om
  användaren vill kunna rätta enskilda felaktiga värden utan att skriva
  om hela extratexten.

## Fas 3e – Systemintegration på macOS

Utfört autonomt på branchen `forbattringar` medan användaren sov. Alla fem
steg byggdes och testades grönt (`xcodebuild ... build`/`test`) innan varje
commit — se `git log --oneline` för commit-för-commit-historik.

### 1. `AVAudioNode.installTap` → `installAudioTap` (deprecerad i macOS 27)

`DictationService.startRecordingAsync` använde den klassiska
`installTap(onBus:bufferSize:format:block:)`, deprecerad i macOS 27.
Ersättaren, `installAudioTap(onBus:bufferSize:format:tapProvider:)`, syns
**inte** direkt i `AVAudioNode.h` — den råa ObjC-signaturen (med en
`NSError**`-parameter) är märkt `NS_REFINED_FOR_SWIFT`, och den faktiska
Swift-vänliga varianten hittades genom att läsa
`AVFAudio.swiftmodule/*.swiftinterface` i macOS 27-SDK:n (`swift-api-digester`
gav ofullständiga resultat; den textuella `.swiftinterface`-filen under
`AVFAudio.framework/Versions/A/Modules/` var facit). Den nya API:t:

- Kastar fel (`throws`) i stället för att vara `void`.
- Ger tap-blocket en ny, `Sendable`, read-only `AVReadOnlyAudioPCMBuffer` i
  stället för den gamla klassen `AVAudioPCMBuffer` — konverteras direkt
  tillbaka med den nya `AVAudioPCMBuffer(copying:)`-initieraren så att
  resten av flödet (`enqueue`/`makeAnalyzerInput`) inte behövde skrivas om.
- Kräver macOS 27 (`@available`). Projektets deployment target är macOS 26,
  så den nya varianten väljs bakom `if #available(macOS 27.0, *)` med den
  gamla, deprecerade varianten som fallback för äldre system — verifierat
  att detta INTE ger någon deprecationsvarning (Swift varnar bara om
  deployment targetet självt är ≥ den deprecerade versionen; en gren som
  bara körs på system < 27 kan fortsätta kalla den gamla API:n utan
  varning). `xcodebuild build` ger 0 varningar för filen efter ändringen.

### 2. FSEvents-baserad filbevakning i stället för ren `Timer`-pollning

`WatchService` bevakade tidigare bara via `Timer.scheduledTimer` var N:e
sekund (`watchIntervalSeconds`, default 10s). Nu:

- **FSEvents** (`FSEventStreamCreate`, `CoreServices`/`FSEvents.framework` —
  signaturer verifierade mot headern i macOS 27-SDK:n) bevakar inputmappen
  rekursivt i realtid. Callbacken bryr sig inte om VILKEN sökväg som
  ändrades — varje händelse matar bara en debouncer, och den efterföljande
  omkontrollen skannar mappen precis som fallback-pollningen redan gjorde.
- **Debounce (~2s)**: `FSEventDebouncer`, en liten klass med en injicerbar
  klocka (`recordEvent(at:)`/`tick(now:)` tar explicita `Date`-värden) så
  hela besluts­logiken ("har det gått X sekunder tystnad sedan senaste
  händelsen?") är enhetstestbar utan riktiga timers eller `sleep`. I
  produktion drivs `tick(now:)` av en kort repeterande `Timer` (var 0.3:e
  sekund).
- **Stabilitetskontroll**: innan filer räknas som färdigkopierade jämförs
  filstorleken vid två mätningar med 1 sekunds mellanrum
  (`WatchService.isFileStable`/`stableFiles`, rena statiska funktioner över
  storleksdictionaries) — viktigt när bilder kopieras direkt från ett
  SD-kort in i inputmappen och en fil annars kunde fångas mitt i
  skrivningen. Filer som fortfarande växer lämnas kvar till nästa kontroll
  i stället för att skickas till pipelinen halvfärdiga.
- **`NSWorkspace.didUnmountNotification`** tillagd (utöver den befintliga
  `didMountNotification`) för att rensa `detectedVolumes` och logga när ett
  SD-kort kopplas bort mitt i en session.
- Den gamla `Timer`-pollningen behålls oförändrad som **fallback-skyddsnät**
  (nu 60s i stället för 10s, default, eftersom FSEvents är primär mekanism
  — `AppSettings.watchIntervalSeconds`) ifall FSEvents skulle missa en
  händelse (t.ex. `kFSEventStreamEventFlagKernelDropped`).
- Alla nya beteenden (debounce-fönster, stabilitetsfördröjning) är
  hårdkodade konstanter snarare än nya inställningar — bedömdes inte
  behöva vara justerbara av användaren; det enda existerande, användarnära
  reglaget (`watchIntervalSeconds`) finns kvar och dess UI-text uppdaterad
  för att förklara att den nu bara är fallback.
- Tester: `WatchServiceDebounceStabilityTests.swift` (debounce-beslut med
  injicerad klocka, stabilitetsfiltrering med syntetiska storleksdata —
  inga riktiga filer/timers).

### 3. Systemnotiser (`UserNotifications`) som komplement till ljud/tal

Ny `NotificationService` (singleton, `@MainActor`, `UNUserNotificationCenter`)
skickar notiser för fyra händelser (samma ställen som redan spelade
ljud/tal via `AudioService`, men nu även som systemnotis):

1. **Nya filer hittade och pipelinen startat** — `WatchService.checkDirectory`,
   samma villkor som redan triggade `onNewFilesDetected` (autoStart på).
2. **Pipeline klar, väntar på granskning** — `PipelineRunner.startPipeline`,
   bredvid det befintliga `audio.playNeedsAttention()`.
3. **Fel i ett steg** — pipelinens toppnivå-`catch` i `startPipeline`,
   bredvid `audio.playError()`.
4. **HDR-sammanslagning klar** — `PipelineRunner+HDR.runHDRMerge()` (hela
   batch-steget, inte enskilda `reMergeHDR`-ommergningar under granskning,
   för att undvika notis-spam), bredvid `audio.playStepComplete()`.

Notisknappar: **"Granska nu"** (aktiverar appen och sätter
`PipelineState.reviewRequestedFromNotification = true`, som `DashboardView`
observerar via `onChange` för att öppna granskningsvyn — en bool på det
delade `PipelineState` i stället för en direkt referens till dashboardens
lokala `@State`, eftersom `PipelineState` redan är nåbar från både
`PhotoFlowApp`/`NotificationService` och alla vyer) och **"Öppna mapp"**
(öppnar mappen i Finder via `NSWorkspace`). `UNUserNotificationCenterDelegate`
implementerad så notiser visas som `.banner` även när appen redan är i
förgrunden (annars visas notiser bara medan appen är i bakgrunden, precis
tvärtom mot vad som behövs här).

**Behörighet begärs lat** — inte vid appstart, utan första gången en notis
faktiskt ska skickas (`requestAuthorizationIfNeeded()` anropas inifrån
`send(...)`), vilket i praktiken alltid blir pipelinens "nya filer
hittade"-notis, dvs. första gången pipeline-läget faktiskt används. Ljud/tal
(`AudioService`) är helt oförändrat och körs parallellt enligt befintliga
inställningar — notisen skickas utan eget notisljud för att undvika en
dubbel signal för samma händelse.

Ny inställning `notificationsEnabled` (default på) i `AppSettings` +
`SettingsView` (fliken "Ljud"/`AudioTab` döpt om till **"Ljud & notiser"**),
med två testknappar (granskning/fel) för att stickprovskontrollera utan att
behöva köra en hel pipeline.

### 4. `MenuBarExtra` + bakgrundsläge

Appen kan nu bevakas utan öppet huvudfönster:

- **Ägandeskap flyttat**: `RunnerWrapper` (och därmed `WatchService`) ägs
  numera av `PhotoFlowApp` (`@StateObject`) i stället för `ContentView` —
  nödvändigt så både huvudfönstret och menyraden delar EXAKT samma
  bevaknings-/pipeline-state. `ContentView` tar nu emot `runner` som
  parameter och beter sig i övrigt identiskt (dashboardens beteende
  oförändrat).
- **`MenuBarExtra`**: ikon kamera i vila / öga (`eye.fill`) när bevakning är
  aktiv. Meny: status ("Bevakar · N nya" / "Bevakning avstängd"),
  starta/stoppa bevakning, "Öppna PhotoFlow" (via
  `openWindow(id: "main")` — huvudfönstret gavs ett explicit
  `WindowGroup`-id just för detta, så ett stängt fönster kan återöppnas),
  "Öppna outputmapp" (Finder, inaktiverad om ingen outputmapp finns än),
  "Avsluta". Ny inställning `showMenuBarExtra` (default på).
- `RunnerWrapper` vidarebefordrar nu `watcher.objectWillChange` till sitt
  eget `objectWillChange` (en liten Combine-`sink`) — annars hade
  `MenuBarExtra`s ikon/meny aldrig fått en anledning att uppdateras när
  `watcher.isWatching`/`newFilesFound` ändras, eftersom `WatchService`s
  egna `@Published`-fält inte renderas av något annat UI-lager sedan
  tidigare (bara `PipelineState`s egna fält gör det).
- **`SMAppService.mainApp`** (`ServiceManagement`, signaturer verifierade
  mot macOS 27-SDK:n) kopplad till en ny inställning "Starta vid
  inloggning" i `SettingsView`s Bevakning-flik, med felhantering (visar
  felmeddelande och återställer togglen till det faktiska systemläget om
  `register()`/`unregister()` kastar) och synk mot
  `SMAppService.mainApp.status` varje gång fliken visas (användaren kan ha
  stängt av det i Systeminställningar sedan sist).

#### En allvarlig bugg hittad och fixad under verifiering

Första implementationen band `MenuBarExtra(isInserted:)` mot
`$settings.showMenuBarExtra`, en `Binding` proxad genom `AppSettings`
(en vanlig `ObservableObject`-klass vars `showMenuBarExtra` är en
`@AppStorage`-property, INTE `@Published`). Det gav en **oändlig
scen-graf-uppdateringsloop** — upptäckt för att `xcodebuild test` kör hela
appen som testvärd (`TEST_HOST` i `PhotoFlowTests`s build settings), så
även ett rent enhetstest startar `PhotoFlowApp` på riktigt. Reproducerades
deterministiskt: antingen en hängning på ~97 % CPU i flera minuter, eller
en krasch (`EXC_BAD_ACCESS`/stack-overflow, `AppGraph.graphDidChange()` →
`sceneList` → om och om igen i kraschloggen) — bekräftat med
`~/Library/Logs/DiagnosticReports/PhotoFlow-*.ips`. Isolerad genom att
binärsöka bort delar av `MenuBarExtra` (label, content, `isInserted`) tills
den exakta triggern (`isInserted`-bindingen) hittades.

**Fix**: deklarera `showMenuBarExtra` som en egen `@AppStorage` DIREKT i
`PhotoFlowApp`-structen (samma UserDefaults-nyckel som `AppSettings`s
kopia, så `SettingsView`s toggle och menyradens `isInserted`-binding
förblir synkade) i stället för att gå via klassen — den native,avsedda
användningen av `@AppStorage` som property wrapper direkt på en
`View`/`Scene`/`App`. Verifierat stabilt över flera upprepade
`xcodebuild test`-körningar efter fixen. **Läxa för framtida faser**: undvik
att skapa `Binding`s till `@AppStorage`-properties som ligger på en vanlig
`ObservableObject`-klass (`$settings.xxx`-mönstret som redan användes
flitigt i `SettingsView` för vanliga `Toggle`/`TextField` fungerar bra där,
men `MenuBarExtra(isInserted:)` — och möjligen andra API:er som skriver
tillbaka till bindingen internt — tål det uppenbarligen inte).

### 5. Övrigt

- Alla nya inställningar (`notificationsEnabled`, `showMenuBarExtra`,
  `launchAtLoginRequested`) har vettiga default-värden och är
  avstängningsbara, enligt de gemensamma reglerna.
- Inga ändringar i `PhotoFlow/project.yml` denna fas förutom nya källfiler
  som redan täcks av de befintliga glob-mönstren (`Sources`/`Tests`) —
  `xcodegen generate` kördes ändå efter varje ny fil för att uppdatera
  `.xcodeproj`.

### Manuell testning användaren bör göra

1. **Notistillstånd**: kör pipelinen mot en riktig session (eller tryck
   testknapparna i Inställningar → Ljud & notiser) och bekräfta att macOS
   faktiskt frågar om notisbehörighet vid första tillfället, att notisen
   syns som banner (även med huvudfönstret i förgrunden), och att
   "Granska nu"/"Öppna mapp"-knapparna gör rätt sak. Kontrollera även i
   Systeminställningar → Notiser → PhotoFlow att appen listas korrekt.
2. **Menyraden**: bekräfta att ikonen faktiskt växlar kamera ↔ öga när
   bevakning startas/stoppas (både via menyn och via dashboardens egna
   kontroller), att "Öppna PhotoFlow" återöppnar huvudfönstret efter att
   det stängts (inte bara aktiverar appen utan fönster), och att "Avsluta"
   verkligen avslutar hela appen (inte bara stänger fönstret).
3. **"Starta vid inloggning"**: slå på/av i Inställningar → Bevakning,
   logga ut/in (eller starta om) och bekräfta i Systeminställningar →
   Allmänt → Inloggningsobjekt att PhotoFlow faktiskt listas/inte listas.
4. **FSEvents med ett riktigt SD-kort**: koppla in ett kort och kopiera (via
   Finder/Bild-tagning) en sats NEF-filer direkt in i den konfigurerade
   inputmappen (inte bara till en undermapp på kortet i sig — den vägen
   testas redan av den befintliga volym-scanningen). Bekräfta att
   pipelinen INTE startar förrän hela kopieringen är klar (stabilitets-
   kontrollen ska filtrera bort halvkopierade filer) och att den startar
   inom några sekunder efter att kopieringen avslutats (debounce-fönstret).
   Detta gick inte att testa mot ett riktigt SD-kort i den här autonoma,
   GUI-lösa körningen.
5. **HDR-klart-notisen**: kör en session med flera bracket-grupper och
   bekräfta att notisen bara skickas EN gång för hela HDR-steget (inte per
   grupp), med korrekt antal lyckade/misslyckade i texten.

### Kvarstående / inte gjort i Fas 3e

- Ingen striktare FSEvents-scoping (t.ex. att bara reagera på händelser i
  undermappar som faktiskt kan innehålla NEF-filer) — varje händelse i
  hela inputträdet triggar en omkontroll efter debounce, vilket är billigt
  nog (en `FileManager`-skanning) för att inte optimera bort i den här
  fasen.
- `MenuBarExtra`s meny uppdaterar inte "Bevakar · N nya" i realtid om
  pipelinen körs och `newFilesFound` sätts om under körning (den
  återspeglar `WatchService.newFilesFound`, som bara uppdateras av
  `checkDirectory`/`searchVolumeForNEFs`, inte av själva pipeline-
  körningen) — bedömdes inte kritiskt, texten är ändå korrekt vid nästa
  bevaknings­kontroll.
- Om användaren byter inputmapp i Inställningar MEDAN bevakning redan
  pågår flyttas FSEvents-strömmen till den nya mappen först vid nästa
  `checkForNewFiles`-anrop (inom en fallback-pollningsperiod, eller
  direkt om en FSEvents-händelse redan var på väg) — inte omedelbart. Inte
  testat manuellt.

## Fas 4 – Arbetsflöde och Lightroom

Utfört autonomt på branchen `forbattringar` medan användaren sov. Alla steg
byggdes och testades grönt (`xcodebuild ... build`/`test`) innan varje
commit — se `git log --oneline` för commit-för-commit-historik. Adobe
Lightroom Classic bekräftades installerad (`ls /Applications`), men eftersom
den här körningen inte kan klicka i GUI:t verifierades Lightroom-pluginet så
långt det gick utan det: Lua-syntax kontrollerad med en fristående
`lua`-interpreter (installerad via `brew install lua` för det här ändamålet),
och hela orkestreringslogiken (JSON-tolkning, catalog-anrop,
GUI-scriptningens `osascript`-sekvens, konfigurerbara väntetider, status-/
done-filer) körd end-to-end mot mockade `LrXxx`-moduler i scratchpad-skript
(inte incheckade — bara utvecklingsverktyg för den här sessionen).

### 1. Gallringsbeslut till Lightroom via XMP i stället för radering

Ny inställning `AppSettings.cullAction` med tre lägen:

- **"markera"** (ny, default): rör inga filer. `PipelineRunner+Culling.swift`
  (`cullExiftoolArguments`/`writeCullRatings`) skriver `XMP:Rating` — 3 för
  accepterade, **-1** för avvisade (Lightroom Classics "Rejected"-flagga,
  verifierat mot Adobes XMP-konvention: Lightroom visar en bild som avvisad
  exakt när `xmp:Rating == -1`) — plus `XMP-photoshop:Urgency=8` (lägst i
  IPTC:s 1–8-skala) på avvisade. Återanvänder samma NEF-symlänk-vs-
  verklig-fil-uppdelning som `PipelineRunner.exiftoolArguments` i
  `PipelineRunner+Metadata.swift` (Fas 1a): DNG/JPEG/HDR-TIFF skrivs
  `-overwrite_original_in_place`, NEF får en XMP-sidecar.
- **"radera"**: det gamla beteendet (`deleteRejectedFiles`), nu bakom en
  `confirmationDialog` i `PreviewCullView` eftersom det är det enda av de tre
  lägena som inte går att ångra.
- **"flytta"**: flyttar (aldrig kopierar) avvisade filers symlänkar/filer
  till en `Gallrade`-undermapp under respektive DNG-/TITTBILDER-/
  ÖVRIGA-mapp.

`PreviewCullView.finishCulling` dispatchar via en ny
`PipelineRunner.finishCullingAction()` och visar statustext som matchar det
valda läget (`performFinishCulling`). Ny `Picker` + förklarande text i
`SettingsView` (Pipeline-fliken, sektion "Gallring"). Tester i
`PipelineRunnerCullingTests` för argfile-byggandet (accepterad/avvisad, NEF
vs DNG/sidecar-hantering).

### 2. Generell ångra-stack i gallringen (upp till 50 beslut), ⌘Z

`z` var tidigare bara en enda-nivå-ångra för senaste "Föreslå
gallring"-batchen (Fas 3b). `PreviewCullView` har nu en riktig stack
(`undoStack: [UndoAction]`, `pushUndo`/`performUndo`) som sparar upp till 50
senaste besluten:

- Varje manuell accept/avvisa (`acceptPhoto`/`rejectPhoto`) trycker en egen
  `UndoAction` med en post (bild-id + tidigare `accepted`/`rejected`-tillstånd).
- "Föreslå gallring" (`s`) trycker EN `UndoAction` som täcker hela batchen,
  så en ångring återställer allihop på en gång — samma beteende som den
  gamla enda-nivå-ångran hade, bara generaliserat.
- Stacken begränsas till 50 poster (äldsta *action* faller bort som helhet,
  aldrig mitt i en batch).
- `z` och `⌘Z` hanteras av samma `onKeyPress(characters:)`-handler — AppKit
  rapporterar samma tecken ("z") oavsett om Command hålls nere, vilket redan
  var det underliggande beteendet de andra en-tangents-genvägarna (x/f/d/s)
  i vyn förlitade sig på.
- Z-knappen i både normal- och helskärmsvyn visas nu när `undoStack` inte är
  tom, i stället för det gamla `lastSuggestionUndo != nil`-villkoret.

### 3. Kalenderval via Picker i Inställningar i stället för fritext

`AppSettings.calendarName` hade tidigare ETT hårdkodat personligt
standardvärde ("Exempelkalender") och **ingen UI alls** — namnet
kunde bara ändras genom att redigera koden. `SettingsView` (Pipeline-fliken,
Kalendersektionen) har nu en `CalendarPickerRow`:

- En riktig `Picker` som listar tillgängliga kalendrar via
  `CalendarService.availableCalendarNames()` (`EKEventStore.calendars(for:
  .event)`), med "Alla kalendrar" (tomt värde) som eget alternativ.
- Om åtkomst inte beviljats än: en "Begär åtkomst"-knapp
  (`CalendarService.authorizationStatus`, `EKAuthorizationStatus`).
- Om åtkomst nekats/begränsats av systemet: ett fritextfält som fallback,
  som fortfarande går genom `CalendarService.resolveCalendar`s
  exakt/skiftlägesokänsliga/delvis-matchning mot namnet.

`calendarName` har inte längre ett hårdkodat personligt standardvärde (tomt
= alla kalendrar). En engångsmigrering (`AppSettings.
migrateCalendarNameIfNeeded`, styrd av `calendarNameMigratedV1`) skriver in
det gamla hårdkodade värdet explicit om användaren aldrig själv satt något —
annars hade uppstarten efter den här ändringen tyst bytt beteende till
"alla kalendrar" för befintliga användare som aldrig öppnat den här delen av
Inställningar.

### 4. Kvarstående från tidigare faser

**Fas 1b — adressrättning uppdaterade inte mappningen:** att rätta en adress
i `AddressBanner` uppdaterade tidigare bara `PipelineState.
allMatchedAddresses` — `PipelineRunner.calendarMappings` (den faktiska
källan `CalendarService.addressFolder` använder för mappnamn) förblev
oförändrad tills kalenderstoppet kördes om helt. Ny
`PipelineRunner+AddressCorrection.swift`:

- `updateCalendarMappingAddress(from:to:)`: fixar `calendarMappings` i
  minnet direkt, anropas från `AddressBanner`s `onSave`-callback.
- `addressFolderAlreadySorted(_:)`: kollar om `files_sorted.json` OCH någon
  av de tre adressmapparna redan finns på disk för den gamla adressen.
- `resortAddressFolder(from:to:)`: döper om DNG-/TITTBILDER-/ÖVRIGA-mapparna
  (`AddressFolderLayout`) till det nya namnet — rör bara mappar med exakt de
  namn appen själv skapar, aldrig input-/originalmapparna.
  `metadata_written.json` ogiltigförklaras redan av `PipelineState.
  correctAddress` (Fas 1b), så metadata skrivs om med rätt adress vid nästa
  körning; `files_sorted.json` påverkas inte (antalet sorterade filer ändras
  inte av en ren mappomdöpning).

`AddressBanner` visar en blå banner med knappen "Sortera om filerna till den
nya adressmappen" när en rättning görs och filer redan sorterats under det
gamla namnet. Tester i `PipelineRunnerAddressCorrectionTests`.

**Fas 3b — filter/sortering i gallringen:** `PreviewCullView.headerBar` har
en ny rad med två segmenterade kontroller: **"Visa"** (Alla / Ogranskade /
Avvisade) och **"Sortera"** (Filnamn / Kvalitet).
`filteredIndexedPhotos` filtrerar/sorterar `allPhotos` men rör aldrig
beslut — bara vad filmremsan visar och i vilken ordning `navigate(_:)`
(←/→, och Return/x:s automatiska "gå vidare") hoppar. `navigate` hanterar
fallet där den aktuella bilden precis föll ur den filtrerade listan (t.ex.
avvisas medan "Ogranskade" är valt) genom att hoppa till närmaste
kvarvarande bild i samma riktning i stället för att fastna på en dold bild.

### 5. Lightroom-integrationen

- **Riktig bakgrundspollning**: appen loggade tidigare "Pluginet auto-pollar
  var 5:e sekund" trots att inget i pluginet faktiskt pollade —
  `RunHDRMerge.lua` kördes bara manuellt från menyn (`Library → Plug-in
  Extras`). Ny `HDRMergeCore.lua` delas nu av `InitPlugin.lua` (startar en
  `LrTasks.startAsyncTask`-loop som kollar trigger-filen var 5:e sekund via
  `M.runOnce({showDialogIfMissing = false})`, `LrTasks.pcall`-skyddad per
  varv så en trasig trigger-fil inte dödar loopen) och `RunHDRMerge.lua`
  (kvar som manuell fallback/omedelbar koll — döpt om till "... (manuell
  koll)" i menyn för att göra rollfördelningen tydlig).
- **Riktig JSON-parsning**: den gamla regex-baserade `parseJSON` (letade
  efter bokstavliga `"group_id"`/`"files"`/`"output_dir"`-mönster med
  Lua-`%`-patterns) ersatt med en riktig liten recursive-descent
  JSON-avkodare (`HDRMergeCore.decodeJSON`/`parseTrigger` — objekt, array,
  sträng med alla standard-escape-sekvenser inklusive `\uXXXX`, tal,
  bool/null). Den gamla parsern skulle t.ex. misstolka en filsökväg som
  råkade innehålla texten `"files"` eller `"group_id"`; den nya klarar det
  eftersom den faktiskt förstår JSON-strukturen i stället för att mönstermatcha
  på nyckelnamn. Verifierat mot verklig, `.prettyPrinted`-formaterad
  trigger-JSON (så som `JSONSerialization` faktiskt skriver den) med en
  fristående Lua-interpreter under utvecklingen.
- **Gemensam bridge-mapp**: appen skrev tidigare till
  `NSTemporaryDirectory()`, pluginet läste från `LrPathUtils.
  getStandardFilePath("temp")` — två olika API:er som råkar peka på samma
  `$TMPDIR` på den här (osandboxade) maskinen, men utan någon garanti för
  det (olika startkontext/macOS-version kan ge olika processer olika
  `$TMPDIR`). Båda sidor använder nu `~/Library/Application Support/
  PhotoFlow` — samma mapp `BookingTitleParser` redan använder för sin
  cache (`booking_titles.json`) — för `lr_trigger.json`/`lr_status.json`/
  `lr_done.json`. `PipelineRunner.lightroomBridgeDirectory` (Swift) och
  `HDRMergeCore`s lokala `bridgeDir()` (Lua) måste hållas i exakt synk;
  det är dokumenterat med kommentarer i båda filerna.
- **Konfigurerbara väntetider**: GUI-scriptningen för själva
  HDR-sammanslagningen (väljer bilderna, Ctrl+H, väntar på
  förhandsvisningen, Enter — Lightroom SDK har fortfarande inget API för
  HDR-merge) är oförändrad i sak, men de fyra hårdkodade `sleep()`-tiderna
  (val-inställning, vänta på förhandsvisning, vänta på att sammanslagningen
  blir klar, paus mellan grupper) är nu `LrPrefs`-baserade
  (`M.selectSettleDelaySeconds()` m.fl. i `HDRMergeCore.lua`) i stället för
  magiska tal i koden, med tydlig `logger:trace`-loggning vid varje
  väntesteg (syns i Lightrooms egen logg,
  `~/Library/Application Support/Adobe/Lightroom/lrc_console.log`, tack
  vare `LrLogger:enable("print")`). En fullständig egen inställningsdialog
  (`sectionsForTopOfDialog` i Plug-in Manager) byggdes INTE — den går inte
  att öva in utan en riktig Lightroom-instans att klicka igenom, och att
  leverera oprövad `LrView`-dialogkod bedömdes mer riskfyllt än
  `LrPrefs`-värden med säkra standardvärden som ändå går att justera (redigera
  defaultvärdena i filen, eller sätta dem direkt via Lua-konsolen).

Ny Swift-test `PipelineRunnerLightroomTests` (bridge-mappens sökväg).
`Info.lua` uppdaterad (version 1.2.0, menytexten förtydligad).

### Manuell testning användaren bör göra

1. **Gallring → "markera"-läget**: kör en gallring, avsluta med ESC, öppna
   sedan adressmappen i Lightroom Classic (importera den om den inte redan
   finns i katalogen) och kontrollera att accepterade bilder har 3 stjärnor
   och avvisade visas som "Rejected" (svart flagga) i Lightrooms eget
   filter/attributfält — utan att någon fil flyttats eller raderats.
2. **Gallring → "flytta"/"radera"**: växla `cullAction` i Inställningar och
   kontrollera att "flytta" skapar `Gallrade`-undermappar med rätt filer,
   och att "radera" fortfarande visar bekräftelsedialogen och tar bort
   filerna permanent när man bekräftar.
3. **Ångra-stacken**: gör en blandning av manuella accept/avvisa och minst
   en "Föreslå gallring"-körning, tryck `z` flera gånger i rad och
   kontrollera att varje tryck återställer exakt ETT föregående steg (en
   bild i taget för manuella beslut, hela batchen på en gång för ett
   "Föreslå gallring"-tryck), samt att `⌘Z` gör samma sak.
4. **Kalender-Pickern**: öppna Inställningar → Pipeline med och utan
   tidigare beviljad kalenderåtkomst, kontrollera att rätt UI-läge visas
   (Picker / "Begär åtkomst" / fritext-fallback) och att en ny installation
   verkligen får "Alla kalendrar" som standard medan en uppgraderad
   installation behåller sitt gamla (implicita) kalenderval.
5. **Adressrättning + ompsortering**: kör en pipeline, låt filer sorteras,
   rätta sedan en adress i `AddressBanner` och bekräfta att "Sortera om
   filerna till den nya adressmappen"-bannern visas och att den faktiskt
   döper om mapparna på disk (och att nästa körning av "Skriv metadata"
   skriver den nya adressen till filerna).
6. **Filter/sortering i gallringen**: testa alla kombinationer av
   Visa-läge × Sorteringsordning, särskilt att ←/→ och nästa-bild-efter-
   beslut hoppar förbi dolda bilder på ett förnuftigt sätt.
7. **Lightroom-pluginet, riktig körning** (kunde inte testas i den här
   GUI-lösa, autonoma körningen): installera/uppdatera pluginet i
   Lightrooms Plug-in Manager, kör en riktig pipeline med bracket-grupper,
   tryck "Skicka till Lightroom" och bekräfta att HDR-sammanslagningen
   startar automatiskt inom ~5 sekunder UTAN att man behöver köra menyalternativet
   manuellt. Kontrollera `~/Library/Application Support/PhotoFlow/
   lr_trigger.json` försvinner och `lr_done.json` dyker upp, samt att
   `lrc_console.log` visar `[trace]`-rader från `PhotoFlowHDR`-loggern.

### Kvarstående / inte gjort i Fas 4

- Ingen egen Plug-in Manager-inställningsdialog för väntetiderna i
  Lightroom-pluginet (se avsnitt 5 ovan) — värdena är `LrPrefs`-baserade och
  justerbara, men bara genom att redigera defaultvärdena i
  `HDRMergeCore.lua` eller sätta dem via Lua-konsolen, inte via ett UI i
  Lightroom självt.
- Lightroom-pluginets faktiska beteende i en RIKTIG Lightroom-instans (den
  automatiska pollningen, GUI-scriptningens tajming mot en verklig
  HDR-sammanslagningsdialog, `require 'HDRMergeCore'` i Lightrooms egen
  Lua-runtime) kunde inte köras — bara verifierat så långt möjligt med en
  fristående `lua`-interpreter och mockade `LrXxx`-moduler (se
  sessionsintroduktionen ovan). Punkt 7 i "Manuell testning" täcker vad som
  bör kontrolleras med riktig Lightroom.
- "Föreslå gallring" (Fas 3b/3c) och dess kalibrering är oförändrad —
  filter/sortering (denna fas) och ångra-stacken (denna fas) bygger ovanpå
  den utan att ändra själva förslagslogiken.
- Ingen ny inställning för hur många ångra-poster som sparas (hårdkodat 50)
  — bedömdes inte behöva vara justerbart av användaren.

## Fas 3g – UI-genomgång med Liquid Glass

Utfört autonomt på branchen `forbattringar` medan användaren sov. Bakgrund:
i Xcode 27/macOS 26+ går det inte längre att välja bort Liquid Glass — appen
får designen automatiskt vid ombyggnad. Problemet var att flera vyer byggde
egna "toolbars" och flytande överlägg med `Color(nsColor:
.controlBackgroundColor)`/`.ultraThinMaterial`/solida färgbakgrunder och
egna knappstilar, vilket krockade visuellt med den nya designen (dubbla
material/glaskanter, hårda rutor ovanpå det nya systemglaset).

Alla nya API:er verifierades mot **`SwiftUI.swiftinterface`/
`SwiftUICore.swiftinterface`** i den installerade macOS 27-SDK:n innan de
användes (`grep` mot
`.../MacOSX.sdk/System/Library/Frameworks/SwiftUI{,Core}.framework/.../*.swiftinterface`)
— inga gissade signaturer. Bekräftat tillgängliga (alla `macOS 26.0+`, vilket
matchar appens deployment target):

- `View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = ...)`
  samt `Glass.regular`/`.clear`/`.identity`/`.tint(_:)`/`.interactive(_:)`
  (`SwiftUICore.swiftinterface`).
- `GlassEffectContainer<Content>` (grupperar flera glasformer för korrekt
  sammansmältning/kant-sampling).
- `PrimitiveButtonStyle.glass` / `GlassButtonStyle` (`SwiftUI.swiftinterface`).
- `ToolbarSpacer(_ sizing: SpacerSizing = .flexible, placement:)` — delar upp
  ett verktygsfält i separata glaskapslar (`.fixed`/`.flexible`).
- `ToolbarItem`/`ToolbarItemGroup`/`ToolbarItemPlacement` (`.navigation`,
  `.principal`, `.primaryAction`) fanns redan sedan tidigare macOS-versioner
  och användes för första gången i den här appen.

### 1. DashboardView: handbyggd topplist → riktiga verktygsfält

`DashboardView.topBar` (en `HStack` med egen `controlBackgroundColor`-
bakgrund) och granskningslägets tunna "Tillbaka"-list (samma mönster) är
ersatta med `.toolbar { ... }` på `DashboardView`s rotvy, med två separata
`@ToolbarContentBuilder`-vyer (`dashboardToolbarContent`/
`reviewToolbarContent`) som växlas beroende på `showReview` — exakt samma
funktioner som förut, bara som riktiga `ToolbarItem`/`ToolbarItemGroup`:

- Input-/output-mappval (med filnamn + NEF-antal) i en
  `ToolbarItemGroup(.navigation)`.
- Körstatus (`ProgressView` + stegtitel) i `.principal` när pipelinen körs.
- Pausa/Fortsätt, Auto (fortfarande `.borderedProminent` för att sticka ut
  som huvud-CTA), Bevaka i en `ToolbarItemGroup(.primaryAction)`, separerad
  med `ToolbarSpacer(.fixed, placement: .primaryAction)` från Logg-/
  Inställningar-gruppen.
- Granskningslägets Tillbaka-knapp/titel/statistik-piller/"Radera
  granskningsdata" är samma uppdelning (`.navigation`/`.principal`/
  `.primaryAction`); `alert`-modifieraren för raderingen ligger nu på
  `reviewContent`s rot i stället för på själva knappen.

`folderButton()` förenklad för toolbar-bruk — ingen egen
`RoundedRectangle`-bakgrund/kant längre (den gav annars en dubbel glasram
ovanpå verktygsfältets egen glaseffekt).

### 2. Glaseffekter på flytande överlägg

`.ultraThinMaterial`/solida färgbakgrunder ersatta med
`.glassEffect(_:in:)`/`GlassEffectContainer` på element som ligger ovanpå
bildinnehåll (INTE på strukturella paneler som `bottomStrip`s/`headerBar`s
egen `controlBackgroundColor`-bakgrund, som är kvar — de är inbäddade
paneler, inte flytande överlägg, och ändrades inte):

- **`CountdownOverlay`**: `.glassEffect(.regular.tint(.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 14))` i stället för `.ultraThinMaterial`
  (den orangea konturen är kvar som `.overlay`-kant).
- **`PreviewCullView`**: "Bra/Kassera/Ej granskad"-badgen
  (`verdictBadgeLarge`), "Föreslog X bilder"-bannern (`suggestionBanner`),
  bildinfolisten i botten (`photoInfoBar`) och hela knapp-/filmremsraden i
  fullskärmsläget (`fullscreenBottomBar`) är glaseffekter. De stora
  symbolknapparna (`symbolButton`/`fsSymbol`, medvetet stora för snabb
  tangentbords-/musgallring — **oförändrad storlek**) och dikteringsknappen
  (`dictationButton`/`dictationButtonFS`) använder `.buttonStyle(.glass)` i
  stället för `.plain`, grupperade i `GlassEffectContainer` för korrekt
  sammansmältning mellan intilliggande glasformer.
- **`BracketReviewView`**: "HDR-sammanslagning"/motor-etiketterna,
  "Visa HDR (H)"-knappen (nu `.buttonStyle(.glass).tint(.orange)` i stället
  för en manuell `Color.orange.opacity(0.85)`-bakgrund) och de tre
  statusbadgarna (Algoritmens val/Ditt val/Avvisad) är glaseffekter i
  stället för solida färgade rutor.

Mörk tining (`.black.opacity(0.25...0.35)`) lades på botten-/infolisterna
som ligger direkt ovanpå fotot (`photoInfoBar`, `fullscreenBottomBar`) —
`.regular`-glas antar annars fel kontrast om fotot eller ljust/mörkt läge
råkar göra glaset för ljust för den vita texten ovanpå. Se kommentarer i
koden.

### 3. Bildvisning i fullskärmsgallringen

`ProgressiveImageView` i `PreviewCullView.fullscreenView` fick ett explicit
`.frame(maxWidth: .infinity, maxHeight: .infinity)` + `.ignoresSafeArea()`
i stället för att förlita sig på `ZStack`ens implicita storleksförslag —
den svarta bakgrunden (`Color.black.ignoresSafeArea()`, redan fanns)
letterboxar det som fotots egen bildproportion inte täcker, så de flytande
glas-overlägen (topplist, verdict-badge, knapprad) alltid ligger ovanpå
antingen svart eller foto, aldrig mot en hård kant.

### 4. Kontroller/knappstilar

Genomsökt `DashboardView`/`PreviewCullView`/`BracketReviewView`/
`CountdownOverlay` efter `Button`+manuell bakgrund. De återstående (efter
punkt 2 ovan) använder redan standardstilar (`.bordered`,
`.borderedProminent`) sedan tidigare faser — inget mer att byta där.

### 5. Mörkt/ljust läge — INTE visuellt verifierat

**Kunde inte skärmbildsverifieras den här körningen**: skärmen var låst
(`CGSSessionScreenIsLocked=Yes` via `ioreg -n Root -d1`) under hela
sessionen — troligen skärmsläckare/låsning eftersom användaren sover.
`screencapture` gav bara svarta bilder (macOS blockerar avsiktligt
skärmdumpar av låsskärmen), och det finns inget lösenord tillgängligt att
låsa upp med (och det vore inte lämpligt att försöka). Appen kunde
fortfarande byggas och köras (processen startade), men UI:t kunde inte
faktiskt ses eller fotograferas — så **`AppleInterfaceStyle` ändrades
aldrig** (lästes bara: var `Dark` från början, oförändrat).

Verifiering gjordes i stället genom kodgranskning av färgkontrast:

- Alla nya `glassEffect`-tintningar använder antingen en stark färgad
  tint (grön/röd/orange/blå vid 0.8–0.85 opacitet) eller en mörk tint
  (svart vid 0.25–0.5) bakom vit text — båda dominerar tillräckligt över
  `Glass.regular`s adaptiva ljus/mörk-bastoning för att vit text ska
  förbli läsbar oavsett systemläge eller hur ljust/mörkt fotot bakom
  råkar vara.
- `CountdownOverlay` använder `.primary`/`.secondary` textfärger (redan
  adaptiva) på en lätt tintad (`15%` orange) `.regular`-glas, samma
  mönster som `.ultraThinMaterial` hade innan — ingen ny kontrastrisk.

**Användaren bör göra en snabb visuell koll i både ljust och mörkt läge**
(`Systeminställningar → Utseende`, eller `defaults write -g
AppleInterfaceStyle Dark`/`defaults delete -g AppleInterfaceStyle` +
omstart av appen) av: verktygsfältet i `DashboardView` (båda lägena),
`CountdownOverlay` (kräver en pågående röstmeddelande-nedräkning),
gallringens fullskärmsläge (`f`-tangenten), och bracket-granskningens
HDR-etiketter — särskilt att ingen vit text hamnar på ett för ljust glas i
ljust läge.

### Kvarstående / inte gjort i Fas 3g

- Inga skärmbilder kunde tas (se punkt 5) — all verifiering är bygge
  (`xcodebuild build`), alla 141 tester (`xcodebuild test`) och manuell
  SDK-verifiering av varje ny API-signatur, inte visuell inspektion.
- `StepCardView`, `SettingsView`, `DictationPanelView` och
  `LocalImageView`s "RAW"-badge har kvar sina
  `controlBackgroundColor`/`ultraThinMaterial`-bakgrunder — de är
  strukturella inbäddade paneler/kort (inte flytande överlägg ovanpå
  bildinnehåll) och låg utanför den här fasens uttryckliga scope
  (DashboardView, CountdownOverlay, PreviewCullView, BracketReviewView).
  Kan vara värt en egen genomgång i en senare fas om de känns
  inkonsekventa mot resten av appen i praktiken.
- `ToolbarItemGroup(.navigation)`s två mappknappar visas nu utan den
  gamla `chevron.right`-pilen mellan dem (verktygsfältets egen gruppering
  gör pilen överflödig) — en liten visuell ändring, inte en
  funktionsförlust.

## Fas 3f – App Intents, Genvägar och Spotlight

Utfört autonomt på branchen `forbattringar` medan användaren sov. Bakgrund:
appbygget varnade sedan tidigare "Metadata extraction skipped, no
AppIntents.framework dependency found" — PhotoFlow hade ingen App
Intents-integration alls. Alla nya API:er (`AppIntents`-modulen: `AppIntent`,
`AppEntity`, `IndexedEntity`, `EntityQuery`/`EnumerableEntityQuery`,
`AppShortcutsProvider`, `IntentFile`, `CSSearchableIndex.indexAppEntities`)
verifierades mot **`AppIntents.swiftinterface`** i den installerade
macOS 27-SDK:n (`arm64e-apple-macos.swiftinterface`) innan de användes —
inga gissade signaturer.

### 1. Fyra grundläggande intents (`PhotoFlow/Sources/Intents/`)

- **`StartPipelineIntent`** ("Bearbeta bilder med PhotoFlow"):
  `@Parameter var folder: IntentFile?` med `supportedContentTypes: [.folder]`
  (en mappväljare i Genvägar/Siri, inte en filväljare) — standard när inget
  valts är `AppSettings.shared.inputDirectory`. `openAppWhenRun = true`
  (pipelinen körs i huvudappens process — det finns ingen separat App
  Intents-extension i det här projektet, se punkt 4).
- **`ToggleWatchIntent`** ("Starta/stoppa PhotoFlow-bevakning"): växlar
  `RunnerWrapper.watcher.isWatching`. Ingen `openAppWhenRun` (default
  `false`) — om appen redan kör (huvudfönster ELLER bara menyradsläge från
  Fas 3e) växlas bevakningen utan att tvinga fram/aktivera något fönster.
- **`SessionStatusIntent`** ("Status för PhotoFlow"): `IntentResult &
  ProvidesDialog` med svensk dialog — aktuellt steg (`PipelineState
  .currentStep.title`), antal bilder, antal ogranskade
  (`!accepted && !rejected`) och senaste matchade adress
  (`matchedAddress`).
- **`ShowReviewIntent`** ("Granska bilder i PhotoFlow"): återanvänder EXAKT
  samma mekanism som notisknappen "Granska nu" från Fas 3e — sätter
  `PipelineState.reviewRequestedFromNotification = true`, som
  `DashboardView` redan observerar för att växla till granskningsvyn. Ingen
  ny koppling till vyerna behövdes.

Alla fyra svarar med en tydlig svensk dialog ("PhotoFlow är inte igång.")
i stället för att krascha eller tyst misslyckas om appen inte kör (se
punkt 3).

### 2. `AddressSessionEntity` + `FindSessionsIntent` + Spotlight-indexering

`AddressSessionEntity` (adress, bokningstitel, datum, antal bilder, antal
godkända) läses av `AddressSessionLoader` ur den **aktuella outputmappens**
`calendar_matches.json` (adresser + datumintervall), `bracket_groups.json`
(per-foto capture-tid, för att räkna antal bilder per adressintervall) och
`cull_decisions.json` (för att räkna godkända — samma `"\(groupId)_
\(filename)"`-nyckelformat som `PipelineRunner+LoadSession` redan bygger
`photoId` med).

**Viktig begränsning, medvetet vald**: PhotoFlow har inget begrepp om
sessionshistorik — en outputmapp motsvarar en körning, och en ny körning i
SAMMA mapp skriver över `calendar_matches.json`. `AddressSessionLoader` kan
därför bara återspegla SENASTE sessionen i den mapp som just nu är
konfigurerad (`AppSettings.shared.outputDirectory`), inte flera veckors
historik över olika mappar. En riktig sessionshistorik (t.ex. en lista över
tidigare outputmappar med tidsstämpel) fanns inte i någon tidigare fas och
byggdes inte i den här — bedömdes vara för stor en förändring för att göra
"i förbifarten" i en fas om App Intents. Dokumenterat under "Kvarstående"
nedan.

`AddressSessionQuery` konformar till `EnumerableEntityQuery` (så både
`FindSessionsIntent` och Spotlight-indexeringen kan lista ALLA sessioner,
inte bara slå upp kända id:n) och `AddressSessionEntity` konformar till
`IndexedEntity` (macOS 15+, verifierat i SDK:n — appens deployment target
är macOS 26 så det är alltid tillgängligt). `AddressSessionQuery
.allEntities()` anropar `CSSearchableIndex.default()
.indexAppEntities(sessions)` (best-effort, `try?` — ett indexeringsfel ska
aldrig hindra att sessionerna ändå returneras) varje gång den körs, med
standardimplementationen av `attributeSet` (titel/undertitel från
`displayRepresentation`) — ingen handbyggd `CSSearchableItemAttributeSet`,
bedömdes vara "enkelt nog" enligt uppdragets kriterium utan att behöva bygga
en egen attributmappning.

### 3. `AppServices` — koppling till appens delade tillstånd

Ny `@MainActor final class AppServices` (singleton) med `weak var pipeline:
PipelineState?`/`weak var runner: RunnerWrapper?`. `PhotoFlowApp
.startupChecks()` registrerar sig där (`AppServices.shared.register
(pipeline:runner:)`) — INTE direkt i `body` som ett bart statement: ett
void-returnerande funktionsanrop mitt i `WindowGroup`s `@SceneBuilder`
gav `error: type '()' cannot conform to 'Scene'` (SceneBuilder tolkar varje
statement som en komponent, till skillnad från vanlig kod). `.task`-blocket
körs gott om i tid — inget intent förväntas köras innan fönstret ens hunnit
visas en första gång.

Referenserna är `weak` av två skäl: dels äger `PhotoFlowApp` originalen
redan via `@StateObject`, dels ska ett intent som råkar köras efter att
appen avslutats aldrig kunna hålla appens objekt vid liv i onödan. Om appen
inte kör alls (kallt anrop via Spotlight/Siri) är båda `nil` — intents utan
`openAppWhenRun` hanterar det med en tydlig dialog i stället för att krascha.

### 4. `PhotoFlowShortcuts` (`AppShortcutsProvider`)

Svenska fraser för alla fem intents (`\(.applicationName)`-token ersätts av
systemet med appens visningsnamn, "PhotoFlow") — t.ex. "Bearbeta bilder med
PhotoFlow", "Starta PhotoFlow-bevakning", "Status för PhotoFlow", "Granska
bilder i PhotoFlow", "Hitta sessioner i PhotoFlow". Ingen egen konfiguration
behövs — `AppShortcutsProvider` gör dem sökbara i Genvägar/Spotlight/Siri
automatiskt.

### 5. `project.yml`: länkad `AppIntents.framework`-dependency

Lade till `dependencies: [{sdk: AppIntents.framework}]` på `PhotoFlow`-
targetet. Utan en riktig LÄNKNINGS-dependency (bara `import AppIntents` i
koden räcker inte) hoppar Xcodes build-system över hela
App Intents-metadataextraktionen — det var precis det den ursprungliga
varningen ("Metadata extraction skipped, no AppIntents.framework dependency
found") beskrev. `xcodegen generate` kördes och `.xcodeproj` committades.

**Verifierat efter ändringen**: `xcodebuild build`-loggen visar nu ett
`ExtractAppIntentsMetadata`-byggsteg (`appintentsmetadataprocessor`) i
stället för att hoppa över det, och:

```
ls PhotoFlow.app/Contents/Resources | grep -i appintents
# Metadata.appintents

ls PhotoFlow.app/Contents/Resources/Metadata.appintents
# version.json  extract.actionsdata
```

`extract.actionsdata` (JSON) verifierades innehålla alla fem intents under
`"actions"` (`StartPipelineIntent`, `ToggleWatchIntent`,
`SessionStatusIntent`, `ShowReviewIntent`, `FindSessionsIntent`), entiteten
under `"entities"` (`AddressSessionEntity`) och frågan under `"queries"`
(`AddressSessionQuery`), samt de svenska frastemplaten (`"Bearbeta bilder
med ${applicationName}"` osv.) under `"autoShortcuts"`.

### 6. Swift 6-fälla: `static var` på `AppIntent`/`AppEntity`-krav under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`

Alla nya typer gav till en början byggfel av typen:

```
error: static property 'title' is not concurrency-safe because it is
nonisolated global shared mutable state [#MutableGlobalVariable]
```

för varje `static var title/description/typeDisplayRepresentation
/defaultQuery/openAppWhenRun` som implementerade ett `AppIntent`/
`AppEntity`-protokollkrav. Orsak: `AppIntents`-protokollens statiska krav
är `nonisolated` (de måste vara läsbara från vilken körningskontext som
helst, inte bara huvudtråden) — men det här projektets `SWIFT_DEFAULT_ACTOR
_ISOLATION: MainActor`-inställning (Fas 2b) gör alla egna typer
huvudtråd-isolerade som standard om inget annat anges. En MUTERBAR
(`var`) statisk property som "råkar" hamna på huvudtråden kan då inte bevisa
att den är säker att läsa från ett icke-isolerat sammanhang. **Fix**: byt
`static var` → `static let` överallt (alla protokollkraven är `{ get }`,
aldrig `{ get set }`) — en immutabel konstant behöver ingen
isolerings-bevisning. Ingen funktionell skillnad, bara en syntaxändring.
Läxa för framtida App Intents-kod i det här projektet.

### 7. Verifiering utan GUI

Kunde INTE klicka i Genvägar-appen eller Spotlight (ingen GUI-interaktion
möjlig den här autonoma körningen). Testat och verifierat via
kommandorad/loggar i stället, enligt uppdragets instruktion — pipelinen och
bevakningen startades ALDRIG (bekräftat: `DashboardView.toggleWatchMode`/
`startPipeline` är de enda ställena som anropar `startWatchingForSDCards`/
kör pipelinen, och ingendera nås bara av att appen startar):

- **Bygg**: `Metadata.appintents/extract.actionsdata` innehåller allt
  förväntat (se punkt 5).
- **`open -n PhotoFlow.app` + `pkill -x PhotoFlow`**: appen startades en
  gång och avslutades igen utan att röra några användarmappar. `log show
  --predicate 'eventMessage contains "photoflow"'` visar att
  `com.apple.appintents:IndexCoordinator`/`linkd` faktiskt reagerar på
  appstarten (`"Looking for bundle: com.photoflow.app"`,
  `"Requesting new set donation <AppIntentsIndexedEntity
  :sourceIdentifier=com.photoflow.app...>"`), dvs. systemets
  AppIntents-indexering känner av appen.
- **`linkd` avvisar klienten**: samma logg visar `"Failed to generate
  bundleIdentity"` / `"Rejecting invalid client due to
  requiresValidatedBundle"` när appen försöker registrera sig för
  auto-shortcuts-donation. Det här är EN KÄND begränsning för en
  ad-hoc-signerad utvecklarbuild som körs direkt från en scratch-
  `DerivedData`-mapp (inte installerad i `/Applications`,
  `CODE_SIGN_IDENTITY: "-"` i `project.yml`) — `requiresValidatedBundle`
  kräver en riktigt signerad/registrerad app. Med andra ord: metadatan
  extraheras och paketeras korrekt (bekräftat), men Siri/Spotlight-
  DONATIONEN (att fraserna faktiskt dyker upp som körbara förslag) kunde
  INTE verifieras end-to-end i den här miljön.
- **`shortcuts list`**: visar bara redan sparade genvägar i Genvägar-appen,
  inte `AppShortcutsProvider`s automatiskt donerade "App Shortcuts" (de är
  en annan mekanism — indexerade av Siri/Spotlight, inte listade av CLI:t).
  Ingen PhotoFlow-post förväntades här och ingen syntes.
- **`pluginkit -m`**: ingen PhotoFlow-post, som förväntat — appen har ingen
  separat App Intents-EXTENSION (`AppIntentsExtension`), alla intents körs
  hostade i huvudapp-processen (samma mönster som `openAppWhenRun`-
  kommentarerna i koden beskriver), vilket inte kräver en egen
  `pluginkit`-registrering.

### Manuell testning användaren bör göra

1. **Genvägar-appen**: öppna Genvägar → Appar → PhotoFlow (efter att ha
   byggt/kört en riktigt signerad version, inte en ad-hoc-build) och
   bekräfta att alla fem App Shortcuts syns med rätt svenska titlar/ikoner.
2. **Siri/Spotlight**: säg eller skriv en av fraserna ("Bearbeta bilder med
   PhotoFlow", "Status för PhotoFlow" osv.) och bekräfta att rätt intent
   körs och ger rätt svensk dialog.
3. **`StartPipelineIntent` med mappval**: kör genvägen med en riktig NEF-
   mapp vald i mappväljaren och bekräfta att PhotoFlow öppnas och pipelinen
   startar mot RÄTT mapp (inte bara standardmappen).
4. **`ToggleWatchIntent` i bakgrunden**: med PhotoFlow körande bara i
   menyradsläge (huvudfönster stängt), kör genvägen och bekräfta att
   bevakningen växlar utan att huvudfönstret plötsligt öppnas.
5. **`FindSessionsIntent`/Spotlight**: kör en riktig session med
   kalendermatchning, sök sedan på adressen i Spotlight och bekräfta att
   sessionen dyker upp (kräver en korrekt signerad/registrerad build, se
   punkt 7 ovan).

### Kvarstående / inte gjort i Fas 3f

- **Ingen riktig sessionshistorik** — `AddressSessionEntity` ser bara den
  SENASTE körningen i den just nu konfigurerade outputmappen (se punkt 2).
  Att bygga en riktig historik (t.ex. en lista över tidigare körningars
  outputmappar, med tidsstämpel) är en större förändring som inte fanns i
  någon tidigare fas och bedömdes ligga utanför den här fasens scope.
- **End-to-end Siri/Spotlight-donation kunde inte verifieras** i den här
  miljön (ad-hoc-signerad build, `requiresValidatedBundle` avvisar den, se
  punkt 7) — bara att metadatan extraheras och paketeras korrekt.
  Användaren bör verifiera med en riktigt signerad build (punkt 1–2 i
  "Manuell testning").
- Ingen ny inställning för att stänga av App Intents/Genvägar — bedömdes
  inte nödvändigt: intents ändrar bara beteende när användaren AKTIVT kör
  dem (via Genvägar/Siri/Spotlight), till skillnad från t.ex. bakgrunds-
  bevakning eller notiser som kör kontinuerligt/automatiskt. De omfattas
  därför inte av regeln om avstängningsbara pipeline-beteenden.
- `ToggleWatchIntent`/`SessionStatusIntent`/`ShowReviewIntent` har inga
  egna enhetstester (de är tunna wrappers runt redan testad logik i
  `RunnerWrapper`/`PipelineState` — se Fas 3e:s tester för den underliggande
  bevaknings-/state-logiken, och `perform()` kräver en riktig `AppIntent`-
  körningskontext som inte går att skapa i ett enhetstest). Kärnlogiken i
  `AddressSessionLoader` (den delen som FAKTISKT kan testas utan GUI/utan
  App Intents-runtimen) fick egna tester i stället:
  `AddressSessionLoaderTests.swift` — en `loadSessions(outputDir:)`-variant
  bröts ut från `loadCurrentSessions()` (som fortfarande läser
  `AppSettings.shared.outputDirectory`) just för att göra det möjligt, med
  syntetiska `calendar_matches.json`/`bracket_groups.json`/
  `cull_decisions.json`-filer i en tillfällig mapp (tom outputmapp, en
  adress med bilder både inom och utanför datumintervallet, flera adresser,
  och en trasig post utan `range_start`/`range_end`).

## Slutgranskning

Utförd autonomt på branchen `forbattringar` medan användaren sov, efter ~67
tidigare commits (`git diff --stat e3be8d0 HEAD`: 105 filer, +15k/-4.7k).
Mål: säkerställa att inget i pipelinen kan förstöra eller läcka användarens
originalbilder, och rök-testa hela pipelinen mot riktig NEF-data i en kopia.
161 tester totalt efter denna fas, alla gröna.

### Del 1 — Granskning av alla destruktiva filsystemanrop

Gick igenom varje `removeItem`/`moveItem`/`createSymbolicLink`/
`overwrite_original`-anrop i `PhotoFlow/Sources` (grep-baserad, se
commit `40c3d71` för den fullständiga listan). Sammanfattning:

**Redan säkert (verifierat, ingen ändring):**
- NEF-original skrivs ALDRIG direkt — `exiftoolArguments`/
  `cullExiftoolArguments` (Metadata/Culling) skriver alltid en XMP-sidecar
  bredvid NEF-symlänken i stället, exakt som Fas 1a etablerade.
- Basnamnsmatchning i gallringsfunktionerna är exakt strängjämförelse på
  `deletingPathExtension().lastPathComponent`, aldrig ett prefix/contains-
  test — `"DSC_0001"` matchar aldrig `"DSC_00011.NEF"` (basnamn
  `"DSC_00011"`). Detta var redan korrekt innan denna fas.
- `PipelineRunner.rerunStep`/HDR-/Lightroom-hjälparnas `removeItem`-anrop
  rör bara fasta, appdefinierade filnamn direkt under `outputDir`
  (`bracket_groups.json`, `hdr/`, `metadata_written.json`, m.fl.) —
  aldrig något härlett från adress- eller filnamnssträngar.
- `PipelineRunner+AddressCorrection.swift`s mappomdöpning byggde redan
  bara på `AddressFolderLayout`s tre fasta undermappnamn direkt under
  `outputDir`.

**Två faktiska brister hittade och fixade (minsta möjliga ändring):**

1. **Path-traversal-risk i `CalendarService.sanitizeFolderName`**
   (`PhotoFlow/Sources/Services/CalendarService.swift`). Adressmappnamnet
   för DNG-mappen används OSKYDDAT (inget suffix, se
   `AddressFolderLayout.dngDirName`). Om en kalenderhändelses titel någon
   gång extraherades/trimmades ner till exakt `".."`, `"."` eller `""` —
   inte troligt men inte omöjligt med udda formulerade händelsetitlar —
   skulle `outputDir.appendingPathComponent(adress)` bli en sökväg som
   OS:et (mkdir/rename/readdir, inte bara Foundations `URL`-typ lexikalt)
   löser upp som outputDirs FÖRÄLDER eller outputDir självt. Alla
   filoperationer för den "adressen" (symlänkar, metadataskrivning,
   gallring) hade då kunnat träffa fel mapp. Samma sanering används även
   för användarens EGEN manuellt inskrivna adressrättning
   (`resortAddressFolder`), så detta gällde både kalenderdata och
   användarinmatning. Fix: saneringen faller nu tillbaka på
   `"Okänd adress"` för dessa tre farliga resultat.
2. **Gallring kunde träffa en främmande fil med samma basnamn**
   (`deleteRejectedFiles`/`moveRejectedToFolder`/`writeCullRatings` i
   `PipelineRunner+SortFolders.swift`/`+Culling.swift`). Matchningen var
   redan exakt på basnamn, men brydde sig inte om filen faktiskt var en
   symlänk/sidecar appen skapat — en användare som av misstag lade en egen
   fil (t.ex. en redigerad `.psd`) med samma basnamn som en gallrad bild i
   `"<adress> ÖVRIGA"` hade fått den filen raderad/flyttad/omtaggad. Fix:
   alla tre funktionerna kräver nu att filen antingen är en symlänk appen
   skapat eller en `.xmp`-sidecar appen skrivit.
3. **(Hittades under förberedelserna för Del 2, samma andetag)** HDR-resultat
   (`hdr_group_N.tiff`/`.jpg`) föll INTE tillbaka på `"Osorterade"` som
   alla andra filtyper i `exportToAddressFolders`, utan `continue`:ade
   (hoppade över) gruppen helt om det inte fanns en kalendermatchning. En
   session utan kalendermatchning (ingen kalenderåtkomst, eller inget
   event som täcker fototillfället) tappade därmed sina HDR-resultat
   PERMANENT i `outputDir/hdr/` — de flyttades aldrig till någon adressmapp
   och syntes aldrig i Lightroom/Finder. Detta är inte en säkerhetsbrist
   (rör inget utanför outputDir) men är ett verkligt dataförlust-artat
   beteendefel, så det fixades i samma anda: samma `?? "Osorterade"`-
   fallback som redan fanns för NEF/DNG/preview.

**Ny central skyddsfunktion** `PhotoFlow/Sources/Services/FileSafety.swift`:
- `assertInsideOutput(_:outputDir:)` — kastar (loggas, sväljs inte tyst) om
  en sökväg, efter lexikal normalisering av `.`/`..`, inte ligger inuti
  `outputDir`. Används av `resortAddressFolder` och det nya
  `PipelineRunner.cullCandidates` (delad av `deleteRejectedFiles`/
  `moveRejectedToFolder`) som defense-in-depth ovanpå
  `sanitizeFolderName`-fixen.
- `isCullManaged(_:)`/`isSymlink(_:)` — "är den här filen vår att
  radera/flytta/ratingmärka" (symlänk ELLER `.xmp`-sidecar).

**Nya tester** (se `PhotoFlow/Tests/`): `FileSafetyTests` (`..`-eskapering,
en syskonmapp med gemensamt strängprefix som INTE ska räknas som "inuti",
`isSymlink`/`isCullManaged`), `PipelineRunnerCullSafetyTests` (en riktig
temp-katalog med exakt uppgiftens fällor: `DSC_00011.NEF` vs `DSC_0001`, en
främmande `.psd` med samma basnamn, en mapp utanför `outputDir`),
`PipelineRunnerHDROrphanTests` (HDR-fallbacken), samt fyra nya
`sanitizeFolderName`-edge-case-tester i `CalendarServiceTests`. Se commit
`40c3d71` och `e6f5b0c`-liknande efterföljande commits för exakta diffar.

### Del 2 — Rök-test av hela pipelinen på riktig data

**Data:** 35 riktiga NEF (Nikon, 7 exponeringsbrackets om 5 bilder vardera,
verifierat med `exiftool` att exponeringstiderna faktiskt varierar per
bracket, t.ex. 1/6s–1.6s) kopierade — ALDRIG flyttade — från
`~/Desktop/ptohotagraphy-test/Exempelgatan 7/` (samma riktiga testmapp Fas 2a
redan använde) till scratchpad `SMOKE/input/`. Källfilerna i
`~/Desktop/ptohotagraphy-test/` rördes aldrig (bara `cp -p`).

**Testet:** `PhotoFlow/Tests/PipelineSmokeTest.swift`, opt-in (av som
standard — se dok-kommentaren i filen). Miljövariabler når INTE alltid
testprocessen via `xcodebuild test` (verifierat: en `export`ad variabel i
det anropande skalet syns inte i `ProcessInfo.processInfo.environment`
inuti testvärden), så testet styrs i stället av en styrfil,
`~/Library/Application Support/PhotoFlow/smoke_test.json`
(`{"enabled": true, "inputPath": "...", "keepOutput": true}`), med
miljövariabler (`PHOTOFLOW_SMOKE`/`_INPUT`/`_KEEP_OUTPUT`) som fallback om
de mot förmodan når fram. Kör den RIKTIGA `PipelineRunner`-koden (ingen
mock): kalendermatchning AV (ingen EventKit-åtkomst behövs), AI-taggning
och HDR (Core Image-motorn) PÅ. Snapshottar/återställer varje
`AppSettings`-inställning den rör, eftersom testvärden delar riktig
`UserDefaults` med appen (`TEST_HOST`).

**Resultat: testet kunde INTE köras klart — se "Känd bugg" nedan.** Det som
gick att verifiera innan avbrottet:

- **Källfilerna är bit-identiska**: `md5` av alla 35 NEF i `SMOKE/input`
  före körningen jämfört med efter (efter att den hängda körningen
  avbröts) — **exakt identiska, 0 skillnader** (`diff` mellan de två
  md5-listorna är tom). Detta är den viktigaste kontrollen i hela
  röktestet och den klarades.
- **DNG-konvertering**: alla 35 DNG-filer skapades korrekt av Adobe DNG
  Converter (`8280×5520`, 42–51 MB, giltiga enligt `exiftool`) i
  `outputDir/dng/` innan pipelinen fastnade i nästa steg.
- Inget annat pipeline-steg (bracket-analys, previews, HDR, metadata,
  filsortering) hann köras — se känd bugg.

**Känd bugg: DNG-konverteringssteget hänger i `Process.waitUntilExit()`
när pipelinen körs via `xcodebuild test`.**

Reproduktion: `PipelineRunner.runDNGConversion` anropar Adobe DNG Converter
via `ProcessRunner.runProcess` (temp-filer för stdout/stderr, inga pipes —
redan skyddat mot det klassiska pipe-buffer-dödläget). `pipeline.log` visar
att steget startade, och alla 35 `.dng`-filer skrevs korrekt till disk inom
någon sekund — men `process.waitUntilExit()` returnerade aldrig,
pipelinen satt fast i **3,5+ minuter** tills körningen avbröts manuellt
(`kill` på `xcodebuild`-processen).

Isolerad felsökning (i scratchpad, inte i appen):
- Samma Adobe DNG Converter-anrop direkt från ett Python-`subprocess`
  (kommandoradsprocess, INTE testvärdad): **0,35 s**, exit-kod 0.
- Samma anrop via ren `Foundation.Process` i ett fristående Swift-skript
  (`xcrun swift script.swift`, INTE testvärdat av Xcode): alla 35 filer på
  **5,4 s**, `waitUntilExit()` returnerade normalt, exit-kod 0.
- Samma anrop, samma kod, samma binär — men INUTI `PhotoFlow.app` när det
  körs som testvärd under `xcodebuild test`: hänger.

Slutsats: detta är inte en bugg i `ProcessRunner`/`PipelineRunner` (samma
`Process`-anrop fungerar perfekt utanför en Xcode-testvärd-kontext), utan
troligen en interaktion mellan Xcodes testrunner/debugger och hur en
testvärdad apps barnprocesser (särskilt en tung GUI-app som Adobe DNG
Converter) reapas. Inte verifierat om det förekommer i den RIKTIGA,
normalt startade appen (dubbelklickad, inte körd under `xcodebuild test`)
— tidigare fasers manuella testanteckningar antar att DNG-konvertering
fungerar där, och inget i denna fas motsäger det. Dokumenterat i
`PipelineSmokeTest.swift`s dok-kommentar så nästa person som kör testet
känner igen symtomet direkt i stället för att tro att pipelinen är trasig.
Ingen kodändring gjord i `ProcessRunner`/`PipelineRunner` för detta — att
lägga till en timeout/watchdog utan att kunna reproducera roten riskerade
att maskera en riktig framtida hängning i stället för att fixa en, så det
lämnas som dokumenterad begränsning snarare än en gissad fix.

**Ej verifierat på grund av avbrottet** (kräver att någon kör om testet,
gärna via Xcodes Test Navigator i stället för `xcodebuild test` på
kommandoraden, se ovan): previews, `bracket_groups.json`, symlänkar i
adressmappar, HDR-TIFF 16-bitars, IPTC/XMP-metadataskrivning, XMP-sidecar
för NEF. Koden för samtliga dessa steg oförändrad av denna fas (förutom
HDR-Osorterade-fixen i Del 1), och tidigare fasers egna verifieringar
(Fas 2a/3a i detta dokument) har redan testat bracket-analys respektive
HDR-motorn separat mot riktig data — bara den FULLA kedjan i ett enda
`xcodebuild test`-kört svep kunde inte verifieras här.

### Del 3 — Att testa manuellt i appen (prioriterat, viktigast först)

1. **Kör hela pipelinen på en riktig SD-kortsmapp i den RIKTIGA appen**
   (inte via testet) och kontrollera att den går igenom alla steg utan att
   hänga — särskilt DNG-konverteringssteget (se känd bugg ovan). Om den
   RIKTIGA appen också hänger där är det allvarligt och inte bara ett
   testartefakt — rapportera i så fall vad som visas i förloppsindikatorn
   och `~/Library/Logs/PhotoFlow/photoflow.log`.
2. **HDR utan kalenderåtkomst/kalendermatchning**: kör en session med
   `AppSettings.calendarMatchEnabled = false` (eller neka
   kalenderbehörighet) och HDR påslaget, med minst en bracket-serie.
   Kontrollera att `hdr_group_*.tiff/.jpg` hamnar i
   `"Osorterade ÖVRIGA"`/`"Osorterade TITTBILDER"` — INTE kvar i
   `outputDir/hdr/` (Del 1, punkt 3-fixen).
3. **Adressrättning med en udda kalenderhändelsetitel**: testa att rätta
   en adress till något kort/konstigt (t.ex. bara mellanslag, eller en
   enda punkt) i adressbanderollen och kontrollera att det INTE skapar
   eller flyttar något utanför outputmappen — `sanitizeFolderName` ska ge
   `"Okänd adress"` i stället för att krascha eller göra något oväntat.
4. **Gallring ("radera"/"flytta"-läget) med en extra fil i adressmappen**:
   lägg manuellt en egen fil (t.ex. en `.psd`) med SAMMA basnamn som en
   NEF i en `"<adress> ÖVRIGA"`-mapp, avvisa den bilden, och kör
   gallringen. Kontrollera att din egna fil FINNS KVAR (inte raderad/
   flyttad) — bara symlänken och ev. `.xmp`-sidecar ska rensas.
5. **Symlänkar intakta efter en full körning**:
   `find <outputmapp> -name "*.NEF" ! -type l` ska ge tom output (inga
   NEF ska någonsin bli vanliga kopior).
6. **XMP-sidecar + IPTC/GPS på en riktig session** med kalendermatchning
   PÅ: kontrollera med `exiftool -G1 -a <fil>.xmp` att adress/GPS ser
   rimliga ut, och att DNG/preview-filer har samma adress i IPTC-fälten.
7. **HDR-TIFF är 16-bitars**: `exiftool -BitsPerSample <hdr-fil>.tiff` på
   en riktig HDR-sammanslagning.
8. **Avbryt mitt i DNG-konvertering** i den riktiga appen (inte testet) —
   kontrollera att "Avbryt" faktiskt dödar Adobe DNG Converter-processen
   (`ps aux | grep -i "dng converter"`) och inte bara fryser UI:t.
9. **Kör om en befintlig session** som redan har `metadata_written.json`/
   `files_sorted.json` från FÖRE denna fas — kontrollera att inget i Del 1s
   fixar (särskilt `sanitizeFolderName`) ändrar mappnamn för adresser som
   redan sorterats (samma adress ska sanera till samma mappnamn som förut,
   om den inte var en av de tre farliga specialfallen).
10. **Bevakningsläge (WatchService) + hela pipelinen** end-to-end med ett
    riktigt SD-kort, för att se om DNG-hänget (känd bugg) är specifikt för
    `xcodebuild test`-kontexten eller om det på något vis även kan uppstå
    i normal, dubbelklickad appdrift.

### Kända begränsningar / nästa steg

- **DNG-konverteringshänget under `xcodebuild test`** (se Del 2) är den
  viktigaste kvarstående frågan från den här fasen — oklart om det bara är
  ett testverktygsartefakt eller pekar på något som kan drabba riktiga
  användare under vissa omständigheter (t.ex. om appen någon gång körs
  under en debugger, eller i en annan ovanlig processkontext). Ingen
  reproduktion hittades i normal, fristående processkörning.
- Rök-testet kunde inte verifiera preview-generering, bracket-gruppering,
  HDR-sammanslagning, metadataskrivning eller XMP-sidecars end-to-end i ETT
  svep på grund av avbrottet ovan — dessa är däremot redan verifierade
  styckvis mot riktig data i tidigare faser (Fas 2a: bracket-analys mot
  142/2117-bilderssessioner; Fas 3a: HDR-motorn mot riktiga RAW-brackets).
- `FileSafety`/`sanitizeFolderName`-fixarna i Del 1 är defense-in-depth för
  ett scenario (en kalenderhändelsetitel som saneras till exakt `".."`)
  som INTE kunnat reproduceras med riktiga kalenderdata under denna eller
  tidigare faser — bara konstruerade i enhetstester. Om användaren någon
  gång ser en mapp bokstavligen döpt `"Okänd adress"` dyka upp där en
  riktig adress förväntades är det ett tecken på att detta fall triggades
  på riktigt, värt att undersöka vilken kalenderhändelsetitel som orsakade
  det.
- Styrfilen för röktestet (`~/Library/Application Support/PhotoFlow/
  smoke_test.json`) är avstängd/borttagen igen efter denna fas — normala
  `xcodebuild test`/Cmd+U-körningar påverkas inte och tar bara några
  sekunder som förut.
