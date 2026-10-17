import SwiftUI
import AppKit

/// Tidslinjen i bildspelsfönstret (ersätter filmremsan): klippblock med bredd proportionell mot
/// längden, övergångar som överlapp med ett chip i skarven, och ett spelhuvud som följer
/// förhandsvisningen. All geometri och träffbestämning ligger i `ReelTimelineLayout`; vyn ritar och
/// översätter en enda dragning (`DragGesture`) till rätt åtgärd utifrån vad som träffades när den började:
///
/// - klipp: klick markerar klippet och flyttar spelhuvudet dit, dragning i sidled flyttar det,
/// - högerkanten: dragning ändrar längden (visas live, och sparas som ett enda steg vid släpp),
/// - övergångschip: klick markerar övergången, dragning i sidled ändrar dess längd (åt vänster =
///   längre, så att chipet följer pekaren; snäpper till 0,05 s, 0,2–1,5 s, klampas mot de två klippens
///   längd) och låser den med behållen typ. Chipet valdes framför överlappets kant eftersom
///   överlappet bara är ca 20–40 px brett och kanten därför ligger under chipet,
/// - linjalen och tom yta: klick och dragning flyttar spelhuvudet.
struct ReelTimelineView: View {
    let model: ReelEditorModel
    let preview: ReelPreviewModel

    /// Pågående dragning (bara för ritning; modellen ändras först vid släpp).
    private enum Drag: Equatable {
        case resize(index: Int, duration: Double)
        case move(index: Int, dx: Double)
        /// Övergången in till klipp `index` med utkastets längd.
        case transition(index: Int, duration: Double)
    }

    /// Vad dragningen gäller, bestämt av första träffen.
    private enum Mode: Equatable {
        case scrub
        case clip(Int)
        case edge(Int)
        case transition(Int)
    }

    @State private var drag: Drag?
    @State private var mode: Mode?
    @State private var cursorPushed = false
    @FocusState private var focused: Bool

    private static let inset = 12.0
    private static let rulerHeight = 22.0
    private static let blockTop = 28.0
    private static let blockHeight = 96.0
    static let height = blockTop + blockHeight + 14

    var body: some View {
        GeometryReader { geo in
            if let spec = model.spec, !spec.timeline.isEmpty {
                content(spec, availableWidth: geo.size.width)
            }
        }
        .frame(height: Self.height)
    }

    // MARK: Innehåll

    private func content(_ committed: ReelSpec, availableWidth: Double) -> some View {
        let total = ReelTimeline.totalDuration(committed)
        // Skalan följer den sparade filmen, inte utkastet under en dragning, så att den inte hoppar.
        let pps = ReelTimelineLayout.pixelsPerSecond(totalDuration: total, availableWidth: availableWidth - 2 * Self.inset)
        var shown = committed
        if case .resize(let i, let d) = drag, shown.timeline.indices.contains(i) { shown.timeline[i].duration = d }
        if case .transition(let i, let d) = drag, shown.timeline.indices.contains(i) {
            var t = shown.timeline[i].transitionIn ?? shown.style.defaultTransition
            t.duration = d
            shown.timeline[i].transitionIn = t
        }
        let layout = ReelTimelineLayout.layout(shown, pixelsPerSecond: pps)
        let rows = model.clipRows
        let width = max(layout.contentWidth + 2 * Self.inset + 40, availableWidth)

        return ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in drawRuler(&context, layout: layout) }
                    .frame(width: width, height: Self.rulerHeight)

                ForEach(layout.blocks, id: \.assetID) { block in
                    if let row = rows.first(where: { $0.id == block.assetID }) {
                        blockView(block, row: row, clip: shown.timeline[block.index])
                    }
                }

                ForEach(layout.joins, id: \.assetID) { join in
                    if join.width > 0 {
                        Rectangle()
                            .fill(Color.accentColor.opacity(model.selectedTransitionAssetID == join.assetID ? 0.55 : 0.32))
                            .frame(width: join.width, height: Self.blockHeight)
                            .offset(x: Self.inset + join.x, y: Self.blockTop)
                            .allowsHitTesting(false)
                    }
                }

                ForEach(layout.blocks, id: \.assetID) { block in
                    edgeHandle(block)
                }

                ForEach(layout.joins, id: \.assetID) { join in
                    chip(join)
                }

