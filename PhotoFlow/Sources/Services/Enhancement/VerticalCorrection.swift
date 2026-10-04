import Foundation
import CoreImage

/// Rätning av lodlinjer ("Upright: vertikal"): hittar nästan lodräta linjesegment,
/// skattar deras gemensamma flyktpunkt och vrider kameran virtuellt (lutning +
/// rotation, homografi `K·R·K⁻¹`) så att lodlinjerna blir parallella och lodräta.
/// Resultatet beskärs till största rektangeln med bildens proportioner utan tomma hörn.
///
/// Försiktigt: korrigeringen görs bara när minst `minSegments` segment med
/// sammanlagd längd ≥ `minTotalLength` × bildhöjden stämmer med flyktpunkten,
/// lutningen är högst `maxPitchDegrees` och rotationen högst `maxRollDegrees`
/// (större är troligen ett medvetet perspektiv). Under `minCorrectionDegrees`
/// görs inget (märks inte).
///
/// Uppmätt på parade leveranser: redigeraren rätar lodlinjerna (kvarvarande median-
/// lutning 0,47° mot våra 0,73°) och beskär ~2 % per sida.
nonisolated struct PerspectiveCorrection: Codable, Sendable, Equatable {
    /// Virtuell lutning (grader, + = kameran vrids uppåt) och rotation (grader, moturs +).
    var pitchDegrees: Double
    var rollDegrees: Double
    /// Brännvidd i andelar av långsidan.
    var focal: Double
    /// Antal segment som bar skattningen.
    var segments: Int
}

