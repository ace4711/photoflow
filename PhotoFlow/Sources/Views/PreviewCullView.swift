import SwiftUI

struct PreviewCullView: View {
    @EnvironmentObject var pipeline: PipelineState
    @EnvironmentObject var runner: RunnerWrapper
    @StateObject private var notesManager = NotesManager()
    @StateObject private var dictation = DictationService()
    @FocusState private var isFocused: Bool
    @State private var isFullscreen: Bool = false
    @State private var showNotes: Bool = false
    @State private var dictPulse: Bool = false

    /// Fas 4: `finishCulling` visar den här innan den faktiskt kör
    /// `AppSettings.cullAction == "radera"` — permanent radering behöver ett
    /// extra klick, till skillnad från "markera"/"flytta" som inte kan
    /// förstöra data.
    @State private var showDeleteConfirmation: Bool = false

    // MARK: - Filter/sortering (Fas 4, kvarstående från Fas 3b)

    private enum CullFilter: CaseIterable {
        case all, unreviewed, rejected
        var label: String {
            switch self {
            case .all: return "Alla"
            case .unreviewed: return "Ogranskade"
            case .rejected: return "Avvisade"
            }
        }
    }

    private enum CullSortOrder: CaseIterable {
        case filename, quality
        var label: String {
            switch self {
            case .filename: return "Filnamn"
            case .quality: return "Kvalitet"
            }
        }
    }

    @State private var cullFilter: CullFilter = .all
    @State private var cullSortOrder: CullSortOrder = .filename

