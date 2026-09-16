import Foundation
import os

/// Fas 6: registret över ALLA kända sessioner (inte bara den senaste körningen
/// i den just nu konfigurerade outputmappen — se `AddressSessionLoader`s
/// gamla begränsning, dokumenterad i Fas 3f), lagrat i
/// `~/Library/Application Support/PhotoFlow/sessions.json`.
///
/// En rad per `SessionManifest.sessionID`, uppdaterad (upsert) varje gång
/// `PipelineState.syncManifest()` sparar ett manifest — se dess anrop till
/// `SessionHistoryStore.record(_:)`. `enum` med statiska funktioner mot en
/// explicit `registryURL`-parameter (default: den riktiga platsen), samma
/// testbarhetsmönster som `AddressSessionLoader`/`SessionManifestStore`.
enum SessionHistoryStore {
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID { sessionID }
        var sessionID: UUID
        /// Alla adresser sessionen matchade mot kalendern (kan vara flera om
        /// fotograferingen spänner över flera bokningar), för sök/visning i
        /// historikvyn.
        var addresses: [String]
        var createdAt: Date
        var updatedAt: Date
        var inputDirectory: String
        var outputDirectory: String
        var photoCount: Int
        var acceptedCount: Int
        var rejectedCount: Int
        var unreviewedCount: Int
        /// Fritext för visning, t.ex. "Klar" eller "Pågående" — se `record(_:)`.
        var status: String
    }

    /// The real, shared registry location — EXCEPT under `xcodebuild test`/
    /// Xcode's Test Navigator, where it redirects to a throwaway temp file
    /// instead. Without this, every pre-existing test that exercises
    /// `PipelineState.completeStep`/`updateStep`/`correctAddress`/
    /// `saveCullDecisions` against a temp output directory (there are many —
    /// none of them written with Fas 6 in mind, since this store didn't exist
    /// yet) would silently write fake sessions pointing at `/var/folders/...`
    /// temp paths into the REAL user's
    /// `~/Library/Application Support/PhotoFlow/sessions.json`, corrupting
    /// the actual "Historik" list. `XCTestConfigurationFilePath` is set by
    /// Xcode/`xcodebuild` on the hosted test process regardless of whether
    /// the tests themselves use XCTest or Swift Testing (this project's test
    /// target is `TEST_HOST`ed inside PhotoFlow.app either way — see
    /// `PipelineSmokeTest.swift`'s doc comment on the same TEST_HOST setup).
    static let defaultRegistryURL: URL = {
        let dir: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowTestSessionHistory-\(UUID().uuidString)")
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PhotoFlow")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }()

    // nonisolated(unsafe): JSONEncoder/JSONDecoder's `.custom` strategy
    // closures are treated as `Sendable` by the compiler, which can't see
    // that they're always invoked synchronously (same thread) from `load`/
    // `save` below — this formatter is created once and only ever read
    // (never mutated) after that, so sharing it across the closure boundary
    // is safe in practice. Same reasoning/pattern as `ToolLocator`'s cache.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let logger = Logger(subsystem: "com.photoflow.app", category: "sessionHistory")

    static func load(from registryURL: URL = defaultRegistryURL) -> [Entry] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ogiltigt ISO8601-datum: \(string)")
            }
            return date
        }
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// Atomisk skrivning, samma mönster som `SessionManifestStore.save`.
    private static func save(_ entries: [Entry], to registryURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }

        let fm = FileManager.default
        let dir = registryURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tempURL = dir.appendingPathComponent(".\(registryURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            if fm.fileExists(atPath: registryURL.path) {
                _ = try fm.replaceItemAt(registryURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: registryURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    /// Upsert:ar en post härledd från `manifest`, nyckel `sessionID`. Anropas
    /// från `PipelineState.syncManifest()` varje gång ett manifest sparas —
    /// registret hålls alltså uppdaterat både när en session körs och när en
    /// gammal session öppnas igen (`loadExistingSession`, som också går via
    /// `syncManifest`).
    static func record(_ manifest: SessionManifest, registryURL: URL = defaultRegistryURL) {
        var entries = load(from: registryURL)
        let isComplete = !manifest.steps.isEmpty && manifest.steps.values.allSatisfy { $0.phase == "complete" || $0.phase == "disabled" }
        let entry = Entry(
            sessionID: manifest.sessionID,
            addresses: manifest.addresses.map(\.address),
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            inputDirectory: manifest.inputDirectory,
            outputDirectory: manifest.outputDirectory,
            photoCount: manifest.photoCount,
            acceptedCount: manifest.cullSummary.accepted,
            rejectedCount: manifest.cullSummary.rejected,
            unreviewedCount: manifest.cullSummary.unreviewed,
            status: isComplete ? "Klar" : "Pågående"
        )
        if let idx = entries.firstIndex(where: { $0.sessionID == manifest.sessionID }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        save(entries, to: registryURL)
    }

    /// Fas 8: tar bort EN post ur registret på användarens uttryckliga begäran
    /// (se `SessionHistoryView`s "Ta bort ur historik"-knapp) — rör ALDRIG
    /// några filer på disk, bara raden i `sessions.json`. Skiljer sig därmed
    /// medvetet från `pruneMissingOutputDirectories` nedan, som tar bort
    /// automatiskt utan att fråga men bara för mappar som redan är borta.
    static func remove(sessionID: UUID, registryURL: URL = defaultRegistryURL) {
        var entries = load(from: registryURL)
        entries.removeAll { $0.sessionID == sessionID }
        save(entries, to: registryURL)
    }

    /// Tar bort poster vars outputmapp inte längre finns på disk (t.ex.
    /// flyttad/raderad manuellt av användaren). Loggas via `os.Logger`, men
    /// frågar aldrig — det här är bara bokföring om var riktiga filer bodde,
    /// inte de riktiga filerna själva (se uppdragets punkt 3: "fråga inte —
    /// logga bara").
    @discardableResult
    static func pruneMissingOutputDirectories(registryURL: URL = defaultRegistryURL) -> [Entry] {
        let entries = load(from: registryURL)
        let fm = FileManager.default
        var kept: [Entry] = []
        var removedCount = 0
        for entry in entries {
            if fm.fileExists(atPath: entry.outputDirectory) {
                kept.append(entry)
            } else {
                removedCount += 1
                logger.info("Tog bort sessionshistorikpost för saknad outputmapp: \(entry.outputDirectory, privacy: .public)")
            }
        }
        if removedCount > 0 {
            save(kept, to: registryURL)
        }
        return kept
    }
}
