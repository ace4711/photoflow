import Testing
import Foundation
@testable import PhotoFlow

struct EditSelectionTests {
    @Test func toggleSendUsesDefaultsAndRemembers() {
        var s = EditSelection()
        s.toggleSend(group: 1, defaultFiles: ["B.NEF", "A.NEF"])
        #expect(s.isSending(1))
        #expect(s.chosenFiles(for: 1) == ["A.NEF", "B.NEF"])
        s.toggleSend(group: 1, defaultFiles: ["C.NEF"])
        #expect(!s.isSending(1))
        #expect(s.chosenFiles(for: 1).isEmpty)
        // Påslagen igen: tidigare val kommer tillbaka, inte nya standardval.
        s.toggleSend(group: 1, defaultFiles: ["C.NEF"])
        #expect(s.chosenFiles(for: 1) == ["A.NEF", "B.NEF"])
    }

    @Test func rejectedFilesCannotBeChosen() {
        var s = EditSelection()
        let changed = s.toggleFile("A.NEF", in: 2, rejected: ["A.NEF"])
        #expect(!changed)
        #expect(!s.isSending(2))
        s.toggleSend(group: 2, defaultFiles: ["A.NEF", "B.NEF"], rejected: ["A.NEF"])
        #expect(s.chosenFiles(for: 2) == ["B.NEF"])
        // Avvisas i efterhand: filtreras bort men minns.
        s.toggleFile("A.NEF", in: 3)
        #expect(s.chosenFiles(for: 3, rejected: ["A.NEF"]).isEmpty)
        #expect(s.counts(rejected: ["A.NEF"]) == .init(groups: 1, files: 1))
        // Bara avvisade standardval ⇒ gruppen slås inte på.
        s.toggleSend(group: 4, defaultFiles: ["X.NEF"], rejected: ["X.NEF"])
        #expect(!s.isSending(4))
    }

    @Test func toggleFileTurnsGroupOnAndOff() {
        var s = EditSelection()
        s.toggleFile("A.NEF", in: 5)
        #expect(s.isSending(5) && s.chosenFiles(for: 5) == ["A.NEF"])
        s.toggleFile("B.NEF", in: 5)
        #expect(s.chosenFiles(for: 5) == ["A.NEF", "B.NEF"])
        s.toggleFile("A.NEF", in: 5)
        s.toggleFile("B.NEF", in: 5)
        #expect(!s.isSending(5))
        // Avslagen grupp med sparade val: ny bock börjar från bara den filen.
        s.toggleSend(group: 6, defaultFiles: ["A.NEF", "B.NEF"])
        s.toggleSend(group: 6, defaultFiles: [])
        s.toggleFile("C.NEF", in: 6)
        #expect(s.chosenFiles(for: 6) == ["C.NEF"])
    }

    @Test func suggestionDoesNotOverwriteUserChoices() {
        var s = EditSelection()
        s.toggleSend(group: 1, defaultFiles: ["U.NEF"])
        s.applySuggestion([
            1: .init(send: false, files: ["S.NEF"]),
            2: .init(send: true, files: ["S2.NEF"]),
        ])
        #expect(s.suggestionApplied)
        #expect(s.chosenFiles(for: 1) == ["U.NEF"])
        #expect(!s.isSuggestion(1))
        #expect(s.isSuggestion(2) && s.chosenFiles(for: 2) == ["S2.NEF"])
        // Ändring tar bort förslagsmarkeringen.
        s.toggleFile("S2.NEF", in: 2)
        #expect(!s.isSuggestion(2))
        s.applySuggestion([3: .init(send: true, files: ["Z.NEF"])])
        s.clearSuggestions()
        #expect(s.entry(for: 3) == nil)
        #expect(s.entry(for: 1) != nil)
    }

