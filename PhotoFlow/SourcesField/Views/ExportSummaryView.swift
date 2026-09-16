import SwiftUI

/// Visas efter att "Exportera" skapat en `.photoflownotes`-fil — förklarar
/// nästa steg (dela till Mac:en) och innehåller själva delningsknappen
/// (`ShareLink`, öppnar systemets delningsark för AirDrop/Filer/mejl).
struct ExportSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let noteCount: Int

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)

                Text("\(noteCount) anteckningar redo att delas")
                    .font(.title3.weight(.semibold))

                Text(url.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Dela filen till din Mac via AirDrop, Filer eller mejl. Öppna den sedan i PhotoFlow (eller använd \"Importera fältanteckningar…\") för att matcha anteckningarna mot bilderna.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)

                ShareLink(item: url) {
                    Label("Dela fältanteckningar", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 32)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") { dismiss() }
                }
            }
        }
    }
}
