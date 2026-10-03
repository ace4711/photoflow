import SwiftUI

/// Inställningar → Objektfilm: server, de två API-nycklarna (sparas i Keychain), "Testa anslutning"
/// och reglaget för automatisk rendering av godkända filmer.
struct ObjektfilmTab: View {
    @State private var urlText = ""
    @State private var photographerKey = ""
    @State private var renderKey = ""
    @AppStorage(ObjektfilmConfig.autoRenderKey) private var autoRender = false
    @State private var testing = false
    @State private var testLines: [TestLine] = []
    @State private var saveMessage: String?
    @State private var worker = ReelWorkerController.shared

    private struct TestLine: Identifiable {
        let id = UUID()
        var ok: Bool
        var text: String
    }

    private let config = ObjektfilmConfig()

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server-URL", text: $urlText, prompt: Text("https://objektfilm.example.se"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Fotografnyckel", text: $photographerKey, prompt: Text("pf_…"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Render-nyckel", text: $renderKey, prompt: Text("pf_…"))
                    .textFieldStyle(.roundedBorder)
                Text("Nycklarna sparas i Keychain (aldrig i inställningsfilen). Fotografnyckeln skickar filmer och hämtar mäklarens ändringar; render-nyckeln hämtar godkända filmer ur renderkön.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Spara") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("Testa anslutning") { Task { await test() } }
                        .disabled(testing || config.serverURL == nil && ObjektfilmConfig.parse(urlText) == nil)
                    if testing { ProgressView().controlSize(.small) }
                    if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(testLines) { line in
                    Label(line.text, systemImage: line.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(line.ok ? .green : .red)
                        .font(.callout)
                }
            }
            Section("Rendering") {
                Toggle("Rendera godkända filmer automatiskt när appen är igång", isOn: $autoRender)
                    .onChange(of: autoRender) { _, _ in ReelWorkerController.shared.apply() }
                workerStatus
                Text("När mäklaren godkänner en film renderar den här Macen den (originalbilderna finns här), laddar upp MP4:n och sparar en kopia i filmens mapp. Appen måste vara igång.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var workerStatus: some View {
        switch worker.status {
        case .off:
            Text("Avstängd").font(.caption).foregroundStyle(.secondary)
        case .waiting:
            Label("Väntar på godkända filmer", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .rendering(_, let fraction):
            Label("Renderar… \(Int(fraction * 100)) %", systemImage: "film").font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        if let last = worker.lastRendered {
            Text("Senast klar: \(last)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        urlText = config.serverURLString
        photographerKey = config.key(.photographer) ?? ""
        renderKey = config.key(.render) ?? ""
    }

    private func save() {
        config.serverURLString = urlText
        guard let url = ObjektfilmConfig.parse(urlText) else {
            saveMessage = urlText.isEmpty ? "Sparat." : "Ogiltig server-URL."
            return
        }
        do {
            try config.saveKey(photographerKey, role: .photographer, for: url)
            try config.saveKey(renderKey, role: .render, for: url)
            saveMessage = "Sparat."
        } catch {
            saveMessage = error.localizedDescription
        }
        ReelWorkerController.shared.apply()
    }

    /// Provar de ifyllda nycklarna med `GET /api/v1/me` (utan att spara dem).
    private func test() async {
        testing = true
        defer { testing = false }
        testLines = []
        guard let url = ObjektfilmConfig.parse(urlText) else {
            testLines = [.init(ok: false, text: "Ogiltig server-URL.")]
            return
        }
        for (name, scope, key) in [("Fotografnyckel", "photographer", photographerKey),
                                   ("Render-nyckel", "render", renderKey)] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let me = try await ReelServerClient(baseURL: url, key: trimmed, maxRetries: 1).me()
                if me.scope == scope {
                    testLines.append(.init(ok: true, text: "\(name): ansluten som \(me.photographer.name)"))
                } else {
                    testLines.append(.init(ok: false, text: "\(name): nyckeln har scope \"\(me.scope)\", förväntade \"\(scope)\""))
                }
            } catch {
                testLines.append(.init(ok: false, text: "\(name): \(error.localizedDescription)"))
            }
        }
        if testLines.isEmpty { testLines = [.init(ok: false, text: "Fyll i minst en nyckel.")] }
    }
}
