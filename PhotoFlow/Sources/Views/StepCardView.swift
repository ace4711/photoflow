import SwiftUI

struct StepCardView: View {
    let step: DashboardStep
    let status: StepStatus
    var onTap: (() -> Void)? = nil
    var onRerun: (() -> Void)? = nil
    /// For manualReview step: pass allPhotos to show cull stats
    var allPhotos: [PhotoItem] = []
    /// Fas 9: infopopoverns "Öppna inställningar"-knapp — hoppar till
    /// `SettingsView`s flik med index `tab` (se `DashboardStep.info.settingsTab`).
    var onOpenSettings: ((_ tab: Int) -> Void)? = nil
    @State private var showDetail: Bool = false
    @State private var showStepInfo: Bool = false
    // Fas 9: infoknappen ska vara diskret — låg opacitet normalt, tydligare
    // vid hover över KORTET, full opacitet vid hover över själva knappen.
    @State private var isCardHovered: Bool = false
    @State private var isInfoButtonHovered: Bool = false

    @State private var dashPhase: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    private var infoButtonOpacity: Double {
        if isInfoButtonHovered { return 1.0 }
        if isCardHovered { return 0.55 }
        return 0.16
    }

    private var phaseColor: Color {
        switch status.phase {
        case .idle: return .secondary.opacity(0.3)
        case .watching: return .blue.opacity(0.5)
        case .queued: return .orange.opacity(0.5)
        case .active: return .accentColor
        case .needsAttention: return .orange
        case .paused: return .yellow.opacity(0.6)
        case .complete: return .green
        case .error: return .red
        case .disabled: return .secondary.opacity(0.15)
        }
    }

    private var iconColor: Color {
        switch status.phase {
        case .idle: return .secondary
        case .watching: return .blue
        case .queued: return .orange
        case .active: return .accentColor
        case .needsAttention: return .orange
        case .paused: return .yellow
        case .complete: return .green
        case .error: return .red
        case .disabled: return .secondary.opacity(0.4)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Icon
            ZStack {
                Image(systemName: step.systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 44, height: 44)

                if status.phase == .complete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                        .background(Circle().fill(.white).frame(width: 12, height: 12))
                        .offset(x: 16, y: -16)
                }
            }

            // Title
            Text(step.title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundColor(status.phase == .disabled ? .secondary.opacity(0.5) : .primary)
                .lineLimit(1)

            // Subtitle
            Text(step.subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)

            // Status text + rerun button
            if status.phase == .complete || status.phase == .needsAttention || status.isError {
                HStack(spacing: 4) {
                    if !status.statusText.isEmpty && !(step == .manualReview && status.phase == .needsAttention) {
                        statusLabel
                    }
                    Spacer(minLength: 0)
                    if let onRerun {
                        Button(action: onRerun) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Kor om detta steg")
                    }
                }
                .frame(height: 16)
            } else if !status.statusText.isEmpty {
                statusLabel
            } else {
                Color.clear.frame(height: 16)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 130)
        // Fas 5: riktigt kort (regularMaterial) i stället för en solid
        // controlBackgroundColor-platta — samma tidsenliga stil som Fas 3g
        // gav DashboardView/PreviewCullView/BracketReviewView.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(status.phase == .disabled ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial))
        )
        .overlay {
            borderOverlay
        }
        .overlay(alignment: .topTrailing) {
            if !status.logEntries.isEmpty {
                Button(action: { showDetail = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        // Needs attention badge (top-left) — only if unreviewed photos remain
        .overlay(alignment: .topLeading) {
            if step == .manualReview && status.phase == .needsAttention && allPhotos.contains(where: { !$0.accepted && !$0.rejected }) {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                    Text("Väntar")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
                .padding(6)
            }
        }
        // Cull stats (bottom-left)
        .overlay(alignment: .bottomLeading) {
            if step == .manualReview && !allPhotos.isEmpty {
                HStack(spacing: 5) {
                    miniStat(icon: "checkmark.circle.fill", count: allPhotos.filter { $0.accepted }.count, color: .green)
                    miniStat(icon: "xmark.circle.fill", count: allPhotos.filter { $0.rejected }.count, color: .red)
                    miniStat(icon: "questionmark.circle", count: allPhotos.filter { !$0.accepted && !$0.rejected }.count, color: .gray)
                }
                .padding(6)
            }
        }
        // Fas 9: diskret infoknapp (bottom-trailing — det enda hörnet inget
        // annat overlay redan använder: top-trailing är logg-info, top-leading
        // "Väntar", bottom-leading gallringsstatistik). Egen tydlig träffyta
        // (.contentShape + .buttonStyle(.plain)) så den aldrig triggar kortets
        // egen onTapGesture/"kör om"-knappen.
        .overlay(alignment: .bottomTrailing) {
            Button(action: { showStepInfo = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(infoButtonOpacity)
            .animation(.easeInOut(duration: 0.15), value: infoButtonOpacity)
            .onHover { hovering in isInfoButtonHovered = hovering }
            .padding(4)
            .accessibilityLabel("Om steget: \(step.title)")
            .popover(isPresented: $showStepInfo, arrowEdge: .bottom) {
                StepInfoPopover(step: step, onOpenSettings: onOpenSettings)
            }
        }
        .opacity(status.phase == .disabled ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in isCardHovered = hovering }
        .help(step.info.summary)
        .onAppear { startAnimations() }
        .onChange(of: status.phase) { _, _ in startAnimations() }
        .sheet(isPresented: $showDetail) {
            StepDetailSheet(step: step, status: status)
        }
    }

    private func miniStat(icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: - Status label

    @ViewBuilder
    private var statusLabel: some View {
        switch status.phase {
        case .active:
            HStack(spacing: 4) {
                if status.totalCount > 0 {
                    Text(status.statusText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                } else {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(status.statusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(height: 16)

        case .needsAttention:
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                Text(status.statusText)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.orange)
            .frame(height: 16)

        case .error:
            Text(status.statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.red)
                .lineLimit(1)
                .frame(height: 16)

        case .complete:
            Text(status.statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green)
                .frame(height: 16)

        default:
            Text(status.statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(height: 16)
        }
    }

    // MARK: - Border overlay (pulsing, spinning, static)

    @ViewBuilder
    private var borderOverlay: some View {
        switch status.phase {
        case .watching:
            // Pulsing ring
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor, lineWidth: 2)

                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor.opacity(pulseOpacity), lineWidth: 2)
                    .scaleEffect(pulseScale)
            }

        case .active:
            // Marching ants
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor.opacity(0.15), lineWidth: 3)

                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6], dashPhase: dashPhase))
            }

        case .needsAttention:
            // Pulsing orange border
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor, lineWidth: 2.5)

                RoundedRectangle(cornerRadius: 14)
                    .stroke(phaseColor.opacity(pulseOpacity), lineWidth: 2.5)
                    .scaleEffect(pulseScale)
            }

        case .complete:
            RoundedRectangle(cornerRadius: 14)
                .stroke(phaseColor, lineWidth: 2)

        case .error:
            RoundedRectangle(cornerRadius: 14)
                .stroke(phaseColor, lineWidth: 2.5)

        case .paused:
            RoundedRectangle(cornerRadius: 14)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundColor(phaseColor)

        case .queued:
            RoundedRectangle(cornerRadius: 14)
                .stroke(phaseColor, lineWidth: 1.5)

        default:
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        switch status.phase {
        case .watching, .needsAttention:
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.06
                pulseOpacity = 0.15
            }
        case .active:
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                dashPhase = -14
            }
        default:
            pulseScale = 1.0
            pulseOpacity = 0.6
            dashPhase = 0
        }
    }
}

