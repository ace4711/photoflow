import SwiftUI
import AppKit

/// Stub: appen startar ALDRIG Lightroom-körningen själv. Den styr Fredriks skärm och tangentbord i
/// 15–20 minuter och körs bara när han startar den (plan, avsnitt 8, beslut 3), så arket visar bara
/// instruktioner och kommandot att köra i terminalen.
struct HDRCompareLightroomSheet: View {
    let manifestURL: URL?
    @Environment(\.dismiss) private var dismiss

    private var command: String {
        "photoflow-cli lr-trigger --manifest \"\(manifestURL?.path ?? HDRCompareManifest.defaultURL.path)\""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Starta Lightroom-körning").font(.title2.bold())
            Text("Den här knappen startar ingenting. Körningen styr skärm och tangentbord i ungefär 15–20 minuter (30–60 s per grupp), så du startar den själv när du kan lämna datorn.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Öppna Lightroom Classic med katalogen PhotoFlow-HDR-test.lrcat och låt PhotoFlowLR-pluginet vara aktivt.", systemImage: "1.circle")
                Label("Kontrollera HDR-dialogen en gång: Auto Align på, Auto Settings på, Deghost Låg, Create Stack av.", systemImage: "2.circle")
                Label("Kör kommandot nedan i Terminal. Det skriver triggern och väntar tills Lightroom är klart.", systemImage: "3.circle")
                Label("Öppna manifestet igen här när det är klart; lr-auto dyker då upp bland varianterna.", systemImage: "4.circle")
            }
            .font(.callout)
            GroupBox {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            HStack {
                Button("Kopiera kommandot", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Spacer()
                Button("Stäng") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
