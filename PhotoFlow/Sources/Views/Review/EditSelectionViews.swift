import AppKit
import SwiftUI

// Vyer för urvalet till extern redigering i granska-läget (se `EditSelection`).

/// Raden ovanför miniatyrerna: växeln "Skicka till redigering" för aktuell grupp.
struct EditSelectionBar: View {
    let isSending: Bool
    let isSuggestion: Bool
    let chosenCount: Int
    let exposureCount: Int
    let suggestedFiles: [String]
    let onToggle: () -> Void
    let onUseSuggestion: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { isSending }, set: { _ in onToggle() })) {
                Label("Skicka till redigering (S)", systemImage: "paperplane")
                    .font(.callout.bold())
            }
            .toggleStyle(.switch)
            .tint(.blue)
            .help("Välj gruppen för extern redigering (S). Bocka i/ur exponeringar i raden nedan eller med E.")

            if isSending && isSuggestion {
                SuggestionTag()
            }

            Text(isSending
                 ? "\(chosenCount) av \(exposureCount) exponeringar valda"
                 : "Skickas inte")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !suggestedFiles.isEmpty {
                Button("Föreslagna exponeringar") { onUseSuggestion() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Bocka i appens förslag (\(suggestedFiles.count) st) för gruppen")
            }
            Text("E: bocka i/ur vald exponering")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSending ? Color.blue.opacity(0.10) : Color.clear)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Liten markering för orörda förslag.
struct SuggestionTag: View {
    var body: some View {
        Text("Förslag")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(Color.blue.opacity(0.7), lineWidth: 1))
            .foregroundStyle(.blue)
            .help("Appens förslag — försvinner när du ändrar urvalet")
    }
}

/// Kryssruta på en miniatyr: vald för redigering. Avvisade bilder kan inte väljas.
struct EditCheckbox: View {
    let checked: Bool
    let rejected: Bool
    let groupSending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: rejected ? "xmark.square" : (checked ? "checkmark.square.fill" : "square"))
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(rejected ? Color.secondary : (checked ? Color.white : Color.white.opacity(0.9)),
                                 rejected ? Color.clear : (checked ? Color.blue : Color.black.opacity(0.35)))
                .shadow(color: .black.opacity(0.5), radius: 1)
        }
        .buttonStyle(.plain)
        .disabled(rejected)
        .opacity(groupSending || !checked ? 1 : 0.5)
        .help(rejected ? "Avvisad — kan inte skickas" : (checked ? "Skickas till redigering — klicka för att ta bort" : "Skicka den här exponeringen till redigering"))
        .padding(4)
    }
}

// MARK: - Skapa skicka-mappar

/// Kör synken av skicka-mapparna och visar förlopp och sammanfattning.
struct EditSendSheet: View {
    let outputDir: URL
    let requests: [SendFolderSync.Request]
    let onClose: () -> Void

    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var summary: SendFolderSync.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skicka-mappar")
                .font(.title2.bold())
            if let summary {
                summaryView(summary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kopierar \(requests.count) DNG-filer till skicka-mapparna…")
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) av \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if let summary, !summary.addresses.isEmpty {
                    Button("Visa i Finder") { showInFinder(summary) }
                }
                Button("Stäng") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(summary == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await run() }
    }

    @ViewBuilder
    private func summaryView(_ s: SendFolderSync.Summary) -> some View {
        let total = s.addresses.reduce(0) { $0 + $1.fileCount }
        let bytes = s.addresses.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 8) {
            Label("\(filesText(total)) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) i \(s.addresses.count) \(s.addresses.count == 1 ? "mapp" : "mappar")",
                  systemImage: s.errors.isEmpty && s.conflicts.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(s.errors.isEmpty && s.conflicts.isEmpty ? .green : .orange)
                .font(.headline)
            ForEach(s.addresses, id: \.address) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.folder.lastPathComponent).font(.callout.bold())
                    Text("\(filesText(a.fileCount)) · \(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file))"
                         + (a.copied > 0 ? " · \(a.copied) nya" : "")
                         + (a.removed > 0 ? " · \(a.removed) borttagna" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            messages("Krockar (skrevs inte över)", s.conflicts, color: .orange)
            messages("Varningar", s.warnings, color: .orange)
            messages("Fel", s.errors, color: .red)
        }
    }

    @ViewBuilder
    private func messages(_ title: String, _ items: [String], color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold()).foregroundStyle(color)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, m in
                            Text(m).font(.caption2).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 90)
            }
        }
    }

    private func filesText(_ n: Int) -> String { n == 1 ? "1 fil" : "\(n) filer" }

    private func run() async {
        let outputDir = outputDir
        let requests = requests
        let result = await Self.sync(outputDir: outputDir, requests: requests) { done, total in
            Task { @MainActor in progress = (done, total) }
        }
        summary = result
    }

    /// Planerar och utför synken utanför MainActor.
    @concurrent
    nonisolated static func sync(outputDir: URL, requests: [SendFolderSync.Request],
                                 progress: @escaping @Sendable (Int, Int) -> Void) async -> SendFolderSync.Summary {
        let manifest = SendFolderSync.Manifest.load(from: outputDir)
        let actions = SendFolderSync.plan(requests: requests, outputDir: outputDir, manifest: manifest)
        progress(0, actions.count)
        let (summary, _) = await SendFolderSync.execute(actions, requests: requests, outputDir: outputDir,
                                                        manifest: manifest, progress: progress)
        return summary
    }

    private func showInFinder(_ s: SendFolderSync.Summary) {
        let folders = s.addresses.map(\.folder).filter { FileManager.default.fileExists(atPath: $0.path) }
        if folders.isEmpty {
            NSWorkspace.shared.open(outputDir)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(folders)
        }
    }
}
