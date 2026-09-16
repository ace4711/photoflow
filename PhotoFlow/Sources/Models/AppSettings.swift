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
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("speechEnabled") var speechEnabled: Bool = true
    /// Fas 3e: systemnotiser (Notification Center) — komplement till ljud/tal,
    /// syns även när huvudfönstret är stängt (menyradsläge). Default på;
    /// själva OS-behörigheten begärs separat, första gången pipeline-läget
    /// används (se `NotificationService.requestAuthorizationIfNeeded`).
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("previewQuality") var previewQuality: Int = 85
    @AppStorage("previewMaxDimension") var previewMaxDimension: Int = 2400
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
    @AppStorage("calendarName") var calendarName: String = "Exempelkalender"
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
