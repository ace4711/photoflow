import Testing
@testable import PhotoFlow

struct ReviewNavigationTests {
    @Test func hittarNastaOgranskade() {
        #expect(ReviewNavigation.nextUnreviewed(from: 0, reviewed: [true, true, false, false]) == 2)
    }
    @Test func wrapAround() {
        #expect(ReviewNavigation.nextUnreviewed(from: 3, reviewed: [false, true, true, true]) == 0)
    }
    @Test func bakat() {
        #expect(ReviewNavigation.nextUnreviewed(from: 2, reviewed: [false, true, true, false], direction: -1) == 0)
    }
    @Test func allaKlaraGerNil() {
        #expect(ReviewNavigation.nextUnreviewed(from: 1, reviewed: [true, true]) == nil)
        #expect(ReviewNavigation.nextUnreviewed(from: 0, reviewed: []) == nil)
    }
    @Test func enstakaOgranskadAktuellWrapparTillSigSjalv() {
        #expect(ReviewNavigation.nextUnreviewed(from: 1, reviewed: [true, false, true]) == 1)
    }
    @Test func prefetchGranser() {
        #expect(ReviewNavigation.prefetchNeighbors(of: 0, count: 5) == [1, 2])
        #expect(ReviewNavigation.prefetchNeighbors(of: 2, count: 5) == [3, 1, 4, 0])
        #expect(ReviewNavigation.prefetchNeighbors(of: 0, count: 0).isEmpty)
    }
    @Test func progress() {
        #expect(ReviewNavigation.progressText(reviewed: 12, total: 100) == "12 av 100 granskade")
    }
}
