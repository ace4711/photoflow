import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("inputDirectoryPath") var inputDirectoryPath: String = ""
    @AppStorage("outputDirectoryPath") var outputDirectoryPath: String = ""
    @AppStorage("watchEnabled") var watchEnabled: Bool = false
    @AppStorage("watchIntervalSeconds") var watchIntervalSeconds: Int = 10
    @AppStorage("autoStartPipeline") var autoStartPipeline: Bool = true
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("speechEnabled") var speechEnabled: Bool = true
    @AppStorage("previewQuality") var previewQuality: Int = 85
    @AppStorage("previewMaxDimension") var previewMaxDimension: Int = 2400
    @AppStorage("maxTimeGap") var maxTimeGap: Int = 15
    @AppStorage("minBracketSize") var minBracketSize: Int = 3
    @AppStorage("hdrMergeEnabled") var hdrMergeEnabled: Bool = true
    @AppStorage("detailedProgress") var detailedProgress: Bool = true
    @AppStorage("calendarMatchEnabled") var calendarMatchEnabled: Bool = true
    @AppStorage("calendarName") var calendarName: String = "Exempelkalender"
    @AppStorage("aiTaggingEnabled") var aiTaggingEnabled: Bool = true

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
