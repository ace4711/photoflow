import AppKit
import SwiftUI
import Testing
@testable import PhotoFlow

/// Renderar granska-läget med urvalet till redigering till PNG-filer i
/// `~/PhotoFlowBenchmark/results/urval/` (skärmbilder åt fotografen). Körs bara när
/// benchmarkdatan finns lokalt; använder riktiga förhandsbilder från Ballonggatan 7.
@MainActor
struct EditSelectionScreenshotTests {
    nonisolated static let bench = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PhotoFlowBenchmark")
    nonisolated static let previews = bench.appendingPathComponent("urval/previews/ballonggatan-7")
    nonisolated static let csv = bench.appendingPathComponent("shoots/ballonggatan-7/groups.csv")
    nonisolated static let out = bench.appendingPathComponent("results/urval")
    nonisolated static var available: Bool { FileManager.default.fileExists(atPath: previews.path) && FileManager.default.fileExists(atPath: csv.path) }

    /// Grupper ur groups.csv från och med `fromGroup` (så att första gruppen i listan är en intressant bracket).
    private func loadSession(fromGroup: Int) throws -> (groups: [BracketGroup], photos: [PhotoItem]) {
        let lines = try String(contentsOf: Self.csv, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }.dropFirst()
        var order: [Int] = []
        var rows: [Int: [[String]]] = [:]
        for l in lines {
            let c = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let gi = Int(c[1]), gi >= fromGroup else { continue }
            if rows[gi] == nil { order.append(gi) }
            rows[gi, default: []].append(c)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var groups: [BracketGroup] = []
        var photos: [PhotoItem] = []
        for gi in order {
            var ids: [String] = []
            for c in rows[gi]! {
                let secs: Double = {
                    let p = c[4].split(separator: "/")
                    return p.count == 2 ? Double(p[0])! / Double(p[1])! : Double(c[4])!
                }()
                let base = c[2].replacingOccurrences(of: ".NEF", with: "")
                let date = fmt.date(from: String(c[3].prefix(19))) ?? Date()
                let id = "\(gi)_\(c[2])"
                ids.append(id)
                photos.append(PhotoItem(id: id, filename: c[2], nefURL: URL(fileURLWithPath: "/saknas/\(c[2])"), dngURL: nil,
                                        previewURL: Self.previews.appendingPathComponent("\(base).jpg"),
                                        exposureTime: c[4], exposureSeconds: secs, fNumber: 9, iso: 320, dateTime: date))
            }
            let r = rows[gi]!
            groups.append(BracketGroup(id: gi, isBracket: r.count > 1, folderName: "g\(gi)", photoIDs: ids, fNumber: 9, iso: 320,
                                       timeStart: String(r.first![3].dropFirst(11).prefix(8)), timeEnd: String(r.last![3].dropFirst(11).prefix(8)),
                                       exposureRangeStops: 0))
        }
        return (groups, photos)
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, settle: TimeInterval, to name: String) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent(name))
        window.orderOut(nil)
    }

    @Test(.enabled(if: available)) func renderReviewWithEditSelection() async throws {
        let session = try loadSession(fromGroup: 9)
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("urval-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let state = PipelineState()
        state.outputDirectory = outDir
        state.allPhotos = session.photos
        state.bracketGroups = session.groups
        // En avvisad exponering, så att den spärrade kryssrutan syns.
        if let p = session.photos.first(where: { $0.id.hasPrefix("9_") && $0.exposureTime == "1.6" }) {
            state.setDecision(photoID: p.id, accepted: false, rejected: true)
        }
        let view = BracketReviewView(runner: RunnerWrapper()).environmentObject(state)
        try await snapshot(view, size: CGSize(width: 1700, height: 1000), settle: 8, to: "granska-urval.png")
        let saved = EditSelection.load(from: outDir)
        #expect(saved.suggestionApplied)
        #expect(saved.counts().groups > 0)
    }

    @Test(.enabled(if: available)) func renderSendSheetSummary() async throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("urval-sheet-\(UUID().uuidString)")
        let dng = outDir.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dng, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        var requests: [SendFolderSync.Request] = []
        for (i, address) in ["Ballonggatan 7", "Ballonggatan 7", "Ballonggatan 7", "Osorterade"].enumerated() {
            let name = "DSC_96\(90 + i)"
            let file = dng.appendingPathComponent("\(name).dng")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let h = try FileHandle(forWritingTo: file)
            try h.truncate(atOffset: 25_000_000)   // gles fil: storleken syns i sammanfattningen
            try h.close()
            requests.append(.init(address: address, nefURL: URL(fileURLWithPath: "/saknas/\(name).NEF"), dngURL: file))
        }
        // En främmande fil med samma namn i skicka-mappen ⇒ krock som inte skrivs över.
        let folder = SendFolderSync.folder(in: outDir, address: "Ballonggatan 7")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("annan".utf8).write(to: folder.appendingPathComponent("DSC_9692.dng"))
        let view = EditSendSheet(outputDir: outDir, requests: requests) {}
            .background(Color(nsColor: .windowBackgroundColor))
        try await snapshot(view, size: CGSize(width: 520, height: 420), settle: 3, to: "skicka-mappar.png")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC_9690.dng").path))
        #expect((try? Data(contentsOf: folder.appendingPathComponent("DSC_9692.dng"))) == Data("annan".utf8))
    }
}
