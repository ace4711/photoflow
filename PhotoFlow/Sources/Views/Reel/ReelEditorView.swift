import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @State private var confirmStartOver = false
    /// Rutnätets filter (bara visning, sparas inte).
    @State private var scope: ReelCandidateFilter.Scope = .all
    @State private var roomFilter: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 1000, minHeight: 720)
        .navigationTitle(model.address.isEmpty ? "Bildspel" : "Bildspel — \(model.address)")
        .task { startIfNeeded() }
        .onAppear { model.undoManager = undoManager }
        .confirmationDialog("Börja om helt?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Börja om helt", role: .destructive) { model.startOver() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Alla lås kastas: bilder du låst eller uteslutit, ordning, längder, rörelser och övergångar du ändrat. Du kan ångra med ⌘Z.")
        }
        .onChange(of: model.revisionToken) { _, _ in
            preview.setSpec(model.spec, specDirectory: model.reelDirectory)
        }
        .onChange(of: model.phase) { _, phase in
            // Filmen är laddad: läs in kopplingen till mäklaren och hämta ändringar (en gång per mapp).
            guard case .ready = phase, let dir = model.reelDirectory, shareLoadedFor != dir else { return }
            shareLoadedFor = dir
            share.load(reelDirectory: dir)
            Task { await share.autoRefresh(into: model) }
            // Filmlistans "Ny länk…": öppna delningsarket direkt.
            if request.showShare == true { showShareSheet = true }
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
            // Den delade bildcachen (upp till ca 600 MB dekodade bilder) behövs inte när fönstret är stängt.
            ReelImageCache.shared.removeAll()
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
                .help("Antal bilder. Ger ett nytt förslag som behåller dina lås (låsta bilder, längder, rörelser och övergångar).")
                .disabled(model.isBusy)

                Menu {
                    Button("Föreslå igen") { model.suggestAgain() }
                    Button("Börja om helt…") { confirmStartOver = true }
                } label: {
                    Label("Föreslå igen", systemImage: "wand.and.stars")
                } primaryAction: {
                    model.suggestAgain()
                }
                .fixedSize()
                .disabled(model.isBusy)
                .help("Föreslå igen behåller allt du låst. Börja om helt kastar alla lås.")

                undoControls

                renderControls
                shareControls
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    /// Ångra och gör om; ⌘Z och ⇧⌘Z kommer via Redigera-menyn (fönstrets `UndoManager`).
    private var undoControls: some View {
        ControlGroup {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.isBusy)
                .help(model.undoActionName.map { "Ångra \($0.lowercased())" } ?? "Ångra")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo || model.isBusy)
                .help(model.redoActionName.map { "Gör om \($0.lowercased())" } ?? "Gör om")
        }
        .fixedSize()
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
            Button("Spela", systemImage: "play.fill") { openPlayer(url) }
            Button("Visa i Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Rendera igen") { model.render() }
        default:
            Button("Rendera", systemImage: "film") { model.render() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasFilm || model.isBusy)
                .help("Skapar reel_\(model.format.output.aspect.replacingOccurrences(of: ":", with: "x")).mp4 och reel.json i \(model.reelDirectory?.lastPathComponent ?? "film-mappen")")
        }
    }

    /// Öppnar spelarfönstret för den just renderade filmen.
    private func openPlayer(_ url: URL) {
        let output = model.spec?.outputs.first
        let aspect = output?.aspect ?? model.format.output.aspect
        openWindow(id: ReelPlayerWindow.id, value: ReelPlayerRequest(
            filePath: url.path, objectId: share.state?.objectId, renderId: nil,
            title: "\(model.address) · \(aspect)",
            width: output?.width ?? model.format.output.width, height: output?.height ?? model.format.output.height,
            folderPath: model.reelDirectory?.path, outputPath: request.outputPath))
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
            ReelTimelineView(model: model, preview: preview)
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
            ScrollView {
            if let id = model.selectedAssetID, let row = rows.first(where: { $0.id == id }) {
                ReelMotionEditor(
                    model: model, preview: preview, row: row,
                    clip: model.spec?.timeline.first { $0.asset == id })
                    .id(id)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) { closeInspectorButton }
            } else if let id = model.selectedTransitionAssetID, let spec = model.spec,
                      let index = spec.timeline.firstIndex(where: { $0.asset == id }), index > 0 {
                ReelTransitionEditor(model: model, preview: preview, spec: spec, index: index)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) { closeInspectorButton }
            } else {
                if let spec = model.spec {
                    ReelStylePanel(model: model, spec: spec)
                }
            }
            }
            Spacer(minLength: 0)
            if let dir = model.reelDirectory {
                Text("Sparas i \(dir.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Stänger inspektören (avmarkerar), så att filmens stil visas. Esc i tidslinjen gör samma sak.
    private var closeInspectorButton: some View {
        Button { model.clearSelection() } label: {
            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Stäng och visa filmens stil (Esc)")
    }

    // MARK: Kandidatrutnät

    /// Rutnätet med filter (läge och rum) överst. Klick: markera/byt/lägg till (`selectCandidate`);
    /// knapparna och kontextmenyn låser eller utesluter; bilden kan dras till tidslinjen.
    private var candidateGrid: some View {
        let all = model.candidateRows
        let rooms = ReelCandidateFilter.rooms(all)
        // Ett rum som inte finns längre (t.ex. efter byte av mapp) filtrerar inte bort allt.
        let room = roomFilter.flatMap { rooms.contains($0) ? $0 : nil }
        let counts = ReelCandidateFilter.counts(all, room: room)
        let shown = ReelCandidateFilter.filter(all, scope: scope, room: room)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Visa", selection: $scope) {
                    ForEach(ReelCandidateFilter.Scope.allCases, id: \.self) { s in
                        Text("\(s.label) (\(counts[s] ?? 0))").tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("Alla rum") { roomFilter = nil }
                    Divider()
                    ForEach(rooms, id: \.self) { r in
                        Button { roomFilter = r } label: {
                            if r == room { Label(r, systemImage: "checkmark") } else { Text(r) }
                        }
                    }
                } label: {
                    Label(room ?? "Alla rum", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .help("Visa bara bilder från ett rum")
                Spacer()
                Text("Dra en bild till tidslinjen: mellan två klipp infogas den, på ett klipp byter den bild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ScrollView {
                if shown.isEmpty {
                    Text("Inga bilder i det här urvalet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(24)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)], spacing: 10) {
                    ForEach(shown) { row in
                        CandidateCell(row: row, isReplaceTarget: model.selectedAssetID != nil, canAdd: model.canAddClip,
                                      onPin: { model.togglePinned(row.id) },
                                      onExclude: { model.toggleExcluded(row.id) })
                            .onTapGesture { model.selectCandidate(row.id) }
                            .onDrag {
                                model.draggedCandidateID = row.id
                                return NSItemProvider(object: ReelCandidateDrag.payload(row.id) as NSString)
                            }
                            .contextMenu { candidateMenu(row) }
                    }
                }
                .padding(10)
            }
        }
    }

    /// Samma val som knapparna i cellen, plus lägg till/byt/markera.
    @ViewBuilder
    private func candidateMenu(_ row: ReelEditorModel.CandidateRow) -> some View {
        Button(row.isPinned ? "Släpp låset" : "Lås i filmen", systemImage: row.isPinned ? "pin.slash" : "pin") {
            model.togglePinned(row.id)
        }
        Button(row.isUserExcluded ? "Ta tillbaka" : "Uteslut", systemImage: row.isUserExcluded ? "arrow.uturn.backward" : "nosign") {
            model.toggleExcluded(row.id)
        }
        Divider()
        if let i = row.clipIndex {
            Button("Markera klipp \(i + 1)") { model.selectCandidate(row.id) }
        } else {
            Button("Lägg till sist") { model.addCandidate(row.id) }
                .disabled(!model.canAddClip)
            if let selected = model.selectedAssetID, let index = model.clipRows.firstIndex(where: { $0.id == selected }) {
                Button("Byt bild i klipp \(index + 1)") { model.replaceClip(selected, withCandidate: row.id) }
            }
        }
    }
}

// MARK: - Delvyer

private struct CandidateCell: View {
    let row: ReelEditorModel.CandidateRow
    let isReplaceTarget: Bool
    let canAdd: Bool
    let onPin: () -> Void
    let onExclude: () -> Void

    private var borderColor: Color {
        if row.isUserExcluded { return .red.opacity(0.7) }
        if row.isPinned { return .orange }
        return row.clipIndex != nil ? .accentColor : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LocalThumbnailView(url: row.url)
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .saturation(row.isUserExcluded ? 0 : 1)
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
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        iconButton(row.isPinned ? "pin.fill" : "pin", tint: row.isPinned ? .orange : nil,
                                   help: row.isPinned ? "Släpp låset (bilden blir kvar i filmen)" : pinHelp, action: onPin)
                        iconButton("nosign", tint: row.isUserExcluded ? .red : nil,
                                   help: row.isUserExcluded ? "Ta tillbaka bilden" : "Uteslut: föreslås aldrig och tas bort ur filmen",
                                   action: onExclude)
                    }
                    .padding(4)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 2))
            HStack {
                Text(row.roomLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(ReelSelector.fmt(row.score))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("Poäng i urvalet (0–1)")
            }
            if let reason = row.excludedReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(row.isUserExcluded ? .red : .orange)
                    .lineLimit(2)
            } else if let reason = row.selectionReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .opacity(row.excludedReason == nil ? 1 : 0.65)
        .contentShape(Rectangle())
        .help(help)
    }

    private var pinHelp: String {
        if row.clipIndex != nil { return "Lås i filmen: bilden är kvar vid Föreslå igen" }
        return canAdd ? "Lås i filmen: läggs till sist och är kvar vid Föreslå igen"
                      : "Lås i filmen: filmen är full, bilden kommer med vid nästa Föreslå igen"
    }

    private var help: String {
        var lines = [row.filename]
        if let reason = row.excludedReason { lines.append(reason) } else if let reason = row.selectionReason { lines.append(reason) }
        if row.isPinned { lines.append("Låst i filmen") }
        if row.clipIndex != nil {
            lines.append("Klicka för att markera klippet")
        } else if isReplaceTarget {
            lines.append("Klicka för att byta det markerade klippets bild")
        } else {
            lines.append(canAdd ? "Klicka för att lägga till sist" : "Filmen är full (högst \(ReelEditorModel.countRange.upperBound) bilder)")
        }
        lines.append("Dra till tidslinjen för att infoga eller byta. Högerklicka för fler val.")
        return lines.joined(separator: "\n")
    }

    private func iconButton(_ symbol: String, tint: Color?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(tint ?? Color.black.opacity(0.45), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
