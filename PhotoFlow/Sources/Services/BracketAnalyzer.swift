import Foundation

/// Parameters that control how `BracketAnalyzer` groups photos, mirrored 1:1
/// from `AppSettings.maxTimeGap`/`minBracketSize` and stored back into
/// `bracket_groups.json`'s `"params"` field so a settings change is detected
/// on the next run (see `PipelineRunner.runBracketAnalysis`).
struct BracketAnalysisParams: Codable, Sendable, Equatable {
    var maxTimeGap: Int
    var minBracketSize: Int

    enum CodingKeys: String, CodingKey {
        case maxTimeGap = "max_time_gap"
        case minBracketSize = "min_bracket_size"
    }
}

/// One bracket (or single-photo) group, in exactly the shape
/// `bracket_groups.json` has always used — old sessions' JSON must stay
/// readable by `PipelineRunner.loadBracketGroups`/`matchCalendarBookings`/
/// `runHDRMerge`, so the key names below are not just style, they're a file
/// format contract.
struct BracketGroupResult: Codable, Sendable, Equatable {
    var groupId: Int
    var isBracket: Bool
    var imageCount: Int
    var files: [String]
    var exposures: [String]
    var fnumber: Double
    var iso: Int
    var timeStart: String
    var timeEnd: String
    var dateStart: String
    var dateEnd: String
    /// Per-file capture time, same order as `files`. Older JSON written before
    /// this field existed simply doesn't have it — readers fall back to
    /// `dateStart` for every photo (see `loadBracketGroups`).
    var datetimes: [String]
    var exposureRangeStops: Double
    var suggestedHDRIndices: [Int]
    var uniqueExposureLevels: Int

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case isBracket = "is_bracket"
        case imageCount = "image_count"
        case files, exposures, fnumber, iso
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case dateStart = "date_start"
        case dateEnd = "date_end"
        case datetimes
        case exposureRangeStops = "exposure_range_stops"
        case suggestedHDRIndices = "suggested_hdr_indices"
        case uniqueExposureLevels = "unique_exposure_levels"
    }
}

/// Top-level `bracket_groups.json` contents.
struct BracketAnalysisOutput: Codable, Sendable, Equatable {
    var totalImages: Int
    var totalGroups: Int
    var groups: [BracketGroupResult]
    var params: BracketAnalysisParams
    var bracketGroupsCount: Int
    var singleGroupsCount: Int

    enum CodingKeys: String, CodingKey {
        case totalImages = "total_images"
        case totalGroups = "total_groups"
        case groups, params
        case bracketGroupsCount = "bracket_groups_count"
        case singleGroupsCount = "single_groups_count"
    }
}

/// Pure, testable port of the bracket-detection algorithm that used to live in
/// the embedded Python script `PipelineRunner.bracketAnalysisPython()`
/// (removed — see FORBATTRINGAR.md "Fas 2a"). Same three phases, same
/// thresholds, same output shape.
enum BracketAnalyzer {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// exposure value in stops (log2 seconds) — 0 for a non-positive exposure,
    /// same guard the Python `ev()` helper had.
    private static func ev(_ exposureSeconds: Double) -> Double {
        exposureSeconds <= 0 ? 0 : log2(exposureSeconds)
    }

    static func analyze(records: [ExifRecord], params: BracketAnalysisParams) -> BracketAnalysisOutput {
        // Sort by filename — the old script did this after reading the CSV,
        // and downstream logic (grouping, group_id ordering) depends on it.
        let images = records.sorted { $0.filename < $1.filename }

        let rawGroups = phase1GroupByTimeAndSettings(images, maxTimeGap: Double(params.maxTimeGap))
        var groups: [[ExifRecord]] = []
        for raw in rawGroups {
            groups.append(contentsOf: findBracketSubsequences(raw))
        }

        var results: [BracketGroupResult] = []
        results.reserveCapacity(groups.count)
        for (i, group) in groups.enumerated() {
            results.append(classify(group: group, groupId: i + 1, minBracketSize: params.minBracketSize))
        }

        let bracketCount = results.filter(\.isBracket).count
        return BracketAnalysisOutput(
            totalImages: images.count,
            totalGroups: groups.count,
            groups: results,
            params: params,
            bracketGroupsCount: bracketCount,
            singleGroupsCount: results.count - bracketCount
        )
    }

    // MARK: - Phase 1: group by time proximity + same aperture/ISO

    private static func phase1GroupByTimeAndSettings(_ images: [ExifRecord], maxTimeGap: Double) -> [[ExifRecord]] {
        guard !images.isEmpty else { return [] }
        var rawGroups: [[ExifRecord]] = []
        var current: [ExifRecord] = [images[0]]
        for i in 1..<images.count {
            let previous = images[i - 1]
            let candidate = images[i]
            let timeDelta = candidate.preciseTimestamp - previous.preciseTimestamp
            let sameSettings = candidate.fNumber == previous.fNumber && candidate.iso == previous.iso
            if timeDelta <= maxTimeGap && sameSettings {
                current.append(candidate)
            } else {
                rawGroups.append(current)
                current = [candidate]
            }
        }
        rawGroups.append(current)
        return rawGroups
    }

    // MARK: - Phase 2: split groups containing multiple bracket sub-sequences

