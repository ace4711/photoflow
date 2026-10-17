# ReelSpec v2 – rutor (normativ beskrivning)

Tillägg till `reel-spec-v1.md` (läs den först; avsnitten och begreppen där gäller här). Version 2 lägger till klipp som består av **rutor** (`fit: "panels"`): delar av en bild (montagehalvor), två bilder staplade eller sida vid sida (kollage) och rutor som visas efter varandra i samma klipp (montage i stående format). Allt annat är oförändrat. Referensimplementationen är fortfarande `PhotoFlow/Sources/Shared/ReelTimeline.swift`, TypeScript-porten `web/reel/src/reelTimeline.ts`; båda testas mot `PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json` (fallen som börjar med `panels-`, tolerans 1e-9).

Beslut som tagits för v2 (de står också där de hör hemma nedan):

| Fråga | Beslut |
|---|---|
| Antal rutor | `stack` och `side`: exakt två. `sequence`: två eller fler. |
| Gutter | Andel av ramens **kortsida**, förval **0,006**, klampas till [0, 0,1]. Ritas alltid **svart** (oberoende av `style.background`). |
| Ingångens längd | Egen: `entrance.duration` (förval **0,6 s**), `entrance.stagger` (förval **0,3 s**), båda klampas till högst D/2. Inte kopplad till `transitionIn`. |
| Utan `entrance` | Rutorna står på plats från första bildrutan (samma som `type: "none"`). |
| Sequence-skjutning | Längd `min(0,4, D / (2n))` (för två rutor `min(0,4, D/4)`), riktning vänster, formler som 6.3, centrerad på gränsen mellan rutornas tidsfönster. |
| Övergång in/ut | Hela klippets rutor är en grupp för `opacity` och `offset`, som `contain-blur`-gruppen (5.2). |
| Versioner | `minReaderVersion: 2` om något klipp har `fit: "panels"`, annars 1 (och `version` likadant). Läsare med `currentVersion` 1 vägrar. |

## 1. Schema

### 1.1 Klippet

Ett klipp med `fit: "panels"` har, förutom de vanliga fälten (`duration`, `transitionIn?`, `motionPreset?`, `durationLocked?`, `transitionLocked?`):

| Fält | Typ | Betydelse |
|---|---|---|
| `fit` | `"panels"` | Gör klippet till ett rutklipp. |
| `layout` | `"stack"`, `"side"` eller `"sequence"` | Hur rutorna läggs ut (avsnitt 3). |
| `panels[]` | lista | Rutorna i ordning (se 1.2). `stack`/`side`: exakt 2. `sequence`: 2 eller fler. |
| `gutter?` | tal ≥ 0 | Bara `stack`/`side`. Avståndet mellan rutorna som andel av ramens kortsida. Förval 0,006. |
| `entrance?` | `{type, stagger?, duration?}` | Bara `stack`/`side`. `type` ∈ `slide`, `fade`, `none`. Ignoreras för `sequence`. Saknas = `none`. |
| `asset` | sträng | **Första rutans bild** (`panels[0].asset`). Redigerarens identitet "ett klipp = en primär bild" gäller därmed som förut. |
| `motion` | `{from, to}` | Obligatoriskt som i v1; **ska** vara en kopia av `panels[0].motion`. Renderare läser rutornas `motion`, inte det här fältet (det finns så att v1-verktyg som läser klippets rörelse inte kraschar). |
| `motionPreset` | sträng | Skrivare **bör** sätta `"custom"` på rutklipp, så att fotografens val behandlas som låst (planerare och lås som i v1 ändrar då inte rutornas rörelse). |

`customMotion` används inte i rutklipp. `duration` är klippets hela längd (alla rutor, avsnitt 5).

### 1.2 Rutan

`{asset, source?, motion}`

- `asset`: id i `assets[]`. Olika rutor får peka på samma bild (montagehalvor).
- `source?`: `{x, y, w, h}`, den del av bilden rutan använder, i bildkoordinater (1 i v1). `w, h > 0`, `x, y ≥ 0`, `x + w ≤ 1`, `y + h ≤ 1`. Saknas den (eller är `null`) används hela bilden, `{0,0,1,1}`.
- `motion`: `{from, to}` som i v1 (2.3). `cx, cy` är mittpunkten i **hela bildens** koordinater och `zoom` ≥ 1 är relativt rutans basutsnitt (avsnitt 2). Mittpunkten klampas inom `source` (2.2).

