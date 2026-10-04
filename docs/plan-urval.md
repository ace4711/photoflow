# Plan: urval till extern redigering

Den automatiska redigeringen räcker inte. Fotografen använder i stället granska-läget för att
välja vad som går till en extern redigerare. Det ersätter det manuella arbetet i Lightroom:
välja de bästa bildgrupperna och konvertera 2–3 exponeringar per bracket till DNG i en mapp
`<adress> skicka`.

## Vad som är byggt

**Urval i Granska** (`Views/BracketReviewView.swift`, `Views/Review/EditSelectionViews.swift`)
- Växeln **Skicka till redigering** finns per grupp, i raden ovanför miniatyrerna. Tangenten är **S**.
- Varje miniatyr har en **kryssruta**. **E** bockar i eller ur den exponering som visas. Avvisade bilder
  är spärrade (xmark) och kan inte väljas. En bild som avvisas efteråt räknas bort, men urvalet minns den.
- Att bocka i en fil i en avslagen grupp slår på gruppen med bara den filen. Att bocka ur den sista
  filen slår av gruppen. Slår man på en grupp igen med S kommer de tidigare valen tillbaka.
- Knappen **Föreslagna exponeringar** bockar i appens förslag för gruppen.
- **Headern** visar "N grupper · M filer valda för redigering". Trollstavsmenyn har "Föreslå urval igen"
  (rör bara orörda grupper) och "Ta bort orörda förslag".
- Grupplistan har ett **pappersflygplan** för grupper som skickas. Orörda förslag har dessutom en liten
  **Förslag**-markering, som försvinner så fort fotografen ändrar gruppen.
- **Filter**: "Skickas till redigering" och "Ej vald för redigering" (J/K och Tab/U följer filtret).
- **⌘Z** ångrar urvalsändringar i samma stapel som granskningsbesluten.
- Urvalet sparas i `edit_selection.json` i sessionens outputmapp (`Services/EditSelection/EditSelection.swift`)
  och överlever omstart.

**Skapa skicka-mappar** (`Services/EditSelection/SendFolderSync.swift`)
- Valda exponeringars DNG hamnar i `<output>/<adress>/<adress> skicka/` och behåller originalfilnamnet
  (`DSC_1234.dng`, samma som DNG Converter och fotografens egna skicka-mappar).
- Gruppens adress bestäms av första bildens tid, precis som adressbadgen i grupplistan. Grupper utan
  kalendermatchning hamnar i `<output>/Osorterade/Osorterade skicka/`. Skälet är att "Osorterade" redan
  är en adressmapp i `AddressFolderLayout`, så samma regel gäller överallt och inget specialfall behövs.
- Källan är pipelinens DNG. Symlänkar löses upp, och kopian görs med APFS-kloning via en temporär fil
  och en atomisk omdöpning. Saknas DNG:n konverteras NEF:en med Adobe DNG Converter på samma sätt som
  DNG-steget: först till `dng/.partial-skicka/`, sedan flyttas filen till `dng/`.
- Appen skriver aldrig över en fil som skiljer sig från källan. Sådana filer visas som krockar.
  En identisk främmande fil lämnas där den är.
- Appen tar bara bort filer som den själv lagt dit och som inte ändrats sedan dess. Det spåras i
  `edit_send_manifest.json` i outputmappen, inte i skicka-mappen, så redigeraren slipper se filen.
  Ändrade egna filer lämnas kvar med en varning. En skicka-mapp som blivit helt tom tas bort.
- Synken körs utanför MainActor och visar förlopp. Efteråt visas en sammanfattning per adress
  (antal filer, storlek, nya och borttagna), krockar och fel, plus knappen **Visa i Finder**.
- Originalfilerna ändras aldrig.
- Sessionsladdningen (`dngLookup`) och verifieringen hoppar över skicka-mapparna.

**Automatiskt förslag** (`Services/EditSelection/EditSuggestion.swift`, `EditSuggestionRunner.swift`)
- Förslaget körs första gången granskningen öppnas för en session (i bakgrunden, med förlopp i
  headern) och läggs in förbockat. Det körs inte igen av sig självt, så fotografens ändringar
  skrivs aldrig över.

Skärmbilder: `~/PhotoFlowBenchmark/results/urval/granska-urval.png` och `skicka-mappar.png`.
De renderas av `EditSelectionScreenshotTests` med riktiga förhandsbilder från Ballonggatan 7.

## Data

Underlaget är fem fotograferingar med fotografens faktiska val (`groups.csv`):

| Fotografering | Grupper | Skickade | Andel |
|---|---:|---:|---:|
| Pilvingegatan 77 | 34 | 25 | 74 % |
| Ballonggatan 7 | 34 | 27 | 79 % |
| Bergstigen 105 | 79 | 50 | 63 % |
| Pilottorget 3 | 15 | 8 | 53 % |
| Varmfrontsgatan 11 | 19 | 18 | 95 % |
| **Totalt** | **181** | **128** | **71 %** |

De lokala NEF-kopiorna täckte bara skickade grupper. De inbäddade förhandsbilderna och EXIF för alla
828 filerna lästes därför från nätverksdisken, enbart läsning
(`~/PhotoFlowBenchmark/urval/extract.sh`, 103 MB). Varje bild mättes (`urval/features.swift`) på
1024 px med Vision feature print, ljushet, klippning, Laplace-skärpa och Vision-klassning.
Analysen finns i `urval/*.py`, och utvärderingen av appens egen Swift-kod i `urval/eval/`.

