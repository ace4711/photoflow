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

    private let audio = AudioService.shared

    var currentPhoto: PhotoItem? {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return nil }
        return pipeline.allPhotos[pipeline.currentCullIndex]
    }

    var acceptedCount: Int { pipeline.allPhotos.filter { $0.accepted }.count }
    var rejectedCount: Int { pipeline.allPhotos.filter { $0.rejected }.count }
    var unreviewedCount: Int { pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count }

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
        }
        .onChange(of: pipeline.currentCullIndex) { _, _ in
            // Auto-show notes if photo has a note, auto-hide if not (and not recording)
            if let photo = currentPhoto, notesManager.noteFor(photoId: photo.id) != nil {
                showNotes = true
            } else if !dictation.isRecording {
                showNotes = false
            }
        }
        .overlay(alignment: .bottom) {
            CountdownOverlay()
                .padding(.bottom, 20)
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

            // Large image
            if let photo = currentPhoto {
                ProgressiveImageView(previewURL: photo.previewURL, fullResURL: photo.nefURL, dngURL: photo.dngURL)
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
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var fullscreenBottomBar: some View {
        VStack(spacing: 0) {
            // Filmstrip on top
            filmstrip
                .frame(height: 90)

            // Large symbol bar on bottom
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
                fsSymbol(icon: "arrow.down.right.and.arrow.up.left", label: "F", color: .white, action: { withAnimation { isFullscreen = false } })
                Spacer()
                fsSymbol(icon: "rectangle.portrait.and.arrow.right", label: "ESC", color: .orange, action: finishCulling)
                Spacer()
            }
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
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
        .buttonStyle(.plain)
        .frame(width: 80)
    }

    // MARK: - Header (normal mode)

    private var headerBar: some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
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

                symbolButton(icon: "arrow.up.left.and.arrow.down.right", label: "F", color: .secondary, action: { withAnimation(.easeInOut(duration: 0.25)) { isFullscreen.toggle() } })
                Spacer()
                symbolButton(icon: "rectangle.portrait.and.arrow.right", label: "ESC", color: .orange, action: finishCulling)
                Spacer()
            }
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(pipeline.allPhotos.enumerated()), id: \.element.id) { index, photo in
                        filmstripThumb(photo: photo, index: index)
                            .id(index)
                            .onTapGesture {
                                pipeline.currentCullIndex = index
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
        let bg = photo.accepted ? Color.green.opacity(0.9) : (photo.rejected ? Color.red.opacity(0.9) : Color.gray.opacity(0.7))

        Label(text, systemImage: icon)
            .font(.title2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 180)
            .background(bg)
            .cornerRadius(10)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .frame(width: 80)
    }

    private func photoInfoBar(for photo: PhotoItem) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Text(photo.displayName).fontWeight(.bold)
                Text(photo.exposureDisplay)
                Text("f/\(String(format: "%.1f", photo.fNumber))")
                Text("ISO \(photo.iso)")
            }
            .font(.system(.body, design: .monospaced))

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
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func navigate(_ direction: Int) {
        let newIndex = pipeline.currentCullIndex + direction
        if newIndex >= 0 && newIndex < pipeline.allPhotos.count {
            pipeline.currentCullIndex = newIndex
        }
    }

    private func acceptPhoto() {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return }
        pipeline.allPhotos[pipeline.currentCullIndex].accepted = true
        pipeline.allPhotos[pipeline.currentCullIndex].rejected = false
        audio.playAccept()
        pipeline.saveCullDecisions()
        navigate(1)
    }

    private func rejectPhoto() {
        guard pipeline.currentCullIndex < pipeline.allPhotos.count else { return }
        pipeline.allPhotos[pipeline.currentCullIndex].accepted = false
        pipeline.allPhotos[pipeline.currentCullIndex].rejected = true
        audio.playReject()
        pipeline.saveCullDecisions()
        navigate(1)
    }

    private func finishCulling() {
        let accepted = pipeline.allPhotos.filter { $0.accepted }.count
        let rejected = pipeline.allPhotos.filter { $0.rejected }.count
        pipeline.statusMessage = "Tar bort \(rejected) gallrade filer..."

        Task {
            await runner.runner?.deleteRejectedFiles()
            pipeline.updateStep(.manualReview, phase: .complete)
            pipeline.completeStep(.manualReview, count: accepted)
            pipeline.currentStep = .done
            pipeline.statusMessage = "Gallring klar! \(accepted) bilder accepterade, \(rejected) borttagna."
            audio.playAllDone()
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

