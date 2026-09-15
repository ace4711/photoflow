import SwiftUI
import Translation

struct DictationPanelView: View {
    let photoId: String
    let photoFilename: String
    @ObservedObject var notesManager: NotesManager
    @ObservedObject var dictation: DictationService
    @StateObject private var translator = TranslationService()

    @State private var originalText: String = ""
    @State private var translatedText: String = ""
    @State private var selectedLanguage: PhotoNote.NoteLanguage = .swedish
    @State private var autoStarted: Bool = false

    /// Dynamic font size: short text → large font, longer text → smaller
    private func adaptiveFontSize(for text: String) -> CGFloat {
        let len = text.count
        if len < 15 { return 36 }
        if len < 40 { return 28 }
        if len < 80 { return 22 }
        if len < 150 { return 18 }
        return 15
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "mic.bubble")
                    .foregroundColor(.accentColor)
                Text("Anteckningar")
                    .font(.system(.caption, design: .rounded, weight: .semibold))

                Spacer()

                if notesManager.notes[photoId] != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            // Language picker + record button
            HStack(spacing: 8) {
                Picker("", selection: $selectedLanguage) {
                    ForEach(PhotoNote.NoteLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(dictation.isRecording)

                Spacer()

                // Manual record toggle
                Button(action: toggleRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 20))
                        Text(dictation.isRecording ? "Stoppa" : "Spela in")
                            .font(.caption)
                    }
                    .foregroundColor(dictation.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
            }

            // Recording indicator
            if dictation.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulsingOpacity)
                    Text("Lyssnar (\(selectedLanguage.displayName))... säg \"stopp\" för att avsluta")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                .onAppear { startPulse() }
            }

            // Translating indicator (visar statusText — t.ex. nedladdning av
            // språkmodell — när den finns, annars en generisk "översätter"-text)
            if translator.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(translator.statusText ?? "Översätter till \(selectedLanguage.other.displayName)...")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            // Original text — fills available space
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedLanguage.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                TextEditor(text: $originalText)
                    .font(.system(size: adaptiveFontSize(for: originalText), weight: .regular, design: .default))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(dictation.isRecording ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            // Translated text — fills available space
            if !translatedText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedLanguage.other.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextEditor(text: $translatedText)
                        .font(.system(size: adaptiveFontSize(for: translatedText), weight: .regular, design: .default))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                // Translate
                Button(action: translateText) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translator.isTranslating)
                .help("Översätt")

                // Save
                Button(action: saveNote) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .disabled(originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Spara")

                // Mail
                if notesManager.notes[photoId] != nil {
                    Button(action: {
                        if let url = notesManager.mailtoURL() {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "envelope")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("Maila anteckning")
                }

                Spacer()

                // Delete
                if notesManager.notes[photoId] != nil {
                    Button(action: deleteNote) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .help("Radera anteckning")
                }
            }

            // Errors
            if let error = dictation.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            if let error = translator.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        // Apples Translation-ramverk: sessionen skapas/uppdateras av SwiftUI
        // varje gång `translator.configuration` ändras eller ogiltigförklaras
        // (se `TranslationService.translate`/`invalidate()`), och stängs ner
        // automatiskt när vyn försvinner.
        .translationTask(translator.configuration) { session in
            await translator.performPendingTranslation(using: session)
        }
        .onChange(of: photoId) { _, _ in
            loadExistingNote()
        }
        .onChange(of: dictation.liveTranscript) { _, newValue in
            if dictation.isRecording && !newValue.isEmpty {
                originalText = newValue
            }
        }
        // Auto-translate + auto-save when voice-stopped
        .onChange(of: dictation.stoppedByVoice) { _, stopped in
            if stopped {
                // Ensure recording is fully stopped
                if dictation.isRecording {
                    dictation.stopRecording()
                }
                originalText = dictation.liveTranscript
                translateAndSave()
                // Reset flag so auto-start won't re-trigger
                dictation.stoppedByVoice = false
            }
        }
        // Also handle manual stop: translate when recording stops and we have text
        .onChange(of: dictation.isRecording) { wasRecording, isNow in
            if wasRecording && !isNow && !dictation.stoppedByVoice {
                // Manual stop — also auto-translate
                if !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translateAndSave()
                }
            }
        }
        .onAppear {
            loadExistingNote()
            // Auto-start recording when panel appears, unless there's already a note
            if originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !dictation.isRecording {
                dictation.startRecording(language: selectedLanguage)
            }
        }
    }

    // MARK: - Pulse animation

    @State private var pulsingOpacity: Double = 1.0

    private func startPulse() {
        pulsingOpacity = 1.0
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            pulsingOpacity = 0.3
        }
    }

    // MARK: - Actions

    private func toggleRecording() {
        if dictation.isRecording {
            dictation.stopRecording()
        } else {
            dictation.startRecording(language: selectedLanguage)
        }
    }

    private func translateText() {
        Task {
            translatedText = await translator.translate(
                originalText,
                from: selectedLanguage,
                to: selectedLanguage.other
            )
        }
    }

    private func translateAndSave() {
        let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            translatedText = await translator.translate(
                text,
                from: selectedLanguage,
                to: selectedLanguage.other
            )
            saveNote()
        }
    }

    private func saveNote() {
        notesManager.setNote(
            photoId: photoId,
            filename: photoFilename,
            originalText: originalText,
            language: selectedLanguage,
            translatedText: translatedText
        )
    }

    private func deleteNote() {
        notesManager.removeNote(photoId: photoId)
        originalText = ""
        translatedText = ""
    }

    private func loadExistingNote() {
        if let existing = notesManager.noteFor(photoId: photoId) {
            originalText = existing.originalText
            translatedText = existing.translatedText
            selectedLanguage = existing.originalLanguage
        } else {
            originalText = ""
            translatedText = ""
        }
    }
}
