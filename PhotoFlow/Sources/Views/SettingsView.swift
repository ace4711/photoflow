import SwiftUI
import ServiceManagement
import EventKit

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                DirectoriesTab(settings: settings)
                    .tabItem { Label("Mappar", systemImage: "folder") }
                    .tag(0)

                PipelineTab(settings: settings)
                    .tabItem { Label("Pipeline", systemImage: "gearshape.2") }
                    .tag(1)

                WatchTab(settings: settings)
                    .tabItem { Label("Bevakning", systemImage: "eye") }
                    .tag(2)

                AudioTab(settings: settings)
                    .tabItem { Label("Ljud & notiser", systemImage: "speaker.wave.2") }
                    .tag(3)

                SystemCheckTab()
                    .tabItem { Label("System", systemImage: "checkmark.shield") }
                    .tag(4)
            }
            .padding(.top, 8)

            Divider()

            HStack {
                Spacer()
                Button("Klar") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Directories

struct DirectoriesTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                DirectoryPicker(
                    label: "Inputmapp (NEF-filer)",
                    url: settings.inputDirectory,
                    onSelect: { settings.inputDirectory = $0 }
                )

                DirectoryPicker(
                    label: "Outputmapp (bearbetade filer)",
                    url: settings.outputDirectory,
                    onSelect: { settings.outputDirectory = $0 }
                )

                Text("Om ingen outputmapp väljs skapas 'processed' i inputmappen.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DirectoryPicker: View {
    let label: String
    let url: URL?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.headline)

            HStack {
                if let url {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    Text(url.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Ingen mapp vald")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Välj...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let selected = panel.url {
                        onSelect(selected)
                    }
                }
            }
        }
    }
}

// MARK: - Pipeline