    /// `pipeline.allPhotos` filtered by `cullFilter` and sorted by
    /// `cullSortOrder`, paired with each photo's real index into `allPhotos`
    /// (which is what `pipeline.currentCullIndex`/`setDecision` actually
    /// address) — the filmstrip and `navigate(_:)` iterate this instead of
    /// `allPhotos` directly, so filtering/sorting never touches decisions,
    /// only what's shown and in what order.
    private var filteredIndexedPhotos: [(index: Int, photo: PhotoItem)] {
        let indexed = pipeline.allPhotos.enumerated().map { (index: $0.offset, photo: $0.element) }
        let filtered = indexed.filter { entry in
            switch cullFilter {
            case .all: return true
            case .unreviewed: return !entry.photo.accepted && !entry.photo.rejected
            case .rejected: return entry.photo.rejected
            }
        }
        switch cullSortOrder {
        case .filename:
            return filtered.sorted { $0.photo.filename.localizedStandardCompare($1.photo.filename) == .orderedAscending }
        case .quality:
            // Highest quality first; photos with no score (nil) sort last regardless of side.
            return filtered.sorted { lhs, rhs in
                switch (lhs.photo.qualityScore, rhs.photo.qualityScore) {
                case let (l?, r?): return l > r
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        }
    }

    // MARK: - Ångra (Fas 4: generell ångra-stack, tidigare bara "Föreslå gallring")

    /// One undoable action: the decisions its affected photo(s) had
    /// *immediately before* the action ran. A manual accept/reject creates a
    /// one-entry action; "Föreslå gallring" (`s`) creates one action covering
    /// every photo it changed, so a single `z`/⌘Z undoes the whole batch at
    /// once — matching the old single-level "Föreslå gallring" undo's
    /// behavior, just generalized to every kind of decision.
    private struct UndoAction {
        let entries: [(id: String, wasAccepted: Bool, wasRejected: Bool)]
    }

    /// Stack of the up to 50 latest undoable actions (oldest dropped first).
    /// `z`/⌘Z pops and restores the most recent one. 50 is a generous bound
    /// for a manual review session (a real session rarely exceeds a few
    /// hundred photos total) while keeping memory bounded — each entry is
    /// just an id + two bools.
    @State private var undoStack: [UndoAction] = []
    private static let maxUndoStackSize = 50

    @State private var suggestionMessage: String?
    @State private var suggestionMessageTask: Task<Void, Never>?

    /// Normalized (0...1) quality-score cutoff for the filmstrip's "low
    /// quality" warning icon. Calibrated loosely against the real Exempelgatan 7
    /// preview session (Fas 3b, see FORBATTRINGAR.md): raw Vision aesthetics
    /// scores there ranged ~0.28...0.85 (median 0.56), i.e. ~0.64...0.93
    /// normalized — 0.7 sits below the median and flags roughly the bottom
    /// quarter without being the calibrated duplicate-clustering threshold
    /// (that one has real precision/recall data behind it; this is a rough
    /// "worth a second look" cutoff and can be tuned later).
    private static let lowQualityThreshold = 0.7

    private let audio = AudioService.shared

    var currentPhoto: PhotoItem? {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return nil }
        return pipeline.allPhotos[pipeline.currentCullIndex]
    }

    // Fas 10 (prestanda vid stora sessioner): läser nu PipelineState's cachade
    // O(1)-räknare i stället för tre `allPhotos.filter { ... }.count`
    // genomlöpningar — de kördes tidigare på VARJE omritning (header + i
    // fullskärm), dvs. vid varje enskilt accept/avvisa i en 2000-bilderssession.
    var acceptedCount: Int { pipeline.acceptedCount }
    var rejectedCount: Int { pipeline.rejectedCount }
    var unreviewedCount: Int { pipeline.unreviewedCount }

    var body: some View {
        ZStack {
            if isFullscreen {
                fullscreenView
            } else {
                normalView
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
        .onKeyPress(.return) { acceptPhoto(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "x")) { _ in rejectPhoto(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "f")) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { isFullscreen.toggle() }
            return .handled
        }
        .onKeyPress(.escape) { finishCulling(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "d")) { _ in
            withAnimation { showNotes.toggle() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "s")) { _ in
            suggestCulling()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "z")) { _ in
            // Handles both "z" and "⌘Z" — AppKit reports the same character
            // ("z") for the key regardless of whether Command is held, so one
            // handler covers both (verified: the existing single-key handlers
            // for x/f/d/s below already rely on the same behavior).
            performUndo()
            return .handled
        }
        .onAppear {
            let outDir = pipeline.outputDirectory ?? AppSettings.shared.outputDirectory
            notesManager.setup(
                outputDir: outDir,
                address: pipeline.matchedAddress
            )
            // Auto-show notes panel if current photo has a note
            if let photo = currentPhoto, notesManager.noteFor(photoId: photo.id) != nil {
                showNotes = true
            }
            prefetchNeighbors(around: pipeline.currentCullIndex)
        }
        .onChange(of: pipeline.currentCullIndex) { _, newIndex in
            // Auto-show notes if photo has a note, auto-hide if not (and not recording)
            if let photo = currentPhoto, notesManager.noteFor(photoId: photo.id) != nil {
                showNotes = true
            } else if !dictation.isRecording {
                showNotes = false
            }
            prefetchNeighbors(around: newIndex)
        }
        .overlay(alignment: .bottom) {
            CountdownOverlay()
                .padding(.bottom, 20)
        }
        .overlay(alignment: .top) {
            suggestionBanner
                .padding(.top, 12)
        }
        .onDisappear {
            // Fas 10: garanterar att gallringsbeslut alltid finns på disk även
            // om vyn stängs (tillbaka till dashboarden) mitt i den debouncade
            // 1s-fönstret från `saveCullDecisions()` — se
            // `PipelineState.flushCullDecisions()`s doc-kommentar för hela
            // listan av garantitillfällen.
            pipeline.flushCullDecisions()
        }
        .confirmationDialog(
            "Radera \(rejectedCount) gallrade bilder permanent?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Radera permanent", role: .destructive) { performFinishCulling() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Filerna går inte att återställa efteråt. Välj \"Markera med betyg\" eller \"Flytta till Gallrade\" i Inställningar → Pipeline → Gallring om du vill kunna ångra i efterhand.")
        }
    }

    // MARK: - "Föreslå gallring" banner

