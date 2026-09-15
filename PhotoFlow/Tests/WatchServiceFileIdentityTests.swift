import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the fix to WatchService identifying files purely by filename: a
/// `Set<String>` of `lastPathComponent`s meant a Nikon restarting its counter
/// (e.g. after formatting a card) at DSC_0001 made the watcher silently ignore
/// genuinely new photos that happened to share a name with an old, already
/// processed one. Files are now identified by `fileKey(for:)` (name + size +
/// mtime) and tracked persistently (per source directory) via
/// `ProcessedFilesStore`, so a restart doesn't forget and re-trigger processing
/// for an entire already-handled card either.
struct WatchServiceFileIdentityTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WatchServiceFileIdentityTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - fileKey(for:)

    @Test("Samma filnamn men olika storlek/mtime ger olika nycklar (kort återanvänt DSC_0001)")
    func fileKey_sameNameDifferentContent_producesDifferentKeys() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("DSC_0001.NEF").path
        try Data(repeating: 0, count: 100).write(to: URL(fileURLWithPath: path))
        // Fresh URL instance for each read — URL/NSURL caches resourceValues
        // results on the instance itself, so reusing the same URL value across
        // the file being rewritten would return stale cached values here (this
        // doesn't affect real usage, where every enumeration produces new URL
        // instances from FileManager).
        let keyA = WatchService.fileKey(for: URL(fileURLWithPath: path))

        // Simulate the card being reformatted and DSC_0001 reused for a
        // different photo: same name, different size and mtime.
        try FileManager.default.removeItem(atPath: path)
        try Data(repeating: 1, count: 999).write(to: URL(fileURLWithPath: path))
        // Force a distinct modification date in case the two writes landed in
        // the same filesystem-timestamp granularity window.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: path)
        let keyB = WatchService.fileKey(for: URL(fileURLWithPath: path))

        #expect(keyA != keyB)
        #expect(keyA.hasPrefix("DSC_0001.NEF|"))
        #expect(keyB.hasPrefix("DSC_0001.NEF|"))
    }

    @Test("Samma fil (oförändrad) ger samma nyckel varje gång")
    func fileKey_unchangedFile_isStable() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("DSC_0002.NEF")
        try Data(repeating: 7, count: 42).write(to: file)

        #expect(WatchService.fileKey(for: file) == WatchService.fileKey(for: file))
    }

    // MARK: - ProcessedFilesStore persistence

    @Test("markProcessed/isProcessed fungerar inom samma instans")
    func store_marksAndChecksWithinSameInstance() {
        let storeFile = tempDir().appendingPathComponent("processed_files.json")
        let store = ProcessedFilesStore(fileURL: storeFile)

        #expect(store.isProcessed(source: "/Volumes/CARD/DCIM/100NIKON", key: "DSC_0001.NEF|100|123") == false)
        store.markProcessed(source: "/Volumes/CARD/DCIM/100NIKON", key: "DSC_0001.NEF|100|123")
        #expect(store.isProcessed(source: "/Volumes/CARD/DCIM/100NIKON", key: "DSC_0001.NEF|100|123") == true)
    }

    @Test("Rundtripp: save() + ny instans som läser samma fil ser tidigare markerade nycklar")
    func store_persistsAcrossInstances() {
        let storeFile = tempDir().appendingPathComponent("processed_files.json")
        let store1 = ProcessedFilesStore(fileURL: storeFile)
        store1.markProcessed(source: "/input", key: "DSC_0001.NEF|100|123")
        store1.markProcessed(source: "/input", key: "DSC_0002.NEF|200|456")
        store1.save()

        // Simulates an app restart: a brand new instance reading the same file.
        let store2 = ProcessedFilesStore(fileURL: storeFile)
        #expect(store2.isProcessed(source: "/input", key: "DSC_0001.NEF|100|123") == true)
        #expect(store2.isProcessed(source: "/input", key: "DSC_0002.NEF|200|456") == true)
        #expect(store2.isProcessed(source: "/input", key: "DSC_0003.NEF|300|789") == false)
    }

    @Test("Nycklar är per källa — samma nyckel från en annan källa räknas som ny")
    func store_scopesKeysPerSource() {
        let storeFile = tempDir().appendingPathComponent("processed_files.json")
        let store = ProcessedFilesStore(fileURL: storeFile)
        store.markProcessed(source: "/Volumes/CARD1/DCIM/100NIKON", key: "DSC_0001.NEF|100|123")

        // Same key, but a different card/source — must not be treated as already handled.
        #expect(store.isProcessed(source: "/Volumes/CARD2/DCIM/100NIKON", key: "DSC_0001.NEF|100|123") == false)
    }

    @Test("Begränsas till senaste 50 000 posterna, äldsta faller bort")
    func store_capsAtMaxEntries() {
        let storeFile = tempDir().appendingPathComponent("processed_files.json")
        let store = ProcessedFilesStore(fileURL: storeFile)

        for i in 0..<(ProcessedFilesStore.maxEntries + 10) {
            store.markProcessed(source: "/input", key: "file\(i).NEF|1|1")
        }

        // The oldest ones should have been trimmed...
        #expect(store.isProcessed(source: "/input", key: "file0.NEF|1|1") == false)
        #expect(store.isProcessed(source: "/input", key: "file9.NEF|1|1") == false)
        // ...but the most recent maxEntries should have survived.
        #expect(store.isProcessed(source: "/input", key: "file\(ProcessedFilesStore.maxEntries + 9).NEF|1|1") == true)
    }
}
