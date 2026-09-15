import Testing
@testable import PhotoFlow

struct StepStatusTests {

    // MARK: - durationText

    @Test("Ingen varaktighet ger nil")
    func durationText_nilWhenNoDuration() {
        var status = StepStatus()
        status.lastDuration = nil
        #expect(status.durationText == nil)
    }

    @Test("Under en minut visas bara sekunder")
    func durationText_secondsOnly() {
        var status = StepStatus()
        status.lastDuration = 45
        #expect(status.durationText == "45s")
    }

    @Test("Över en minut visas minuter och sekunder")
    func durationText_minutesAndSeconds() {
        var status = StepStatus()
        status.lastDuration = 133 // 2m 13s
        #expect(status.durationText == "2m 13s")
    }

    // MARK: - statusText

    @Test("Idle ger tom sträng")
    func statusText_idle() {
        let status = StepStatus(phase: .idle)
        #expect(status.statusText == "")
    }

    @Test("Active med totalCount visar förlopp")
    func statusText_activeWithProgress() {
        var status = StepStatus(phase: .active)
        status.processedCount = 3
        status.totalCount = 10
        #expect(status.statusText == "3/10 (7 kvar)")
    }

    @Test("Active utan totalCount visar 'Arbetar...'")
    func statusText_activeWithoutTotal() {
        let status = StepStatus(phase: .active)
        #expect(status.statusText == "Arbetar...")
    }

    @Test("Complete med totalCount och varaktighet")
    func statusText_completeWithDurationAndCount() {
        var status = StepStatus(phase: .complete)
        status.totalCount = 5
        status.lastDuration = 12
        #expect(status.statusText == "5 klara · 12s")
    }

    @Test("Complete utan totalCount eller varaktighet")
    func statusText_completePlain() {
        let status = StepStatus(phase: .complete)
        #expect(status.statusText == "Klar")
    }

    @Test("Error-fas visar felmeddelandet")
    func statusText_error() {
        let status = StepStatus(phase: .error("Något gick fel"))
        #expect(status.statusText == "Något gick fel")
        #expect(status.isError)
    }

    @Test("Watching utan nya filer visar 'Bevakar...'")
    func statusText_watchingNoNewFiles() {
        let status = StepStatus(phase: .watching)
        #expect(status.statusText == "Bevakar...")
    }
}
