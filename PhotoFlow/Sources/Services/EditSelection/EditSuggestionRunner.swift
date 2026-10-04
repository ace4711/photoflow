import Foundation
import ImageIO
import Vision

/// Kör det automatiska förslaget för en session: mäter förhandsbilderna (Vision
/// feature print, utanför MainActor) och kombinerar `EditGroupSuggester` och
/// `EditExposureSuggester` till poster för `EditSelection.applySuggestion`.
nonisolated enum EditSuggestionRunner {
    struct PhotoInput: Sendable, Equatable {
        var file: String
        var previewURL: URL?
        var seconds: Double
        var rejected: Bool
    }

    struct GroupInput: Sendable, Equatable {
        var id: Int
        var start: Date
        var end: Date
        /// I tagningsordning.
        var photos: [PhotoInput]
    }

    /// Förhandsbilden skalas till högst så här många pixlar innan feature print — samma
    /// storlek som i analysen som tröskeln kalibrerades på.
    static let featurePrintMaxPixels = 1024

    static func featurePrint(url: URL) async -> FeaturePrintObservation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: featurePrintMaxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return try? await GenerateImageFeaturePrintRequest().perform(on: cg)
    }

    /// Ren kombination: grupp-förslag via `distance` (index i `groups`) och exponeringsförslag
    /// per grupp. Ej föreslagna grupper får en avslagen post med exponeringsförslaget, så
    /// att "Skicka" (S) på dem bockar i förslaget.
    static func entries(groups: [GroupInput], distance: (Int, Int) -> Double?) -> (entries: [Int: EditSelection.Entry], result: EditGroupSuggester.Result) {
        let infos = groups.map {
            EditGroupSuggester.Group(id: $0.id, start: $0.start, end: $0.end,
                                     eligible: $0.photos.contains { !$0.rejected })
        }
        let result = EditGroupSuggester.suggest(infos, distance: distance)
        var out: [Int: EditSelection.Entry] = [:]
        for g in groups {
            let files = EditExposureSuggester.suggest(g.photos.map {
                .init(file: $0.file, seconds: $0.seconds, rejected: $0.rejected)
            })
            out[g.id] = EditSelection.Entry(send: result.selected.contains(g.id) && !files.isEmpty,
                                            files: files, isSuggestion: true)
        }
        return (out, result)
    }

    /// Mäter alla förhandsbilder (parallellt, högst `maxConcurrent`) och returnerar förslaget.
    /// Grupper utan mätbara bilder räknas som olika sina grannar.
    @concurrent
    static func suggest(groups: [GroupInput], maxConcurrent: Int = 4,
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> (entries: [Int: EditSelection.Entry], result: EditGroupSuggester.Result) {
        var jobs: [(group: Int, url: URL)] = []
        for (gi, g) in groups.enumerated() {
            for p in g.photos { if let u = p.previewURL { jobs.append((gi, u)) } }
        }
        var prints = [[FeaturePrintObservation]](repeating: [], count: groups.count)
        await withTaskGroup(of: (Int, FeaturePrintObservation?).self) { tg in
            var next = 0, done = 0
            func add() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                tg.addTask { (job.group, await featurePrint(url: job.url)) }
            }
            for _ in 0..<max(1, maxConcurrent) { add() }
            while let (gi, fp) = await tg.next() {
                if let fp { prints[gi].append(fp) }
                done += 1
                progress(done, jobs.count)
                if Task.isCancelled { tg.cancelAll(); break }
                add()
            }
        }
        return entries(groups: groups) { a, b in
            var best: Double?
            for x in prints[a] {
                for y in prints[b] {
                    if let d = try? x.distance(to: y), d < (best ?? .infinity) { best = d }
                }
            }
            return best
        }
    }
}
