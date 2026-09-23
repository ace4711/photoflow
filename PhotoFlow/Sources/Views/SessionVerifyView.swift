import SwiftUI
import AppKit

/// "Verifiera session": kör `SessionVerifier` mot en outputmapp och visar
/// resultatet grupperat efter allvarlighetsgrad. Öppnas som ett sheet från
/// `SessionHistoryView` — antingen för en specifik historikpost eller för
/// den just nu konfigurerade sessionen (`AppSettings.shared.outputDirectory`).
///
/// Lägger INGET i `DashboardView`s verktygsfält (en annan agent äger den
/// filen, se `agent-rules.md`/`FORBATTRINGAR.md`) — en genväg därifrån för
/// "den aktuella sessionen" kan läggas till senare av den som äger
/// `DashboardView`.
struct SessionVerifyView: View {
    let outputDirectory: URL
    /// Visas i titeln, t.ex. en adress eller "aktuell session" — rent
    /// kosmetiskt, ingen kod fattar beslut baserat på den.
    var subtitle: String?

    @Environment(\.dismiss) private var dismiss

    @State private var report: SessionVerifier.Report?
    @State private var isRunning = false
    @State private var runError: String?
    @State private var verifyTask: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if isRunning {
                    ContentUnavailableView {
                        Label("Verifierar session...", systemImage: "checkmark.shield")
                    } description: {
                        Text(outputDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let runError {
                    ContentUnavailableView {
                        Label("Verifieringen misslyckades", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(runError)
                    } actions: {
                        Button("Försök igen", action: runVerification)
                    }
                } else if let report {
                    reportBody(report)
                } else {
                    Color.clear
                }
            }
            .navigationTitle(subtitle.map { "Verifiera session — \($0)" } ?? "Verifiera session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") {
                        verifyTask?.cancel()
                        dismiss()
                    }
                }
                if let report {
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied ? "Kopierad!" : "Kopiera rapport", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            copyReport(report)
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Kör igen", systemImage: "arrow.clockwise", action: runVerification)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { runVerification() }
        .onDisappear { verifyTask?.cancel() }
    }

    @ViewBuilder
    private func reportBody(_ report: SessionVerifier.Report) -> some View {
        List {
            Section {
                SummaryHeaderView(report: report)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach([SessionVerifier.Severity.error, .warning, .ok], id: \.self) { severity in
                let findings = report.findings.filter { $0.severity == severity }.sorted { $0.id < $1.id }
                if !findings.isEmpty {
                    Section(sectionTitle(severity, count: findings.count)) {
                        ForEach(findings) { finding in
                            FindingRow(finding: finding)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func sectionTitle(_ severity: SessionVerifier.Severity, count: Int) -> String {
        switch severity {
        case .error: return "Fel (\(count))"
        case .warning: return "Varningar (\(count))"
        case .ok: return "OK (\(count))"
        }
    }

    private func runVerification() {
        verifyTask?.cancel()
        report = nil
        runError = nil
        isRunning = true
        let outputDirectory = outputDirectory
        verifyTask = Task {
            do {
                let result = try await SessionVerifier.verify(outputDir: outputDirectory)
                if Task.isCancelled { return }
                report = result
                isRunning = false
            } catch is CancellationError {
                // Sheeten stängdes eller "Kör igen" avbröt en pågående körning — inget att visa.
            } catch {
                if Task.isCancelled { return }
                runError = error.localizedDescription
                isRunning = false
            }
        }
    }

    private func copyReport(_ report: SessionVerifier.Report) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.asPlainText(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// "3 fel, 5 varningar, 14 kontroller OK" — se `SessionVerifier.Report.summaryText`.
private struct SummaryHeaderView: View {
    let report: SessionVerifier.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                countBadge("\(report.errorCount) fel", color: .red, isEmphasized: report.errorCount > 0)
                countBadge("\(report.warningCount) varningar", color: .orange, isEmphasized: report.warningCount > 0)
                countBadge("\(report.okCount) OK", color: .green, isEmphasized: false)
                Spacer()
            }
            Text(report.outputDirectory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func countBadge(_ text: String, color: Color, isEmphasized: Bool) -> some View {
        Text(text)
            .font(.system(.body, design: .rounded, weight: isEmphasized ? .bold : .regular))
            .foregroundStyle(isEmphasized ? color : .secondary)
    }
}

private struct FindingRow: View {
    let finding: SessionVerifier.Finding
    @State private var expanded = false

    private var icon: String {
        switch finding.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .error: return .red
        case .warning: return .orange
        case .ok: return .green
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let recommendation = finding.recommendation {
                    Label(recommendation, systemImage: "wrench.and.screwdriver")
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
                if !finding.affectedFiles.isEmpty {
                    affectedFilesView
                }
            }
            .padding(.top, 4)
            .padding(.leading, 28)
        } label: {
            Label(finding.title, systemImage: icon)
                .foregroundStyle(finding.severity == .ok ? .primary : .primary)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var affectedFilesView: some View {
        let shown = finding.affectedFiles.prefix(25)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, path in
                HStack {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Visa i Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if finding.affectedFiles.count > shown.count {
                Text("... och \(finding.affectedFiles.count - shown.count) till")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
