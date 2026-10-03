import SwiftUI
import AppKit

/// Bildspelsfönstret ("Objektfilm"): välj mapp med färdiga bilder, få ett automatiskt
/// förslag, justera (ordning, bilder, längd, rörelse, format) och rendera till mp4.
/// All logik ligger i `ReelEditorModel` och `ReelPreviewModel`; vyn ritar bara.
struct ReelEditorView: View {
    let request: ReelLaunchRequest

    @State private var model = ReelEditorModel()
    @State private var preview = ReelPreviewModel()
    @State private var share = ReelShareModel()
    @State private var didStart = false
    @State private var showShareSheet = false
    @State private var shareLoadedFor: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 1000, minHeight: 720)
        .navigationTitle(model.address.isEmpty ? "Bildspel" : "Bildspel — \(model.address)")
        .task { startIfNeeded() }
        .onChange(of: model.revisionToken) { _, _ in
            preview.setSpec(model.spec, specDirectory: model.reelDirectory)
        }
        .onChange(of: model.phase) { _, phase in
            // Filmen är laddad: läs in kopplingen till mäklaren och hämta ändringar (en gång per mapp).
            guard case .ready = phase, let dir = model.reelDirectory, shareLoadedFor != dir else { return }
            shareLoadedFor = dir
            share.load(reelDirectory: dir)
            Task { await share.autoRefresh(into: model) }
        }
        .sheet(isPresented: $showShareSheet) {
            ReelShareSheet(share: share, editor: model) { showShareSheet = false }
        }
        .alert(share.conflict?.title ?? "", isPresented: Binding(
            get: { share.conflict != nil }, set: { if !$0 { share.dismissConflict() } }
        ), presenting: share.conflict) { _ in
            Button("Ladda om") { share.resolveConflictByReloading(into: model) }
            Button("Avbryt", role: .cancel) { share.dismissConflict() }
        } message: { conflict in
            Text(conflict.message)
        }
        .onDisappear {
            model.cancelAll()
            preview.stop()
        }
    }

    // MARK: Start

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if let path = request.sourcePath {
            model.open(source: URL(fileURLWithPath: path), address: request.address, sessionID: request.sessionID,
                       aiTagsDirectory: request.outputPath.map { URL(fileURLWithPath: $0) })
        } else if request.startPath != nil {
            chooseSource()
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Välj"
        panel.message = "Välj mappen med färdiga bilder (till exempel \"<adress> FÄRDIGA\")"
        if let start = request.startPath ?? model.sourceDirectory?.deletingLastPathComponent().path {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.open(source: url, address: request.address, sessionID: request.sessionID,
                       aiTagsDirectory: request.outputPath.map { URL(fileURLWithPath: $0) })
        }
    }

    // MARK: Huvud

    private var header: some View {
        HStack(spacing: 12) {
            Button("Välj mapp…", systemImage: "folder") { chooseSource() }
                .disabled(model.isBusy)
            if let source = model.sourceDirectory {
                Text(source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.path)
            }
            Spacer()
            if model.spec != nil {
                Picker("Format", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                    Text("9:16").tag(ReelFormat.vertical)
                    Text("1:1").tag(ReelFormat.square)
                    Text("16:9").tag(ReelFormat.landscape)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .labelsHidden()
                .disabled(model.isBusy)

                Stepper(value: Binding(get: { model.count }, set: { model.setCount($0) }),
                        in: ReelEditorModel.countRange) {
                    Text("Bilder: \(model.count)")
                }
                .help("Antal bilder. Byter ut förslaget (manuella ändringar nollställs).")
                .disabled(model.isBusy)

                renderControls
                shareControls
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    /// Statusmärke, "Hämta ändringar" och "Skicka till mäklare…".
    @ViewBuilder
    private var shareControls: some View {
        Divider().frame(height: 20)
        Text(share.badge.label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
            .help(share.pendingRemoteRevision.map { "Mäklaren har en nyare version (rev \($0)). Klicka \"Hämta ändringar\"." } ?? "Status hos mäklaren")
        if share.pendingRemoteRevision != nil {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
        }
        if share.isLinked {
            Button("Hämta ändringar", systemImage: "arrow.down.circle") {
                Task { await share.pull(into: model) }
            }
            .disabled(model.isBusy || share.isBusy)
        }
        Button("Skicka till mäklare…", systemImage: "paperplane") { showShareSheet = true }
            .disabled(!model.hasFilm || model.isBusy)
    }

    private var badgeColor: Color {
        switch share.badge {
        case .draft: return .secondary
        case .withAgent: return .blue
        case .approvedWaiting: return .orange
        case .rendered: return .green
        }
    }

    @ViewBuilder
    private var renderControls: some View {
        switch model.phase {
        case .rendering(let p):
            ProgressView(value: p).frame(width: 120)
            Text("\(Int(p * 100)) %").font(.caption).monospacedDigit()
            Button("Avbryt") { model.cancelRender() }
        case .rendered(let url):
            Label("Klar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Visa i Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Rendera igen") { model.render() }
        default:
            Button("Rendera", systemImage: "film") { model.render() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasFilm || model.isBusy)
                .help("Skapar reel_\(model.format.output.aspect.replacingOccurrences(of: ":", with: "x")).mp4 och reel.json i \(model.reelDirectory?.lastPathComponent ?? "film-mappen")")
        }
    }

    // MARK: Innehåll

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle where model.spec == nil:
            ContentUnavailableView {
                Label("Inget bildspel", systemImage: "film")
            } description: {
                Text("Välj mappen med de färdiga bilderna så föreslår PhotoFlow en kort film.")
            } actions: {
                Button("Välj mapp…") { chooseSource() }
                    .buttonStyle(.borderedProminent)
            }
        case .analyzing(let done, let total):
            VStack(spacing: 12) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 320)
                Text("Analyserar bilderna… \(done) av \(total)")
                    .foregroundStyle(.secondary)
                Button("Avbryt") { model.cancelAll(); model.dismissError() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.spec == nil:
            ContentUnavailableView {
                Label("Det gick inte", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Välj mapp…") { chooseSource() }
            }
        default:
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = model.phase {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Stäng") { model.dismissError() }
                }
                .padding(8)
                .background(.orange.opacity(0.12))
            }
            if case .failed(let message) = share.phase, !showShareSheet {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Stäng") { share.dismissFailure() }
                }
                .padding(8)
                .background(.orange.opacity(0.12))
            } else if let notice = share.notice {
                Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.top, 4)
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal).padding(.top, 4)
            }
            HStack(alignment: .top, spacing: 16) {
                previewPane
                    .frame(width: 360)
                sidePane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding()
            .frame(height: 500)

            Divider()
            filmstrip
            Divider()
            candidateGrid
        }
    }

    // MARK: Förhandsvisning

    private var previewPane: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let frame = preview.frame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(preview.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button(action: { preview.togglePlay() }) {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .disabled(!model.hasFilm)
                .keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { preview.time }, set: { preview.seek(to: $0) }),
                       in: 0...max(preview.duration, 0.01))
                    .disabled(!model.hasFilm)
                Text("\(Self.clock(preview.time)) / \(Self.clock(preview.duration))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private static func clock(_ t: Double) -> String {
        String(format: "%.1f s", t).replacingOccurrences(of: ".", with: ",")
    }

    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            let rows = model.clipRows
            Text("Längd \(Self.clock(model.totalDuration)) · \(rows.count) klipp")
                .font(.headline)
            if let id = model.selectedAssetID, let row = rows.first(where: { $0.id == id }) {
                ReelMotionEditor(
                    row: row,
                    clip: model.spec?.timeline.first { $0.asset == id },
                    onPreset: { model.setPreset(id, $0) },
                    onDuration: { model.setDuration(id, seconds: $0) },
                    onAutoDuration: { model.clearDuration(id) })
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Markera ett klipp i filmremsan för att ändra rörelse och längd. Klicka på en bild i rutnätet nedan för att byta den markerade bilden, eller lägga till en ny sist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let dir = model.reelDirectory {
                Text("Sparas i \(dir.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Filmremsa

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(model.clipRows) { row in
                    ClipCard(row: row, isSelected: model.selectedAssetID == row.id,
                             canRemove: model.clipRows.count > 1,
                             onSelect: { model.selectedAssetID = row.id },
                             onRemove: { model.removeClip(row.id) },
                             onDuration: { model.setDuration(row.id, seconds: $0) })
                        .draggable(row.id)
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let dragged = dropped.first else { return false }
                            model.moveClip(dragged, before: row.id)
                            return true
                        }
                }
            }
            .padding(10)
        }
        .frame(height: 190)
    }

    // MARK: Kandidatrutnät

    private var candidateGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)], spacing: 10) {
                ForEach(model.candidateRows) { row in
                    CandidateCell(row: row, isReplaceTarget: model.selectedAssetID != nil)
                        .onTapGesture { model.selectCandidate(row.id) }
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Delvyer

private struct ClipCard: View {
    let row: ReelEditorModel.ClipRow
    let isSelected: Bool
    let canRemove: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onDuration: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                LocalThumbnailView(url: row.url)
                    .frame(width: 130, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("\(row.index + 1)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Ta bort ur filmen")
                }
            }
            Text(row.room ?? row.filename)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 130)
            Stepper(value: Binding(get: { row.duration }, set: { onDuration($0) }),
                    in: ReelEditorModel.durationRange, step: 0.1) {
                Text(ReelMotionEditor.seconds(row.duration))
                    .font(.caption).monospacedDigit()
            }
            .controlSize(.small)
            .frame(width: 130)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .help(row.reason)
    }
}

private struct CandidateCell: View {
    let row: ReelEditorModel.CandidateRow
    let isReplaceTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LocalThumbnailView(url: row.url)
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let i = row.clipIndex {
                        Text("\(i + 1)")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(row.clipIndex != nil ? Color.accentColor : .clear, lineWidth: 2))
            HStack {
                Text(row.room ?? row.category ?? "Okänt rum")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(ReelSelector.fmt(row.score))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let reason = row.excludedReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .opacity(row.excludedReason == nil ? 1 : 0.65)
        .contentShape(Rectangle())
        .help("\(row.filename)\(row.excludedReason.map { " — \($0)" } ?? "")\n" +
              (row.clipIndex != nil ? "Klicka för att markera klippet" :
                (isReplaceTarget ? "Klicka för att byta det markerade klippets bild" : "Klicka för att lägga till sist")))
    }
}