    private static func findBracketSubsequences(_ group: [ExifRecord]) -> [[ExifRecord]] {
        guard group.count > 3 else { return [group] }
        let evs = group.map { ev($0.exposureSeconds) }
        let n = group.count

        // A gap >6s within the group suggests a new bracket take.
        var subSeqs: [[Int]] = []
        var currentSeq = [0]
        for i in 1..<n {
            let gap = group[i].preciseTimestamp - group[i - 1].preciseTimestamp
            if gap > 6.0 {
                subSeqs.append(currentSeq)
                currentSeq = [i]
            } else {
                currentSeq.append(i)
            }
        }
        subSeqs.append(currentSeq)

        if subSeqs.count > 1 {
            return subSeqs.map { seq in seq.map { group[$0] } }
        }

        // Look for repeating bracket patterns (e.g. 3+3, or 3+3+extra).
        for patLen in [3, 4, 5] {
            guard n >= patLen * 2 && n <= patLen * 2 + 2 else { continue }
            let firstEvs = Array(evs[0..<patLen]).sorted()
            let secondEvs = Array(evs[patLen..<(patLen * 2)]).sorted()
            guard secondEvs.count >= patLen else { continue }
            let spread1 = firstEvs.last! - firstEvs.first!
            let spread2 = secondEvs.last! - secondEvs.first!
            if spread1 > 1.0 && spread2 > 1.0 && abs(spread1 - spread2) < 2.0 {
                var result = [Array(group[0..<patLen]), Array(group[patLen..<(patLen * 2)])]
                if n > patLen * 2 {
                    result.append(Array(group[(patLen * 2)...]))
                }
                return result
            }
        }

        return [group]
    }

    // MARK: - Phase 3: classify + find optimal HDR subset

    /// Removes duplicate exposures (keeping the first of each unique EV level,
    /// within 0.3 stops), sorts ascending by exposure, and optionally drops the
    /// darkest frame if it's much darker than the median — dark frames pull an
    /// HDR merge down too much. Returns original-group indices, in the
    /// ascending-exposure order the Python script produced (not necessarily
    /// the group's original file order).
    private static func findBestHDRSubset(_ group: [ExifRecord], minBracketSize: Int) -> [Int] {
        let exps = group.enumerated().map { (idx: $0.offset, exposure: $0.element.exposureSeconds) }
        guard exps.count > 1 else { return Array(0..<group.count) }

        var unique: [(idx: Int, exposure: Double)] = []
        for (idx, exposure) in exps {
            let evVal = ev(exposure)
            let isDup = unique.contains { abs(ev($0.exposure) - evVal) < 0.3 }
            if !isDup {
                unique.append((idx, exposure))
            }
        }

        unique.sort { $0.exposure < $1.exposure }

        if unique.count >= 3 {
            let evsSorted = unique.map { ev($0.exposure) }
            let medianEV = evsSorted[evsSorted.count / 2]
            let darkestEV = evsSorted[0]
            if (medianEV - darkestEV) > 2.5 {
                unique.removeFirst()
            }
        }

        return unique.map(\.idx)
    }

    private static func classify(group: [ExifRecord], groupId: Int, minBracketSize: Int) -> BracketGroupResult {
        let exps = group.map(\.exposureSeconds)
        let minExp = exps.min() ?? 0
        let maxExp = exps.max() ?? 0
        let exposureRange = minExp > 0 ? maxExp / max(minExp, 0.0001) : 0

        var uniqueEVs = Set<Double>()
        for exp in exps {
            uniqueEVs.insert((ev(exp) * 3).rounded(.toNearestOrEven) / 3)
        }

        let hasEnoughUnique = uniqueEVs.count >= minBracketSize
        let hasRange = exposureRange > 2.0
        let isBracket = hasEnoughUnique && hasRange

        let hdrIndices = isBracket ? findBestHDRSubset(group, minBracketSize: minBracketSize) : []

        let files = group.map { record -> String in
            let base = record.filename.contains(".")
                ? String(record.filename[..<record.filename.lastIndex(of: ".")!])
                : record.filename
            return base + ".NEF"
        }

        return BracketGroupResult(
            groupId: groupId,
            isBracket: isBracket,
            imageCount: group.count,
            files: files,
            exposures: group.map(\.exposureTime),
            fnumber: group[0].fNumber,
            iso: group[0].iso,
            timeStart: timeFormatter.string(from: group[0].dateTimeOriginal),
            timeEnd: timeFormatter.string(from: group[group.count - 1].dateTimeOriginal),
            dateStart: dateFormatter.string(from: group[0].dateTimeOriginal),
            dateEnd: dateFormatter.string(from: group[group.count - 1].dateTimeOriginal),
            datetimes: group.map { dateFormatter.string(from: $0.dateTimeOriginal) },
            // Python's `round()` uses round-half-to-even (banker's rounding),
            // not round-half-away-from-zero — verified this matters in
            // practice: 29 of ~2250 real groups (scratchpad session, lint/INPUT
            // test data) landed exactly on a .x5 boundary after *10 and would
            // otherwise round to X.3 instead of the Python script's X.2.
            exposureRangeStops: (exposureRange * 10).rounded(.toNearestOrEven) / 10,
            suggestedHDRIndices: hdrIndices,
            uniqueExposureLevels: uniqueEVs.count
        )
    }
}
