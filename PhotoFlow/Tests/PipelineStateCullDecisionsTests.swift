import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the single-source-of-truth fix: `PipelineState.allPhotos` used to be
/// duplicated inside `BracketGroup.photos`, so a decision made in BracketReviewView
/// (which only edited the group's copy) could be invisible to PreviewCullView/
/// `saveCullDecisions` (which only read `allPhotos`), and vice versa. `BracketGroup`
/// now only stores `photoIDs`; `PipelineState.photos(in:)` resolves them from
/// `allPhotos`, and `setDecision`/`setAlgorithmSuggested` are the only way to change
/// a decision.
@MainActor
struct PipelineStateCullDecisionsTests {

    private func makePhoto(id: String) -> PhotoItem {
        PhotoItem(
            id: id,
            filename: "\(id).NEF",
            nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
            dngURL: nil,
            previewURL: nil,
            exposureTime: "1/125",
            exposureSeconds: 1.0 / 125.0,
            fNumber: 8.0,
            iso: 100,
            dateTime: Date()
        )
    }

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineStateCullDecisionsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("photos(in:) löser upp photoIDs från allPhotos i gruppens ordning")
    func photosInGroup_resolvesFromAllPhotos() {
        let state = PipelineState()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b"), makePhoto(id: "c")]
        let group = BracketGroup(
            id: 1, isBracket: true, folderName: "bracket_001",
            photoIDs: ["c", "a"], fNumber: 8, iso: 100,
            timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 2
        )
        let resolved = state.photos(in: group)
        #expect(resolved.map(\.id) == ["c", "a"])
    }

    @Test("Beslut satt via grupp (setDecision) syns direkt i allPhotos")
    func setDecision_viaGroup_isVisibleInAllPhotos() {
        let state = PipelineState()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b")]
        let group = BracketGroup(
            id: 1, isBracket: true, folderName: "bracket_001",
            photoIDs: ["a", "b"], fNumber: 8, iso: 100,
            timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 2
        )

        // Simulates what BracketReviewView does: resolve the photo through the
        // group, then set the decision by ID.
        let photo = state.photos(in: group)[0]
        state.setDecision(photoID: photo.id, accepted: true, rejected: false)

        #expect(state.allPhotos[0].accepted == true)
        #expect(state.photos(in: group)[0].accepted == true)
        #expect(state.selectedCount(in: group) == 1)
        #expect(state.allReviewed(group) == false)

        state.setDecision(photoID: "b", accepted: false, rejected: true)
        #expect(state.allReviewed(group) == true)
    }

    @Test("saveCullDecisions/loadCullDecisions gör en rundtripp via allPhotos")
    func saveCullDecisions_roundTripsThroughAllPhotos() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [makePhoto(id: "x"), makePhoto(id: "y"), makePhoto(id: "z")]
        state.setDecision(photoID: "x", accepted: true, rejected: false)
        state.setDecision(photoID: "y", accepted: false, rejected: true)
        // "z" stays undecided.

        // Fas 10: saveCullDecisions() debouncar den faktiska diskskrivningen
        // (1s), så ett synkront test måste anropa flushCullDecisions() i
        // stället för att invänta timern — se PipelineState.swift's doc-
        // kommentar för `saveCullDecisions()`/`flushCullDecisions()`.
        state.saveCullDecisions()
        state.flushCullDecisions()
        let loaded = state.loadCullDecisions()

