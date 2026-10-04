import Testing
import Foundation
@testable import PhotoFlow

@Suite("SendFolderSync")
struct SendFolderSyncTests {
    let root: URL
    var outputDir: URL { root.appendingPathComponent("out", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sendsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out/dng"), withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Skapar en riktig DNG i dng/ och en symlänk till den i adressmappen.
    func makeDNG(_ name: String, address: String, content: String = "dng-data") throws -> (real: URL, link: URL) {
        let real = outputDir.appendingPathComponent("dng/\(name).dng")
        try write(real, content)
        let link = outputDir.appendingPathComponent("\(address)/\(name).dng")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (real, link)
    }

    func request(_ name: String, address: String, dng: URL?) -> SendFolderSync.Request {
        .init(address: address, nefURL: root.appendingPathComponent("in/\(name).NEF"), dngURL: dng)
    }

    let fakeConverter: SendFolderSync.Converter = { nef, dngDir in
        let url = dngDir.appendingPathComponent(nef.deletingPathExtension().lastPathComponent + ".dng")
        try Data("konverterad".utf8).write(to: url)
        return url
    }

    func run(_ requests: [SendFolderSync.Request], manifest: SendFolderSync.Manifest? = nil)
        async -> (SendFolderSync.Summary, SendFolderSync.Manifest, [SendFolderSync.Action]) {
        let m = manifest ?? SendFolderSync.Manifest.load(from: outputDir)
        let actions = SendFolderSync.plan(requests: requests, outputDir: outputDir, manifest: m)
        let (s, nm) = await SendFolderSync.execute(actions, requests: requests, outputDir: outputDir, manifest: m, converter: fakeConverter)
        return (s, nm, actions)
    }

    func dest(_ name: String, address: String) -> URL {
        SendFolderSync.folder(in: outputDir, address: address).appendingPathComponent("\(name).dng")
    }

    @Test func namnOchMapp() {
        #expect(SendFolderSync.folderName(address: "Gatan 1") == "Gatan 1 skicka")
        #expect(SendFolderSync.folder(in: URL(fileURLWithPath: "/x"), address: "A").path == "/x/A/A skicka")
        #expect(request("DSC_1", address: "A", dng: nil).fileName == "DSC_1.dng")
    }

    @Test func kopierarViaSymlankSomRiktigFil() async throws {
        let (real, link) = try makeDNG("DSC_1", address: "Gatan 1")
        let (summary, manifest, actions) = await run([request("DSC_1", address: "Gatan 1", dng: link)])
        guard case .copy = actions.first else { Issue.record("väntade copy"); return }
        let d = dest("DSC_1", address: "Gatan 1")
        #expect(FileManager.default.fileExists(atPath: d.path))
        #expect(!FileSafety.isSymlink(d))
        #expect(try Data(contentsOf: d) == Data(contentsOf: real))
        #expect(summary.errors.isEmpty)
        #expect(summary.addresses.first?.fileCount == 1)
        #expect(summary.addresses.first?.copied == 1)
        #expect(manifest.files["Gatan 1/Gatan 1 skicka/DSC_1.dng"] != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: d.deletingLastPathComponent().path)
        #expect(leftovers == ["DSC_1.dng"])
    }

    @Test func keepVidAndraKorningen() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A")
        let req = [request("DSC_1", address: "A", dng: link)]
        _ = await run(req)
        let (summary, _, actions) = await run(req)
        guard case .keep = actions.first else { Issue.record("väntade keep"); return }
        #expect(summary.addresses.first?.fileCount == 1)
        #expect(summary.addresses.first?.copied == 0)
    }

    @Test func krockMedFrammandFilSkrivsInteOver() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A")
        let d = dest("DSC_1", address: "A")
        try write(d, "redigerarens egen")
        let (summary, manifest, actions) = await run([request("DSC_1", address: "A", dng: link)])
        guard case .conflict = actions.first else { Issue.record("väntade conflict"); return }
        #expect(try String(contentsOf: d, encoding: .utf8) == "redigerarens egen")
        #expect(summary.conflicts.count == 1)
        #expect(manifest.files.isEmpty)
    }

