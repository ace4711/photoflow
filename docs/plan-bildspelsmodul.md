# Plan: Bildspelsmodul för PhotoFlow ("Objektfilm")

*Version 1, 3 oktober 2026. Bara plan, ingen kod är skriven. Märkningen **[Verifierat]** betyder att uppgiften kontrollerats mot en källa som är länkad i texten. **[Antagande]** betyder att det är min bedömning och behöver testas.*

---

## 1. Sammanfattning och rekommendation

**Vad modulen gör:** Efter redigeringen tar modulen emot de färdiga bilderna för ett objekt, oftast 15–30 stycken. Den väljer själv ut ungefär 5 och bygger en kort film på 10–15 sekunder i 9:16, med panorering och zoom (Ken Burns) och mjuka övergångar. Fotografen och senare mäklaren kan byta bilder, ändra ordning och längd och se resultatet direkt. Hela regin beskrivs av en liten JSON-fil, **ReelSpec**. Samma fil kan öppnas, ändras och förhandsvisas på flera plattformar.

**Min rekommendation i korthet:**

| Beslut | Rekommendation |
|---|---|
| Var regin sker först | **Bara i macOS-appen** (Fas 1). Fotografen gör förslaget och renderar till en fil. |
| Mäklarens regi | **En mobilanpassad webbsida** (Fas 2), inte en iOS-app. Mäklaren behöver inte installera något, och det krävs ingen App Store-distribution. |
| Renderare | **AVFoundation + Core Image på Mac** i Fas 1. JSON-formatet definieras matematiskt exakt, så att en webbrenderare (Canvas) och senare en molnrenderare kan ge samma bild. Det kontrolleras med golden-frame-tester. |
| Publicering | **Ingen API-publicering i Fas 1–2.** Filmen hamnar i ett "arkiv" (en mapp, sedan en webblänk). Mäklaren delar den från mobilen via delningsmenyn till Instagram/TikTok och lägger till musik där. API-publicering till utkast kommer i Fas 4, via en hanterad tjänst kopplad till mäklarens egna konton. |
| Musik | Börja **utan inbränd musik**. Mäklaren väljer ljud i TikTok/Instagram vid publicering. Licensierad musik via API (t.ex. Epidemic Sound) tas upp senare. |

**Det viktigaste från researchen:**

- **TikTok har riktiga utkast via API.** Videon laddas upp till användarens inkorg och mäklaren gör klart inlägget i appen.
- **Instagram har inga utkast via API.** Där finns bara direktpublicering, eller "trial reels" som visas för icke-följare.
- **YouTube kan ta emot privata uppladdningar.** Det fungerar i praktiken som ett utkast.
- **Facebook-sidor har ett DRAFT-läge för Reels.**
- **LinkedIn tar bara emot publicerade inlägg** när man skapar via API.

Därför är "arkiv + mäklaren publicerar själv" både det enklaste och det som bäst motsvarar önskemålet om utkast hos mäklaren.

---

## 2. Användarflöden

### 2.1 Fotografen (macOS-appen)

1. Fotografen exporterar de färdiga bilderna från Lightroom till en mapp, t.ex. `Lindvägen 12, Tyresö FÄRDIGA/`.
2. Hon öppnar PhotoFlow → **Bildspel…** (verktygsfältet, eller adressraden i Historik) och drar in mappen. Appen kopplar mappen till rätt session och adress via mappnamnet.
3. **Autonomt:** Appen analyserar bilderna (cachat, några sekunder per bild), väljer 5, sätter ordning, rörelse och övergångar och visar en spelbar förhandsvisning direkt.
4. **Manuellt (valfritt):**
   - Byta bild genom att dra från rutnätet med kandidater.
   - Ändra ordning genom att dra i filmremsan.
   - Ändra längd per bild.
   - Välja rörelsens riktning ("zooma in", "panorera vänster→höger"), eller dra start- och slutram direkt på bilden.
   - Välja format (9:16, 1:1, 16:9).
5. **Rendera** → `reel_9x16.mp4` och `reel.json` hamnar i `Lindvägen 12, Tyresö FILM/`. Det är arkivet i Fas 1.
6. Fotografen skickar filen till mäklaren som hittills (WeTransfer, mejl, länk). I Fas 2 skickas i stället en länk.

### 2.2 Mäklaren (Fas 2 och framåt, webb)

1. Mäklaren får en länk via SMS eller mejl och öppnar den i mobilen.
2. Hon ser filmen, som spelas upp i webbläsaren direkt från JSON + bilder, och fotografens förslag.
3. Hon kan:
   - byta eller ta bort bilder bland objektets alla färdiga bilder
   - ändra ordning och dra ut eller korta längder
   - senare även ändra texter (visning, pris).
4. **Godkänn** → filmen renderas i full upplösning och dyker upp i mäklarens arkiv.
5. **Dela** → iOS delningsmeny → Instagram Reels eller TikTok, där mäklaren lägger till musik och publicerar. I Fas 4 kan hon i stället trycka "Skicka som utkast till TikTok/YouTube/Facebook".

### 2.3 Vad som är autonomt och vad som är manuellt

| Moment | Autonomt | Manuellt |
|---|---|---|
| Analys av färdiga bilder | Ja | – |
| Urval (5 st) och ordning | Ja (förslag) | Kan ändras |
| Rörelse per bild (fokus, riktning, zoom) | Ja (via saliency) | Kan ändras |
| Längder, övergångar, total längd | Ja (efter format) | Kan ändras |
| Rendering till fil | Ett klick | – |
| Publicering | **Aldrig autonomt.** Kräver alltid ett aktivt val av kontoägaren. | Mäklaren |

---

## 3. Automatiskt urval av bilder

### 3.1 Indata: de färdiga bilderna saknar analys

Dagens analys ligger i `ai_tags.json` (AITagsStore: `mlRoom`, `mlCategory`, `mlFeatures`, `mlCaption`) och `photo_quality.json` (PhotoQualityService: `qualityScore`, `isUtility`, `horizonAngleDegrees`, `sharpness`, `duplicateGroupID`). Båda är nycklade på **previewns filnamn utan ändelse**, t.ex. `DSC_1234`. Det har jag sett i `PipelineRunner+AITagging.swift`.

De färdiga bilderna är något annat:

- De är exporterade från Lightroom.
- De har ofta nya namn, t.ex. `DSC_1234-HDR.jpg`, `Lindvägen-12-07.jpg` eller `hdr_group_12.jpg`.
- De är beskurna, rätade och färgkorrigerade.
- HDR-bilder motsvarar flera originalbilder.

**Rekommendation: kör analysen om på de färdiga bilderna.** Skälen:

- Den är billig. Vision-estetik, horisont, skärpa och feature prints tar bråkdelar av en sekund per bild. Foundation Models-beskrivningen tar några sekunder per bild **[Antagande, baserat på Fas 3d-mätningarna i FORBATTRINGAR.md]**. För 30 bilder blir det under en minut, och resultatet cachas.
- Den blir mer korrekt. Horisonten är redan rätad i Lightroom och skärpan efter export är det som faktiskt syns. Beskärningen ändrar också både rumsintrycket och saliency.
- Den är robust. Det finns ingen bräcklig namnmatchning.

**Återanvändning som bonus:** Om ett färdigt filnamn börjar med ett känt preview-namn (`DSC_1234…`) hämtas `mlRoom` och `mlCaption` från sessionens `ai_tags.json` som reserv, när Foundation Models inte finns (macOS 26) eller misslyckas.

