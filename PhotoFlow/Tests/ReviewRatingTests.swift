import Testing
import Foundation
@testable import PhotoFlow

struct ReviewRatingTests {
    @Test func setAndToggle() {
        var r = ReviewRatings()
        r.set(3, for: 7)
        #expect(r.rating(for: 7) == 3)
        r.set(3, for: 7)
        #expect(r.rating(for: 7) == 0)
        r.set(9, for: 7)
        #expect(r.rating(for: 7) == 0)
        r.set(5, for: 7); r.clear(group: 7)
        #expect(r.rating(for: 7) == 0)
    }

    @Test func starsText() {
        #expect(ReviewRatings.stars(3) == "★★★☆☆")
        #expect(ReviewRatings.stars(9) == "★★★★★")
        #expect(ReviewRatings.stars(-1) == "☆☆☆☆☆")
    }

    @Test func saveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ratings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var r = ReviewRatings()
        r.set(4, for: 2); r.set(1, for: 10)
        r.save(to: dir)
        #expect(ReviewRatings.load(from: dir) == r)
        #expect(ReviewRatings.load(from: dir.appendingPathComponent("saknas")) == ReviewRatings())
    }

    @Test func minRatingFilter() {
        let s = [0, 2, 3, 5].map {
            ReviewGroupSummary(allReviewed: true, hasRejected: false, hasUserOverride: false, addressFolder: nil, rating: $0)
        }
        #expect(ReviewFilter.visibleIndices(s, filter: .minRating(3)) == [2, 3])
        #expect(ReviewFilter.minRating(3).title == "★ 3+")
    }

    @Test func compareModeCycle() {
        #expect(ReviewCompareMode.off.next(hasFinal: false, hasEnhanced: false) == .off)
        #expect(ReviewCompareMode.off.next(hasFinal: true, hasEnhanced: false) == .source)
        #expect(ReviewCompareMode.source.next(hasFinal: true, hasEnhanced: false) == .off)
        #expect(ReviewCompareMode.source.next(hasFinal: true, hasEnhanced: true) == .merged)
        #expect(ReviewCompareMode.merged.next(hasFinal: true, hasEnhanced: true) == .off)
    }

    @Test func reMergeStatus() {
        #expect(ReMergeStatus.resolve(isRunning: true, error: "x") == .running)
        #expect(ReMergeStatus.resolve(isRunning: false, error: "x") == .failed("x"))
        #expect(ReMergeStatus.resolve(isRunning: false, error: nil) == .idle)
    }
}
