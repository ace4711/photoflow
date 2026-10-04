import Foundation

extension PipelineRunner {
    // MARK: - Fas 1c: AI-taggning samtidigt med HDR
    //
    // AI-taggningen (Vision, Foundation Models, kvalitetsanalys — Neural Engine/GPU, läser bara
    // förhandsbilderna) och HDR (CIRAWFilter + fusion — processor/GPU, läser DNG/NEF) beror inte på
    // varandra [V, plan 1.2]: HDR:s metadata vid skapandet slår upp AI-taggar via `state.allPhotos`,
    // som är tom tills `loadBracketGroups` körs efter båda, och en HDR-fil heter aldrig som en bild.
    // Det som behöver AI-taggarna (bracket-grupperna i UI:t, Förbättra via `isExterior`) körs först
    // när båda är klara. Utdata blir därför desamma som i följd.
    //
    // I felsökningsläget (`maxParallelism == 1`) och vid kritiskt minnestryck körs stegen i följd,
    // precis som före fas 1c.

    func runAITaggingAndHDR(hdrEnabled: Bool) async throws {
        let aiEnabled = AppSettings.shared.aiTaggingEnabled
        let budget = ResourceGovernor.currentBudget(userMax: AppSettings.shared.maxParallelism)
        guard aiEnabled, hdrEnabled, ResourceGovernor.allowsStepOverlap(budget: budget) else {
            try await checkCancellationAndWaitIfPaused()
            try await runAITaggingStep(enabled: aiEnabled)
            try await checkCancellationAndWaitIfPaused()
            try await runHDRStep(enabled: hdrEnabled)
            return
        }

        try await checkCancellationAndWaitIfPaused()
        pipelineLog(">>> AI-taggning och HDR körs samtidigt")
        do {
            // Båda körs på MainActor men släpper den vid varje `await` (det tunga arbetet sker i
            // `@concurrent`-motorerna och Vision), så de går omlott. Kastar det ena avbryts det andra
            // när scopet lämnas.
            async let ai: Void = runAITaggingStep(enabled: true, markErrors: true)
            async let hdr: Void = runHDRStep(enabled: true, markErrors: true)
            try await ai
            try await hdr
        } catch {
            // Ett fel i det ena steget avbryter det andra; lämna inte dess kort som "Arbetar...".
            if !(error is CancellationError) {
                for step in [DashboardStep.aiTagging, .createHDR] where state.stepStatuses[step]?.phase == .active {
                    state.updateStep(step, phase: .idle)
                    state.appendStepLog(step, "Avbrutet", type: .warning)
                }
            }
            throw error
        }
    }

    /// Steg: AI-taggning + Vision-baserad kvalitetsanalys (Fas 3b).
    private func runAITaggingStep(enabled: Bool, markErrors: Bool = false) async throws {
        pipelineLog(">>> Steg: AI-taggning / Vision-analys")
        if enabled {
            state.updateStep(.aiTagging, phase: .active)
            do {
                try await runAITagging()
            } catch where markErrors && !(error is CancellationError) {
                state.updateStep(.aiTagging, phase: .error(error.localizedDescription))
                throw error
            }
            state.completeStep(.aiTagging, count: aiTagResults.count)
        } else {
            state.updateStep(.aiTagging, phase: .disabled)
            state.appendStepLog(.aiTagging, "AI-taggning/Vision-analys avaktiverad i inställningar", type: .info)
        }
        pipelineLog("<<< AI-taggning / Vision-analys klar")
    }

    /// Steg: HDR-sammanslagning. Startar om stegets klocka: kortet har stått som aktivt sedan
    /// bracket-analysen, och utan omstart hade previews, kalender (och i följd även AI) räknats
    /// in i HDR-tiden.
    private func runHDRStep(enabled: Bool, markErrors: Bool = false) async throws {
        if enabled {
            state.updateStep(.createHDR, phase: .active)
            do {
                try await runHDRMerge()
            } catch where markErrors && !(error is CancellationError) {
                state.updateStep(.createHDR, phase: .error(error.localizedDescription))
                throw error
            }
            state.completeStep(.createHDR)
        } else {
            state.updateStep(.createHDR, phase: .disabled)
            state.appendStepLog(.createHDR, "HDR-merge avaktiverad i inställningar", type: .info)
        }
    }
}
