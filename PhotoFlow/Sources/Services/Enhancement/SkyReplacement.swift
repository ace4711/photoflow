import Foundation
import CoreImage

/// "Blå himmel" (Förbättra v4, Mäklarstil): redigeraren byter vit/grå himmel mot blå i
/// samtliga 15 exteriörer i underlaget (tre adresser) — andel blå himmel i övre halvan
/// 0,07–0,55 i leveranserna mot ≈ 0 hos oss. Himlen ersätts med en lodrät gradient med
/// leveransernas uppmätta färger (Lab-median: topp 72/−2/−29, mitt 80/−4/−24, horisont
/// 85/−3/−13), med lite av originalets ljushetsvariation (moln) kvar.
///
/// Himmeln hittas i analysbilden: ljus (luma ≥ 0,82), omättad eller ljusblå, slät, och
/// sammanhängande med bildens överkant; minst `minFraction` av bilden. Används bara i bilder
/// med exteriörvikt ≥ `minExteriorWeight` — ljusa tak i interiörer ser likadana ut.
/// Ren `nonisolated enum`.
nonisolated enum SkyReplacement {
    static let minFraction = 0.06
    static let minExteriorWeight = 0.1
    static let minLuma: Float = 0.82
    static let maxSaturation: Float = 0.16
    static let maxLocalStd: Float = 0.035
    /// Leveransernas himmel (Lab) i topp, mitt och vid horisonten.
    static let top = (l: 72.0, a: -2.0, b: -29.0)
    static let middle = (l: 80.0, a: -4.0, b: -24.0)
    static let horizon = (l: 86.0, a: -3.0, b: -13.0)
    /// Andel av originalets ljushetsvariation (L* kring himlens median) som behålls.
    static let detail = 0.5

    struct Sky: Sendable, Equatable {
        /// Mask (0…1) i analysbildens storlek, rad 0 = överst.
        var mask: [Float]
        var width: Int
        var height: Int
        /// Lägsta himmelsraden (andel av höjden, 95:e percentilen) — där gradienten når horisontfärgen.
        var bottom: Double
        var fraction: Double
        /// Medianluma (gammakodad) i himlen före bytet.
        var medianLuma: Double
    }

    /// Himlen i en gammakodad RGBA-bild, eller `nil` om ingen (tillräckligt stor) hittas.
    static func detect(pixels: [Float], width: Int, height: Int) -> Sky? {
        let n = width * height
        guard n > 0, pixels.count >= n * 4 else { return nil }
        var luma = [Float](repeating: 0, count: n), cand = [Float](repeating: 0, count: n)
        for i in 0..<n { luma[i] = HDRImageOps.luma(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]) }
        // Himlen hör till bildens ljusaste femtedel (annars fångas överexponerade väggar).
        var sample: [Float] = []
        for i in stride(from: 0, to: n, by: 7) { sample.append(luma[i]) }
        let threshold = max(minLuma, HDRImageOps.percentile(sample, 0.8))
        let r = max(1, Int((Double(max(width, height)) / 500).rounded()))
        let plane = ExposureFusion.Plane(width: width, height: height, data: luma)
        let mean = HDRImageOps.boxMean(plane, radius: r)
        let meanSq = HDRImageOps.boxMean(ExposureFusion.Plane(width: width, height: height, data: luma.map { $0 * $0 }), radius: r)
        for i in 0..<n {
            let rr = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            let mx = max(rr, g, b), mn = min(rr, g, b)
            let sat = mx > 1e-4 ? (mx - mn) / mx : 0
            let blueish = b >= rr && b >= g * 0.98 && sat < 0.45
            guard luma[i] >= threshold || (blueish && luma[i] >= 0.55) else { continue }
            guard sat <= maxSaturation || blueish else { continue }
            let sd = max(meanSq.data[i] - mean.data[i] * mean.data[i], 0).squareRoot()
            guard sd <= maxLocalStd else { continue }
            cand[i] = 1
        }
        // Sammanhängande med överkanten.
        let (labels, count) = WindowPull.labelComponents(cand, width: width, height: height)
        guard count > 0 else { return nil }
        // Komponenter som når överkanten längs minst 15 % av bredden och ligger i bildens
        // övre del (90 % av pixlarna ovanför 60 % av höjden) — inte dörrkarmar och väggar.
        var topContact = [Int](repeating: 0, count: count + 1)
        // Översta raderna (bildkanten själv är ofta mörkare efter nedskalningen/linskorrektionen):
        // en kolumn räknas en gång per komponent.
        let band = max(3, height / 60)
        for x in 0..<width {
            var seen = Set<Int32>()
            for y in 0..<band where labels[y * width + x] > 0 && !seen.contains(labels[y * width + x]) {
                seen.insert(labels[y * width + x]); topContact[Int(labels[y * width + x])] += 1
            }
        }
        var compRows = [[Int]](repeating: [], count: count + 1)
        for i in stride(from: 0, to: n, by: 3) where labels[i] > 0 && topContact[Int(labels[i])] > 0 { compRows[Int(labels[i])].append(i / width) }
        var touches = [Bool](repeating: false, count: count + 1)
        for l in 1...count where Double(topContact[l]) >= 0.15 * Double(width) && !compRows[l].isEmpty {
            let sorted = compRows[l].sorted()
            touches[l] = Double(sorted[Int(Double(sorted.count - 1) * 0.9)]) <= 0.6 * Double(height)
        }
        var mask = [Float](repeating: 0, count: n)
        var total = 0
        var rows: [Int] = []
        var skyLumas: [Float] = []
        for i in 0..<n where labels[i] > 0 && touches[Int(labels[i])] {
            mask[i] = 1; total += 1
            if total % 7 == 0 { rows.append(i / width); skyLumas.append(luma[i]) }
        }
        // Kanten ovanför himlen (översta raderna) hör till himlen.
        for x in 0..<width where mask[min(band, height - 1) * width + x] > 0.5 {
            for y in 0..<min(band, height) where mask[y * width + x] < 0.5 { mask[y * width + x] = 1; total += 1 }
        }
        let fraction = Double(total) / Double(n)
        guard fraction >= minFraction, !rows.isEmpty else { return nil }
        // Mjuk kant: guided filter med lumat som guide (kantföljande mot träd och tak).
        let coeffs = HDRImageOps.guidedCoefficients(guide: plane, input: ExposureFusion.Plane(width: width, height: height, data: mask),
                                                    radius: max(2, r * 2), eps: 1e-3)
        var soft = [Float](repeating: 0, count: n)
        for i in 0..<n { soft[i] = min(max(coeffs.a.data[i] * luma[i] + coeffs.b.data[i], 0), 1) }
        // Utanför den hårda masken bara mot ljusa pixlar (annars ljusnar mörka kanter).
        for i in 0..<n where mask[i] < 0.5 && luma[i] < 0.6 { soft[i] = 0 }
        rows.sort()
        let bottom = Double(rows[min(rows.count - 1, Int(Double(rows.count - 1) * 0.95))] + 1) / Double(height)
        return Sky(mask: soft, width: width, height: height, bottom: max(bottom, 0.1), fraction: fraction,
                   medianLuma: Double(HDRImageOps.percentile(skyLumas, 0.5)))
    }

    /// Himmelens färg (gammakodad sRGB) på relativ höjd `t` (0 = överkant, 1 = horisont).
    static func color(at t: Double) -> (Double, Double, Double) {
        let t = min(max(t, 0), 1)
        let (a, b, u) = t < 0.5 ? (top, middle, t / 0.5) : (middle, horizon, (t - 0.5) / 0.5)
        let lab = BrokerLook.Lab(l: a.l + (b.l - a.l) * u, a: a.a + (b.a - a.a) * u, b: a.b + (b.b - a.b) * u)
        let c = lab.toSRGB()
        return (min(max(c.0, 0), 1), min(max(c.1, 0), 1), min(max(c.2, 0), 1))
    }

    /// Lägger himlen i `image` (gammakodad, extent från origo) med `mask` (redan i bildens
    /// geometri, gråskala 0…1). Gradienten följer bildens höjd till `bottom`; molndetalj ur
    /// originalets ljushet kring `medianLuma`.
    static func apply(_ image: CIImage, mask: CIImage, bottom: Double, medianLuma: Double) -> CIImage {
        let extent = image.extent
        let h = extent.height
        // Gradient: CILinearGradient i tre steg (topp → mitt → horisont); CI har y uppåt.
        let topC = color(at: 0), midC = color(at: 0.5), horC = color(at: 1)
        // Färgerna är gammakodade värden och bilden här är gammakodad (i den linjära
        // arbetsrymden) — skicka dem utan färgrymdskonvertering.
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func ciColor(_ c: (Double, Double, Double)) -> CIColor {
            CIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1, colorSpace: linear)
                ?? CIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2))
        }
        let yTop = extent.maxY, yMid = extent.maxY - CGFloat(bottom / 2) * h, yHor = extent.maxY - CGFloat(bottom) * h
        func gradient(_ y0: CGFloat, _ c0: (Double, Double, Double), _ y1: CGFloat, _ c1: (Double, Double, Double)) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: y0), "inputColor0": ciColor(c0),
                "inputPoint1": CIVector(x: 0, y: y1), "inputColor1": ciColor(c1)
            ])!.outputImage!.cropped(to: extent)
        }
        let upper = gradient(yTop, topC, yMid, midC)
        let lower = gradient(yMid, midC, yHor, horC)
        let split = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: extent.minX, y: yMid, width: extent.width, height: extent.maxY - yMid))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent))
        var sky = upper.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: lower, kCIInputMaskImageKey: split])
        // Moln: originalets ljushet kring medianen, `detail` av avvikelsen (additivt i gammakodat).
        let bias = CGFloat(-detail * medianLuma)
        let d = CGFloat(detail)
        let detailImage = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126 * d, y: 0.7152 * d, z: 0.0722 * d, w: 0),
            "inputGVector": CIVector(x: 0.2126 * d, y: 0.7152 * d, z: 0.0722 * d, w: 0),
            "inputBVector": CIVector(x: 0.2126 * d, y: 0.7152 * d, z: 0.0722 * d, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])
        sky = sky.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: detailImage]).cropped(to: extent)
        return sky.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    /// Masken som `CIImage` (gråskala, rad 0 överst → CI:s y uppåt), skalad till `size`.
    static func maskImage(_ sky: Sky, size: CGSize) -> CIImage? {
        var rgba = [Float](repeating: 1, count: sky.width * sky.height * 4)
        for y in 0..<sky.height {
            for x in 0..<sky.width {
                let v = sky.mask[y * sky.width + x]
                let p = (y * sky.width + x) * 4
                rgba[p] = v; rgba[p + 1] = v; rgba[p + 2] = v
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let img = CIImage(bitmapData: data, bytesPerRow: sky.width * 16, size: CGSize(width: sky.width, height: sky.height),
                          format: .RGBAf, colorSpace: nil)
        let sx = size.width / CGFloat(sky.width), sy = size.height / CGFloat(sky.height)
        return img.clampedToExtent().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
