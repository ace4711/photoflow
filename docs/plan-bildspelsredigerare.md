# Plan: Interaktiv bildspelsredigerare ("Regi")

*Version 1, 17 oktober 2026. Bygger vidare på `plan-bildspelsmodul.md` (Fas 1–2 genomförda) och `reel-spec-v1.md`.*

**Status 17 oktober 2026:** R0–R5 är genomförda på grenen `forbattringar`. Besluten i avsnitt 7 följer rekommendationerna. Swift: 288 Reel-tester gröna, bygget utan varningar. Webben: 40 tester. Servern: 62 tester. Efter R4 gjordes en adversariell granskning av R0–R4 (fyra perspektiv, två skeptiker per fynd), och 18 bekräftade fel rättades. R5 granskades på samma sätt. Avvikelser och tillägg mot planen:

- `Clip.customMotion` (fotografens oklampade nycklar) infördes så att ett formatbyte fram och tillbaka inte ändrar en egen rörelse för gott (reel-spec 2.3).
- "Föreslå igen", antal och "Börja om helt" behåller filmens id och höjer revisionen, så att synken mot mäklaren inte ser en ny film. Bilder med per-bild-lås räknas som pinnade vid nytt förslag.
- Mäklaren kan inte byta bort en egen rörelse (menyn är låst), och servern (`server/src/locks.ts`) vägrar mäklarskrivningar som ändrar stil, tempo, ordningslås, låsta övergångar eller egna rörelser, eller som lägger till låsningar och uteslutningar. Ändringen i servern är inte driftsatt.
- Kvar att verifiera i appen: dragningar i tidslinjen och på ramarna, dra från rutnätet, ⌘Z/⇧⌘Z i menyn Redigera, och hur flytande förhandsvisningen är med riktiga bilder.

---

## 1. Mål

Filmen ska kunna göras **helt autonomt** (som i dag: `ReelComposer.compose` väljer bilder, ordning, rörelse, längd och övergångar) men **varje beslut ska gå att se, förstå och ändra** i ett interaktivt gränssnitt:

| Beslut | I dag | Efter planen |
|---|---|---|
| Urval av bilder | Byt/lägg till/ta bort via rutnätet | + lås bild ("ska vara med"), uteslut bild ("aldrig"), dra från rutnätet till en plats i tidslinjen |
| Ordning | Dra i filmremsan | + lås ordningen; "Föreslå igen" behåller låsta platser |
| Längd per bild | Stepper | Dra klippets kant i en proportionell tidslinje |
| Övergångar | **Går inte att ändra** (planeraren väljer, skrivs över vid varje ombyggnad) | Typ, riktning och längd per övergång, plus filmens standardövergång |
| Panorering/zoom | Förval i meny (zooma in/ut, panorera ←/→, contain) | + dra start- och slutram direkt på bilden |
| Stil | Fast | Tempo, easing, bakgrundsoskärpa |
| Ångra | Saknas | ⌘Z / ⇧⌘Z för allt |

## 2. Princip: förslag + lås

Varje beslut har ett **ursprung**: *automatiskt* eller *ditt*.

- Automatiska beslut räknas om vid varje ombyggnad (`ReelComposer.rebuild`), precis som i dag. Byter du ordning får alla automatiska rörelser och övergångar ny rytm (alternerande riktning, push som följer panoreringen osv.).
- Ett beslut du ändrar för hand blir **låst**: det visas med en liten låsikon och följer med bilden genom omordning, byte av format och "Föreslå igen". Klick på låset = tillbaka till automatiskt.
- "Föreslå igen" behåller låsen och fyller resten. Ett separat "Börja om helt" kastar alla lås (med bekräftelse och ångra).

Det är samma mönster som redan finns för längd (`durationLocked`) och rörelse (`motionPreset`); planen utvidgar det till övergångar, egna nyckelramar och urval.

**Autonomin påverkas inte:** CLI:t (`photoflow-cli reel`) och det automatiska filmförslaget efter pipelinen ger en spec helt utan lås, alltså samma resultat som i dag.

## 3. Datamodell (tillägg inom ReelSpec v1)