Resultatet sparas i `<adress> FILM/reel_analysis.json`. Det är versionerat i samma stil som `PhotoQualityService.PersistedFile` och nycklat på **innehållshash (SHA-256)** i stället för filnamn. Då överlever analysen omdöpningar och om-exporter.

**Kodmässigt:**

- `PhotoQualityService.measureImage(url:)` och `computeSharpness` är `private`. De behöver göras interna, eller få en ny publik ingång för "analysera godtycklig lista av URL:er".
- `PhotoDescriptionService.describe(imageAt:)` kan användas direkt.
- `clusterDuplicates` och `bestIndex` är redan ren, testbar logik som kan återanvändas rakt av.

Ny analys som behövs:

| Analys | API | Användning |
|---|---|---|
| Saliency (var blicken dras) | Vision `GenerateAttentionBasedSaliencyImageRequest` | Fokuspunkt och utsnitt för Ken Burns |
| Feature print-avstånd | Samma som dubblettklustringen | Variation i urvalet (inte bara dubbletter) |
| Ljusstyrka/kvällsbild | Medelluminans + EXIF-tid | "Skymningsbild som avslutning" |

### 3.2 Algoritmen (ren logik, `nonisolated enum ReelSelector`)

**Steg 1 – Hårda filter.** Följande tas bort:

- `isUtility == true`
- `|horisont| > 3°`, men bara för exteriörbilder. Interiörer har ofta ingen horisont alls.
- Skärpa under 25:e percentilen *inom objektet* (måttet är relativt, se kommentaren i `PhotoQualityService`).
- Alla utom den bästa i varje dubblettgrupp (`bestIndex`).

**Steg 2 – Grundpoäng per bild (0…1)**

```
bas = 0.55 · quality
    + 0.15 · skärpePercentil
    + 0.10 · särdragsbonus     // mlFeatures/mlCaption innehåller "utsikt", "öppen spis",
                               // "sjötomt", "terrass", "kakelugn"…
    + 0.10 · ljusbonus         // välexponerad; skymningsbild får extra som avslutning
    + 0.10 · saliency-tydlighet // ett tydligt motiv ger bättre Ken Burns
```

Vikterna är startvärden **[Antagande]**. De kalibreras mot 5–10 riktiga objekt där fotografen själv väljer "sina" 5 (se Fas 1d).

**Steg 3 – Berättelsemall med platser ("slots").** Malltypen väljs automatiskt:

- **Villa/hus:** minst en exteriör med `mlRoom ∈ {Fasad, Hus, Tomt, Trädgård}`.
- **Lägenhet:** inga fasadbilder eller bara entré/trapphus.

| Plats | Villa | Lägenhet | Regel |
|---|---|---|---|
| 1. Öppning ("hook") | Bästa fasaden/exteriören | Starkaste rummet eller utsikten | Måste vara stark: högst bas bland kandidaterna |
| 2 | Vardagsrum/allrum | Vardagsrum | – |
| 3 | Kök | Kök | – |
| 4 | Särdrag: sovrum, badrum, matplats, altan | Balkong, sovrum eller badrum | Rumstyp som inte redan är med |
| 5. Avslut | Exteriör nr 2: trädgård, uteplats, skymning, sjö/utsikt | Balkong/utsikt eller bästa kvarvarande | Får inte likna bild 1 (feature print-avstånd) |

**Steg 4 – Fyll platserna med MMR (maximal marginal relevans).** För varje plats väljs kandidaten som maximerar

`λ · bas − (1−λ) · max(likhet med redan valda)`, med λ ≈ 0,7.

Likhet = 1 − normaliserat feature print-avstånd. Det ger variation även när rumstaggarna saknas eller är fel.

**Steg 5 – Reservlogik.** Saknas en rumstyp fylls platsen med bästa MMR-kandidat oavsett rum. Saknas Foundation Models helt används Visions grova kategori (`category` = Interiör/Exteriör) plus ren MMR.

**Steg 6 – Förklaring.** Varje val får en kort motivering, t.ex. *"Öppning: Fasad, kvalitet 0,82"*. Den visas i UI:t och sparas i `provenance` i JSON-filen, så att fotografen förstår förslaget och vikterna kan kalibreras.

Antalet bilder (3–8, standard 5) är en inställning. Mallen förlänger då plats 4 till flera särdragsplatser.

---

## 4. Filmdesign

### 4.1 Format och längd

| Format | Upplösning | Användning | Total längd (5 bilder) |
|---|---|---|---|
| 9:16 (standard) | 1080×1920, 30 fps | Reels, TikTok, Shorts, FB Reels | ca 12–15 s |
| 1:1 | 1080×1080 | Flöde (IG/FB/LinkedIn) | ca 12–15 s |
| 16:9 | 1920×1080 | YouTube, mäklarens webb, LinkedIn | ca 15–20 s |

Plattformarnas krav **[Verifierat]**:

