import SwiftUI

/// Fas 6: listar ALLA kända sessioner (`SessionHistoryStore`), inte bara den
/// senaste körningen i den just nu konfigurerade outputmappen — se
/// `AddressSessionLoader`s gamla begränsning (Fas 3f). Presenteras som ett
/// sheet från `DashboardView`s verktygsfält ("Historik").
struct SessionHistoryView: View {
    @ObservedObject var runner: RunnerWrapper
    @Environment(\.dismiss) private var dismiss

    /// Anropas efter att en session har börjat laddas via "Öppna" — låter
    /// `DashboardView` växla till granskningsvyn utan att den här vyn
    /// behöver känna till dess `showReview`-state direkt.
    var onOpened: () -> Void = {}

    @State private var entries: [SessionHistoryStore.Entry] = []
    @State private var searchText: String = ""
    /// Fas 8: posten som väntar på bekräftelse i borttagningsdialogen —
    /// `nil` när ingen dialog visas.
    @State private var entryPendingDeletion: SessionHistoryStore.Entry?

    private var filteredEntries: [SessionHistoryStore.Entry] {
        let sorted = entries.sorted { $0.updatedAt > $1.updatedAt }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { entry in
            entry.addresses.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || entry.outputDirectory.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Inga sessioner än",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Kör pipelinen på en mapp med NEF-filer för att se sessioner här.")
                    )
                } else if filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredEntries) { entry in
                        SessionHistoryRow(
                            entry: entry,
                            onOpen: { open(entry) },
                            onRevealInFinder: { reveal(entry) },
                            onDelete: { entryPendingDeletion = entry }
                        )
                        .swipeActions(edge: .trailing) {
                            Button("Ta bort ur historik", role: .destructive) {
                                entryPendingDeletion = entry
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historik")
            .searchable(text: $searchText, prompt: "Sök adress eller mapp")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            // "Fråga inte — logga bara" (uppdragets punkt 3): rensar tyst
            // poster vars outputmapp inte längre finns varje gång vyn öppnas,
            // så listan inte samlar på sig döda pekare över tid.
            SessionHistoryStore.pruneMissingOutputDirectories()
            reload()
        }
        // Fas 8: till skillnad från `pruneMissingOutputDirectories` (som
        // rensar tyst) är det här en explicit, användarinitierad borttagning
        // — därför en bekräftelsedialog som är tydlig med att bara REGISTER-
        // posten försvinner, aldrig filerna i output-/inputmappen.
        .confirmationDialog(
            "Ta bort session ur historiken?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            presenting: entryPendingDeletion
        ) { entry in
            Button("Ta bort ur historik", role: .destructive) {
                SessionHistoryStore.remove(sessionID: entry.sessionID)
                reload()
                entryPendingDeletion = nil
            }
            Button("Avbryt", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text("Bara posten i historiklistan tas bort. Inga filer raderas — mappen \"\(entry.outputDirectory)\" och dess innehåll ligger kvar orörda på disk.")
        }
    }

    private func reload() {
        entries = SessionHistoryStore.load()
    }

    private func open(_ entry: SessionHistoryStore.Entry) {
        let inputURL = URL(fileURLWithPath: entry.inputDirectory)
        let outputURL = URL(fileURLWithPath: entry.outputDirectory)
        // Pekar om de konfigurerade in-/outputmapparna på den öppnade
        // sessionen, så att t.ex. en "Kör om steg" från dashboarden efteråt
        // fortsätter arbeta mot RÄTT mapp i stället för den som råkade vara
        // konfigurerad innan man öppnade historiken.
        AppSettings.shared.inputDirectory = inputURL
        AppSettings.shared.outputDirectory = outputURL
        runner.loadExistingSession(inputDir: inputURL, outputDir: outputURL)
        onOpened()
        dismiss()
    }

    private func reveal(_ entry: SessionHistoryStore.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.outputDirectory)])
    }
}

private struct SessionHistoryRow: View {
    let entry: SessionHistoryStore.Entry
    let onOpen: () -> Void
    let onRevealInFinder: () -> Void
    let onDelete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "sv_SE")
        return formatter
    }()

    private var outputDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: entry.outputDirectory)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.addresses.isEmpty ? "Okänd adress" : entry.addresses.joined(separator: ", "))
                    .font(.headline)
                Text(Self.dateFormatter.string(from: entry.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(entry.photoCount) bilder", systemImage: "photo.stack")
                    if entry.unreviewedCount > 0 {
                        Label("\(entry.unreviewedCount) ogranskade", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Text(entry.status)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(entry.status == "Klar" ? Color.green.opacity(0.2) : Color.blue.opacity(0.2), in: Capsule())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Öppna", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .disabled(!outputDirectoryExists)
                Button("Visa i Finder", action: onRevealInFinder)
                    .buttonStyle(.bordered)
                    .disabled(!outputDirectoryExists)
                Button("Ta bort ur historik", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .opacity(outputDirectoryExists ? 1 : 0.5)
        .help(outputDirectoryExists ? "" : "Outputmappen finns inte längre på disk")
    }
}