                dropIndicator(layout)
                PlayheadView(preview: preview, pixelsPerSecond: pps, inset: Self.inset)
                    .frame(width: width, height: Self.height, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(dragGesture(layout, spec: committed))
            .onContinuousHover { phase in updateCursor(phase, layout: layout) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.delete) { deleteSelected() }
        .onKeyPress(.deleteForward) { deleteSelected() }
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
    }

    // MARK: Delar

    private func blockView(_ block: ReelTimelineLayout.Block, row: ReelEditorModel.ClipRow, clip: ReelSpec.Clip) -> some View {
        let isSelected = model.selectedAssetID == block.assetID
        var dx = 0.0
        var moving = false
        if case .move(let i, let d) = drag, i == block.index { dx = d; moving = true }
        let locked = clip.durationLocked == true || row.preset != .auto || clip.transitionLocked == true
        return ClipBlock(row: row, duration: block.duration, width: block.width, height: Self.blockHeight,
                         isSelected: isSelected, isLocked: locked, lockHelp: Self.lockHelp(clip, row: row))
            .offset(x: Self.inset + block.x + dx, y: Self.blockTop)
            .opacity(moving ? 0.8 : 1)
            .zIndex(moving ? 10 : Double(block.index))
    }

    /// Greppet på högerkanten; syns tydligare på det markerade klippet.
    private func edgeHandle(_ block: ReelTimelineLayout.Block) -> some View {
        let isSelected = model.selectedAssetID == block.assetID
        var showsLabel = false
        if case .resize(let i, _) = drag, i == block.index { showsLabel = true }
        return Capsule()
            .fill(.white.opacity(isSelected || showsLabel ? 0.95 : 0.55))
            .frame(width: 4, height: 28)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .overlay(alignment: .top) {
                if showsLabel {
                    Text(ReelMotionEditor.seconds(block.duration))
                        .font(.caption.bold()).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(y: -22)
                }
            }
            .offset(x: Self.inset + block.end - 5, y: Self.blockTop + Self.blockHeight / 2 - 14)
            .allowsHitTesting(false)
            .zIndex(20)
    }

    private func chip(_ join: ReelTimelineLayout.Join) -> some View {
        let isSelected = model.selectedTransitionAssetID == join.assetID
        let half = ReelTimelineLayout.chipHalfWidth
        return Image(systemName: Self.symbol(join.type, join.direction))
            .font(.system(size: 11, weight: .semibold))
            .frame(width: half * 2, height: half * 2)
            .background(isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor), in: Circle())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .overlay(Circle().stroke(isSelected ? Color.white : Color.secondary.opacity(0.6), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if join.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .padding(2)
                        .background(Color.orange, in: Circle())
                        .foregroundStyle(.white)
                        .offset(x: 4, y: -4)
                }
            }
            .overlay(alignment: .top) {
                if case .transition(let i, _) = drag, i == join.index {
                    Text(ReelTransitionEditor.seconds(join.duration))
                        .font(.caption.bold()).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(y: -24)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1.5)
            .offset(x: Self.inset + join.centerX - half, y: Self.chipCenterY - half)
            .help(Self.chipHelp(join))
            .zIndex(30)
    }

    private static var chipCenterY: Double { blockTop + blockHeight / 2 }

