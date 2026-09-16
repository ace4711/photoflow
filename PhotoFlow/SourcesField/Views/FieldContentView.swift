import SwiftUI
import UIKit

/// Huvudvyn i "PhotoFlow Fält": stor inspelningsknapp längst ner, lista över
/// dagens anteckningar ovanför, "Exportera" i verktygsfältet. Se
/// `FORBATTRINGAR.md` (Fas 7) för designresonemang (tumvänlig, stora
/// knappar, tydlig kontrast — appen är tänkt att användas med handskar på).
struct FieldContentView: View {
    @StateObject private var store = FieldNoteStore()
    @StateObject private var dictation = FieldDictationService()
    @StateObject private var location = FieldLocationService()

    @State private var editingNote: FieldNote?
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if store.notes.isEmpty && !dictation.isRecording {
                    ContentUnavailableView(
                        "Inga anteckningar än",
                        systemImage: "mic.circle",
                        description: Text("Tryck på mikrofonknappen och diktera, t.ex. \"kök, fixa reflexen i fönstret\".")
                    )
                } else {
                    List {
                        ForEach(store.notes) { note in
                            FieldNoteRow(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture { editingNote = note }
                        }
                        .onDelete { offsets in store.remove(at: offsets) }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 132) }
                }

                recordingArea
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .navigationTitle("PhotoFlow Fält")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportNotes()
                    } label: {
                        Label("Exportera", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.notes.isEmpty)
                }
            }
            .sheet(item: $editingNote) { note in
                FieldNoteEditView(note: note, store: store)
            }
            .sheet(isPresented: $showExportSheet) {
                if let exportURL {
                    ExportSummaryView(url: exportURL, noteCount: store.notes.count)
                }
            }
            .onAppear {
                location.requestAuthorizationIfNeeded()
            }
        }
    }

    // MARK: - Inspelningsområde

    private var recordingArea: some View {
        VStack(spacing: 10) {
            if let statusText = dictation.statusText {
                statusLine(statusText, color: .orange)
            }
            if dictation.isRecording {
                Text(dictation.liveTranscript.isEmpty ? "Lyssnar…" : dictation.liveTranscript)
                    .font(.system(.body, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
            if let error = dictation.error {
                statusLine(error, color: .red)
            }
            RecordButtonView(isRecording: dictation.isRecording, action: toggleRecording)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if dictation.isRecording {
            let text = dictation.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Tidsstämpeln tas i samma ögonblick knappen släpps — INTE efter
            // att ha väntat på GPS-fixen (som kan ta flera sekunder) — annars
            // skulle anteckningens tid drifta bort från när den faktiskt
            // gjordes och kunde missa Mac-appens matchningsfönster.
            let stoppedAt = Date()
            dictation.stopRecording()
            guard !text.isEmpty else { return }

            Task {
                let fix = await location.currentLocation()
                let coordinate = fix.map {
                    FieldCoordinate(
                        latitude: $0.coordinate.latitude,
                        longitude: $0.coordinate.longitude,
                        horizontalAccuracy: $0.horizontalAccuracy
                    )
                }
                store.add(FieldNote(recordedAt: stoppedAt, text: text, transcriptLanguage: .swedish, coordinate: coordinate))
            }
        } else {
            location.requestAuthorizationIfNeeded()
            dictation.startRecording()
        }
    }

    private func exportNotes() {
        guard let url = try? store.writeExportFile(deviceName: UIDevice.current.name) else { return }
        exportURL = url
        showExportSheet = true
    }
}
