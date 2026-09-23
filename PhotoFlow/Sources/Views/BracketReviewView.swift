import SwiftUI

struct BracketReviewView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var notesManager = NotesManager()
    @StateObject private var dictation = DictationService()
    @State private var selectedGroupIndex: Int = 0
    @State private var selectedPhotoIndex: Int = 0
    @State private var showHDRPreview: Bool = false
    @State private var showNotes: Bool = false
    @FocusState private var isFocused: Bool

    private let audio = AudioService.shared

    var currentGroup: BracketGroup? {
        guard selectedGroupIndex < pipeline.bracketGroups.count else { return nil }
        return pipeline.bracketGroups[selectedGroupIndex]
    }

    var currentGroupPhotos: [PhotoItem] {
        guard let group = currentGroup else { return [] }
        return pipeline.photos(in: group)
    }

    var currentPhoto: PhotoItem? {
        guard selectedPhotoIndex < currentGroupPhotos.count else { return nil }
        return currentGroupPhotos[selectedPhotoIndex]
    }

    /// Reflects which HDR engine actually produced `mergedHDRPreviewURL` (see
    /// `AppSettings.hdrEngine`) — previously hardcoded to "Mertens Exposure
    /// Fusion (OpenCV)" even after Fas 3a added the Core Image RAW engine.
    private var engineLabel: String {
        settings.hdrEngine == "opencv" ? "Mertens Exposure Fusion (OpenCV)" : "Exposure Fusion (Core Image RAW)"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            HStack(spacing: 0) {
                groupList
                    .frame(width: 220)

                Divider()

                VStack(spacing: 0) {
                    largePreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    thumbnailStrip
                        .frame(height: 130)
                }

                // Notes panel (right side)
                if showNotes, let photo = currentPhoto {
                    Divider()
                    DictationPanelView(
                        photoId: photo.id,
                        photoFilename: photo.filename,
                        notesManager: notesManager,
                        dictation: dictation
                    )
                    .frame(width: 300)
                }
            }
        }
        .onAppear {
            notesManager.setup(
                outputDir: pipeline.outputDirectory,
                address: pipeline.matchedAddress
            )
            prefetchCurrentGroup()
        }
        .onDisappear {
            // Fas 10: samma garanti som PreviewCullView — se
            // `PipelineState.flushCullDecisions()`s doc-kommentar.
            pipeline.flushCullDecisions()
        }
        .onChange(of: selectedGroupIndex) { _, _ in prefetchCurrentGroup() }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { navigatePhoto(-1); return .handled }
        .onKeyPress(.rightArrow) { navigatePhoto(1); return .handled }
        .onKeyPress(.upArrow) { navigateGroup(-1); return .handled }
        .onKeyPress(.downArrow) { navigateGroup(1); return .handled }
        .onKeyPress(.space) { toggleCurrentPhoto(); return .handled }
        .onKeyPress(.return) { acceptCurrentPhoto(); return .handled }
        .onKeyPress(.delete) { rejectCurrentPhoto(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "h")) { _ in
            if currentGroup?.mergedHDRPreviewURL != nil { showHDRPreview.toggle() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "d")) { _ in finishReview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "n")) { _ in
            withAnimation { showNotes.toggle() }
            return .handled
        }
        .overlay(alignment: .bottom) {
            CountdownOverlay()
                .padding(.bottom, 20)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Granska bracket-grupper")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Välj vilka bilder som ska ingå i HDR-sammanslagningen")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            AddressBanner()
                .padding(.horizontal, 4)

            Spacer()

            // Legend
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text("Algoritmens val")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(.blue).frame(width: 10, height: 10)
                    Text("Ditt val")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text("Grupp \(selectedGroupIndex + 1) av \(pipeline.bracketGroups.count)")
                    .font(.headline)
                Text("Piltangenter: navigera | Mellanslag: välj/avvälj | H: HDR-preview")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Notes toggle
            Button(action: { withAnimation { showNotes.toggle() } }) {
                Label(
                    showNotes ? "Dolj anteckningar" : "Anteckningar (N)",
                    systemImage: showNotes ? "mic.slash" : "mic.bubble"
                )
            }
            .buttonStyle(.bordered)
            .tint(showNotes ? .accentColor : nil)
            .controlSize(.large)

            // Email notes
            if !notesManager.notes.isEmpty {
                Button(action: emailNotes) {
                    Label("Maila", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button(action: {
                let bracketGroups = pipeline.bracketGroups.filter { $0.isBracket && pipeline.selectedCount(in: $0) >= 2 }
                runner.sendToLightroom(groups: bracketGroups)
            }) {
                Label("Lightroom HDR", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.orange)
            .padding(.leading, 8)

            Button("Klar (D)") {
                finishReview()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Group list

    private var groupList: some View {
        List(selection: Binding(
            get: { selectedGroupIndex },
            set: { selectedGroupIndex = $0; selectedPhotoIndex = 0; showHDRPreview = false }
        )) {
            ForEach(Array(pipeline.bracketGroups.enumerated()), id: \.element.id) { index, group in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if group.isBracket {
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                            Text(pipeline.label(for: group))
                                .font(.system(.caption, design: .rounded, weight: .medium))
                        }
                        HStack(spacing: 8) {
                            Text("\(group.timeStart)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(pipeline.selectedCount(in: group))/\(pipeline.photos(in: group).count) valda")
                                .font(.caption2)
                                .foregroundColor(pipeline.selectedCount(in: group) > 0 ? .green : .secondary)
                        }
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        if group.mergedHDRPreviewURL != nil {
                            Label("HDR", systemImage: "photo.stack")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .cornerRadius(4)
                        } else if group.isBracket {
                            Text("Väntar")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if pipeline.allReviewed(group) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
                .tag(index)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Large preview

    private var largePreview: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if showHDRPreview, let hdrURL = currentGroup?.mergedHDRPreviewURL {
                // Show merged HDR preview
                VStack(spacing: 12) {
                    LocalImageView(url: hdrURL)
                        .overlay(alignment: .topTrailing) {
                            GlassEffectContainer {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Label("HDR-sammanslagning", systemImage: "photo.stack")
                                        .font(.title3.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .glassEffect(.regular.tint(.orange.opacity(0.85)), in: RoundedRectangle(cornerRadius: 8))

                                    Label(engineLabel, systemImage: "cpu")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .glassEffect(.regular.tint(.black.opacity(0.5)), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(12)
                        }

                    HStack(spacing: 16) {
                        Label("HDR - \(currentGroup.map { pipeline.selectedCount(in: $0) } ?? 0) exponeringar", systemImage: "photo.stack")
                            .font(.system(.body, design: .monospaced))
                        Text("·")
                        Label(engineLabel, systemImage: "cpu")
                            .font(.system(.body, design: .monospaced))
                        Button("Visa enskilda bilder (H)") {
                            showHDRPreview = false
                        }
                        .buttonStyle(.bordered)
                    }
                    .foregroundColor(.secondary)
                }
                .padding()
            } else if let photo = currentPhoto {
                VStack(spacing: 12) {
                    ProgressiveImageView(previewURL: photo.previewURL, fullResURL: photo.nefURL, dngURL: photo.dngURL)
                        .overlay(alignment: .topTrailing) {
                            statusBadge(for: photo)
                                .padding(12)
                        }
                        .overlay(alignment: .topLeading) {
                            if currentGroup?.mergedHDRPreviewURL != nil {
                                Button(action: { showHDRPreview = true }) {
                                    Label("Visa HDR (H)", systemImage: "photo.stack")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.glass)
                                .tint(.orange)
                                .padding(12)
                            }
                        }

                    HStack(spacing: 24) {
                        Label(photo.displayName, systemImage: "photo")
                        Label(photo.exposureDisplay, systemImage: "timer")
                        Label("f/\(String(format: "%.1f", photo.fNumber))", systemImage: "camera.aperture")
                        Label("ISO \(photo.iso)", systemImage: "sun.max")
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)

                    if !photo.aiTags.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                            ForEach(photo.aiTags.prefix(6), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundColor(.accentColor)
                            }
                            if photo.aiTags.count > 6 {
                                Text("+\(photo.aiTags.count - 6)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
            } else {
                Text("Ingen bild vald")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for photo: PhotoItem) -> some View {
        if photo.accepted && photo.algorithmSuggested {
            Label("Algoritmens val", systemImage: "cpu")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.green.opacity(0.85)), in: RoundedRectangle(cornerRadius: 8))
        } else if photo.accepted && !photo.algorithmSuggested {
            Label("Ditt val", systemImage: "hand.tap")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.blue.opacity(0.85)), in: RoundedRectangle(cornerRadius: 8))
        } else if photo.rejected {
            Label("Avvisad", systemImage: "xmark.circle.fill")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.red.opacity(0.85)), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Thumbnail strip

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // HDR preview thumbnail (if available)
                    if let group = currentGroup, group.mergedHDRPreviewURL != nil {
                        VStack(spacing: 4) {
                            LocalThumbnailView(url: group.mergedHDRPreviewURL)
                                .frame(width: 100, height: 75)
                                .clipped()

                            Text("HDR")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundColor(.orange)
                        }
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(showHDRPreview ? Color.orange.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange, lineWidth: showHDRPreview ? 3 : 2)
                        )
                        .onTapGesture {
                            showHDRPreview.toggle()
                        }

                        Divider()
                            .frame(height: 80)
                    }

                    if currentGroup != nil {
                        ForEach(Array(currentGroupPhotos.enumerated()), id: \.element.id) { index, photo in
                            thumbnailCard(photo: photo, index: index)
                                .id(index)
                                .onTapGesture {
                                    selectedPhotoIndex = index
                                    showHDRPreview = false
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: selectedPhotoIndex) { _, newVal in
                withAnimation {
                    proxy.scrollTo(newVal, anchor: .center)
                }
            }
        }
    }

    private func thumbnailCard(photo: PhotoItem, index: Int) -> some View {
        VStack(spacing: 4) {
            LocalThumbnailView(url: photo.previewURL)
                .frame(width: 100, height: 75)
                .clipped()

            Text(photo.exposureDisplay)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index == selectedPhotoIndex && !showHDRPreview ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor(for: photo, isSelected: index == selectedPhotoIndex && !showHDRPreview), lineWidth: (index == selectedPhotoIndex && !showHDRPreview) ? 3 : 2)
        )
        .opacity(photo.rejected ? 0.4 : 1.0)
    }

    private func borderColor(for photo: PhotoItem, isSelected: Bool) -> Color {
        if photo.accepted && photo.algorithmSuggested { return .green }
        if photo.accepted && !photo.algorithmSuggested { return .blue }
        if photo.rejected { return .red }
        if isSelected { return .accentColor }
        return .clear
    }

    // MARK: - Förhämtning (Fas 5)

    /// En bracket-/singelgrupp har typiskt bara 1–5 bilder, så hela gruppens
    /// miniatyrer + förhandsbilder förhämtas till `ImageCache` så fort den
    /// väljs — billigt (ingen kostnad om gruppen redan är i cachen) och
    /// täcker både klick i gruppslistan och pil upp/ner-navigering.
    private func prefetchCurrentGroup() {
        for photo in currentGroupPhotos {
            ImageCache.shared.prefetch(url: photo.previewURL, tier: .thumbnail, maxDimension: 200)
            ImageCache.shared.prefetch(url: photo.previewURL, tier: .fullSize, maxDimension: 2400)
        }
    }

    // MARK: - Actions

    private func navigatePhoto(_ direction: Int) {
        guard currentGroup != nil else { return }
        showHDRPreview = false
        let newIndex = selectedPhotoIndex + direction
        if newIndex >= 0 && newIndex < currentGroupPhotos.count {
            selectedPhotoIndex = newIndex
        }
    }

    private func navigateGroup(_ direction: Int) {
        let newIndex = selectedGroupIndex + direction
        if newIndex >= 0 && newIndex < pipeline.bracketGroups.count {
            selectedGroupIndex = newIndex
            selectedPhotoIndex = 0
            showHDRPreview = false
        }
    }

    private func toggleCurrentPhoto() {
        guard currentGroup != nil, let photo = currentPhoto else { return }
        let wasAccepted = photo.accepted
        pipeline.setDecision(photoID: photo.id, accepted: !wasAccepted, rejected: false)
        // Mark as user choice (not algorithm)
        if !wasAccepted {
            pipeline.setAlgorithmSuggested(photoID: photo.id, suggested: false)
        }
        if wasAccepted {
            audio.playReject()
        } else {
            audio.playAccept()
        }
        pipeline.saveCullDecisions()
        scheduleReMerge()
    }

    private func acceptCurrentPhoto() {
        guard currentGroup != nil, let photo = currentPhoto else { return }
        pipeline.setDecision(photoID: photo.id, accepted: true, rejected: false)
        pipeline.setAlgorithmSuggested(photoID: photo.id, suggested: false)
        audio.playAccept()
        pipeline.saveCullDecisions()
        navigatePhoto(1)
        scheduleReMerge()
    }

    private func rejectCurrentPhoto() {
        guard currentGroup != nil, let photo = currentPhoto else { return }
        pipeline.setDecision(photoID: photo.id, accepted: false, rejected: true)
        audio.playReject()
        pipeline.saveCullDecisions()
        navigatePhoto(1)
        scheduleReMerge()
    }

    /// Debounced re-merge: waits 1.5s after last change before triggering Photoshop
    @State private var reMergeTask: Task<Void, Never>?

    private func scheduleReMerge() {
        guard let group = currentGroup, group.isBracket else { return }
        reMergeTask?.cancel()
        let groupCopy = pipeline.bracketGroups[selectedGroupIndex]
        reMergeTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            runner.reMergeHDR(group: groupCopy)
        }
    }

    private func finishReview() {
        pipeline.currentStep = .culling
        pipeline.statusMessage = "Gallra bilder – acceptera eller avvisa"
        audio.playStepComplete()
    }

    private func emailNotes() {
        if let url = notesManager.mailtoURL() {
            NSWorkspace.shared.open(url)
        }
    }
}
