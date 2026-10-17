import SwiftUI

/// Rörelseeditorn (Regi R3): förvalsmeny, hela källbilden med dragbara start- och slutramar
/// (`ReelKeyframeCanvas`), snabbknappar, motivlager, tempovarning, längd och "Varför": skälet till
/// den automatiska rörelsen (`ReelEditorModel.motionReason`, "Vald av dig" för låsta) och till urvalet.
///
/// **Under dragning** ändras inte redigeringsmodellen: vyn håller en lokal, osparad rörelse och
/// visar den i förhandsvisningen som en isolerad spec med bara det här klippet
/// (`ReelPreviewModel.showTransient`), start- eller slutbild beroende på vilken ram som dras.
/// Det ger flytande bild utan ombyggnad, disksparande eller ny revision per musrörelse. Först när
/// musen släpps sparas rörelsen med `setCustomMotion` (ett ångringssteg) och förhandsvisningen
/// får den riktiga specen tillbaka.
struct ReelMotionEditor: View {
    let model: ReelEditorModel
    let preview: ReelPreviewModel
    let row: ReelEditorModel.ClipRow
    let clip: ReelSpec.Clip?

    @State private var image: CGImage?
    @State private var selected: ReelKeyframeCanvas.End = .start
    @State private var draft: ReelSpec.Motion?
    @State private var showSubject = false
    @State private var nudgeTask: Task<Void, Never>?

