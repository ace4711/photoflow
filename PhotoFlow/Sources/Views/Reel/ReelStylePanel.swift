import SwiftUI

/// Filmens stil (R2), visas i sidopanelen när ingenting är markerat: "Så valde PhotoFlow"-sammandraget
/// (R4, `ReelChoiceSummary`), tempo, standardövergång, rörelsekurva och bakgrund för "hela
/// bilden"-klipp. Stilen går via `ReelEditorModel.setStyle` (ångringsbart, sparas).
/// Standardövergången ändrar inte låsta övergångar.
struct ReelStylePanel: View {
    let model: ReelEditorModel
    let spec: ReelSpec

    private var tempo: ReelMotionPlanner.Tempo { .init(editorValue: spec.editor?.tempo) }
    private var transition: ReelSpec.Transition { spec.style.defaultTransition }
    private var isBlur: Bool { spec.style.background.type != "black" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            choiceSummary(ReelChoiceSummary.summary(spec))

            Divider()

            Text("Filmens stil").font(.headline)

            if model.adaptedCustomMotions > 0 {
                Label("\(model.adaptedCustomMotions) egna rörelser har anpassats till \(model.format.output.aspect)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }

            row("Tempo") {
                Picker("Tempo", selection: Binding(get: { tempo }, set: { model.setTempo($0) })) {
                    Text("Lugn").tag(ReelMotionPlanner.Tempo.calm)
                    Text("Normal").tag(ReelMotionPlanner.Tempo.normal)
                    Text("Snabb").tag(ReelMotionPlanner.Tempo.fast)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            row("Standardövergång") {
                Picker("Typ", selection: Binding(get: { transition.type }, set: { setType($0) })) {
                    Text("Mjuk tona").tag(ReelSpec.TransitionType.crossfade)
                    Text("Hårt klipp").tag(ReelSpec.TransitionType.cut)
                    Text("Via svart").tag(ReelSpec.TransitionType.fadeThroughBlack)
                    Text("Skjut").tag(ReelSpec.TransitionType.push)
                }
                .pickerStyle(.menu).labelsHidden()
                if transition.type == .push {
                    Picker("Riktning", selection: Binding(get: { transition.direction ?? .left }, set: { setDirection($0) })) {
                        ForEach(ReelTransitionEditor.directions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Slider(value: Binding(get: { transition.duration }, set: { setDuration($0) }),
                           in: ReelMotionPlanner.transitionRange, step: ReelTimelineLayout.transitionStep,
                           onEditingChanged: coalesce)
                        .disabled(transition.type == .cut)
                    Text(transition.type == .cut ? "–" : ReelTransitionEditor.seconds(transition.duration))
                        .font(.callout).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                Text("Gäller alla automatiska övergångar. Låsta övergångar påverkas inte.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            row("Rörelsekurva") {
                Picker("Rörelsekurva", selection: Binding(get: { spec.style.easing }, set: { easing in
                    model.setStyle({ $0.easing = easing }, op: "easing")
                })) {
                    Text("Mjuk").tag(ReelSpec.Easing.easeInOut)
                    Text("Jämn").tag(ReelSpec.Easing.linear)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            row("Bakgrund för \"hela bilden\"") {
                Picker("Bakgrund", selection: Binding(get: { isBlur }, set: { blur in
                    model.setStyle({ $0.background = blur ? .init(type: "blur", amount: $0.background.amount ?? 0.6)
                                                           : .init(type: "black", amount: nil) }, op: "background")
                })) {
                    Text("Suddig").tag(true)
                    Text("Svart").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                if isBlur {
                    HStack {
                        Slider(value: Binding(get: { spec.style.background.amount ?? 0.6 }, set: { amount in
                            model.setStyle({ $0.background = .init(type: "blur", amount: amount) }, op: "background")
                        }), in: 0...1, step: 0.05, onEditingChanged: coalesce)
                        Text("\(Int(((spec.style.background.amount ?? 0.6) * 100).rounded())) %")
                            .font(.callout).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Text("Markera ett klipp eller en övergång (chipet mellan klippen) i tidslinjen för att ändra just den. Dra ett klipps högerkant för att ändra längden, och dra ett övergångschip i sidled för att ändra övergångens längd.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Så valde PhotoFlow": mall, antal bilder och låsta val, och en rad per klipp med låsikon.
    /// Klick på en rad markerar klippet.
    private func choiceSummary(_ summary: ReelChoiceSummary.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Så valde PhotoFlow").font(.headline)
            Text(Self.headline(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(summary.rows, id: \.assetID) { r in
                    GridRow {
                        Text("\(r.index + 1)").monospacedDigit().foregroundStyle(.secondary)
                        Text(r.room).lineLimit(1)
                        Text(r.motion).lineLimit(1)
                        Text(r.transition.map { "in: \($0)" } ?? "–").lineLimit(1).foregroundStyle(.secondary)
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .opacity(r.locked ? 1 : 0)
                            .help("Har val du låst")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedAssetID = r.assetID }
                }
            }
            .font(.caption)
            Text("Rörelse och övergång räknas om automatiskt när du ändrar filmen, utom det du låst. Markera ett klipp för att se varför det rör sig som det gör.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// T.ex. "Mall: villa · 6 bilder · 2 låsta val".
    static func headline(_ s: ReelChoiceSummary.Summary) -> String {
        var parts: [String] = []
        if let t = s.template { parts.append("Mall: \(t.lowercased())") }
        parts.append(s.clipCount == 1 ? "1 bild" : "\(s.clipCount) bilder")
        switch s.lockedChoices {
        case 0: parts.append("inga låsta val")
        case 1: parts.append("1 låst val")
        default: parts.append("\(s.lockedChoices) låsta val")
        }
        return parts.joined(separator: " · ")
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func coalesce(_ editing: Bool) {
        if editing { model.beginCoalescing() } else { model.endCoalescing() }
    }

    private func setType(_ type: ReelSpec.TransitionType) {
        model.setStyle({ $0.defaultTransition = ReelMotionPlanner.retyped($0.defaultTransition, to: type) },
                       op: "defaultTransition")
    }

    private func setDirection(_ direction: ReelSpec.Direction) {
        model.setStyle({ $0.defaultTransition.direction = direction }, op: "defaultTransition")
    }

    private func setDuration(_ seconds: Double) {
        model.setStyle({ $0.defaultTransition.duration = seconds }, op: "defaultTransition")
    }
}