        #expect(loaded["x"] == "accepted")
        #expect(loaded["y"] == "rejected")
        #expect(loaded["z"] == nil)
    }

    @Test("flushCullDecisions() garanterar besluten på disk även om debounce-timern inte hunnit löpa ut")
    func flushCullDecisions_persistsBeforeDebounceTimerFires() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b")]

        // Simulerar "gallring klar"-vägen: ett beslut, sedan omedelbart flush
        // (PreviewCullView.performFinishCulling gör precis detta) — INGEN
        // väntan alls, så om debouncen fortfarande gällde skulle filen vara
        // tom/saknas.
        state.setDecision(photoID: "a", accepted: true, rejected: false)
        state.saveCullDecisions()
        state.flushCullDecisions()

        let loaded = state.loadCullDecisions()
        #expect(loaded["a"] == "accepted")
        #expect(loaded["b"] == nil)
    }

    @Test("clearAllCullDecisions() avbryter en väntande debounced skrivning — den får inte återuppstå på disk efteråt")
    func clearAllCullDecisions_cancelsPendingDebouncedWrite() async throws {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b")]

        // Ett beslut schemalägger en debounced skrivning (1s) av
        // ["a": "accepted"] — sedan raderas ALL granskningsdata innan den
        // hinner löpa ut (samma ordning som "Radera all granskningsdata" i
        // DashboardView: användaren hinner gallra lite, ångrar sig helt).
        state.setDecision(photoID: "a", accepted: true, rejected: false)
        state.saveCullDecisions()
        state.clearAllCullDecisions()

        // Vänta längre än debounce-fönstret (1s) — om den gamla schemalagda
        // skrivningen INTE avbrutits hade den nu skrivit tillbaka
        // ["a": "accepted"] till disk, vilket vore dataförlust i motsatt
        // riktning (ett raderat beslut som återuppstår).
        try await Task.sleep(nanoseconds: 1_300_000_000)

        let loaded = state.loadCullDecisions()
        #expect(loaded.isEmpty)
    }

    @Test("setAlgorithmSuggested ändrar bara den angivna bilden")
    func setAlgorithmSuggested_onlyAffectsTargetPhoto() {
        let state = PipelineState()
        var a = makePhoto(id: "a")
        a.algorithmSuggested = true
        state.allPhotos = [a, makePhoto(id: "b")]

        state.setAlgorithmSuggested(photoID: "a", suggested: false)

        #expect(state.allPhotos[0].algorithmSuggested == false)
        #expect(state.allPhotos[1].algorithmSuggested == false)
    }

    // MARK: - Cachade räknare (Fas 10): måste alltid stämma med allPhotos
    //
    // "En cachad räknare som glider isär från sanningen är värre än en
    // långsam" — dessa testar acceptedCount/rejectedCount/unreviewedCount mot
    // ett facit räknat direkt från allPhotos, efter varje typ av mutation som
    // rör beslut: enskilda beslut, massändring ("Föreslå gallring"), ångra,
    // clearAllCullDecisions och en simulerad sessionsomladdning.

    private func expectCountsMatchAllPhotos(_ state: PipelineState, sourceLocation: SourceLocation = #_sourceLocation) {
        let accepted = state.allPhotos.filter(\.accepted).count
        let rejected = state.allPhotos.filter(\.rejected).count
        let unreviewed = state.allPhotos.filter { !$0.accepted && !$0.rejected }.count
        #expect(state.acceptedCount == accepted, sourceLocation: sourceLocation)
        #expect(state.rejectedCount == rejected, sourceLocation: sourceLocation)
        #expect(state.unreviewedCount == unreviewed, sourceLocation: sourceLocation)
    }

    @Test("acceptedCount/rejectedCount/unreviewedCount stämmer efter enskilda beslut")
    func cachedCounts_matchAfterIndividualDecisions() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(10)
        expectCountsMatchAllPhotos(state)

        state.setDecision(photoID: "IMG_0", accepted: true, rejected: false)
        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 1)

        state.setDecision(photoID: "IMG_1", accepted: false, rejected: true)
        expectCountsMatchAllPhotos(state)
        #expect(state.rejectedCount == 1)
        #expect(state.unreviewedCount == 8)

        // Byter beslut på en redan avgjord bild (accepterad -> avvisad) —
        // räknarna ska flytta med, inte bara öka.
        state.setDecision(photoID: "IMG_0", accepted: false, rejected: true)
        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 0)
        #expect(state.rejectedCount == 2)

        // Ett no-op-anrop (samma beslut igen) ska inte rubba räknarna.
        state.setDecision(photoID: "IMG_0", accepted: false, rejected: true)
        expectCountsMatchAllPhotos(state)
        #expect(state.rejectedCount == 2)
    }

    @Test("acceptedCount/rejectedCount stämmer efter en massändring (motsvarar \"Föreslå gallring\")")
    func cachedCounts_matchAfterBatchChange() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(20)

        // suggestCulling() i PreviewCullView gör precis detta: en loop av
        // setDecision-anrop för flera foton i en enda användaråtgärd.
        for i in 0..<8 {
            state.setDecision(photoID: "IMG_\(i)", accepted: false, rejected: true)
        }
        expectCountsMatchAllPhotos(state)
        #expect(state.rejectedCount == 8)
        #expect(state.unreviewedCount == 12)
    }

    @Test("acceptedCount/rejectedCount stämmer efter ångra (setDecision tillbaka till tidigare värde)")
    func cachedCounts_matchAfterUndo() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(5)

        // Görs, ångras (samma väg som PreviewCullView.performUndo).
        state.setDecision(photoID: "IMG_0", accepted: true, rejected: false)
        state.setDecision(photoID: "IMG_1", accepted: false, rejected: true)
        expectCountsMatchAllPhotos(state)

        state.setDecision(photoID: "IMG_0", accepted: false, rejected: false)
        state.setDecision(photoID: "IMG_1", accepted: false, rejected: false)
        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 0)
        #expect(state.rejectedCount == 0)
        #expect(state.unreviewedCount == 5)
    }

    @Test("clearAllCullDecisions() nollställer räknarna och matchar allPhotos")
    func cachedCounts_matchAfterClearAllCullDecisions() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(10)
        for i in 0..<10 {
            state.setDecision(photoID: "IMG_\(i)", accepted: i % 2 == 0, rejected: i % 2 != 0)
        }
        #expect(state.acceptedCount == 5)
        #expect(state.rejectedCount == 5)

        state.clearAllCullDecisions()

        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 0)
        #expect(state.rejectedCount == 0)
        #expect(state.unreviewedCount == 10)
        #expect(state.allPhotos.allSatisfy { !$0.accepted && !$0.rejected })
    }

    @Test("Räknarna byggs om korrekt när en session laddas om (allPhotos ersätts helt)")
    func cachedCounts_matchAfterSimulatedSessionReload() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(5)
        state.setDecision(photoID: "IMG_0", accepted: true, rejected: false)
        #expect(state.acceptedCount == 1)

        // Simulerar PipelineRunner+LoadSession: reset() (allPhotos = []) följt
        // av en helt ny `allPhotos`-tilldelning (t.ex. inläst från
        // bracket_groups.json/cull_decisions.json på disk) — annat
        // fotoinnehåll, andra beslut.
        state.reset()
        #expect(state.acceptedCount == 0)
        #expect(state.rejectedCount == 0)

        var reloaded = makeSyntheticPhotos(7)
        reloaded[0].accepted = true
        reloaded[1].rejected = true
        reloaded[2].rejected = true
        state.allPhotos = reloaded

        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 1)
        #expect(state.rejectedCount == 2)
        #expect(state.unreviewedCount == 4)

        // Och index/räknare fortsätter fungera för nya beslut efter omladdningen.
        state.setDecision(photoID: "IMG_3", accepted: true, rejected: false)
        expectCountsMatchAllPhotos(state)
        #expect(state.acceptedCount == 2)
    }

    // MARK: - Prestanda vid stora sessioner (2000+ bilder), se FORBATTRINGAR.md
    //
    // Dessa körs som vanliga tester (så en framtida O(n²)-regression fångas av
    // `#expect`-gränserna nedan), men det som faktiskt dokumenterades i
    // FORBATTRINGAR.md är siffrorna i `print`-utskrifterna — körda med
    // `xcodebuild test -only-testing:PhotoFlowTests/PipelineStateCullDecisionsTests`
    // (utan grep-filtret i agent-rules.md, annars försvinner utskrifterna) både
    // FÖRE och EFTER Fas 10s ändringar. Generösa gränser med flit — poängen är
    // att fånga en algoritmisk regression (ms → sekunder), inte mäta exakt.

    private func makeSyntheticPhotos(_ count: Int) -> [PhotoItem] {
        (0..<count).map { i in
            PhotoItem(
                id: "IMG_\(i)",
                filename: "IMG_\(String(format: "%05d", i)).NEF",
                nefURL: URL(fileURLWithPath: "/tmp/perf/IMG_\(i).NEF"),
                dngURL: nil,
                previewURL: nil,
                exposureTime: "1/125",
                exposureSeconds: 1.0 / 125.0,
                fNumber: 8.0,
                iso: 100,
                dateTime: Date()
            )
        }
    }

    @Test("PERF: 2000 sekventiella setDecision-anrop (fångar en O(n²)-regression i photoIndexByID-ombyggnaden)")
    func perf_manyDecisions_2000Photos() {
        let state = PipelineState()
        state.allPhotos = makeSyntheticPhotos(2000)
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for photo in state.allPhotos {
                state.setDecision(photoID: photo.id, accepted: true, rejected: false)
            }
        }
        print("PERF setDecision x2000 (alla accepterade): \(elapsed)")
        #expect(state.allPhotos.allSatisfy { $0.accepted })
        // Genrös gräns — verkligt "före"-läge (O(n²) omindexering per anrop)
        // uppmättes till ~0.3–0.6s på utvecklarmaskinen; 100x det är fortfarande
        // långt under vad en riktig regression skulle ge.
        #expect(elapsed < .seconds(5))
    }

    @Test("PERF: de tre räknarna (allPhotos.filter { ... }.count) över 2000 bilder, 200 upprepningar (simulerar 200 omritningar)")
    func perf_threeCounters_repeatedOverRedraws() {
        var photos = makeSyntheticPhotos(2000)
        for i in photos.indices {
            if i % 3 == 0 { photos[i].accepted = true }
            else if i % 3 == 1 { photos[i].rejected = true }
        }
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<200 {
                let accepted = photos.filter { $0.accepted }.count
                let rejected = photos.filter { $0.rejected }.count
                let unreviewed = photos.filter { !$0.accepted && !$0.rejected }.count
                #expect(accepted + rejected + unreviewed == photos.count)
            }
        }
        print("PERF tre räknare (gamla mönstret) x200 omritningar över 2000 bilder: \(elapsed)")
        #expect(elapsed < .seconds(5))
    }

    @Test("PERF: saveCullDecisions() (JSON-serialisering av hela beslutsordboken) för 2000 bilder")
    func perf_saveCullDecisions_2000Photos() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = makeSyntheticPhotos(2000)
        for photo in state.allPhotos {
            state.setDecision(photoID: photo.id, accepted: true, rejected: false)
        }
        let clock = ContinuousClock()

        // 50 "snabba" anrop i rad — simulerar 50 tangenttryck utan paus, det
        // värsta scenariot debounce ska lösa.
        let elapsed = clock.measure {
            for _ in 0..<50 {
                state.saveCullDecisions()
            }
        }
        print("PERF saveCullDecisions() x50 (2000 beslutade bilder): \(elapsed)")
        #expect(elapsed < .seconds(10))
    }

    @Test("PERF: filtrering+sortering av filmremsans innehåll (2000 bilder, filnamnsordning)")
    func perf_filmstripFilterSort_2000Photos() {
        let photos = makeSyntheticPhotos(2000)
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            let indexed = photos.enumerated().map { (index: $0.offset, photo: $0.element) }
            let filtered = indexed.filter { _ in true } // motsvarar `.all`-filtret
            _ = filtered.sorted { $0.photo.filename.localizedStandardCompare($1.photo.filename) == .orderedAscending }
        }
        print("PERF filteredIndexedPhotos-motsvarighet (filter+sortering) över 2000 bilder: \(elapsed)")
        #expect(elapsed < .seconds(2))
    }
}
