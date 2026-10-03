# Objektfilm på webben (delsteg 2a och 2b)

Plattformsoberoende webbdel för ReelSpec v1: tidslinjematematik, canvasrenderare och en mobilvänlig redigerare. Den serveras av `server/` (se `server/README.md`) på `/m` (mäklarredigeraren) och `/a` (arkivet). Utan token i adressen fungerar redigeraren som förut helt lokalt: inget laddas upp och "Godkänn" laddar bara ner en uppdaterad `reel.json`.

## Mäklarläge (2b)

`/m#<token>`: token ligger i URL-fragmentet, som webbläsaren aldrig skickar till servern. `src/shareApi.ts` läser det och skickar `Authorization: Link <token>`.

- Läser `GET /api/v1/share` (spec med signerade bild-URL:er, pool, status, renderingar). Bilder på tidslinjen hämtas som w1600, övriga som w480 (full storlek hämtas först när bilden läggs till).
- **Spara** (`PUT /api/v1/share/spec` med `If-Match`) och **Godkänn** (sparar först, sedan `POST /api/v1/share/approve`). Vid 412 visas "Fotografen har ändrat, ladda om." med en knapp som läser in allt på nytt. Längder är begränsade till 0,5–10 s i mäklarläge.
- Medan filmen renderas pollar sidan status och visar länken till arkivet när den är klar.
- `src/archive.ts` (`/a#<token>`): spelar upp renderingarna. **Dela** använder Web Share med fil när `navigator.canShare({files})` stöds (iOS Safari), annars laddas filen ner.
- Allt är samma ursprung och inga inline-skript eller inline-stilar (CSP `script-src 'self'; style-src 'self'`).

## Hur det hänger ihop med Swift-sidan

| Webb | Swift | Not |
|---|---|---|
| `src/reelSpec.ts` | `Sources/Shared/ReelSpec.swift` | Typer + `parseReelSpec` (tål okända fält, svenska felmeddelanden). |
| `src/reelTimeline.ts` | `Sources/Shared/ReelTimeline.swift` | Exakt port. Testas mot `PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json` (tolerans 1e-9) och `example-v1.json` (12,1 s). |
| `src/canvasRenderer.ts` | `Sources/Services/Reel/ReelRenderer.swift` | Ritar bara det `state(at:)` ger. Blandning i sRGB (Canvas 2D `globalAlpha` på gammakodade värden, kontext utan display-p3). contain-blur ritas som grupp på en hjälpcanvas; bakgrunden suddas med `ctx.filter = blur(σpx)` och kanten klampas som `clampedToExtent`. |
| `src/motionPresets.ts` | `ReelMotionPlanner.swift` | De manuella förvalen (zooma in/ut, panorera, hela bilden). Planerarens alternerande tillstånd ersätts av klippets index. Ändrad längd låses (`durationLocked`) som i appen. |

Normativa formler: `docs/reel-spec-v1.md`. Ändra aldrig en formel på ena sidan utan den andra och dokumentet.

## Tester

```sh
cd web/reel
npm test        # node --test "test/*.test.ts"
```

Från repots rot: `node --test "web/reel/test/*.test.ts"`. (Node 25 accepterar inte bara katalogen `web/reel/test/`; använd glob.) Kärnan och testerna har inga npm-beroenden: Node kör `.ts` direkt, så bara "erasable" syntax (inga enums/namespaces/parameter properties) och `import ... from "./x.ts"`.

## Bygga och prova

```sh
cd web/reel
npm install     # bara esbuild
npm run build   # skriver dist/ (index.html, archive.html, styles.css, editor.js, archive.js)
```

Servera `dist/` med valfri statisk server, t.ex. `python3 -m http.server -d dist 8080`, eller `npm run serve` (esbuild `--servedir`, bygger om vid ändring). Öppna sedan `http://localhost:8080/`.

- **Mapp/filer/släpp:** välj mappen med `reel.json` och bilderna. Bilder matchas på filnamnet i `sources[].path` (utan känslighet för versaler och å/ä/ö-normalisering), annars på sha256.
- **Via adress:** `http://localhost:8080/?spec=<url-till-reel.json>`. Lokala sökvägar i `sources` tolkas relativt `reel.json`:s adress. Servern måste ge åtkomst till bilderna (samma ursprung eller CORS). Förberett för backend i nästa steg.

Typkontroll (valfritt, ingen beroende i projektet): `npx -p typescript tsc -p .`

## Redigeraren

Förhandsvisning i specens format med spela/pausa/skrubba, filmremsa (dra i greppet eller upp/ner-knappar, ta bort, längd, rörelseförval), kandidater (bilder i `assets` som inte ligger på tidslinjen) och "Godkänn och ladda ner" (revision +1, status `approved`, `updatedBy.role = "agent"`, poster i `provenance.edits`). "Automatisk" behåller klippets nuvarande rörelse; nya klipp får automatiskt val enligt `ReelMotionPlanner.kind`. Övergångar ändras inte av redigeraren.
