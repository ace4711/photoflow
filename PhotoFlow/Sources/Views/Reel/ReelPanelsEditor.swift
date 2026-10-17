import SwiftUI
import UniformTypeIdentifiers

/// Redigeraren för rutklipp (R6d, plan 8.5): rutorna som miniatyrer, Byt plats och Dela upp, layout, ingång,
/// inramning per ruta (dra ramen i rutans bild) och Tillbaka till automatiskt. Vyn ritar bara; varje åtgärd
/// är ett anrop i `ReelEditorModel` (`ReelEditorModel+Panels`) och ett ångringssteg. Dragningen av en
/// inramning ändrar inte modellen förrän musen släpps (en lokal, osparad mittpunkt visas under tiden).
struct ReelPanelsEditor: View {
    let model: ReelEditorModel
    let row: ReelEditorModel.ClipRow
    let clip: ReelSpec.Clip

    private var kind: ReelPanelEdit.Kind { ReelPanelEdit.kind(of: clip) }
    private var locked: Bool { ReelPanelEdit.isLocked(clip) }
    private var infos: [ReelEditorModel.PanelInfo] { model.panelInfos(forAsset: row.id) }

    var body: some View {
        let layout = clip.layout ?? .stack
        VStack(alignment: .leading, spacing: 10) {
            Label(summary(layout), systemImage: ReelPanelEdit.symbol(layout))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                ForEach(infos) { info in panelCard(info) }
            }

            HStack(spacing: 8) {
                Button { model.swapPanels(row.id) } label: { Label("Byt plats", systemImage: "arrow.left.arrow.right") }
                    .help(kind == .collage ? "Rutorna byter ordning (bilderna byter plats)" : "Montagets halvor visas i omvänd ordning")
                Button { model.splitPanels(row.id) } label: { Label("Dela upp", systemImage: "rectangle.split.2x1.slash") }
                    .help(kind == .collage ? "Rutorna blir två vanliga klipp" : "Montaget blir ett vanligt klipp med hela bilden")
                Button { model.restorePanelsAuto(row.id) } label: { Label("Tillbaka till automatiskt", systemImage: "wand.and.stars") }
                    .disabled(!locked)
                    .help("Släpp ditt val: PhotoFlow väljer layout, inramning och ingång igen")
            }
            .controlSize(.small)
            .labelStyle(.titleOnly)

            if kind == .collage {
                HStack {
                    Text("Layout")
                    Picker("Layout", selection: Binding(get: { layout }, set: { model.setPanelLayout(row.id, $0) })) {
                        ForEach(model.availableLayouts(forAsset: row.id), id: \.self) { l in
                            Label(ReelPanelEdit.label(l), systemImage: ReelPanelEdit.symbol(l)).tag(l)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if layout != .sequence {
                    HStack {
                        Text("Ingång")
                        Picker("Ingång", selection: Binding(get: { clip.entrance?.type ?? .none }, set: { model.setEntrance(row.id, $0) })) {
                            ForEach([ReelSpec.EntranceType.slide, .fade, .none], id: \.self) { t in
                                Text(ReelPanelEdit.label(t)).tag(t)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            } else if kind == .montage {
                montagePicker
            }

            if let info = infos.first(where: { $0.index == min(model.selectedPanelIndex, infos.count - 1) }) {
                ReelPanelFramingView(model: model, clipID: row.id, info: info)
            }

            if kind == .collage {
                Text("Klicka på en annan bild i rutnätet för att byta bilden i den markerade rutan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var montagePicker: some View {
        HStack {
            Text("Montage")
            Picker("Montage", selection: Binding(get: { ReelEditorModel.MontageLayout.sequence }, set: { model.setMontageLayout(row.id, $0) })) {
                Text("Som två klipp (sekvens)").tag(ReelEditorModel.MontageLayout.sequence)
                Text("Som montage (hela bilden)").tag(ReelEditorModel.MontageLayout.whole)
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    private func summary(_ layout: ReelSpec.PanelLayout) -> String {
        let how = ReelPanelEdit.label(layout).lowercased()
        switch kind {
        case .collage: return "Kollage, \(how)\(locked ? " (ditt val)" : " (automatiskt)")"
        case .montage: return "Montage, halvorna \(how == "efter varandra" ? "efter varandra" : how)\(locked ? " (ditt val)" : " (automatiskt)")"
        case .none: return ReelChoiceSummary.motionLabel(clip)
        }
    }

    private func panelCard(_ info: ReelEditorModel.PanelInfo) -> some View {
        let selected = min(model.selectedPanelIndex, infos.count - 1) == info.index
        return VStack(alignment: .leading, spacing: 2) {
            LocalThumbnailView(url: info.url)
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            Text("Ruta \(info.index + 1)\(info.room.map { " · \($0)" } ?? "")").font(.caption.weight(.semibold)).lineLimit(1)
            Text(info.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedPanelIndex = info.index }
        .help("Klicka för att markera rutan (inramning och bildbyte gäller den)")
    }
}

// MARK: - Inramning

/// Rutans bild med utsnittet som en ram. Dra ramen för att flytta mittpunkten; musen släppt sparar ett steg.
struct ReelPanelFramingView: View {
    let model: ReelEditorModel
    let clipID: String
    let info: ReelEditorModel.PanelInfo

    @State private var image: CGImage?
    @State private var draftCenter: CGPoint?
    @State private var startCenter: CGPoint?

    private var imageAspect: Double { Double(info.imageSize.width / max(info.imageSize.height, 1)) }

    /// Nyckeln som visas: den dragna mittpunkten (klampad) eller den sparade.
    private var shownKey: ReelSpec.MotionKey {
        guard let c = draftCenter else { return info.key }
        var k = info.key
        k.cx = c.x; k.cy = c.y
        return ReelPanelEdit.clamped(k, source: info.source, imageSize: info.imageSize, paneAspect: info.paneAspect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inramning, ruta \(info.index + 1)").font(.subheadline.weight(.semibold))
            GeometryReader { geo in
                let size = geo.size
                let frame = ReelPanelEdit.frame(of: shownKey, source: info.source, imageSize: info.imageSize, paneAspect: info.paneAspect)
                let r = CGRect(x: frame.minX * size.width, y: frame.minY * size.height,
                               width: frame.width * size.width, height: frame.height * size.height)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Color.gray.opacity(0.25).overlay(ProgressView())
                    }
                    Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(r) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startCenter ?? CGPoint(x: info.key.cx, y: info.key.cy)
                        startCenter = start
                        draftCenter = CGPoint(x: start.x + value.translation.width / max(size.width, 1),
                                              y: start.y + value.translation.height / max(size.height, 1))
                    }
                    .onEnded { _ in
                        if let c = draftCenter { commit(c) }
                        draftCenter = nil; startCenter = nil
                    })
            }
            .aspectRatio(imageAspect, contentMode: .fit)
            .frame(maxHeight: 240)
            .frame(maxWidth: .infinity)
            Text("Dra ramen för att flytta utsnittet. Rutorna står stilla (ingen panorering), bara en svag zoom.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: info.sha256) { await loadImage() }
    }

    private func commit(_ center: CGPoint) {
        model.beginCoalescing()
        model.setPanelCenter(clipID, panel: info.index, cx: center.x, cy: center.y)
        model.endCoalescing()
    }

    private func loadImage() async {
        image = nil
        guard let url = info.url else { return }
        image = await Self.load(id: info.sha256, url: url, original: info.originalLongEdge)
    }

    @concurrent
    private static func load(id: String, url: URL, original: Int) async -> CGImage? {
        ReelImageCache.shared.image(id: id, url: url, minLongEdge: 1200, originalLongEdge: original)
    }
}
