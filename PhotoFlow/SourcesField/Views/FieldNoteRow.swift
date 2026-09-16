import SwiftUI

struct FieldNoteRow: View {
    let note: FieldNote

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: note.recordedAt))
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let room = note.roomLabel, !room.isEmpty {
                    Text(room)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if note.coordinate != nil {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(note.text)
                .font(.body)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
    }
}
