import Foundation
import Testing
@testable import PhotoFlow

struct ReelRemoteStateTests {

    @Test("reel-remote.json sparas och läses tillbaka och innehåller ingen token")
    func roundTrip() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ReelRemoteState.load(from: dir) == nil)
        let state = ReelRemoteState(server: "https://objekt.example.se", objectId: "obj-1", reelId: "reel-1",
                                    lastSyncedRevision: 4, lastSyncedLocalRevision: 4,
                                    sourceRelativePath: "../Hus FÄRDIGA", lastKnownStatus: "proposed",
                                    links: [.init(linkId: "l1", label: "Maja", createdAt: nil, expiresAt: "2026-11-02T10:00:00.000Z")])
        try state.save(to: dir)
        #expect(ReelRemoteState.load(from: dir) == state)
        let text = try String(contentsOf: ReelRemoteState.url(in: dir), encoding: .utf8)
        #expect(!text.lowercased().contains("token") && !text.contains("#"))
        #expect(state.sourceDirectory(relativeTo: dir.appendingPathComponent("Hus FILM"))?.lastPathComponent == "Hus FÄRDIGA")
    }

    @Test("Appindexet: objectId → FILM-mapp, bara om mappen finns")
    func appIndex() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index/objektfilm-index.json")
        let film = dir.appendingPathComponent("Hus FILM")
        try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
        #expect(ReelRemoteIndex.directory(for: "obj-1", at: index) == nil)
        try ReelRemoteIndex.register(objectId: "obj-1", directory: film, at: index)
        try ReelRemoteIndex.register(objectId: "obj-2", directory: dir.appendingPathComponent("finns-inte"), at: index)
        #expect(ReelRemoteIndex.directory(for: "obj-1", at: index)?.path == film.standardizedFileURL.path)
        #expect(ReelRemoteIndex.directory(for: "obj-2", at: index) == nil)
        #expect(ReelRemoteIndex.entries(at: index).count == 2)
        // Appens riktiga index ligger i Application Support, inte i testkatalogen.
        #expect(ReelRemoteIndex.defaultURL.path.contains("Application Support/PhotoFlow"))
    }
}
