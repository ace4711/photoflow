import Foundation
import Testing
@testable import PhotoFlow

struct PreviewOrientationTests {
    @Test("Tolkar exiftool -T-utdata till orientering per filnamn")
    func parsesOrientationTable() {
        let text = "DSC_1243.NEF\t1\nDSC_1601.NEF\t8\nDSC_1700.NEF\t-\n\nDSC_1800.NEF\t6\n"
        let parsed = PipelineRunner.parseOrientations(text)
        #expect(parsed == ["DSC_1243": 1, "DSC_1601": 8, "DSC_1800": 6])
    }
}
