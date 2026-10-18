import SwiftUI

/// Bedömning av den valda gruppen: A bättre / lika / B bättre, aspekter och kommentar.
struct HDRCompareVerdictPanel: View {
    @Bindable var model: HDRCompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Vilken är bäst?").font(.headline)
                choiceButton("A bättre", .left)
                choiceButton("Lika", .tie)
                choiceButton("B bättre", .right)
                Spacer()
                if model.currentVerdict != nil {
                    Button("Ta bort betyg", role: .destructive) { model.clearVerdict() }
                        .buttonStyle(.link)
                }
            }
            HStack(spacing: 14) {
                ForEach(HDRCompareAspect.allCases) { aspect in
                    Toggle(aspect.title, isOn: Binding(
                        get: { model.draftAspects.contains(aspect) },
                        set: { on in
                            if on { model.draftAspects.insert(aspect) } else { model.draftAspects.remove(aspect) }
                            model.draftChanged()
                        }))
                        .toggleStyle(.checkbox)
                }
            }
            .help("Vad avgjorde? Sparas med betyget")
            TextField("Kommentar", text: $model.draftNote, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.draftChanged() }
                .onChange(of: model.draftNote) { _, _ in model.draftChanged() }
            footer
        }
        .padding(12)
    }

    private func choiceButton(_ title: String, _ choice: HDRCompareChoice) -> some View {
        let selected = model.displayedChoice == choice
        return Button(title) { model.rate(choice) }
            .buttonStyle(.borderedProminent)
            .tint(selected ? .accentColor : .gray)
            .disabled(model.displayPair == nil)
    }

    @ViewBuilder
    private var footer: some View {
        if model.blind, let v = model.currentVerdict, let d = model.displayPair {
            // Avslöjat: bedömningen är gjord.
            Label("A var \(d.left), B var \(d.right)" + (v.winner.map { ". Du valde \($0)." } ?? ". Du valde lika."),
                  systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
        } else if model.blind {
            Label("Bedöm först; sedan visas vilken som var vilken.", systemImage: "eye.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let error = model.saveError {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }
}
