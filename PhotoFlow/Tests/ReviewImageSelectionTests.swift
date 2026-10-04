import Foundation
import Testing
@testable import PhotoFlow

struct ReviewImageSelectionTests {
    private let tiff = URL(fileURLWithPath: "/o/hdr/hdr_group_1.tiff")
    private let jpg = URL(fileURLWithPath: "/o/hdr/hdr_group_1.jpg")
    private let enhTiff = URL(fileURLWithPath: "/o/enhanced/hdr_group_1_enh.tiff")
    private let enhJpg = URL(fileURLWithPath: "/o/enhanced/hdr_group_1_enh.jpg")

    @Test func hdrFinnsGerHdrJpeg() {
        let c = ReviewImageSelection.defaultChoice(hdr: .init(tiff: tiff, jpeg: jpg), enhanced: [])
        #expect(c == .hdr(jpg))
        #expect(c.isFinalProduct)
    }

    @Test func barTiffGerTiff() {
        #expect(ReviewImageSelection.defaultChoice(hdr: .init(tiff: tiff, jpeg: nil), enhanced: []) == .hdr(tiff))
    }

    @Test func förbättradVinnerOverHdr() {
        let c = ReviewImageSelection.defaultChoice(hdr: .init(tiff: tiff, jpeg: jpg), enhanced: [enhTiff, enhJpg])
        #expect(c == .enhancedHDR(enhJpg))
    }

    @Test func inteHdrGerFörstaExponeringen() {
        let c = ReviewImageSelection.defaultChoice(hdr: nil, enhanced: [])
        #expect(c == .sourceExposure(index: 0))
        #expect(!c.isFinalProduct)
        #expect(ReviewImageSelection.defaultChoice(hdr: .init(), enhanced: []) == .sourceExposure(index: 0))
    }

    @Test func etiketter() {
        #expect(ReviewImageSelection.label(showingFinal: .hdr(jpg), exposureIndex: 0, exposureCount: 3) == "HDR")
        #expect(ReviewImageSelection.label(showingFinal: .enhancedHDR(enhJpg), exposureIndex: 0, exposureCount: 3) == "HDR · förbättrad")
        #expect(ReviewImageSelection.label(showingFinal: .sourceExposure(index: 1), exposureIndex: 1, exposureCount: 3) == "Exponering 2 av 3")
    }
}