struct PipelineTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Bracket-detektering") {
                HStack {
                    Text("Max tidslucka mellan bilder i grupp")
                    Spacer()
                    TextField("", value: $settings.maxTimeGap, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("sekunder")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Minsta antal bilder för bracket")
                    Spacer()
                    TextField("", value: $settings.minBracketSize, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("bilder")
                        .foregroundColor(.secondary)
                }
            }

            Section("HDR-sammanslagning") {
                Toggle("Aktivera HDR-merge (Mertens exposure fusion)", isOn: $settings.hdrMergeEnabled)

                if settings.hdrMergeEnabled {
                    Text("Bracket-grupper slås ihop automatiskt med Mertens exposure fusion. Resultatet visas i granskningsvyn.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Motor", selection: $settings.hdrEngine) {
                        Text("Core Image RAW (Swift)").tag("coreImage")
                        Text("OpenCV (äldre, JPEG-förhandsbilder)").tag("opencv")
                    }
                    .pickerStyle(.menu)

                    if settings.hdrEngine == "coreImage" {
                        Text("Riktig exposure fusion på RAW-data (DNG/NEF) via Core Image, i ren Swift — bevarar RAW-dynamiken i stället för att fusionera 8-bitars JPEG-förhandsbilder.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Max upplösning (lång sida)")
                            Spacer()
                            TextField("", value: $settings.hdrMaxDimension, format: .number)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("px (0 = full upplösning)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Toggle("Justera handhållna brackets (Vision-bildregistrering)", isOn: $settings.hdrAlignEnabled)
                    } else {
                        Text("Den äldre vägen: python3 + OpenCV (cv2.createMergeMertens) på inbäddade 8-bitars JPEG-förhandsbilder. Kräver att OpenCV är installerat (pip3 install opencv-python numpy).")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("HDR-steget och bracket-granskning hoppas över. Alla bilder går direkt till gallring.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("AI-taggning") {
                Toggle("Tagga bilder med Apple Vision", isOn: $settings.aiTaggingEnabled)

                if settings.aiTaggingEnabled {
                    Text("Varje bild analyseras av Apples Vision-modell och taggas med rumstyp (Kök, Badrum, Vardagsrum...), interiör/exteriör och andra mäklarrelevanta taggar. Taggarna skrivs som IPTC-nyckelord.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Ingen automatisk bildtaggning.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Toggle("Generera AI-bildbeskrivningar (Foundation Models)", isOn: $settings.aiDescriptionsEnabled)

                if settings.aiDescriptionsEnabled {
                    Text(PhotoDescriptionService.isAvailable
                         ? "Ett urval bilder (en per bracket-/singelgrupp) beskrivs på svenska av Apples on-device språkmodell (Foundation Models) — rum, kategori, särdrag och en kort bildtext. Skrivs till samma IPTC/XMP-fält som Vision-taggarna."
                         : "Kräver Apple Intelligence med bildstöd (Foundation Models, macOS 27+) — inte tillgängligt på den här enheten just nu. Vision-taggning används som vanligt tills dess.")
                        .font(.caption)
                        .foregroundColor(PhotoDescriptionService.isAvailable ? .secondary : .orange)
                } else {
                    Text("Bara Apple Vision-taggning (rumstyp, interiör/exteriör) används — ingen bildtext genereras.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Toggle("\"Föreslå gallring\" ska även föreslå nyttobilder", isOn: $settings.cullSuggestUtility)

                Text(settings.cullSuggestUtility
                     ? "\"Föreslå gallring\" (s i gallringsvyn) föreslår dubbletter OCH bilder Vision klassar som nyttobilder (kvitton/dokument-liknande)."
                     : "\"Föreslå gallring\" (s i gallringsvyn) föreslår bara dubbletter (behåller bästa i varje grupp). Vision flaggade 34 % av en testsession som \"nyttobild\" — för högt för att lita på automatiskt utan att slå på detta.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Gallring") {
                Picker("Vid \"Avsluta gallring\"", selection: $settings.cullAction) {
                    Text("Markera med betyg (rekommenderas)").tag("markera")
                    Text("Flytta till \"Gallrade\"-mapp").tag("flytta")
                    Text("Radera permanent").tag("radera")
                }
                .pickerStyle(.menu)

                switch settings.cullAction {
                case "radera":
                    Text("Avvisade bilders filer raderas permanent från adressmapparna. Går inte att ångra — en bekräftelsedialog visas innan radering.")
                        .font(.caption)
                        .foregroundColor(.orange)
                case "flytta":
                    Text("Avvisade bilders filer flyttas till en \"Gallrade\"-undermapp under respektive adressmapp i stället för att raderas eller taggas — enkelt att återställa manuellt om du ångrar dig.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                default:
                    Text("Inga filer rörs. Accepterade bilder får betyg 3 stjärnor, avvisade får Lightroom Classics \"Rejected\"-flagga (XMP:Rating -1) — synligt direkt när adressmappen öppnas i Lightroom, och helt ångringsbart där.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Kalenderintegration") {
                Toggle("Matcha bilder mot kalenderbokningar", isOn: $settings.calendarMatchEnabled)

                if settings.calendarMatchEnabled {
                    Text("Bilderna matchas mot iCal-bokningar baserat på fotograferingstid. Accepterade bilder organiseras i mappar namngivna efter bokningens adress.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    CalendarPickerRow(settings: settings)
                } else {
                    Text("Ingen adressorganisering — alla bilder hamnar i samma outputmapp.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("Progress") {
                Toggle("Detaljerad progress", isOn: $settings.detailedProgress)
                Text("Visar input-bilder och HDR-resultat live under bearbetning.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Previews") {
                HStack {
                    Text("JPEG-kvalitet")
                    Spacer()
                    TextField("", value: $settings.previewQuality, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("(1-100)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Max dimension")
                    Spacer()
                    TextField("", value: $settings.previewMaxDimension, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("pixlar")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Fas 4: låter användaren välja en kalender ur en riktig `Picker` (listar
/// EventKit-kalendrarna via `CalendarService`) i stället för att bara skriva
/// namnet i fritext. Fritextfältet finns kvar som fallback för de fall
/// åtkomst ännu inte beviljats (eller nekats) — precis vad `CalendarService.
/// resolveCalendar` redan stödjer (exakt/skiftlägesokänslig/delvis matchning
/// mot fritexten).
struct CalendarPickerRow: View {
    @ObservedObject var settings: AppSettings
    @State private var availableCalendars: [String] = []
    @State private var accessStatus: EKAuthorizationStatus = CalendarService.authorizationStatus
    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch accessStatus {
            case .fullAccess:
                Picker("Kalender", selection: $settings.calendarName) {
                    Text("Alla kalendrar").tag("")
                    ForEach(availableCalendars, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    // Sparat namn som inte längre finns bland de riktiga
                    // kalendrarna (borttagen kalender sedan sist, eller ett
                    // gammalt fritextvärde) — visa det ändå som ett eget
                    // alternativ i stället för att valet tyst hoppar till
                    // "Alla kalendrar" bara för att listan uppdaterades.
                    if !settings.calendarName.isEmpty && !availableCalendars.contains(settings.calendarName) {
                        Text("\(settings.calendarName) (hittas inte just nu)").tag(settings.calendarName)
                    }
                }
                .pickerStyle(.menu)
            case .notDetermined:
                HStack {
                    Text("Kalenderåtkomst har inte begärts än.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(isRequesting ? "Begär..." : "Begär åtkomst") { requestAccess() }
                        .disabled(isRequesting)
                }
                fallbackTextField
            default: // .denied, .restricted, .writeOnly (kan inte lista kalendrar)
                Text("Ingen kalenderåtkomst — ange kalendernamnet manuellt nedan, eller aktivera åtkomst i Systeminställningar → Sekretess och säkerhet → Kalendrar.")
                    .font(.caption)
                    .foregroundColor(.orange)
                fallbackTextField
            }
        }
        .onAppear { refresh() }
    }

    private var fallbackTextField: some View {
        TextField("Kalendernamn (exakt, eller tomt = alla kalendrar)", text: $settings.calendarName)
            .textFieldStyle(.roundedBorder)
    }

    private func refresh() {
        accessStatus = CalendarService.authorizationStatus
        availableCalendars = CalendarService.shared.availableCalendarNames()
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            _ = await CalendarService.shared.requestAccess()
            isRequesting = false
            refresh()
        }
    }
}

// MARK: - Watch

struct WatchTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Bevakning") {
                HStack {
                    Text("Fallback-kontrollintervall")
                    Spacer()
                    TextField("", value: $settings.watchIntervalSeconds, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("sekunder")
                        .foregroundColor(.secondary)
                }
                Text("Inputmappen bevakas i realtid via FSEvents — det här intervallet är bara ett skyddsnät ifall en filsystemhändelse skulle missas.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Starta pipeline automatiskt vid nya filer", isOn: $settings.autoStartPipeline)
            }

            Section("Bakgrundsläge") {
                Toggle("Visa i menyraden", isOn: $settings.showMenuBarExtra)
                Text("Låter dig starta/stoppa bevakning och se status från menyraden, utan att huvudfönstret behöver vara öppet.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Starta vid inloggning", isOn: Binding(
                    get: { settings.launchAtLoginRequested },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("Information") {
                Text("I bevakningsläge övervakas inputmappen (via FSEvents, med ~2 sekunders debounce) och alla anslutna volymer (SD-kort) för nya NEF-filer. Filer väntas ut tills storleken slutat växa innan de räknas som färdigkopierade. När nya filer hittas kan pipelinen startas automatiskt.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Håll den lagrade önskan i synk med det faktiska systemläget —
            // användaren kan ha stängt av det i Systeminställningar sedan sist.
            settings.launchAtLoginRequested = LaunchAtLogin.isEnabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLoginRequested = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Kunde inte \(enabled ? "aktivera" : "avaktivera") inloggningsobjekt: \(error.localizedDescription)"
            // Spegla det faktiska (oförändrade) systemläget, inte önskan.
            settings.launchAtLoginRequested = LaunchAtLogin.isEnabled
        }
    }
}

/// Tunn wrapper runt `SMAppService.mainApp` (Fas 3e) — registrerar PhotoFlow
/// som inloggningsobjekt. Signaturer verifierade mot SDK:n
/// (`ServiceManagement.framework/Headers/SMAppService.h`,
/// macOS 27-SDK): `SMAppService.mainApp` (klassegenskap, `NS_SWIFT_NAME`),
/// `register()`/`unregister()` (kastande), `.status` (`SMAppServiceStatus`).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Audio

struct AudioTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Ljud och tal") {
                Toggle("Systemljud (steg klart, fel, etc)", isOn: $settings.soundEnabled)
                Toggle("Talsyntes (röstmeddelanden)", isOn: $settings.speechEnabled)
            }

            Section("Notiser") {
                Toggle("Systemnotiser (Notification Center)", isOn: $settings.notificationsEnabled)
                Text("Visas när nya filer hittas och bearbetning startar, när resultatet är klart för granskning, vid fel i ett steg, och när HDR-sammanslagningen är klar — även om huvudfönstret är stängt (menyradsläge). Behörighet begärs första gången bearbetning startas.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Testa") {
                HStack(spacing: 12) {
                    Button("Steg klart") { AudioService.shared.playStepComplete() }
                    Button("Behöver hjälp") { AudioService.shared.playNeedsAttention() }
                    Button("Fel") { AudioService.shared.playError() }
                    Button("Allt klart") { AudioService.shared.playAllDone() }
                }
                HStack(spacing: 12) {
                    Button("Testnotis: Granskning") { NotificationService.shared.notifyReviewReady() }
                    Button("Testnotis: Fel") { NotificationService.shared.notifyError("Detta är en testnotis.") }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - System Check

struct SystemCheckTab: View {
    @StateObject private var deps = DependencyManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if deps.checks.isEmpty && !deps.isChecking {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Kontrollera att alla systemberoenden är installerade")
                        .foregroundColor(.secondary)
                    Button("Kör kontroll") { deps.runChecks() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(deps.checks) { check in
                            DependencyRow(check: check, deps: deps)
                        }
                    }
                    .padding(20)
                }

                Divider()

                HStack {
                    if deps.allCriticalOK {
                        Label("Alla nödvändiga verktyg är installerade", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(.body, weight: .medium))
                    } else if deps.hasMissing {
                        Label("Verktyg saknas — installera nedan", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(.body, weight: .medium))
                    } else if !deps.checks.isEmpty {
                        Label("Alla verktyg OK (valfria saknas)", systemImage: "checkmark.circle")
                            .foregroundColor(.orange)
                            .font(.system(.body, weight: .medium))
                    }
                    Spacer()
                    Button("Kontrollera igen") { deps.runChecks() }
                        .disabled(deps.isChecking)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            if deps.isChecking {
                ProgressView()
                    .padding()
            }
        }
        .onAppear { deps.runChecks() }
    }
}

struct DependencyCheck: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let status: DependencyStatus
    let detail: String?
    let version: String?
    var importance: DependencyImportance = .required
    var installMethod: DependencyManager.InstallMethod? = nil
}

enum DependencyStatus {
    case ok, warning, missing
}

enum DependencyImportance {
    case required, optional
}

struct DependencyRow: View {
    let check: DependencyCheck
    @ObservedObject var deps: DependencyManager

    private var isInstalling: Bool { deps.isInstalling == check.name }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(check.name)
                        .font(.system(.body, weight: .semibold))
                    if check.importance == .optional {
                        Text("valfri")
                            .font(.system(.caption2, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(3)
                    }
                    if let version = check.version {
                        Text(version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                Text(check.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let detail = check.detail {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(check.status == .missing ? .red : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Install button for missing tools
            if check.status == .missing, check.installMethod != nil {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        if check.name == "Homebrew" {
                            deps.installHomebrew()
                        } else {
                            deps.install(check)
                        }
                    } label: {
                        Label("Installera", systemImage: "arrow.down.circle")
                            .font(.system(.caption, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(check.importance == .required ? .red : .orange)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch check.status {
        case .ok: return .green
        case .warning: return .orange
        case .missing: return check.importance == .required ? .red : .orange
        }
    }

    private var statusIcon: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }
}
