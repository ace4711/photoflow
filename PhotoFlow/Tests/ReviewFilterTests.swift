import Testing
import Foundation
@testable import PhotoFlow

struct ReviewFilterTests {
    private func s(_ reviewed: Bool, rejected: Bool = false, user: Bool = false, addr: String? = nil) -> ReviewGroupSummary {
        ReviewGroupSummary(allReviewed: reviewed, hasRejected: rejected, hasUserOverride: user, addressFolder: addr)
    }

    @Test func filtersByState() {
        let list = [s(true, addr: "A"), s(false, addr: "A"), s(true, rejected: true, addr: "B"), s(true, user: true)]
        #expect(ReviewFilter.visibleIndices(list, filter: .all) == [0, 1, 2, 3])
        #expect(ReviewFilter.visibleIndices(list, filter: .unreviewed) == [1])
        #expect(ReviewFilter.visibleIndices(list, filter: .flagged) == [2, 3])
        #expect(ReviewFilter.visibleIndices(list, filter: .address("A")) == [0, 1])
        #expect(ReviewFilter.addresses(in: list) == ["A", "B"])
    }

    @Test func stepsWithinVisible() {
        let visible = [1, 4, 7]
        #expect(ReviewFilter.step(from: 1, direction: 1, visible: visible) == 4)
        #expect(ReviewFilter.step(from: 7, direction: 1, visible: visible) == nil)
        #expect(ReviewFilter.step(from: 5, direction: -1, visible: visible) == 4)
        #expect(ReviewFilter.step(from: 0, direction: 1, visible: visible) == 1)
        #expect(ReviewFilter.step(from: 1, direction: -1, visible: visible) == nil)
    }

    @Test func undoStackIsLimitedLIFO() {
        var st = ReviewUndoStack(limit: 2)
        func snap(_ id: String) -> ReviewDecisionSnapshot {
            ReviewDecisionSnapshot(photoID: id, accepted: false, rejected: false, algorithmSuggested: true, groupIndex: 0, photoIndex: 0)
        }
        st.push(snap("a")); st.push(snap("b")); st.push(snap("c"))
        #expect(st.count == 2)
        #expect(st.pop()?.photoID == "c")
        #expect(st.pop()?.photoID == "b")
        #expect(st.pop() == nil)
        #expect(st.isEmpty)
    }
}

struct ReviewImageAnalysisTests {
    @Test func detectsClipping() {
        // 4 pixlar: vit, svart, grå, nästan vit i en kanal
        let px: [UInt8] = [255,255,255,255,  0,0,0,255,  128,128,128,255,  10,251,10,255]
        let r = ReviewImageAnalysis.analyze(rgba: px, width: 4, height: 1)
        #expect(r.highClipFraction == 0.5)
        #expect(r.lowClipFraction == 0.25)
        #expect(abs(r.bins.reduce(0, +) - 1) < 1e-9)
        #expect(r.mask[0] == 255 && r.mask[3] > 0)          // röd
        #expect(r.mask[4 + 2] == 255 && r.mask[4 + 3] > 0)  // blå
        #expect(r.mask[8 + 3] == 0)                         // ingen
    }

    @Test func emptyInputIsSafe() {
        let r = ReviewImageAnalysis.analyze(rgba: [], width: 0, height: 0)
        #expect(r.highClipFraction == 0 && r.bins.count == ReviewImageAnalysis.binCount)
    }
}

struct ReviewZoomTests {
    @Test func fitRectCenters() {
        let r = ReviewZoom.fitRect(container: CGSize(width: 200, height: 100), image: CGSize(width: 100, height: 100))
        #expect(r == CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    @Test func clampsPan() {
        let c = ReviewZoom.clampOffset(CGSize(width: 900, height: -900), image: CGSize(width: 1000, height: 300), viewport: CGSize(width: 400, height: 400))
        #expect(c == CGSize(width: 300, height: 0))
    }

    @Test func pointerMapping() {
        let fit = CGRect(x: 50, y: 0, width: 100, height: 100)
        #expect(ReviewZoom.normalizedPoint(pointer: CGPoint(x: 100, y: 50), fit: fit) == CGPoint(x: 0.5, y: 0.5))
        #expect(ReviewZoom.normalizedPoint(pointer: CGPoint(x: 10, y: 50), fit: fit) == nil)
        let off = ReviewZoom.loupeOffset(normalized: CGPoint(x: 0.25, y: 0.5), imagePixels: CGSize(width: 1000, height: 600))
        #expect(off == CGSize(width: 250, height: 0))
    }
}
