import Foundation

/// Släpper igenom en förloppsuppdatering per tiondel, så att renderingens bildruteanrop (från en
/// bakgrundstråd) inte skapar en huvudtrådsuppgift per ruta.
nonisolated private final class ReelProposalProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func pass(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value > last else { return false }
        last = value
        return true
    }
}

extension PipelineRunner {
    // MARK: - Steg: Filmförslag
    //
    // Körs sist, efter "Skriv metadata": då är bildfilerna i sitt slutliga skick, så specens
    // `sha256` per bild stämmer med filerna som ligger kvar (metadatasteget skriver EXIF/GPS i
    // FÖRBÄTTRADE/TITTBILDER på plats och ändrar därmed filernas hash). Själva beslutet "är
    // förslaget aktuellt?" beror inte på metadatasteget — se `ReelProposal.fingerprint`, som
    // identifierar bilderna via original-NEF:er och förbättringsloggen i stället för filstorlek.
    // Adresserna är kända sedan sorteringen. Steget rör aldrig en film som användaren redigerat
    // eller skickat (se `ReelProposal.inspectExisting`).

    /// Adressmapparna: varje kalendermatchad adress (samma mappnamn som sorteringen ger), aldrig "Osorterade".
    func reelProposalFolders() -> [String] {
        var folders: [String] = []
        for mapping in calendarMappings {
            let folder = CalendarService.sanitizeFolderName(mapping.address)
            guard !folder.isEmpty, folder != "Osorterade", !folders.contains(folder) else { continue }
            folders.append(folder)
        }
        return folders
    }

    /// Kör steget. Returnerar antalet adresser som nu har ett aktuellt förslag (byggda + redan klara).
    /// `force`: bygg om även när fingerprintet stämmer (manuell omkörning); skyddet gäller alltid.
    @discardableResult
    func runReelProposals(force: Bool = false) async throws -> Int {
        guard let outputDir = state.outputDirectory else { return 0 }
        let step = DashboardStep.reelProposal
        state.currentStep = .proposingReel

        let folders = reelProposalFolders()
        guard !folders.isEmpty else {
            state.markStepUntimed(step)
            logDecision(step: "reel_proposal", decision: "skipped", details: ["reason": "no_addresses"])
            state.appendStepLog(step, "Inga kalendermatchade adresser — inga filmförslag", type: .info)
            state.appendLog("Filmförslag: inga adresser.", type: .info)
            return 0
        }

        state.statusMessage = "Filmförslag: kontrollerar \(folders.count) adresser..."
        state.updateStepProgress(step, processed: 0, total: folders.count)
        let existing = await ReelProposal.loadExistingData(outputDir: outputDir)
        var plans: [ReelProposal.Plan] = []
        for folder in folders {
            try await checkCancellationAndWaitIfPaused()
            plans.append(await ReelProposal.plan(outputDir: outputDir, folderName: folder, existing: existing, force: force))
        }
        state.setPendingFingerprint(
            SessionManifestStore.fingerprint(fileURLs: [], settings: [
                "reel": plans.map { "\($0.folderName)=\($0.fingerprint)" }.joined(separator: ";"),
                "engine": "\(ReelProposal.engineVersion)",
            ]),
            for: step
        )

        // Foundation Models bara när bildbeskrivningar är på; annars räcker taggarna och analysen.
        let describe = AppSettings.shared.aiDescriptionsEnabled
        var built = 0, skipped = 0, current = 0, failed = 0, protectedCount = 0
        state.totalFiles = plans.count
        state.currentFileIndex = 0
        state.progress = 0
        state.appendStepLog(step, "Filmförslag för \(plans.count) adresser")

        for (index, plan) in plans.enumerated() {
            try await checkCancellationAndWaitIfPaused()
            state.currentFileIndex = index
            let name = plan.folderName
            switch plan.action {
            case .skip(let reason, let isProtected):
                skipped += 1
                if isProtected {
                    protectedCount += 1
                    state.appendStepLog(step, "\(name): \(reason)", type: .warning)
                } else {
                    // En redan aktuell film räknas som klar; "för få bilder" gör det inte.
                    if plan.source != nil { current += 1 }
                    state.appendStepLog(step, "\(name): hoppar över — \(reason)", type: .info)
                }
            case .build(let reason):
                guard let source = plan.source else { continue }
                state.statusMessage = "Filmförslag: \(name) (\(index + 1)/\(plans.count))..."
                state.appendStepLog(step, "\(name): källa \(source.kind.label) (\(source.files.count) bilder) — \(reason)")
                let gate = ReelProposalProgressGate()
                do {
                    let result = try await ReelProposal.build(
                        source: source, outputDir: outputDir, filmDir: plan.filmDir, folderName: name,
                        existing: existing, fingerprint: plan.fingerprint, describe: describe
                    ) { [weak self] stage in
                        switch stage {
                        case .analyzing(let done, let total):
                            guard gate.pass(done * 100 / max(total, 1) / 10) else { return }
                            Task { @MainActor in self?.state.statusMessage = "Filmförslag: \(name) — analys \(done)/\(total)" }
                        case .rendering(let fraction):
                            let pct = Int(fraction * 10) * 10
                            guard gate.pass(10 + pct / 10) else { return }
                            Task { @MainActor in self?.state.statusMessage = "Filmförslag: \(name) — rendering \(pct) %" }
                        }
                    }
                    built += 1
                    for pick in result.picks {
                        state.appendStepLog(step, "   \(pick.slot): \(pick.file) — \(pick.reason)")
                    }
                    if result.mergedDuplicates > 0 {
                        state.appendStepLog(step, "   \(result.mergedDuplicates) nästan-dubbletter sammanslagna (pipelinens kluster)")
                    }
                    state.appendStepLog(step,
                        "\(name): film \(String(format: "%.1f", result.duration)) s · analys \(StepTiming.formatExact(result.analysisSeconds)) "
                        + "(\(result.fromPipelineData) ur pipelinens data, \(result.measured) mätta) · rendering \(StepTiming.formatExact(result.renderSeconds)) "
                        + "· \(result.videoURL.lastPathComponent) \(String(format: "%.1f", Double(result.fileBytes) / 1_000_000)) MB",
                        type: .success)
                    pipelineLog("  Filmförslag \(name): \(source.kind.label), \(result.picks.count) bilder, \(String(format: "%.1f", result.duration)) s")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    state.appendStepLog(step, "\(name): misslyckades — \(error.localizedDescription)", type: .error)
                    pipelineLog("  Filmförslag \(name) misslyckades: \(error.localizedDescription)")
                }
            }
            state.progress = Double(index + 1) / Double(plans.count)
            state.updateStepProgress(step, processed: index + 1, total: plans.count)
        }

        state.progress = 1.0
        // Redan klara eller skyddade adresser gör att tiden inte säger något om stegets längd.
        if skipped > 0 || built == 0 { state.markStepUntimed(step) }
        let details = [
            "built": "\(built)", "upToDate": "\(current)", "protected": "\(protectedCount)",
            "skipped": "\(skipped)", "failed": "\(failed)", "addresses": "\(plans.count)",
        ]
        logDecision(step: "reel_proposal", decision: built == 0 && failed == 0 ? "skipped" : "done", details: details)
        let summary = "Filmförslag: \(built) skapade" + (current > 0 ? ", \(current) redan aktuella" : "")
            + (protectedCount > 0 ? ", \(protectedCount) orörda (redigerade/skickade)" : "")
            + (failed > 0 ? ", \(failed) misslyckades" : "")
        state.appendLog(summary + ".", type: failed == 0 ? .success : .warning)
        return built + current
    }
}