Alla assets som rutorna pekar på ska finnas i `assets[]`. En läsare som laddar bilder eller laddar upp dem ska använda **alla** bilder som något klipp eller någon ruta pekar på, inte bara `clip.asset`.

## 2. Utsnitt i en ruta

Låt `W × H` vara bildens pixelmått och `S = source ?? {0,0,1,1}`. Rutans mål har bildförhållandet `a` (för `stack`/`side`: `dest.w · A / dest.h`, avsnitt 3; för `sequence`: ramens `A`).

### 2.1 Rutans bildförhållande

```
I = (S.w · W) / (S.h · H)
```

Utan `source` är det bildens `I` (reel-spec-v1, avsnitt 1).

### 2.2 Cover inom `source`

`cover`-formeln (v1 5.1) används på den **del av bilden som `source` är**, och resultatet mappas tillbaka till hela bildens koordinater:

```
mittpunkt i source:   l = ((cx − S.x) / S.w,  (cy − S.y) / S.h)
r = cover( bildstorlek (S.w·W, S.h·H),  bildförhållande a,  mittpunkt l,  zoom z )       // 5.1, inkl. klampning
crop = { S.x + r.x·S.w,  S.y + r.y·S.h,  r.w·S.w,  r.h·S.h }
```

Klampningen (5.1) sker alltså **inom `source`**: utsnittet lämnar aldrig rutans del av bilden. Lagrets `crop` är alltid i hela bildens koordinater, och `dest` i ramkoordinater, så en renderare behöver inte veta något om `source`. Är `source` utelämnad är `l = (cx, cy)` och `crop = r`, alltså exakt v1:s cover med bildförhållandet `a`.

### 2.3 Rörelse

Varje ruta har egen `motion` med samma easing och geometriska zoom som v1 avsnitt 4: för `stack`/`side` är rutornas `p = clamp(τ / D, 0, 1)` där `τ` är tiden sedan klippets start, `e = easing(p)`, `cx, cy` linjärt och `z = from.zoom · (to.zoom/from.zoom)^e`. För `sequence` har varje ruta sin egen tidsdel (avsnitt 5).

## 3. Layouter för `stack` och `side`

Låt `A` vara ramens bildförhållande och `g = clamp(gutter ?? 0,006, 0, 0,1)`. Gutter anges som andel av ramens kortsida och räknas om till ramkoordinater:

```
gx = g · min(1, 1/A)        // andel av ramens bredd   (kortsida / bredd)
gy = g · min(A, 1)          // andel av ramens höjd    (kortsida / höjd)
```

**`stack`** (ruta 1 uppe, ruta 2 nere):

```
dest[0] = { 0,            0, 1, (1 − gy)/2 }
dest[1] = { 0, (1 + gy)/2,   1, (1 − gy)/2 }
```

**`side`** (ruta 1 till vänster, ruta 2 till höger):

```
dest[0] = {            0, 0, (1 − gx)/2, 1 }
dest[1] = { (1 + gx)/2,   0, (1 − gx)/2, 1 }
```

Rutorna täcker alltså hela ramen utom gutterbandet i mitten (`gy` respektive `gx` brett). Bandet är **svart** (se 4.2). Rutans bildförhållande för utsnittet är `a = dest.w · A / dest.h`; i 9:16 med `stack` blir det (1 · 0,5625) / 0,4983 ≈ 1,13, så en 3:2-bild (I = 1,5) förlorar ca 25 % av bredden.

**`sequence`**: varje ruta fyller hela ramen, `dest = {0,0,1,1}` och `a = A`; `gutter` används inte.

En renderare som ritar i heltalspixlar **ska** runda `dest`-kanterna till hela pixlar (som för `contain-blur`-förgrunden, 5.2) och rita rutorna med dessa heltalsrutor; då blir gutterbandet ett helt antal pixlar och rutorna får inga halvtäckta kanter.

## 4. Lager och grupper

### 4.1 Lagerformat

`state(t)` ger **ett lager per synlig ruta**, med samma fält som i v1 (`asset`, `fit` = `"panels"`, `crop`, `dest`, `opacity`, `offset`, `z`, `backdrop` = `null`) och ett nytt fält:

```
panel: { index, opacity, offset {x, y} }     // null för lager som inte är rutor
```

