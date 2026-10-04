import SwiftUI

struct BracketReviewView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var notesManager = NotesManager()
    @StateObject private var dictation = DictationService()
    @State private var selectedGroupIndex: Int = 0
    @State private var selectedPhotoIndex: Int = 0
    /// Användaren har valt att bläddra bland källexponeringarna. Har gruppen en
    /// färdig HDR visas den som standard (se `ReviewImageSelection`).
    @State private var showSources: Bool = false
    @State private var showNotes: Bool = false
    @State private var filter: ReviewFilter = .all
    @State private var viewOptions = ReviewViewOptions()
    @State private var undoStack = ReviewUndoStack()
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

    /// Sant när slutprodukten (förbättrad/sammanslagen HDR) visas i stora bilden.
    private var showHDRPreview: Bool {
        get { currentGroup?.finalPreviewURL != nil && !showSources }
        nonmutating set { showSources = !newValue }
    }

    /// Bilden som visas i stora bilden just nu (för histogram, zoom och lupp).
    private var displayedURL: URL? {
        if showHDRPreview { return currentGroup?.finalPreviewURL }
        return currentPhoto?.previewURL
    }

    /// Adressmapp per grupp (efter första bildens tid), via kalendermatchningarna.
    private var groupAddresses: [Int: String] {
        guard let mappings = runner.runner?.calendarMappings, !mappings.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        for group in pipeline.bracketGroups {
            guard let first = pipeline.photos(in: group).first else { continue }
            result[group.id] = PhotoClustering.addressFolder(for: first.dateTime, mappings: mappings) ?? "Osorterade"
        }
        return result
    }

    private func summaries(addresses: [Int: String]) -> [ReviewGroupSummary] {
        pipeline.bracketGroups.map { g in
            let photos = pipeline.photos(in: g)
            return ReviewGroupSummary(
                allReviewed: photos.allSatisfy { $0.accepted || $0.rejected },
                hasRejected: photos.contains { $0.rejected },
                hasUserOverride: photos.contains { $0.accepted && !$0.algorithmSuggested },
                addressFolder: addresses[g.id])
        }
    }

    var currentPhoto: PhotoItem? {
        guard selectedPhotoIndex < currentGroupPhotos.count else { return nil }
        return currentGroupPhotos[selectedPhotoIndex]
    }

    /// Reflects which HDR engine actually produced `finalPreviewURL` (see
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
            if currentGroup?.finalPreviewURL != nil { showHDRPreview.toggle() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "d")) { _ in finishReview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "z")) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            viewOptions.zoom100.toggle()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "c")) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            viewOptions.showClipping.toggle()
            return .handled
        }
        .onKeyPress(.tab) { goToUnreviewedGroup(direction: 1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "u")) { _ in goToUnreviewedGroup(direction: 1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "j")) { _ in navigateGroup(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "k")) { _ in navigateGroup(-1); return .handled }
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
                Text(ReviewNavigation.progressText(reviewed: reviewedCount, total: pipeline.bracketGroups.count))
                    .font(.caption.bold())
                    .foregroundColor(reviewedCount == pipeline.bracketGroups.count ? .green : .secondary)
                Text("Pilar/J/K: navigera | Mellanslag: välj | Retur/Delete: acceptera/avvisa | ⌘Z: ångra | H: HDR | Tab/U: nästa ogranskade | Z: 100 % | Shift: lupp | C: histogram/klippning")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(action: undoLastDecision) {
                Label("Ångra", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoStack.isEmpty)
            .help("Ångra senaste granskningsbeslut (⌘Z)")

            // Notes toggle
            Button(action: { withAnimation { showNotes.toggle() } }) {
                Label(
                    showNotes ? "Dölj anteckningar" : "Anteckningar (N)",
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
        let addresses = groupAddresses
        let sums = summaries(addresses: addresses)
        let visible = ReviewFilter.visibleIndices(sums, filter: filter)
        return VStack(spacing: 0) {
            ReviewFilterBar(filter: $filter, addresses: ReviewFilter.addresses(in: sums),
                            visibleCount: visible.count, totalCount: sums.count)
            Divider()
            groupListBody(visible: visible, addresses: addresses)
        }
    }

    private func groupListBody(visible: [Int], addresses: [Int: String]) -> some View {
        List(selection: Binding(
            get: { selectedGroupIndex },
            set: { selectedGroupIndex = $0; selectedPhotoIndex = 0; showSources = false }
        )) {
            ForEach(visible, id: \.self) { index in
                let group = pipeline.bracketGroups[index]
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
                        if let address = addresses[group.id] {
                            Label(address, systemImage: "folder")
                                .font(.caption2)
                                .foregroundColor(address == "Osorterade" ? .orange : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("Adressmapp: \(address)")
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
                        if group.finalPreviewURL != nil {
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

            if showHDRPreview, let hdrURL = currentGroup?.finalPreviewURL {
                // Show merged HDR preview
                VStack(spacing: 12) {
                    LocalImageView(url: hdrURL)
                        .id(hdrIdentity)
                        .reviewImageOverlays(url: hdrURL, options: viewOptions)
                        .overlay {
                            if isReMergingCurrent { reMergeBadge(large: true) }
                        }
                        .overlay(alignment: .topTrailing) {
                            GlassEffectContainer {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Label(currentGroup?.enhancedPreviewURL != nil ? "HDR · förbättrad" : "HDR-sammanslagning", systemImage: "photo.stack")
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
                            showSources = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .foregroundColor(.secondary)
                }
                .padding()
            } else if let photo = currentPhoto {
                VStack(spacing: 12) {
                    ProgressiveImageView(previewURL: photo.previewURL, fullResURL: photo.nefURL, dngURL: photo.dngURL)
                        .reviewImageOverlays(url: photo.previewURL, options: viewOptions)
                        .overlay(alignment: .topTrailing) {
                            statusBadge(for: photo)
                                .padding(12)
                        }
                        .overlay(alignment: .topLeading) {
                            if currentGroup?.finalPreviewURL != nil {
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
                        if currentGroup?.finalPreviewURL != nil {
                            Label("Exponering \(selectedPhotoIndex + 1) av \(currentGroupPhotos.count)", systemImage: "square.stack.3d.up")
                                .foregroundColor(.accentColor)
                        }
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
                    if let group = currentGroup, group.finalPreviewURL != nil {
                        VStack(spacing: 4) {
                            LocalThumbnailView(url: group.finalPreviewURL)
                                .id(hdrIdentity)
                                .frame(width: 100, height: 75)
                                .clipped()
                                .overlay {
                                    if isReMergingCurrent { reMergeBadge(large: false) }
                                }

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
                                    showSources = true
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
        // Grannar: nästa/föregående grupp så att pil upp/ner känns omedelbart.
        let groups = pipeline.bracketGroups
        for i in ReviewNavigation.prefetchNeighbors(of: selectedGroupIndex, count: groups.count, radius: 2) {
            for photo in pipeline.photos(in: groups[i]) {
                ImageCache.shared.prefetch(url: photo.previewURL, tier: .fullSize, maxDimension: 2400)
            }
            if let hdr = groups[i].finalPreviewURL {
                ImageCache.shared.prefetch(url: hdr, tier: .fullSize, maxDimension: 2400)
            }
        }
    }

    // MARK: - Actions

    private func navigatePhoto(_ direction: Int) {
        guard currentGroup != nil else { return }
        // Pil åt höger från HDR-bilden går till första exponeringen, åt vänster stannar kvar.
        if showHDRPreview {
            if direction > 0 { showSources = true; selectedPhotoIndex = 0 }
            return
        }
        let newIndex = selectedPhotoIndex + direction
        if newIndex >= 0 && newIndex < currentGroupPhotos.count {
            selectedPhotoIndex = newIndex
        }
    }

    private var reviewedCount: Int {
        pipeline.bracketGroups.filter { pipeline.allReviewed($0) }.count
    }

    private func goToUnreviewedGroup(direction: Int) {
        let reviewed = pipeline.bracketGroups.map { pipeline.allReviewed($0) }
        let sums = summaries(addresses: groupAddresses)
        // Med filter aktivt: bara ogranskade bland de synliga.
        let visible = Set(ReviewFilter.visibleIndices(sums, filter: filter))
        let masked = reviewed.enumerated().map { visible.contains($0.offset) ? $0.element : true }
        guard let idx = ReviewNavigation.nextUnreviewed(from: selectedGroupIndex, reviewed: masked, direction: direction) else { return }
        selectedGroupIndex = idx
        selectedPhotoIndex = 0
        showSources = false
    }

    private func navigateGroup(_ direction: Int) {
        let visible = ReviewFilter.visibleIndices(summaries(addresses: groupAddresses), filter: filter)
        if let newIndex = ReviewFilter.step(from: selectedGroupIndex, direction: direction, visible: visible) {
            selectedGroupIndex = newIndex
            selectedPhotoIndex = 0
            showSources = false
        }
    }

    private func toggleCurrentPhoto() {
        guard currentGroup != nil, let photo = currentPhoto else { return }
        let wasAccepted = photo.accepted
        recordUndo(photo)
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
        recordUndo(photo)
        pipeline.setDecision(photoID: photo.id, accepted: true, rejected: false)
        pipeline.setAlgorithmSuggested(photoID: photo.id, suggested: false)
        audio.playAccept()
        pipeline.saveCullDecisions()
        navigatePhoto(1)
        scheduleReMerge()
    }

    private func rejectCurrentPhoto() {
        guard currentGroup != nil, let photo = currentPhoto else { return }
        recordUndo(photo)
        pipeline.setDecision(photoID: photo.id, accepted: false, rejected: true)
        audio.playReject()
        pipeline.saveCullDecisions()
        navigatePhoto(1)
        scheduleReMerge()
    }

    // MARK: - Ångra

    private func recordUndo(_ photo: PhotoItem) {
        undoStack.push(ReviewDecisionSnapshot(
            photoID: photo.id, accepted: photo.accepted, rejected: photo.rejected,
            algorithmSuggested: photo.algorithmSuggested,
            groupIndex: selectedGroupIndex, photoIndex: selectedPhotoIndex))
    }

    /// Återställer senaste beslutet och hoppar till bilden det gällde.
    private func undoLastDecision() {
        guard let snap = undoStack.pop() else { return }
        pipeline.setDecision(photoID: snap.photoID, accepted: snap.accepted, rejected: snap.rejected)
        pipeline.setAlgorithmSuggested(photoID: snap.photoID, suggested: snap.algorithmSuggested)
        pipeline.saveCullDecisions()
        if snap.groupIndex < pipeline.bracketGroups.count {
            selectedGroupIndex = snap.groupIndex
            selectedPhotoIndex = snap.photoIndex
            showSources = true
        }
        scheduleReMerge()
    }

    // MARK: - Omgjord HDR

    private var isReMergingCurrent: Bool {
        currentGroup.map { pipeline.reMergingGroups.contains($0.id) } ?? false
    }

    /// Byts när gruppens HDR gjorts om, så att bilden laddas om fast filnamnet är detsamma.
    private var hdrIdentity: String {
        guard let group = currentGroup else { return "hdr-none" }
        return "hdr-\(group.id)-\(pipeline.hdrRevision[group.id] ?? 0)"
    }

    private func reMergeBadge(large: Bool) -> some View {
        VStack(spacing: large ? 10 : 4) {
            ProgressView().controlSize(large ? .regular : .small)
            Text(large ? "Gör om HDR med ditt urval…" : "Gör om…")
                .font(large ? .headline : .caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(large ? 16 : 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.6)))
    }

    /// Debounced re-merge: waits 1.5s after the last change, then re-runs HDREngine with the new selection
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
