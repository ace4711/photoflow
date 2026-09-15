import Foundation
import Vision
import CoreGraphics
import ImageIO
import Accelerate

/// Vision-baserat beslutsstöd för gallring (Fas 3b): per-bild estetik/kvalitet,
/// horisontlutning, en egen skärpemetrik, och kluster av nästan-dubbletter via
/// Vision feature prints. Körs som en del av `.aiTagging`-steget i pipelinen
/// (se `PipelineRunner+AITagging.swift`) och resultaten persisteras i
/// `photo_quality.json` i outputDir så analysen inte körs om i onödan.
///
/// `nonisolated enum` — samma mönster som `HDREngine`/`RAWRenderer`/
/// `ExposureFusion` (Fas 3a): ingen instansstatus att skydda, och att köra
/// utanför `MainActor` (projektets `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`)
/// är avgörande här eftersom `computeSharpness` gör riktigt CPU-arbete
/// (CGContext-ritning + vImage-faltning) som annars skulle seriealiseras på
/// huvudtråden eller en enda actor-executor istället för att köra parallellt
/// över de ~6 samtidiga TaskGroup-jobben i `analyzeSession`.
nonisolated enum PhotoQualityService {

    // MARK: - Persisterat resultat per bild

    struct Result: Codable, Sendable, Equatable {
        /// 0...1, normaliserad från Vision's `overallScore` (-1...1) — se
        /// `normalizedQualityScore`.
        var qualityScore: Double?
        /// Vision's signal för "nyttobild" (kvitto/dokument/skärmdump-liknande)
        /// snarare än ett minnesvärt foto — föreslås avvisad i "Föreslå gallring".
        var isUtility: Bool
        /// Lutning i grader, normaliserad till (-90, 90] — se `tiltDegrees`.
        /// `nil` när Vision inte kunde detektera en horisontlinje alls (vanligt
        /// för närbilder/interiörer utan tydlig horisont — det är inte ett fel).
        var horizonAngleDegrees: Double?
        /// Varians av en 3x3 Laplace-faltning på en nedskalad gråskalebild.
        /// Endast meningsfull relativt andra bilder i samma session/
        /// dubblettgrupp, inte som ett absolut mått.
        var sharpness: Double?
        /// Index för den kluster-grupp (om någon) denna bild anses vara en
        /// nästan-dubblett av andra bilder i, se `clusterDuplicates`.
        var duplicateGroupID: Int?
    }

    struct PersistedFile: Codable {
        var version: Int
        var duplicateThreshold: Double
        var results: [String: Result]
    }

    /// Bump om beräkningslogiken (tröskelvärde, skärpemetrik, etc) ändras på
    /// ett sätt som gör en gammal `photo_quality.json` otillförlitlig — filer
    /// utan matchande version behandlas som saknade och analysen körs om.
    static let currentVersion = 1

    /// Kalibrerad mot riktiga bracket-sessionens previews (se FORBATTRINGAR.md,
    /// Fas 3b), med single-linkage-klustringens "chaining"-risk i åtanke — inte
    /// bara enkla parvisa percentiler:
    ///
    /// Ett första försök med 0.15 (baserat bara på percentiler: samma-motiv-par
    /// mätte <0.01, olika rum/motiv låg på 0.27+ vid 10:e percentilen) visade
    /// sig i praktiken kedja ihop *olika* vykomponeringar i samma rum via en
    /// kedja av mellanliggande, delvis lika bilder (verifierat visuellt: två
    /// tydligt olika vyer av samma vardagsrum hamnade i samma "dubblett"-kluster
    /// via 3-4 mellansteg). 0.05 valdes istället efter att ha jämfört
    /// klustringsresultat vid flera trösklar (0.02...0.15) och visuellt granskat
    /// klustrens ändpunkter: vid 0.05 innehöll varje kluster uteslutande
    /// verifierat identiska kompositioner (bilder som fotografen av misstag
    /// bracketade två gånger i rad), utan att dra in andra vyer i samma rum.
    static let duplicateDistanceThreshold = 0.05

    // MARK: - Ren logik (testbar utan Vision/bilder)

    /// Klustrar index i dubblettgrupper från en parvis avståndsfunktion, med
    /// single-linkage-klustring under `threshold` (union-find): om a-b är
    /// nära och b-c är nära hamnar a/b/c i samma grupp även om a-c aldrig
    /// mättes eller själv ligger precis över tröskeln.
    ///
    /// `excludePair` låter anroparen hålla par som redan hanteras någon
    /// annanstans (t.ex. exponeringar inom samma HDR-bracket-grupp — de är
    /// avsiktligt flera exponeringar, inte oavsiktliga upprepningar, och
    /// hanteras redan av bracket-granskningen) helt utanför klustringen.
    ///
    /// Returnerar en grupp-id per index (`nil` om bilden inte tillhör någon
    /// dubblettgrupp). Grupper med bara en medlem räknas inte som dubbletter.
    static func clusterDuplicates(
        count: Int,
        threshold: Double,
        distance: (Int, Int) -> Double?,
        excludePair: (Int, Int) -> Bool = { _, _ in false }
    ) -> [Int?] {
        guard count > 0 else { return [] }
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        for i in 0..<count {
            for j in (i + 1)..<count {
                if excludePair(i, j) { continue }
                guard let d = distance(i, j), d < threshold else { continue }
                union(i, j)
            }
        }

        var rootMemberCount: [Int: Int] = [:]
        for i in 0..<count { rootMemberCount[find(i), default: 0] += 1 }

        var rootToGroupID: [Int: Int] = [:]
        var nextID = 0
        var groupIDs = [Int?](repeating: nil, count: count)
        for i in 0..<count {
            let root = find(i)
            guard rootMemberCount[root, default: 0] > 1 else { continue }
            if rootToGroupID[root] == nil {
                rootToGroupID[root] = nextID
                nextID += 1
            }
            groupIDs[i] = rootToGroupID[root]
        }
        return groupIDs
    }

    /// Väljer index för den "bästa" bilden bland `indices`: högst kvalitetspoäng
    /// först, därefter högst skärpa som tiebreak (saknade värden räknas som
    /// sämst). Används av `suggestCulling` för att avgöra vilken bild i en
    /// dubblettgrupp som ska behållas.
    static func bestIndex(in indices: [Int], qualityScore: (Int) -> Double?, sharpness: (Int) -> Double?) -> Int? {
        indices.max { a, b in
            let qa = qualityScore(a) ?? -1, qb = qualityScore(b) ?? -1
            if qa != qb { return qa < qb }
            let sa = sharpness(a) ?? -1, sb = sharpness(b) ?? -1
            return sa < sb
        }
    }

    /// Konverterar en horisontvinkel i radianer (från
    /// `HorizonObservation.angle.converted(to: .radians).value`) till en
    /// lutning-från-vågrätt i grader, normaliserad till (-90, 90]. En
    /// horisontlinje är oriktad (en 180°-rotation beskriver samma linje), så
    /// det här viker in vinkeln till motsvarande lutning med minst magnitud.
    static func tiltDegrees(fromRadians radians: Double) -> Double {
        var deg = radians * 180.0 / .pi
        deg = deg.truncatingRemainder(dividingBy: 180)
        if deg > 90 { deg -= 180 }
        if deg <= -90 { deg += 180 }
        return deg
    }

    /// Normaliserar Vision's -1...1 `overallScore` till 0...1 för visning
    /// (stjärnor/stapel i gallringsvyn).
    static func normalizedQualityScore(overallScore: Float) -> Double {
        (Double(overallScore) + 1) / 2
    }

    // MARK: - "Föreslå gallring"-logik (ren, testbar utan GUI)

    struct CullCandidate {
        let id: String
        let isUtility: Bool
        let qualityScore: Double?
        let sharpness: Double?
        let duplicateGroupID: Int?
        /// Redan accepterad eller avvisad av användaren — sådana bilder ska
        /// aldrig röras av ett förslag, även om de tekniskt sett matchar en
        /// dubblett-/nyttobild-regel.
        let isDecided: Bool
    }

    /// Returnerar ID:n för de bilder som bör *föreslås* avvisade: för varje
    /// dubblettgrupp behålls den med högst kvalitet/skärpa (`bestIndex`) och
    /// resten föreslås; `isUtility`-bilder föreslås alltid (oavsett
    /// dubblettgrupp). Rör aldrig redan beslutade bilder.
    static func suggestCulling(_ candidates: [CullCandidate]) -> Set<String> {
        var suggested: Set<String> = []

        var groups: [Int: [Int]] = [:]
        for (i, c) in candidates.enumerated() {
            if let gid = c.duplicateGroupID { groups[gid, default: []].append(i) }
        }
        for (_, indices) in groups {
            guard let bestIdx = bestIndex(
                in: indices,
                qualityScore: { candidates[$0].qualityScore },
                sharpness: { candidates[$0].sharpness }
            ) else { continue }
            for i in indices where i != bestIdx {
                let c = candidates[i]
                if !c.isDecided { suggested.insert(c.id) }
            }
        }

        for c in candidates where c.isUtility && !c.isDecided {
            suggested.insert(c.id)
        }

        return suggested
    }

    // MARK: - Skärpemetrik (vImage/Accelerate)

    /// Varians av en 3x3 Laplace-faltning på en nedskalad (max 512px lång
    /// sida) gråskaleversion av bilden — ett vanligt, billigt
    /// "oskärpe"-mått: en skarp bild har starka högfrekventa kanter (stor
    /// Laplace-varians), en suddig har det inte. Bara meningsfullt relativt
    /// andra bilder i samma session/dubblettgrupp.
    static func computeSharpness(cgImage: CGImage) -> Double? {
        let maxDim = 512
        let w = cgImage.width, h = cgImage.height
        guard w > 2, h > 2 else { return nil }
        let scale = min(1.0, Double(maxDim) / Double(max(w, h)))
        let tw = max(3, Int(Double(w) * scale))
        let th = max(3, Int(Double(h) * scale))

        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: tw * th)

        var srcBuffer = vImage_Buffer(data: pixels, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw)

        var srcFloat = [Float](repeating: 0, count: tw * th)
        var err: vImage_Error = kvImageNoError
        srcFloat.withUnsafeMutableBufferPointer { fptr in
            var destBuffer = vImage_Buffer(data: fptr.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * MemoryLayout<Float>.size)
            err = vImageConvert_Planar8toPlanarF(&srcBuffer, &destBuffer, 1.0, 0.0, vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else { return nil }

        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        var lapFloat = [Float](repeating: 0, count: tw * th)
        srcFloat.withUnsafeMutableBufferPointer { srcPtr in
            var srcF = vImage_Buffer(data: srcPtr.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * MemoryLayout<Float>.size)
            lapFloat.withUnsafeMutableBufferPointer { destPtr in
                var destF = vImage_Buffer(data: destPtr.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * MemoryLayout<Float>.size)
                err = vImageConvolve_PlanarF(&srcF, &destF, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard err == kvImageNoError else { return nil }

        var mean: Float = 0
        var meanSq: Float = 0
        vDSP_meanv(lapFloat, 1, &mean, vDSP_Length(lapFloat.count))
        vDSP_measqv(lapFloat, 1, &meanSq, vDSP_Length(lapFloat.count))
        // vImageConvert_Planar8toPlanarF normaliserade 0...255 till 0...1 —
        // skala tillbaka variansen så talen är i samma härad som en naiv
        // 0...255-skalig Laplace (rent kosmetiskt; bara relativa jämförelser
        // används på riktigt).
        return (Double(meanSq) - Double(mean) * Double(mean)) * Double(255 * 255)
    }

    private static func computeSharpness(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return computeSharpness(cgImage: cgImage)
    }

    // MARK: - Per-bild Vision-mätning

    private struct ImageMeasurement {
        var overallScore: Float = 0
        var isUtility: Bool = false
        var horizonAngleDegrees: Double?
        var sharpness: Double?
        var featurePrint: FeaturePrintObservation?
    }

    private static func measureImage(url: URL) async -> ImageMeasurement {
        var m = ImageMeasurement()

        if let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: url) {
            m.overallScore = aesthetics.overallScore
            m.isUtility = aesthetics.isUtility
        }
        // `Result` for DetectHorizonRequest is itself `HorizonObservation?`, so
        // `try?` flattens perform()'s throw *and* "no horizon found" into one
        // optional — both cases mean "no tilt to report", which is correct here.
        if let horizon = try? await DetectHorizonRequest().perform(on: url) {
            m.horizonAngleDegrees = tiltDegrees(fromRadians: horizon.angle.converted(to: .radians).value)
        }
        m.featurePrint = try? await GenerateImageFeaturePrintRequest().perform(on: url)
        m.sharpness = computeSharpness(url: url)

        return m
    }

    // MARK: - Batch-orkestrering

    struct SessionInput {
        let filename: String
        let url: URL
        /// Bilder som redan delar en bracket-grupp klustras aldrig som
        /// dubbletter av varandra (se `clusterDuplicates`'s `excludePair`).
        let bracketGroupID: Int?
    }

    /// Analyserar en hel sessions previews parallellt (TaskGroup, `maxConcurrent`
    /// samtidiga jobb), klustrar dubbletter över hela resultatet, och
    /// rapporterar förlopp via `progress`. Respekterar avbrytning: kastar
    /// `CancellationError` mellan varje slutfört jobb, vilket avbryter alla
    /// kvarvarande jobb i gruppen (strukturerad concurrency).
    static func analyzeSession(
        items: [SessionInput],
        maxConcurrent: Int = 6,
        progress: @Sendable @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> [String: Result] {
        guard !items.isEmpty else { return [:] }

        var measurements = [ImageMeasurement?](repeating: nil, count: items.count)

        try await withThrowingTaskGroup(of: (Int, ImageMeasurement).self) { group in
            var nextIndex = 0
            var inFlight = 0
            var completed = 0

            func addNext() {
                guard nextIndex < items.count else { return }
                let idx = nextIndex
                let url = items[idx].url
                nextIndex += 1
                inFlight += 1
                group.addTask {
                    (idx, await measureImage(url: url))
                }
            }

            while inFlight < maxConcurrent && nextIndex < items.count {
                try Task.checkCancellation()
                addNext()
            }

            while let (idx, measurement) = try await group.next() {
                inFlight -= 1
                measurements[idx] = measurement
                completed += 1
                await progress(completed, items.count)
                try Task.checkCancellation()
                addNext()
            }
        }

        let groupIDs = clusterDuplicates(
            count: items.count,
            threshold: duplicateDistanceThreshold,
            distance: { i, j in
                guard let a = measurements[i]?.featurePrint, let b = measurements[j]?.featurePrint else { return nil }
                return try? a.distance(to: b)
            },
            excludePair: { i, j in
                guard let ga = items[i].bracketGroupID, let gb = items[j].bracketGroupID else { return false }
                return ga == gb
            }
        )

        var results: [String: Result] = [:]
        for (i, item) in items.enumerated() {
            let m = measurements[i]
            results[item.filename] = Result(
                qualityScore: m.map { normalizedQualityScore(overallScore: $0.overallScore) },
                isUtility: m?.isUtility ?? false,
                horizonAngleDegrees: m?.horizonAngleDegrees,
                sharpness: m?.sharpness,
                duplicateGroupID: groupIDs[i]
            )
        }
        return results
    }

    // MARK: - Persistens (photo_quality.json)

    static func load(from outputDir: URL) -> [String: Result]? {
        let file = outputDir.appendingPathComponent("photo_quality.json")
        guard let data = try? Data(contentsOf: file),
              let persisted = try? JSONDecoder().decode(PersistedFile.self, from: data),
              persisted.version == currentVersion else { return nil }
        return persisted.results
    }

    static func save(_ results: [String: Result], to outputDir: URL) {
        let file = outputDir.appendingPathComponent("photo_quality.json")
        let persisted = PersistedFile(version: currentVersion, duplicateThreshold: duplicateDistanceThreshold, results: results)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: file)
    }
}
