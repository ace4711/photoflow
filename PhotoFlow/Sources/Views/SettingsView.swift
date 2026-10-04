import SwiftUI
import ServiceManagement
import EventKit
import CoreLocation

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    // Fas 9: låter infopopovern på ett stegkort (StepCardView) hoppa direkt
    // till rätt flik ("Öppna inställningar") i stället för att bara öppna
    // Inställningar på den flik som råkade vara öppen sist.
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
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

                ObjektfilmTab()
                    .tabItem { Label("Objektfilm", systemImage: "film") }
                    .tag(5)

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
            // Fas 5: regularMaterial i stället för en solid platta — samma
            // tidsenliga stil som resten av appen sedan Fas 3g.
            .background(.regularMaterial)
        }
    }
}

// MARK: - Directories

struct DirectoriesTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var preflight = PreflightModel.shared

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

            // Samma kontroll som Startkontroll i verktygsfältet, bara mappdelen.
            Section("Status") {
                ForEach(preflight.report.checks(in: .folders)) { check in
                    PreflightRow(check: check, showSection: false, onFix: handle)
                }
            }
        }
        .formStyle(.grouped)
        .task { await preflight.run() }
    }

    private func handle(_ fix: Preflight.Fix) {
        switch fix {
        case .chooseInput, .chooseOutput:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if fix == .chooseInput { settings.inputDirectory = url } else { settings.outputDirectory = url }
            Task { await preflight.run() }
        case .openSettings:
            return
        default:
            Task { await preflight.perform(fix) }
        }
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

/// Raderna i sektionen "Förbättra bilder" (steget efter HDR): av/på + val av stilprofil.
struct EnhanceSettingsRows: View {
    @ObservedObject var settings: AppSettings
    @State private var profiles = EnhancementProfileStore.shared.loadAll()

    var body: some View {
        Toggle("Förbättra bilder automatiskt (färg & ton)", isOn: $settings.enhanceEnabled)

        if settings.enhanceEnabled {
            Picker("Stilprofil", selection: $settings.enhanceProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
                if !profiles.contains(where: { $0.id == settings.enhanceProfileID }) {
                    Text("Okänd profil (Mäklarstil används)").tag(settings.enhanceProfileID)
                }
            }
            .pickerStyle(.menu)

            Toggle("Räta lodlinjer", isOn: $settings.enhanceUprightEnabled)

            Text("Efter HDR-steget korrigeras varje färdig bild (HDR-TIFF per bracket, DNG-rendering per singel): vitbalans, exponering, svart/vit-punkt, skuggor/högdagrar, lätt S-kurva, vibrance, clarity, skärpa och liten horisonträtning. Resultatet sparas som nya filer i mappen FÖRBÄTTRADE — originalen rörs aldrig. Parametrar per bild sparas i enhancement.json.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Automatisk: full automatik med en liten varm förskjutning. Neutral: svag automatik, ingen varm ton, ingen rätning. Varm & ljus: något ljusare och varmare. Mäklarstil: härmar redigerarens leveranser — ljus och luftig, neutrala vita väggar, upplyfta skuggor, dämpad mättnad och lågt brus. Räta lodlinjer: väggar och dörrkarmar blir lodräta (högst 8°, beskärs utan tomma hörn; hoppas över när linjerna är osäkra). Egna profiler läggs som JSON i ~/Library/Application Support/PhotoFlow/profiles/.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("Bilderna levereras som HDR-TIFF/DNG utan automatisk förbättring.")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }
}

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
                    Text("Bracket-grupper slås ihop automatiskt (basram eller Mertens exposure fusion, se Metod). Resultatet visas i granskningsvyn.")
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
                            Picker("Upplösning", selection: $settings.hdrMaxDimension) {
                                Text("Snabb (6000 px)").tag(6000)
                                Text("Full (kamerans upplösning, ca 2× tid)").tag(0)
                                if settings.hdrMaxDimension != 6000 && settings.hdrMaxDimension != 0 {
                                    Text("Egen (\(settings.hdrMaxDimension) px)").tag(settings.hdrMaxDimension)
                                }
                            }
                        }

                        Picker("Metod", selection: $settings.hdrMethod) {
                            Text("Basram (mäklarstil, standard)").tag(HDREngine.Method.baseFrame.rawValue)
                            Text("Exposure fusion (Mertens)").tag(HDREngine.Method.fusion.rawValue)
                        }
                        .pickerStyle(.menu)
                        Text("Basram: en ljus exponering som bas, bara klippta högdagrar hämtas ur mörkare exponeringar — jämnt ljusa tak och väggar utan fusionens skuggor. Fönstren hämtas ur den mörkaste exponeringen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Toggle("Lätt skärpning av HDR-resultatet", isOn: $settings.hdrSharpenEnabled)
                        Toggle("Justera brackets mot varandra (Vision-bildregistrering)", isOn: $settings.hdrAlignEnabled)
                        Text("Justeringen rättar små rörelser mellan exponeringarna (även på stativ) och avvisar orimliga mätningar. Påverkar bara HDR som skapas härefter.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Fönster från mörkaste exponeringen (window pull)", isOn: $settings.hdrWindowPullEnabled)
                        if settings.hdrWindowPullEnabled {
                            HStack {
                                Text("Styrka")
                                Slider(value: $settings.hdrWindowPullStrength, in: 0...100, step: 5)
                                Text("\(Int(settings.hdrWindowPullStrength)) %")
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                            HStack {
                                Text("Fönsterljushet")
                                Slider(value: $settings.hdrWindowBrightness, in: -1...1, step: 0.25)
                                Text(String(format: "%+.2f EV", settings.hdrWindowBrightness))
                                    .monospacedDigit()
                                    .frame(width: 72, alignment: .trailing)
                            }
                            Toggle("Även lampor och himmel", isOn: $settings.hdrWindowIncludeLampsSky)
                        }
                        Text("Utfrätta fönster ersätts med utsikten ur bracketens mörkaste exponering (även när den inte ingår i sammanslagningen), exponeringsmatchad och kantförfinad. Lampor och himmel lämnas annars orörda. Fönstermasken sparas i hdr_masks/.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Gör om befintliga HDR när motorn uppdaterats", selection: $settings.hdrRedoOnEngineUpdate) {
                            Text("Aldrig").tag(HDRLog.RedoPolicy.never.rawValue)
                            Text("Alltid").tag(HDRLog.RedoPolicy.always.rawValue)
                        }
                        .pickerStyle(.menu)
                        Text("Gäller HDR som redan finns när en ny version av sammanslagningen kommer (t.ex. window pull). Aldrig: de ligger kvar som de är. Alltid: de görs om — även levererade filer i adressmapparna skrivs över — nästa gång sessionen körs. Ändrade inställningar ovan gör alltid om berörda HDR.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

            Section("Förbättra bilder") {
                EnhanceSettingsRows(settings: settings)
            }

            Section("Filmförslag") {
                Toggle("Skapa filmförslag automatiskt (Objektfilm per adress)", isOn: $settings.reelProposalEnabled)

                if settings.reelProposalEnabled {
                    Text("Sist i körningen skapas en film (9:16, 5 bilder) per adress i mappen \"<adress> FILM\", av bilderna i FÄRDIGA, annars FÖRBÄTTRADE, annars TITTBILDER (minst 3 bilder). Rum och kvalitet hämtas ur AI-taggningen. En film som du redigerat eller skickat till mäklaren rörs aldrig. Kräver kalendermatchning (adresserna).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Inga filmförslag skapas automatiskt. Du kan fortfarande göra filmer från Bildspel.")
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

            Section("Fältanteckningar (iPhone-appen)") {
                HStack {
                    Text("Matchningsfönster")
                    Spacer()
                    TextField("", value: $settings.fieldNotesMatchWindowSeconds, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("sekunder")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Klockdrift-korrigering")
                    Spacer()
                    TextField("", value: $settings.fieldNotesClockOffsetSeconds, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("sekunder")
                        .foregroundColor(.secondary)
                }
                Text("Vid import av en .photoflownotes-fil (\"Importera fältanteckningar…\") matchas varje anteckning mot bilden som togs närmast i tiden, inom matchningsfönstret. Anteckningar utanför fönstret blir sessionsanteckningar. Klockdrift-korrigeringen läggs till anteckningens tid innan matchning — positiv om telefonens klocka går efter kamerans.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Prestanda") {
                Picker("Samtidiga jobb", selection: $settings.maxParallelism) {
                    Text("Automatiskt").tag(0)
                    Text("1 (i följd, felsökning)").tag(1)
                    ForEach(2...6, id: \.self) { n in
                        Text("Högst \(n)").tag(n)
                    }
                }
                Text("Hur många HDR-grupper och förbättringar som körs samtidigt, och om AI-taggningen får köras medan HDR pågår. Automatiskt lämnar minst 2 kärnor och 25 % av minnet fria och sänker takten om datorn får ont om minne. Resultatet blir detsamma i alla lägen; 1 kör allt i följd som förr.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Progress") {
                Toggle("Detaljerad progress", isOn: $settings.detailedProgress)
                Text("Visar input-bilder och HDR-resultat live under bearbetning.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // "Previews"-sektionen (JPEG-kvalitet, Max dimension) är borttagen:
            // preview-steget extraherar kamerans inbäddade JPEG med exiftool
            // rakt av, utan omkodning eller skalning, så reglagen läste aldrig
            // av någon kod. De såg ut att styra kvaliteten men gjorde inget.
        }
        .formStyle(.grouped)
    }
}

/// Fas 4, flerval i Fas 10: låter användaren välja EN ELLER FLERA kalendrar
/// ur en flervalslista (listar EventKit-kalendrarna via `CalendarService`) i
/// stället för att bara skriva namnet i fritext. Fritextläget finns kvar som
/// fallback för de fall åtkomst ännu inte beviljats (eller nekats) — precis
/// vad `CalendarService.resolveCalendar`/`matchCalendarNames` redan stödjer
/// (exakt/skiftlägesokänslig/delvis matchning, per namn).
struct CalendarPickerRow: View {
    @ObservedObject var settings: AppSettings
    @State private var availableCalendars: [String] = []
    @State private var accessStatus: EKAuthorizationStatus = CalendarService.authorizationStatus
    @State private var isRequesting = false
    @State private var showTestMatchSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch accessStatus {
            case .fullAccess:
                calendarMultiSelect
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
                Text("Ingen kalenderåtkomst — ange kalendernamn manuellt nedan, eller aktivera åtkomst i Systeminställningar → Sekretess och säkerhet → Kalendrar.")
                    .font(.caption)
                    .foregroundColor(.orange)
                fallbackTextField
            }

            Button("Testa matchning…") { showTestMatchSheet = true }
                .disabled(accessStatus != .fullAccess)
            if accessStatus != .fullAccess {
                Text("Kräver kalenderåtkomst.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { refresh() }
        .sheet(isPresented: $showTestMatchSheet) {
            CalendarMatchTestSheet()
        }
    }

    // MARK: - Flerval (åtkomst beviljad)

    /// Namn som är sparade i `calendarNames` men som inte längre finns bland
    /// EventKit-kalendrarna (borttagen kalender sedan sist, eller ett gammalt
    /// fritextvärde) — visas ändå som ett eget, ikryssat alternativ i stället
    /// för att valet tyst försvinner bara för att listan uppdaterades.
    private var missingSelectedNames: [String] {
        settings.calendarNames.filter { !availableCalendars.contains($0) }
    }

    private var summaryText: String {
        let count = settings.calendarNames.count
        switch count {
        case 0: return "Alla kalendrar"
        case 1: return "1 kalender vald"
        default: return "\(count) kalendrar valda"
        }
    }

    private var calendarMultiSelect: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Toggle("Alla kalendrar", isOn: Binding(
                    get: { settings.calendarNames.isEmpty },
                    set: { isOn in if isOn { settings.calendarNames = [] } }
                ))
                Divider()
                ForEach(availableCalendars, id: \.self) { name in
                    Toggle(name, isOn: selectionBinding(for: name))
                }
                if !missingSelectedNames.isEmpty {
                    Divider()
                    ForEach(missingSelectedNames, id: \.self) { name in
                        Toggle("\(name) (hittas inte just nu)", isOn: selectionBinding(for: name))
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "calendar")
                    Text("Välj kalendrar")
                    Spacer()
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text(summaryText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func selectionBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { settings.calendarNames.contains(name) },
            set: { isOn in
                var names = settings.calendarNames
                if isOn {
                    if !names.contains(name) { names.append(name) }
                } else {
                    names.removeAll { $0 == name }
                }
                settings.calendarNames = names
            }
        )
    }

    // MARK: - Fritextfallback (åtkomst saknas)

    /// Ett kalendernamn per rad — INTE kommaseparerat i ett enda fält, eftersom
    /// riktiga kalendernamn kan innehålla komma (och de flesta andra
    /// separatortecken). Radbrytning är i praktiken aldrig del av ett
    /// kalendernamn, så den kan användas som separator här.
    private var fallbackNamesBinding: Binding<String> {
        Binding(
            get: { settings.calendarNames.joined(separator: "\n") },
            set: { newValue in
                settings.calendarNames = newValue
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var fallbackTextField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kalendernamn, ett per rad (exakt eller delvis; tomt = alla kalendrar)")
                .font(.caption2)
                .foregroundColor(.secondary)
            TextEditor(text: fallbackNamesBinding)
                .font(.system(size: 12))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
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

/// Fas 10: "Testa matchning"-arket i Kalenderintegration. Visar vad en riktig
/// pipeline-körning SKULLE matcha (adress + mappnamn per kalenderhändelse)
/// för de valda kalendrarna, UTAN att röra pipelinen eller skriva något till
/// disk. Läser händelser via `CalendarService.previewEvents(daysBack:)`
/// (read-only) och extraherar adress precis som en riktig körning gör: via
/// `BookingTitleParser` (Foundation Models) när modellen är tillgänglig på
/// enheten, annars `CalendarService.extractAddress`-heuristiken direkt —
/// vilken väg som användes visas som en liten etikett per rad. Geokodning
/// (MapKit, nätverk) körs ALDRIG automatiskt — bara på begäran, per rad eller
/// för alla synliga rader via knappen i headern.
struct CalendarMatchTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var daysBack = 14
    @State private var rows: [PreviewRow] = []
    @State private var isLoading = false
    @State private var accessStatus: EKAuthorizationStatus = CalendarService.authorizationStatus
    @State private var geocodeResults: [String: GeocodeState] = [:]
    @State private var isGeocodingAll = false

    private enum GeocodeState: Equatable {
        case loading
        case found(latitude: Double, longitude: Double)
        case notFound
    }

    private struct PreviewRow: Identifiable {
        let id: String
        let date: Date
        let title: String
        /// `nil` = ingen adress kunde extraheras ur titeln — precis de fallen
        /// användaren vill upptäcka innan en riktig körning, se doc-kommentaren
        /// ovan.
        let address: String?
        let extractionPath: String
        let folderName: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Picker("Period", selection: $daysBack) {
                Text("7 dagar").tag(7)
                Text("14 dagar").tag(14)
                Text("30 dagar").tag(30)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: daysBack) { _, _ in loadEvents() }

            Divider()

            content
        }
        .frame(minWidth: 580, minHeight: 440)
        .onAppear {
            accessStatus = CalendarService.authorizationStatus
            loadEvents()
        }
    }

    private var header: some View {
        HStack {
            Text("Testa kalendermatchning")
                .font(.headline)
            Spacer()
            if rows.contains(where: { $0.address != nil }) {
                Button(isGeocodingAll ? "Kontrollerar GPS…" : "Kontrollera GPS för alla") {
                    geocodeAll()
                }
                .disabled(isGeocodingAll)
            }
            Button("Stäng") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if accessStatus != .fullAccess {
            emptyState(
                icon: "calendar.badge.exclamationmark",
                text: "Ingen kalenderåtkomst — kan inte förhandsvisa matchning. Aktivera åtkomst i Systeminställningar → Sekretess och säkerhet → Kalendrar.",
                color: .orange
            )
        } else if isLoading {
            emptyState(icon: "hourglass", text: "Laddar händelser…", color: .secondary)
        } else if rows.isEmpty {
            emptyState(
                icon: "calendar",
                text: "Inga kalenderhändelser hittades de senaste \(daysBack) dagarna i valda kalendrar.",
                color: .secondary
            )
        } else {
            List(rows) { row in
                rowView(row)
            }
            .listStyle(.plain)
        }
    }

    private func emptyState(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
            Text(text)
                .font(.callout)
                .foregroundColor(color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: PreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.date, format: .dateTime.day().month().hour().minute())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(row.extractionPath)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let address = row.address, let folderName = row.folderName {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle")
                        .foregroundColor(.green)
                    Text(address)
                        .font(.system(size: 12))
                    Text("→ \"\(folderName)\"")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                geocodeRow(for: row)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Ingen adress kunde extraheras ur titeln")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func geocodeRow(for row: PreviewRow) -> some View {
        switch geocodeResults[row.id] {
        case .some(.loading):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Geokodar…").font(.caption2).foregroundColor(.secondary)
            }
        case .some(.found(let lat, let lon)):
            Text(String(format: "GPS: %.4f, %.4f", lat, lon))
                .font(.caption2)
                .foregroundColor(.green)
        case .some(.notFound):
            Text("Kunde inte geokoda adressen")
                .font(.caption2)
                .foregroundColor(.orange)
        case .none:
            Button("Kontrollera GPS") { geocode(row) }
                .font(.caption2)
                .buttonStyle(.link)
        }
    }

    // MARK: - Data (strikt read-only)

    /// Läser händelser via `CalendarService.previewEvents` (ingen skrivning,
    /// ingen påverkan på `accessGranted`/pipelinen) och extraherar adress för
    /// varje händelse. `BookingTitleParser` cachar titel→`BookingInfo` som
    /// vanligt (samma cache pipelinen skulle byggt ändå) — inget annat
    /// cachas eller skrivs av det här arket.
    private func loadEvents() {
        accessStatus = CalendarService.authorizationStatus
        guard accessStatus == .fullAccess else { rows = []; return }
        isLoading = true
        geocodeResults = [:]
        let daysBackSnapshot = daysBack
        Task {
            let events = CalendarService.shared.previewEvents(daysBack: daysBackSnapshot)
            let useModel = BookingTitleParser.isModelAvailable
            var built: [PreviewRow] = []
            for event in events {
                let title = event.title ?? "(ingen titel)"
                let id = event.eventIdentifier ?? UUID().uuidString
                let date = event.startDate ?? Date()
                let address: String?
                let path: String
                if useModel {
                    let info = await BookingTitleParser.shared.parse(title: title)
                    address = BookingTitleParser.addressString(from: info)
                    path = "Foundation Models"
                } else {
                    address = CalendarService.extractAddress(from: title)
                    path = "Heuristik"
                }
                let folder = address.map { CalendarService.sanitizeFolderName($0) }
                built.append(PreviewRow(id: id, date: date, title: title, address: address, extractionPath: path, folderName: folder))
            }
            rows = built
            isLoading = false
        }
    }

    private func geocode(_ row: PreviewRow) {
        guard let address = row.address else { return }
        geocodeResults[row.id] = .loading
        Task {
            if let coord = await CalendarService.shared.geocodeAddress(address) {
                geocodeResults[row.id] = .found(latitude: coord.latitude, longitude: coord.longitude)
            } else {
                geocodeResults[row.id] = .notFound
            }
        }
    }

    /// Seriellt (inte N samtidiga MapKit-anrop) — geokodar bara rader som
    /// ännu inte har ett resultat, en adress i taget.
    private func geocodeAll() {
        isGeocodingAll = true
        Task {
            for row in rows {
                guard let address = row.address, geocodeResults[row.id] == nil else { continue }
                geocodeResults[row.id] = .loading
                if let coord = await CalendarService.shared.geocodeAddress(address) {
                    geocodeResults[row.id] = .found(latitude: coord.latitude, longitude: coord.longitude)
                } else {
                    geocodeResults[row.id] = .notFound
                }
            }
            isGeocodingAll = false
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
                .background(.regularMaterial)
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
        // Fas 5: riktigt kort (regularMaterial), samma stil som StepCardView.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
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
