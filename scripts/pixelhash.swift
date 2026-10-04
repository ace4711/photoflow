// scripts/pixelhash.swift -- SHA-256 av AVKODADE pixlar (ImageIO), inte av filbytes.
// Läser filsökvägar (en per rad) från stdin och skriver "<hash>\t<sökväg>" per fil.
// Bilden ritas till en 16-bitars RGBX-buffert i sin egen färgrymd (ingen färgkonvertering),
// så två filer med olika komprimering men samma pixlar får samma hash. Används av
// scripts/compare-outputs.sh (kompileras med swiftc vid första körningen).
import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

func pixelHash(path: String) -> String {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "OREAD" }
    let w = image.width, h = image.height
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var buffer = [UInt8](repeating: 0, count: w * h * 8)
    let ok: Bool = buffer.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return "NOCONTEXT" }
    let digest = SHA256.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
    return "\(w)x\(h):\(digest)"
}

var paths: [String] = []
while let line = readLine() { if !line.isEmpty { paths.append(line) } }
var results = [String](repeating: "", count: paths.count)
let lock = NSLock()
let group = DispatchGroup()
let queue = DispatchQueue(label: "hash", attributes: .concurrent)
let limiter = DispatchSemaphore(value: 6)
for (i, path) in paths.enumerated() {
    limiter.wait()
    queue.async(group: group) {
        let hash = pixelHash(path: path)
        lock.lock(); results[i] = hash; lock.unlock()
        limiter.signal()
    }
}
group.wait()
for (i, path) in paths.enumerated() { print("\(results[i])\t\(path)") }
