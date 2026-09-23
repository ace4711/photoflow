import Foundation

/// Textinnehåll för infopopovern på varje stegkort (`StepCardView`).
///
/// Ligger i en egen fil, separat från `DashboardStep.swift`, eftersom
/// texterna är betydligt längre och ändras i takt med den faktiska
/// pipeline-logiken (`Services/Pipeline/PipelineRunner+*.swift` m.fl.) —
/// snarare än stegens grundläggande identitet (titel/ikon/ordning).
///
/// **Håll i synk med koden**: om ett stegs logik ändras (nya
/// hoppa-över-villkor, nya inställningar, ny skrivplats för filer), uppdatera
/// motsvarande `StepInfo` här i samma commit. `DashboardStepInfoTests`
/// (PhotoFlowTests) kontrollerar bara att texterna FINNS och är rimligt
/// korta/antal — inte att de stämmer med koden, det kräver mänsklig
/// eftergranskning.
struct StepInfo {
    /// En mening som sammanfattar vad steget gör. Visas även som
    /// `.help()`-tooltip vid hover över hela kortet.
    var summary: String
    /// 3–6 korta, skumbara punkter om indata/utdata, verktyg, hoppa-över-
    /// villkor, styrande inställningar och typiska fel — anpassat per steg,
    /// inte varje kategori för varje steg.
    var details: [String]
    /// Tag-index i `SettingsView`s `TabView` dit "Öppna inställningar" ska
    /// hoppa, om steget faktiskt styrs av en konkret inställning där. `nil`
    /// när inget sådant finns — popovern visar då ingen inställningsknapp.
    var settingsTab: Int?
}