    @ViewBuilder
    private var suggestionBanner: some View {
        if let suggestionMessage {
            Text(suggestionMessage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.orange.opacity(0.85)), in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { self.suggestionMessage = nil } }
        }
    }

    // MARK: - Normal view

    private var normalView: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HStack(spacing: 0) {
                mainPreviewArea

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
            Divider()
            bottomStrip
        }
    }

    // MARK: - Fullscreen view

    private var fullscreenView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Large image — bleeds to the window edges (ignoresSafeArea +
            // an explicit fill frame, rather than relying on the ZStack's
            // implicit sizing) with the black background letterboxing
            // whatever the photo's own aspect ratio doesn't cover, so the
            // floating glass toolbar/bars above always sit on black or photo,
            // never on a hard content edge.
            if let photo = currentPhoto {
                ProgressiveImageView(previewURL: photo.previewURL, fullResURL: photo.nefURL, dngURL: photo.dngURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        verdictBadgeLarge(for: photo)
                            .padding(20)
                    }
            }

            // Bottom filmstrip overlay
            VStack {
                Spacer()
                fullscreenBottomBar
            }

            // Top-right stats + exit
            VStack {
                HStack {
                    Spacer()
                    fullscreenTopBar
                }
                Spacer()
            }
        }
    }

    private var fullscreenTopBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                StatPill(icon: "checkmark.circle.fill", count: acceptedCount, color: .green)
                StatPill(icon: "xmark.circle.fill", count: rejectedCount, color: .red)
                StatPill(icon: "questionmark.circle", count: unreviewedCount, color: .gray)
            }

            Text("\(pipeline.currentCullIndex + 1)/\(pipeline.allPhotos.count)")
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundColor(.white)

            Button(action: { withAnimation { isFullscreen = false } }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(8)
            }
            .buttonStyle(.glass)
        }
        .padding(16)
    }

    private var fullscreenBottomBar: some View {
        VStack(spacing: 0) {
            // Filmstrip on top
            filmstrip
                .frame(height: 90)

            // Large symbol bar on bottom
            GlassEffectContainer {
                HStack(spacing: 0) {
                    Spacer()
                    fsSymbol(icon: "chevron.left", label: "←", color: .white, action: { navigate(-1) })
                    Spacer()
                    fsSymbol(icon: "xmark.circle.fill", label: "X", color: .red, action: rejectPhoto)
                    Spacer()
                    fsSymbol(icon: "checkmark.circle.fill", label: "Return", color: .green, action: acceptPhoto)
                    Spacer()
                    fsSymbol(icon: "chevron.right", label: "→", color: .white, action: { navigate(1) })

                    Spacer()
                    Divider().frame(height: 44).opacity(0.4)
                    Spacer()

                    dictationButtonFS
                    Spacer()
                    fsSymbol(icon: "wand.and.stars", label: "S", color: .white, action: suggestCulling)
                    Spacer()
                    if !undoStack.isEmpty {
                        fsSymbol(icon: "arrow.uturn.backward.circle", label: "Z", color: .white, action: performUndo)
                        Spacer()
                    }
                    fsSymbol(icon: "arrow.down.right.and.arrow.up.left", label: "F", color: .white, action: { withAnimation { isFullscreen = false } })
                    Spacer()
                    fsSymbol(icon: "rectangle.portrait.and.arrow.right", label: "ESC", color: .orange, action: finishCulling)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        // Mörk tining av samma anledning som `photoInfoBar` — bakgrunden är
        // oftast svart (letterboxad bild), men kan vara fotot självt.
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: Rectangle())
    }

    private func fsSymbol(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .buttonStyle(.glass)
        .frame(width: 80)
    }

    // MARK: - Header (normal mode)

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("Gallring")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                AddressBanner()

                Spacer()

                HStack(spacing: 12) {
                    StatPill(icon: "checkmark.circle.fill", count: acceptedCount, color: .green)
                    StatPill(icon: "xmark.circle.fill", count: rejectedCount, color: .red)
                    StatPill(icon: "questionmark.circle", count: unreviewedCount, color: .gray)
                }

                Text("\(pipeline.currentCullIndex + 1) / \(pipeline.allPhotos.count)")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }

            filterSortBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Fas 4 (kvarstående från Fas 3b): filtrera filmremsan till alla/bara
    /// ogranskade/bara avvisade, och sortera den efter filnamn eller
    /// Vision-kvalitet. Rör inga beslut — bara vad som visas och i vilken
    /// ordning `navigate(_:)`/filmremsan hoppar mellan.
    private var filterSortBar: some View {
        HStack(spacing: 16) {
            Picker("Visa", selection: $cullFilter) {
                ForEach(CullFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .labelsHidden()

            Picker("Sortera", selection: $cullSortOrder) {
                ForEach(CullSortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .labelsHidden()

            if filteredIndexedPhotos.count != pipeline.allPhotos.count {
                Text("Visar \(filteredIndexedPhotos.count) av \(pipeline.allPhotos.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Main preview area (normal mode)

    private var mainPreviewArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if let photo = currentPhoto {
                ProgressiveImageView(previewURL: photo.previewURL, fullResURL: photo.nefURL, dngURL: photo.dngURL)
                    .overlay(alignment: .topTrailing) {
                        verdictBadgeLarge(for: photo)
                            .padding(16)
                    }
                    .overlay(alignment: .bottom) {
                        photoInfoBar(for: photo)
                    }
                    .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("Alla bilder granskade!")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Bottom strip (normal mode)

    private var bottomStrip: some View {
        VStack(spacing: 0) {
            Divider()

            filmstrip
                .frame(height: 100)

            Divider()

            // All actions as large symbol buttons
            GlassEffectContainer {
                HStack(spacing: 0) {
                    Spacer()
                    symbolButton(icon: "chevron.left", label: "←", color: .secondary, action: { navigate(-1) })
                    Spacer()
                    symbolButton(icon: "xmark.circle.fill", label: "X", color: .red, action: rejectPhoto)
                    Spacer()
                    symbolButton(icon: "checkmark.circle.fill", label: "Return", color: .green, action: acceptPhoto)
                    Spacer()
                    symbolButton(icon: "chevron.right", label: "→", color: .secondary, action: { navigate(1) })

                    Spacer()
                    Divider().frame(height: 44)
                    Spacer()

                    dictationButton
                    Spacer()

                    if !notesManager.notes.isEmpty {
                        symbolButton(icon: "envelope", label: "Mail", color: .secondary, action: {
                            if let url = notesManager.mailtoURL() {
                                NSWorkspace.shared.open(url)
                            }
                        })
                        Spacer()
                    }

                    symbolButton(icon: "wand.and.stars", label: "S", color: .secondary, action: suggestCulling)
                    Spacer()

                    if !undoStack.isEmpty {
                        symbolButton(icon: "arrow.uturn.backward.circle", label: "Z", color: .secondary, action: performUndo)
                        Spacer()
                    }

                    symbolButton(icon: "arrow.up.left.and.arrow.down.right", label: "F", color: .secondary, action: { withAnimation(.easeInOut(duration: 0.25)) { isFullscreen.toggle() } })
                    Spacer()
                    symbolButton(icon: "rectangle.portrait.and.arrow.right", label: "ESC", color: .orange, action: finishCulling)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Fas 10: `LazyHStack` i stället för `HStack` — med upp till
                // ~2100 bilder i en session byggde en vanlig `HStack` alla
                // miniatyrkort direkt (även de långt utanför synligt område),
                // i stället för bara de faktiskt synliga ± en liten buffert.
                // Förhämtningen (±3 grannar, se `prefetchNeighbors` nedan) är
                // helt fristående från SwiftUIs vy-livscykel (den jobbar direkt
                // mot `ImageCache` via index, inte via `onAppear` på
                // miniatyrvyerna) och påverkas alltså inte av bytet.
                LazyHStack(spacing: 6) {
                    ForEach(filteredIndexedPhotos, id: \.index) { entry in
                        filmstripThumb(photo: entry.photo, index: entry.index)
                            .id(entry.index)
                            .onTapGesture {
                                pipeline.currentCullIndex = entry.index
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .onChange(of: pipeline.currentCullIndex) { _, newVal in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newVal, anchor: .center)
                }
            }
        }
    }

    private func filmstripThumb(photo: PhotoItem, index: Int) -> some View {
        let isCurrent = index == pipeline.currentCullIndex
        let thumbSize: CGFloat = isCurrent ? 72 : 60

        return ZStack {
            LocalThumbnailView(url: photo.previewURL)
                .frame(width: thumbSize * 1.33, height: thumbSize)
                .clipped()
                .cornerRadius(4)

            // Status indicator (top-right)
            VStack {
                HStack {
                    Spacer()
                    verdictDot(for: photo)
                        .offset(x: -3, y: 3)
                }
                Spacer()
            }

            // Notes indicator (bottom-left)
            if notesManager.noteFor(photoId: photo.id) != nil {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .offset(x: 4, y: -3)
                        Spacer()
                    }
                }
            }

            // Vision-kvalitetsindikatorer (bottom-right): dubblettgrupp / låg kvalitet
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    qualityIndicatorIcons(for: photo)
                        .offset(x: -3, y: -3)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.accentColor : thumbBorderColor(for: photo), lineWidth: isCurrent ? 3 : 1.5)
        )
        .opacity(photo.rejected ? 0.4 : 1.0)
        .scaleEffect(isCurrent ? 1.0 : 0.9)
        .animation(.easeInOut(duration: 0.15), value: isCurrent)
    }

    // MARK: - Verdict indicators

    @ViewBuilder
    private func verdictBadgeLarge(for photo: PhotoItem) -> some View {
        let text = photo.accepted ? "Bra" : (photo.rejected ? "Kassera" : "Ej granskad")
        let icon = photo.accepted ? "checkmark.circle.fill" : (photo.rejected ? "xmark.circle.fill" : "questionmark.circle")
        let tint = photo.accepted ? Color.green : (photo.rejected ? Color.red : Color.gray)

        Label(text, systemImage: icon)
            .font(.title2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 180)
            .glassEffect(.regular.tint(tint.opacity(0.8)), in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 4)
            .animation(.none, value: text)
    }

    @ViewBuilder
    private func verdictDot(for photo: PhotoItem) -> some View {
        if photo.accepted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.green)
                .background(Circle().fill(.white).frame(width: 18, height: 18))
        } else if photo.rejected {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.red)
                .background(Circle().fill(.white).frame(width: 18, height: 18))
        } else {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.gray)
                .background(Circle().fill(.white).frame(width: 18, height: 18))
        }
    }

    private func thumbBorderColor(for photo: PhotoItem) -> Color {
        if photo.accepted { return .green.opacity(0.6) }
        if photo.rejected { return .red.opacity(0.6) }
        return .clear
    }

    // MARK: - Vision-kvalitetsbeslutsstöd (Fas 3b)

    /// All photos sharing `photo`'s duplicate group (including `photo` itself),
    /// in `allPhotos` order — empty when the photo has no duplicate group.
    private func duplicateGroup(for photo: PhotoItem) -> [PhotoItem] {
        guard let gid = photo.duplicateGroupID else { return [] }
        return pipeline.allPhotos.filter { $0.duplicateGroupID == gid }
    }

    /// "2/3"-style position within the photo's duplicate group, `nil` if it
    /// isn't in one.
    private func duplicatePosition(for photo: PhotoItem) -> (index: Int, total: Int)? {
        let group = duplicateGroup(for: photo)
        guard group.count > 1, let idx = group.firstIndex(where: { $0.id == photo.id }) else { return nil }
        return (idx + 1, group.count)
    }

    /// True when `photo` has the lowest `sharpness` among its duplicate group
    /// (a hint that it's the blurriest of a set of otherwise-identical shots).
    private func isBlurriestInDuplicateGroup(_ photo: PhotoItem) -> Bool {
        let group = duplicateGroup(for: photo)
        guard group.count > 1, let mySharpness = photo.sharpness else { return false }
        let minSharpness = group.compactMap(\.sharpness).min()
        return minSharpness == mySharpness
    }

    @ViewBuilder
    private func qualityIndicatorIcons(for photo: PhotoItem) -> some View {
        HStack(spacing: 2) {
            if photo.duplicateGroupID != nil {
                Image(systemName: "square.on.square.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.blue.opacity(0.85)))
            }
            if let q = photo.qualityScore, q < Self.lowQualityThreshold {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.orange.opacity(0.85)))
            }
        }
    }

    /// Comma-formatted (Swedish) degrees string, e.g. "2,3".
    private func swedishDegrees(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func hasQualityWarnings(_ photo: PhotoItem) -> Bool {
        duplicatePosition(for: photo) != nil
            || isBlurriestInDuplicateGroup(photo)
            || (photo.horizonAngle.map { abs($0) > 1.0 } ?? false)
            || photo.isUtility
    }

    @ViewBuilder
    private func qualityWarningChips(for photo: PhotoItem) -> some View {
        HStack(spacing: 8) {
            if let pos = duplicatePosition(for: photo) {
                warningChip(icon: "square.on.square", text: "Dubblett \(pos.index)/\(pos.total)", color: .blue)
            }
            if isBlurriestInDuplicateGroup(photo) {
                warningChip(icon: "eye.trianglebadge.exclamationmark", text: "Suddig?", color: .orange)
            }
            if let angle = photo.horizonAngle, abs(angle) > 1.0 {
                warningChip(icon: "level", text: "Skev horisont \(swedishDegrees(angle))°", color: .yellow)
            }
            if photo.isUtility {
                warningChip(icon: "doc.text.image", text: "Nyttobild", color: .gray)
            }
        }
    }

    private func warningChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.35)))
    }

    private func qualityBadge(_ score: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)
            Text(String(format: "%.2f", score))
        }
    }

    // MARK: - Dictation button with pulsing rings

    private var dictationButton: some View {
        Button(action: { withAnimation { showNotes.toggle() } }) {
            VStack(spacing: 4) {
                ZStack {
                    if dictation.isRecording {
                        Circle()
                            .stroke(Color.red.opacity(0.3), lineWidth: 2)
                            .frame(width: 48, height: 48)
                            .scaleEffect(dictPulse ? 1.6 : 1.0)
                            .opacity(dictPulse ? 0.0 : 0.6)
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 2)
                            .frame(width: 48, height: 48)
                            .scaleEffect(dictPulse ? 1.3 : 1.0)
                            .opacity(dictPulse ? 0.0 : 0.8)
                    }
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 32))
                        .foregroundColor(dictation.isRecording ? .red : (showNotes ? .accentColor : .secondary))
                }
                Text("D")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(dictation.isRecording ? .red : .secondary)
            }
        }
        .buttonStyle(.glass)
        .frame(width: 80)
        .onChange(of: dictation.isRecording) { _, recording in
            if recording {
                dictPulse = false
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    dictPulse = true
                }
            } else {
                withAnimation(.default) { dictPulse = false }
            }
        }
    }

    private var dictationButtonFS: some View {
        Button(action: { withAnimation { showNotes.toggle() } }) {
            VStack(spacing: 4) {
                ZStack {
                    if dictation.isRecording {
                        Circle()
                            .stroke(Color.red.opacity(0.3), lineWidth: 2)
                            .frame(width: 48, height: 48)
                            .scaleEffect(dictPulse ? 1.6 : 1.0)
                            .opacity(dictPulse ? 0.0 : 0.6)
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 2)
                            .frame(width: 48, height: 48)
                            .scaleEffect(dictPulse ? 1.3 : 1.0)
                            .opacity(dictPulse ? 0.0 : 0.8)
                    }
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 32))
                        .foregroundColor(dictation.isRecording ? .red : (showNotes ? .accentColor : .white))
                }
                Text("D")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(dictation.isRecording ? .red : .white.opacity(0.6))
            }
        }
        .buttonStyle(.glass)
        .frame(width: 80)
    }

    // MARK: - Shared components

    private func symbolButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.glass)
        .frame(width: 80)
    }

    private func photoInfoBar(for photo: PhotoItem) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Text(photo.displayName).fontWeight(.bold)
                Text(photo.exposureDisplay)
                Text("f/\(String(format: "%.1f", photo.fNumber))")
                Text("ISO \(photo.iso)")
                if let quality = photo.qualityScore {
                    qualityBadge(quality)
                }
            }
            .font(.system(.body, design: .monospaced))

            if hasQualityWarnings(photo) {
                qualityWarningChips(for: photo)
            }

            if !photo.aiTags.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                    ForEach(photo.aiTags.prefix(5), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.2)))
                    }
                    if photo.aiTags.count > 5 {
                        Text("+\(photo.aiTags.count - 5)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        // Fas 3g: mörk tining på glaset (i stället för ren .ultraThinMaterial)
        // — bilden bakom kan vara ljus, och vit text måste vara läsbar oavsett
        // vad som råkar synas igenom glaset.
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: Rectangle())
    }

    // MARK: - Förhämtning (Fas 5)

    /// Hur många grannar (åt varje håll) i `filteredIndexedPhotos`-ordningen
    /// som förhämtas till `ImageCache` runt ett givet index. Täcker både
    /// huvudvyns förhandsbild och filmremsans miniatyr för samma bilder —
    /// SwiftUI har inget dedikerat lazy-förhämtnings-API för
    /// `ScrollView`/`LazyHStack` i den här SDK:n (verifierat: bara
    /// `onScrollTargetVisibilityChange`/`scrollPosition` finns, inget som
    /// motsvarar UIKit/AppKit-cellprefetching), så det här är egen,
    /// indexbaserad logik i stället.
    private static let prefetchRadius = 3

    private func prefetchNeighbors(around index: Int) {
        let list = filteredIndexedPhotos
        guard let pos = list.firstIndex(where: { $0.index == index }) else { return }

        for offset in 1...Self.prefetchRadius {
            for neighborPos in [pos - offset, pos + offset] where list.indices.contains(neighborPos) {
                let photo = list[neighborPos].photo
                ImageCache.shared.prefetch(url: photo.previewURL, tier: .thumbnail, maxDimension: 200)
                ImageCache.shared.prefetch(url: photo.previewURL, tier: .fullSize, maxDimension: 2400)
            }
        }
    }

    // MARK: - Actions

    /// Moves within `filteredIndexedPhotos`' order, not raw `allPhotos`
    /// adjacency — so ←/→ and Return/x (which call this after deciding) skip
    /// over whatever the current filter/sort hides.
    private func navigate(_ direction: Int) {
        let list = filteredIndexedPhotos
        guard !list.isEmpty else { return }

        if let pos = list.firstIndex(where: { $0.index == pipeline.currentCullIndex }) {
            let newPos = pos + direction
            guard newPos >= 0 && newPos < list.count else { return }
            pipeline.currentCullIndex = list[newPos].index
            return
        }

        // The current photo just fell out of the filtered list (typical case:
        // accepting/rejecting it while filtered to "Ogranskade"/"Avvisade") —
        // jump to the nearest remaining item in the direction we were moving,
        // so accept/reject's trailing navigate(1) still advances sensibly.
        if direction >= 0 {
            if let next = list.first(where: { $0.index > pipeline.currentCullIndex }) {
                pipeline.currentCullIndex = next.index
            } else if let last = list.last {
                pipeline.currentCullIndex = last.index
            }
        } else if let prev = list.last(where: { $0.index < pipeline.currentCullIndex }) {
            pipeline.currentCullIndex = prev.index
        } else if let first = list.first {
            pipeline.currentCullIndex = first.index
        }
    }

    private func acceptPhoto() {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return }
        let photo = pipeline.allPhotos[pipeline.currentCullIndex]
        pushUndo(UndoAction(entries: [(photo.id, photo.accepted, photo.rejected)]))
        // Fas 10: går via `setDecision` (i stället för att mutera `allPhotos`
        // direkt via index) så PipelineState's cachade `acceptedCount`/
        // `rejectedCount` uppdateras inkrementellt — se `setDecision`s doc.
        pipeline.setDecision(photoID: photo.id, accepted: true, rejected: false)
        audio.playAccept()
        pipeline.saveCullDecisions()
        navigate(1)
    }

    private func rejectPhoto() {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return }
        let photo = pipeline.allPhotos[pipeline.currentCullIndex]
        pushUndo(UndoAction(entries: [(photo.id, photo.accepted, photo.rejected)]))
        pipeline.setDecision(photoID: photo.id, accepted: false, rejected: true)
        audio.playReject()
        pipeline.saveCullDecisions()
        navigate(1)
    }

    /// Fas 4: beteendet styrs av `AppSettings.cullAction`. "radera" (den gamla,
    /// enda vägen tidigare) kräver nu en bekräftelse eftersom den är den enda
    /// av de tre som inte går att ångra i efterhand — se `showDeleteConfirmation`.
    private func finishCulling() {
        if AppSettings.shared.cullAction == "radera" {
            showDeleteConfirmation = true
        } else {
            performFinishCulling()
        }
    }

    private func performFinishCulling() {
        // Fas 10: garanterar att cull_decisions.json speglar det ALLRA sista
        // beslutet innan finishCullingAction() (radera/flytta/skriv XMP) och
        // "Gallring klar"-statusen kör — annars skulle den sista snabba
        // accept/avvisa-åtgärden kunna hamna innanför den debouncade 1s-
        // fönstret från `saveCullDecisions()` och riskera att gå förlorad om
        // appen stängs direkt efter.
        pipeline.flushCullDecisions()
        let accepted = pipeline.acceptedCount
        let rejected = pipeline.rejectedCount

        pipeline.statusMessage = switch AppSettings.shared.cullAction {
        case "radera": "Tar bort \(rejected) gallrade filer..."
        case "flytta": "Flyttar \(rejected) gallrade filer till Gallrade..."
        default: "Skriver gallringsbeslut som XMP-betyg (Lightroom)..."
        }

        Task {
            await runner.runner?.finishCullingAction()
            pipeline.updateStep(.manualReview, phase: .complete)
            pipeline.completeStep(.manualReview, count: accepted)
            pipeline.currentStep = .done
            pipeline.statusMessage = switch AppSettings.shared.cullAction {
            case "radera": "Gallring klar! \(accepted) bilder accepterade, \(rejected) borttagna."
            case "flytta": "Gallring klar! \(accepted) bilder accepterade, \(rejected) flyttade till Gallrade."
            default: "Gallring klar! \(accepted) bilder accepterade, \(rejected) markerade som avvisade (XMP-betyg, inget raderat)."
            }
            audio.playAllDone()
        }
    }

    // MARK: - "Föreslå gallring" (Fas 3b)

    /// Marks (never deletes — deletion only happens in `finishCulling`) the
    /// photos Vision considers worst: the sharpest/highest-quality photo in
    /// each duplicate group is kept, the rest in that group are suggested for
    /// rejection — that always happens. `isUtility` photos are only suggested
    /// when `AppSettings.cullSuggestUtility` is on (off by default, see
    /// FORBATTRINGAR.md Fas 3c — Vision flagged 34% of a real session as
    /// "utility" in the Fas 3b calibration, too high to suggest automatically
    /// without opt-in). Never touches a photo the user already decided on. See
    /// `PhotoQualityService.suggestCulling` for the pure decision logic.
    private func suggestCulling() {
        let candidates = pipeline.allPhotos.map { photo in
            PhotoQualityService.CullCandidate(
                id: photo.id,
                isUtility: photo.isUtility,
                qualityScore: photo.qualityScore,
                sharpness: photo.sharpness,
                duplicateGroupID: photo.duplicateGroupID,
                isDecided: photo.accepted || photo.rejected
            )
        }
        let includeUtility = AppSettings.shared.cullSuggestUtility
        let suggestion = PhotoQualityService.suggestCulling(candidates, includeUtility: includeUtility)

        guard !suggestion.isEmpty else {
            let reason = includeUtility
                ? "inga dubbletter eller nyttobilder kvar att bedöma"
                : "inga dubbletter kvar att bedöma (nyttobilder är avstängt, se Inställningar)"
            showSuggestionMessage("Inga förslag att gallra — \(reason).")
            return
        }

        let suggestedIDs = suggestion.all
        var undoEntries: [(id: String, wasAccepted: Bool, wasRejected: Bool)] = []
        for photo in pipeline.allPhotos where suggestedIDs.contains(photo.id) {
            undoEntries.append((photo.id, photo.accepted, photo.rejected))
            pipeline.setDecision(photoID: photo.id, accepted: false, rejected: true)
        }
        pushUndo(UndoAction(entries: undoEntries))
        pipeline.saveCullDecisions()
        audio.playReject()

        var parts: [String] = []
        if !suggestion.duplicates.isEmpty { parts.append("\(suggestion.duplicates.count) dubbletter") }
        if !suggestion.utility.isEmpty { parts.append("\(suggestion.utility.count) nyttobilder") }
        showSuggestionMessage("Föreslog \(undoEntries.count) bilder för gallring (\(parts.joined(separator: ", "))). Tryck z (eller ⌘Z) för att ångra.")
    }

    // MARK: - Generell ångra-stack (Fas 4)

    /// Pushes a new undo action, capping the stack at `maxUndoStackSize` by
    /// dropping the oldest action(s) — never dropping in the middle of a
    /// batch, since each `UndoAction` must be undone as a whole.
    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        while undoStack.count > Self.maxUndoStackSize {
            undoStack.removeFirst()
        }
    }

    /// Pops and restores the most recent undoable action — a single manual
    /// accept/reject, or a whole "Föreslå gallring" batch. Bound to both `z`
    /// and `⌘Z` (see the `onKeyPress` handler in `body`).
    private func performUndo() {
        guard let action = undoStack.popLast() else {
            showSuggestionMessage("Inget att ångra.")
            return
        }
        for entry in action.entries {
            pipeline.setDecision(photoID: entry.id, accepted: entry.wasAccepted, rejected: entry.wasRejected)
        }
        pipeline.saveCullDecisions()
        let word = action.entries.count == 1 ? "beslut" : "beslut (\(action.entries.count) bilder)"
        showSuggestionMessage("Ångrade \(word).")
    }

    private func showSuggestionMessage(_ text: String) {
        withAnimation { suggestionMessage = text }
        suggestionMessageTask?.cancel()
        suggestionMessageTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { suggestionMessage = nil }
        }
    }
}

// MARK: - Stat pill

struct StatPill: View {
    let icon: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text("\(count)")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

