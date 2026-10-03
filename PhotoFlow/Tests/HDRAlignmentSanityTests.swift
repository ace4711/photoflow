import Foundation
import CoreGraphics
import Testing
@testable import PhotoFlow

/// `HDRAlignment.sanitizedShift`: avvisar felregistreringar, avrundar små rörelser.
struct HDRAlignmentSanityTests {
    @Test("Orimlig förskjutning (tusentals px) avvisas — så såg felet i köksgruppen ut")
    func wildShiftRejected() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: -2, y: -3000), width: 6000, height: 4000) == nil)
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: 200, y: 0), width: 6000, height: 4000) == nil)
    }

    @Test("Liten verklig rörelse rundas till hela pixlar")
    func smallShiftRounded() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: -2.75, y: 2.4), width: 8256, height: 5504) == CGPoint(x: -3, y: 2))
    }

    @Test("Brus under 1,5 px blir ingen förskjutning")
    func noiseIgnored() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: 0.8, y: -1.2), width: 6000, height: 4000) == .zero)
    }

    @Test("NaN/oändligt avvisas")
    func nonFiniteRejected() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: Double.nan, y: 0), width: 6000, height: 4000) == nil)
    }
}
