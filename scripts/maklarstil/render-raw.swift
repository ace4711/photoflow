import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
// render-raw <maxDim> <in> <out.tif> [...]
let args = CommandLine.arguments
let maxDim = CGFloat(Double(args[1])!)
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
var i = 2
while i + 1 < args.count {
    let url = URL(fileURLWithPath: args[i]); let out = URL(fileURLWithPath: args[i+1]); i += 2
    guard let f = CIRAWFilter(imageURL: url) else { print("fail", url.path); continue }
    if let v = f.supportedDecoderVersions.last { f.decoderVersion = v }
    f.exposure = 0; f.boostAmount = 1; f.extendedDynamicRangeAmount = 0
    if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = true }
    print(url.lastPathComponent, "lensSupported", f.isLensCorrectionSupported)
    let n = f.nativeSize; let l = max(n.width, n.height)
    if l > maxDim { f.scaleFactor = Float(maxDim / l) }
    guard let img = f.outputImage else { continue }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    try! ctx.writeTIFFRepresentation(of: img, to: out, format: .RGBA16, colorSpace: cs)
}