Alla tillägg är metadata som renderare inte läser. Renderarna (Swift, Canvas, ffmpeg) läser redan `motion`, `duration` och `transitionIn` per klipp, så **ingen renderare behöver ändras** och `minReaderVersion` förblir 1. Webbens `reelSpec.ts` bevarar redan okända fält (`[extra: string]: unknown`), men det ska verifieras med ett rundturstest.

**Per klipp (`timeline[]`):**

- `transitionLocked?: Bool` — `true` när övergången satts för hand; `rebuild` behåller då klippets `transitionIn` i stället för att planera om den. `{"type":"cut"}` är ett giltigt låst val.
- `motionPreset: "custom"` — nytt värde: start/slut har dragits för hand. `rebuild` behåller `motion` som den är (klampad, se 5.3) och planeraren rör den inte.
- `fitLocked?: Bool` — om cover/contain-blur valts separat från rörelsen (behövs bara om "Hela bilden" ska kunna kombineras med egen rörelse; annars följer fit av förvalet som i dag).

**Toppnivå, nytt objekt `editor` (okänt för äldre läsare, ignoreras):**

```json
"editor": {
  "pinnedAssets": ["<sha256>", "..."],
  "excludedAssets": ["<sha256>", "..."],
  "orderLocked": false,
  "tempo": "normal"
}
```

- `pinnedAssets`: bilder som alltid ska vara med vid "Föreslå igen".
- `excludedAssets`: bilder som aldrig ska föreslås (visas gråade i rutnätet).
- `orderLocked`: "Föreslå igen" får byta bilder men inte flytta låsta klipp.
- `tempo`: `calm` / `normal` / `fast`, en faktor på planerarens längder (ca 1,2 / 1,0 / 0,85) och tempotak.

`ReelMotionPlanner.ClipOverride` utökas till `{preset, duration, transition?, motion?}` och `ReelComposer.overrides(in:)` läser in de nya fälten. `ReelSelector.select` får parametrarna `pinned:` och `excluded:` (låsta bilder fyller sina platser först, resten väljs med nuvarande poäng/MMR).

## 4. Gränssnittet

Fönstret behåller sin uppdelning men mittdelen byggs om kring en tidslinje:

