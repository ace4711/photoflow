import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("inputDirectoryPath") var inputDirectoryPath: String = ""
    @AppStorage("outputDirectoryPath") var outputDirectoryPath: String = ""
    @AppStorage("watchEnabled") var watchEnabled: Bool = false
    /// Fas 3e: numera bara FALLBACK-pollning. FSEvents (`WatchService`) är den
    /// primära bevakningsmekanismen och reagerar inom sekunder via ett
    /// debounce-fönster (~2 s) — den här timern körs parallellt som
    /// skyddsnät ifall FSEvents skulle missa en händelse. 60 s (upp från
    /// tidigare 10 s, då pollningen var den enda mekanismen) räcker gott om
    /// som skyddsnät.
    @AppStorage("watchIntervalSeconds") var watchIntervalSeconds: Int = 60
    @AppStorage("autoStartPipeline") var autoStartPipeline: Bool = true
    /// Fas 3e: en `MenuBarExtra` (ikon: kamera/öga beroende på om bevakning är
    /// aktiv) så appen kan bevakas utan öppet huvudfönster. Default på.
    @AppStorage("showMenuBarExtra") var showMenuBarExtra: Bool = true
    /// Fas 3e: registrerar appen som inloggningsobjekt via `SMAppService`.
    /// Denna flagga speglar bara ANVÄNDARENS önskan — `SettingsView` läser
    /// `SMAppService.mainApp.status` för det faktiska systemläget (som kan
    /// skilja sig, t.ex. om användaren stängde av det i Systeminställningar).
    @AppStorage("launchAtLoginRequested") var launchAtLoginRequested: Bool = false
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("speechEnabled") var speechEnabled: Bool = true
    /// Fas 3e: systemnotiser (Notification Center) — komplement till ljud/tal,
    /// syns även när huvudfönstret är stängt (menyradsläge). Default på;
    /// själva OS-behörigheten begärs separat, första gången pipeline-läget
    /// används (se `NotificationService.requestAuthorizationIfNeeded`).
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    // previewQuality/previewMaxDimension är borttagna: preview-steget kopierar
    // kamerans inbäddade JPEG rakt av (exiftool -JpgFromRaw), utan omkodning,
    // så inställningarna lästes aldrig av någon kod.
    @AppStorage("maxTimeGap") var maxTimeGap: Int = 15
    @AppStorage("minBracketSize") var minBracketSize: Int = 3
    @AppStorage("hdrMergeEnabled") var hdrMergeEnabled: Bool = true
    /// "coreImage" (default, Fas 3a): riktig exposure fusion på RAW-data i ren
    /// Swift (`Services/HDR/`). "opencv": den äldre vägen — Mertens fusion via
    /// python3/OpenCV på 8-bitars inbäddade JPEG-förhandsbilder
    /// (`PipelineRunner+HDR.swift`), kvar som fallback om Core Image RAW-vägen
    /// ger sämre resultat på en viss kamera/RAW-typ.
    @AppStorage("hdrEngine") var hdrEngine: String = "coreImage"
    /// Lång sida i pixlar för RAW-rendering inför HDR-fusion. `0` = full
    /// sensorupplösning (kan bli mycket minneskrävande för stora brackets).
    @AppStorage("hdrMaxDimension") var hdrMaxDimension: Int = 6000
    /// Justerar handhållna brackets (Vision-baserad translationell
    /// bildregistrering mot mittexponeringen) innan fusion.
    @AppStorage("hdrAlignEnabled") var hdrAlignEnabled: Bool = true
    @AppStorage("detailedProgress") var detailedProgress: Bool = true
    @AppStorage("calendarMatchEnabled") var calendarMatchEnabled: Bool = true
    /// DEPRECERAD läsväg (flera kalendrar): ersatt av `calendarNames` nedan,
    /// som stödjer att välja FLERA kalendrar samtidigt. Kvar bara som
    /// bakåtkompatibel fallback för `calendarNames`s getter — en session som
    /// aldrig sparat något i den nya nyckeln men har ett gammalt värde här
    /// ska fortsätta fungera som ett enda valt namn, UTAN att något skrivs om
    /// (se `calendarNames` och den borttagna migreringskommentaren nedan för
    /// varför det medvetet inte skriver en tyst migrering).
    @AppStorage("calendarName") var calendarName: String = ""

    /// Valda kalendernamn (tom lista = sök i ALLA kalendrar, se
    /// `CalendarService.resolveCalendar`). Väljs med en flervalslista i
    /// SettingsView som listar riktiga kalendrar via EventKit, med ett
    /// fritextläge kvar som fallback när åtkomst saknas.
    ///
    /// Lagras som en JSON-kodad sträng (inte `@AppStorage`s inbyggda
    /// array-stöd, som inte finns för `[String]`) direkt i `UserDefaults`,
    /// inte via `@AppStorage`-macrot — dels för att kunna skilja på "nyckeln
    /// saknas helt" och "nyckeln finns men listan är tom" (bakåtkompatibilitet
    /// nedan bygger på just den skillnaden), dels för att kalendernamn kan
    /// innehålla komma och de flesta andra separatortecken, så en naiv
    /// sträng-join/split vore fel.
    var calendarNames: [String] {
        get {
            if let json = UserDefaults.standard.string(forKey: Self.calendarNamesKey),
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded
            }
            // Nyckeln saknas (aldrig sparad än) — bakåtkompatibilitet utan
            // migreringsskrivning: tolka den gamla `calendarName` (om den har
            // ett värde) som ett enda valt namn. En tidigare migrering här
            // togs bort för att den skrev in ett hårdkodat personligt värde —
            // gör inte om det misstaget genom att skriva något till
            // UserDefaults i den här gettern.
            let legacy = calendarName.trimmingCharacters(in: .whitespaces)
            return legacy.isEmpty ? [] : [legacy]
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: Self.calendarNamesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.calendarNamesKey)
            }
        }
    }
    private static let calendarNamesKey = "calendarNames"
    @AppStorage("aiTaggingEnabled") var aiTaggingEnabled: Bool = true
    /// Fas 3d: genererar svenska bildbeskrivningar (rum, kategori, särdrag,
    /// bildtext) med Apples on-device Foundation Models, för ett urval
    /// bilder (en per bracket-/singelgrupp) efter Vision-taggningen. Default
    /// `true`, men körs bara i praktiken när
    /// `PhotoDescriptionService.isAvailable` är sant (kräver Apple
    /// Intelligence + macOS 27, se den typens dokumentation) — annars
    /// hoppas steget alltid över och Vision-taggarna används som tidigare,
    /// så det finns inget läge där detta "tvingas på" på en enhet som inte
    /// stödjer det.
    @AppStorage("aiDescriptionsEnabled") var aiDescriptionsEnabled: Bool = true
    /// Styr om "Föreslå gallring" (`s` i gallringsvyn) även föreslår Vision's
    /// `isUtility`-flaggade bilder för avvisning, utöver dubbletter (som alltid
    /// föreslås). Av som standard (Fas 3c): kalibreringen i Fas 3b visade att
    /// Vision flaggade 34 % av en riktig fastighetssession som "nyttobild" —
    /// för högt för att lita på automatiskt, se FORBATTRINGAR.md Fas 3c.
    @AppStorage("cullSuggestUtility") var cullSuggestUtility: Bool = false

    /// Fas 4: vad som händer med avvisade bilder när gallringen avslutas
    /// (`PreviewCullView.finishCulling`/`PipelineRunner.finishCullingAction`).
    /// - "markera" (default, NY): rör inga filer. Skriver `XMP:Rating` (3 för
    ///   accepterade, -1 = Lightroom Classics "Rejected"-flagga för avvisade)
    ///   + `XMP-photoshop:Urgency` på avvisade, så gallringen syns direkt i
    ///   Lightroom (filtrera på stjärnor/flagga) utan att något raderas —
    ///   säkrast, och gör hela steget ångringsbart efteråt via Lightroom.
    /// - "radera": det gamla beteendet, tar bort avvisade filer permanent.
    /// - "flytta": flyttar avvisade filer till en "Gallrade"-undermapp under
    ///   respektive adressmapp, i stället för att röra dem alls.
    @AppStorage("cullAction") var cullAction: String = "markera"

    /// Fas 7: hur många sekunder från en bilds tidsstämpel som en importerad
    /// fältanteckning (från "PhotoFlow Fält", iOS) får ligga inom för att
    /// räknas som en träff — se `FieldNoteMatcher`. Standard ±90s enligt
    /// planen. Anteckningar utanför fönstret blir "sessionsanteckningar".
    @AppStorage("fieldNotesMatchWindowSeconds") var fieldNotesMatchWindowSeconds: Double = 90
    /// Kompenserar klockdrift mellan telefonens och kamerans klocka (sekunder
    /// att lägga till varje antecknings tidsstämpel innan matchning). 0 =
    /// ingen korrigering (standard — de flesta telefoner/kameror har
    /// synkroniserad tid via NTP/GPS).
    @AppStorage("fieldNotesClockOffsetSeconds") var fieldNotesClockOffsetSeconds: Double = 0

    init() {}

    // Migreringen av `calendarName` är borttagen. Den fanns för att bevara ett
    // hårdkodat personligt kalendernamn som tidigare låg i koden, och som nu är
    // borta ur både koden och historiken (repot är publikt). Att behålla
    // migreringen efter den städningen hade bara skrivit in en platshållare som
    // inte matchar någon riktig kalender.
    //
    // Konsekvens: den som aldrig valt kalender söker i ALLA kalendrar, vilket är
    // ett rimligt standardläge. Välj kalender under Inställningar → Pipeline →
    // Kalenderintegration. Nyckeln `calendarNameMigratedV1` lämnas kvar i
    // UserDefaults för dem som redan kört migreringen; den läses inte längre.

    var inputDirectory: URL? {
        get {
            guard !inputDirectoryPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: inputDirectoryPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set {
            inputDirectoryPath = newValue?.path ?? ""
            objectWillChange.send()
        }
    }

    var outputDirectory: URL? {
        get {
            guard !outputDirectoryPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: outputDirectoryPath)
            return url
        }
        set {
            outputDirectoryPath = newValue?.path ?? ""
            objectWillChange.send()
        }
    }

    // Known SD card mount points.
    //
    // Previously excluded only the literal volume name "Macintosh HD" — breaks for
    // any differently-named boot volume (common: a custom name, a Time Machine
    // clone, or any other non-card external drive mounted under /Volumes). Now
    // uses actual volume properties instead of a name guess.
    var sdCardSearchPaths: [URL] {
        let volumesDir = URL(fileURLWithPath: "/Volumes")
        let resourceKeys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesDir, includingPropertiesForKeys: resourceKeys,
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let hasDCIM = FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
            return Self.isCandidateSDCardVolume(
                removable: values?.volumeIsRemovable,
                ejectable: values?.volumeIsEjectable,
                isRootFileSystem: values?.volumeIsRootFileSystem,
                hasDCIM: hasDCIM
            )
        }
    }

    /// Pure decision logic for `sdCardSearchPaths`, factored out so it's testable
    /// without touching the real filesystem/`/Volumes`.
    static func isCandidateSDCardVolume(removable: Bool?, ejectable: Bool?, isRootFileSystem: Bool?, hasDCIM: Bool) -> Bool {
        // Never treat the boot volume as an SD card, no matter what it's named.
        guard isRootFileSystem != true else { return false }
        guard (removable ?? false) || (ejectable ?? false) else { return false }
        return hasDCIM
    }
}