    @Test func undoRestoresPreviousEntry() {
        var s = EditSelection()
        s.applySuggestion([7: .init(send: true, files: ["A.NEF", "B.NEF"])])
        let undo = EditSelectionUndo(groupID: 7, previous: s.entry(for: 7), groupIndex: 0, photoIndex: 0)
        s.toggleFile("A.NEF", in: 7)
        #expect(s.chosenFiles(for: 7) == ["B.NEF"])
        s.setEntry(undo.previous, for: undo.groupID)
        #expect(s.chosenFiles(for: 7) == ["A.NEF", "B.NEF"])
        #expect(s.isSuggestion(7))
        s.setEntry(nil, for: 7)
        #expect(s.entry(for: 7) == nil)

        var stack = ReviewUndoStack()
        stack.push(.editSelection(undo))
        stack.push(ReviewDecisionSnapshot(photoID: "p", accepted: true, rejected: false, algorithmSuggested: false, groupIndex: 0, photoIndex: 0))
        #expect(stack.pop()?.decision?.photoID == "p")
        #expect(stack.pop()?.editSelection == undo)
    }

    @Test func persistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("editsel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = EditSelection()
        s.applySuggestion([1: .init(send: true, files: ["A.NEF"]), 2: .init(send: false, files: ["B.NEF"])])
        s.toggleFile("C.NEF", in: 3)
        try s.save(to: dir)
        let loaded = EditSelection.load(from: dir)
        #expect(loaded == s)
        #expect(loaded.suggestionApplied)
        #expect(EditSelection.load(from: dir.appendingPathComponent("saknas")) == EditSelection())
    }

    @Test func countsAndText() {
        var s = EditSelection()
        s.toggleSend(group: 1, defaultFiles: ["A.NEF", "B.NEF"])
        s.toggleSend(group: 2, defaultFiles: ["C.NEF"])
        s.toggleSend(group: 3, defaultFiles: ["D.NEF"])
        #expect(s.counts() == .init(groups: 3, files: 4))
        #expect(s.counts(validGroups: [1, 2]) == .init(groups: 2, files: 3))
        #expect(EditSelection.countsText(.init(groups: 1, files: 1)) == "1 grupp · 1 fil valda för redigering")
        #expect(EditSelection.countsText(.init(groups: 2, files: 5)) == "2 grupper · 5 filer valda för redigering")
    }

    @Test func filterSendingAndNotSelected() {
        let sums = [true, false, true].map {
            ReviewGroupSummary(allReviewed: false, hasRejected: false, hasUserOverride: false, addressFolder: nil, isSending: $0)
        }
        #expect(ReviewFilter.visibleIndices(sums, filter: .sending) == [0, 2])
        #expect(ReviewFilter.visibleIndices(sums, filter: .notSending) == [1])
        #expect(ReviewFilter.sending.title == "Skickas")
        #expect(ReviewFilter.notSending.title == "Ej vald")
    }
}

struct EditExposureSuggesterTests {
    typealias E = EditExposureSuggester.Exposure

    /// Bracket i hela steg: 1/60 … 1 s (6 bilder, ~6 EV).
    private func bracket(_ secs: [Double]) -> [E] {
        secs.enumerated().map { E(file: "F\($0.offset).NEF", seconds: $0.element) }
    }

    @Test func picksBrightestOneStepDownAndAboutThreeAndAHalfDown() {
        // EV: -5.9, -4.6, -3.3, -2.3, -1.3, 0 → ljusast F5, mitt ≈ -1 ⇒ F4, mörk ≈ -3.5 ⇒ F2
        let r = EditExposureSuggester.suggest(bracket([1.0 / 60, 1.0 / 25, 1.0 / 10, 1.0 / 5, 0.4, 1]))
        #expect(r == ["F2.NEF", "F4.NEF", "F5.NEF"])
    }