- `index`: rutans plats i `panels[]` (0 = första).
- `opacity` (0..1) och `offset` (ramandelar) är **rutans egna** värden inom gruppen: ingången (avsnitt 5) och den interna skjutningen i `sequence`. Rutor med `panel.opacity <= 0` utelämnas.
- Lagrets egna `opacity`, `offset` och `z` är **gruppens**: de är klippets övergångsvärden enligt v1 avsnitt 6 och **lika för alla rutor i klippet**.

Lagren för ett klipp ligger i ritordning (rutornas ordning; i en intern skjutning den utgående före den inkommande).

### 4.2 Grupp: opacitet och förskjutning vid övergångar

Alla lager med `panel != null` och samma `z` är **en grupp**, som `contain-blur`-gruppen i 5.2. En renderare ritar gruppen så här:

1. Fyll en ram av ramens storlek med **svart** (det blir gutterbandet och ytan bakom rutor som ännu inte kommit in).
2. Rita rutorna i listans ordning: varje ruta ritar `crop` i `dest` förskjutet med `panel.offset` (ramandelar av bredd respektive höjd), blandad över med `panel.opacity` (`source over` på sRGB-värden, v1 avsnitt 1), **klippt till ramen**.
3. Blanda hela gruppen ovanpå det som ligger under, med lagrets `opacity` och förskjuten med lagrets `offset`, klippt till ramen.

Eftersom gruppen har en svart botten täcker den ramen helt: vid `crossfade` blandas hela gruppen (inklusive gutterbandet) med utgående klipp enligt 6.1, och vid `push` flyttas hela gruppen (6.3). Övergången in i och ut ur ett rutklipp behandlar alltså klippet som en enda bild; övergångstyperna och -längderna är som i v1 avsnitt 3 och 6, och klippets rutor följer sin egen tid (klampad) under övergången som i v1.

Är ett klipp utgående i en övergång, har dess rutors ingång för länge sedan avslutats (ingången är klar efter `stagger + duration ≤ D`), och `sequence` fortsätter vid den ruta som är aktuell vid tiden.

## 5. Ingång och tid

Låt `D` vara klippets längd och `τ = clamp(t − start, 0, D)` tiden sedan klippets start (för det utgående klippet i en övergång är `τ` sin egen tid, klampad till D).

### 5.1 Ingång (`stack`, `side`)

```
d_in    = clamp(entrance.duration ?? 0,6, 0, D/2)
stagger = clamp(entrance.stagger  ?? 0,3, 0, D/2)
q[k]    = d_in > 0 ? clamp((τ − k·stagger) / d_in, 0, 1) : 1          // k = 0, 1
e[k]    = easing(q[k])                                               // v1 avsnitt 4
```

- `none` (eller `entrance` saknas): `panel.opacity = 1`, `panel.offset = (0,0)`.
- `fade`: `panel.opacity = e[k]`, `panel.offset = (0,0)`. Rutan utelämnas medan `e[k] = 0`.
- `slide`: `panel.opacity = 1` och rutan glider in **hela ramens bredd/höjd**:
  - `stack`: ruta 1 från vänster, ruta 2 från höger: `offset = (−(1 − e[0]), 0)` respektive `(+(1 − e[1]), 0)`.
  - `side`: ruta 1 ovanifrån, ruta 2 underifrån: `offset = (0, −(1 − e[0]))` respektive `(0, +(1 − e[1]))`.

Vid `e = 0` ligger rutan precis utanför ramen (klipps bort) och vid `e = 1` på sin plats; lagret finns med hela tiden (opaciteten är 1). Ruta 2 startar `stagger` sekunder efter ruta 1. Rutorna rör sig bara längs sin egen rad/kolumn och överlappar därför aldrig varandra.

Ingången börjar vid klippets start (`τ = 0`), alltså samtidigt som en inkommande övergång. Skrivare som vill att ingången syns bör därför ge klippet en kort eller mjuk övergång in.

### 5.2 Sequence

Klippets längd delas lika: ruta `k` (0-baserat) har sitt tidsfönster `[k·seg, (k+1)·seg]`, `seg = D/n`, och sin egen rörelse över det:

```
p[k] = clamp((τ − k·seg) / seg, 0, 1)         // easing och rörelse enligt 2.3
```

Mellan ruta `k−1` och `k` (för k = 1 .. n−1) finns en intern **push åt vänster** (v1 6.3) med längden

