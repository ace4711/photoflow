import Foundation

/// "Radians" (HDREngine v7): alla exponeringar slås ihop till en **scenlinjär radiansbild** —
/// som Lightrooms HDR-sammanslagning — i stället för att klippa och klistra fönster med masker.
///
/// - Ramarna är renderade linjärt (ingen RAW-kurva, ingen skuggförskjutning, gemensam vitbalans)
///   och registrerade mot referensen. Exponeringskvoterna mäts ur bilderna (median av
///   luminanskvoten där båda ramarna är välexponerade, kedjat mellan grannramar) — EXIF-tiderna
///   är ungefärliga.
/// - Per pixel: viktat medel av `värde / kvot` över ramarna. Vikten är en "hatt" på pixelns
///   max-kanal (0 i klippta och nästan svarta värden, mjuka övergångar) gånger kvoten — en ljusare
///   ram har bättre signal/brus, så skuggorna kommer i praktiken från de ljusa ramarna och
///   fönstren från de mörka, utan sömmar eftersom alla ramar är fysikaliskt samma ljus.
/// - **Spökskydd**: rörliga partier (löv, gardiner) ger olika värden i olika ramar efter
///   exponeringsnormaliseringen. Ett ankare väljs per pixel — referensen där den är välexponerad,
///   annars den närmaste välexponerade ramen — och varje ram vägs ned där den skiljer sig från
///   ankaret (> `ghostLowEV`, helt vid `ghostHighEV`). Konsistenskartan räknas på en nedskalad
///   bild (brus utjämnat), krymps lite (spökets kant tas med) och jämnas ut mjukt.
///
/// Ren `nonisolated enum` utan tillstånd (testas med syntetiska bilder).
nonisolated enum RadianceMerge {
    typealias Plane = ExposureFusion.Plane

    struct Options: Sendable, Equatable {
        /// Hattens övre kant (max-kanal, linjärt i ramens skala): full vikt till `clipStart`, 0 vid `clipEnd`.
        var clipStart: Float = 0.80
        var clipEnd: Float = 0.95
        /// Hattens nedre kant: 0 vid `darkStart`, full vikt från `darkEnd`.
        var darkStart: Float = 0.0005
        var darkEnd: Float = 0.004
        /// Spökskydd: skillnad mot ankaret (log2, nedskalad luminans) där vikten börjar sjunka / är 0.
        var ghostLowEV: Float = 0.30
        var ghostHighEV: Float = 0.60
        var ghostDimension = 1000
        /// Spökkartans krympning (spökets kant) och utjämning, px på `ghostDimension`.
        var ghostErode = 2
        var ghostBlur = 3

        init() {}
    }

    struct Result {
        /// RGBA linjärt i referensramens skala (alfa 1).
        var pixels: [Float]
        /// Exponeringskvot per ram (sorterade mörkast först) relativt referensen.
        var ratios: [Float]
        /// Andel av pixlarna där minst en ram vägdes ned av spökskyddet.
        var ghostFraction: Double
        /// Spökkarta (0 = konsistent, 1 = spöke, max över ramarna) på `ghostDimension` — felsökning.
        var ghostMap: Plane?
    }

    /// Kör `body` med delbara pekare till alla `arrays` (nästlade `withUnsafeBufferPointer`, så att
    /// pekarna är giltiga under hela anropet) — snabb åtkomst i pixelslingan utan arrayer av arrayer.
    static func withPointers(_ arrays: [[Float]], from index: Int = 0, collected: [HDRImageOps.Shared] = [],
                             _ body: ([HDRImageOps.Shared]) -> Void) {
        guard index < arrays.count else { body(collected); return }
        arrays[index].withUnsafeBufferPointer { buf in
            withPointers(arrays, from: index + 1, collected: collected + [HDRImageOps.Shared(buf)], body)
        }
    }

    /// Hattvikten för en pixels max-kanal.
    @inline(__always) static func hat(_ m: Float, options: Options) -> Float {
        if m >= options.clipEnd || m <= options.darkStart { return 0 }
        var w: Float = 1
        if m > options.clipStart {
            let t = (options.clipEnd - m) / (options.clipEnd - options.clipStart)
            w = t * t * (3 - 2 * t)
        }
        if m < options.darkEnd {
            let t = (m - options.darkStart) / (options.darkEnd - options.darkStart)
            w *= t * t * (3 - 2 * t)
        }
        return w
    }

    /// Ljuskvoten ljus/mörk ram (linjärt): median av luminanskvoten där båda är välexponerade.
    /// `nil` om underlaget är för litet.
    static func exposureRatio(bright: [Float], dark: [Float], count: Int, options: Options) -> Float? {
        let step = max(1, count / 300_000)
        var ratios: [Float] = []
        var i = 0
        while i < count {
            let p = i * 4
            let bMax = max(bright[p], bright[p + 1], bright[p + 2]), dMax = max(dark[p], dark[p + 1], dark[p + 2])
            if bMax < options.clipStart * 0.9, dMax > options.darkEnd * 4, dMax < options.clipStart {
                let lb = HDRImageOps.luma(bright[p], bright[p + 1], bright[p + 2])
                let ld = HDRImageOps.luma(dark[p], dark[p + 1], dark[p + 2])
                if ld > 1e-6 { ratios.append(lb / ld) }
            }
            i += step
        }
        guard ratios.count >= 100 else { return nil }
        return max(HDRImageOps.percentile(ratios, 0.5), 1e-3)
    }

    /// Kvoterna relativt referensen (`ratios[reference] == 1`), kedjade mellan grannramar.
    /// `fallback[i]` (t.ex. ur EXIF-tiderna, relativt referensen) används där mätningen saknas.
    static func relativeExposures(images: [[Float]], count: Int, reference: Int, fallback: [Float]?, options: Options) -> [Float] {
        let n = images.count
        var ratios = [Float](repeating: 1, count: n)
        guard n > 1 else { return ratios }
        // Grannkvot k[i] = ram i+1 / ram i.
        var step = [Float](repeating: 2, count: n - 1)
        for i in 0..<(n - 1) {
            if let r = exposureRatio(bright: images[i + 1], dark: images[i], count: count, options: options) {
                step[i] = r
            } else if let fallback, fallback[i] > 0 {
                step[i] = fallback[i + 1] / fallback[i]
            }
        }
        var acc: Float = 1
        for i in stride(from: reference - 1, through: 0, by: -1) {
            acc /= step[i]
            ratios[i] = acc
        }
        acc = 1
        for i in (reference + 1)..<max(reference + 1, n) {
            acc *= step[i - 1]
            ratios[i] = acc
        }
        return ratios
    }

    /// - Parameters:
    ///   - images: registrerade exponeringar (RGBA, linjära, ramens skala), sorterade mörkast först.
    ///   - reference: referensens index (medianexponeringen).
    ///   - fallbackExposures: exponeringstider (samma ordning) om kvoterna inte går att mäta.
    static func merge(images: [[Float]], width: Int, height: Int, reference: Int,
                      fallbackExposures: [Float]? = nil, options: Options = Options(),
                      keepGhostMap: Bool = false) -> Result {
        let count = width * height
        guard images.count > 1 else {
            return Result(pixels: images.first ?? [], ratios: [1], ghostFraction: 0, ghostMap: nil)
        }
        let n = images.count
        let ref = min(max(reference, 0), n - 1)
        let fallback = fallbackExposures.map { e in e.map { $0 / max(e[ref], 1e-9) } }
        let ratios = relativeExposures(images: images, count: count, reference: ref, fallback: fallback, options: options)

        // 1. Spökskydd på nedskalad luminans: ankare = referensen där den är välexponerad, annars
        //    närmaste välexponerade ram (mot mörkare om referensen är klippt, mot ljusare om den är
        //    för mörk). Konsistens per ram mot ankaret.
        let s = HDRImageOps.scaledSize(width: width, height: height, maxDimension: options.ghostDimension)
        let sc = s.width * s.height
        var smallLum: [[Float]] = [], smallMax: [[Float]] = []
        for img in images {
            let small = HDRImageOps.scaleRGBA(img, width: width, height: height, toWidth: s.width, toHeight: s.height)
            var lum = [Float](repeating: 0, count: sc), mx = [Float](repeating: 0, count: sc)
            for i in 0..<sc {
                lum[i] = max(HDRImageOps.luma(small[i * 4], small[i * 4 + 1], small[i * 4 + 2]), 0)
                mx[i] = max(small[i * 4], small[i * 4 + 1], small[i * 4 + 2])
            }
            smallLum.append(lum); smallMax.append(mx)
        }
        func wellExposed(_ m: Float) -> Bool { m < options.clipStart && m > options.darkEnd * 2 }
        var anchorIndex = [Int](repeating: ref, count: sc)
        for i in 0..<sc {
            if wellExposed(smallMax[ref][i]) { continue }
            let clipped = smallMax[ref][i] >= options.clipStart
            var j = ref
            var found = -1
            while true {
                j += clipped ? -1 : 1
                guard j >= 0, j < n else { break }
                if wellExposed(smallMax[j][i]) { found = j; break }
            }
            anchorIndex[i] = found >= 0 ? found : (clipped ? 0 : n - 1)
        }
        var ghost = [[Float]](repeating: [], count: n)
        var ghostAny = [Float](repeating: 0, count: sc)
        let span = max(options.ghostHighEV - options.ghostLowEV, 1e-3)
        for f in 0..<n {
            var g = [Float](repeating: 0, count: sc)
            for i in 0..<sc {
                let a = anchorIndex[i]
                guard a != f, smallMax[f][i] < options.clipEnd, smallMax[f][i] > options.darkStart else { continue }
                let va = smallLum[a][i] / ratios[a], vf = smallLum[f][i] / ratios[f]
                guard va > 1e-7, vf > 1e-7 else { continue }
                // Mörka värden är brusigare: tröskeln växer när ramens värde närmar sig brusgolvet.
                let noise = min(0.5, 0.004 / max(smallLum[f][i], 1e-4))
                let d = abs(log2f(vf / va))
                g[i] = min(max((d - options.ghostLowEV - noise) / span, 0), 1)
            }
            // Spökets kant tas med (dilatera spöket = krymp konsistensen), mjuk övergång.
            var plane = HDRImageOps.morph(Plane(width: s.width, height: s.height, data: g), radius: options.ghostErode, dilate: true)
            plane = HDRImageOps.boxMean(HDRImageOps.boxMean(plane, radius: options.ghostBlur), radius: options.ghostBlur)
            ghost[f] = plane.data
            for i in 0..<sc where plane.data[i] > ghostAny[i] { ghostAny[i] = plane.data[i] }
        }
        var ghostCount = 0
        for v in ghostAny where v > 0.5 { ghostCount += 1 }

        // Spökvikterna samplas bilinjärt ur de nedskalade kartorna direkt i slingan (ingen
        // fullupplöst karta per ram — sparar ~100 MB per ram vid 6000 px); ankaret närmaste granne.
        let sx = Float(s.width) / Float(width), sy = Float(s.height) / Float(height)
        let sw = s.width, sh = s.height

        // 2. Sammanslagning per pixel.
        var out = [Float](repeating: 1, count: count * 4)
        let inv = ratios.map { 1 / $0 }
        withPointers(images) { imgs in
          withPointers(ghost) { ghosts in
            out.withUnsafeMutableBufferPointer { oBuf in
            let o = HDRImageOps.Shared(oBuf)
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let ys = min(Int(Float(y) * sy), sh - 1)
                let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
                let y0 = min(Int(fy), sh - 1), y1 = min(y0 + 1, sh - 1)
                let ty = fy - Float(y0)
                for x in 0..<width {
                    let p = y * width + x
                    let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                    let x0 = min(Int(fx), sw - 1), x1 = min(x0 + 1, sw - 1)
                    let tx = fx - Float(x0)
                    let i00 = y0 * sw + x0, i01 = y0 * sw + x1, i10 = y1 * sw + x0, i11 = y1 * sw + x1
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0, sum: Float = 0
                    for f in 0..<n {
                        let img = imgs[f]
                        let r = img[p * 4], g = img[p * 4 + 1], b = img[p * 4 + 2]
                        let gm = ghosts[f]
                        let ghostValue = (gm[i00] * (1 - tx) + gm[i01] * tx) * (1 - ty) + (gm[i10] * (1 - tx) + gm[i11] * tx) * ty
                        let w = hat(max(r, g, b), options: options) * ratios[f] * (1 - ghostValue)
                        guard w > 1e-6 else { continue }
                        sr += w * r * inv[f]; sg += w * g * inv[f]; sb += w * b * inv[f]; sum += w
                    }
                    if sum > 1e-6 {
                        o[p * 4] = sr / sum; o[p * 4 + 1] = sg / sum; o[p * 4 + 2] = sb / sum
                    } else {
                        // Ingen användbar ram (klippt i alla eller svart i alla): ankarets värde.
                        let a = anchorIndex[ys * sw + min(Int(Float(x) * sx), sw - 1)]
                        let img = imgs[a]
                        o[p * 4] = img[p * 4] * inv[a]; o[p * 4 + 1] = img[p * 4 + 1] * inv[a]; o[p * 4 + 2] = img[p * 4 + 2] * inv[a]
                    }
                }
            }
            }
          }
        }
        return Result(pixels: out, ratios: ratios, ghostFraction: Double(ghostCount) / Double(max(sc, 1)),
                      ghostMap: keepGhostMap ? Plane(width: s.width, height: s.height, data: ghostAny) : nil)
    }
}
