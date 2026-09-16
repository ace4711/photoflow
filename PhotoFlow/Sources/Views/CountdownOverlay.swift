import SwiftUI

struct CountdownOverlay: View {
    @ObservedObject private var audio = AudioService.shared

    var body: some View {
        if audio.isCountingDown {
            HStack(spacing: 16) {
                // Countdown circle
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(audio.countdownSeconds) / 15.0)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: audio.countdownSeconds)
                    Text("\(audio.countdownSeconds)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Röstmeddelande om \(audio.countdownSeconds) sek")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("\"\(audio.countdownMessage)\"")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .italic()
                }

                Spacer()

                Text("Rör musen för att avbryta")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { audio.cancelCountdown() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
            )
            .frame(maxWidth: 550)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(duration: 0.3), value: audio.isCountingDown)
        }
    }
}
