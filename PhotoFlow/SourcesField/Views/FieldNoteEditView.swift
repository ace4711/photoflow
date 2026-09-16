import SwiftUI

/// Redigeringsvy för en sparad fältanteckning: fri text, rumsetikett
/// (snabbval + eget fritextfält) och radering. Öppnas genom att trycka på en
/// rad i listan (se `FieldContentView`).
struct FieldNoteEditView: View {
    @Environment(\.dismiss) private var dismiss
    let note: FieldNote
    @ObservedObject var store: FieldNoteStore

    @State private var text: String
    @State private var roomLabel: String
    @State private var showDeleteConfirm = false

    init(note: FieldNote, store: FieldNoteStore) {
        self.note = note
        self.store = store
        _text = State(initialValue: note.text)
        _roomLabel = State(initialValue: note.roomLabel ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rum") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104))], spacing: 8) {
                        ForEach(FieldNoteStore.quickRoomLabels, id: \.self) { label in
                            let isSelected = roomLabel == label
                            Button {
                                roomLabel = isSelected ? "" : label
                            } label: {
                                Text(label)
                                    .font(.callout.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 12)
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    TextField("Eget rum...", text: $roomLabel)
                }

                Section("Anteckning") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                }

                if let coordinate = note.coordinate {
                    Section("Position") {
                        Text("\(coordinate.latitude, specifier: "%.6f"), \(coordinate.longitude, specifier: "%.6f")")
                            .font(.system(.footnote, design: .monospaced))
                        if let accuracy = coordinate.horizontalAccuracy, accuracy > 0 {
                            Text("Noggrannhet: ±\(Int(accuracy)) m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Label("Ingen position sparad för den här anteckningen", systemImage: "location.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Radera anteckning", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Redigera anteckning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        var updated = note
                        updated.text = text
                        updated.roomLabel = roomLabel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : roomLabel
                        store.update(updated)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Radera anteckning?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Radera", role: .destructive) {
                    store.remove(note)
                    dismiss()
                }
                Button("Avbryt", role: .cancel) {}
            }
        }
    }
}
