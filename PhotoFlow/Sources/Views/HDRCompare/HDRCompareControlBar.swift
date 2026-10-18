import SwiftUI

/// Övre raden över bilderna: val av A/B, referens, visningsläge och blindläge.
struct HDRCompareControlBar: View {
    @Bindable var model: HDRCompareModel

    var body: some View {
        HStack(spacing: 12) {
            if let g = model.selectedGroup, let p = model.canonicalPair {
                let ids = model.variants(of: g)
                if model.blind {
                    Label("Blindläge: varianterna är dolda och A/B är slumpade", systemImage: "eye.slash")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    variantMenu("A", selection: p.a, ids: ids) { model.preferredA = $0; model.variantChanged() }
                    variantMenu("B", selection: p.b, ids: ids) { model.preferredB = $0; model.variantChanged() }
                }
                Toggle("Ref", isOn: $model.showReference)
                    .toggleStyle(.checkbox)
                    .disabled(!(model.available[g.id] ?? []).contains(HDRCompareManifest.Group.referenceID))
                    .help("Visa fotografens färdiga bild som tredje ruta (bara Chronas väg 7)")
                    .onChange(of: model.showReference) { _, _ in model.variantChanged() }
            }
            Spacer()
            Picker("Läge", selection: $model.mode) {
                ForEach(HDRCompareMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .help("Sida vid sida · Svep (S) · A/B-växling (mellanslag)")

            Toggle(isOn: Binding(get: { model.blind }, set: { model.blind = $0 })) {
                Label("Blind", systemImage: model.blind ? "eye.slash" : "eye")
            }
            .toggleStyle(.button)
            .help("Blindläge (B): dolda etiketter och slumpad A/B-ordning per grupp")

            Button("Anpassa") { model.viewport.reset() }
                .help("Visa hela bilden")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func variantMenu(_ title: String, selection: String, ids: [String], set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(ids, id: \.self) { id in
                Button(id) { set(id) }
            }
        } label: {
            Text("\(title): \(selection)")
        }
        .fixedSize()
    }
}
