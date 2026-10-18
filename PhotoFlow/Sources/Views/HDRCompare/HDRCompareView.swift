import SwiftUI

/// Innehållet i fönstret "HDR-jämförelse": grupplista till vänster, bilder och bedömning till höger
/// (eller sammanfattningen).
struct HDRCompareView: View {
    @State private var model = HDRCompareModel()

    var body: some View {
        HSplitView {
            HDRCompareGroupList(model: model)
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 700)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .navigationTitle("HDR-jämförelse")
        .toolbar { toolbar }
        .task { model.openStoredOrDefault() }
        .sheet(isPresented: $model.showLightroomSheet) {
            HDRCompareLightroomSheet(manifestURL: model.manifestURL)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.manifest == nil {
            VStack(spacing: 12) {
                ContentUnavailableView("Inget manifest öppet", systemImage: "photo.on.rectangle.angled",
                                       description: Text(model.loadError ?? "Öppna manifest.json från testkatalogen."))
                Button("Öppna manifest…") { model.pickManifest() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.showSummary {
            HDRCompareSummaryView(model: model)
        } else {
            VStack(spacing: 0) {
                HDRCompareControlBar(model: model)
                Divider()
                HDRCompareStage(model: model)
                Divider()
                HDRCompareVerdictPanel(model: model)
                    .background(.bar)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Föregående grupp", systemImage: "chevron.up") { model.selectRelative(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Nästa grupp", systemImage: "chevron.down") { model.selectRelative(1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Öppna manifest…", systemImage: "folder") { model.pickManifest() }
                .help("Öppna manifest.json (standard: ~/PhotoFlowBenchmark/hdr-lr/manifest.json)")
            Button("Starta Lightroom-körning…", systemImage: "play.rectangle") { model.showLightroomSheet = true }
                .help("Visar bara instruktioner; körningen startas i terminalen")
            Toggle("Sammanfattning", systemImage: "chart.bar", isOn: $model.showSummary)
                .toggleStyle(.button)
                .help("Betyg och mått för alla grupper")
        }
    }
}
