import Foundation
import CoreLocation

extension PipelineRunner {
    // MARK: - Step 2.5: Calendar Matching

    func matchCalendarBookings() async {
        guard let outputDir = state.outputDirectory else { return }

        // Check if calendar_matches.json already exists
        let matchesFile = outputDir.appendingPathComponent("calendar_matches.json")
        if let savedData = try? Data(contentsOf: matchesFile),
           let savedJSON = try? JSONSerialization.jsonObject(with: savedData) as? [[String: Any]],
           !savedJSON.isEmpty {
            // Load from disk
            let dateFormatter = ISO8601DateFormatter()
            calendarMappings = []
            state.allMatchedAddresses = []
            // Addresses with a manually-corrected coordinate saved in the JSON
            // (see PipelineState.correctAddress/saveCalendarMatches) — these must
            // never be silently re-geocoded, since the whole point of a manual
            // correction is that automatic geocoding got it wrong.
            var correctedAddresses: Set<String> = []
            for entry in savedJSON {
                guard let address = entry["address"] as? String,
                      let eventTitle = entry["event_title"] as? String,
                      let startStr = entry["range_start"] as? String,
                      let endStr = entry["range_end"] as? String,
                      let start = dateFormatter.date(from: startStr),
                      let end = dateFormatter.date(from: endStr) else { continue }
                calendarMappings.append((address: address, eventTitle: eventTitle, photoDateRange: start...end))

                let isCorrected = (entry["corrected"] as? Bool) ?? false
                if isCorrected, let lat = entry["latitude"] as? Double, let lon = entry["longitude"] as? Double {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    state.correctedCoordinates[address] = coord
                    correctedAddresses.insert(address)
                    state.allMatchedAddresses.append((address: address, eventTitle: eventTitle, hasGPS: true, coordinate: coord))
                } else {
                    state.allMatchedAddresses.append((address: address, eventTitle: eventTitle, hasGPS: false, coordinate: nil))
                }
            }
            state.matchedAddress = state.allMatchedAddresses.first?.address
            state.matchedEventTitle = state.allMatchedAddresses.first?.eventTitle
            logDecision(step: "calendar_match", decision: "skipped", details: [
                "reason": "json_exists",
                "matchCount": "\(calendarMappings.count)"
            ])
            state.appendStepLog(.findCalendarInfo, "Kalendermatchningar redan sparade (\(calendarMappings.count) st) — hoppar over", type: .info)
            state.appendLog("Kalendermatchning redan klar — laddar fran calendar_matches.json.", type: .info)
            for mapping in calendarMappings {
                state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle)", type: .success)
            }
            // Geocode cached addresses to show GPS status — skip any address with a
            // saved manual correction, using its corrected coordinate instead.
            let calendar = CalendarService.shared
            _ = await calendar.requestAccess()
            for (idx, mapping) in calendarMappings.enumerated() {
                if correctedAddresses.contains(mapping.address) {
                    let coord = state.correctedCoordinates[mapping.address]
                    state.appendStepLog(.findCalendarInfo, "GPS (manuellt rättad): \"\(mapping.address)\" → \(String(format: "%.4f", coord?.latitude ?? 0)), \(String(format: "%.4f", coord?.longitude ?? 0))", type: .success)
                    continue
                }
                let coord = await calendar.geocodeAddress(mapping.address)
                if let coord {
                    state.appendStepLog(.findCalendarInfo, "GPS hittad: \"\(mapping.address)\" → \(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))", type: .success)
                    if idx < state.allMatchedAddresses.count {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    state.appendStepLog(.findCalendarInfo, "GPS saknas: \"\(mapping.address)\" — kunde inte geokoda", type: .warning)
                }
            }
            return
        }

        let calendar = CalendarService.shared

        state.appendLog("Matchar bilder mot kalenderbokningar...", type: .info)

        let granted = await calendar.requestAccess()
        guard granted else {
            state.appendLog("Ingen kalenderåtkomst — hoppar över adressmatchning.", type: .warning)
            return
        }

        // Read photo dates from bracket_groups.json
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard let data = try? Data(contentsOf: groupsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Use every photo's own capture time when available (per-file "datetimes"),
        // not just the group's start time — a group can span several minutes, which
        // previously made every photo in it match the same single calendar event
        // even when some of them actually fell just outside its window.
        var photoDates: [Date] = []
        for group in groups {
            if let dateStrs = group["datetimes"] as? [String], !dateStrs.isEmpty {
                photoDates.append(contentsOf: dateStrs.compactMap { dateFormatter.date(from: $0) })
            } else if let dateStr = group["date_start"] as? String,
                      let date = dateFormatter.date(from: dateStr) {
                photoDates.append(date)
            }
        }

        state.appendStepLog(.findCalendarInfo, "\(photoDates.count) fotodatum extraherade fran \(groups.count) grupper")

        guard !photoDates.isEmpty else {
            state.appendStepLog(.findCalendarInfo, "Inga fotodatum — hoppar over", type: .warning)
            return
        }

        calendarMappings = calendar.matchPhotosToAddresses(photoDates: photoDates)

        if calendarMappings.isEmpty {
            state.appendLog("Inga matchande kalenderbokningar hittades.", type: .info)
            state.appendStepLog(.findCalendarInfo, "Inga kalenderbokningar matchade nagot fotodatum", type: .warning)
        } else {
            state.allMatchedAddresses = []
            for mapping in calendarMappings {
                state.appendLog("Kalender: \"\(mapping.address)\" (\(mapping.eventTitle))", type: .success)
                let rangeFmt = DateFormatter()
                rangeFmt.dateFormat = "HH:mm"
                let rangeStr = "\(rangeFmt.string(from: mapping.photoDateRange.lowerBound))–\(rangeFmt.string(from: mapping.photoDateRange.upperBound))"
                state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle) (foton \(rangeStr))", type: .success)
                state.allMatchedAddresses.append((address: mapping.address, eventTitle: mapping.eventTitle, hasGPS: false, coordinate: nil))
            }
            state.matchedAddress = state.allMatchedAddresses.first?.address
            state.matchedEventTitle = state.allMatchedAddresses.first?.eventTitle
            pipelineLog("Kalender-matchningar: \(calendarMappings.count)")

            // Geocode addresses and report GPS status on this step card
            for (idx, mapping) in calendarMappings.enumerated() {
                let coord = await calendar.geocodeAddress(mapping.address)
                if let coord {
                    state.appendStepLog(.findCalendarInfo, "GPS hittad: \"\(mapping.address)\" → \(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))", type: .success)
                    if idx < state.allMatchedAddresses.count {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    state.appendStepLog(.findCalendarInfo, "GPS saknas: \"\(mapping.address)\" — kunde inte geokoda", type: .warning)
                }
            }

            // Save to JSON for persistence
            let isoFormatter = ISO8601DateFormatter()
            let matchArray: [[String: Any]] = calendarMappings.map { mapping in
                [
                    "address": mapping.address,
                    "event_title": mapping.eventTitle,
                    "range_start": isoFormatter.string(from: mapping.photoDateRange.lowerBound),
                    "range_end": isoFormatter.string(from: mapping.photoDateRange.upperBound)
                ]
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: matchArray, options: .prettyPrinted) {
                try? jsonData.write(to: matchesFile)
            }
        }
    }
}
