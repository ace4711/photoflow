# PhotoFlow

Ett personligt verktyg för fastighetsfotografering: tar råfilerna från kortet och
lämnar ifrån sig färdigsorterade, taggade och HDR-sammanslagna bilder per adress.

Kedjan är: **NEF → DNG → förhandsbilder → kalendermatchning → Vision/AI-taggning →
HDR → adressmappar → metadata → gallring → Lightroom.**

## Delar

| Del | Vad det är |
|---|---|
| `PhotoFlow/` (mål `PhotoFlow`) | macOS-appen. Dashboard med ett kort per steg, granskning och gallring. |
| `PhotoFlow/` (mål `PhotoFlowField`) | **PhotoFlow Fält**, iPhone-app för dikterade fältanteckningar med GPS och tid. Endast Simulator (inget signeringsteam). |
| `PhotoFlow/` (mål `photoflow-cli`) | Kör hela pipelinen headless, utan GUI. |
| `PhotoFlowLR.lrplugin/` | Lightroom Classic-plugin som slår ihop HDR från appens trigger-fil. |
| `scripts/smoke-run.sh` | Kopierar NEF till en temporär mapp, kör pipelinen och verifierar resultatet. Skriver aldrig i källan. |

## Krav

- macOS 26 eller senare, Xcode 27.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — projektfilen genereras ur `PhotoFlow/project.yml`.
- `exiftool` (`brew install exiftool`) — EXIF, förhandsbilder och metadataskrivning.
- Adobe DNG Converter i `/Applications` — NEF → DNG.
- Valfritt: Adobe Lightroom Classic (pluginet), python3 med `cv2`/`numpy` (bara för den äldre OpenCV-baserade HDR-motorn).

Appen kontrollerar verktygen vid start och visar vad som saknas under Inställningar → System.

## Bygga och köra

```bash
cd PhotoFlow && xcodegen generate && cd ..

# macOS-appen
xcodebuild -project PhotoFlow/PhotoFlow.xcodeproj -scheme PhotoFlow build

# Tester
xcodebuild -project PhotoFlow/PhotoFlow.xcodeproj -scheme PhotoFlow test

# iPhone-appen (Simulator)
xcodebuild -project PhotoFlow/PhotoFlow.xcodeproj -scheme PhotoFlowField \
  -destination 'generic/platform=iOS Simulator' build
```

### Headless

```bash
photoflow-cli run --input <mapp med NEF> --output <mapp> [--no-hdr] [--no-calendar] [--no-ai] [--json]
```

`--json` skriver en maskinläsbar sammanfattning per steg. Exit-kod ≠ 0 vid fel.
`scripts/smoke-run.sh <inputmapp>` gör samma sak mot en kopia och kontrollerar
efteråt att källfilerna är orörda, att symlänkar pekar rätt och att HDR-filerna
är 16-bitars.

## Vad som hamnar var

För varje matchad adress skapas tre mappar i outputkatalogen:

```
Lindvägen 12, Tyresö/              DNG-filer (symlänkar)
Lindvägen 12, Tyresö TITTBILDER/   JPEG-förhandsbilder + HDR-preview
Lindvägen 12, Tyresö ÖVRIGA/       original-NEF (symlänkar) + XMP-sidecars + HDR-TIFF
```

Bilder utan kalendermatchning hamnar under `Osorterade`. Arbetsfilerna ligger kvar
i `dng/`, `previews/`, `hdr/` och `bracket_groups/` — adressmapparna innehåller
symlänkar dit, så inget dupliceras.

**Original-NEF ändras aldrig.** Metadata skrivs in i DNG och JPEG, medan NEF får en
`.xmp`-sidecar bredvid sig.

En körning lämnar också `photoflow_session.json` (manifest med steg, fingeravtryck
och status), plus `bracket_groups.json`, `calendar_matches.json`, `ai_tags.json`,
`photo_quality.json`, `cull_decisions.json`, `photo_notes.json` och `decision_log.jsonl`
för felsökning. Manifestet styr vilka steg som kan hoppas över vid omkörning.

## Fallgropar

**Behörighetsdialogen kommer tillbaka efter varje ombygge.** macOS knyter
behörigheter till appens kodsignatur, och projektet ad hoc-signeras. Förnya ett
utvecklarcertifikat (Xcode → Inställningar → Accounts → Manage Certificates) och
följ instruktionen i `project.yml` för att signera stabilt.

**Callbacks som kraschar direkt.** Projektet bygger med
`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`. Completion-block från C- och
Objective-C-API:er (Speech, UserNotifications, FSEvents, ljudtappar) blir då
MainActor-isolerade och kraschar när systemet anropar dem från en bakgrundskö —
innan blockets kropp ens körs. Märk dem `nonisolated`/`@Sendable` och hoppa till
MainActor inuti.

**Lightroom-pluginet styr HDR via GUI-scriptning.** Lightrooms SDK saknar API för
sammanslagning, så pluginet skickar tangenttryck med väntetider emellan. Tiderna
ställs in i Arkiv → Plug-in Manager → PhotoFlow HDR om sammanslagningen klipper
för tidigt.

## Dokumentation

`FORBATTRINGAR.md` är arbetsloggen: vad som ändrats, varför, mätningar och vad som
behöver testas manuellt. Förklaringarna av varje pipelinesteg bor i
`PhotoFlow/Sources/Models/DashboardStepInfo.swift` och visas som infopopover på
stegkorten i appen — håll dem i synk när logiken ändras.