    /// Där ett flyttat block hamnar: en lodrät linje i luckan mellan två andra block.
    @ViewBuilder
    private func dropIndicator(_ layout: ReelTimelineLayout.Layout) -> some View {
        if case .move(let i, let dx) = drag, abs(dx) > 3 {
            let target = ReelTimelineLayout.dropIndex(layout, dragging: i, dx: dx)
            let others = layout.blocks.filter { $0.index != i }
            let x = target < others.count ? others[target].x : (others.last?.end ?? 0)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3, height: Self.blockHeight + 8)
                .offset(x: Self.inset + x - 1.5, y: Self.blockTop - 4)
                .allowsHitTesting(false)
                .zIndex(40)
        }
    }

    private func drawRuler(_ context: inout GraphicsContext, layout: ReelTimelineLayout.Layout) {
        let pps = layout.pixelsPerSecond
        let labelEvery = pps >= 28 ? 1 : 2
        var t = 0
        while Double(t) <= layout.totalDuration + 0.001 {
            let x = Self.inset + Double(t) * pps
            var path = Path()
            path.move(to: CGPoint(x: x, y: Self.rulerHeight - 6))
            path.addLine(to: CGPoint(x: x, y: Self.rulerHeight))
            context.stroke(path, with: .color(.secondary), lineWidth: 1)
            if t % labelEvery == 0 {
                context.draw(Text("\(t) s").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
            }
            t += 1
        }
        var base = Path()
        base.move(to: CGPoint(x: Self.inset, y: Self.rulerHeight - 0.5))
        base.addLine(to: CGPoint(x: Self.inset + layout.contentWidth, y: Self.rulerHeight - 0.5))
        context.stroke(base, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
    }

    // MARK: Interaktion

    private func dragGesture(_ layout: ReelTimelineLayout.Layout, spec: ReelSpec) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if mode == nil {
                    focused = true
                    mode = startMode(at: value.startLocation, layout: layout)
                }
                switch mode {
                case .scrub:
                    scrub(toX: value.location.x, layout: layout)
                case .clip(let i):
                    if abs(value.translation.width) > 4 { drag = .move(index: i, dx: value.translation.width) }
                case .edge(let i):
                    let original = spec.timeline[i].duration
                    let d = ReelTimelineLayout.draggedDuration(from: original, dx: value.translation.width,
                                                               pixelsPerSecond: layout.pixelsPerSecond,
                                                               range: ReelEditorModel.durationRange)
                    drag = .resize(index: i, duration: d)
                case .transition(let i):
                    // Hårt klipp har ingen längd att dra i: då blir det bara ett klick.
                    // Utgå från den sparade specen (layouten visar redan utkastet).
                    let original = spec.timeline[i].transitionIn ?? spec.style.defaultTransition
                    guard original.type != .cut, abs(value.translation.width) > 3 else { break }
                    let d = ReelTimelineLayout.draggedTransition(from: original.duration, dx: value.translation.width,
                                                                 pixelsPerSecond: layout.pixelsPerSecond,
                                                                 limit: min(spec.timeline[i - 1].duration, spec.timeline[i].duration))
                    drag = .transition(index: i, duration: d)
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { mode = nil; drag = nil }
                switch mode {
                case .scrub:
                    scrub(toX: value.location.x, layout: layout)
                case .clip(let i):
                    if case .move(_, let dx) = drag {
                        let id = layout.blocks[i].assetID
                        model.moveClip(id, to: ReelTimelineLayout.dropIndex(layout, dragging: i, dx: dx))
                        model.selectedAssetID = id
                    } else {
                        selectClip(layout.blocks[i])
                    }
                case .edge(let i):
                    if case .resize(_, let d) = drag {
                        let block = layout.blocks[i]
                        if abs(d - spec.timeline[i].duration) > 1e-9 { model.setDuration(block.assetID, seconds: d) }
                        model.selectedAssetID = block.assetID
                    } else {
                        selectClip(layout.blocks[i])
                    }
                case .transition(let i):
                    if let join = layout.joins.first(where: { $0.index == i }) {
                        var t = spec.timeline[i].transitionIn ?? spec.style.defaultTransition
                        if case .transition(_, let d) = drag, abs(d - t.duration) > 1e-9 {
                            // Dragning låser övergången och behåller typ och riktning.
                            t.duration = d
                            model.setTransition(join.assetID, t)
                        }
                        model.selectedTransitionAssetID = join.assetID
                    }
                case nil:
                    break
                }
            }
    }

    private func startMode(at p: CGPoint, layout: ReelTimelineLayout.Layout) -> Mode {
        guard p.y >= Self.rulerHeight else { return .scrub }
        let overChip = abs(p.y - Self.chipCenterY) <= ReelTimelineLayout.chipHalfWidth
        switch ReelTimelineLayout.hit(layout, x: p.x - Self.inset, overChip: overChip) {
        case .clip(let i): return .clip(i)
        case .clipEdge(let i): return .edge(i)
        case .transition(let i): return .transition(i)
        case .empty: return .scrub
        }
    }

    private func scrub(toX x: Double, layout: ReelTimelineLayout.Layout) {
        preview.seek(to: ReelTimelineLayout.time(atX: x - Self.inset, pixelsPerSecond: layout.pixelsPerSecond,
                                                 totalDuration: layout.totalDuration))
    }

    private func selectClip(_ block: ReelTimelineLayout.Block) {
        model.selectedAssetID = block.assetID
        preview.seek(to: block.start)
    }

    private func deleteSelected() -> KeyPress.Result {
        guard let id = model.selectedAssetID, model.clipRows.count > 1 else { return .ignored }
        model.removeClip(id)
        return .handled
    }

    /// Storleksmarkör över högerkanten.
    private func updateCursor(_ phase: HoverPhase, layout: ReelTimelineLayout.Layout) {
        var overEdge = false
        if case .active(let p) = phase, p.y >= Self.blockTop, p.y <= Self.blockTop + Self.blockHeight {
            if case .clipEdge = ReelTimelineLayout.hit(layout, x: p.x - Self.inset, overChip: false) { overEdge = true }
        }
        guard mode == nil else { return }   // under en dragning ändras markören inte
        if overEdge, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        if !overEdge, cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    // MARK: Text och symboler

    static func symbol(_ type: ReelSpec.TransitionType, _ direction: ReelSpec.Direction?) -> String {
        switch type {
        case .crossfade: return "circle.lefthalf.filled"
        case .cut: return "scissors"
        case .fadeThroughBlack: return "square.fill"
        case .push:
            switch direction {
            case .left: return "arrow.left"
            case .up: return "arrow.up"
            case .down: return "arrow.down"
            default: return "arrow.right"
            }
        }
    }

    static func typeLabel(_ type: ReelSpec.TransitionType) -> String {
        switch type {
        case .crossfade: return "Mjuk tona"
        case .cut: return "Hårt klipp"
        case .fadeThroughBlack: return "Via svart"
        case .push: return "Skjut"
        }
    }

    static func directionLabel(_ d: ReelSpec.Direction) -> String {
        switch d {
        case .left: return "åt vänster"
        case .right: return "åt höger"
        case .up: return "uppåt"
        case .down: return "nedåt"
        }
    }

    private static func chipHelp(_ join: ReelTimelineLayout.Join) -> String {
        var text = typeLabel(join.type)
        if let d = join.direction, join.type == .push { text += " \(directionLabel(d))" }
        if join.type != .cut { text += ", \(ReelMotionEditor.seconds(join.duration))" }
        return text + (join.locked ? " (låst, klicka för att ändra)" : " (automatisk, klicka för att ändra)")
    }

    private static func lockHelp(_ clip: ReelSpec.Clip, row: ReelEditorModel.ClipRow) -> String {
        var parts: [String] = []
        if clip.durationLocked == true { parts.append("längd") }
        if row.preset != .auto { parts.append("rörelse") }
        if clip.transitionLocked == true { parts.append("övergång") }
        return "Låst: " + parts.joined(separator: ", ")
    }
}

// MARK: - Klippblock

private struct ClipBlock: View {
    let row: ReelEditorModel.ClipRow
    let duration: Double
    let width: Double
    let height: Double
    let isSelected: Bool
    let isLocked: Bool
    let lockHelp: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            LocalThumbnailView(url: row.url)
                .frame(width: width, height: height)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("\(row.index + 1)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer(minLength: 0)
                    if isLocked, width > 56 {
                        Image(systemName: "lock.fill").font(.caption2).help(lockHelp)
                    }
                }
                Spacer(minLength: 0)
                if width > 70 {
                    Text(row.room ?? row.filename).font(.caption).lineLimit(1)
                }
                Text(ReelMotionEditor.seconds(duration)).font(.caption2).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(5)
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.black.opacity(0.35),
                                                          lineWidth: isSelected ? 3 : 1))
        .help(row.reason)
    }
}

// MARK: - Spelhuvud

/// Egen vy så att bara den ritas om när uppspelningen tickar (`preview.time`).
private struct PlayheadView: View {
    let preview: ReelPreviewModel
    let pixelsPerSecond: Double
    let inset: Double

    var body: some View {
        let x = inset + ReelTimelineLayout.x(forTime: preview.time, pixelsPerSecond: pixelsPerSecond)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.red).frame(width: 2, height: ReelTimelineView.height - 4)
                .offset(x: x - 1, y: 2)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10)).foregroundStyle(.red)
                .offset(x: x - 5, y: 0)
        }
    }
}
