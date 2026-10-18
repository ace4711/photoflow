import SwiftUI

/// Bildytan: sida vid sida med gemensam zoom, svepreglage eller A/B-växling.
struct HDRCompareStage: View {
    @Bindable var model: HDRCompareModel
    @Environment(\.displayScale) private var displayScale
    @State private var paneSize: CGSize = .zero

    var body: some View {
        Group {
            if let d = model.displayPair {
                switch model.mode {
                case .sideBySide: sideBySide(d)
                case .swipe: swipe(d)
                case .flip: flip()
                }
            } else {
                ContentUnavailableView("Inget par att jämföra", systemImage: "photo.on.rectangle",
                                       description: Text("Gruppen har färre än två varianter på disk."))
            }
        }
        .background(Color.black)
        // Kortkommandon: S svep, mellanslag växla, Z 100 %, B blindläge.
        .background { shortcuts }
        .onChange(of: model.viewport.scale) { _, scale in
            if scale > 1.5 { model.ensureFullResolution() }
        }
    }

    // MARK: - Lägen

    private func sideBySide(_ d: (left: String, right: String)) -> some View {
        HStack(spacing: 2) {
            pane(d.left, position: "A")
            pane(d.right, position: "B")
            if let ref = model.referenceVariant { pane(ref, position: "Ref") }
        }
    }

    private func pane(_ variant: String, position: String) -> some View {
        ZStack(alignment: .topLeading) {
            paneContent(variant)
            label(model.label(for: variant, position: position))
        }
        .clipped()
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { paneSize = $0 }
    }

    private func swipe(_ d: (left: String, right: String)) -> some View {
        GeometryReader { geo in
            let x = geo.size.width * model.swipeFraction
            ZStack(alignment: .topLeading) {
                paneContent(d.left, interactive: false)
                paneContent(d.right, interactive: false)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: max(geo.size.width - x, 0))
                    }
                if let img = model.image(for: d.left) {
                    CompareInteractionLayer(viewport: model.viewport, aspect: aspect(img)) { toggleHundred() }
                }
                // Delningslinje med grepp; bara greppet fångar drag, resten panorerar bilden.
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2).offset(x: x - 1)
                    .allowsHitTesting(false)
                Circle().fill(.white).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                    .shadow(radius: 2)
                    .position(x: x, y: geo.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.swipeFraction = min(max(v.location.x / max(geo.size.width, 1), 0.02), 0.98)
                    })
                label(model.label(for: d.left, position: "A"))
                label(model.label(for: d.right, position: "B"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .clipped()
            .onAppear { paneSize = geo.size }
            .onChange(of: geo.size) { _, s in paneSize = s }
        }
    }

    private func flip() -> some View {
        let seq = model.flipSequence
        let i = seq.isEmpty ? 0 : model.flipIndex % seq.count
        let variant = seq.isEmpty ? "" : seq[i]
        let position = i == 0 ? "A" : (i == 1 ? "B" : "Ref")
        return ZStack(alignment: .topLeading) {
            paneContent(variant)
            label(model.label(for: variant, position: position))
        }
        .clipped()
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { paneSize = $0 }
    }

    // MARK: - Delar

    @ViewBuilder
    private func paneContent(_ variant: String, interactive: Bool = true) -> some View {
        if let img = model.image(for: variant) {
            ZStack {
                CompareImageCanvas(image: img, viewport: model.viewport)
                if interactive {
                    CompareInteractionLayer(viewport: model.viewport, aspect: aspect(img)) { toggleHundred() }
                }
            }
        } else {
            ZStack {
                if model.selectedGroup.map({ (model.available[$0.id] ?? []).contains(variant) }) == true {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Saknas").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func aspect(_ img: CGImage) -> CGFloat { CGFloat(img.width) / CGFloat(max(img.height, 1)) }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
            .allowsHitTesting(false)
    }

    private func toggleHundred() {
        model.toggleHundredPercent(paneSize: paneSize, displayScale: displayScale)
    }

    private var shortcuts: some View {
        Group {
            Button("Svep") { model.mode = model.mode == .swipe ? .sideBySide : .swipe }
                .keyboardShortcut("s", modifiers: [])
            Button("Växla A/B") {
                if model.mode != .flip { model.mode = .flip } else { model.flipIndex += 1 }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("100 %") { toggleHundred() }
                .keyboardShortcut("z", modifiers: [])
            Button("Blindläge") { model.blind.toggle() }
                .keyboardShortcut("b", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}
