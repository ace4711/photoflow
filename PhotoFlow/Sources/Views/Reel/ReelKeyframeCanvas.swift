import SwiftUI

/// Källbilden med start- och slutram för rörelseeditorn (Regi R3). Ritar bara och översätter
/// pekarrörelser till nya nycklar via `ReelMotionGeometry`; vyn äger ingen modell. Ramarna är
/// exakt det utsnitt som renderas (samma klampning som `ReelTimeline.cropRect`/`containCrop`).
struct ReelKeyframeCanvas: View {
    enum End: Hashable { case start, end }

    let image: CGImage?
    let imageSize: CGSize
    let frameAspect: Double
    let fit: ReelSpec.Fit
    /// Rörelsen som visas (under dragning den ännu osparade).
    let motion: ReelSpec.Motion
    let boxes: [ReelImageAnalysis.Box]
    let showSubject: Bool
    @Binding var selected: End
    /// Anropas för varje pekarrörelse med ny rörelse och vilken ram som dras.
    let onDrag: (ReelSpec.Motion, End) -> Void
    /// Dragningen är slut (musknappen släppt).
    let onDragEnd: () -> Void
    /// Piltangent: ny rörelse för vald ram.
    let onNudge: (ReelSpec.Motion) -> Void

    private struct DragState {
        enum Mode { case move, resize(ReelMotionGeometry.Corner) }
        var end: End
        var mode: Mode
        var startRect: CGRect
        var startCorner: CGPoint
    }

    @State private var drag: DragState?
    @FocusState private var focused: Bool

    private static let startColor = Color.green
    private static let endColor = Color.orange
    private static let handleHit: CGFloat = 16

    private var imageAspect: Double { Double(imageSize.width / max(imageSize.height, 1)) }

    private func key(_ end: End) -> ReelSpec.MotionKey { end == .start ? motion.from : motion.to }

    private func rect(_ end: End) -> CGRect {
        ReelMotionGeometry.frame(for: key(end), fit: fit, imageSize: imageSize, frameAspect: frameAspect)
    }

    private func color(_ end: End) -> Color { end == .start ? Self.startColor : Self.endColor }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                backdrop
                if showSubject { subjectLayer(size) }
                frameLayer(.start, size)
                frameLayer(.end, size)
                arrow(size)
                handles(.start, size)
                handles(.end, size)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in nudge(press) }
        }
        .aspectRatio(imageAspect, contentMode: .fit)
    }

    // MARK: Lager

    @ViewBuilder private var backdrop: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
        } else {
            Color.gray.opacity(0.25).overlay(ProgressView())
        }
    }

    private func px(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func subjectLayer(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, b in
                let r = px(CGRect(x: b.x, y: b.y, width: b.width, height: b.height), size)
                Rectangle()
                    .fill(Color.yellow.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private func frameLayer(_ end: End, _ size: CGSize) -> some View {
        let r = px(rect(end), size)
        let isSelected = selected == end
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color(end).opacity(isSelected ? 0.14 : 0.07))
            Rectangle()
                .strokeBorder(color(end), lineWidth: isSelected ? 3 : 2)
            Text(end == .start ? "Start" : "Slut")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color(end), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .frame(width: r.width, height: r.height)
        .contentShape(Rectangle())
        .pointerStyle(drag == nil ? .grabIdle : .grabActive)
        .offset(x: r.minX, y: r.minY)
    }

    private func handles(_ end: End, _ size: CGSize) -> some View {
        let r = px(rect(end), size)
        return ZStack(alignment: .topLeading) {
            ForEach(ReelMotionGeometry.Corner.allCases, id: \.self) { corner in
                let p = ReelMotionGeometry.point(of: corner, in: rect(end))
                Rectangle()
                    .fill(color(end))
                    .overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
                    .frame(width: 9, height: 9)
                    .frame(width: Self.handleHit, height: Self.handleHit)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: Self.position(corner)))
                    .offset(x: p.x * size.width - Self.handleHit / 2, y: p.y * size.height - Self.handleHit / 2)
            }
        }
        .opacity(r.width > 0 ? 1 : 0)
    }

    private static func position(_ c: ReelMotionGeometry.Corner) -> FrameResizePosition {
        switch c {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private func arrow(_ size: CGSize) -> some View {
        let a = CGPoint(x: rect(.start).midX * size.width, y: rect(.start).midY * size.height)
        let b = CGPoint(x: rect(.end).midX * size.width, y: rect(.end).midY * size.height)
        return Path { path in
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 8 else { return }
            path.move(to: a)
            path.addLine(to: b)
            let ux = dx / length, uy = dy / length
            let head: CGFloat = 9
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - ux * head - uy * head * 0.5, y: b.y - uy * head + ux * head * 0.5))
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - ux * head + uy * head * 0.5, y: b.y - uy * head - ux * head * 0.5))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .allowsHitTesting(false)
    }

    // MARK: Dragning

    private func hitTest(_ p: CGPoint, _ size: CGSize) -> DragState? {
        let order: [End] = selected == .start ? [.start, .end] : [.end, .start]
        for end in order {
            let r = rect(end)
            for corner in ReelMotionGeometry.Corner.allCases {
                let c = ReelMotionGeometry.point(of: corner, in: r)
                if hypot(c.x * size.width - p.x, c.y * size.height - p.y) <= Self.handleHit {
                    return DragState(end: end, mode: .resize(corner), startRect: r, startCorner: c)
                }
            }
        }
        for end in order where px(rect(end), size).contains(p) {
            return DragState(end: end, mode: .move, startRect: rect(end), startCorner: .zero)
        }
        return nil
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                if drag == nil {
                    guard let state = hitTest(value.startLocation, size) else { return }
                    drag = state
                    selected = state.end
                }
                guard let state = drag, size.width > 0, size.height > 0 else { return }
                let newRect: CGRect
                switch state.mode {
                case .move:
                    newRect = ReelMotionGeometry.moved(state.startRect, by: CGSize(
                        width: value.translation.width / size.width, height: value.translation.height / size.height))
                case .resize(let corner):
                    let target = CGPoint(x: state.startCorner.x + value.translation.width / size.width,
                                         y: state.startCorner.y + value.translation.height / size.height)
                    newRect = ReelMotionGeometry.resized(state.startRect, corner: corner, to: target,
                                                         fit: fit, imageSize: imageSize, frameAspect: frameAspect)
                }
                let newKey = ReelMotionGeometry.key(for: newRect, fit: fit, imageSize: imageSize, frameAspect: frameAspect)
                var m = motion
                if state.end == .start { m.from = newKey } else { m.to = newKey }
                onDrag(m, state.end)
            }
            .onEnded { _ in
                if drag != nil { onDragEnd() }
                drag = nil
            }
    }

    // MARK: Tangentbord

    /// Piltangenter flyttar den valda ramen 1 % av bilden (⇧ = 5 %).
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? 0.05 : 0.01
        var d = CGSize.zero
        switch press.key {
        case .leftArrow: d.width = -step
        case .rightArrow: d.width = step
        case .upArrow: d.height = -step
        case .downArrow: d.height = step
        default: return .ignored
        }
        let moved = ReelMotionGeometry.moved(rect(selected), by: d)
        let newKey = ReelMotionGeometry.key(for: moved, fit: fit, imageSize: imageSize, frameAspect: frameAspect)
        var m = motion
        if selected == .start { m.from = newKey } else { m.to = newKey }
        onNudge(m)
        return .handled
    }
}
