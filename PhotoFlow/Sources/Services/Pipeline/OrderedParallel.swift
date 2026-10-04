import Foundation

/// Fas 1c: kör oberoende jobb samtidigt men lämnar resultaten **i jobbens ordning**, så att allt
/// som händer efter ett jobb (loggrader, stämplar, `enhancement.json`, räknare) blir exakt som
/// vid seriell körning. Bara själva arbetet (`work`) körs samtidigt; `prepare` och `finish` körs
/// på anroparens aktör (MainActor), en i taget.
///
/// - Taket (`limit`) läses om före varje ny start, så att minnestryck kan sänka det mitt i steget.
///   Pågående jobb får alltid bli klara.
/// - Högst `window` jobb ligger mellan det äldsta ofärdiga och det senast startade, så att ett
///   långsamt jobb inte gör att färdiga resultat hopar sig.
/// - `gate` anropas före varje start (paus/avbrott, `checkCancellationAndWaitIfPaused`). Är
///   körningen pausad (`isPaused`) och något jobb pågår väntar vi in det i stället, så att dess
///   resultat hinner lämnas innan pausen.
/// - Avbrott eller fel i `finish`: inga nya jobb startas, pågående avbryts och väntas in, och de
///   som hann bli klara lämnas till `finish` (i ordning) innan felet kastas vidare — så att färdigt
///   arbete inte görs om nästa gång.
/// - Ett fel i ett jobb (annat än avbrott) avbryter inte de andra; det lämnas som `.failure`.
@MainActor
enum OrderedParallel {
    static func run<T: Sendable>(
        count: Int,
        limit: () -> Int,
        window: Int? = nil,
        gate: () async throws -> Void,
        isPaused: () -> Bool = { false },
        prepare: (Int) async throws -> @Sendable () async throws -> T,
        finish: (Int, Result<T, Error>) async throws -> Void
    ) async throws {
        guard count > 0 else { return }
        try await withThrowingTaskGroup(of: (Int, Result<T, Error>).self) { group in
            var next = 0
            var running = 0
            var emitIndex = 0
            var buffered: [Int: Result<T, Error>] = [:]

            func emitReady() async throws {
                while let result = buffered.removeValue(forKey: emitIndex) {
                    let index = emitIndex
                    emitIndex += 1
                    if case .failure(let error) = result, error is CancellationError { throw CancellationError() }
                    try await finish(index, result)
                }
            }

            do {
                while true {
                    while next < count {
                        let currentLimit = max(1, limit())
                        let currentWindow = max(currentLimit, window ?? currentLimit * 2)
                        guard running < currentLimit, next - emitIndex < currentWindow else { break }
                        if running > 0 && isPaused() { break }
                        try await gate()
                        let index = next
                        next += 1
                        let work = try await prepare(index)
                        running += 1
                        group.addTask {
                            do {
                                return (index, .success(try await work()))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }
                    guard let (index, result) = try await group.next() else { break }
                    running -= 1
                    buffered[index] = result
                    try await emitReady()
                }
            } catch {
                group.cancelAll()
                // Jobben kastar aldrig (fel blir `.failure`), så `next()` ger nil först när alla är klara.
                while let item = try? await group.next() {
                    buffered[item.0] = item.1
                }
                for index in buffered.keys.sorted() {
                    guard let result = buffered[index] else { continue }
                    if case .failure(let failure) = result, failure is CancellationError { continue }
                    try? await finish(index, result)
                }
                throw error
            }
        }
    }
}

/// Resultatet av en HDR-grupp i `runHDRMerge` (lämnas till `finish` i gruppordning).
nonisolated struct HDRGroupOutcome: Sendable {
    var metadata: (tiff: IPTCFileMetadata?, jpeg: IPTCFileMetadata?)
    var metadataWritten: Bool
    var seconds: Double
}

/// Resultatet av en förbättring i `runEnhancePhotos`.
nonisolated struct EnhanceJobOutcome: Sendable {
    var outcome: EnhancementEngine.Outcome
    var seconds: Double
}
