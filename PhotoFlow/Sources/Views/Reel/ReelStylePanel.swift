import SwiftUI

/// Filmens stil (R2), visas i sidopanelen när ingenting är markerat: tempo, standardövergång,
/// rörelsekurva och bakgrund för "hela bilden"-klipp. Allt går via `ReelEditorModel.setStyle`
/// (ångringsbart, sparas). Standardövergången ändrar inte låsta övergångar.
struct ReelStylePanel: View {
    let model: ReelEditorModel
    let spec: ReelSpec

    private var tempo: ReelMotionPlanner.Tempo { .init(editorValue: spec.editor?.tempo) }
    private var transition: ReelSpec.Transition { spec.style.defaultTransition }
    private var isBlur: Bool { spec.style.background.type != "black" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        model.setStyle({ s in
            s.defaultTransition.type = type
            s.defaultTransition.direction = type == .push ? (s.defaultTransition.direction ?? .left) : nil
        }, op: "defaultTransition")
    }

    private func setDirection(_ direction: ReelSpec.Direction) {
        model.setStyle({ $0.defaultTransition.direction = direction }, op: "defaultTransition")
    }

    private func setDuration(_ seconds: Double) {
        model.setStyle({ $0.defaultTransition.duration = seconds }, op: "defaultTransition")
    }
}
