import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import AVFoundation
import CoreMedia
import CoreVideo

/// Fel från bildspelsrenderingen.
nonisolated enum ReelRenderError: LocalizedError {
    case assetNotFound(id: String)
    case invalidOutput(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .assetNotFound(let id): return "Hittar ingen bildfil för asset \(id)."
        case .invalidOutput(let why): return "Ogiltig exportprofil: \(why)"
        case .writerFailed(let why): return "Videoexporten misslyckades: \(why)"
        }
    }
}

/// Renderar en `ReelSpec` med Core Image: en bildruta i taget (`renderFrame`)
/// och hela filmen till H.264/AAC-mp4 (`export`).
///
/// **Samma kod för preview och slutrender** (plan 6.2): både `export` och en
/// live-förhandsvisning anropar `renderFrame(at:size:)`, som tar *all* geometri
/// och opacitet från `ReelTimeline.state(at:spec:outputSize:)` och bara ritar
/// den. Inga egna formler här utom ren översättning från normaliserade
/// koordinater (y neråt) till Core Images pixelkoordinater (y uppåt).
///
/// **Färg:** specen kräver blandning i sRGB-kodade värden (inte linjärt ljus).
/// `CIContext` skapas därför med `workingColorSpace` = `CGColorSpace.sRGB`
/// (gammakodad, inte `linearSRGB` som är Core Images standard). Indata
/// (t.ex. Display P3-JPEG) färghanteras då till sRGB vid inläsning, och all
/// blandning och suddning sker på sRGB-värden; utdata renderas till sRGB. Testet
/// `crossfadeBlendsInSRGB` verifierar att svart/vitt i mitten av en crossfade
/// blir ~128 (inte ~188 som linjär blandning ger).
///
/// **Bildcache:** varje asset laddas nedskalat med `CGImageSource` (till den
/// storlek som räcker för utsnittet vid högsta zoom i `maxOutputSize`) och
/// cachas per asset-id. Klassen är trådsäker (lås kring cachen; `CIContext` är
/// trådsäker) och kan delas mellan en förhandsvisning och en export. En
/// förhandsvisning i lägre upplösning kan ange `size` per bildruta; bilderna
/// laddas ändå för `maxOutputSize`, så ange samma `maxOutputSize` som i exporten.
nonisolated final class ReelRenderer: @unchecked Sendable {

    let spec: ReelSpec
    let specDirectory: URL
    let maxOutputSize: CGSize
    let context: CIContext

    private let lock = NSLock()
    private var images: [String: CIImage] = [:]
    private var failed: Set<String> = []

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(spec: ReelSpec, specDirectory: URL, maxOutputSize: CGSize) {
        self.spec = spec
        // Alltid en katalog-URL: `URL(fileURLWithPath:relativeTo:)` löser annars en
        // relativ sökväg mot FÖRÄLDERN när basen saknar avslutande snedstreck (t.ex.
        // en FILM-mapp som inte fanns när URL:en byggdes) — bilderna hittades då inte.
        self.specDirectory = URL(fileURLWithPath: specDirectory.path, isDirectory: true)
        self.maxOutputSize = maxOutputSize
        self.context = CIContext(options: [
            .workingColorSpace: Self.sRGB,
            .outputColorSpace: Self.sRGB,
            .cacheIntermediates: false
        ])
    }

    var totalDuration: Double { ReelTimeline.totalDuration(spec) }

    // MARK: - Bildladdning

    /// Filen för en asset: första `local`-källan som finns på disk.
    func fileURL(for asset: ReelSpec.Asset) -> URL? {
        for s in asset.sources where s.kind == .local {
            guard let path = s.path else { continue }
            let url = URL(fileURLWithPath: path, relativeTo: specDirectory).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Längsta sidan (pixlar) som behövs för att utsnittet ska vara skarpt vid
    /// högsta zoom i någon av asset:ens klipp, i `maxOutputSize`. Aldrig mer än originalet.
    func requiredLongEdge(for asset: ReelSpec.Asset) -> Int {
        let imageSize = CGSize(width: asset.width, height: asset.height)
        let frame = maxOutputSize
        let aspect = Double(frame.width / frame.height)
        var scale = 0.0   // bildpixlar per källpixel som behövs
        for clip in spec.timeline where clip.asset == asset.id {
            let z = max(clip.motion.from.zoom, clip.motion.to.zoom, 1)
            let center = CGPoint(x: 0.5, y: 0.5)
            // Cover: utsnittet (z) ska fylla ramen. Gäller även contain-blurs bakgrund (z = 1).
            let cover = ReelTimeline.cropRect(imageSize: imageSize, frameAspect: aspect, center: center, zoom: clip.fit == .cover ? z : 1)
            scale = max(scale, Double(frame.width) / (cover.width * Double(asset.width)),
                        Double(frame.height) / (cover.height * Double(asset.height)))
            if clip.fit == .containBlur {
                let dest = ReelTimeline.containRect(imageSize: imageSize, frameAspect: aspect)
                let crop = ReelTimeline.containCrop(center: center, zoom: z)
                scale = max(scale, Double(dest.width * frame.width) / (crop.width * Double(asset.width)))
            }
        }
        let original = max(asset.width, asset.height)
        guard scale > 0 else { return original }
        return min(original, Int((Double(original) * min(scale, 1)).rounded(.up)) + 2)
    }

    /// Laddar (och cachar) en asset nedskalad. nil om filen saknas eller inte går att läsa.
    func image(for asset: ReelSpec.Asset) -> CIImage? {
        lock.lock()
        if let cached = images[asset.id] { lock.unlock(); return cached }
        if failed.contains(asset.id) { lock.unlock(); return nil }
        lock.unlock()

        var result: CIImage?
        if let url = fileURL(for: asset), let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // rotera enligt EXIF
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: requiredLongEdge(for: asset)
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                result = CIImage(cgImage: cg)
            }
        }

        lock.lock()
        if let result { images[asset.id] = result } else { failed.insert(asset.id) }
        lock.unlock()
        return result
    }

    /// Laddar alla asset som används, och kastar om någon saknas (så att en export
    /// misslyckas direkt och inte efter halva filmen).
    func preload() throws {
        let used = Set(spec.timeline.map(\.asset))
        for asset in spec.assets where used.contains(asset.id) {
            guard image(for: asset) != nil else { throw ReelRenderError.assetNotFound(id: asset.id) }
        }
    }

    // MARK: - Bildruta

    /// Bildrutan vid tid `t` (sekunder) i storleken `size`, som en CIImage med
    /// extent (0, 0, size). Svart där inget lager täcker.
    func renderFrame(at t: Double, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: .black).cropped(to: frame)
        for layer in ReelTimeline.state(at: t, spec: spec, outputSize: size) {
            guard let asset = spec.assets.first(where: { $0.id == layer.asset }),
                  let source = image(for: asset) else { continue }
            var group = draw(layer, source: source, frame: frame)
            if layer.opacity < 1 {
                // Alfa på en helt täckande grupp; vanlig "over" blir (1−a)·under + a·grupp i sRGB.
                group = group.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
                ])
            }
            if layer.offset != .zero {
                // Spec: y neråt. Core Image: y uppåt.
                group = group.transformed(by: CGAffineTransform(
                    translationX: layer.offset.x * size.width, y: -layer.offset.y * size.height))
            }
            canvas = group.composited(over: canvas).cropped(to: frame)
        }
        return canvas
    }

    /// Ritar ett lager (inklusive bakgrund) utan opacitet och förskjutning.
    private func draw(_ layer: ReelTimeline.LayerState, source: CIImage, frame: CGRect) -> CIImage {
        switch layer.fit {
        case .cover:
            return place(source, crop: layer.crop, into: frame)
        case .containBlur:
            var backdrop = CIImage(color: .black).cropped(to: frame)
            if let b = layer.backdrop {
                let cover = place(source, crop: b.crop, into: frame)
                // CIGaussianBlur.inputRadius är standardavvikelsen (sigma) i pixlar.
                backdrop = b.sigma > 0
                    ? cover.clampedToExtent().applyingGaussianBlur(sigma: b.sigma).cropped(to: frame)
                    : cover
            }
            let fg = place(source, crop: layer.crop, into: destinationRect(layer.dest, in: frame))
            return fg.composited(over: backdrop).cropped(to: frame)
        }
    }

    /// Normaliserad ramruta (y neråt) till heltalsrutan i Core Images pixlar (y uppåt).
    /// Kanterna avrundas så att förgrunden inte får halvtäckta kantpixlar.
    private func destinationRect(_ dest: CGRect, in frame: CGRect) -> CGRect {
        let x0 = (dest.minX * frame.width).rounded(), x1 = (dest.maxX * frame.width).rounded()
        let yTop = (dest.minY * frame.height).rounded(), yBottom = (dest.maxY * frame.height).rounded()
        return CGRect(x: x0, y: frame.height - yBottom, width: x1 - x0, height: yBottom - yTop)
    }

    /// Skalar och flyttar bildens utsnitt (normaliserade bildkoordinater, y neråt)
    /// så att det fyller `dest` (pixlar, y uppåt). Kanten klampas före beskärning,
    /// så bråkdelar av pixlar vid utsnittets kant aldrig ger halvtransparenta kanter.
    private func place(_ image: CIImage, crop: CGRect, into dest: CGRect) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        let cx = crop.minX * w, cy = (1 - crop.maxY) * h
        let cw = crop.width * w, ch = crop.height * h
        let t = CGAffineTransform(translationX: -cx - image.extent.minX, y: -cy - image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: dest.width / cw, y: dest.height / ch))
            .concatenating(CGAffineTransform(translationX: dest.minX, y: dest.minY))
        return image.clampedToExtent().transformed(by: t).cropped(to: dest)
    }

    // MARK: - Pixelbuffert

    /// Renderar bildrutan till en pixelbuffert (BGRA) och märker den Rec.709.
    func render(at t: Double, to buffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let image = renderFrame(at: t, size: size)
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.sRGB)
        Self.tagRec709(buffer)
    }

    static func tagRec709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    // MARK: - Export

    static let audioSampleRate = 48_000
    /// Antal bildrutor för en film: ceil(total · fps), med liten tolerans mot flyttalsbrus.
    static func frameCount(total: Double, fps: Int) -> Int {
        max(1, Int((total * Double(fps) - 1e-9).rounded(.up)))
    }

    /// Exporterar specen med profilen `output` till `url` (H.264 High, konstant
    /// fps, tyst AAC 48 kHz stereo, moov först, Rec.709-märkt). Rendrerar bild
    /// *n* vid t = n / fps. Skriver först till en temporär fil bredvid målet och
    /// flyttar den på plats när den är klar; vid fel eller avbrott tas den bort.
    /// `progress` får 0...1 (anropas från en bakgrundstråd).
    @concurrent
    static func export(
        spec: ReelSpec,
        specDirectory: URL,
        output: ReelSpec.Output,
        to url: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let width = output.width, height = output.height, fps = output.fps
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw ReelRenderError.invalidOutput("bredd och höjd måste vara jämna och > 0 (\(width)×\(height))")
        }
        guard fps > 0 else { throw ReelRenderError.invalidOutput("fps måste vara > 0") }
        let total = ReelTimeline.totalDuration(spec)
        guard total > 0 else { throw ReelRenderError.invalidOutput("filmen är tom") }

        let size = CGSize(width: width, height: height)
        let renderer = ReelRenderer(spec: spec, specDirectory: specDirectory, maxOutputSize: size)
        try renderer.preload()

        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp.mp4")

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // moov-atomen först (faststart)

        let bitrate = Int((output.encoding?.bitrateMbps ?? 14) * 1_000_000)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ] as [String: Any]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        // Plattformarna vill ha ett ljudspår: tyst AAC, 48 kHz stereo.
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw ReelRenderError.writerFailed("kunde inte lägga till spår")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        do {
            guard writer.startWriting() else {
                throw ReelRenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
            }
            writer.startSession(atSourceTime: .zero)
            guard let pool = adaptor.pixelBufferPool else {
                throw ReelRenderError.writerFailed("ingen pixelbuffertpool")
            }

            let frames = frameCount(total: total, fps: fps)
            let totalAudioSamples = Int64((Double(frames) / Double(fps) * Double(audioSampleRate)).rounded())
            var audioWritten: Int64 = 0
            var audioFinished = false
            // Skrivaren släpper inte fram nya bildrutor förrän ljudspåret ligger
            // en bit före (sammanflätning); utan försprång hänger exporten.
            let audioLookahead = 2.0

            func checkWriter() throws {
                if writer.status == .failed {
                    throw ReelRenderError.writerFailed(writer.error?.localizedDescription ?? "okänt fel")
                }
            }
            /// Matar ljudspåret fram till `seconds` (så länge ljudingången vill ha mer).
            func pumpAudio(upTo seconds: Double) throws {
                while audioWritten < totalAudioSamples,
                      Double(audioWritten) / Double(audioSampleRate) <= seconds,
                      audioInput.isReadyForMoreMediaData {
                    let n = Int(min(4800, totalAudioSamples - audioWritten))
                    guard let sb = silentAudio(samples: n, startSample: audioWritten) else {
                        throw ReelRenderError.writerFailed("kunde inte skapa tyst ljud")
                    }
                    guard audioInput.append(sb) else { try checkWriter(); throw ReelRenderError.writerFailed("ljud") }
                    audioWritten += Int64(n)
                }
                // Allt ljud är skrivet: avsluta spåret direkt. Annars väntar skrivaren på mer
                // ljud innan den släpper fram fler bildrutor (hängde korta filmer).
                if audioWritten >= totalAudioSamples, !audioFinished {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
            }

            for n in 0..<frames {
                try Task.checkCancellation()
                while !videoInput.isReadyForMoreMediaData {
                    try checkWriter()
                    try pumpAudio(upTo: Double(n) / Double(fps) + audioLookahead)
                    try await Task.sleep(for: .milliseconds(2))
                }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buffer = pb else { throw ReelRenderError.writerFailed("pixelbuffert") }
                renderer.render(at: Double(n) / Double(fps), to: buffer)
                let pts = CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps))
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    try checkWriter()
                    throw ReelRenderError.writerFailed("kunde inte lägga till bildruta \(n)")
                }
                try pumpAudio(upTo: Double(n) / Double(fps) + audioLookahead)
                progress(Double(n + 1) / Double(frames))
            }
            videoInput.markAsFinished()
            while audioWritten < totalAudioSamples {
                try Task.checkCancellation()
                try checkWriter()
                try pumpAudio(upTo: .infinity)
                if audioWritten < totalAudioSamples { try await Task.sleep(for: .milliseconds(2)) }
            }
            try Task.checkCancellation()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw ReelRenderError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            Self.removeTemporaryFiles(for: tmp)
            throw error
        }
    }

    /// Tar bort temporärfilen och AVAssetWriters egna syskonfiler (`<tmp>.sb-…`). De senare kan
    /// dyka upp en kort stund efter `cancelWriting()`, så vi tittar några gånger (högst ~200 ms).
    /// Blockerande väntan med flit: uppgiften är redan avbruten, så `Task.sleep` skulle inte vänta.
    nonisolated static func removeTemporaryFiles(for tmp: URL) {
        let fm = FileManager.default
        let directory = tmp.deletingLastPathComponent()
        let prefix = tmp.lastPathComponent
        var quietRounds = 0
        for _ in 0..<10 where quietRounds < 2 {
            let leftovers = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(prefix) }
            if leftovers.isEmpty {
                quietRounds += 1
            } else {
                quietRounds = 0
                for name in leftovers { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
            }
            usleep(20_000)
        }
    }

    /// `samples` samplar tystnad (16-bitars PCM, stereo, 48 kHz) som börjar vid `startSample`.
    private static func silentAudio(samples: Int, startSample: Int64) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let bytes = samples * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples,
            presentationTimeStamp: CMTime(value: startSample, timescale: CMTimeScale(audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
