import Foundation
import CoreGraphics
import Testing
@testable import PhotoFlow

/// Tests for the pure/testable parts of `PhotoQualityService` (Fas 3b):
/// duplicate clustering from a distance function, picking the best photo in a
/// group, horizon-angle normalization, and the "föreslå gallring" decision
/// logic. None of these touch Vision or real images — they're pure functions
/// so the decision logic can be verified without a GUI or camera files.
struct PhotoQualityServiceTests {

    // MARK: - clusterDuplicates

    @Test("Två bilder under tröskeln hamnar i samma dubblettgrupp")
    func clusterDuplicates_pairBelowThreshold_sameGroup() {
        // 3 images: 0 and 1 are near-duplicates (distance 0.05), 2 is unrelated.
        let distances: [[Double]] = [
            [0, 0.05, 0.9],
            [0.05, 0, 0.8],
            [0.9, 0.8, 0],
        ]
        let groups = PhotoQualityService.clusterDuplicates(
            count: 3, threshold: 0.15,
            distance: { i, j in distances[i][j] }
        )
        #expect(groups[0] != nil)
        #expect(groups[0] == groups[1])
        #expect(groups[2] == nil)
    }

    @Test("Ingen dubblett under tröskeln ger inga grupper")
    func clusterDuplicates_allAboveThreshold_noGroups() {
        let groups = PhotoQualityService.clusterDuplicates(
            count: 3, threshold: 0.15,
            distance: { _, _ in 0.9 }
        )
        #expect(groups == [nil, nil, nil])
    }

    @Test("Single-linkage: A-B och B-C nära kedjar ihop A/B/C trots att A-C aldrig mättes")
    func clusterDuplicates_chainedPairs_transitivelyGrouped() {
        // A-B close, B-C close, A-C never measured (nil = "not comparable").
        let groups = PhotoQualityService.clusterDuplicates(
            count: 3, threshold: 0.15,
            distance: { i, j in
                if (i, j) == (0, 1) || (i, j) == (1, 0) { return 0.05 }
                if (i, j) == (1, 2) || (i, j) == (2, 1) { return 0.05 }
                return nil
            }
        )
        #expect(groups[0] == groups[1])
        #expect(groups[1] == groups[2])
        #expect(groups[0] != nil)
    }

    @Test("excludePair hindrar två nära bilder från att klustras (t.ex. samma bracket-grupp)")
    func clusterDuplicates_excludedPair_notGrouped() {
        let groups = PhotoQualityService.clusterDuplicates(
            count: 2, threshold: 0.15,
            distance: { _, _ in 0.01 },
            excludePair: { _, _ in true }
        )
        #expect(groups == [nil, nil])
    }

    @Test("Grupp med bara en medlem (efter uteslutning) räknas inte som dubblett")
    func clusterDuplicates_singleMemberGroup_isNil() {
        let groups = PhotoQualityService.clusterDuplicates(
            count: 1, threshold: 0.15,
            distance: { _, _ in 0 }
        )
        #expect(groups == [nil])
    }

    // MARK: - bestIndex

    @Test("bestIndex väljer högst kvalitetspoäng")
    func bestIndex_picksHighestQuality() {
        let quality: [Double?] = [0.3, 0.9, 0.5]
        let sharpness: [Double?] = [100, 100, 100]
        let best = PhotoQualityService.bestIndex(in: [0, 1, 2], qualityScore: { quality[$0] }, sharpness: { sharpness[$0] })
        #expect(best == 1)
    }

    @Test("bestIndex använder skärpa som tiebreak vid lika kvalitet")
    func bestIndex_tiebreaksOnSharpness() {
        let quality: [Double?] = [0.5, 0.5]
        let sharpness: [Double?] = [200, 800]
        let best = PhotoQualityService.bestIndex(in: [0, 1], qualityScore: { quality[$0] }, sharpness: { sharpness[$0] })
        #expect(best == 1)
    }

    @Test("bestIndex behandlar saknad kvalitetspoäng som sämst")
    func bestIndex_missingQuality_treatedAsWorst() {
        let quality: [Double?] = [nil, 0.1]
        let sharpness: [Double?] = [1000, 1]
        let best = PhotoQualityService.bestIndex(in: [0, 1], qualityScore: { quality[$0] }, sharpness: { sharpness[$0] })
        #expect(best == 1)
    }

    // MARK: - tiltDegrees(fromRadians:)

    @Test("2 grader i radianer ger ~2.0 grader")
    func tiltDegrees_smallPositiveAngle() {
        let radians = 2.0 * Double.pi / 180.0
        let deg = PhotoQualityService.tiltDegrees(fromRadians: radians)
        #expect(abs(deg - 2.0) < 0.0001)
    }

    @Test("Vågrätt (0 radianer) ger 0 grader")
    func tiltDegrees_zero() {
        #expect(PhotoQualityService.tiltDegrees(fromRadians: 0) == 0)
    }

