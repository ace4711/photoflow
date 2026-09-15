import Foundation
import Testing
@testable import PhotoFlow

/// Parity tests for `BracketAnalyzer`/`ExifReader` against the old embedded
/// Python bracket-analysis script (`PipelineRunner.bracketAnalysisPython()`,
/// removed in Fas 2a — see FORBATTRINGAR.md).
///
/// Each fixture pair in `Fixtures/BracketAnalysis/` is a synthetic exiftool-
/// style CSV plus the exact JSON the old Python script produced for it (run
/// once via `python3 bracket_analysis.py fixture.csv fixture.expected.json 15 3`,
/// with the script extracted verbatim into a scratchpad tempfile — see the
/// Fas 2a session notes). If `BracketAnalyzer.analyze` doesn't reproduce this
/// JSON exactly, the Swift port has diverged from the algorithm real sessions'
/// `bracket_groups.json` files were built with.
struct BracketAnalyzerParityTests {

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BracketAnalysis")
    }()

    /// Loads a synthetic exiftool-style CSV fixture into `[ExifRecord]`,
    /// exactly the fields `ExifReader.readAll` would have produced (this
    /// fixture stands in for exiftool's CSV output, so there's no ImageIO
    /// involved — just the same string/number parsing `ExifReader` does).
    private func loadRecords(csvNamed name: String) throws -> [ExifRecord] {
        let url = Self.fixturesDir.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        var records: [ExifRecord] = []
        for row in ExifReader.parseCSV(text) {
            guard let filename = row["FileName"],
                  let exposureTimeStr = row["ExposureTime"],
                  let fNumberStr = row["FNumber"], let fNumber = Double(fNumberStr),
                  let isoStr = row["ISO"], let iso = Int(isoStr),
                  let dateStr = row["DateTimeOriginal"], let date = ExifReader.parseEXIFDate(dateStr) else {
                continue
            }
            let exposureSeconds = (try? ExifReader.parseExposureString(exposureTimeStr)) ?? 0
            let subsec = ExifReader.parseSubsec(row["SubSecTimeOriginal"] ?? "")
            records.append(ExifRecord(
                filename: filename,
                exposureTime: exposureTimeStr,
                exposureSeconds: exposureSeconds,
                fNumber: fNumber,
                iso: iso,
                dateTimeOriginal: date,
                subsec: subsec,
                orientation: 1
            ))
        }
        return records
    }

    private func loadExpected(jsonNamed name: String) throws -> BracketAnalysisOutput {
        let url = Self.fixturesDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BracketAnalysisOutput.self, from: data)
    }

    private func assertParity(_ baseName: String) throws {
        let records = try loadRecords(csvNamed: "\(baseName).csv")
        let expected = try loadExpected(jsonNamed: "\(baseName).expected.json")
        let actual = BracketAnalyzer.analyze(records: records, params: expected.params)
        #expect(actual == expected)
    }

    @Test("Enkla singlar utan tidsmässig eller inställningsmässig koppling")
    func singles() throws {
        try assertParity("singles")
    }

    @Test("3-bracket med subsec i 1, 2 och 3 siffror")
    func bracket3WithVaryingSubsecDigits() throws {
        try assertParity("bracket3_subsec")
    }

    @Test("5-bracket där mörkaste exponeringen hoppas över i suggested_hdr_indices")
    func bracket5DropsDarkestFromHDRSubset() throws {
        try assertParity("bracket5_dark")
    }

    @Test("Två 3-brackets direkt efter varandra (mönsterdelning) + glapp >6s delar en grupp")
    func twoBracketsBackToBackAndInternalGapSplit() throws {
        try assertParity("two_brackets_and_gap")
    }
}