### Vad fotografen gör

- **Skickar en per vy.** Hon tar om samma komposition tills hon är nöjd. Omtagningar i följd har ett
  feature print-avstånd under ~0,25 (euklidiskt) och tas inom en till två minuter. Av dem skickas
  nästan alltid **den sista**.
- **Exponeringar i en bracket.** Seriens **ljusaste** bild skickas i 71 av 88 fall. Mellan sista och
  mittersta skickade bilden skiljer det typiskt ~1–2 EV, och den mörkaste skickade ligger ~3,5–4 EV
  under den ljusaste. Nästan alltid skickas 3 filer. Innehåller gruppen två bracket-serier (en
  omtagning) väljs ur den sista.
- **Serier utan exponeringsspridning** (handhållna exteriörer med samma slutartid): en bild skickas,
  oftast **den sista**. I 65 % av fallen är det exakt den sista, mot 12 % för den första.
- Exteriörserier (Bergstigen, Pilottorget) har mest bortval och är svårast att förutsäga.

### Modell (enkel och förklarbar)

1. **Grupper.** Gå igenom grupperna i tagningsordning. En grupp hör till föregående grupps kluster om
   minsta feature print-avståndet mellan deras bilder är under 0,25 (Vision `distance` 0,0625, som är
   kvadraten på avståndet) och pausen är under 120 s. Föreslå den sista valbara gruppen i varje kluster.
   Varje kluster ger en grupp, så alla rum och vyer täcks.
2. **Exponeringar.** Ur sista bracket-serien (en ny serie börjar när EV sjunker mer än 0,5): ta den
   ljusaste, den närmast 3,5 EV mörkare och den närmast 1 EV mörkare. Är spannet under 2,5 EV blir
   det 2 bilder, under 0,6 EV (ingen bracket) 1 bild, nämligen den sista.

### Mått

Utvärderingen kör appens egen Swift-kod (`urval/eval`) mot fotografens val. Hela utskriften finns i
`results/urval/utvardering.txt`.

| | Precision | Recall | F1 |
|---|---:|---:|---:|
| Grupper, modellen | **0,81** | **0,95** | **0,87** |
| Grupper, "skicka alla" (baslinje) | 0,71 | 1,00 | 0,83 |

Per fotografering (grupper): Pilvinge P 0,96/R 0,88, Ballonggatan 0,93/1,00, Bergstigen 0,67/0,92,
Pilottorget 0,89/1,00, Varmfront 0,95/1,00.

Lämna-en-ute över de fem fotograferingarna, där tröskeln väljs på fyra och testas på den femte:
alla fem delningar valde 0,25. Resultatet blir därför detsamma som tabellen, P 0,81 R 0,95.

Exponeringar i skickade grupper (n = 128):

| | Precision | Recall | Exakt samma uppsättning |
|---|---:|---:|---:|
| Modellen (lämna-en-ute, 3,5/1,0 EV valt i 4 av 5) | **0,66** | **0,69** | **0,40** |
| Mörkast/mitten/ljusast i hela gruppen (baslinje) | 0,61 | 0,65 | 0,35 |

Ärligt sagt:
- **Gruppförslaget** tar bort ungefär hälften av bortvalen (53 → 28 felaktigt föreslagna) och missar
  7 av 128 skickade grupper. Fotografen behöver alltså fortfarande gå igenom listan. Felen sitter
  främst i exteriörserier, där fotografen väljer bland lika vyer på ett sätt som bilderna inte
  avslöjar.
- **Exponeringsförslaget** stämmer i ungefär 2 av 3 filer. Den ljusaste blir rätt i ungefär 80 %
  av bracketgrupperna. Avvikelserna är oftast en bild åt ena eller andra hållet, vilket spelar mindre
  roll för redigeraren än vilka grupper som skickas.
- Det här är litet underlag från en fotograf och en kamera (Z8, manuell bracket).

### Prövat och förkastat

- **Ljushetstak** (hoppa över överexponerad ljusaste): gav ingen förbättring, 0,63–0,65 oavsett tak.
- **Skärpa** för att välja i serier utan bracket: sämre än "sista", 0,32 mot 0,39 exakt.
- **Välj gruppen med störst EV-spann eller flest bilder i klustret**, och **filtrera bort små grupper
  utan bracket**: bättre på hela datan (P 0,83), men valdes olika i olika delningar. I lämna-en-ute
  blev det sämre (F1 0,82–0,84 mot 0,87), så det behölls inte.
- **Avstånd mellan representativa bilder** (exponeringen närmast mellanljus) i stället för minsta
  avståndet mellan alla exponeringar: marginellt sämre.
- Vision-klassningen (rumstyp) används inte i modellen. Klustringen ger redan en grupp per vy, så
  alla rum täcks, och etiketterna (mest "structure", "furniture") var för grova för att skilja
  omtagningar åt.

## Nästa steg (förslag)

- Mät hur ofta fotografen ändrar förslaget (spara ursprungsförslaget) och kalibrera om på fler
  fotograferingar.
- Exteriörserier: pröva skärpa och horisont i kombination med "sista", när det finns mer data.