nonisolated enum VerticalCorrection {
    static let maxSegmentAngle = 15.0
    static let minSegmentLength = 0.05
    static let minSegments = 4
    static let minTotalLength = 0.6
    static let maxPitchDegrees = 8.0
    static let maxRollDegrees = 3.0
    static let minCorrectionDegrees = 0.15
    static let inlierDegrees = 1.5

    struct Segment: Equatable {
        /// Ändpunkter i pixlar, rad 0 överst.
        var x0: Double, y0: Double, x1: Double, y1: Double
        var length: Double { hypot(x1 - x0, y1 - y0) }
        /// Vinkel från lodrätt i grader (+ = övre änden åt höger).
        var angleFromVertical: Double {
            let (tx, ty) = y0 < y1 ? (x0 - x1, y0 - y1) : (x1 - x0, y1 - y0)  // från nedre till övre
            return atan2(tx, -ty) * 180 / .pi
        }
    }

    // MARK: - Segment

    /// Nästan lodräta raka kantsegment i en luma-bild (0…1, rad 0 överst): Sobel,
    /// horisontell icke-max-undertryckning, sammanhängande komponenter per
    /// gradienttecken och en linjepassning (PCA) per komponent.
    static func detectSegments(luma: [Float], width w: Int, height h: Int) -> [Segment] {
        guard w > 4, h > 4, luma.count >= w * h else { return [] }
        var gx = [Float](repeating: 0, count: w * h), gy = gx, mag = gx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = luma[i - w - 1], b = luma[i - w], c = luma[i - w + 1]
                let d = luma[i - 1], f = luma[i + 1]
                let g = luma[i + w - 1], hh = luma[i + w], k = luma[i + w + 1]
                let sx = (c + 2 * f + k) - (a + 2 * d + g)
                let sy = (g + 2 * hh + k) - (a + 2 * b + c)
                gx[i] = sx; gy[i] = sy; mag[i] = hypotf(sx, sy)
            }
        }
        let sorted = mag.sorted()
        let threshold = max(0.08, sorted[Int(Double(sorted.count - 1) * 0.90)])
        let tanMax = Float(tan(maxSegmentAngle * .pi / 180))
        // label: 0 = ingen kant, 1 = positiv gx, 2 = negativ gx
        var label = [UInt8](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 2..<(w - 2) {
                let i = y * w + x
                let m = mag[i]
                guard m >= threshold, abs(gy[i]) <= tanMax * abs(gx[i]),
                      m >= mag[i - 1], m >= mag[i + 1] else { continue }
                label[i] = gx[i] > 0 ? 1 : 2
            }
        }
        // Komponenter (samma tecken): grannar inom ±1 kolumn och ±3 rader, så att en sned kant
        // som byter kolumn (och där icke-max-undertryckningen lämnar en lucka) hänger ihop.
        var visited = [Bool](repeating: false, count: w * h)
        var segments: [Segment] = []
        let minPixels = max(8, Int(minSegmentLength * Double(h) * 0.7))
        var stack: [Int] = []
        var pts: [Int] = []
        for start in 0..<(w * h) where label[start] != 0 && !visited[start] {
            let lab = label[start]
            stack.removeAll(keepingCapacity: true); pts.removeAll(keepingCapacity: true)
            stack.append(start); visited[start] = true
            while let i = stack.popLast() {
                pts.append(i)
                let x = i % w, y = i / w
                for dy in -3...3 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let j = ny * w + nx
                        if !visited[j] && label[j] == lab { visited[j] = true; stack.append(j) }
                    }
                }
            }
            guard pts.count >= minPixels else { continue }
            if let s = fitSegment(pts, width: w), s.length >= minSegmentLength * Double(h),
               abs(s.angleFromVertical) <= maxSegmentAngle {
                segments.append(s)
            }
        }
        return segments
    }

    /// Linjepassning (PCA); nil om punkterna inte ligger på en rak linje (std vinkelrätt > 1 px).
    private static func fitSegment(_ pts: [Int], width w: Int) -> Segment? {
        let n = Double(pts.count)
        var mx = 0.0, my = 0.0
        for i in pts { mx += Double(i % w); my += Double(i / w) }
        mx /= n; my /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in pts {
            let dx = Double(i % w) - mx, dy = Double(i / w) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = sqrt(max(tr * tr / 4 - det, 0))
        let l1 = tr / 2 + disc, l2 = tr / 2 - disc
        guard sqrt(max(l2, 0)) <= 1.0 else { return nil }
        // Huvudriktning
        var vx = sxy, vy = l1 - sxx
        if abs(vx) + abs(vy) < 1e-12 { vx = sxx >= syy ? 1 : 0; vy = sxx >= syy ? 0 : 1 }
        let norm = hypot(vx, vy); vx /= norm; vy /= norm
        var lo = Double.infinity, hi = -Double.infinity
        for i in pts {
            let t = (Double(i % w) - mx) * vx + (Double(i / w) - my) * vy
            lo = min(lo, t); hi = max(hi, t)
        }
        return Segment(x0: mx + vx * lo, y0: my + vy * lo, x1: mx + vx * hi, y1: my + vy * hi)
    }

    // MARK: - Skattning

    /// Skattar korrigeringen ur segmenten. `focal` = brännvidd / långsida.
    /// nil = för osäkert, för litet eller för stort.
    static func estimate(segments: [Segment], width w: Int, height h: Int, focal: Double) -> PerspectiveCorrection? {
        let L = Double(max(w, h))
        let cx = Double(w) / 2, cy = Double(h) / 2
        // Linjer i normerade, centrerade koordinater (enhet = långsidan).
        struct Line { var a, b, c, weight: Double; var seg: Segment }
        var lines: [Line] = segments.map { s in
            let p = (x: (s.x0 - cx) / L, y: (s.y0 - cy) / L), q = (x: (s.x1 - cx) / L, y: (s.y1 - cy) / L)
            var a = p.y - q.y, b = q.x - p.x, c = p.x * q.y - q.x * p.y
            let n = hypot(a, b); a /= n; b /= n; c /= n
            return Line(a: a, b: b, c: c, weight: s.length / Double(h), seg: s)
        }
        var vp: (Double, Double, Double)?
        for _ in 0..<4 {
            guard lines.count >= minSegments else { return nil }
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            for l in lines {
                let v = [l.a, l.b, l.c]
                for r in 0..<3 { for c in 0..<3 { m[r][c] += l.weight * v[r] * v[c] } }
            }
            let v = smallestEigenvector(m)
            vp = (v[0], v[1], v[2])
            // Bort med segment vars riktning avviker från riktningen mot flyktpunkten.
            let kept = lines.filter { angularResidual($0.seg, vp: v, cx: cx, cy: cy, scale: L) <= inlierDegrees }
            if kept.count == lines.count { break }
            lines = kept
        }
        guard let (X, Y, W) = vp, lines.count >= minSegments,
              lines.reduce(0, { $0 + $1.weight }) >= minTotalLength else { return nil }
        // Lodriktningen i kameran: K⁻¹·V ∝ (X, Y, W·f).
        var d = (X, Y, W * focal)
        if d.1 < 0 { d = (-d.0, -d.1, -d.2) }  // peka nedåt i bilden (y+)
        let horiz = hypot(d.0, d.1)
        guard horiz > 1e-9 else { return nil }
        // Lutning: vinkeln mellan lodriktningen och bildplanet. Tecken: flyktpunkt ovanför
        // bilden (lodlinjer konvergerar uppåt) = kameran lutad uppåt.
        let pitch = atan2(d.2, horiz) * 180 / .pi
        let roll = atan2(d.0, d.1) * 180 / .pi
        guard abs(pitch) <= maxPitchDegrees, abs(roll) <= maxRollDegrees else { return nil }
        guard abs(pitch) >= minCorrectionDegrees || abs(roll) >= minCorrectionDegrees else { return nil }
        return PerspectiveCorrection(pitchDegrees: pitch, rollDegrees: roll, focal: focal, segments: lines.count)
    }

    /// Vinkel (grader) mellan segmentets riktning och linjen från dess mittpunkt till flyktpunkten.
    private static func angularResidual(_ s: Segment, vp v: [Double], cx: Double, cy: Double, scale L: Double) -> Double {
        let mx = ((s.x0 + s.x1) / 2 - cx) / L, my = ((s.y0 + s.y1) / 2 - cy) / L
        // Riktning mot V (homogen): V.xy − m·V.z
        let tx = v[0] - mx * v[2], ty = v[1] - my * v[2]
        let sx = (s.x1 - s.x0), sy = (s.y1 - s.y0)
        let cross = abs(tx * sy - ty * sx), dot = abs(tx * sx + ty * sy)
        return atan2(cross, dot) * 180 / .pi
    }

    /// Minsta egenvektorn till en symmetrisk 3×3-matris (Jacobi).
    static func smallestEigenvector(_ m: [[Double]]) -> [Double] {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1
            var best = abs(a[0][1])
            if abs(a[0][2]) > best { best = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > best { best = abs(a[1][2]); p = 1; q = 2 }
            if best < 1e-15 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
            let c = 1 / sqrt(t * t + 1), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq
            }
        }
        var idx = 0
        for i in 1..<3 where a[i][i] < a[idx][idx] { idx = i }
        return [v[0][idx], v[1][idx], v[2][idx]]
    }

    // MARK: - Geometri

    /// Homografin (pixlar, rad 0 överst) som rätar lodlinjerna: `K·R·K⁻¹`, där R är den
    /// minsta rotationen som för lodriktningen till bildens y-axel.
    static func homography(_ p: PerspectiveCorrection, width w: Int, height h: Int) -> [Double] {
        let L = Double(max(w, h))
        let f = p.focal * L, cx = Double(w) / 2, cy = Double(h) / 2
        let pitch = p.pitchDegrees * .pi / 180, roll = p.rollDegrees * .pi / 180
        // Lodriktningen i kameran (nedåt i bilden):
        let u = (sin(roll) * cos(pitch), cos(roll) * cos(pitch), sin(pitch))
        let e = (0.0, 1.0, 0.0)
        // Rodrigues: rotation u → e.
        let axis = (u.1 * e.2 - u.2 * e.1, u.2 * e.0 - u.0 * e.2, u.0 * e.1 - u.1 * e.0)
        let s = sqrt(axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2)
        let c = u.0 * e.0 + u.1 * e.1 + u.2 * e.2
        var R: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        if s > 1e-12 {
            let k = (axis.0 / s, axis.1 / s, axis.2 / s)
            let K: [Double] = [0, -k.2, k.1, k.2, 0, -k.0, -k.1, k.0, 0]
            let K2 = mul3(K, K)
            for i in 0..<9 { R[i] += s * K[i] + (1 - c) * K2[i] }
        }
        let Km: [Double] = [f, 0, cx, 0, f, cy, 0, 0, 1]
        let Ki: [Double] = [1 / f, 0, -cx / f, 0, 1 / f, -cy / f, 0, 0, 1]
        return mul3(Km, mul3(R, Ki))
    }

    static func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return r
    }

    static func apply(_ H: [Double], _ x: Double, _ y: Double) -> (Double, Double) {
        let w = H[6] * x + H[7] * y + H[8]
        return ((H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w)
    }

    /// Största axelparallella rektangeln med proportionerna `aspect` (b/h) inuti den konvexa
    /// fyrhörningen `quad` (fyra hörn i ordning). Mitten söks i ett rutnät kring tyngdpunkten.
    static func largestInscribedRect(quad: [(Double, Double)], aspect: Double) -> CGRect {
        guard quad.count == 4 else { return .zero }
        let gx = quad.map(\.0).reduce(0, +) / 4, gy = quad.map(\.1).reduce(0, +) / 4
        let span = max(quad.map(\.0).max()! - quad.map(\.0).min()!, quad.map(\.1).max()! - quad.map(\.1).min()!)
        func inside(_ x: Double, _ y: Double) -> Bool {
            var sign = 0.0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let cr = (b.0 - a.0) * (y - a.1) - (b.1 - a.1) * (x - a.0)
                if abs(cr) < 1e-9 { continue }
                if sign == 0 { sign = cr > 0 ? 1 : -1 } else if (cr > 0 ? 1 : -1) != sign { return false }
            }
            return true
        }
        func fits(_ cx: Double, _ cy: Double, _ hh: Double) -> Bool {
            let hw = hh * aspect
            return inside(cx - hw, cy - hh) && inside(cx + hw, cy - hh) && inside(cx + hw, cy + hh) && inside(cx - hw, cy + hh)
        }
        var best = (h: 0.0, x: gx, y: gy)
        let steps = 8
        for iy in -steps...steps {
            for ix in -steps...steps {
                let cx = gx + Double(ix) / Double(steps) * span * 0.05
                let cy = gy + Double(iy) / Double(steps) * span * 0.05
                guard inside(cx, cy) else { continue }
                var lo = 0.0, hi = span
                if !fits(cx, cy, lo + 1e-6) { continue }
                for _ in 0..<40 {
                    let mid = (lo + hi) / 2
                    if fits(cx, cy, mid) { lo = mid } else { hi = mid }
                }
                if lo > best.h { best = (lo, cx, cy) }
            }
        }
        let hw = best.h * aspect
        return CGRect(x: best.x - hw, y: best.y - best.h, width: 2 * hw, height: 2 * best.h)
    }

    /// Beskärningen (pixlar, rad 0 överst, i den korrigerade bildens koordinater) för en
    /// korrigering av en bild `w × h`: hela pixlar, jämna mått.
    static func cropRect(_ p: PerspectiveCorrection, width w: Int, height h: Int) -> (H: [Double], rect: CGRect) {
        let H = homography(p, width: w, height: h)
        let corners = [(0.0, 0.0), (Double(w), 0), (Double(w), Double(h)), (0, Double(h))].map { apply(H, $0.0, $0.1) }
        let r = largestInscribedRect(quad: corners, aspect: Double(w) / Double(h))
        let x0 = ceil(r.minX), y0 = ceil(r.minY)
        let cw = floor((r.maxX - x0) / 2) * 2, ch = floor((r.maxY - y0) / 2) * 2
        return (H, CGRect(x: x0, y: y0, width: max(cw, 2), height: max(ch, 2)))
    }

    /// Tillämpar korrigeringen på en bild med extent från origo (Core Image, y uppåt).
    /// Resultatets extent börjar i origo. Samma funktion används för fönstermasken.
    static func render(_ image: CIImage, correction p: PerspectiveCorrection, width w: Int, height h: Int) -> CIImage {
        let (H, rect) = cropRect(p, width: w, height: h)
        let Hd = Double(h)
        // Hörn i bildkoordinater (y nedåt) → Core Image (y uppåt).
        func ci(_ pt: (Double, Double)) -> CIVector { CIVector(x: pt.0, y: Hd - pt.1) }
        let tl = apply(H, 0, 0), tr = apply(H, Double(w), 0), br = apply(H, Double(w), Hd), bl = apply(H, 0, Hd)
        let warped = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": ci(tl), "inputTopRight": ci(tr), "inputBottomRight": ci(br), "inputBottomLeft": ci(bl)
        ])
        let ciRect = CGRect(x: rect.minX, y: Hd - rect.maxY, width: rect.width, height: rect.height)
        return warped.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
    }

    /// Hela skattningen för en analysbild (RGBA, gammakodad).
    static func measure(pixels: [Float], width w: Int, height h: Int, focal: Double) -> PerspectiveCorrection? {
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { luma[i] = HDRImageOps.luma(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]) }
        return estimate(segments: detectSegments(luma: luma, width: w, height: h), width: w, height: h, focal: focal)
    }

    /// Brännvidd / långsida ur källans EXIF (35 mm-ekvivalent, annars brännvidd × beskärningsfaktor 1).
    /// Saknas den: 20 mm-ekvivalent (vanligt vidvinkelzoom-läge för interiörer).
    static func focal(fromExifOf url: URL) -> Double {
        let fallback = 20.0 / 36.0
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return fallback }
        if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, f35 > 5 { return f35 / 36 }
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double, f > 5 { return f / 36 }
        return fallback
    }
}