```
dp   = min(0,4, D / (2n))                      // för n = 2: min(0,4, D/4)
from = k·seg − dp/2                            // skjutningen är centrerad på gränsen k·seg
```

- För `from ≤ τ < from + dp` pågår skjutningen, `q = (τ − from) / dp` och `e = easing(q)`. Två lager: utgående ruta `k−1` med `panel.offset = (−e, 0)` och inkommande ruta `k` med `panel.offset = (1 − e, 0)` (6.3 med riktning `left`: `dx·e` respektive `dx·(e − 1)`). Båda har `panel.opacity = 1`. Rutornas rörelse följer sin egen `p` (klampad), så den utgående har nästan slutat och den inkommande står på sin start.
- Annars visas **en** ruta: den största `k` med `τ ≥ k·seg + dp/2` (ruta 0 om ingen), med `panel.offset = (0,0)`.

Fönstren överlappar aldrig eftersom `dp ≤ D/(2n) = seg/2`. `entrance` och `gutter` ignoreras för `sequence`. Kantfall: om en ruta saknar bild (`asset` finns inte i `assets[]`) utelämnas dess lager; en `sequence` med färre än två rutor, ett `stack`/`side` utan exakt två rutor eller `duration ≤ 0` ger inga lager.

## 6. Övergångar in och ut ur ett rutklipp

Reel-spec-v1 avsnitt 3 och 6 gäller oförändrat; skillnaden är bara vad ett "lager" är. För klipp `i` i en övergång ersätts "klipp i:s lager" av klippets rutlager (avsnitt 4) med övergångens `opacity`/`offset`/`z`:

- `crossfade`: utgående grupp `opacity = 1`, inkommande `opacity = e`; en grupp vars övergångs-`opacity` är 0 utelämnas helt.
- `push`: gruppens `offset` enligt 6.3 (gäller alla rutor lika); rutornas egna `panel.offset` läggs till vid ritningen (steg 2 ovan, före gruppens förskjutning).
- `fadeThroughBlack`: gruppens `opacity` enligt 6.4.
- `cut`: inget.

Ett rutklipp och ett vanligt klipp kan mötas i vilken kombination som helst.

## 7. Versioner och kompatibilitet

- `ReelSpec.currentVersion` / `CURRENT_VERSION` (läsarens version) är **2**.
- En spec med minst ett klipp med `fit: "panels"` skrivs med **`minReaderVersion: 2`** (och `version: 2`). Skrivare sätter det automatiskt (Swift: `ReelSpec.raisingVersions()` vid kodning, `updatingVersions()` vid ombyggnad). En spec utan rutklipp skrivs med `version: 1` och `minReaderVersion: 1`, byte för byte som förut; tar fotografen bort sista rutklippet skrivs alltså åter version 1.
- En läsare med `currentVersion` 1 **ska** vägra en v2-fil (v1 avsnitt 2: `minReaderVersion > currentVersion`). Ingen v1-läsare ska behöva tolka `fit: "panels"`.
- En v2-läsare läser v1-filer utan ändring.
- Läsare ignorerar okända fält som förut. `layout`, `panels`, `gutter` och `entrance` på ett klipp som inte har `fit: "panels"` ignoreras.
- Servern (mäklarens webb) godtar ännu bara version 1 (se plan avsnitt 8.6, R6e); en v2-spec avvisas där med ett tydligt fel.

## 8. Testvektorer

`timeline-vectors.json` har åtta fall som börjar med `panels-` (genererade av Swift-implementationen, verifierade mot TypeScript): `panels-stack-slide`, `panels-side-slide`, `panels-fade-gutter`, `panels-no-entrance-default-gutter`, `panels-source-halves`, `panels-sequence-montage`, `panels-sequence-three-short` och `panels-linear-black`. De täcker alla tre layouter, `source` (montagehalvor, mittpunkt utanför `source` som klampas), gutter (förval, 0, 0,008, 0,02, 0,05), alla ingångstyper (`slide`, `fade`, `none`, saknad), övergång in i och ut ur rutklipp (`crossfade`, `push`, `fadeThroughBlack`, `cut`), `sequence` med två och tre rutor och kort klipp, linjär easing och svart bakgrund, i 9:16, 16:9 och 1:1. Varje lager har fältet `panel` (`{index, opacity, offset}` eller `null`); äldre fall saknar det, vilket läses som `null`.
