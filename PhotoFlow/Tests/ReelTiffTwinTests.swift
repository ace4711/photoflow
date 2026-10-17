import Foundation
import Testing
@testable import PhotoFlow

/// TIFF-tvillingar: en `.tiff` hoppas över när en JPG med samma stam finns, utom när en befintlig
/// film använder den.
struct ReelTiffTwinTests {

    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/x/\($0)") }
    }

    private func names(_ files: [URL]) -> [String] { files.map(\.lastPathComponent) }

    @Test("TIFF med JPG-tvilling hoppas över, ordningen bevaras")
    func skipsTwins() {
        let files = urls(["DSC_1635_enh.jpg", "DSC_1635_enh.tiff", "DSC_1636_enh.JPG", "DSC_1636_enh.TIF",
                          "hdr_group_1_enh.heic", "hdr_group_1_enh.tif", "other.png", "other.tiff"])
        #expect(names(ReelFileIndex.withoutTiffTwins(files))
                == ["DSC_1635_enh.jpg", "DSC_1636_enh.JPG", "hdr_group_1_enh.heic", "other.png"])
    }

    @Test("TIFF utan tvilling behålls, och en annan stam är ingen tvilling")
    func keepsLoneTiff() {
        let files = urls(["a.tiff", "b.jpg", "b_enh.tiff", "c.tif"])
        #expect(names(ReelFileIndex.withoutTiffTwins(files)) == ["a.tiff", "b.jpg", "b_enh.tiff", "c.tif"])
    }

    @Test("Två TIFF med samma stam räknas inte som tvillingar av varandra")
    func tiffPairIsNotTwin() {
        let files = urls(["a.tif", "a.tiff"])
        #expect(names(ReelFileIndex.withoutTiffTwins(files)).count == 2)
    }

    @Test("Filer i keeping behålls trots tvilling")
    func keepingWins() {
        let files = urls(["a.jpg", "a.tiff", "b.jpg", "b.tiff"])
        #expect(names(ReelFileIndex.withoutTiffTwins(files, keeping: ["b.tiff"])) == ["a.jpg", "b.jpg", "b.tiff"])
    }

    @Test("reel.json i filmmappen: TIFF som filmen använder följer med, övriga tvillingar hoppas över")
    func existingFilmKeepsItsTiff() throws {
        let root = try ObjektfilmTestKit.tempDir("Tiffvillingar")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A FÖRBÄTTRADE")
        let film = root.appendingPathComponent("A FILM")
        let items = try ObjektfilmTestKit.realItems(count: 4, in: source)
        // Tvillingar: en .tiff (tomma filer räcker, de läses inte) bredvid varje JPG.
        for item in items {
            let twin = item.url.deletingPathExtension().appendingPathExtension("tiff")
            try Data("t".utf8).write(to: twin)
        }
        // Utan film: alla tvillingar bort.
        #expect(ReelFileIndex.filmImages(in: source, filmDirectory: film).count == items.count)
        #expect(ReelFileIndex.filmImages(in: source, filmDirectory: nil).allSatisfy { $0.pathExtension != "tiff" })

        // Filmen använder den första bildens TIFF.
        var spec = ReelComposer.compose(items: items, specDirectory: film).spec
        let used = items[0].url.deletingPathExtension().appendingPathExtension("tiff")
        spec.assets[0].sources = [.init(kind: .local, path: ReelComposer.relativePath(from: film, to: used))]
        try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
        try spec.jsonData().write(to: film.appendingPathComponent("reel.json"))

        let files = ReelFileIndex.filmImages(in: source, filmDirectory: film)
        #expect(files.contains { $0.lastPathComponent == used.lastPathComponent })
        #expect(files.filter { $0.pathExtension == "tiff" }.count == 1)
        #expect(files.count == items.count + 1)
        #expect(ReelEditorModel.imageFiles(in: source, filmDirectory: film).count == items.count + 1)
    }

    @Test("Pipelinens FÄRDIGA-källa hoppar över TIFF-tvillingar")
    func proposalSourceSkipsTwins() throws {
        let root = try ObjektfilmTestKit.tempDir("Tiffkalla")
        defer { try? FileManager.default.removeItem(at: root) }
        let address = "Testvägen 1"
        let dir = ReelProposal.SourceKind.finished.directory(in: root, folderName: address)
        let items = try ObjektfilmTestKit.realItems(count: 3, in: dir)
        for item in items {
            try Data("t".utf8).write(to: item.url.deletingPathExtension().appendingPathExtension("tif"))
        }
        let chosen = try #require(ReelProposal.selectSource(outputDir: root, folderName: address).source)
        #expect(chosen.files.count == 3)
        #expect(chosen.files.allSatisfy { $0.pathExtension != "tif" })
    }
}
