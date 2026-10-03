import SwiftUI
import AppKit

/// Arket "Skicka till mäklare": etikett och giltighet, förlopp ("Laddar upp 12/24") och sedan länken
/// med Kopiera och Dela. Logiken ligger i `ReelShareModel`.
struct ReelShareSheet: View {
    let share: ReelShareModel
    let editor: ReelEditorModel
    let onClose: () -> Void

    @State private var label = ""
    @State private var days = 30
    @State private var anchor: NSView?
    @State private var copied = false

    private let config = ObjektfilmConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skicka till mäklare").font(.title2.bold())
            if config.isPhotographerConfigured {
                content
            } else {
                Text("Ange server och fotografnyckel under Inställningar → Objektfilm först.")
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Öppna inställningar") }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(share.createdLink == nil ? "Stäng" : "Klar") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(share.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onDisappear { share.resetProgress() }
    }

    @ViewBuilder
    private var content: some View {
        if let link = share.createdLink, let url = URL(string: link.url) {
            linkView(link: link, url: url)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mäklaren får en länk där hen kan byta ordning på bilderna, ändra längder och godkänna. Webbbilderna saknar plats- och kameradata.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Mäklarens namn eller etikett", text: $label)
                .textFieldStyle(.roundedBorder)
                .disabled(share.isBusy)
            Stepper(value: $days, in: 1...90) { Text("Länken gäller i \(days) dagar") }
                .disabled(share.isBusy)

            progress

            HStack {
                Button("Skicka och skapa länk") {
                    Task { await share.send(from: editor, label: label, days: days, newLink: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(share.isBusy)
                if share.isLinked {
                    Button("Skicka bara ändringar") {
                        Task { await share.send(from: editor, label: label, days: days, newLink: false) }
                    }
                    .disabled(share.isBusy)
                }
            }
            if let links = share.state?.links, !links.isEmpty {
                Divider()
                Text("Tidigare länkar").font(.caption.bold())
                ForEach(links, id: \.linkId) { link in
                    Text("\(link.label ?? "Utan etikett")\(link.expiresAt.map { " · gäller till \($0.prefix(10))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Länkens hemliga del visas bara när den skapas.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch share.phase {
        case .working(let text):
            HStack { ProgressView().controlSize(.small); Text(text).foregroundStyle(.secondary) }
        case .uploading(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Laddar upp \(done)/\(total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .done:
            Label(share.isLinked ? "Skickat." : "Klart.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            EmptyView()
        }
    }

    private func linkView(link: ReelServerCreatedLink, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Länken är klar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(link.url)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(copied ? "Kopierad" : "Kopiera", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                    copied = true
                }
                Button("Dela…", systemImage: "square.and.arrow.up") {
                    guard let anchor else { return }
                    let picker = NSSharingServicePicker(items: ["Granska och godkänn objektfilmen: \(link.url)"])
                    picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
                }
                .background(ShareAnchor(view: $anchor))
            }
            Text("Giltig till \(link.expiresAt.prefix(10)). Länken visas bara nu: kopiera eller dela den innan du stänger.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Ger `NSSharingServicePicker` en vy att fästa sig vid.
struct ShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
