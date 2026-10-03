# ReelSpec v1 – normativ beskrivning

Det här dokumentet är facit för schemat `photoflow.reel` version 1 och för formlerna som gör att alla renderare (Swift/Core Image på Mac, Canvas/WebGL på webben, ffmpeg i molnet) ritar samma bild. Referensimplementationen är `PhotoFlow/Sources/Shared/ReelTimeline.swift`; den testas mot `PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json`, som en TypeScript-port ska testas mot med samma tolerans (1e-9).

Orden **ska**/**får** används i RFC-mening. Siffror är dubbla flyttal (IEEE 754 binary64).

## 1. Konventioner

- **Bildkoordinater** är normaliserade: (0,0) uppe till vänster, (1,1) nere till höger, y neråt. Ett utsnitt är en rektangel `{x, y, w, h}` inom [0,1]².
- **Ramkoordinater** är normaliserade på samma sätt, för utbilden (den renderade ramen). `dest` och `offset` anges i dem. `offset.x` är andelar av ramens bredd, `offset.y` andelar av ramens höjd.
- **Ramens bildförhållande** `A = bredd / höjd` för den utbildsstorlek som renderas (t.ex. 9/16 för 1080×1920). Specen är oberoende av format: samma spec renderas i alla `outputs`.
- **Bildens bildförhållande** `I = asset.width / asset.height`.
- Tid anges i sekunder. Bildruta *n* visas vid t = n / fps.
- **Färgrymd:** all blandning sker i **sRGB-kodade värden** (gamma-kodade, 0..1), inte i linjärt ljus. Det är ett medvetet val: det är identiskt med vad en Canvas 2D `globalAlpha` och `ffmpeg blend` gör som standard.

## 2. Schema

Läsare **ska** ignorera okända fält på alla nivåer. Skrivare **bör** skriva JSON med sorterade nycklar och ISO 8601-datum (`2026-10-03T09:12:00Z`, UTC, utan bråkdelssekunder).

| Fält | Typ | Betydelse |
|---|---|---|
| `schema` | sträng | Alltid `"photoflow.reel"`. |
| `version` | heltal | Version av skrivarens schema. Nu 1. |
| `minReaderVersion` | heltal | Lägsta läsarversion som kan tolka filen. En läsare med lägre version **ska** vägra filen. |
| `id` | sträng | Reelens id (UUID). |
| `revision` | heltal | Räknas upp vid varje sparning. |
| `status` | sträng | Fritext, t.ex. `draft`, `approved`. |
| `createdAt`, `updatedAt` | datum | ISO 8601. |
| `updatedBy` | `{role, name?}` | Vem som sparade senast. |
| `property` | `{address, sessionID?, kind?}` | Objektet filmen gäller. |
| `assets[]` | lista | Se nedan. |
| `style` | objekt | Se nedan. |
| `timeline[]` | lista | Klippen i ordning. |
| `audio` | `null` | Alltid `null` i v1. Reserverad. |
| `overlays[]` | lista | Reserverad (text). v1-renderare ignorerar den. Varje element har minst `type`. |
| `brand` | objekt eller `null` | Reserverad. |
| `outputs[]` | lista | Exportprofiler: `{id, aspect, width, height, fps, encoding?{codec, bitrateMbps?, audio?}}`. `width`/`height`/`fps` styr renderingen; `encoding` får ignoreras av en webbförhandsvisning. |
| `provenance` | objekt | `{generator, autoSelection?[{asset, slot, reason}], edits?[{at, by, op}]}`. Påverkar inte rendering. |

### 2.1 `assets[]`

`{id, sha256, width, height, sources[], analysis?}`.

- `id` är unikt i reelen och är det `timeline[].asset` pekar på. `width`/`height` är bildens pixelmått *efter* rotation (det visade formatet) och används bara för att räkna `I`; en renderare som laddar en nedskalad variant **ska** behålla `I` från specen.
- `sha256` är bildens identitet. Hittas ingen källa letar läsaren på hash.
- `sources[]`: `{kind: "local", path}` (relativ sökväg från spec-filens mapp), `{kind: "url", url}`, `{kind: "store", key}`.
- `analysis?`: `{room?, category?, focus?{x,y}, salientWidth?}`. Påverkar inte rendering (bara hur förslaget gjordes).

### 2.2 `style`

- `defaultTransition`: `{type, direction?, duration}`. Gäller för **varje klipp utom det första som saknar egen `transitionIn`**. Vill man ha hårt klipp mellan två klipp anger man `{"type":"cut"}` explicit på det klippet.
- `easing`: `"linear"` eller `"easeInOut"`. Används för både kamerarörelse och övergångar.
- `background`: `{type: "blur", amount}` (0..1) eller `{type: "black"}`. Används av `contain-blur`.

### 2.3 `timeline[]`

`{asset, duration, fit, motion, transitionIn?}`

- `duration`: sekunder, > 0.
- `fit`: `"cover"` eller `"contain-blur"`.
- `motion`: `{from, to}` där varje nyckel är `{cx, cy, zoom}`. `cx`, `cy` är mittpunkten i bildkoordinater, `zoom` ≥ 1 är relativt basutsnittet (1 = hela cover-utsnittet).
- `transitionIn`: `{type, direction?, duration}` med `type` ∈ `crossfade`, `cut`, `fadeThroughBlack`, `push`. `direction` ∈ `left`, `right`, `up`, `down` (bara `push`; saknas den används `left`). Ignoreras för klipp 0.

## 3. Tid

Låt klipp *i* ha längd `D[i]` och ange den **effektiva övergången** `T[i]`:

- `T[0]` = ingen övergång.
- För i ≥ 1: `tr = timeline[i].transitionIn ?? style.defaultTransition`. Är `tr.type == "cut"` är det ingen övergång. Annars är övergångens längd `d[i] = clamp(tr.duration, 0, min(D[i−1], D[i]))`; är `d[i] == 0` är det ingen övergång.

Klippstart (`d[i] = 0` om ingen övergång):

```
start[0] = 0
start[i] = start[i-1] + D[i-1] - d[i]
total    = start[last] + D[last]
```

Övergången ligger alltså *inom* båda klippens längd; total längd blir kortare med summan av övergångarna. En giltig spec har `d[i] + d[i+1] <= D[i]`; annars gäller regeln i avsnitt 8 (inget fel, men resultatet är bara definierat av den regeln).

## 4. Easing och rörelse

```
linear(p)    = p
easeInOut(p) = p·p·(3 − 2p)        // smoothstep
e(p)         = easing(clamp(p, 0, 1))
```

För ett klipp *c* med start `s` vid tid `t`:

```
p  = clamp((t − s) / D[c], 0, 1)
e  = easing(p)
cx = from.cx + (to.cx − from.cx)·e
cy = from.cy + (to.cy − from.cy)·e
z  = from.zoom · (to.zoom / from.zoom)^e        // geometrisk interpolation
```

## 5. Utsnitt

### 5.1 `cover`

Basutsnittet är det största utsnittet med ramens bildförhållande `A` som ryms i bilden:

```
om I >= A:  baseW = A / I,  baseH = 1
annars:     baseW = 1,      baseH = I / A
z' = max(z, 1)
w = baseW / z',  h = baseH / z'
x = clamp(cx − w/2, 0, 1 − w)
y = clamp(cy − h/2, 0, 1 − h)
crop = {x, y, w, h}          dest = {0, 0, 1, 1}
```

Utsnittet **klampas** alltså så att det aldrig lämnar bilden (vid zoom 1 med mittpunkt i ett hörn ligger det kvar mot kanten). Utsnittet ritas så att det fyller hela ramen.

Exempel: en 3:2-bild (I = 1,5) ger vid z = 1 `w = 0,375, h = 1` i 9:16, `w = 2/3, h = 1` i 1:1 och `w = 1, h = 0,84375` i 16:9.

### 5.2 `contain-blur`

Förgrunden visar hela bilden, centrerad i ramen, och bakgrunden är en suddig kopia som fyller ramen.

```
Contain-ruta (ramkoordinater):
  om I >= A:  cw = 1,      ch = A / I
  annars:     cw = I / A,  ch = 1
  dest = {(1 − cw)/2, (1 − ch)/2, cw, ch}

Förgrundens utsnitt (bildkoordinater), s = 1 / max(z, 1):
  x = clamp(cx − s/2, 0, 1 − s)
  y = clamp(cy − s/2, 0, 1 − s)
  crop = {x, y, s, s}
```

Förgrunden ritas alltid i `dest`; zoomen sker *inuti* rutan (rutans kanter flyttar sig inte). Vid z = 1 är `crop` hela bilden oavsett (cx, cy).

Bakgrund (bara om `style.background.type == "blur"`; vid `"black"` är bakgrunden svart):

```
backdrop.crop  = cover-utsnittet enligt 5.1 med zoom 1 och samma (cx, cy)
backdrop.dest  = {0, 0, 1, 1}
backdrop.sigma = background.amount · 0,05 · ramens höjd i pixlar     // gaussisk oskärpa i utpixlar
```

Förgrund och bakgrund hör ihop som en grupp: lagrets `opacity` och `offset` gäller hela gruppen (renderaren ritar gruppen först och blandar sedan).

## 6. Lager vid tid t

`state(t)` ger de lager som syns, i ritordning (stigande `z`). `t` klampas först till [0, total]. Det *aktuella* klippet *i* är det med störst index som uppfyller `start[i] <= t`. Ett lager har `asset`, `fit`, `crop`, `dest`, `opacity`, `offset`, `z` och eventuell `backdrop`. **Lager med `opacity <= 0` utelämnas.**

Är `i` ≥ 1, finns en övergång `d[i] > 0` och `t < start[i] + d[i]`, är vi i en övergång med `q = (t − start[i]) / d[i]` (0..1) och `e = easing(q)`. Annars returneras ett enda lager för klipp *i* med `opacity = 1`, `offset = (0,0)`, `z = 1`.

Under övergången är **utgående** lager klipp *i−1* (z = 0) och **inkommande** lager klipp *i* (z = 1); båda följer sin egen rörelse enligt avsnitt 4 (klippens `p` klampas, så utgående fortsätter sin rörelse och inkommande har redan börjat).

### 6.1 `crossfade` (blandning i sRGB)

- Utgående: `opacity = 1`, `offset = (0,0)`.
- Inkommande: `opacity = e`, `offset = (0,0)`.

Pixeln blir `(1 − e)·ut + e·in` direkt på sRGB-kodade värden (vanlig "source over" med alfa `e` ovanpå ett helt täckande utgående lager). Ingen konvertering till linjärt ljus. Vid e = 0 utelämnas inkommande lagret.

### 6.2 `cut`

Ingen övergång: `d = 0`, inget överlapp, alltid ett lager. Klippbytet sker exakt vid `start[i]`.

### 6.3 `push`

Riktningsvektorn `(dx, dy)` är hur innehållet rör sig: `left` = (−1, 0), `right` = (1, 0), `up` = (0, −1), `down` = (0, 1). Båda lagren har `opacity = 1`.

- Utgående: `offset = (dx·e, dy·e)`.
- Inkommande: `offset = (dx·(e − 1), dy·(e − 1))`.

Exempel `left`: utgående glider mot vänster och lämnar ramen vid e = 1, inkommande kommer in från höger (offset +1 vid e = 0, 0 vid e = 1). Förskjutningen är i ramkoordinater; delar utanför ramen klipps bort.

### 6.4 `fadeThroughBlack`

Ramen är svart bakom lagren. Övergångstiden delas i två halvor, och easingen tillämpas på varje halva för sig:

- `q < 0,5`: bara utgående lager, `opacity = 1 − easing(2q)`.
- `q >= 0,5`: bara inkommande lager, `opacity = easing(2q − 1)`.

I exakta mitten (q = 0,5) är opaciteten 0 och inget lager returneras: hela bilden är svart. Vid övergångens start är utgående helt synligt, vid slutet är inkommande det.

## 7. Bildrutor

En renderare som exporterar med `fps` ritar bildruta *n* med `state(n / fps)` för n = 0 .. ceil(total · fps) − 1. Sista bildrutan vid exakt `total` klampas till slutet av sista klippet.

## 8. Kantfall

- Tom `timeline`: total 0, inga lager.
- Övergång längre än det kortaste av de två klippen kortas till det (avsnitt 3).
- Om övergångsfönster överlappar (`d[i] + d[i+1] > D[i]`) gäller regeln "klippet med störst index vars start passerats är aktuellt"; därför kan klipp *i* aldrig synas som utgående efter att klipp *i+1* börjat.
- `zoom < 1` behandlas som 1. En `asset` som saknas ger inget lager.
- Okända `type`-värden i `transitionIn` eller `fit` gör filen oläsbar för v1 (`minReaderVersion` bör höjas av den som inför dem).

## 9. Testvektorer

`timeline-vectors.json` (`PhotoFlow/Tests/Fixtures/Reel/`) innehåller:

- `easing[]`: `{type, p, expected}`.
- `cropRects[]`: `{imageSize [w,h], frameAspect, center [cx,cy], zoom, expected {x,y,w,h}}` för `cover`.
- `timelines[]`: `{name, spec | specFile, clipStarts[], totalDuration, states[]}`. Varje `state` har `t`, `outputSize [w,h]` och `layers[]` med `asset`, `fit`, `crop`, `dest`, `opacity`, `offset {x,y}`, `z` och `backdrop {crop, sigma} | null`. `specFile` pekar på en fil i samma mapp.

Alla tal jämförs med `tolerance` (1e-9). Filen genereras av ett oberoende Python-skript, inte av Swift-koden, så att en avvikelse upptäcks som en siffra. En ny renderare är klar när alla fall går igenom.

## 10. Komplett exempel

Totalt: 3,0 + 2,6 + 2,6 + 2,6 + 3,4 = 14,2 s minus fyra övergångar (push 0,5 + standard 0,5 + standard 0,5 + crossfade 0,6 = 2,1 s) = **12,1 s**. Klippstarter: 0, 2,5, 4,6, 6,7, 8,7.

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
  "updatedBy": {
    "role": "photographer",
    "name": "Fredrik"
  },
  "property": {
    "address": "Lindvägen 12, Tyresö",
    "sessionID": "2B0E…",
    "kind": "house"
  },
  "assets": [
    {
      "id": "a1",
      "sha256": "9f2c…",
      "width": 6048,
      "height": 4024,
      "sources": [
        {
          "kind": "local",
          "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1201.jpg"
        }
      ],
      "analysis": {
        "room": "Fasad",
        "category": "Exteriör",
        "focus": {
          "x": 0.52,
          "y": 0.47
        },
        "salientWidth": 0.71
      }
    },
    {
      "id": "a2",
      "sha256": "1ab8…",
      "width": 6048,
      "height": 4024,
      "sources": [
        {
          "kind": "local",
          "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1244.jpg"
        }
      ],
      "analysis": {
        "room": "Vardagsrum",
        "category": "Interiör",
        "focus": {
          "x": 0.4,
          "y": 0.55
        },
        "salientWidth": 0.62
      }
    },
    {
      "id": "a3",
      "sha256": "77de…",
      "width": 6048,
      "height": 4024,
      "sources": [
        {
          "kind": "local",
          "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1260.jpg"
        }
      ],
      "analysis": {
        "room": "Kök",
        "category": "Interiör",
        "focus": {
          "x": 0.58,
          "y": 0.5
        },
        "salientWidth": 0.3
      }
    },
    {
      "id": "a4",
      "sha256": "c03a…",
      "width": 6048,
      "height": 4024,
      "sources": [
        {
          "kind": "local",
          "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1302.jpg"
        }
      ],
      "analysis": {
        "room": "Altan",
        "category": "Exteriör",
        "focus": {
          "x": 0.45,
          "y": 0.6
        },
        "salientWidth": 0.55
      }
    },
    {
      "id": "a5",
      "sha256": "e91b…",
      "width": 6048,
      "height": 4024,
      "sources": [
        {
          "kind": "local",
          "path": "../Lindvägen 12, Tyresö FÄRDIGA/DSC_1355.jpg"
        }
      ],
      "analysis": {
        "room": "Trädgård",
        "category": "Exteriör",
        "focus": {
          "x": 0.5,
          "y": 0.45
        },
        "salientWidth": 0.9
      }
    }
  ],
  "style": {
    "defaultTransition": {
      "type": "crossfade",
      "duration": 0.5
    },
    "easing": "easeInOut",
    "background": {
      "type": "blur",
      "amount": 0.6
    }
  },
  "timeline": [
    {
      "asset": "a1",
      "duration": 3.0,
      "fit": "cover",
      "motion": {
        "from": {
          "cx": 0.3,
          "cy": 0.47,
          "zoom": 1.0
        },
        "to": {
          "cx": 0.7,
          "cy": 0.47,
          "zoom": 1.04
        }
      }
    },
    {
      "asset": "a2",
      "duration": 2.6,
      "fit": "cover",
      "motion": {
        "from": {
          "cx": 0.62,
          "cy": 0.55,
          "zoom": 1.0
        },
        "to": {
          "cx": 0.28,
          "cy": 0.55,
          "zoom": 1.0
        }
      },
      "transitionIn": {
        "type": "push",
        "direction": "left",
        "duration": 0.5
      }
    },
    {
      "asset": "a3",
      "duration": 2.6,
      "fit": "cover",
      "motion": {
        "from": {
          "cx": 0.58,
          "cy": 0.5,
          "zoom": 1.0
        },
        "to": {
          "cx": 0.58,
          "cy": 0.5,
          "zoom": 1.12
        }
      }
    },
    {
      "asset": "a4",
      "duration": 2.6,
      "fit": "cover",
      "motion": {
        "from": {
          "cx": 0.45,
          "cy": 0.6,
          "zoom": 1.12
        },
        "to": {
          "cx": 0.45,
          "cy": 0.58,
          "zoom": 1.0
        }
      }
    },
    {
      "asset": "a5",
      "duration": 3.4,
      "fit": "contain-blur",
      "motion": {
        "from": {
          "cx": 0.5,
          "cy": 0.45,
          "zoom": 1.0
        },
        "to": {
          "cx": 0.5,
          "cy": 0.45,
          "zoom": 1.06
        }
      },
      "transitionIn": {
        "type": "crossfade",
        "duration": 0.6
      }
    }
  ],
  "audio": null,
  "overlays": [],
  "brand": null,
  "outputs": [
    {
      "id": "vertical",
      "aspect": "9:16",
      "width": 1080,
      "height": 1920,
      "fps": 30,
      "encoding": {
        "codec": "h264",
        "bitrateMbps": 14,
        "audio": "aac-silent"
      }
    }
  ],
  "provenance": {
    "generator": "PhotoFlow macOS 1.x / ReelSelector v1",
    "autoSelection": [
      {
        "asset": "a1",
        "slot": "opening",
        "reason": "Fasad, kvalitet 0.82"
      },
      {
        "asset": "a5",
        "slot": "closing",
        "reason": "Trädgård, skiljer sig från öppningen"
      }
    ],
    "edits": [
      {
        "at": "2026-10-03T09:20:41Z",
        "by": "photographer",
        "op": "reorder"
      }
    ]
  }
}
```
