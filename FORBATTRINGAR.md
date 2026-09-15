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
