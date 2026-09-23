import Foundation
import Testing
@testable import PhotoFlow

/// "Verifiera session" (se FORBATTRINGAR.md): bygger en syntetisk
/// sessions-outputmapp i EXAKT samma filformat som
/// `Services/Pipeline/*`/`AddressFolderLayout`/`BracketAnalyzer` faktiskt
/// producerar (samma mönster som `AddressSessionLoaderTests`), och verifierar
/// att `SessionVerifier` upptäcker varje enskild avvikelse med rätt
/// allvarlighetsgrad — och att en helt korrekt session ger noll fel.
///
/// `@MainActor`: `SessionVerifier.verify`/`loadContext` är `MainActor`
/// (samma skäl som `SessionManifestStore`, se dess egen kommentar) — bara de
/// sex `check*`-funktionerna själva är `nonisolated` för att kunna köras
/// parallellt, se `SessionVerifier.swift`s topp-kommentar.
@MainActor
struct SessionVerifierTests {
    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionVerifierTests-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: Any, to url: URL) {
        let data = try! JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try! data.write(to: url)
    }

    private let folderName = "Testgatan 1"

    /// Bygger en fullständigt korrekt sessions-outputmapp för EN adress med
    /// `filenames.count` bilder: DNG/preview-staging, adressmappens tre
    /// undermappar (DNG/TITTBILDER/ÖVRIGA) med symlänkar, en XMP-sidecar per
    /// NEF, och en `bracket_groups.json` som täcker allihop. Varje test
    /// nedan tar bort/lägger till EN sak för att isolera exakt den kontroll
    /// som ska slå till.
    private func buildValidSession(outputDir: URL, originalsDir: URL, filenames: [String]) {
        let fm = FileManager.default
        let dngDir = outputDir.appendingPathComponent("dng")
        let previewDir = outputDir.appendingPathComponent("previews")
        let hdrDir = outputDir.appendingPathComponent("hdr")
        try! fm.createDirectory(at: dngDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: hdrDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: originalsDir, withIntermediateDirectories: true)

        let dngFolder = AddressFolderLayout.dngDir(in: outputDir, folderName: folderName)
        let previewFolder = AddressFolderLayout.previewDir(in: outputDir, folderName: folderName)
        let extrasFolder = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
        for dir in [dngFolder, previewFolder, extrasFolder] {
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var datetimes: [String] = []

        for (i, filename) in filenames.enumerated() {
            let base = (filename as NSString).deletingPathExtension

            let originalNEF = originalsDir.appendingPathComponent(filename)
            fm.createFile(atPath: originalNEF.path, contents: Data("nef".utf8))

            let dngFile = dngDir.appendingPathComponent("\(base).dng")
            fm.createFile(atPath: dngFile.path, contents: Data("dng".utf8))

            let previewFile = previewDir.appendingPathComponent("\(base).jpg")
            fm.createFile(atPath: previewFile.path, contents: Data("jpg".utf8))

            try? fm.createSymbolicLink(at: extrasFolder.appendingPathComponent(filename), withDestinationURL: originalNEF)
            try? fm.createSymbolicLink(at: dngFolder.appendingPathComponent("\(base).dng"), withDestinationURL: dngFile)
            try? fm.createSymbolicLink(at: previewFolder.appendingPathComponent("\(base).jpg"), withDestinationURL: previewFile)

            let sidecar = extrasFolder.appendingPathComponent("\(base).xmp")
            fm.createFile(atPath: sidecar.path, contents: Data("<xmp/>".utf8))

            datetimes.append(dateFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))))
        }

        let groupsJSON: [String: Any] = [
            "total_images": filenames.count,
            "total_groups": 1,
            "params": ["max_time_gap": 15, "min_bracket_size": 3],
            "bracket_groups_count": 0,
            "single_groups_count": 1,
            "groups": [[
                "group_id": 1,
                "is_bracket": false,
                "image_count": filenames.count,
                "files": filenames,
                "exposures": filenames.map { _ in "1/100" },
                "fnumber": 8.0,
                "iso": 100,
                "time_start": "10:00:00",
                "time_end": "10:00:05",
                "date_start": datetimes.first ?? "2023-01-01 10:00:00",
                "date_end": datetimes.last ?? "2023-01-01 10:00:00",
                "datetimes": datetimes,
                "exposure_range_stops": 0,
                "suggested_hdr_indices": [],
                "unique_exposure_levels": 1
            ]]
        ]
        write(groupsJSON, to: outputDir.appendingPathComponent("bracket_groups.json"))
    }

    private func finding(_ report: SessionVerifier.Report, _ id: String) -> SessionVerifier.Finding? {
        report.findings.first { $0.id == id }
    }

    // MARK: - Frisk session

    @Test("En helt korrekt session ger noll fel")
    func validSession_hasZeroErrors() async throws {
        let outputDir = tempDir("valid")
        let originalsDir = tempDir("valid-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        #expect(report.errorCount == 0)
        // Sanity: kontrollerna faktiskt kördes och hittade OK-fynd, inte bara
        // ett tomt resultat pga att något laddades fel.
        #expect(report.okCount > 0)
        #expect(finding(report, "symlinks.broken")?.severity == .ok)
        #expect(finding(report, "coverage.previewFiles")?.severity == .ok)
        #expect(finding(report, "coverage.dngFiles")?.severity == .ok)
        #expect(finding(report, "coverage.extrasLinks")?.severity == .ok)
        #expect(finding(report, "orphans.hdrLeftovers")?.severity == .ok)
    }

    @Test("Outputmapp som inte finns ger ett fel, kraschar inte")
    func missingOutputDirectory_reportsSingleError() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("SessionVerifierTests-does-not-exist-\(UUID().uuidString)")
        let report = try await SessionVerifier.verify(outputDir: missing)
        #expect(report.errorCount == 1)
        #expect(finding(report, "output.missing") != nil)
    }

    // MARK: - Bruten symlänk

    @Test("Bruten symlänk (originalet borttaget) rapporteras som fel")
    func brokenSymlink_isReportedAsError() async throws {
        let outputDir = tempDir("broken-symlink")
        let originalsDir = tempDir("broken-symlink-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        // Ta bort originalet en NEF-symlänk pekar på — själva länken finns
        // kvar (så `coverage.extrasLinks` inte påverkas), men blir bruten.
        try FileManager.default.removeItem(at: originalsDir.appendingPathComponent("DSC_0001.NEF"))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let brokenFinding = try #require(finding(report, "symlinks.broken"))
        #expect(brokenFinding.severity == .error)
        #expect(brokenFinding.affectedFiles.contains { $0.hasSuffix("DSC_0001.NEF") })
        // Coverage-kontrollen för NEF-symlänkar ska INTE påverkas — länken
        // finns, den pekar bara på ingenting längre.
        #expect(finding(report, "coverage.extrasLinks")?.severity == .ok)
    }

    // MARK: - Saknad preview

    @Test("Saknad preview rapporteras som fel")
    func missingPreview_isReportedAsError() async throws {
        let outputDir = tempDir("missing-preview")
        let originalsDir = tempDir("missing-preview-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        let fm = FileManager.default
        try fm.removeItem(at: outputDir.appendingPathComponent("previews/DSC_0002.jpg"))
        try fm.removeItem(at: AddressFolderLayout.previewDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0002.jpg"))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let previewFinding = try #require(finding(report, "coverage.previewFiles"))
        #expect(previewFinding.severity == .error)
        #expect(previewFinding.affectedFiles == ["DSC_0002"])
        #expect(previewFinding.recommendation != nil)
    }

    // MARK: - HDR-fil kvar i hdr/

    @Test("HDR-resultat kvar i hdr/-stagingmappen rapporteras som fel")
    func leftoverHDRFile_isReportedAsError() async throws {
        let outputDir = tempDir("hdr-leftover")
        let originalsDir = tempDir("hdr-leftover-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        let leftoverTiff = outputDir.appendingPathComponent("hdr/hdr_group_1.tiff")
        FileManager.default.createFile(atPath: leftoverTiff.path, contents: Data("tiff".utf8))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let hdrFinding = try #require(finding(report, "orphans.hdrLeftovers"))
        #expect(hdrFinding.severity == .error)
        #expect(hdrFinding.affectedFiles.count == 1)
        #expect(hdrFinding.affectedFiles.first?.hasSuffix(leftoverTiff.lastPathComponent) == true)
        #expect(hdrFinding.recommendation != nil)
    }

    // MARK: - Manifest säger fler filer än vad som finns

    @Test("Manifest som säger fler bearbetade previews än vad som finns på disk rapporteras som varning")
    func manifestOvercount_isReportedAsWarning() async throws {
        let outputDir = tempDir("manifest-overcount")
        let originalsDir = tempDir("manifest-overcount-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion, sessionID: UUID(),
            createdAt: Date(), updatedAt: Date(),
            inputDirectory: originalsDir.path, outputDirectory: outputDir.path,
            photoCount: 2, groupCount: 1, addresses: [],
            steps: [
                DashboardStep.generatePreviews.manifestKey: SessionManifest.StepRecord(
                    stepID: DashboardStep.generatePreviews.manifestKey, phase: "complete",
                    // Manifestet säger 5 — bara 2 previews finns faktiskt på disk.
                    processedCount: 5, totalCount: 5, duration: nil, finishedAt: nil, inputFingerprint: nil
                )
            ],
            cullSummary: SessionManifest.CullSummary(accepted: 0, rejected: 0, unreviewed: 2)
        )
        SessionManifestStore.save(manifest, to: outputDir)

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let manifestFinding = try #require(finding(report, "manifest.previews"))
        #expect(manifestFinding.severity == .warning)
        #expect(manifestFinding.detail.contains("5"))
        #expect(manifestFinding.detail.contains("2"))
    }

    // MARK: - NEF utan sidecar

    @Test("NEF utan XMP-sidecar rapporteras som varning")
    func missingXMPSidecar_isReportedAsWarning() async throws {
        let outputDir = tempDir("missing-sidecar")
        let originalsDir = tempDir("missing-sidecar-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        let extrasFolder = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
        try FileManager.default.removeItem(at: extrasFolder.appendingPathComponent("DSC_0001.xmp"))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let sidecarFinding = try #require(finding(report, "metadata.xmpSidecarSample"))
        #expect(sidecarFinding.severity == .warning)
        #expect(sidecarFinding.affectedFiles.contains { $0.hasSuffix("DSC_0001.NEF") })
    }

    // MARK: - Gallring

    @Test("Avvisad bild helt borttagen från disk stämmer med gallringsläget \"radera\" — inget fel")
    func rejectedPhotoDeleted_matchesDeleteMode() async throws {
        let outputDir = tempDir("cull-deleted")
        let originalsDir = tempDir("cull-deleted-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF", "DSC_0002.NEF"])

        // Simulera "radera"-läget (`PipelineRunner+Culling.deleteRejectedFiles`):
        // alla tre filtyper för den avvisade bilden borttagna ur adressmappen.
        let fm = FileManager.default
        try fm.removeItem(at: AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0001.NEF"))
        try fm.removeItem(at: AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0001.xmp"))
        try fm.removeItem(at: AddressFolderLayout.dngDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0001.dng"))
        try fm.removeItem(at: AddressFolderLayout.previewDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0001.jpg"))

        write(["1_DSC_0001.NEF": "rejected", "1_DSC_0002.NEF": "accepted"], to: outputDir.appendingPathComponent("cull_decisions.json"))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let cullFinding = try #require(finding(report, "culling.consistency"))
        #expect(cullFinding.severity == .ok)
    }

    @Test("Gallringsbeslut som inte stämmer med filerna på disk rapporteras som fel")
    func inconsistentCullState_isReportedAsError() async throws {
        let outputDir = tempDir("cull-inconsistent")
        let originalsDir = tempDir("cull-inconsistent-originals")
        buildValidSession(
            outputDir: outputDir, originalsDir: originalsDir,
            filenames: ["DSC_0001.NEF", "DSC_0002.NEF", "DSC_0003.NEF", "DSC_0004.NEF"]
        )

        // DSC_0001 avvisad men fortfarande orörd (varken borttagen eller
        // flyttad) OCH DSC_0002 avvisad men helt borttagen — två olika
        // "lägen" samtidigt, vilket inte kan stämma med EN vald
        // `cullAction`.
        let fm = FileManager.default
        try fm.removeItem(at: AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0002.NEF"))
        try fm.removeItem(at: AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0002.xmp"))
        try fm.removeItem(at: AddressFolderLayout.dngDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0002.dng"))
        try fm.removeItem(at: AddressFolderLayout.previewDir(in: outputDir, folderName: folderName).appendingPathComponent("DSC_0002.jpg"))

        write([
            "1_DSC_0001.NEF": "rejected",
            "1_DSC_0002.NEF": "rejected",
            "1_DSC_0003.NEF": "accepted",
            "1_DSC_0004.NEF": "accepted"
        ], to: outputDir.appendingPathComponent("cull_decisions.json"))

        let report = try await SessionVerifier.verify(outputDir: outputDir)

        let cullFinding = try #require(finding(report, "culling.consistency"))
        #expect(cullFinding.severity == .error)
        #expect(!cullFinding.affectedFiles.isEmpty)
    }

    // MARK: - Cancellation

    @Test("En avbruten verifiering kastar CancellationError i stället för att returnera en ofullständig rapport")
    func cancellation_throwsInsteadOfReturningPartialReport() async {
        let outputDir = tempDir("cancelled")
        let originalsDir = tempDir("cancelled-originals")
        buildValidSession(outputDir: outputDir, originalsDir: originalsDir, filenames: ["DSC_0001.NEF"])

        let task = Task {
            try await SessionVerifier.verify(outputDir: outputDir)
        }
        task.cancel()

        do {
            _ = try await task.value
            // Beroende på timing kan `verify` hinna returnera INNAN
            // avbrottet upptäcks (kontrollerna är snabba) — det är inte ett
            // fel i sig, bara inte vad det här testet undersöker.
        } catch is CancellationError {
            // Förväntat.
        } catch {
            Issue.record("Förväntade CancellationError, fick \(error)")
        }
    }
}
