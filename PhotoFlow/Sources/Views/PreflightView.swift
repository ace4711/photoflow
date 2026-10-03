import SwiftUI

/// Arket för startkontrollen (`Preflight`/`PreflightModel`): det som måste
/// åtgärdas överst, med en knapp per brist, därefter allt som är klart per
/// sektion och mappträdet som visar var appen lägger sina filer.
struct PreflightView: View {
    @ObservedObject var model: PreflightModel
    /// Åtgärder som rör tillstånd `DashboardView` äger (välj mapp, öppna en flik
    /// i Inställningar). Övriga går direkt till `model.perform`.
    let onFix: (Preflight.Fix) -> Void
    @Environment(\.dismiss) private var dismiss

    private var report: Preflight.Report { model.report }
    private var needsAction: [Preflight.Check] {
        report.checks.filter { $0.status == .blocker || $0.status == .warning }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = model.actionMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                    }

                    if !needsAction.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Att åtgärda")
                                .font(.headline)
                            ForEach(needsAction) { check in
                                PreflightRow(check: check, showSection: true, onFix: handle)
                            }
                        }
                    }

                    ForEach(Preflight.Section.allCases, id: \.self) { section in
                        let rows = report.checks(in: section).filter { $0.status == .ok || $0.status == .info }
                        if !rows.isEmpty || (section == .folders && !report.structure.isEmpty) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(section.title, systemImage: section.systemImage)
                                    .font(.headline)
                                ForEach(rows) { check in
                                    PreflightRow(check: check, showSection: false, onFix: handle)
                                }
                                if section == .folders && !report.structure.isEmpty {
                                    structureTree
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 660)
    }

    // MARK: - Delar

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: Self.icon(for: report.worst))
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Self.color(for: report.worst))
            VStack(alignment: .leading, spacing: 2) {
                Text("Startkontroll")
                    .font(.title2.weight(.semibold))
                Text(report.checks.isEmpty ? "Kontrollerar…" : headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
    }

    private var headline: String {
        switch report.worst {
        case .blocker: return "\(report.summary) innan pipelinen kan köra."
        case .warning: return "Pipelinen kan köra, men titta på \(report.warnings.count == 1 ? "varningen" : "varningarna")."
        case .ok, .info: return "Mappar, kalender och verktyg är klara."
        }
    }

    private var footer: some View {
        HStack {
            if let lastRun = model.lastRun {
                Text("Kontrollerad \(lastRun.formatted(date: .omitted, time: .shortened)) · uppdateras när en disk ansluts eller en inställning ändras")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Kontrollera igen") {
                Task { await model.run(includeTools: true) }
            }
            .disabled(model.isRunning)
            Button("Klar") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var structureTree: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Så här ser mapparna ut")
                .font(.subheadline.weight(.medium))
                .padding(.bottom, 2)
            ForEach(report.structure) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.exists ? "folder.fill" : "folder.badge.questionmark")
                        .foregroundStyle(entry.exists ? Color.accentColor : (entry.createdByPipeline ? .secondary : .red))
                        .frame(width: 18)
                    Text(entry.depth == 0 ? entry.path : entry.name)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("— \(entry.purpose)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.exists ? "finns" : (entry.createdByPipeline ? "skapas vid körning" : "saknas"))
                        .font(.caption)
                        .foregroundStyle(entry.exists ? .green : (entry.createdByPipeline ? .secondary : .red))
                }
                .padding(.leading, CGFloat(entry.depth) * 22)
            }
            Text("Adressmapparna (\"Gatan 1, Ort\", \"… TITTBILDER\", \"… ÖVRIGA\") och \"Osorterade\" skapas i outputmappen vid körning.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private func handle(_ fix: Preflight.Fix) {
        switch fix {
        case .chooseInput, .chooseOutput, .openSettings:
            onFix(fix)
        default:
            Task { await model.perform(fix) }
        }
    }

    // MARK: - Färger och ikoner (delas med verktygsfältet)

    static func color(for status: Preflight.Status) -> Color {
        switch status {
        case .ok: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .blocker: return .red
        }
    }

    static func icon(for status: Preflight.Status) -> String {
        switch status {
        case .ok: return "checkmark.seal.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocker: return "xmark.octagon.fill"
        }
    }
}

struct PreflightRow: View {
    let check: Preflight.Check
    let showSection: Bool
    let onFix: (Preflight.Fix) -> Void

    private var color: Color { PreflightView.color(for: check.status) }
    private var prominent: Bool { check.status == .blocker || check.status == .warning }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: PreflightView.icon(for: check.status))
                .font(.system(size: prominent ? 18 : 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.title)
                        .font(prominent ? .body.weight(.semibold) : .callout.weight(.medium))
                    if showSection {
                        Text(check.section.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = check.path {
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let fix = check.fix {
                if prominent {
                    Button(fix.label) { onFix(fix) }
                        .buttonStyle(.borderedProminent)
                        .tint(color)
                        .controlSize(.small)
                } else {
                    Button(fix.label) { onFix(fix) }
                        .controlSize(.small)
                }
            }
        }
        .padding(prominent ? 12 : 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(prominent ? AnyShapeStyle(color.opacity(0.08)) : AnyShapeStyle(.regularMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(prominent ? 0.45 : 0.15), lineWidth: 1)
        )
    }
}
