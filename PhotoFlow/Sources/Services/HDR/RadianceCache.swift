import Foundation

/// Radianscache för utvärderingen av tonsättningen (docs/plan-hdr-v8-framkallning.md): den
/// scenlinjära radiansbilden efter `RadianceMerge` sparas rått (RGBA Float32) så att en ny
/// tonsättning kan provas utan att ramarna renderas och slås ihop igen. Används bara av CLI:t
/// (`photoflow-cli hdr --radiance-cache`), aldrig av appens pipeline.
///
/// Format: `PFRAD1` + två nollbyte, bredd, höjd, antal kvoter (UInt32 LE), spökandel (Float64), kvoterna
/// (Float32), därefter pixlarna (Float32 LE, RGBA, radvis).
nonisolated enum RadianceCache {
    struct Entry {
        var width: Int
        var height: Int
        var pixels: [Float]
        var ratios: [Float]
        var ghostFraction: Double
    }

    private static let magic = Array("PFRAD1\0\0".utf8)

    static func write(_ pixels: [Float], width: Int, height: Int, ratios: [Float], ghostFraction: Double, to url: URL) throws {
        var data = Data(magic)
        for v in [UInt32(width), UInt32(height), UInt32(ratios.count)] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        withUnsafeBytes(of: ghostFraction.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        ratios.withUnsafeBytes { data.append(contentsOf: $0) }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= magic.count + 20,
              Array(data.prefix(magic.count)) == magic else { return nil }
        func u32(_ offset: Int) -> Int {
            Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
        }
        let width = u32(8), height = u32(12), count = u32(16)
        let ghost = Double(bitPattern: UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt64.self) }))
        let ratioStart = 28, pixelStart = ratioStart + count * 4
        guard width > 0, height > 0, data.count == pixelStart + width * height * 16 else { return nil }
        var ratios = [Float](repeating: 0, count: count)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        ratios.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: ratioStart..<pixelStart) }
        pixels.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: pixelStart..<data.count) }
        return Entry(width: width, height: height, pixels: pixels, ratios: ratios, ghostFraction: ghost)
    }
}
