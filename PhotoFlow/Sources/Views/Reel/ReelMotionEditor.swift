import SwiftUI

/// Rörelse för ett klipp (enkel variant): förval i en meny, och en beskrivning av vad
/// som faktiskt planerats (zoom eller panorering). Att dra start- och slutram direkt på
/// bilden kommer i en senare version; förvalen täcker det fotografen oftast vill.
struct ReelMotionEditor: View {
    let row: ReelEditorModel.ClipRow
    let clip: ReelSpec.Clip?
    let onPreset: (ReelMotionPlanner.Preset) -> Void
    let onDuration: (Double) -> Void
    let onAutoDuration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LocalThumbnailView(url: row.url)
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Klipp \(row.index + 1)\(row.room.map { " · \($0)" } ?? "")")
                        .font(.headline)
                    Text(row.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Picker("Rörelse", selection: Binding(get: { row.preset }, set: { onPreset($0) })) {
                ForEach(ReelMotionPlanner.Preset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.menu)

            if let clip {
                Text(Self.describe(clip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Stepper(value: Binding(get: { row.duration }, set: { onDuration($0) }),
                        in: ReelEditorModel.durationRange, step: 0.1) {
                    Text("Längd: \(Self.seconds(row.duration))")
                }
                if row.durationLocked {
                    Button("Auto", action: onAutoDuration)
                        .buttonStyle(.link)
                        .help("Tillbaka till automatisk längd")
                }
            }

            Text(row.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func seconds(_ s: Double) -> String {
        String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")
    }

    /// Kort beskrivning av klippets rörelse, t.ex. "Zoom 1,00 → 1,12" eller "Panorerar →, 28 % av bilden".
    static func describe(_ clip: ReelSpec.Clip) -> String {
        func f(_ x: Double) -> String { String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",") }
        let m = clip.motion
        let fit = clip.fit == .containBlur ? "Hela bilden, " : ""
        if abs(m.to.zoom - m.from.zoom) > 1e-6 {
            return "\(fit)Zoom \(f(m.from.zoom)) → \(f(m.to.zoom))"
        }
        let dx = m.to.cx - m.from.cx
        if abs(dx) > 1e-6 {
            return "Panorerar \(dx > 0 ? "→" : "←"), \(Int((abs(dx) * 100).rounded())) % av bildbredden"
        }
        return "\(fit)Stilla"
    }
}
