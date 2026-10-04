import Foundation

/// Mått för window pull (docs/plan-hdr-fonster.md, avsnitt 3), räknade i felsökningsläget
/// (`photoflow-cli --hdr-debug`) och skrivna som `hdr_metrics.json` per grupp. Varje mått
/// räknas både för resultatet med window pull och för fusionen utan, så att A/B går att
/// jämföra i samma körning.
nonisolated enum WindowPullMetrics {
    typealias Plane = ExposureFusion.Plane

    struct Pair: Codable, Sendable, Equatable {
        var withPull: Double
        var withoutPull: Double
    }

    struct Report: Codable, Sendable {
        var group: String
        var frames: [String]
        var reference: String
        var windowSource: String?
        var window: WindowPull.Stats?
        var components: [WindowPull.ComponentInfo]?
        /// Maskens andel av bilden (m ≥ 0,5).
        var maskFraction: Double
        /// Andel maskpixlar med någon kanal ≥ 0,98 (mål < 2 %).
        var clippedInMask: Pair
        /// Korrelation mellan gradientstyrkan i resultatet och i den mörka ramen inom
        /// masken (mål ≥ 0,8): hur mycket av utsiktens struktur som finns kvar.
        var structureVsDark: Pair
        /// Lumaspridning p95 − p5 inom masken (låg = grå slöja).
        var lumaSpread: Pair
        /// Medelkroma (max − min av kanalerna) inom masken (låg = grått, urtvättat).
        var chroma: Pair
        /// Halobredd i px (full upplösning) utanför maskkanten (mål < 8 px), och största
        /// avvikelse i luma mot referensen i ringarna (mål < 0,03).
        var haloWidthPx: Pair
        var haloAmplitude: Pair
        /// Den mörka ramens uppmätta förskjutning och kvarvarande förskjutning efter
        /// justeringen (> 1 px flaggas), i px vid full upplösning.
        var darkShiftPx: [Double]?
        var darkShiftRejected: Bool?
        var residualShiftPx: Double?
        var residualShiftVector: [Double]?
        var seconds: Double
        var pullSeconds: Double
    }

    /// Räknar måtten på ~`dimension` px.
    static func measure(output: [Float], fusion: [Float], dark: [Float], reference: [Float], fullMask: Plane?,
                        width: Int, height: Int, dimension: Int = 2000)
        -> (maskFraction: Double, clipped: Pair, structure: Pair, spread: Pair, chroma: Pair, haloWidth: Pair, haloAmplitude: Pair) {
        let s = HDRImageOps.scaledSize(width: width, height: height, maxDimension: dimension)
        let factor = Double(max(width, height)) / Double(max(s.width, s.height))
        let outS = HDRImageOps.scaleRGBA(output, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let fusS = HDRImageOps.scaleRGBA(fusion, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let darkS = HDRImageOps.scaleRGBA(dark, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let refS = HDRImageOps.scaleRGBA(reference, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let n = s.width * s.height
        let maskS: [Float] = fullMask.map { HDRImageOps.scale($0, toWidth: s.width, toHeight: s.height).data } ?? [Float](repeating: 0, count: n)
        let inMask = maskS.map { $0 >= 0.5 }
        let maskCount = inMask.filter { $0 }.count
        let zero = Pair(withPull: 0, withoutPull: 0)
        guard maskCount > 0 else { return (0, zero, zero, zero, zero, zero, zero) }

        func clipped(_ img: [Float]) -> Double {
            var c = 0
            for p in 0..<n where inMask[p] && max(img[p * 4], img[p * 4 + 1], img[p * 4 + 2]) >= 0.98 { c += 1 }
            return Double(c) / Double(maskCount)
        }
        func gradient(_ img: [Float]) -> [Float] {
            let lum = HDRImageOps.lumaPlane(img, width: s.width, height: s.height).data
            var g = [Float](repeating: 0, count: n)
            for y in 1..<(s.height - 1) {
                for x in 1..<(s.width - 1) {
                    let p = y * s.width + x
                    let gx = lum[p + 1] - lum[p - 1], gy = lum[p + s.width] - lum[p - s.width]
                    g[p] = sqrtf(gx * gx + gy * gy)
                }
            }
            return g
        }
        // Inre masken (två px in) så att själva fönsterkanten inte dominerar korrelationen.
        let inner = HDRImageOps.morph(Plane(width: s.width, height: s.height, data: inMask.map { $0 ? 1 : 0 }), radius: 2, dilate: false).data
        let darkGrad = gradient(darkS)
        func structure(_ img: [Float]) -> Double {
            let g = gradient(img)
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, k = 0.0
            for p in 0..<n where inner[p] > 0.5 {
                let a = Double(g[p]), b = Double(darkGrad[p])
                sx += a; sy += b; sxx += a * a; syy += b * b; sxy += a * b; k += 1
            }
            guard k > 10 else { return 0 }
            let cov = sxy / k - sx / k * sy / k
            let va = sxx / k - (sx / k) * (sx / k), vb = syy / k - (sy / k) * (sy / k)
            guard va > 1e-12, vb > 1e-12 else { return 0 }
            return cov / sqrt(va * vb)
        }
        func spreadAndChroma(_ img: [Float]) -> (Double, Double) {
            var lumas: [Float] = []
            var chroma = 0.0
            for p in 0..<n where inMask[p] {
                let r = img[p * 4], g = img[p * 4 + 1], b = img[p * 4 + 2]
                lumas.append(HDRImageOps.luma(r, g, b))
                chroma += Double(max(r, g, b) - min(r, g, b))
            }
            return (Double(HDRImageOps.percentile(lumas, 0.95) - HDRImageOps.percentile(lumas, 0.05)), chroma / Double(lumas.count))
        }
        // Halo: medelavvikelse i luma mot referensen i ringar utanför masken (avstånd 1…40 px
        // på mätupplösningen), relativt baslinjen i ringarna 28…40. Klippta referenspixlar räknas inte.
        var rings: [[Int]] = []
        var current = Plane(width: s.width, height: s.height, data: inMask.map { $0 ? 1 : 0 })
        for _ in 0..<40 {
            let next = HDRImageOps.morph(current, radius: 1, dilate: true)
            var ring: [Int] = []
            for p in 0..<n where next.data[p] > 0.5 && current.data[p] < 0.5 {
                if max(refS[p * 4], refS[p * 4 + 1], refS[p * 4 + 2]) < 0.95 { ring.append(p) }
            }
            rings.append(ring)
            current = next
        }
        let refLum = HDRImageOps.lumaPlane(refS, width: s.width, height: s.height).data
        func halo(_ img: [Float]) -> (width: Double, amplitude: Double) {
            let lum = HDRImageOps.lumaPlane(img, width: s.width, height: s.height).data
            let diffs: [Double?] = rings.map { ring in
                guard ring.count >= 20 else { return nil }
                return ring.reduce(0.0) { $0 + Double(lum[$1] - refLum[$1]) } / Double(ring.count)
            }
            let base = diffs[27...].compactMap { $0 }
            guard !base.isEmpty else { return (0, 0) }
            let baseline = base.reduce(0, +) / Double(base.count)
            var widthRings = 0
            var amplitude = 0.0
            for (i, d) in diffs.prefix(27).enumerated() {
                guard let d else { continue }
                let dev = abs(d - baseline)
                amplitude = max(amplitude, dev)
                if dev > 0.03 { widthRings = i + 1 }
            }
            return (Double(widthRings) * factor, amplitude)
        }
        let (spreadOut, chromaOut) = spreadAndChroma(outS)
        let (spreadFus, chromaFus) = spreadAndChroma(fusS)
        let haloOut = halo(outS), haloFus = halo(fusS)
        return (Double(maskCount) / Double(n),
                Pair(withPull: clipped(outS), withoutPull: clipped(fusS)),
                Pair(withPull: structure(outS), withoutPull: structure(fusS)),
                Pair(withPull: spreadOut, withoutPull: spreadFus),
                Pair(withPull: chromaOut, withoutPull: chromaFus),
                Pair(withPull: haloOut.width, withoutPull: haloFus.width),
                Pair(withPull: haloOut.amplitude, withoutPull: haloFus.amplitude))
    }
}