    @Test("179 grader (nästan vågrätt åt andra hållet) viks till -1 grad")
    func tiltDegrees_nearHalfTurn_foldsToSmallNegative() {
        let radians = 179.0 * Double.pi / 180.0
        let deg = PhotoQualityService.tiltDegrees(fromRadians: radians)
        #expect(abs(deg - (-1.0)) < 0.0001)
    }

    @Test("-179 grader viks till +1 grad")
    func tiltDegrees_negativeNearHalfTurn_foldsToSmallPositive() {
        let radians = -179.0 * Double.pi / 180.0
        let deg = PhotoQualityService.tiltDegrees(fromRadians: radians)
        #expect(abs(deg - 1.0) < 0.0001)
    }

    @Test("Resultatet ligger alltid i (-90, 90] för en rad olika vinklar")
    func tiltDegrees_alwaysInRange() {
        for degrees in stride(from: -400.0, through: 400.0, by: 17.0) {
            let radians = degrees * Double.pi / 180.0
            let deg = PhotoQualityService.tiltDegrees(fromRadians: radians)
            #expect(deg > -90.0001 && deg <= 90.0001)
        }
    }

    // MARK: - normalizedQualityScore

    @Test("overallScore -1...1 normaliseras till 0...1")
    func normalizedQualityScore_mapsRange() {
        #expect(PhotoQualityService.normalizedQualityScore(overallScore: -1) == 0)
        #expect(PhotoQualityService.normalizedQualityScore(overallScore: 0) == 0.5)
        #expect(PhotoQualityService.normalizedQualityScore(overallScore: 1) == 1)
    }

    // MARK: - suggestCulling

    private func candidate(
        _ id: String, isUtility: Bool = false, quality: Double? = nil,
        sharpness: Double? = nil, group: Int? = nil, decided: Bool = false
    ) -> PhotoQualityService.CullCandidate {
        .init(id: id, isUtility: isUtility, qualityScore: quality, sharpness: sharpness, duplicateGroupID: group, isDecided: decided)
    }

    @Test("I en dubblettgrupp föreslås alla utom den bästa avvisade")
    func suggestCulling_duplicateGroup_keepsOnlyBest() {
        let candidates = [
            candidate("a", quality: 0.9, group: 0),
            candidate("b", quality: 0.4, group: 0),
            candidate("c", quality: 0.2, group: 0),
        ]
        let suggested = PhotoQualityService.suggestCulling(candidates)
        #expect(suggested == ["b", "c"])
    }

    @Test("isUtility-bilder föreslås avvisade även utan dubblettgrupp")
    func suggestCulling_utilityPhoto_suggestedEvenWithoutGroup() {
        let candidates = [
            candidate("a", isUtility: true, quality: 0.9),
            candidate("b", quality: 0.5),
        ]
        let suggested = PhotoQualityService.suggestCulling(candidates)
        #expect(suggested == ["a"])
    }

    @Test("Redan beslutade bilder föreslås aldrig, även om de matchar en regel")
    func suggestCulling_decidedPhotos_neverSuggested() {
        let candidates = [
            candidate("a", quality: 0.9, group: 0),
            candidate("b", quality: 0.1, group: 0, decided: true),
            candidate("c", isUtility: true, decided: true),
        ]
        let suggested = PhotoQualityService.suggestCulling(candidates)
        #expect(suggested.isEmpty)
    }

    @Test("Tom lista ger inga förslag")
    func suggestCulling_empty_noSuggestions() {
        #expect(PhotoQualityService.suggestCulling([]).isEmpty)
    }

    // MARK: - computeSharpness (real CGImage, no Vision — deterministic)

    @Test("Ett skarpt schackrutigt mönster ger högre skärpa än en enfärgad bild")
    func computeSharpness_checkerboardSharperThanFlat() {
        let flat = makeSolidGrayImage(size: 64, gray: 128)
        let checker = makeCheckerboardImage(size: 64, squareSize: 2)

        let flatSharpness = PhotoQualityService.computeSharpness(cgImage: flat)
        let checkerSharpness = PhotoQualityService.computeSharpness(cgImage: checker)

        #expect(flatSharpness != nil)
        #expect(checkerSharpness != nil)
        #expect(flatSharpness! < 1.0) // Flat image: near-zero Laplacian everywhere.
        #expect(checkerSharpness! > flatSharpness!)
    }

    private func makeSolidGrayImage(size: Int, gray: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: gray, count: size * size)
        return pixels.withUnsafeMutableBufferPointer { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func makeCheckerboardImage(size: Int, squareSize: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let isWhite = ((x / squareSize) + (y / squareSize)) % 2 == 0
                pixels[y * size + x] = isWhite ? 255 : 0
            }
        }
        return pixels.withUnsafeMutableBufferPointer { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }
}
