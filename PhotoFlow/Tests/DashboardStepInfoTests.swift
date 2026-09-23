import Testing
@testable import PhotoFlow

/// Fas 9: skyddar infopopoverns textinnehåll (`DashboardStep.info`,
/// `DashboardStepInfo.swift`) mot uppenbara regressioner — INTE att texterna
/// stämmer med den faktiska pipeline-koden (det kräver mänsklig
/// eftergranskning när logiken ändras), bara att varje steg faktiskt har
/// rimligt innehåll: en sammanfattning, 3–6 punkter, inga orimligt långa rader.
struct DashboardStepInfoTests {

    @Test("Alla steg har en icke-tom sammanfattning")
    func allSteps_haveNonEmptySummary() {
        for step in DashboardStep.allCases {
            let summary = step.info.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!summary.isEmpty, "\(step) saknar summary")
        }
    }

    @Test("Alla steg har mellan 3 och 6 punkter")
    func allSteps_haveThreeToSixDetails() {
        for step in DashboardStep.allCases {
            let count = step.info.details.count
            #expect(count >= 3 && count <= 6, "\(step) har \(count) punkter, väntat 3-6")
        }
    }

    @Test("Ingen punkt är orimligt lång")
    func allSteps_noDetailLineTooLong() {
        for step in DashboardStep.allCases {
            for detail in step.info.details {
                #expect(detail.count <= 200, "\(step) har en punkt på \(detail.count) tecken: \"\(detail)\"")
            }
        }
    }

    @Test("Ingen punkt är tom")
    func allSteps_noDetailLineEmpty() {
        for step in DashboardStep.allCases {
            for detail in step.info.details {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!trimmed.isEmpty, "\(step) har en tom punkt")
            }
        }
    }

    @Test("Sammanfattningen är inte orimligt lång (tooltip-vänlig)")
    func allSteps_summaryNotTooLong() {
        for step in DashboardStep.allCases {
            #expect(step.info.summary.count <= 200, "\(step) har en summary på \(step.info.summary.count) tecken")
        }
    }

    @Test("settingsTab, när satt, är ett giltigt SettingsView-fliktaggindex (0-4)")
    func allSteps_settingsTabInValidRange() {
        for step in DashboardStep.allCases {
            if let tab = step.info.settingsTab {
                #expect((0...4).contains(tab), "\(step) har ogiltigt settingsTab \(tab)")
            }
        }
    }
}