    @Test func smallSpanGivesTwoAndNoSpanGivesLast() {
        #expect(EditExposureSuggester.suggest(bracket([1.0 / 50, 1.0 / 25, 1.0 / 13])) == ["F0.NEF", "F2.NEF"])
        #expect(EditExposureSuggester.suggest(bracket([1.0 / 320, 1.0 / 320, 1.0 / 250, 1.0 / 320])) == ["F3.NEF"])
        #expect(EditExposureSuggester.suggest([E(file: "S.NEF", seconds: 0.01)]) == ["S.NEF"])
        #expect(EditExposureSuggester.suggest([]).isEmpty)
    }

    @Test func usesLastBracketRunAndSkipsRejected() {
        // Två serier: 1/10,1/5,0.4 sedan omtagning 1/15,1/6,0.4,1
        let exps = bracket([0.1, 0.2, 0.4, 1.0 / 15, 1.0 / 6, 0.4, 1])
        #expect(EditExposureSuggester.lastRun(exps).map(\.file) == ["F3.NEF", "F4.NEF", "F5.NEF", "F6.NEF"])
        #expect(EditExposureSuggester.suggest(exps) == ["F3.NEF", "F5.NEF", "F6.NEF"])
        var withRejected = exps
        withRejected[6].rejected = true
        #expect(!EditExposureSuggester.suggest(withRejected).contains("F6.NEF"))
    }
}

struct EditGroupSuggesterTests {
    private func groups(_ starts: [TimeInterval]) -> [EditGroupSuggester.Group] {
        starts.enumerated().map { i, s in
            .init(id: 100 + i, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: s + 5))
        }
    }

    @Test func clustersNearIdenticalConsecutiveGroupsAndPicksLast() {
        let g = groups([0, 20, 40, 300, 320])
        // 0–1–2 samma vy, 3 ny vy, 4 samma som 3.
        let d: [Double] = [0.01, 0.02, 0.5, 0.03]
        let r = EditGroupSuggester.suggest(g) { a, b in b == a + 1 ? d[a] : nil }
        #expect(r.clusters == [[100, 101, 102], [103, 104]])
        #expect(r.selected == [102, 104])
    }

    @Test func timeGapAndUnknownDistanceSplit() {
        let g = groups([0, 500, 520])
        let r = EditGroupSuggester.suggest(g) { a, _ in a == 0 ? 0.01 : nil }
        #expect(r.clusters == [[100], [101], [102]])
        #expect(r.selected == [100, 101, 102])
    }

    @Test func ineligibleGroupIsSkippedWithinCluster() {
        var g = groups([0, 10])
        g[1].eligible = false
        let r = EditGroupSuggester.suggest(g) { _, _ in 0.0 }
        #expect(r.selected == [100])
        g[0].eligible = false
        #expect(EditGroupSuggester.suggest(g) { _, _ in 0.0 }.selected.isEmpty)
    }

    @Test func runnerCombinesGroupAndExposureSuggestions() {
        let t = Date(timeIntervalSince1970: 0)
        func photos(_ secs: [Double]) -> [EditSuggestionRunner.PhotoInput] {
            secs.enumerated().map { .init(file: "G\($0.offset).NEF", previewURL: nil, seconds: $0.element, rejected: false) }
        }
        let gs: [EditSuggestionRunner.GroupInput] = [
            .init(id: 1, start: t, end: t.addingTimeInterval(4), photos: photos([1.0 / 25, 1.0 / 8, 0.25, 0.5, 1])),
            .init(id: 2, start: t.addingTimeInterval(10), end: t.addingTimeInterval(14), photos: photos([1.0 / 25, 1.0 / 8, 0.25, 0.5, 1])),
        ]
        let (entries, result) = EditSuggestionRunner.entries(groups: gs) { _, _ in 0.01 }
        #expect(result.selected == [2])
        #expect(entries[1]?.send == false)
        #expect(entries[2]?.send == true)
        #expect(entries[2]?.files == ["G1.NEF", "G3.NEF", "G4.NEF"])
        #expect(entries[2]?.isSuggestion == true)
    }
}