// MARK: - Step info popover

/// Fas 9: diskret förklaring av vad ett steg gör och hur logiken fungerar —
/// innehållet kommer från `DashboardStep.info` (`DashboardStepInfo.swift`),
/// härlett ur den faktiska pipeline-koden, inte påhittat. Stil matchar
/// appens övriga glas/`regularMaterial`-look sedan Fas 3g/5.
struct StepInfoPopover: View {
    let step: DashboardStep
    var onOpenSettings: ((_ tab: Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var info: StepInfo { step.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
                Text(step.title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
            }

            Text(info.summary)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(info.details.enumerated()), id: \.offset) { _, detail in
                    HStack(alignment: .top, spacing: 6) {
                        Text("–")
                            .foregroundColor(.secondary)
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let settingsTab = info.settingsTab, let onOpenSettings {
                Divider()
                Button {
                    dismiss()
                    onOpenSettings(settingsTab)
                } label: {
                    Label("Öppna inställningar", systemImage: "gearshape")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial)
    }
}

// MARK: - Step detail sheet

struct StepDetailSheet: View {
    let step: DashboardStep
    let status: StepStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: step.systemImage)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(step.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 8, height: 8)
                    Text(status.statusText)
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(phaseColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(phaseColor.opacity(0.1))
                .cornerRadius(6)

                if let updated = status.lastUpdated {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button("Stang") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.regularMaterial)

            Divider()

            // Summary
            HStack(spacing: 24) {
                if status.totalCount > 0 {
                    summaryItem(label: "Totalt", value: "\(status.totalCount)")
                }
                if status.processedCount > 0 {
                    summaryItem(label: "Bearbetade", value: "\(status.processedCount)")
                }
                if status.queuedCount > 0 {
                    summaryItem(label: "I ko", value: "\(status.queuedCount)")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Log entries
            if status.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("Ingen logg tillganglig")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(status.logEntries) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.timeString)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 60, alignment: .leading)
                                    logIcon(line.type)
                                        .frame(width: 14)
                                    Text(line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(logColor(line.type))
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 3)
                                .background(
                                    line.type == .error ? Color.red.opacity(0.05) :
                                    line.type == .warning ? Color.orange.opacity(0.03) :
                                    Color.clear
                                )
                                .id(line.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        if let last = status.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 450)
    }

    private var phaseColor: Color {
        switch status.phase {
        case .idle: return .secondary
        case .watching: return .blue
        case .queued: return .orange
        case .active: return .accentColor
        case .needsAttention: return .orange
        case .paused: return .yellow
        case .complete: return .green
        case .error: return .red
        case .disabled: return .secondary
        }
    }

    private func summaryItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func logColor(_ type: LogLine.LogType) -> Color {
        switch type {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    @ViewBuilder
    private func logIcon(_ type: LogLine.LogType) -> some View {
        switch type {
        case .info:
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
        }
    }
}