extension DashboardStep {
    var info: StepInfo {
        switch self {
        case .watchSources:
            return StepInfo(
                summary: "Bevakar inputmappen och anslutna SD-kort och startar pipelinen automatiskt när nya NEF-filer dyker upp.",
                details: [
                    "Läser: inputmappen (rekursivt) och DCIM-mappen på nyanslutna volymer, filtrerat på .NEF.",
                    "FSEvents bevakar inputmappen i realtid (~2 s debounce); en fallback-timer kör samma kontroll som skyddsnät.",
                    "En fil räknas färdigkopierad först när storleken är oförändrad i två mätningar ~1 s isär.",
                    "Redan hanterade filer memoreras på namn+storlek+ändringsdatum (inte bara namn), så ett återanvänt SD-kort inte ignoreras.",
                    "Väntar/hoppar över: ingen inputmapp konfigurerad, eller alla hittade filer redan skickade till bearbetning sedan tidigare."
                ],
                settingsTab: 2
            )

        case .copyToInput:
            return StepInfo(
                summary: "Räknar de NEF-filer som redan ligger i vald inputmapp — själva \"kopieringen\" är att peka ut mappen.",
                details: [
                    "Gör ingen egen filkopiering: användaren (eller Bevaka källor) har redan lagt filerna i inputmappen.",
                    "Läser: alla .NEF-filer i inputmappen, rekursivt (utom outputmappen och interna pipeline-mappar).",
                    "Markeras klar direkt med antalet hittade NEF-filer — inga egna hoppa-över-regler.",
                    "Styrs av: Mappar → Inputmapp (NEF-filer) / Outputmapp (bearbetade filer)."
                ],
                settingsTab: 0
            )

        case .convertToDNG:
            return StepInfo(
                summary: "Konverterar varje NEF till DNG via Adobe DNG Converter, för bredare RAW-kompatibilitet i Lightroom.",
                details: [
                    "Kör /Applications/Adobe DNG Converter.app i batchar om 50 filer, skriver till processed/dng/.",
                    "Hoppar över per fil: en riktig DNG (inte en symlänk) med samma filnamn finns redan i dng/.",
                    "Om ALLA DNG redan finns hoppas hela steget över direkt, utan att starta konverteraren.",
                    "Ingen egen inställning i appen — konverterarens sökväg är hårdkodad till standardinstallationen.",
                    "Fel: \"Adobe DNG Converter saknas\" om appen inte ligger i /Applications — hela steget stoppar då."
                ],
                settingsTab: nil
            )

        case .generatePreviews:
            return StepInfo(
                summary: "Extraherar kamerans inbäddade JPEG-förhandsvisning ur varje NEF, för snabb visning i appen och Lightroom.",
                details: [
                    "Kör exiftool -JpgFromRaw på alla NEF i en enda batch, skriver till processed/previews/<namn>.jpg.",
                    "Ingen egen skalning/komprimering — det är exakt kamerans inbäddade preview, redan rätt roterad.",
                    "Hoppar över per fil: en previews/<namn>.jpg finns redan för den NEF-filen.",
                    "Fingerprintas (filnamn+storlek) i sessionsmanifestet mest för spårbarhet — själva kontrollen är per fil.",
                    "Inga inställningar styr innehållet: \"Previews\"-sektionen (JPEG-kvalitet/Max dimension) används inte av det här steget."
                ],
                settingsTab: nil
            )

        case .findCalendarInfo:
            return StepInfo(
                summary: "Matchar fotograferingstiderna mot kalenderbokningar (EventKit) för att räkna ut vilken adress bilderna hör till.",
                details: [
                    "Läser fotodatum ur bracket_groups.json och söker EventKit-kalendrar efter bokningar som täcker den tiden.",
                    "Geokodar varje matchad adress (CoreLocation) till GPS-koordinater för senare steg.",
                    "Sparar till calendar_matches.json; hoppar över om filen finns och fingerprintet (bracket_groups.json + valt kalendernamn) matchar.",
                    "Byte av kalender i Inställningar gör alltid om matchningen, även om fotoantalet är oförändrat.",
                    "Ingen match för en bild → den sorteras senare till \"Osorterade\" i stället för en adressmapp.",
                    "Varning: kalenderåtkomst nekad → hela adressmatchningen hoppas över för sessionen."
                ],
                settingsTab: 1
            )

        case .aiTagging:
            return StepInfo(
                summary: "Analyserar varje förhandsbild med Apple Vision (taggar, svensk bildtext) och en Vision-baserad kvalitetskontroll.",
                details: [
                    "Vision-klassificering taggar varje bild med rumstyp/interiör-exteriör m.m., sparas i ai_tags.json.",
                    "Foundation Models (om tillgängligt: Apple Intelligence, macOS 27+) skriver en svensk bildtext + särdrag för ett urval — en bild per bracket-/singelgrupp.",
                    "Vision-kvalitetsanalys (estetik, horisont, skärpa, dubbletter) sparas separat, används av gallringsvyn.",
                    "Hoppar över: fingerprintet (preview-filerna) matchar och ai_tags.json redan täcker alla previews.",
                    "Styrs av: Pipeline → AI-taggning (Tagga bilder med Apple Vision, Generera AI-bildbeskrivningar, förslag av nyttobilder).",
                    "Varning: Foundation Models inte tillgängligt på enheten → bildbeskrivningar hoppas över, Vision-taggar används ändå."
                ],
                settingsTab: 1
            )

        case .createHDR:
            return StepInfo(
                summary: "Grupperar bracketserier utifrån EXIF och slår ihop dem till HDR-bilder via exposure fusion.",
                details: [
                    "Läser EXIF (exponering/bländare/ISO/tid) via ImageIO, grupperar bilder inom Max tidslucka till brackets på minst Minsta antal bilder.",
                    "Sparar grupperna i bracket_groups.json och symlänkade bracket_NNN_HDR_.../single_NNN_...-mappar.",
                    "Slår ihop varje bracket till en 16-bitars TIFF i processed/hdr/hdr_group_N.tiff (+ JPEG-preview); motor väljs i Inställningar.",
                    "Core Image-motorn (standard) kör riktig fusion på RAW/DNG; OpenCV-motorn (äldre) fusionerar 8-bitars JPEG-previews via python3.",
                    "Hoppar över om bracket_groups.json finns och fingerprintet (filer + Max tidslucka/Minsta antal bilder) matchar; färdiga HDR-grupper mergas inte om.",
                    "Fel: python3 med OpenCV saknas (OpenCV-motorn) — installera med pip3 install opencv-python numpy."
                ],
                settingsTab: 1
            )

        case .moveToFolders:
            return StepInfo(
                summary: "Symlänkar alla bilder (och HDR-resultat) in i adressnamngivna mappar utifrån kalendermatchningen.",
                details: [
                    "Skapar per adress tre mappar: <adress> (DNG), <adress> TITTBILDER (previews) och <adress> ÖVRIGA (original-NEF + HDR-TIFF).",
                    "Kopierar aldrig filerna — skapar symlänkar tillbaka till dng/ och previews/, så inget dubbleras på disk.",
                    "Ingen kalendermatchning → bilden hamnar i \"Osorterade\" i stället för en adressmapp.",
                    "Hoppar över om files_sorted.json finns och fingerprintet (bildlista + HDR-läge + adresser/GPS-rättningar) matchar.",
                    "En manuell GPS-/adressrättning i AddressBanner triggar alltid omsortering, även vid oförändrat bildantal."
                ],
                settingsTab: 1
            )

        case .writeIPTCTags:
            return StepInfo(
                summary: "Skriver GPS, adress och AI-taggar som IPTC/XMP-metadata på de sorterade filerna via exiftool.",
                details: [
                    "Skriver till DNG/JPEG/HDR-TIFF direkt (overwrite in place); NEF-original rörs aldrig — får i stället en XMP-sidecar.",
                    "Fält: GPS-koordinater, adress (Headline/ObjectName/Title), bokningstitel och AI-taggar/beskrivning som nyckelord/bildtext.",
                    "Körs i batchar om 100 filer via ett exiftool-argfile för hastighet.",
                    "Hoppar över om metadata_written.json finns och fingerprintet (bilder + AI-taggar + adresser/rättningar) matchar.",
                    "En omkörd AI-taggning eller adressrättning triggar alltid en ny skrivning, även vid samma filantal.",
                    "Fel: exiftool saknas → installera med brew install exiftool; steget skriver då ingen metadata alls."
                ],
                settingsTab: 1
            )

        case .manualReview:
            return StepInfo(
                summary: "Din genomgång av bracket-val och gallring (acceptera/avvisa) innan filerna slutbehandlas.",
                details: [
                    "Öppnar bracket-granskningen (om HDR är på) eller gallringsvyn direkt (om HDR är av).",
                    "Gallringsbeslut sparas i cull_decisions.json; vad som händer med avvisade filer styrs av Gallring → Vid \"Avsluta gallring\".",
                    "\"Markera med betyg\" (standard) rör inga filer — skriver XMP:Rating (3 / -1) så Lightroom visar beslutet direkt.",
                    "\"Flytta\" resp. \"Radera\" flyttar till en Gallrade-undermapp respektive tar bort filerna permanent (med bekräftelsedialog).",
                    "\"Väntar\"-märket visas tills alla bilder har fått ett beslut (accepterad eller avvisad)."
                ],
                settingsTab: 1
            )

        case .importToLightroom:
            return StepInfo(
                summary: "Skickar valda HDR-bracketgrupper till Lightroom Classic-pluginet för sammanslagning där i stället.",
                details: [
                    "Klick på kortet skriver en trigger-fil med accepterade bilder per bracket-grupp till en delad bryggmapp.",
                    "Öppnar/aktiverar Lightroom Classic — pluginet (PhotoFlowLR.lrplugin) pollar bryggmappen var 5:e sekund och startar mergen där.",
                    "Väntar (pollar) upp till 10 minuter på ett svar från pluginet innan den ger upp med en timeout-varning.",
                    "Ett alternativ till appens egen HDR-motor (Skapa HDR-steget) — körs manuellt, inte i den automatiska pipelinen."
                ],
                settingsTab: nil
            )
        }
    }
}
