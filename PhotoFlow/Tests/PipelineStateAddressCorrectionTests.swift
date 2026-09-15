import Foundation
import CoreLocation
import Testing
@testable import PhotoFlow

/// Tests for the fix to manually corrected addresses/coordinates not being
/// persisted: `PipelineState.correctAddress` used to store the corrected
/// coordinate only in an in-memory dictionary and write just the address text to
/// calendar_matches.json — so reloading the session (the
/// `matchCalendarBookings` skip branch) re-geocoded the address from scratch and
/// silently threw the correction away.
@MainActor
struct PipelineStateAddressCorrectionTests {

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineStateAddressCorrectionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeCalendarMatches(to dir: URL, address: String, eventTitle: String = "Fotografering") {
        let iso = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "address": address,
            "event_title": eventTitle,
            "range_start": iso.string(from: Date()),
            "range_end": iso.string(from: Date().addingTimeInterval(3600))
        ]
        let data = try! JSONSerialization.data(withJSONObject: [entry], options: .prettyPrinted)
        try! data.write(to: dir.appendingPathComponent("calendar_matches.json"))
    }

    private func readCalendarMatches(from dir: URL) -> [[String: Any]] {
        let data = try! Data(contentsOf: dir.appendingPathComponent("calendar_matches.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    @Test("correctAddress sparar latitude/longitude/corrected i calendar_matches.json")
    func correctAddress_persistsCoordinateAndCorrectedFlag() {
        let dir = tempOutputDir()
        writeCalendarMatches(to: dir, address: "Fel Gatan 1, Fel Stad")

        let state = PipelineState()
        state.outputDirectory = dir
        state.allMatchedAddresses = [(address: "Fel Gatan 1, Fel Stad", eventTitle: "Fotografering", hasGPS: false, coordinate: nil)]

        let coord = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        state.correctAddress(at: 0, newAddress: "Rätt Gatan 2, Rätt Stad", coordinate: coord)

        #expect(state.correctedCoordinates["Rätt Gatan 2, Rätt Stad"]?.latitude == 59.33)
        #expect(state.allMatchedAddresses[0].address == "Rätt Gatan 2, Rätt Stad")
        #expect(state.allMatchedAddresses[0].hasGPS == true)

        let saved = readCalendarMatches(from: dir)
        #expect(saved[0]["address"] as? String == "Rätt Gatan 2, Rätt Stad")
        #expect(saved[0]["latitude"] as? Double == 59.33)
        #expect(saved[0]["longitude"] as? Double == 18.06)
        #expect(saved[0]["corrected"] as? Bool == true)
    }

    @Test("correctAddress tar bort metadata_written.json om den redan finns, och loggar det")
    func correctAddress_removesStaleMetadataMarker() {
        let dir = tempOutputDir()
        writeCalendarMatches(to: dir, address: "Fel Gatan 1, Fel Stad")
        let markerFile = dir.appendingPathComponent("metadata_written.json")
        try! Data("{}".utf8).write(to: markerFile)

        let state = PipelineState()
        state.outputDirectory = dir
        state.allMatchedAddresses = [(address: "Fel Gatan 1, Fel Stad", eventTitle: "Fotografering", hasGPS: false, coordinate: nil)]

        #expect(FileManager.default.fileExists(atPath: markerFile.path) == true)
        state.correctAddress(at: 0, newAddress: "Rätt Gatan 2, Rätt Stad", coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2))

        #expect(FileManager.default.fileExists(atPath: markerFile.path) == false)
        #expect(state.logLines.contains { $0.text.contains("Metadata var redan skriven") })
    }

    @Test("correctAddress lämnar filsystemet orört om ingen metadata_written.json finns")
    func correctAddress_noOpWhenNoMetadataMarkerExists() {
        let dir = tempOutputDir()
        writeCalendarMatches(to: dir, address: "Fel Gatan 1, Fel Stad")

        let state = PipelineState()
        state.outputDirectory = dir
        state.allMatchedAddresses = [(address: "Fel Gatan 1, Fel Stad", eventTitle: "Fotografering", hasGPS: false, coordinate: nil)]

        state.correctAddress(at: 0, newAddress: "Rätt Gatan 2, Rätt Stad", coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2))

        #expect(!state.logLines.contains { $0.text.contains("Metadata var redan skriven") })
    }
}
