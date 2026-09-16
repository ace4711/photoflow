import SwiftUI

/// Stor, tumvänlig inspelningsknapp — tänkt att gå att träffa och använda med
/// handskar på (fastighetsfotografering i februari, se planen för Fas 7).
/// Tydlig färgkontrast (grön/vila vs. rött/inspelning) i stället för att
/// bara byta ikon, så statusen syns även i starkt solljus.
struct RecordButtonView: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 104, height: 104)
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 8)
                        .frame(width: 128, height: 128)
                }
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityLabel(isRecording ? "Stoppa inspelning" : "Spela in anteckning")
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }
}