```
┌──────────────────────────────────────────────────────────────────────┐
│ Mapp …   [9:16|1:1|16:9]  Tempo [Lugn|Normal|Snabb]  Föreslå igen ▾  │
│                                         Rendera   Skicka till mäklare │
├──────────────┬───────────────────────────────────────────────────────┤
│              │  Inspektör (det markerade):                           │
│  Förhands-   │   • Klipp → rörelseeditorn (start/slut-ram på bilden) │
│  visning     │   • Övergång → typ, riktning, längd                   │
│  9:16        │   • Ingenting → filmens stil och "varför"-sammandrag  │
│  ▶ ──●────   │                                                       │
├──────────────┴───────────────────────────────────────────────────────┤
│ Tidslinje (bredd ∝ sekunder, spelhuvud synkat med förhandsvisningen) │
│ [ Fasad 3,0 s ]⟋[ Kök 2,5 s 🔒]⟋[ Vardagsrum 2,8 s ]▮[ Sovrum ]⟋[ … ] │
│              ↑ övergångschip: klicka = redigera, dra = ändra längd   │
├──────────────────────────────────────────────────────────────────────┤
│ Bilder: [Alla|Valda|Ej valda|Uteslutna]  Rum ▾   (dra in i tidslinjen)│
│ ▢▢▢▢▢▢▢▢  📌 lås   ⊘ uteslut   poäng och skäl                         │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.1 Tidslinje (ersätter filmremsan)

- Klippblock med bredd proportionell mot längden; övergången ritas som överlappet mellan två block (samma tidsmodell som `ReelTimeline.clipStarts`).
- **Dra högerkanten** = ändra längd (låser längden). Visar sekunder under dragningen, snäpper till 0,1 s.
- **Dra blocket** = flytta (som i dag). **Delete** = ta bort.
- **Övergångschip** mellan blocken med ikon för typen (⟋ crossfade, │ cut, ▮ via svart, → push). Klick markerar övergången och öppnar den i inspektören; dra i chipets kant = ändra övergångens längd.
- Spelhuvud som följer förhandsvisningen; klick i tidslinjen = hoppa dit. Markerat klipp/övergång spelas i loop med ⌥-mellanslag.
- Låsikon på block/chip med låsta beslut.

### 4.2 Övergångsinspektören

- Typ: Automatisk · Mjuk tona (crossfade) · Hårt klipp · Via svart · Skjut (push) + riktning ←→↑↓.
- Längd 0,2–1,5 s (klampas mot de två klippens längd enligt spec 3; visa varning om den kortas).
- "Använd på alla" sätter filmens `style.defaultTransition` och tar bort låsen på övergångar som var automatiska.
- Förhandsvisa: spelar ±1 s runt övergången.

### 4.3 Rörelseeditorn (direktmanipulation)

Inspektören visar **hela källbilden** med två ramar i utformatets bildförhållande:

- **Start** (grön) och **Slut** (orange), med en pil mellan mittpunkterna. Dra i ramen = flytta (cx, cy); dra i hörnen = zooma (ramen krymper = zoom in). Ramarna kan aldrig lämna bilden: samma klampning som `ReelTimeline.cropRect`/`containCrop`, så det du ser är exakt det som renderas.
- Knappar: Byt start/slut · Centrera på motivet · Tillbaka till automatisk.
- Förvalen finns kvar som snabbval ovanför bilden; att dra en ram byter förvalet till "Eget".
- Valfritt lager: saliency-boxarna från analysen, så man ser vad planeraren siktade på.
- Tempovarning (inte spärr) när rörelsen går över `maxPanPerSecond` / `maxZoomPerSecond`: "Snabb panorering — kan se ryckig ut".
- För contain-blur visas den kvadratiska förgrundsramen (spec 5.2) i stället.
- Under dragningen uppdateras förhandsvisningen live med klippets start- eller slutbild (beroende på vilken ram man drar); specen sparas och revisionen höjs först när musen släpps.

Omräkning ram ↔ nyckel: `cx, cy` = ramens mittpunkt, `zoom = baseW / w` (baseW från spec 5.1). Lagras klampat.

### 4.4 Urval

- Rutnätet får filter (Alla / I filmen / Ej i filmen / Uteslutna) och rumsfilter.
- Per bild: 📌 *Lås i filmen* och ⊘ *Uteslut*, plus nuvarande poäng och skäl (`ReelSelector`), och för uteslutna bilder skälet.
- Dra en bild från rutnätet till en plats i tidslinjen = infoga där; släpp på ett block = byt bild.
- Antal bilder: taket höjs från 8 till 12 (filmen blir då längre än 15 s; visa total längd tydligt).

### 4.5 "Varför"

Varje automatiskt beslut får en kort förklaring i inspektören, beräknad på nytt (inte sparad):

- Urval: finns redan (`provenance.autoSelection[].reason`).
- Rörelse: "Panorering: motivet (62 % av bredden) är bredare än ramen (37 %)." / "Zoom: motivet ryms i ramen."
- Övergång: "Skjut åt vänster eftersom förra klippet panorerade åt höger." / "Längre tona in i sista bilden."

Det kräver att `ReelMotionPlanner.plan` också returnerar ett skäl per klipp (ren logik, testbar).

### 4.6 Ångra / gör om

Specen är liten (några kB). Modellen håller en historik med hela specar (tak ca 100 steg), kopplad till fönstrets `UndoManager` så att ⌘Z/⇧⌘Z och menyn Redigera fungerar. Dragningar slås ihop till ett steg. "Hämta ändringar" från mäklaren blir också ett ångringsbart steg.

## 5. Teknik och risker

1. **Förhandsvisningens fart vid dragning.** `ReelPreviewModel.setSpec` skapar en ny `ReelRenderer` vid varje ändring. Under dragning behövs ca 30 bilder/s. Åtgärd: en delad bildcache (sha256 + storlek) som överlever renderarbyten, och en "transient" spec under dragningen som inte sparas eller höjer revisionen. Mät före/efter.
2. **`rebuild` får inte skriva över låsta val.** Kärnan i hela planen. Täcks av tester: varje låst fält är oförändrat efter omordning, byte av format, byte av bild och "Föreslå igen".
3. **Formatbyte med egen rörelse.** En egen ram i 9:16 betyder något annat i 16:9. Regel: `cx, cy, zoom` behålls (de är formatoberoende) och klampas om; visa en notis "Egna rörelser har anpassats till 16:9". Alternativ: släpp låset. Beslut 3 nedan.
4. **Webben (mäklarens editor).** Den redigerar klipp på plats och bevarar okända fält, men `motionPresets.ts` måste känna till `"custom"` och `transitionLocked` så att mäklarens ändringar inte nollställer fotografens val. Rundturstest Swift → JSON → TS → JSON → Swift.
5. **Synk och konflikter.** `ReelSyncMerger` och revisionshanteringen är oförändrade; nya fält följer med specen.

## 6. Faser

Storlek: S ≈ 1 dag, M ≈ 2–4 dagar agentarbete. Varje fas byggs och testas (`xcodebuild test`) före commit, i projektets stil (ren logik i `nonisolated enum`, svenska kommentarer).

| Fas | Innehåll | Filer (huvudsakligen) | Storlek | Verifiering |
|---|---|---|---|---|
| **R0** Lås i datamodellen | Spec-fälten i avsnitt 3, utökad `ClipOverride`, `rebuild` respekterar alla lås, `ReelSelector` med pinned/excluded, "Föreslå igen" behåller lås + "Börja om helt" | `ReelSpec.swift`, `ReelComposer.swift`, `ReelMotionPlanner.swift`, `ReelSelector.swift`, `ReelEditorModel.swift` | M | Nya `ReelLockTests`; befintliga Reel-tester och testvektorer oförändrade |
| **R1** Ångra + tidslinje | Historik/`UndoManager`; ny `ReelTimelineView` (proportionell, spelhuvud, dra längd, dra ordning, övergångschip) ersätter filmremsan | `ReelEditorModel.swift`, ny `ReelTimelineView.swift`, `ReelEditorView.swift` | M | Modelltester för ångra; manuellt i appen |
| **R2** Övergångar + stil | Övergångsinspektören, "Använd på alla", tempo, easing, bakgrundsoskärpa | ny `ReelTransitionEditor.swift`, `ReelStylePanel.swift`, planeraren (tempofaktor) | S–M | `ReelMotionPlannerTests` för tempo; låst `cut` överlever ombyggnad |
| **R3** Rörelseeditor | Start/slut-ramar på bilden, klampning, live-förhandsvisning, saliency-lager, tempovarning; bildcache i förhandsvisningen | `ReelMotionEditor.swift` (skrivs om), `ReelPreviewModel.swift`, `ReelRenderer.swift` (cache) | M | Ren omräkning ram ↔ nyckel testas mot `ReelTimeline.cropRect`; mätt bildfrekvens vid dragning |
| **R4** Urval + "varför" | Filter, lås/uteslut, dra från rutnät till plats, tak 12 bilder, skäl för rörelse och övergång | `ReelEditorView.swift` (rutnätet), `ReelMotionPlanner.swift` (skäl) | S–M | Skälstester; manuellt |
| **R5** Webbparitet | `motionPresets.ts`/`editor.ts` respekterar `custom` och `transitionLocked`; visa låsta val som låsta för mäklaren | `web/reel/src/` | S | Rundturstest Swift ↔ TS; `npm test` |

R0 är grunden och måste komma först. R1–R4 kan göras i valfri ordning efter det; R3 är det som ger mest "regikänsla" och har störst teknisk risk (prestanda).

## 7. Beslut du behöver ta

1. **Låser en manuell ändring automatiskt?** Rekommendation: *ja* — allt du ändrar för hand låses, och ett klick på låset släpper det. Alternativet (explicit "lås"-knapp) ger fler klick och fler överraskningar.
2. **Vad gör "Föreslå igen"?** Rekommendation: behåller lås och fyller resten; "Börja om helt" i en meny bredvid.
3. **Formatbyte med egna rörelser:** anpassa (behåll mittpunkt/zoom, klampa om) eller släpp låset? Rekommendation: anpassa och visa en notis.
4. **Ska mäklaren också kunna redigera övergångar och panorering på webben?** Rekommendation: *inte nu* — webben ska bara respektera fotografens val (R5). Mäklarens regi hålls enkel (urval, ordning, längd).
5. **Fler övergångstyper** (t.ex. zoom-genom, swipe med oskärpa)? Rekommendation: vänta. Varje ny typ måste definieras exakt i specen och implementeras i tre renderare, och kräver `minReaderVersion` 2.
