import Foundation

extension PipelineRunner {
    // MARK: - Step 4: HDR Merge (Mertens exposure fusion via OpenCV)

    func runHDRMerge() async throws {
        guard let outputDir = state.outputDirectory else { return }

        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard FileManager.default.fileExists(atPath: groupsJSON.path) else { return }

        let data = try Data(contentsOf: groupsJSON)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let previewDir = outputDir.appendingPathComponent("previews")
        let hdrDir = outputDir.appendingPathComponent("hdr")
        try FileManager.default.createDirectory(at: hdrDir, withIntermediateDirectories: true)

        let bracketGroups = groups.filter { ($0["is_bracket"] as? Bool) == true }
        guard !bracketGroups.isEmpty else { return }

        state.currentStep = .mergingHDR
        state.statusMessage = "Slår ihop HDR-brackets (Mertens exposure fusion)..."
        state.totalFiles = bracketGroups.count
        state.currentFileIndex = 0
        state.progress = 0.0
        state.appendLog("Startar HDR-sammanslagning med Mertens exposure fusion (\(bracketGroups.count) bracket-grupper)...", type: .info)

        // Build list of groups to merge (skip already-done ones)
        var groupsToMerge: [(groupId: Int, previewPaths: [String])] = []
        for group in bracketGroups {
            let groupId = (group["group_id"] as? Int) ?? 0
            let files = (group["files"] as? [String]) ?? []
            let suggestedIndices = (group["suggested_hdr_indices"] as? [Int]) ?? Array(0..<files.count)

            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(groupId).tiff")
            if FileManager.default.fileExists(atPath: hdrTiff.path) { continue }

            // Use preview JPEGs for fusion (full resolution embedded previews from NEF)
            let previewPaths = suggestedIndices.compactMap { i -> String? in
                guard i < files.count else { return nil }
                let baseName = files[i].replacingOccurrences(of: ".NEF", with: "")
                let preview = previewDir.appendingPathComponent("\(baseName).jpg")
                return FileManager.default.fileExists(atPath: preview.path) ? preview.path : nil
            }

            guard previewPaths.count >= 2 else { continue }
            groupsToMerge.append((groupId: groupId, previewPaths: previewPaths))
        }

        if groupsToMerge.isEmpty {
            logDecision(step: "hdr_merge", decision: "skipped", details: [
                "reason": "all_complete"
            ])
            state.appendLog("Alla HDR-grupper redan klara.", type: .info)
            state.progress = 1.0
            return
        }

        // Resolve python3+OpenCV once up front — failing per-group would produce
        // "N misslyckades" instead of one clear "installera OpenCV" message.
        let python3Path = try requirePython3WithOpenCV()

        // Write the Python fusion script
        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
        let pyScript = mertensFusionPython()
        try pyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptPath) }

        var successCount = 0
        var failCount = 0
        state.updateStepProgress(.createHDR, processed: 0, total: groupsToMerge.count)

        for (idx, group) in groupsToMerge.enumerated() {
            try await checkCancellationAndWaitIfPaused()
            state.statusMessage = "Exposure fusion: grupp \(group.groupId) (\(idx + 1)/\(groupsToMerge.count))..."
            state.currentFileIndex = idx
            state.progress = Double(idx) / Double(groupsToMerge.count)
            state.updateStepProgress(.createHDR, processed: idx, total: groupsToMerge.count)
            state.appendLog("HDR grupp \(group.groupId): \(group.previewPaths.count) bilder (Mertens fusion)...", type: .info)

            // Update detailed progress
            state.currentMergeGroupId = group.groupId
            state.currentMergeInputURLs = group.previewPaths.map { URL(fileURLWithPath: $0) }
            state.currentMergeOutputURL = nil

            let outputPath = hdrDir.appendingPathComponent("hdr_group_\(group.groupId).tiff").path
            let previewPath = hdrDir.appendingPathComponent("hdr_group_\(group.groupId).jpg").path

            let inputNames = group.previewPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): mergar \(group.previewPaths.count) bilder (\(inputNames))...")

            do {
                let output = try await runProcess(
                    executablePath: python3Path,
                    arguments: [scriptPath.path, outputPath] + group.previewPaths
                )
                if FileManager.default.fileExists(atPath: outputPath) {
                    successCount += 1
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): klar → hdr_group_\(group.groupId).tiff (\(sizeMB) MB)", type: .success)
                    // Show JPEG preview in UI
                    let showURL = FileManager.default.fileExists(atPath: previewPath)
                        ? URL(fileURLWithPath: previewPath)
                        : URL(fileURLWithPath: outputPath)
                    state.currentMergeOutputURL = showURL
                    pipelineLog("  Grupp \(group.groupId): Mertens fusion klar (16-bit TIFF)")
                } else {
                    failCount += 1
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): ingen output skapad", type: .error)
                    pipelineLog("  Grupp \(group.groupId): Ingen output skapad. \(output)")
                }
            } catch {
                failCount += 1
                state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): misslyckades — \(error.localizedDescription)", type: .error)
                pipelineLog("  Grupp \(group.groupId): Fusion misslyckades: \(error.localizedDescription)")
            }

            state.currentFileIndex = idx + 1
            state.progress = Double(idx + 1) / Double(groupsToMerge.count)
        }

        // Clear detailed progress
        state.currentMergeInputURLs = []
        state.currentMergeOutputURL = nil
        state.currentMergeGroupId = nil

        state.progress = 1.0
        if failCount == 0 {
            state.appendLog("HDR-sammanslagning klar: \(successCount) grupper (Mertens fusion).", type: .success)
        } else {
            state.appendLog("HDR-sammanslagning: \(successCount) lyckades, \(failCount) misslyckades.", type: .warning)
        }
        audio.playStepComplete()
    }

    /// Re-merge a single bracket group after user changes selection.
    /// Called from BracketReviewView when user modifies which photos are included.
    func reMergeHDR(group: BracketGroup) async {
        guard let outputDir = state.outputDirectory else { return }
        let hdrDir = outputDir.appendingPathComponent("hdr")

        let selectedPhotos = state.photos(in: group).filter { $0.accepted }
        guard selectedPhotos.count >= 2 else {
            state.appendLog("Grupp \(group.id): Minst 2 bilder krävs för HDR.", type: .warning)
            return
        }

        // Remove old HDR files
        let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(group.id).tiff")
        let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(group.id).jpg")
        let hdrTifOld = hdrDir.appendingPathComponent("hdr_group_\(group.id).tif")
        try? FileManager.default.removeItem(at: hdrTiff)
        try? FileManager.default.removeItem(at: hdrJpeg)
        try? FileManager.default.removeItem(at: hdrTifOld)

        // Use preview JPEGs for Mertens fusion
        let previewPaths = selectedPhotos.compactMap { photo -> String? in
            guard let url = photo.previewURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.path
        }

        guard previewPaths.count >= 2 else { return }

        guard let python3Path = ToolLocator.python3WithOpenCV else {
            state.appendLog("python3 med OpenCV (cv2) och numpy saknas — installera med: pip3 install opencv-python numpy", type: .error)
            return
        }

        state.appendLog("Gör om HDR för grupp \(group.id) med \(previewPaths.count) bilder (Mertens fusion)...", type: .info)

        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
        let pyScript = mertensFusionPython()
        try? pyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptPath) }

        do {
            _ = try await runProcess(
                executablePath: python3Path,
                arguments: [scriptPath.path, hdrTiff.path] + previewPaths
            )
        } catch {
            state.appendLog("Fusion misslyckades: \(error.localizedDescription)", type: .error)
        }

        if FileManager.default.fileExists(atPath: hdrTiff.path) {
            // Use JPEG preview for UI if available, otherwise TIFF
            let previewURL = FileManager.default.fileExists(atPath: hdrJpeg.path) ? hdrJpeg : hdrTiff
            if let idx = state.bracketGroups.firstIndex(where: { $0.id == group.id }) {
                state.bracketGroups[idx].mergedHDRPreviewURL = previewURL
            }
            state.appendLog("HDR-ommerge klar för grupp \(group.id) (16-bit TIFF).", type: .success)
            audio.playStepComplete()
        } else {
            state.appendLog("HDR-ommerge misslyckades för grupp \(group.id).", type: .error)
            audio.playError()
        }
    }

    /// Python script for Mertens exposure fusion via OpenCV.
    /// Usage: python3 script.py output.jpg input1.jpg input2.jpg input3.jpg
    private func mertensFusionPython() -> String {
        """
        import cv2, numpy as np, sys

        output_path = sys.argv[1]
        input_paths = sys.argv[2:]

        images = [cv2.imread(p) for p in input_paths]
        images = [img for img in images if img is not None]

        if len(images) < 2:
            print(f"Error: only {len(images)} valid images", file=sys.stderr)
            sys.exit(1)

        # Ensure all same size
        h, w = images[0].shape[:2]
        images = [cv2.resize(img, (w, h)) if img.shape[:2] != (h, w) else img for img in images]

        # Mertens exposure fusion - blends best-exposed regions from each image
        merge = cv2.createMergeMertens(
            contrast_weight=1.0,
            saturation_weight=1.0,
            exposure_weight=1.0
        )
        fusion = merge.process(images)

        # Clamp and convert to 16-bit for maximum quality
        result_16 = np.clip(fusion * 65535, 0, 65535).astype(np.uint16)

        # Save as 16-bit TIFF (lossless, raw-like quality)
        cv2.imwrite(output_path, result_16)

        # Also save a JPEG preview for the UI
        if output_path.lower().endswith('.tiff') or output_path.lower().endswith('.tif'):
            jpeg_path = output_path.rsplit('.', 1)[0] + '.jpg'
        else:
            jpeg_path = output_path + '.jpg'
        result_8 = np.clip(fusion * 255, 0, 255).astype(np.uint8)
        cv2.imwrite(jpeg_path, result_8, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"Mertens fusion: {len(images)} bilder -> {output_path} + preview")
        """
    }
}
