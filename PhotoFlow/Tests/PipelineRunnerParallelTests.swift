import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PhotoFlow

/// Fas 1c: "Förbättra bilder" med flera jobb samtidigt ger samma resultat (parametrar, pixlar,
/// loggordning) som i följd, och avbryt-knappen mitt i en parallell körning stoppar steget
/// utan att förstöra det som hann bli klart. Små syntetiska förhandsbilder (ingen RAW behövs).
@MainActor
@Suite(.serialized)
struct PipelineRunnerParallelTests {

    private func tempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerParallelTests-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// En liten JPEG med en gradient som skiljer sig per bild (olika exponering/färg ger olika
    /// parametrar, så att en förväxling mellan jobb syns).
    private func writeJPEG(index: Int, to url: URL, width: Int = 240, height: Int = 160) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let base = 0.15 + 0.05 * Double(index % 12)
        for x in 0..<width {
            let t = Double(x) / Double(width - 1)
            ctx.setFillColor(red: min(1, base + 0.5 * t), green: min(1, base + 0.3 * t + 0.02 * Double(index % 5)),
                             blue: min(1, base + 0.2 * t), alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// En session med `count` enskilda bilder som bara har förhandsbilder.
    private func makeSession(count: Int, name: String) throws -> (PipelineRunner, PipelineState, URL) {
        let outputDir = tempDir(name)
        let previews = outputDir.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let state = PipelineState()
        state.outputDirectory = outputDir
        var photos: [PhotoItem] = []
        var groups: [BracketGroup] = []
        for i in 0..<count {
            let id = String(format: "DSC_%04d", i + 1)
            let preview = previews.appendingPathComponent("\(id).jpg")
            try writeJPEG(index: i, to: preview)
            photos.append(PhotoItem(
                id: id, filename: "\(id).NEF", nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
                dngURL: nil, previewURL: preview, exposureTime: "1/125", exposureSeconds: 1.0 / 125.0,
                fNumber: 8.0, iso: 100, dateTime: Date(timeIntervalSince1970: 1_790_000_000 + Double(i * 60))
            ))
            groups.append(BracketGroup(id: i + 1, isBracket: false, folderName: String(format: "single_%03d", i + 1), photoIDs: [id],
                                       fNumber: 8, iso: 100, timeStart: "10:00", timeEnd: "10:00", exposureRangeStops: 0))
        }
        state.allPhotos = photos
        state.bracketGroups = groups
        state.updateStep(.enhancePhotos, phase: .active)
        return (PipelineRunner(state: state), state, outputDir)
    }

    /// Kör med inställningen `maxParallelism` och återställer användarens värde efteråt (testerna
    /// körs med appen som värd och delar dess inställningar).
    private func withParallelism<T>(_ value: Int, _ body: () async throws -> T) async rethrows -> T {
        let settings = AppSettings.shared
        let previous = settings.maxParallelism
        settings.maxParallelism = value
        defer { settings.maxParallelism = previous }
        return try await body()
    }

    /// Loggraderna för steget utan tidsangivelsen ("— 0s"), som skiljer mellan körningar.
    private func stepLog(_ state: PipelineState) -> [String] {
        (state.stepStatuses[.enhancePhotos]?.logEntries ?? []).map { line in
            line.text.components(separatedBy: " — ").first ?? line.text
        }
    }

    /// Avkodade pixlar (8-bitars RGBA) för en bildfil.
    private func pixels(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    @Test("Parallell förbättring ger samma parametrar, pixlar och loggordning som seriell")
    func parallelEnhance_matchesSerial() async throws {
        let count = 10
        let (serialRunner, serialState, serialDir) = try makeSession(count: count, name: "serial")
        let (parallelRunner, parallelState, parallelDir) = try makeSession(count: count, name: "parallel")
        defer {
            try? FileManager.default.removeItem(at: serialDir)
            try? FileManager.default.removeItem(at: parallelDir)
        }

        let serialDone = try await withParallelism(1) { try await serialRunner.runEnhancePhotos() }
        let parallelDone = try await withParallelism(4) { try await parallelRunner.runEnhancePhotos() }
        #expect(serialDone == count)
        #expect(parallelDone == count)

        let serialLog = try #require(EnhancementLog.load(from: serialDir))
        let parallelLog = try #require(EnhancementLog.load(from: parallelDir))
        #expect(serialLog.entries.count == count)
        #expect(Set(serialLog.entries.keys) == Set(parallelLog.entries.keys))
        for (key, entry) in serialLog.entries {
            let other = try #require(parallelLog.entries[key])
            #expect(entry.parameters == other.parameters, "parametrar för \(key)")
            #expect(entry.analysis == other.analysis, "analys för \(key): \(entry.analysis) VS \(other.analysis)")
            #expect(entry.outputs == other.outputs)
            #expect(entry.fingerprint == other.fingerprint)
        }

        // Samma loggrader i samma ordning (resultaten lämnas i jobbordning).
        #expect(stepLog(serialState) == stepLog(parallelState))
        #expect(!stepLog(parallelState).isEmpty)

        // Samma pixlar i de förbättrade filerna.
        let serialStaging = AddressFolderLayout.enhancedStagingDir(in: serialDir)
        let parallelStaging = AddressFolderLayout.enhancedStagingDir(in: parallelDir)
        for key in serialLog.entries.keys.sorted() {
            for ext in ["tiff", "jpg"] {
                let name = "\(key)\(AddressFolderLayout.enhancedFileSuffix).\(ext)"
                let a = pixels(serialStaging.appendingPathComponent(name))
                let b = pixels(parallelStaging.appendingPathComponent(name))
                #expect(a != nil)
                #expect(a == b, "pixlar i \(name)")
            }
        }
    }

    @Test("Avbryt mitt i en parallell förbättring: steget stoppar, det färdiga sparas, omstart gör klart resten")
    func cancelMidParallelEnhance() async throws {
        let count = 16
        let (runner, state, outputDir) = try makeSession(count: count, name: "cancel")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        try await withParallelism(3) {
            final class Outcome { var error: Error?; var finished = false }
            let outcome = Outcome()
            // Samma väg som appens körning: steget körs i `pipelineTask`, som avbryt-knappen avbryter.
            runner.pipelineTask = Task { @MainActor in
                do { _ = try await runner.runEnhancePhotos() } catch { outcome.error = error }
                outcome.finished = true
            }
            while (state.stepStatuses[.enhancePhotos]?.processedCount ?? 0) < 1 && !outcome.finished {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            runner.cancel()
            await runner.pipelineTask?.value

            #expect(outcome.error is CancellationError)
            let log = try #require(EnhancementLog.load(from: outputDir))
            #expect(log.entries.count >= 1)
            #expect(log.entries.count < count)
            // Varje sparad post har sina filer.
            let staging = AddressFolderLayout.enhancedStagingDir(in: outputDir)
            for (_, entry) in log.entries {
                for output in entry.outputs {
                    #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(output).path))
                }
            }

            // Omstart: de färdiga hoppas över och resten görs.
            let doneBefore = log.entries.count
            state.isRunning = true
            let total = try await runner.runEnhancePhotos()
            #expect(total == count)
            #expect(EnhancementLog.load(from: outputDir)?.entries.count == count)
            #expect(doneBefore < count)
        }
    }
}