    @Test func identiskFrammandFilLamnasUtanManifest() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A", content: "samma")
        try write(dest("DSC_1", address: "A"), "samma")
        let (summary, manifest, actions) = await run([request("DSC_1", address: "A", dng: link)])
        guard case .identicalForeign = actions.first else { Issue.record("väntade identicalForeign"); return }
        #expect(summary.addresses.first?.fileCount == 1)
        #expect(summary.conflicts.isEmpty)
        #expect(manifest.files.isEmpty)
    }

    @Test func avmarkeradEgenFilTasBortOchMappenStadas() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A")
        _ = await run([request("DSC_1", address: "A", dng: link)])
        let folder = SendFolderSync.folder(in: outputDir, address: "A")
        try write(folder.appendingPathComponent(".DS_Store"), "x")
        let (summary, manifest, actions) = await run([])
        guard case .remove = actions.first else { Issue.record("väntade remove"); return }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(manifest.files.isEmpty)
        #expect(summary.addresses.first?.removed == 1)
        // adressmappen och symlänken är orörda
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func andradEgenFilTasInteBort() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A")
        _ = await run([request("DSC_1", address: "A", dng: link)])
        let d = dest("DSC_1", address: "A")
        try write(d, "redigerad av någon, längre än förut")
        let (summary, manifest, actions) = await run([])
        guard case .keepModified = actions.first else { Issue.record("väntade keepModified"); return }
        #expect(FileManager.default.fileExists(atPath: d.path))
        #expect(summary.warnings.count == 1)
        #expect(manifest.files.count == 1)
    }

    @Test func frammandFilTasInteBort() async throws {
        let folder = SendFolderSync.folder(in: outputDir, address: "A")
        try write(folder.appendingPathComponent("annan.dng"), "x")
        let (_, _, actions) = await run([])
        #expect(actions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("annan.dng").path))
    }

    @Test func konverterarNarDNGSaknas() async throws {
        let (summary, manifest, actions) = await run([request("DSC_9", address: "Osorterade", dng: nil)])
        guard case .convertAndCopy = actions.first else { Issue.record("väntade convertAndCopy"); return }
        let d = SendFolderSync.folder(in: outputDir, address: "Osorterade").appendingPathComponent("DSC_9.dng")
        #expect(try String(contentsOf: d, encoding: .utf8) == "konverterad")
        #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("dng/DSC_9.dng").path))
        #expect(summary.errors.isEmpty)
        #expect(manifest.files["Osorterade/Osorterade skicka/DSC_9.dng"] != nil)
    }

    @Test func manifestSparasOchLaddas() async throws {
        var m = SendFolderSync.Manifest()
        m.files["A/A skicka/x.dng"] = .init(size: 5, modified: Date(timeIntervalSince1970: 1_700_000_000), source: "s")
        try m.save(to: outputDir)
        let loaded = SendFolderSync.Manifest.load(from: outputDir)
        #expect(loaded == m)
        #expect(SendFolderSync.Manifest.load(from: root).files.isEmpty)
    }

    @Test func forsvunnenManifestPostRensas() async throws {
        var m = SendFolderSync.Manifest()
        m.files["A/A skicka/borta.dng"] = .init(size: 5, modified: Date(), source: "s")
        let (summary, manifest, _) = await run([], manifest: m)
        #expect(manifest.files.isEmpty)
        #expect(summary.warnings.isEmpty)
    }

    @Test func dubblettRequestsGerEnAtgard() async throws {
        let (_, link) = try makeDNG("DSC_1", address: "A")
        let r = request("DSC_1", address: "A", dng: link)
        let (summary, _, actions) = await run([r, r])
        #expect(actions.count == 1)
        #expect(summary.addresses.first?.fileCount == 1)
    }
}