- **Facebook Reels:** 9:16, 1080×1920 rekommenderat, 3–90 s, 24–60 fps, H.264/H.265, AAC 48 kHz ([Meta Reels Publishing](https://developers.facebook.com/docs/video-api/guides/reels-publishing)).
- **Instagram Reels via API:** 3 s–15 min. Bara 5–90 s i 9:16 kan visas i Reels-fliken. Max 1920 px bredd och max 300 MB ([Phyllo-guide](https://www.getphyllo.com/post/a-complete-guide-to-the-instagram-reels-api), [AdaptlyPost](https://adaptlypost.com/blog/instagram-reels-api-max-length-file-size)). Detta kommer från sekundärkällor som citerar Metas spec.
- **TikTok via API:** 23–60 fps, 360–4096 px, upp till 10 min, max 4 GB, MP4/H.264 rekommenderat ([TikTok Media Transfer Guide](https://developers.tiktok.com/doc/content-posting-api-media-transfer-guide)).
- **YouTube Shorts:** klassas automatiskt om videon är kvadratisk eller vertikal och högst 3 minuter. Det finns ingen särskild flagga ([Bundle.social](https://bundle.social/blog/youtube-shorts-api-secrets), [Hootsuite](https://blog.hootsuite.com/youtube-shorts/)).

**Gemensam exportprofil som klarar allt:** H.264 High, 1080×1920, 30 fps konstant, AAC 48 kHz stereo (även tyst spår), cirka 12–16 Mbit/s, `moov` först (faststart).

### 4.2 Takt

- **Bild 1:** 3,0 s med tydlig rörelse från första bildrutan. De första sekunderna avgör om tittaren stannar.
- **Mitten:** 2,4–2,8 s per bild.
- **Sista bilden:** 3,2–3,5 s med långsammare rörelse. Senare följer ett slutkort på 2–3 s (Fas 3).
- **Övergångar:** 0,4–0,6 s.
- Om musik med känt BPM läggs till senare kvantiseras klippbytena till takterna (Fas 3+).

### 4.3 Ken Burns: hur rörelsen väljs automatiskt

**Ett viktigt problem:** Fastighetsbilder är liggande, 3:2. I en ram på 9:16 syns bara cirka **37 % av bildens bredd** när bilden fyller hela ramen ("cover"). Det har två följder:

- **Horisontell panorering blir det naturliga** för rumsbilder. Man "går igenom" rummet från vänster till höger och tittaren får ändå se hela rummet.
- För bilder där motivet är brett (fasad, sjöutsikt) finns alternativet **"contain-blur"**: hela bilden visas centrerad och en suddig, förstorad kopia fyller bakgrunden. Det är vanligt i Reels.

Regeln (ren funktion `ReelMotionPlanner`):

1. Räkna ut synlig bredd w = ramens bildförhållande / bildens bildförhållande. För 3:2 i 9:16 blir w ≈ 0,375.
2. Hämta saliency-boxarna och deras sammanlagda bredd s.
3. Välj rörelse:
   - **s ≤ w** (motivet ryms): *zoom in mot motivets mittpunkt*, 1,00 → 1,12, med litet drift.
   - **w < s ≤ 0,85** (motivet är bredare än ramen): *panorera* från ena kanten av motivet till den andra. Riktningen alterneras mellan klippen för rytmens skull.
   - **s > 0,85 och exteriör** (bred fasad eller utsikt): *contain-blur* plus långsam zoom 1,00 → 1,06.
4. Alternera mellan in- och utzoom och mellan vänster- och högerpanorering mellan intilliggande klipp.
5. Begränsa tempot: högst cirka 10 % av bildbredden per sekund vid panorering (höjt från 6 % i 1d: 6 % gav bara ~0,17 av bilden; en panorering ska täcka minst ~0,25) och högst 4 % zoom per sekund. Långsammare än så ser exklusivt ut, snabbare ser billigt ut **[Antagande, kalibreras med fotografen]**.
6. Utsnittet får aldrig gå utanför bilden. Allt klampas, och kontrollen är en del av den rena logiken med tester.

### 4.4 Övergångar (v1)

| Typ | Beskrivning | Varför |
|---|---|---|
| `crossfade` (standard) | Mjuk tona-över, 0,5 s | Ser dyrt ut och fungerar alltid |
| `cut` | Hårt klipp | För beatsynk senare |
| `fadeThroughBlack` | Via svart | För slutkortet |
| `push` | Nästa bild skjuter ut föregående (vänster/höger/upp) | Passar ihop med panorering åt samma håll |

Alla fyra går att implementera identiskt i Core Image, Canvas/WebGL och ffmpeg. Fler effekter (zoom-blur, swipe) läggs till först när de kan definieras exakt i specifikationen.

### 4.5 Textlager (senare, men förbered nu)

Exempel på framtida textlager: adress-titel över bild 1, "Visning sön 13–14", pris, mäklarens logga och namn, ett slutkort med kontaktuppgifter. I v1 av schemat finns en reserverad lista `overlays` och en `brand`-referens. Renderaren i Fas 1 ignorerar dem, men validerar att fälten är välformade.

---

## 5. JSON-specifikationen (ReelSpec v1)

### 5.1 Principer

1. **Plattformsoberoende och matematiskt exakt.** Specen beskriver *vad* som ska synas vid tid *t*, aldrig *hur* en viss renderare gör det. Varje fält har en entydig formel (se 5.4).
2. **Oberoende av bildförhållande.** Rörelse anges som *mittpunkt + zoom relativt "cover"-utsnittet* i normaliserade bildkoordinater. Samma spec kan då renderas i 9:16, 1:1 och 16:9 utan omregi. Den som vill kan lägga till en override per format.
3. **Bilder refereras via ett asset-ID och en innehållshash.** Varje plattform löser referensen på sitt sätt: lokal sökväg, URL eller lagrings-ID.
4. **Versionering:** `schema` + `version` (heltal för större versioner). Läsare ignorerar okända fält, så tillägg är tillåtna inom v1. `minReaderVersion` används för brytande ändringar.
5. **Renderingsspecifikt hålls utanför** själva regin. Codec och bitrate ligger i en separat exportprofil (`outputs[].encoding`) som en webbförhandsvisning får ignorera.

### 5.2 Exempel: 5-bildersbildspel

```json
{
  "schema": "photoflow.reel",
  "version": 1,
  "minReaderVersion": 1,
  "id": "6f1c2a9e-3b7d-4d0e-9a51-0c3e8f2b7d11",
  "revision": 3,
  "status": "draft",
  "createdAt": "2026-10-03T09:12:00Z",
  "updatedAt": "2026-10-03T09:20:41Z",
  "updatedBy": { "role": "photographer", "name": "Fredrik" },

  "property": {
    "address": "Lindvägen 12, Tyresö",
    "sessionID": "2B0E…",
    "kind": "house"
  },

  "assets": [
    { "id": "a1", "sha256": "9f2c…", "width": 6048, "height": 4024,
      "sources": [ { "kind": "local", "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1201.jpg" } ],
      "analysis": { "room": "Fasad", "category": "Exteriör",
                    "focus": { "x": 0.52, "y": 0.47 }, "salientWidth": 0.71 } },
    { "id": "a2", "sha256": "1ab8…", "width": 6048, "height": 4024,
      "sources": [ { "kind": "local", "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1244.jpg" } ],
      "analysis": { "room": "Vardagsrum", "category": "Interiör",
                    "focus": { "x": 0.40, "y": 0.55 }, "salientWidth": 0.62 } },
    { "id": "a3", "sha256": "77de…", "width": 6048, "height": 4024,
      "sources": [ { "kind": "local", "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1260.jpg" } ],
      "analysis": { "room": "Kök", "category": "Interiör",
                    "focus": { "x": 0.58, "y": 0.50 }, "salientWidth": 0.30 } },
    { "id": "a4", "sha256": "c03a…", "width": 6048, "height": 4024,
      "sources": [ { "kind": "local", "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1302.jpg" } ],
      "analysis": { "room": "Altan", "category": "Exteriör",
                    "focus": { "x": 0.45, "y": 0.60 }, "salientWidth": 0.55 } },
    { "id": "a5", "sha256": "e91b…", "width": 6048, "height": 4024,
      "sources": [ { "kind": "local", "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1355.jpg" } ],
      "analysis": { "room": "Trädgård", "category": "Exteriör",
                    "focus": { "x": 0.50, "y": 0.45 }, "salientWidth": 0.90 } }
  ],

  "style": {
    "defaultTransition": { "type": "crossfade", "duration": 0.5 },
    "easing": "easeInOut",
    "background": { "type": "blur", "amount": 0.6 }
  },

  "timeline": [
    { "asset": "a1", "duration": 3.0, "fit": "cover",
      "motion": { "from": { "cx": 0.30, "cy": 0.47, "zoom": 1.00 },
                  "to":   { "cx": 0.70, "cy": 0.47, "zoom": 1.04 } } },
    { "asset": "a2", "duration": 2.6, "fit": "cover",
      "motion": { "from": { "cx": 0.62, "cy": 0.55, "zoom": 1.00 },
                  "to":   { "cx": 0.28, "cy": 0.55, "zoom": 1.00 } },
      "transitionIn": { "type": "push", "direction": "left", "duration": 0.5 } },
    { "asset": "a3", "duration": 2.6, "fit": "cover",
      "motion": { "from": { "cx": 0.58, "cy": 0.50, "zoom": 1.00 },
                  "to":   { "cx": 0.58, "cy": 0.50, "zoom": 1.12 } } },
    { "asset": "a4", "duration": 2.6, "fit": "cover",
      "motion": { "from": { "cx": 0.45, "cy": 0.60, "zoom": 1.12 },
                  "to":   { "cx": 0.45, "cy": 0.58, "zoom": 1.00 } } },
    { "asset": "a5", "duration": 3.4, "fit": "contain-blur",
      "motion": { "from": { "cx": 0.50, "cy": 0.45, "zoom": 1.00 },
                  "to":   { "cx": 0.50, "cy": 0.45, "zoom": 1.06 } },
      "transitionIn": { "type": "crossfade", "duration": 0.6 } }
  ],

  "audio": null,
  "overlays": [],
  "brand": null,

  "outputs": [
    { "id": "vertical", "aspect": "9:16", "width": 1080, "height": 1920, "fps": 30,
      "encoding": { "codec": "h264", "bitrateMbps": 14, "audio": "aac-silent" } }
  ],

  "provenance": {
    "generator": "PhotoFlow macOS 1.x / ReelSelector v1",
    "autoSelection": [
      { "asset": "a1", "slot": "opening", "reason": "Fasad, kvalitet 0.82" },
      { "asset": "a5", "slot": "closing", "reason": "Trädgård, skiljer sig från öppningen" }
    ],
    "edits": [ { "at": "2026-10-03T09:20:41Z", "by": "photographer", "op": "reorder" } ]
  }
}
```

Total längd i exemplet: 3,0 + 2,6 + 2,6 + 2,6 + 3,4 = 14,2 s minus 4 övergångar (0,5 + 0,5 + 0,5 + 0,6 = 2,1 s) = **12,1 s**.

### 5.3 Bildreferenser (`assets[].sources`)

| `kind` | Exempel | Används av |
|---|---|---|
| `local` | Relativ sökväg från spec-filens mapp | macOS-appen (samma princip som relativa symlänkar i sessionen) |
| `url` | `https://…/assets/9f2c….jpg` (signerad, tidsbegränsad) | Webbredigeraren och förhandsvisningen |
| `store` | `{"kind":"store","key":"objects/<id>/9f2c….jpg"}` | Backend/molnrenderare |

**`sha256` är identiteten.** En plattform som inte hittar en källa letar på hash i sitt eget lager. Det gör också att mäklarens ändringar kan synkas tillbaka till Mac-appen, eftersom asset-ID och hash är oförändrade. Webben laddar en nedskalad variant (t.ex. 1600 px) för förhandsvisning, och slutrenderingen använder originalet.

### 5.4 Normativa formler (det som håller preview och slutrender lika)

Formlerna dokumenteras i `docs/reel-spec-v1.md` tillsammans med ett JSON Schema (`reel-spec-v1.schema.json`), och varje renderare ska följa dem exakt.

- **Tid:** Bildruta *n* visas vid t = n / fps. Klipp *i* börjar vid start(i) = start(i−1) + duration(i−1) − transitionIn(i).duration. Övergången ligger alltså **inom** båda klippens längd.
- **Rörelseförlopp:** p = clamp((t − start)/duration, 0, 1), sedan e = easing(p). `easeInOut` definieras som smoothstep: e = p²(3 − 2p). `linear`: e = p.
- **Utsnitt ("cover"):**
  - Basutsnittet är det största utsnitt med ramens bildförhållande som ryms i bilden.
  - Vid zoom z har utsnittet storleken bas / z.
  - Mittpunkten är (cx, cy) interpolerat linjärt med e och klampas så att utsnittet ligger inom [0,1]².
  - Zoom interpoleras **geometriskt**: z = z₀ · (z₁/z₀)^e. Det ger jämn upplevd hastighet.
- **contain-blur:** förgrunden skalas så att hela bilden ryms och zoomas sedan med z kring (cx, cy). Bakgrunden är samma bild i "cover", gaussisk oskärpa med σ = amount · 0,05 · ramens höjd.
- **crossfade:** opacitet för det inkommande klippet = e(lokal övergångstid). Blandningen görs i linjärt ljus (sRGB → linjärt → blanda → sRGB) **[Antagande: det ser bäst ut; alternativet är att blanda i sRGB, vilket är enklare att matcha på webben. Beslut tas i Fas 1a.]**
- **push:** förskjutning = e · ramens bredd i den angivna riktningen.

### 5.5 Framtida textlager (förberett i v1, används i Fas 3)

```json
"brand": { "id": "maklarbyran-x", "logo": "asset:logo1", "primaryColor": "#0B3D2E", "font": "Inter" },
"overlays": [
  { "type": "title",   "text": "Lindvägen 12, Tyresö", "from": 0.3, "to": 2.8,
    "position": "lowerThird", "style": "brand" },
  { "type": "badge",   "text": "Visning sön 12/10 13–14", "from": 3.0, "to": 9.0, "position": "top" },
  { "type": "endCard", "duration": 2.5, "fields": ["logo","agentName","agentPhone","price"] }
]
```

- Positioner anges som namngivna platser plus säkra marginaler, inte i pixlar. Då fungerar de i alla format och hamnar inte under TikToks och Instagrams egna knappar.
- Typsnitt måste vara ett som alla renderare har tillgång till: bäddas in som asset eller hämtas från Google Fonts med fri licens.

---

## 6. Arkitektur

```
            ┌──────────────────────────── Fas 1 ───────────────────────────┐
 Lightroom  │  macOS PhotoFlow                                             │
  export ──►│  ReelImageAnalyzer ─► ReelSelector ─► ReelMotionPlanner      │
  (FÄRDIGA) │        │                  (ren logik, testad)                │
            │        ▼                         │                           │
            │  reel_analysis.json        ReelSpec (reel.json)              │
            │                                  │                           │
            │                 ReelTimeline (ren: spec + t → bildrutans     │
            │                 tillstånd)                                   │
            │                 ┌───────────────┴──────────────┐             │
            │          Live-förhandsvisning          ReelRenderer          │
            │          (Core Image → MTKView)       (AVAssetWriter)        │
            │                                              │               │
            │                              <adress> FILM/reel_9x16.mp4     │
            └──────────────────────────────────────────────────────────────┘
                         │ ladda upp spec + bilder (Fas 2)
                         ▼
   ┌─────────────── Backend (liten) ────────────────┐      ┌──────────────┐
   │ Objekt/specar (rev.), bildlager (EU), länkar,  │◄────►│ Webbredigerare│
   │ godkännanden, renderkö, mäklarens arkiv        │      │ (mobil, TS,  │
   └──────┬─────────────────────────┬───────────────┘      │ Canvas-      │
          │ renderjobb              │ utkast (Fas 4)       │ förhandsvisn.)│
          ▼                         ▼                      └──────────────┘
   Renderare: Mac (Fas 2)    Publiceringslager:
   eller moln (Fas 5)        hanterad tjänst (Upload-Post/Zernio/…)
                             via mäklarens OAuth → TikTok-inkorg,
                             YouTube privat, FB-utkast; IG via dela-knapp
```

### 6.1 Var renderingen sker

| Alternativ | Fördelar | Nackdelar | När |
|---|---|---|---|
| **Lokalt i macOS (AVFoundation + Core Image)** | Inga kostnader, högsta kvalitet, full kontroll, inga moln-/GDPR-frågor, passar projektets Swift-stil | Bara när Macen är igång | **Fas 1–2** |
| Mac som renderserver för webbändringar | Samma renderare som Fas 1, alltså identiskt resultat | Väntetid om Macen är avstängd | Fas 2 |
| Molnrenderare med ffmpeg (egen) | Billigt, alltid tillgängligt | Ny implementation av formlerna (filtergraf eller rendering bild för bild) | Fas 5 |
| Remotion (React) på Lambda | Samma TS-kod för webbförhandsvisning och slutrender ger exakt samma resultat; ca $0,02 per minut video på Lambda ([Remotion kostnadsexempel](https://www.remotion.dev/docs/lambda/cost-example)) | Gratis bara för individer och bolag med högst 3 anställda. Annars "Automators" $0,01 per render, minst $100/mån **[Verifierat: [licens](https://raw.githubusercontent.com/remotion-dev/remotion/main/LICENSE.md), [pris](https://www.remotion.dev/docs/license/pricing)]**. Kräver headless Chrome. | Alternativ i Fas 5 om webben blir huvudplattform |
| Hanterad JSON-till-video (Shotstack, Creatomate) | Inget eget renderjobb | Eget JSON-format (inlåsning), webbpreviewn blir inte identisk. Pris: Shotstack ca $0,20–0,30/min, Creatomate från $54/mån ([Shotstack](https://shotstack.io/pricing/), [Creatomate](https://creatomate.com/pricing)) | Avråds |
| editly (Node + ffmpeg, MIT) | Deklarativ JSON, öppen källkod ([mifi/editly](https://github.com/mifi/editly)) | Annat schema, Ken Burns-semantiken är inte exakt styrbar | Möjlig byggsten för en ffmpeg-renderare |

### 6.2 Hur preview och slutrender hålls lika

1. **En enda ren tidslinjefunktion per språk:** `ReelTimeline.state(at: t)` → lista av lager (asset, utsnitt, opacitet, förskjutning, oskärpa). Den är ren matematik utan grafik-API och skrivs en gång i Swift och en gång i TypeScript.
2. **Gemensamma testvektorer:** `reel-timeline-vectors.json` innehåller ett antal specar och tidpunkter med förväntade utsnitt och opaciteter. Båda implementationerna testas mot samma fil. Då upptäcks avvikelser som en siffra, inte som en känsla.
3. **Golden frames:** varje renderare renderar t.ex. t = 0,0 / 2,75 / 6,0 / 12,0 för en referensspec. Bilderna jämförs med SSIM eller PSNR mot referensbilder med tolerans (färghantering och skalning skiljer alltid lite).
4. **På Mac är förhandsvisning och export samma kod.** Förhandsvisningen ritar `ReelTimeline` + Core Image i realtid via `MTKView`/`CIRenderDestination` i låg upplösning. Exporten kör samma `renderFrame(t)` till `AVAssetWriter` i full upplösning. Ett alternativ är `AVPlayer` + `AVVideoComposition`, men det kräver en källvideo eller en egen compositor. Rendering bild för bild är enklare och helt deterministisk.

---

## 7. Plattformsval för mäklarens regi

| | macOS-only | Webbapp (mobil först) | iOS-app |
|---|---|---|---|
| Mäklaren kan ändra själv | Nej (fotografen gör ändringar på uppdrag) | Ja | Ja |
| Installation | – | Ingen, bara en länk | App Store/TestFlight. Kräver betalt Apple Developer Program för distribution; i dag finns bara Development-certifikat |
| Utvecklingskostnad | Lägst | Medel: TS-version av tidslinjen + Canvas + liten backend | Hög: ny app, men specen kan dela Swift-kod via `Sources/Shared` |
| Förhandsvisning inline | Ja (Core Image) | Ja (Canvas/WebGL) | Ja (samma Swift-kod som Mac) |
| Dela till IG/TikTok med inbyggt redigeringsläge och musik | – | Ja, via Web Share API med filer (Safari 15+) ([web.dev](https://web.dev/articles/web-share), [Bits and Pieces](https://blog.bitsrc.io/sharing-files-from-ios-15-safari-to-apps-using-web-share-c0e98f6a4971)). Att IG/TikTok syns som mål är **[Antagande, testas på riktig iPhone]** | Ja, via TikTok Share Kit ([tiktok-opensdk-ios](https://github.com/tiktok/tiktok-opensdk-ios)) och Instagram "Sharing to Reels" ([TechCrunch](https://techcrunch.com/2023/10/13/instagrams-sharing-to-reels-feature-opens-up-to-all-app-developers)) |
| Fungerar för mäklare med Android/PC | – | Ja | Nej |

**Rekommendation:**

- **Steg 1 (Fas 1): macOS-only.** Det bevisar värdet med noll infrastruktur. Fotografen kan ta emot ändringsönskemål via telefon eller sms och justera på 30 sekunder.
- **Steg 2 (Fas 2): webbapp för mäklaren.** Den är mobilanpassad, länkbaserad och kräver ingen inloggning i första versionen. Länken är en hemlig token per objekt med utgångsdatum. Senare kan magic-link-inloggning per mäklare läggas till.
- **iOS-app bara om** något av följande inträffar: webbdelningen till IG/TikTok visar sig fungera dåligt, mäklarna efterfrågar push-notiser eller offline-läge, eller ni ändå skaffar Apple Developer Program för PhotoFlow Fält. Placera Swift-delen av specen (`ReelSpec`, `ReelTimeline`) i `Sources/Shared/` redan nu, så är dörren öppen. Den mappen kompileras redan in i både Mac- och iOS-målet enligt `project.yml`.

---

## 8. Publicering

### 8.1 Vad plattformarnas egna API:er tillåter (oktober 2026)

| Plattform | Video via API | **Utkast/opublicerat?** | Konto och krav | Begränsningar |
|---|---|---|---|---|
| **TikTok** | Ja | **Ja: "Upload to inbox".** Videon hamnar som utkast i mäklarens TikTok-inkorg och hon gör klart (ljud, text) och publicerar i appen. Scope `video.upload` ([TikTok Upload API](https://developers.tiktok.com/doc/content-posting-api-reference-upload-video)) | Utkastflödet kräver **inte** TikToks audit enligt flera oberoende källor ([vorplabs](https://vorplabs.com/agent-tools/tiktok-content-posting-api), [postpeer](https://www.postpeer.dev/blog/best-tiktok-posting-api)). TikToks egen dokumentation nämner inte saken. **Direct Post** kräver audit; utan audit blir allt `SELF_ONLY` och max 5 användare per 24 h ([TikTok riktlinjer](https://developers.tiktok.com/doc/content-sharing-guidelines)) | Max 5 väntande utkast per 24 h och användare, 6 anrop/min. PULL_FROM_URL kräver verifierad domän ([Media Transfer](https://developers.tiktok.com/doc/content-posting-api-media-transfer-guide)). Postiz anger att utkastet måste göras klart inom 24 h ([Postiz docs](https://docs.postiz.com/public-api/providers/tiktok)), ej bekräftat av TikTok |
| **Instagram** | Ja, Reels | **Nej.** En container som inte publiceras inom 24 h förfaller ([Meta Content Publishing](https://developers.facebook.com/docs/instagram-platform/content-publishing/)). Närmast är *trial reels* (`trial_params`, `graduation_strategy: MANUAL`), som visas för icke-följare och som mäklaren sedan själv "graduerar" till vanlig reel | Professionellt konto (Business/Creator) kopplat till en sida. För andras konton krävs **Advanced Access, Meta App Review och Business Verification**, i praktiken veckor ([singhamandeep](https://singhamandeep.com/instagram-api-advanced-access-approval/), [Meta-forum](https://communityforums.atmeta.com/discussions/Questions_Discussions/business-verification-in-review-10-days-%E2%80%94-blocking-app-review-submission/1372323)). Standard Access räcker för konton som har en roll i appen, vilket fungerar för en pilot | 100 API-publiceringar per 24 h. Videon måste ligga på en publik URL. IG:s musikbibliotek är inte tillgängligt via vanliga API:t ([postproxy](https://postproxy.dev/blog/instagram-reels-api-publishing-guide/)) |
| **Facebook-sida** | Ja, Reels | **Ja:** `video_state: DRAFT` (även SCHEDULED) ([Meta Reels Publishing](https://developers.facebook.com/docs/video-api/guides/reels-publishing)) | `pages_manage_posts` m.fl. Samma Meta-granskning som ovan för andras sidor | 3–90 s, 9:16, 30 publiceringar per 24 h |
| **YouTube** | Ja, Shorts automatiskt | **I praktiken ja:** `privacyStatus: private` (eller `unlisted`), som mäklaren gör offentlig i Studio. `publishAt` för schemaläggning ([videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert)) | Ogranskade API-projekt skapade efter 28/7 2020 får **bara** ladda upp privat, vilket passar utkastfallet. Audit krävs för offentligt. `youtube.upload` är ett känsligt scope, och Googles OAuth-verifiering behövs för fler än testanvändare **[Antagande om exakta gränser]** | Video Uploads-kvot: 100 anrop per dag och projekt (enligt dokumentationen) |
| **LinkedIn** | Ja | **Nej:** `PUBLISHED` är enda tillåtna värdet när man skapar ett inlägg ([Posts API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api)) | `w_member_social` (person), `w_organization_social` (företagssida, admin- eller innehållsroll) | Lägre prioritet för fastighetsreels |

**Slutsats:** "Utkast i mäklarens konto" går att göra på riktigt på **TikTok, YouTube (privat) och Facebook-sidor**. På **Instagram**, som är troligast viktigast för mäklare, går det inte. Där är det realistiska:

- **(a)** Delningsknapp från mobilen till Instagram, där mäklaren hamnar i Instagrams redigeringsläge med musik. Detta rekommenderas.
- **(b)** Direktpublicering först efter att mäklaren tryckt "Publicera" i vårt gränssnitt. Godkännandet i vårt UI fungerar då som utkastet.
- **(c)** Trial reel.

### 8.2 Integrationsalternativ

| Alternativ | Licens/mognad | Självhosting | Kanaler | Video/Reels/Shorts | Utkast | Kostnad ca |
|---|---|---|---|---|---|---|
| **Egen integration per plattform** | – | Ja | Valfritt | Ja | Det API:erna tillåter | Utvecklingstid plus egna granskningar hos Meta, TikTok och Google |
| **[opencoredev/social-sdk](https://github.com/opencoredev/social-sdk)** | MIT, TypeScript, version 0.x (0.6 med Postiz-backend), ca 400 stjärnor. Ungt projekt | Ja (bibliotek, Node 22+) | Bluesky, IG, LinkedIn, Threads, TikTok, X, YouTube direkt, plus *managed backends* Zernio, Post for Me, PostFast, Postiz | Delvis dokumenterat | Inte dokumenterat | Gratis (men egna appgranskningar vid direktadaptrar) |
| **[Postiz](https://github.com/gitroomhq/postiz-app)** | AGPL-3.0, ca 36,7k stjärnor, aktivt | Ja (Docker; **kräver egna utvecklarappar** hos varje plattform) | 30+ | Ja | TikTok `UPLOAD` (inkorg) ([docs](https://docs.postiz.com/public-api/providers/tiktok)) | Cloud $29–99/mån ([blotato](https://www.blotato.com/blog/postiz-pricing)) |
| **[Upload-Post](https://www.upload-post.com/platforms/tiktok/)** | Hanterad | Nej | ca 10 stora + fler | Ja | TikTok-utkast. Har **egen granskad TikTok-app**, så ingen egen audit behövs | Gratis 10 uppladdningar/mån (ej TikTok), sedan $16–24/mån ([pris](https://www.upload-post.com/#pricing)) |
| **[Zernio](https://zernio.com/)** (f.d. Late) | Hanterad | Nej | 14 | Ja | Ej verifierat | 2 konton gratis, sedan $6 → $1 per konto ([källa](https://zernio.com/alternatives/ayrshare)) |
| **[Post for Me](https://www.postforme.dev/pricing)** | Hanterad, koden öppen på GitHub (licens ej verifierad) | Delvis | 9 | Ja | Ej verifierat | $10/mån för 1 000 inlägg. Egna eller deras utvecklarnycklar |
| **[PostFast](https://postfa.st/)** | Hanterad | Nej | Stora | Ja | "Drafts" i Pro-plan | €12–99/mån, API ingår ([socialk.it](https://socialk.it/en/pricing/postfast)) |
| **[Ayrshare](https://www.ayrshare.com/)** | Hanterad, mogen | Nej | 13 | Ja (från Premium) | TikTok-utkast | $149–599/mån ([blotato](https://www.blotato.com/blog/ayrshare-pricing)) |

Utkaststöd per tjänst utöver TikTok har jag inte kunnat verifiera fullt ut. Kontrollera det i respektive API-dokumentation innan ett val görs.

### 8.3 Rekommendation för publicering

1. **Fas 1–2: ingen API-publicering.** Arkivet (mapp, sedan webblänk) plus delningsknapp ger noll granskningar, noll tokenhantering och full kontroll hos mäklaren. Musik väljs i plattformens app, vilket löser licensfrågan.
2. **Fas 4: en hanterad tjänst med mäklarens egna konton.** Varje mäklare kopplar sina konton via tjänstens OAuth-flöde ("connect link"). Vi lagrar bara tjänstens profil-ID, aldrig plattformslösenord. Börja med **Upload-Post eller Zernio** (billigt, egna granskade appar, TikTok-utkast) och lägg ett **tunt eget gränssnitt** ovanpå, gärna via social-sdk:s abstraktion, så att tjänsten kan bytas.
   - TikTok → inkorgsutkast
   - YouTube → privat
   - Facebook-sida → DRAFT
   - Instagram → "Publicera nu/schemalägg" först efter uttryckligt godkännande, annars delningsknappen
3. **Egen direktintegration** bara om volymen motiverar det, eller om tjänsterna inte klarar utkast på rätt sätt. Starta i så fall Meta Business Verification för Digido AB tidigt, eftersom det tar veckor.

### 8.4 Kontoägarskap, integritet och GDPR

- **Mäklaren äger sina konton.** Publicering sker alltid i hennes namn och efter hennes aktiva val. Behörigheter kan återkallas, både i vårt gränssnitt och hos plattformen.
- **Personuppgifter:** bilder på någons hem kopplade till adress, kanske personer i bild, och mäklarens kontaktuppgifter och OAuth-tokens. Det kräver:
  - Biträdesavtal (DPA) med backend- och lagringsleverantör och med publiceringstjänsten.
  - **Lagring inom EU/EES.** Kontrollera var Upload-Post, Zernio m.fl. lagrar data **[ej verifierat]**.
  - Gallringsregel, t.ex. att bilder och specar raderas 90 dagar efter godkännande eller när objektet är sålt.
  - Krypterade tokens, minsta möjliga scope och loggning av publiceringar.
- **Säljarens samtycke** till sociala medier är mäklarens ansvar, men gränssnittet bör ha en bekräftelseruta.
- **Upphovsrätt:** fotografen äger bilderna och filmen är ett derivat. Villkor med mäklaren bör ange att filmen får användas för marknadsföring av objektet.
- **App-granskningar som krävs vid egen integration:** Meta App Review + Business Verification (IG/FB), TikTok audit (bara för Direct Post), Google OAuth-verifiering + YouTube API-audit (bara för offentlig uppladdning). Med en hanterad tjänst slipper man i regel dessa, eftersom tjänsten har egna godkända appar.

### 8.5 Musik

- **Rekommendation för Fas 1–2:** ingen inbränd musik. TikTok-utkast och Instagram via delning låter mäklaren välja ett aktuellt ljud i appen. Det ger bäst räckvidd och kräver ingen licens från oss. Inbränd licensierad musik kan krocka med plattformarnas Content ID-system.
- **Senare (Fas 3+):** valfri inbränd musik från en licenskälla.
  - **Epidemic Sound API** har gratisnivå för prototyper, betald nivå för drift och "safelisting" mot YouTube, IG, TikTok och FB ([Epidemic Sound developers](https://www.epidemicsound.com/business/developers/)).
  - **Pixabay Music** är gratis för kommersiell användning utan krav på attribution ([källa](https://www.foximusic.com/blog/best-royalty-free-music-platform-for-creators/)). Kontrollera dock villkoren för vidareförmedling via en tjänst.
  - Instagrams `audioConfiguration` för licensierade spår kräver Facebook Login-varianten ([postproxy](https://postproxy.dev/blog/instagram-reels-api-publishing-guide/)) och är mindre moget **[osäkert]**.

---

## 9. Fasindelad plan

### Fas 1 – MVP i macOS-appen (autonomt förslag + justering + lokal rendering)

**Mål:** Fotografen drar in mappen med färdiga bilder och har en färdig MP4 i 9:16 inom en minut, med möjlighet att ändra urval och ordning.

**Föreslagna filer** (i projektets stil: ren logik i `nonisolated enum`, svenska kommentarer, tester i `PhotoFlow/Tests/`):

| Fil | Typ | Innehåll |
|---|---|---|
| `Sources/Shared/ReelSpec.swift` | `struct ReelSpec: Codable, Sendable, Equatable` | Schema v1 (avsnitt 5), `currentVersion`, avkodning som tål okända fält. Ligger i `Shared` så att iOS-målet kan använda den senare. |
| `Sources/Shared/ReelTimeline.swift` | `nonisolated enum ReelTimeline` | `clipStarts(spec)`, `totalDuration(spec)`, `state(at:t, spec, outputSize) -> [LayerState]`, `cropRect(...)` med klampning och easing. **Kärnan, helt utan grafik.** |
| `Sources/Services/Reel/ReelImageAnalyzer.swift` | `nonisolated enum` + async-funktion | Kör PhotoQualityService-måtten, saliency och (om tillgängligt) PhotoDescriptionService på färdiga bilder. Cachar i `reel_analysis.json` nycklat på SHA-256. |
| `Sources/Services/Reel/ReelSelector.swift` | `nonisolated enum` | Filter, poäng, mallval (villa/lägenhet), MMR, reservlogik och motivering. Indata är en ren `[Candidate]`-struktur. |
| `Sources/Services/Reel/ReelMotionPlanner.swift` | `nonisolated enum` | Väljer fit (cover/contain-blur), rörelse, riktning, längder och övergångar från analys och format. |
| `Sources/Services/Reel/ReelRenderer.swift` | `actor` eller `nonisolated` + async | `renderFrame(t, size) -> CIImage` (delas med förhandsvisningen) och `export(spec, output, progress) async throws` via `AVAssetWriter` (H.264, 30 fps, tyst AAC-spår, faststart). Respekterar avbrytning som `analyzeSession`. |
| `Sources/Services/AddressFolderLayout.swift` | utökas | `reelDirName` (`"<adress> FILM"`) och `finishedDirName` (`"<adress> FÄRDIGA"`), så att mappnamnen bara finns på ett ställe. |
| `Sources/Views/Reel/ReelEditorView.swift` | SwiftUI | Tre delar: (1) förhandsvisning (`MTKView` via `NSViewRepresentable` och `ReelRenderer.renderFrame`, spela/pausa/skrubba), (2) filmremsa med dra-och-släpp för ordning och längd per klipp, (3) kandidatrutnät med poäng och motivering. Formatväljare och knappen "Rendera". |
| `Sources/Views/Reel/ReelMotionEditor.swift` | SwiftUI | Visar bilden med start- och slutram som går att dra, plus förval ("Zooma in", "Panorera ←/→"). |
| `Sources/PhotoFlowApp.swift` | utökas | Nytt `Window("Bildspel", id: "reel")`. Öppnas från en verktygsknapp i `DashboardView` och från adressraderna i `SessionHistoryView`. |
| `SourcesCLI/` | utökas | `photoflow-cli reel --input <FÄRDIGA> --output <FILM> [--count 5] [--aspect 9:16] [--json]` för headless körning och smoketest. |
| `PhotoFlow/Models/DashboardStepInfo.swift` | – | Påverkas inte. Modulen är **inget pipelinesteg**, eftersom den körs dagar senare efter redigeringen. |

**Placering i UI:t:** Ett eget fönster, eftersom arbetsflödet ligger utanför pipelinen. Fönstret kan öppnas på tre sätt:

1. **Bildspel…** i verktygsfältet. Då väljs en mapp, och appen föreslår adress genom att jämföra mappnamnet med sessionens `AddressRecord`.
2. Ikonen **Film** på varje adress i Historik. Den öppnar `FÄRDIGA`-mappen om den finns, annars en mappväljare.
3. Dra en mapp till appikonen.

Senare kan en App Intent "Skapa bildspel för adress" läggas till, i samma mönster som `StartPipelineIntent`.

**Delsteg och storlek** (grov uppskattning av agentarbete; S ≈ 1 dag, M ≈ 2–4 dagar, L ≈ 1 vecka):

| Delsteg | Innehåll | Storlek | Verifiering |
|---|---|---|---|
| **1a** Spec + tidslinje | `ReelSpec`, `ReelTimeline`, `docs/reel-spec-v1.md`, JSON Schema, testvektorfil | M | `ReelSpecCodingTests` (golden JSON fram och tillbaka, okända fält ignoreras, version), `ReelTimelineTests` (klippstarter, total längd, övergångsöverlapp, klampning vid zoom 1.0 i hörn, geometrisk zoom, alla tre bildförhållanden) |
| **1b** Analys + urval + rörelse | `ReelImageAnalyzer`, `ReelSelector`, `ReelMotionPlanner`, `PhotoQualityService`-ingångar görs interna | M | `ReelSelectorTests` med syntetiska kandidater (dubbletter bort, utility bort, villamall börjar med fasad, lägenhetsmall utan fasad, MMR undviker två snarlika, reserv när rum saknas), `ReelMotionPlannerTests` (panorering när motivet är bredare än ramen, alternerande riktning, tempotak) |
| **1c** Renderare | `renderFrame` + `AVAssetWriter`-export | M | `ReelRendererTests`: rendera en spec på 2 s i 270×480, kontrollera längd, antal bildrutor, fps, codec, ljudspår och att bildruta 0 ≈ golden PNG (SSIM-tolerans) |
| **1d** UI + CLI + kalibrering | `ReelEditorView`, rörelseeditor, fönster, CLI, arkivmapp | L | Manuellt: 5–10 riktiga objekt. Fotografen väljer "sina 5" blint och vi mäter överlapp med algoritmen (mål: minst 3 av 5) och justerar vikterna. Spela upp MP4 på iPhone och prova uppladdning manuellt till IG/TikTok |

**Risker i Fas 1:**

- Prestanda i förhandsvisningen med bilder i full upplösning. Åtgärd: förskalade texturer på cirka 2500 px i förhandsvisningen och original bara vid export.
- Färghantering (Display P3 eller sRGB i exporterade JPEG). Åtgärd: allt renderas i sRGB/Rec.709 och taggas korrekt i MP4.
- Foundation Models saknas på macOS 26. Åtgärd: reservlogiken i 3.2.

**Inte i Fas 1:** musik, textlager, webben, backend, publicering.

### Fas 2 – Mäklaren i loopen (webbgranskning + arkiv)

- **Innehåll:**
  - Liten backend: objekt, specar med `revision`, bildlager i EU, länkar med token, statusflöde `draft → proposed → approved → rendered`.
  - "Skicka till mäklare" i Mac-appen: laddar upp spec + bilder i webbstorlek och skickar länken.
  - Mobil webbredigerare i TypeScript: `ReelTimeline`-port + Canvas 2D/WebGL-förhandsvisning, byt/ordna/längd, godkänn.
  - Rendering av godkända specar på fotografens Mac via polling av en kö, sedan uppladdning av MP4 till arkivet.
  - Arkivsida per mäklare med delningsknapp (Web Share).
- **Storlek:** L–XL (2–4 veckor).
- **Konflikter mellan samtidiga ändringar:** optimistisk låsning på `revision`. Vid konflikt visas "mäklaren har ändrat, ladda om".
- **Verifiering:**
  - Samma testvektorer passerar i Swift och TS.
  - Golden frames från webbens Canvas mot Mac-renderaren.
  - Riktig iPhone: Web Share till IG Reels och TikTok fungerar.
  - En pilotmäklare.
- **Risker:**
  - Webbdelning till IG/TikTok kan bete sig olika mellan iOS-versioner **[Antagande]**.
  - Macen måste vara igång för att rendera. Åtgärd: tydlig status ("Renderas när fotografens dator är igång").

### Fas 3 – Text, varumärke och fler format

- **Innehåll:**
  - Mäklarprofiler (logga, färg, typsnitt, kontaktuppgifter).
  - Textlager: adress, visningstid, pris, slutkort.
  - 1:1 och 16:9 från samma spec.
  - Valfri musik från licenskälla med takttsynk.
  - Undertexter i separat fil om det behövs.
- **Storlek:** L.
- **Verifiering:**
  - Säkra zoner mot IG/TikTok-gränssnittet. Kontrollera med skärmbilder från riktiga appar.
  - Textrendering identisk på Mac och webb (typsnitten bäddas in).
- **Risker:** textlayout är den svåraste delen att hålla identisk mellan renderare. Håll layoutmodellen enkel med namngivna positioner.

### Fas 4 – Publicering till utkast

- **Innehåll:**
  - Integration med en hanterad tjänst (förslagsvis Upload-Post eller Zernio), med mäklarens egna OAuth-kopplingar.
  - Knappar: "Skicka som utkast till TikTok", "Ladda upp privat till YouTube", "Utkast på Facebook-sida", och för Instagram "Publicera/schemalägg" efter bekräftelse.
  - Logg och status per kanal.
  - DPA och GDPR-genomgång.
- **Storlek:** M–L, plus väntan på tjänstens onboarding.
- **Verifiering:** testkonton på varje plattform, verifiera att inget publiceras offentligt utan aktivt val, återkallning av koppling.
- **Risker:** tjänsten ändrar pris eller villkor (åtgärd: tunt eget gränssnitt eller social-sdk), plattformsändringar i API:erna, gränsen på 5 utkast per dygn på TikTok.

### Fas 5 – Skalning (vid behov)

- **Innehåll:** molnrenderare (ffmpeg eller Remotion enligt 6.1) så att Macen inte behövs, eventuellt iOS-app för mäklare, statistik från plattformarna, mallbibliotek.
- **Storlek:** XL. Starta bara om volymen eller mäklarnas efterfrågan motiverar det.

---

## 10. Risker och beslut du behöver ta

### 10.1 Beslut

| # | Fråga | Min rekommendation |
|---|---|---|
| 1 | Bara macOS eller även mäklarregi? | **macOS i Fas 1, mobilwebb i Fas 2.** iOS-app bara om webben inte räcker. |
| 2 | Var ska de färdiga bilderna komma ifrån? | En konvention: Lightroom exporterar till `<adress> FÄRDIGA/` i sessionsmappen. Lightroom-pluginet kan senare få en exportförinställning för detta. |
| 3 | Köra om analysen på färdiga bilder? | **Ja**, med cachning på innehållshash. Gamla taggar används bara som reserv. |
| 4 | Standardformat och längd? | **9:16, 5 bilder, cirka 12–15 s**, crossfade/push och Ken Burns. 1:1 och 16:9 i Fas 3. |
| 5 | Musik inbränd? | **Nej i början.** Mäklaren väljer ljud i TikTok eller Instagram. |
| 6 | Publicering via API, och när? | **Inte före Fas 4.** Arkiv + delningsknapp först. |
| 7 | Egen integration, öppen källkod eller hanterad tjänst? | **Hanterad tjänst** (Upload-Post eller Zernio) bakom ett tunt eget gränssnitt. Postiz självhostat bara om ni vill driva servrar och själva klara Metas och TikToks granskningar. |
| 8 | Renderare för webb och moln? | Egen TS-port av `ReelTimeline` + Canvas för förhandsvisning, Macen som renderare i Fas 2. Ta ställning till Remotion eller ffmpeg i molnet i Fas 5. Kontrollera antalet anställda i Digido AB mot Remotions gräns på högst 3. |
| 9 | Vem äger filmen och kontona? | Mäklaren äger konton och publicering, fotografen äger bilderna. Skriv in användningsrätt i villkoren. |
| 10 | Var lagras data (Fas 2+)? | EU-region, DPA med alla leverantörer, gallring efter 90 dagar eller när objektet är sålt. |
| 11 | Ska mäklaren kunna lägga till bilder utanför fotografens färdiga set? | **Nej i v1.** Bara bland objektets färdiga bilder, så att kvaliteten och upphovsrätten hålls under kontroll. |
| 12 | Apple Developer Program (betalt)? | Behövs inte för Fas 1–4 med webbspåret. Ta upp frågan igen om iOS-appen blir aktuell. |

### 10.2 Risker

| Risk | Sannolikhet/effekt | Åtgärd |
|---|---|---|
| Urvalet känns "fel" för fotografen | Medel/hög | Kalibrering mot verkliga val, synlig motivering, byte med ett klick |
| Ken Burns i 9:16 tappar för mycket av liggande bilder | Hög/medel | Panoreringslogiken + contain-blur. Låt fotografen välja per bild. |
| Förhandsvisning och slutrender skiljer sig mellan plattformar | Medel/hög | Normativa formler, testvektorer, golden frames |
| Instagram saknar utkast-API | Säker | Delningsknapp. Godkännande i vårt UI fungerar som utkast. |
| Meta- och TikTok-granskningar drar ut | Hög vid egen integration | Hanterad tjänst med egna godkända appar |
| Plattformarnas API:er ändras (har skett ofta) | Medel | Abstraktionslager och inga beroenden i Fas 1–3 |
| GDPR (hem och adress, personer i bild) | Medel | EU-lagring, DPA, gallring, samtyckesruta |
| Foundation Models saknas eller är långsam | Låg/medel | Reservlogik med Vision-kategori + MMR |
| Webbdelning till IG/TikTok fungerar inte på alla telefoner | Medel | Testa tidigt i Fas 2. Reserv: ladda ner filen. iOS-app som sista utväg. |

### 10.3 Det jag inte kunnat verifiera

- Om TikToks inkorgsutkast kräver audit. Oberoende källor säger nej, TikToks egen dokumentation säger ingenting.
- Exakt utkaststöd hos Zernio, Post for Me och PostFast.
- Var de hanterade tjänsterna lagrar data.
- Post for Me:s licens.
- Prestanda för analys och rendering på din Mac.
- Hur Instagram och TikTok beter sig som delningsmål från Safari.

Alla dessa testas eller kontrolleras i början av respektive fas.
