import Foundation
import CoreGraphics

/// Orchestrates the full RAW-to-merged-TIFF pipeline for one bracket group:
/// render every exposure with `RAWRenderer`, optionally correct hand-held
/// misalignment with `HDRAlignment`, fuse with `ExposureFusion`, and write
/// the result with `HDRWriter`. This is the Swift/Core Image replacement for
/// the old `PipelineRunner+HDR.swift` OpenCV/Python path (see
/// `FORBATTRINGAR.md`, "Fas 3a").
///
/// `nonisolated` (not `@MainActor`): called with `await` from
/// `PipelineRunner` (which itself runs on `@MainActor` under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`), a call from a `MainActor`
/// context into a `nonisolated async` function actually hops off the main
/// actor to run on the cooperative thread pool — exactly the "run outside
/// MainActor" behavior the pipeline needs for a multi-second RAW decode +
/// pyramid fusion, without a manual `Task.detached`.
nonisolated enum HDREngine {
    /// Räknas upp när sammanslagningens resultat ändras för samma indata, så att
    /// det som bygger på HDR-filen (t.ex. "Förbättra bilder") vet att göra om.
    /// 2 = rimlig justering (3000 px, avvisade orimliga förskjutningar), skärpning
    /// och rätta kanter i pyramiden.
    /// 3 = window pull (fönster från mörkaste exponeringen), EV-sortering med
    /// medianreferens, exponeringsmatchad registrering och straff för klippta pixlar
    /// i fusionsvikterna (docs/plan-hdr-fonster.md, fas 0–1).
    /// 4 = ljusare fönsterutsikt: högdagerskuldra i stället för hårt p99-tak, mål-median 0,72.
    /// 5 = window pull sorterar bort släta ytor och ljusfall (lampa/sol på tak och väggar,
    /// solbelysta pelare) som tidigare blev grå fläckar (docs/plan-maklarstil.md, v2).
    /// 6 = metoden "basram" (standard): en ljus exponering som bas med pixelvis
    /// högdageråtervinning i stället för Mertens-fusion (`BaseFrameMerge`), ramarna renderade
    /// utan RAW-kurva; fönstrets kärna ersätts helt i window pull.
    static let version = 6

    /// Sammanslagningsmetod: "basram" (standard sedan v6) eller Mertens exposure fusion.
    enum Method: String, Sendable, CaseIterable {
        case baseFrame = "base"
        case fusion
    }

    /// En exponering: RAW-filen (DNG eller NEF) och exponeringstiden i sekunder
    /// (0 = okänd).
    struct Frame: Sendable, Equatable {
        var url: URL
        var exposureSeconds: Double
    }

    struct Options: Sendable {
        var maxDimension: Int = 6000
        var alignEnabled: Bool = true
        /// Förut 2400 px — förstorades ~2,5× i granskningen på en 6K-skärm.
        var jpegMaxDimension: Int = 4000
        var jpegQuality: Double = 0.92
        /// Lätt skärpning (unsharp mask) av resultatet, som kamerans och
        /// Lightrooms standardrendering gör — RAW-renderingen skärper inte.
        var sharpenEnabled: Bool = true
        /// Window pull: fönsterutsikten från den mörkaste exponeringen.
        var windowPull = WindowPull.Options()
        var method: Method = .baseFrame
        var baseFrame = BaseFrameMerge.Options()
        /// Var fönstermasken sparas (PNG, ~1500 px) — `nil` = sparas inte.
        var maskURL: URL?
        /// Felsökningsmapp: mask, mörkMatchad, fusion utan pull och `hdr_metrics.json`.
        var debugDir: URL?
    }

    /// Vad sammanslagningen gjorde — sparas i `hdr.json`.
    struct MergeResult: Sendable {
        var metadataWritten: Bool
        /// Exponeringarna i den ordning de slogs ihop (mörkast först) och referensen.
        var orderedFrames: [URL]
        var referenceFrame: URL
        var windowSource: URL?
        var window: WindowPull.Stats?
    }

    enum EngineError: LocalizedError {
        case tooFewImages
        case sizeMismatch

        var errorDescription: String? {
            switch self {
            case .tooFewImages: return "Minst 2 bilder krävs för HDR-sammanslagning."
            case .sizeMismatch: return "Bilderna i bracket-gruppen har olika storlek efter RAW-rendering."
            }
        }
    }

    /// Exponeringarna sorterade från mörkast till ljusast. Kameran tar dem i olika
    /// ordning (Nikon: 0/−/+), och referensen ska vara medianexponeringen — förut togs
    /// `count/2` i tagningsordning, vilket gav fel vitbalans/registreringsreferens.
    /// Saknas en exponeringstid behålls ordningen som den kom.
    static func orderedFrames(_ frames: [Frame]) -> [Frame] {
        guard frames.allSatisfy({ $0.exposureSeconds > 0 }) else { return frames }
        return frames.enumerated().sorted { a, b in
            a.element.exposureSeconds != b.element.exposureSeconds
                ? a.element.exposureSeconds < b.element.exposureSeconds
                : a.offset < b.offset
        }.map(\.element)
    }

    /// Referensens index i de sorterade exponeringarna: medianen (vid jämnt antal den
    /// ljusare av de två mittersta — interiören är det viktiga i en fastighetsbild).
    static func referenceIndex(count: Int) -> Int { count / 2 }

    /// Fönsterkällan: gruppens mörkaste exponering, men bara om den är mörkare än
    /// referensen (annars finns inget att hämta).
    static func windowSource(among group: [Frame]) -> Frame? {
        let known = group.filter { $0.exposureSeconds > 0 }
        guard known.count == group.count, let darkest = known.min(by: { $0.exposureSeconds < $1.exposureSeconds }) else {
            return group.first
        }
        return darkest
    }

    /// Slår ihop `frames` (DNG-if-available/NEF, valfri ordning — sorteras här) till
    /// ett TIFF+JPEG-par. `windowSource` (gruppens mörkaste exponering, även om den inte
    /// ingår i `frames`) används för window pull när det är på.
    ///
    /// Checks `Task.checkCancellation()` between each image render and
    /// before/after fusion, so a cancelled pipeline `Task` unwinds promptly
    /// instead of finishing an already-started multi-second merge.
    ///
    /// - Parameter progress: optional UI progress callback, 0...1, called a
    ///   handful of times (per image rendered, per fusion phase) — not
    ///   throwing; use the caller's own `Task` cancellation to abort.
    ///
    /// - Parameter metadata: IPTC/XMP/GPS för TIFF- respektive JPEG-filen när den redan är
    ///   känd (fas 1b) — skrivs i samma exiftool-anrop som EXIF-kopian. `nil` = bara EXIF,
    ///   metadatasteget skriver resten.
    ///
    /// `@concurrent`: projektet bygger med `NonisolatedNonsendingByDefault`, så
    /// utan det kördes hela sammanslagningen (sekunder per grupp, pixel för pixel)
    /// på anroparens aktör — huvudtråden — och appen frös med snurrande färghjul.
    @concurrent
    @discardableResult
    static func merge(
        frames inputFrames: [Frame],
        windowSource: Frame? = nil,
        options: Options = Options(),
        tiffURL: URL,
        jpegURL: URL,
        exiftoolPath: String?,
        metadata: (tiff: IPTCFileMetadata?, jpeg: IPTCFileMetadata?) = (nil, nil),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MergeResult {
        guard inputFrames.count >= 2 else { throw EngineError.tooFewImages }
        let started = Date()

        let frames = orderedFrames(inputFrames)
        let rawURLs = frames.map(\.url)
        let middleIndex = referenceIndex(count: frames.count)
        let whiteBalance = try PipelineMetrics.phase("readWhiteBalance") { try RAWRenderer.readWhiteBalance(url: rawURLs[middleIndex]) }

        // Fönsterkällan: en fusionsram om den mörkaste redan ingår, annars en extra rendering.
        var pullSource: Frame?
        if options.windowPull.enabled, let candidate = windowSource ?? frames.first {
            let darkestFused = frames[0]
            if candidate.url == darkestFused.url || (candidate.exposureSeconds > 0 && darkestFused.exposureSeconds > 0
                                                      && candidate.exposureSeconds >= darkestFused.exposureSeconds) {
                pullSource = darkestFused
            } else {
                pullSource = candidate
            }
        }
        let extraWindowFrame = pullSource.map { $0.url != frames[0].url } ?? false
        let renderCount = rawURLs.count + (extraWindowFrame ? 1 : 0)

        var rendered: [RAWRenderer.RenderedImage] = []
        rendered.reserveCapacity(renderCount)
        let renderList = rawURLs + (extraWindowFrame ? [pullSource!.url] : [])
        for (i, url) in renderList.enumerated() {
            try Task.checkCancellation()
            progress?(0.05 + 0.45 * Double(i) / Double(renderCount))
            rendered.append(try PipelineMetrics.phase("render", bytesIn: PipelineMetrics.totalSize(of: [url])) {
                try RAWRenderer.render(url: url, whiteBalance: whiteBalance, maxDimension: options.maxDimension,
                                       boostAmount: options.method == .baseFrame ? 0 : 1)
            })
        }

        guard let first = rendered.first else { throw EngineError.tooFewImages }
        let width = first.width, height = first.height
        guard rendered.allSatisfy({ $0.width == width && $0.height == height }) else {
            throw EngineError.sizeMismatch
        }
        let windowIndex: Int? = pullSource == nil ? nil : (extraWindowFrame ? rendered.count - 1 : 0)

        var darkShift: CGPoint?
        var appliedWindowShift: CGPoint?
        var darkShiftRejected = false
        var residualShift: CGPoint?
        if options.alignEnabled {
            let reference = rendered[middleIndex]
            for i in rendered.indices where i != middleIndex {
                try Task.checkCancellation()
                let measured = try PipelineMetrics.phase("align") {
                    try HDRAlignment.computeShift(
                        floating: rendered[i], reference: reference, maxAlignDimension: HDRAlignment.refinedAlignDimension
                    )
                }
                // Orimliga förskjutningar avvisas, små rundas till hela pixlar — se sanitizedShift.
                let shift = HDRAlignment.sanitizedShift(measured, width: width, height: height)
                if i == windowIndex {
                    darkShift = measured
                    darkShiftRejected = shift == nil
                }
                guard let shift, shift != .zero else { continue }
                let shifted = PipelineMetrics.phase("align.shift") {
                    RAWRenderer.shiftRGBA(rendered[i].pixels, width: width, height: height, dx: Float(shift.x), dy: Float(shift.y))
                }
                // Verifiering av större förskjutningar: mät om på den förskjutna bilden. En riktig
                // förskjutning lämnar ~0 kvar; en felmätning (vanligast för den mörkaste ramen,
                // 6–7 EV under referensen) lämnar lika mycket kvar åt andra hållet — då behålls
                // bilden oförskjuten. Uppmätt: 18 px felregistrering i 2 av 30 testgrupper.
                if HDRAlignment.needsVerification(shift) {
                    let residual = try PipelineMetrics.phase("align.verify") {
                        try HDRAlignment.computeShift(floating: RAWRenderer.RenderedImage(width: width, height: height, pixels: shifted),
                                                      reference: reference, maxAlignDimension: HDRAlignment.refinedAlignDimension)
                    }
                    if !HDRAlignment.verifiedShift(shift, residual: residual) {
                        if i == windowIndex { darkShiftRejected = true }
                        continue
                    }
                }
                rendered[i].pixels = shifted
                if i == windowIndex { appliedWindowShift = shift }
            }
            // Felsökning: kvarvarande förskjutning för fönsterkällan efter justeringen.
            if options.debugDir != nil, let windowIndex, windowIndex != middleIndex {
                let residual = try HDRAlignment.computeShift(floating: rendered[windowIndex], reference: reference,
                                                             maxAlignDimension: HDRAlignment.refinedAlignDimension)
                residualShift = residual
            }
        }
        progress?(0.55)
        try Task.checkCancellation()

        let images = rendered.prefix(rawURLs.count).map(\.pixels)
        let fused: [Float]
        // Referensen för window pull: medianexponeringen (båda metoderna).
        let pullReference = rendered[middleIndex].pixels
        var referenceURL = rawURLs[middleIndex]
        switch options.method {
        case .fusion:
            fused = try ExposureFusion.fuse(images: Array(images), width: width, height: height) { fraction in
                try Task.checkCancellation()
                progress?(0.55 + 0.30 * fraction)
            }
        case .baseFrame:
            // Alla renderade exponeringar mörkast först (en extra fönsterram är gruppens mörkaste).
            var ordered = Array(images)
            var orderedURLs = rawURLs
            if extraWindowFrame, let last = rendered.last, let url = pullSource?.url {
                ordered.insert(last.pixels, at: 0)
                orderedURLs.insert(url, at: 0)
            }
            let result = PipelineMetrics.phase("baseFrame") {
                BaseFrameMerge.merge(images: ordered, width: width, height: height, options: options.baseFrame)
            }
            fused = result.pixels
            // Fönsterdetekteringen görs fortfarande mot medianexponeringen: i en ljusare basram
            // är stora väggpartier klippta och växer ihop med fönstren (sorteras då bort som slät yta).
            referenceURL = orderedURLs[result.baseIndex]
            progress?(0.85)
        }

        try Task.checkCancellation()
        var pulled = fused
        var windowStats: WindowPull.Stats?
        var pullResult: WindowPull.Result?
        if let windowIndex {
            // Basram: utsikten hämtas ur fönsterramen med RAW-filtrets vanliga tonkurva (som i
            // fusionen) — den linjära renderingen gav en platt, mjölkig utsikt. Samma förskjutning.
            var pullDark = rendered[windowIndex].pixels
            if options.method == .baseFrame, let url = pullSource?.url {
                var curved = try PipelineMetrics.phase("render", bytesIn: PipelineMetrics.totalSize(of: [url])) {
                    try RAWRenderer.render(url: url, whiteBalance: whiteBalance, maxDimension: options.maxDimension, boostAmount: 1)
                }
                if curved.width == width && curved.height == height {
                    if let shift = appliedWindowShift {
                        curved.pixels = RAWRenderer.shiftRGBA(curved.pixels, width: width, height: height, dx: Float(shift.x), dy: Float(shift.y))
                    }
                    pullDark = curved.pixels
                }
            }
            let result = PipelineMetrics.phase("windowPull") {
                WindowPull.apply(fused: fused, reference: pullReference, dark: pullDark,
                                 width: width, height: height, options: options.windowPull, keepFullMask: options.debugDir != nil)
            }
            pulled = result.pixels
            windowStats = result.stats
            if options.method == .baseFrame {
                let boxes = WindowPull.windowBoxes(result.components)
                let dehazed = PipelineMetrics.phase("windowDehaze") {
                    WindowPull.dehazeWindows(pulled, width: width, height: height, boxes: boxes)
                }
                pulled = dehazed.pixels
                windowStats?.dehazedFraction = dehazed.fraction
            }
            pullResult = result
            if let maskURL = options.maskURL {
                try? FileManager.default.createDirectory(at: maskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if result.stats.applied {
                    try? HDRImageOps.writeGrayPNG(result.mask, to: maskURL)
                } else {
                    try? FileManager.default.removeItem(at: maskURL)
                }
            }
        } else if let maskURL = options.maskURL {
            try? FileManager.default.removeItem(at: maskURL)
        }
        progress?(0.9)

        try Task.checkCancellation()
        // Radien skalas med upplösningen: 1,2 px vid kamerans 8256 px.
        let finalPixels = options.sharpenEnabled
            ? PipelineMetrics.phase("sharpen") {
                HDRWriter.sharpen(pixels: pulled, width: width, height: height, radius: max(0.6, 1.2 * Double(max(width, height)) / 8256), intensity: 0.6)
            }
            : pulled
        try HDRWriter.write(pixels: finalPixels, width: width, height: height, tiffURL: tiffURL, jpegURL: jpegURL, jpegMaxDimension: options.jpegMaxDimension, jpegQuality: options.jpegQuality)
        progress?(0.95)

        if let debugDir = options.debugDir {
            try? writeDebug(to: debugDir, group: tiffURL.deletingPathExtension().lastPathComponent,
                            fused: fused, output: pulled, rendered: rendered, middleIndex: middleIndex, windowIndex: windowIndex,
                            width: width, height: height, pull: pullResult, frames: rawURLs, windowSource: pullSource?.url,
                            darkShift: darkShift, darkShiftRejected: darkShiftRejected, residualShift: residualShift,
                            seconds: Date().timeIntervalSince(started))
        }

        var metadataWritten = false
        if let exiftoolPath {
            // Fasnamnet "copyEXIF" behålls för jämförbarhet i timings.jsonl (fas 1a).
            metadataWritten = PipelineMetrics.phase("copyEXIF") {
                HDRWriter.writeMetadata(from: rawURLs[middleIndex],
                                        outputs: [(tiffURL, metadata.tiff), (jpegURL, metadata.jpeg)],
                                        exiftoolPath: exiftoolPath)
            }
        }
        progress?(1.0)
        return MergeResult(metadataWritten: metadataWritten, orderedFrames: rawURLs, referenceFrame: referenceURL,
                           windowSource: pullSource?.url, window: windowStats)
    }

    /// Felsökningsfiler per grupp i `<debugDir>/<grupp>/`: `mask.png`, `dark_matched.jpg`,
    /// `fusion.jpg` (utan pull), `pull.jpg` (med pull, före skärpning), `dark_raw.jpg`
    /// (mörkaste exponeringen, registrerad) och `hdr_metrics.json`.
    private static func writeDebug(to dir: URL, group: String, fused: [Float], output: [Float], rendered: [RAWRenderer.RenderedImage],
                                   middleIndex: Int, windowIndex: Int?, width: Int, height: Int, pull: WindowPull.Result?,
                                   frames: [URL], windowSource: URL?, darkShift: CGPoint?, darkShiftRejected: Bool,
                                   residualShift: CGPoint?, seconds: Double) throws {
        let dir = dir.appendingPathComponent(group, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try HDRImageOps.writeJPEG(fused, width: width, height: height, to: dir.appendingPathComponent("fusion.jpg"))
        try HDRImageOps.writeJPEG(output, width: width, height: height, to: dir.appendingPathComponent("pull.jpg"))
        let dark = windowIndex.map { rendered[$0].pixels } ?? rendered[0].pixels
        try HDRImageOps.writeJPEG(dark, width: width, height: height, to: dir.appendingPathComponent("dark_raw.jpg"))
        if let pull {
            try HDRImageOps.writeGrayPNG(pull.mask, to: dir.appendingPathComponent("mask.png"))
            try HDRImageOps.writeJPEG(WindowPull.matchedDark(dark, gain: pull.gain), width: width, height: height,
                                      to: dir.appendingPathComponent("dark_matched.jpg"))
        }
        let m = WindowPullMetrics.measure(output: output, fusion: fused, dark: dark, reference: rendered[middleIndex].pixels,
                                          fullMask: pull?.fullMask, width: width, height: height)
        let report = WindowPullMetrics.Report(
            group: group, frames: frames.map(\.lastPathComponent), reference: frames[middleIndex].lastPathComponent,
            windowSource: windowSource?.lastPathComponent, window: pull?.stats, components: pull?.components, maskFraction: m.maskFraction,
            clippedInMask: m.clipped, structureVsDark: m.structure, lumaSpread: m.spread, chroma: m.chroma,
            haloWidthPx: m.haloWidth, haloAmplitude: m.haloAmplitude, pullHaloWidthPx: m.pullHalo,
            darkShiftPx: darkShift.map { [Double($0.x), Double($0.y)] }, darkShiftRejected: darkShift == nil ? nil : darkShiftRejected,
            residualShiftPx: residualShift.map { Double(($0.x * $0.x + $0.y * $0.y).squareRoot()) },
            residualShiftVector: residualShift.map { [Double($0.x), Double($0.y)] }, seconds: seconds, pullSeconds: pull?.stats.seconds ?? 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: dir.appendingPathComponent("hdr_metrics.json"))
    }
}
