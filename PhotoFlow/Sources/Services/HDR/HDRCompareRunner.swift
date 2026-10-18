import Foundation
import CoreImage

/// Cache för måtten (`metrics.json` bredvid manifestet): per grupp och variant, plus en signatur per
/// grupp (sökvägar och ändringstider) så att bara ändrade grupper räknas om.
nonisolated struct HDRCompareMetricsFile: Codable, Equatable, Sendable {
    var version = 1
    var groups: [String: [String: VariantResult]] = [:]
    var signatures: [String: String] = [:]

    struct VariantResult: Codable, Equatable, Sendable {
        var metrics: HDRCompareMetrics.VariantMetrics
        /// ΔE2000 mot lr-auto resp. fotografens referens (efter registrering). Nil för varianten själv
        /// och när registreringen är dålig.
        var vsLR: HDRCompareMetrics.PairMetrics?
        var vsRef: HDRCompareMetrics.PairMetrics?
    }

    static func url(forManifest manifest: URL) -> URL {
        manifest.deletingLastPathComponent().appendingPathComponent("metrics.json")
    }

    static func load(forManifest manifest: URL) -> HDRCompareMetricsFile? {
        guard let data = try? Data(contentsOf: url(forManifest: manifest)) else { return nil }
        return try? JSONDecoder().decode(HDRCompareMetricsFile.self, from: data)
    }

    func save(forManifest manifest: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(forManifest: manifest), options: .atomic)
    }
}

/// Läser bilderna i ett manifest, kör `HDRCompareMetrics` och fyller `metrics.json`.
nonisolated enum HDRCompareRunner {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Läser en bild (TIFF/JPEG/PNG/DNG) nedskalad till `maxDimension` som sRGB-gamma-RGBA-float.
    static func loadImage(_ url: URL, maxDimension: Int = HDRCompareMetrics.workingDimension) -> HDRCompareMetrics.Image? {
        guard FileManager.default.fileExists(atPath: url.path),
              var ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let extent = ci.extent
        guard extent.width >= 1, extent.height >= 1, extent.isInfinite == false else { return nil }
        let scale = min(1.0, Double(maxDimension) / Double(max(extent.width, extent.height)))
        if scale < 1 {
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let bounds = ci.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [Float](repeating: 1, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            context.render(ci, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        for p in 0..<(w * h) { pixels[p * 4 + 3] = 1 }
        return HDRCompareMetrics.Image(width: w, height: h, pixels: pixels)
    }

    static func resolve(_ path: String, base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    /// Ändras när en variantfil byts ut eller ramlistan ändras.
    static func signature(of group: HDRCompareManifest.Group, base: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = group.frames.map { $0.file }
        for (id, path) in group.allImages.sorted(by: { $0.key < $1.key }) {
            let attrs = try? fm.attributesOfItem(atPath: resolve(path, base: base).path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            parts.append("\(id)=\(path)@\(Int(mtime)):\(size)")
        }
        return parts.joined(separator: "|")
    }

    /// Referensramen (medianexponering) och den mörkaste ramen, renderade av oss. Nil per ram om NEF:erna saknas.
    static func loadFrames(of group: HDRCompareManifest.Group, base: URL) -> (reference: HDRCompareMetrics.Image?, dark: HDRCompareMetrics.Image?) {
        guard !group.frames.isEmpty else { return (nil, nil) }
        let sorted = group.frames.sorted { ($0.exposureSeconds ?? 0) < ($1.exposureSeconds ?? 0) }
        func render(_ f: HDRCompareManifest.Frame) -> HDRCompareMetrics.Image? {
            let url = resolve(f.file, base: base)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? RAWRenderer.render(url: url, whiteBalance: nil, maxDimension: HDRCompareMetrics.workingDimension)
        }
        let median = sorted[sorted.count / 2]
        let ref = render(median)
        let dark = sorted.count > 1 ? render(sorted[0]) : nil
        return (ref, dark)
    }

    /// Mått för alla varianter i en grupp. Utan ramar används lr-auto (annars första varianten) som referens
    /// och fönstermåtten utgår.
    static func computeGroup(_ group: HDRCompareManifest.Group, base: URL) -> [String: HDRCompareMetricsFile.VariantResult] {
        let images = group.allImages
        var loaded: [String: HDRCompareMetrics.Image] = [:]
        for (id, path) in images {
            if let img = loadImage(resolve(path, base: base)) { loaded[id] = img }
        }
        guard !loaded.isEmpty else { return [:] }

        let frames = loadFrames(of: group, base: base)
        var reference = frames.reference
        var dark = frames.dark
        if reference == nil {
            let fallbackID = loaded["lr-auto"] != nil ? "lr-auto" : loaded.keys.sorted()[0]
            reference = loaded[fallbackID]
            dark = nil
        }
        guard let reference else { return [:] }
        let mask = dark.map { HDRCompareMetrics.windowMask(reference: reference, dark: $0) }

        var registered: [String: HDRCompareMetrics.Registered] = [:]
        for (id, img) in loaded { registered[id] = HDRCompareMetrics.registered(img, to: reference) }

        func usable(_ id: String) -> HDRCompareMetrics.Registered? {
            guard let r = registered[id], r.registration?.ok == true else { return nil }
            return r
        }
        var out: [String: HDRCompareMetricsFile.VariantResult] = [:]
        for (id, reg) in registered {
            let metrics = HDRCompareMetrics.analyze(reg, reference: reference, dark: dark, mask: mask)
            var vsLR: HDRCompareMetrics.PairMetrics?, vsRef: HDRCompareMetrics.PairMetrics?
            if let me = usable(id) {
                if id != "lr-auto", let lr = usable("lr-auto") { vsLR = HDRCompareMetrics.pairMetrics(me, lr, windowMask: mask) }
                if id != HDRCompareManifest.Group.referenceID, let ref = usable(HDRCompareManifest.Group.referenceID) {
                    vsRef = HDRCompareMetrics.pairMetrics(me, ref, windowMask: mask)
                }
            }
            out[id] = HDRCompareMetricsFile.VariantResult(metrics: metrics, vsLR: vsLR, vsRef: vsRef)
        }
        return out
    }

    /// Räknar om de grupper vars signatur ändrats (alla vid `force`) och sparar `metrics.json` efter varje grupp.
    @concurrent
    static func compute(manifest: HDRCompareManifest, manifestURL: URL, force: Bool = false,
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> HDRCompareMetricsFile {
        let base = manifestURL.deletingLastPathComponent()
        var file = (force ? nil : HDRCompareMetricsFile.load(forManifest: manifestURL)) ?? HDRCompareMetricsFile()
        let current = Set(manifest.groups.map(\.id))
        file.groups = file.groups.filter { current.contains($0.key) }
        file.signatures = file.signatures.filter { current.contains($0.key) }
        for (i, group) in manifest.groups.enumerated() {
            if Task.isCancelled { break }
            progress(i, manifest.groups.count)
            let sig = signature(of: group, base: base)
            if file.signatures[group.id] == sig, file.groups[group.id] != nil { continue }
            let result = computeGroup(group, base: base)
            file.groups[group.id] = result
            file.signatures[group.id] = sig
            try? file.save(forManifest: manifestURL)
        }
        progress(manifest.groups.count, manifest.groups.count)
        return file
    }
}