    private var asset: ReelSpec.Asset? { model.spec?.assets.first { $0.id == row.id } }
    private var geometry: (imageSize: CGSize, frameAspect: Double)? { model.motionGeometryContext(forAsset: row.id) }
    private var analysis: ReelImageAnalysis? { model.analysis(forAsset: row.id) }
    private var shownMotion: ReelSpec.Motion? { draft ?? clip?.motion }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Klipp \(row.index + 1)\(row.room.map { " · \($0)" } ?? "")")
                .font(.headline)
            Text(row.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Rörelse", selection: Binding(get: { row.preset }, set: { p in act { model.setPreset(row.id, p) } })) {
                ForEach(ReelMotionPlanner.Preset.selectableCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
                // Egen rörelse väljs inte i menyn, men visas när klippet har en.
                if row.preset == .custom { Text(ReelMotionPlanner.Preset.custom.label).tag(ReelMotionPlanner.Preset.custom) }
            }
            .pickerStyle(.menu)

            if let clip, let g = geometry, let motion = shownMotion {
                canvasSection(clip: clip, g: g, motion: motion)
            }

            HStack {
                Stepper(value: Binding(get: { row.duration }, set: { d in act { model.setDuration(row.id, seconds: d) } }),
                        in: ReelEditorModel.durationRange, step: 0.1) {
                    Text("Längd: \(Self.seconds(row.duration))")
                }
                if row.durationLocked {
                    Button("Auto") { act { model.clearDuration(row.id) } }
                        .buttonStyle(.link)
                        .help("Tillbaka till automatisk längd")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Varför").font(.subheadline.weight(.semibold))
                if let reason = model.motionReason(forAsset: row.id) {
                    Label("Rörelse: \(reason.text)", systemImage: reason == .chosenByUser ? "lock.fill" : "wand.and.stars")
                }
                Label("Urval: \(row.reason)", systemImage: row.reason == "Vald av dig" ? "lock.fill" : "wand.and.stars")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: asset?.sha256) { await loadImage() }
        .onDisappear { nudgeTask?.cancel(); endNudge() }
    }

    // MARK: Bild och ramar

    @ViewBuilder
    private func canvasSection(clip: ReelSpec.Clip, g: (imageSize: CGSize, frameAspect: Double), motion: ReelSpec.Motion) -> some View {
        ReelKeyframeCanvas(
            image: image, imageSize: g.imageSize, frameAspect: g.frameAspect, fit: clip.fit, motion: motion,
            boxes: analysis?.saliencyBoxes ?? [], showSubject: showSubject, selected: $selected,
            onDrag: { dragged, end in drag(dragged, end: end) },
            onDragEnd: { finishDrag() },
            onNudge: { nudge($0) })
            .frame(maxWidth: .infinity, maxHeight: 360)
            .frame(maxWidth: .infinity)

        if clip.fit == .containBlur {
            Text("Hela bilden syns i bildspelet med suddig bakgrund. Ramarna visar den del som zoomas in på.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Button { act { model.swapMotionEnds(row.id) } } label: { Label("Byt start/slut", systemImage: "arrow.left.arrow.right") }
                .disabled(motion.from == motion.to)
            Button { act { model.centerMotionOnSubject(row.id) } } label: { Label("Centrera på motivet", systemImage: "scope") }
                .disabled(analysis?.focus == nil)
            Button { act { model.setPreset(row.id, .auto) } } label: { Label("Tillbaka till automatisk", systemImage: "wand.and.stars") }
                .disabled(row.preset == .auto)
        }
        .controlSize(.small)
        .labelStyle(.titleOnly)

        Toggle("Visa motiv", isOn: $showSubject)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled((analysis?.saliencyBoxes ?? []).isEmpty)

        let pace = ReelMotionGeometry.pace(motion, duration: row.duration, imageSize: g.imageSize)
        if pace.isTooFast {
            VStack(alignment: .leading, spacing: 2) {
                if pace.tooFastPan {
                    Label("Snabb panorering — kan se ryckig ut", systemImage: "exclamationmark.triangle.fill")
                }
                if pace.tooFastZoom {
                    Label("Snabb zoom — kan se ryckig ut", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }

        Text(Self.describe(clip.fit, motion))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Dragning

    private func drag(_ motion: ReelSpec.Motion, end: ReelKeyframeCanvas.End) {
        draft = motion
        guard let spec = model.spec else { return }
        preview.showTransient(spec, assetID: row.id, motion: motion, atEnd: end == .end, specDirectory: model.reelDirectory)
    }

    /// Musen släppt: spara en ändrad rörelse som ett ångringssteg och återställ förhandsvisningen.
    private func finishDrag() {
        defer { draft = nil }
        if let draft, let clip, draft != clip.motion {
            model.beginCoalescing()
            model.setCustomMotion(row.id, fit: clip.fit, motion: draft)
            model.endCoalescing()
        }
        preview.setSpec(model.spec, specDirectory: model.reelDirectory)
    }

    /// Piltangenter: varje tryck sparas direkt, men trycken inom en kort stund är ett enda ångringssteg.
    private func nudge(_ motion: ReelSpec.Motion) {
        guard let clip, motion != clip.motion else { return }
        // Nytt fönster även om modellen avslutat det (ångra, eller en annan ändring emellan).
        if nudgeTask == nil || !model.isCoalescing { model.beginCoalescing() }
        model.setCustomMotion(row.id, fit: clip.fit, motion: motion)
        nudgeTask?.cancel()
        nudgeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            endNudge()
        }
    }

    /// Övriga knappar i editorn: stäng först ett öppet knuffönster, så att ändringen blir ett eget steg.
    private func act(_ change: () -> Void) {
        nudgeTask?.cancel()
        endNudge()
        change()
    }

    private func endNudge() {
        guard nudgeTask != nil else { return }
        nudgeTask = nil
        model.endCoalescing()
    }

    // MARK: Källbild

    /// Källbilden i ca 1200 pixlar via den delade bildcachen (förhandsvisningen använder samma bilder).
    private func loadImage() async {
        image = nil
        guard let asset, let url = row.url else { return }
        image = await Self.loadSource(id: asset.sha256, url: url, original: max(asset.width, asset.height))
    }

    @concurrent
    private static func loadSource(id: String, url: URL, original: Int) async -> CGImage? {
        ReelImageCache.shared.image(id: id, url: url, minLongEdge: 1200, originalLongEdge: original)
    }

    static func seconds(_ s: Double) -> String {
        String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")
    }

    /// Kort beskrivning av rörelsen, t.ex. "Zoom 1,00 → 1,12" eller "Panorerar →, 28 % av bildbredden".
    static func describe(_ clip: ReelSpec.Clip) -> String { describe(clip.fit, clip.motion) }

    static func describe(_ fit: ReelSpec.Fit, _ m: ReelSpec.Motion) -> String {
        func f(_ x: Double) -> String { String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",") }
        let prefix = fit == .containBlur ? "Hela bilden, " : ""
        if abs(m.to.zoom - m.from.zoom) > 1e-6 {
            return "\(prefix)Zoom \(f(m.from.zoom)) → \(f(m.to.zoom))"
        }
        let dx = m.to.cx - m.from.cx
        if abs(dx) > 1e-6 {
            return "Panorerar \(dx > 0 ? "→" : "←"), \(Int((abs(dx) * 100).rounded())) % av bildbredden"
        }
        return "\(prefix)Stilla"
    }
}
