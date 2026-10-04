import Foundation
import CoreLocation

extension PipelineRunner {
    /// Sätts bara av photoflow-cli (`--calendar-matches`): använd en befintlig calendar_matches.json
    /// i outputmappen utan att kontrollera manifestets fingerprint (och alltså utan EventKit).
    static var trustExistingCalendarMatches = false

    // MARK: - Step 2.5: Calendar Matching

    func matchCalendarBookings() async {
        guard let outputDir = state.outputDirectory else { return }

        // Fas 8 (utökad Fas 10 för flerval): manifest-fingerprint av
        // bracket_groups.json (representerar fotodatumen matchningen läser) +
        // vilka kalendrar som söks — satt HÄR (innan något skip-beslut) av
        // samma skäl som övriga fingerprint-grindade steg. Byte av
        // `calendarNames` i Inställningar ändrar inte fotoantalet, men SKA
        // trigga en ny matchning i stället för att tyst återanvända en gammal
        // `calendar_matches.json` mot fel kalender(rar) — det var precis den
        // sortens bugg (`maxTimeGap`) Fas 6:s fingerprint-mönster fanns till
        // för att stänga. JSON-kodad (sorterad) lista i stället för en naiv
        // join, av samma skäl som `AppSettings.calendarNames` lagras som JSON
        // — kalendernamn kan innehålla nästan vilket separatortecken som helst.
        let groupsJSONForFingerprint = outputDir.appendingPathComponent("bracket_groups.json")
        let calendarFingerprint = SessionManifestStore.fingerprint(
            fileURLs: [groupsJSONForFingerprint],
            settings: [
                "calendarNames": CalendarService.calendarNamesFingerprintValue(AppSettings.shared.calendarNames),
                // Regelversion för tilldelningen (tidskluster): en ändrad regel matchar om befintliga
                // sessioner, och sorteringen flyttar sedan felplacerade filer (se exportToAddressFolders).
                "matchRule": PhotoClustering.ruleVersion
            ]
        )
        state.setPendingFingerprint(calendarFingerprint, for: .findCalendarInfo)

        // Check if calendar_matches.json already exists AND the manifest
        // fingerprint still matches (samma bracket_groups.json + samma
        // vald kalender). Annars matchas om nedanför, precis som ett
        // vanligt förstagångskörning.
        let matchesFile = outputDir.appendingPathComponent("calendar_matches.json")
        let manifestRecord = state.sessionManifest?.steps[DashboardStep.findCalendarInfo.manifestKey]
        // Manifestet matchar, ELLER (bakåtkompatibilitet) sessionen kördes
        // före Fas 8 och har inget fingerprint-record alls för det här
        // steget än — då är den gamla "filen finns och är inte tom"-
        // kontrollen fortfarande rimlig (annars skulle varje uppgraderad,
        // redan klar session i onödan göra om kalenderåtkomst+geokodning).
        // `trustExistingCalendarMatches` (photoflow-cli --calendar-matches): testvägen för riktmärket,
        // där calendar_matches.json läggs in i förväg och EventKit inte finns (headless).
        let canUseCache = manifestRecord == nil || manifestRecord?.inputFingerprint == calendarFingerprint
            || Self.trustExistingCalendarMatches
        if canUseCache,
           let savedData = try? Data(contentsOf: matchesFile),
           let savedJSON = try? JSONSerialization.jsonObject(with: savedData) as? [[String: Any]],
           !savedJSON.isEmpty {
            await applySavedCalendarMatches(savedJSON)
            logDecision(step: "calendar_match", decision: "skipped", details: [
                "reason": manifestRecord == nil ? "json_exists_no_manifest_record" : "manifest_fingerprint_match",
                "matchCount": "\(calendarMappings.count)",
                "fingerprint": calendarFingerprint
            ])
            state.appendStepLog(.findCalendarInfo, "Kalendermatchningar redan sparade (\(calendarMappings.count) st) — hoppar över", type: .info)
            state.appendLog("Kalendermatchning redan klar — laddar från calendar_matches.json.", type: .info)
            return
        }

        let calendar = CalendarService.shared

        // Den tidigare matchningen (om någon): reserv när kalendern inte går att läsa, och källan
        // till manuella adressrättningar som ska överleva en ny matchning.
        let previousJSON = (try? Data(contentsOf: matchesFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []

        state.appendLog("Matchar bilder mot kalenderbokningar...", type: .info)

        let granted = await calendar.requestAccess()
        guard granted else {
            if !previousJSON.isEmpty {
                // Hellre den gamla matchningen än ingen alls: utan mappningar skulle sorteringen lägga
                // allt i "Osorterade".
                state.appendLog("Ingen kalenderåtkomst — använder den tidigare sparade matchningen.", type: .warning)
                state.appendStepLog(.findCalendarInfo, "Ingen kalenderåtkomst — använder tidigare calendar_matches.json", type: .warning)
                await applySavedCalendarMatches(previousJSON)
            } else {
                state.appendLog("Ingen kalenderåtkomst — hoppar över adressmatchning.", type: .warning)
            }
            return
        }

        // Read photo dates from bracket_groups.json
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard let data = try? Data(contentsOf: groupsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let photoDates = Self.photoDates(fromBracketGroups: groups)
        state.appendStepLog(.findCalendarInfo, "\(photoDates.count) fotodatum extraherade från \(groups.count) grupper")

        guard !photoDates.isEmpty else {
            state.appendStepLog(.findCalendarInfo, "Inga fotodatum — hoppar över", type: .warning)
            return
        }

        guard let match = await calendar.matchPhotosToAddresses(photoDates: photoDates) else {
            state.appendStepLog(.findCalendarInfo, "Kalendermatchningen kunde inte göras", type: .warning)
            return
        }
        logClusterMatch(match)

        // Manuella adressrättningar (adress + GPS) från den tidigare matchningen följer med
        // till samma bokning (nyckel = händelsetiteln).
        var corrections: [String: (address: String, latitude: Double, longitude: Double)] = [:]
        for entry in previousJSON where (entry["corrected"] as? Bool) == true {
            guard let title = entry["event_title"] as? String, let address = entry["address"] as? String,
                  let lat = entry["latitude"] as? Double, let lon = entry["longitude"] as? Double else { continue }
            corrections[title] = (address, lat, lon)
        }

        calendarMappings = match.result.mappings.map { mapping in
            (address: corrections[mapping.eventTitle]?.address ?? mapping.address,
             eventTitle: mapping.eventTitle, photoDateRange: mapping.range)
        }

        if calendarMappings.isEmpty {
            state.appendLog("Inga matchande kalenderbokningar hittades.", type: .info)
            state.appendStepLog(.findCalendarInfo, "Inga kalenderbokningar matchade något fotodatum", type: .warning)
        } else {
            state.allMatchedAddresses = []
            let rangeFmt = DateFormatter()
            rangeFmt.dateFormat = "HH:mm"
            for mapping in calendarMappings {
                state.appendLog("Kalender: \"\(mapping.address)\" (\(mapping.eventTitle))", type: .success)
                let rangeStr = "\(rangeFmt.string(from: mapping.photoDateRange.lowerBound))–\(rangeFmt.string(from: mapping.photoDateRange.upperBound))"
                state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle) (foton \(rangeStr))", type: .success)
                if let corrected = corrections[mapping.eventTitle] {
                    let coord = CLLocationCoordinate2D(latitude: corrected.latitude, longitude: corrected.longitude)
                    state.correctedCoordinates[corrected.address] = coord
                    state.allMatchedAddresses.append((address: mapping.address, eventTitle: mapping.eventTitle, hasGPS: true, coordinate: coord))
                } else {
                    state.allMatchedAddresses.append((address: mapping.address, eventTitle: mapping.eventTitle, hasGPS: false, coordinate: nil))
                }
            }
            state.matchedAddress = state.allMatchedAddresses.first?.address
            state.matchedEventTitle = state.allMatchedAddresses.first?.eventTitle
            pipelineLog("Kalender-matchningar: \(calendarMappings.count)")

            // Geocode addresses and report GPS status on this step card
            for (idx, mapping) in calendarMappings.enumerated() where corrections[mapping.eventTitle] == nil {
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

            // Spara för återanvändning. Klusterinfo och bokningstid är nya fält (fas: tidskluster);
            // äldre läsare bryr sig bara om address/event_title/range_start/range_end.
            let matchArray = Self.calendarMatchesJSON(match: match, mappings: calendarMappings, corrections: corrections)
            if let jsonData = try? JSONSerialization.data(withJSONObject: matchArray, options: .prettyPrinted) {
                try? jsonData.write(to: matchesFile)
            }
        }
    }

    /// Bildtiderna i `bracket_groups.json`: varje bilds egen tid (`datetimes`), annars gruppens starttid.
    nonisolated static func photoDates(fromBracketGroups groups: [[String: Any]]) -> [Date] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var photoDates: [Date] = []
        for group in groups {
            if let dateStrs = group["datetimes"] as? [String], !dateStrs.isEmpty {
                photoDates.append(contentsOf: dateStrs.compactMap { dateFormatter.date(from: $0) })
            } else if let dateStr = group["date_start"] as? String, let date = dateFormatter.date(from: dateStr) {
                photoDates.append(date)
            }
        }
        return photoDates
    }

    /// Posterna i `calendar_matches.json`, en per mappning (samma ordning som `calendarMappings`,
    /// som `PipelineState.saveCalendarMatches` förutsätter).
    nonisolated static func calendarMatchesJSON(
        match: PhotoClusterMatch,
        mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)],
        corrections: [String: (address: String, latitude: Double, longitude: Double)]
    ) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        return zip(match.result.mappings, mappings).map { clusterMapping, mapping in
            let booking = match.bookings[clusterMapping.bookingIndex]
            var entry: [String: Any] = [
                "address": mapping.address,
                "event_title": mapping.eventTitle,
                "range_start": iso.string(from: mapping.photoDateRange.lowerBound),
                "range_end": iso.string(from: mapping.photoDateRange.upperBound),
                "rule": PhotoClustering.ruleVersion,
                "booking_start": iso.string(from: booking.start),
                "booking_end": iso.string(from: booking.end),
                "clusters": clusterMapping.clusters.map { cluster -> [String: Any] in
                    ["start": iso.string(from: cluster.start), "end": iso.string(from: cluster.end), "count": cluster.count]
                }
            ]
            if let corrected = corrections[mapping.eventTitle] {
                entry["latitude"] = corrected.latitude
                entry["longitude"] = corrected.longitude
                entry["corrected"] = true
            }
            return entry
        }
    }

    /// Loggar klustringen: ett beslut per kluster (tid, antal bilder, bokning, överlapp).
    private func logClusterMatch(_ match: PhotoClusterMatch) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let short = DateFormatter()
        short.dateFormat = "HH:mm"
        let result = match.result
        state.appendStepLog(.findCalendarInfo,
            "\(match.bookings.count) bokningar, \(result.assignments.count) tidskluster (ny adress vid lucka > \(Int(result.gapThreshold / 60)) min)")
        for skipped in match.skippedEvents {
            state.appendStepLog(.findCalendarInfo, "Ingen bokning: \(skipped)", type: .info)
        }
        for assignment in result.assignments {
            let cluster = assignment.cluster
            let span = "\(fmt.string(from: cluster.start))–\(fmt.string(from: cluster.end)) (\(cluster.count) bilder)"
            var details: [String: String] = [
                "start": ISO8601DateFormatter().string(from: cluster.start),
                "end": ISO8601DateFormatter().string(from: cluster.end),
                "count": "\(cluster.count)", "reason": assignment.reason
            ]
            if let index = assignment.bookingIndex {
                let booking = match.bookings[index]
                details["booking"] = booking.address
                details["strictOverlap"] = "\(assignment.strictOverlap)"
                details["marginOverlap"] = "\(assignment.marginOverlap)"
                state.appendStepLog(.findCalendarInfo,
                    "Kluster \(span) → \"\(booking.address)\" (bokning \(short.string(from: booking.start))–\(short.string(from: booking.end)); "
                    + "\(assignment.strictOverlap) inom bokningen, \(assignment.marginOverlap) inom ±\(Int(PhotoClustering.Parameters.standard.bookingMargin / 60)) min; \(assignment.reason))",
                    type: .success)
            } else {
                state.appendStepLog(.findCalendarInfo, "Kluster \(span) → Osorterade (\(assignment.reason))", type: .warning)
            }
            logDecision(step: "calendar_cluster", decision: assignment.bookingIndex == nil ? "unsorted" : "matched", details: details)
        }
    }

    /// Läser in sparade matchningar (`calendar_matches.json`) i `calendarMappings`/adresslistan och
    /// geokodar adresserna för GPS-statusen. Används när matchningen redan är gjord, och som reserv
    /// när en ny matchning inte går att göra (ingen kalenderåtkomst).
    func applySavedCalendarMatches(_ savedJSON: [[String: Any]]) async {
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
        for mapping in calendarMappings {
            state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle)", type: .success)
        }
        // Geocode cached addresses to show GPS status — skip any address with a
        // saved manual correction, using its corrected coordinate instead.
        // Ingen kalenderåtkomst behövs här (matchningarna kommer från filen och
        // geokodningen går via MapKit) — förut begärdes den ändå, vilket kunde
        // visa en onödig dialog och fick photoflow-cli att krascha.
        let calendar = CalendarService.shared
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
    }
}
