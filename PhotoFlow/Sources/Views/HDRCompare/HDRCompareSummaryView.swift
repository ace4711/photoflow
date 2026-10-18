import SwiftUI

/// Sammanfattningen: vinst/lika/förlust totalt och per kategori, aspekter som fällde vår HDR och
/// måttabellen (medel/median), med Markdown-export.
struct HDRCompareSummaryView: View {
    @Bindable var model: HDRCompareModel

    var body: some View {
        ScrollView {
            if let r = model.summary {
                VStack(alignment: .leading, spacing: 20) {
                    header(r)
                    verdicts(r)
                    aspects(r)
                    metricsTable(r)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("Inget manifest öppet", systemImage: "chart.bar")
            }
        }
        .task {
            // Mått som saknas räknas i bakgrunden första gången sammanfattningen visas.
            if model.metrics == nil { model.computeMetrics() }
        }
    }

    private func header(_ r: HDRCompareSummary.Result) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sammanfattning").font(.title2.bold())
                Text("\(r.ratedGroups) av \(r.totalGroups) grupper bedömda, sett ur \(r.subject)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Jämför bilderna", systemImage: "rectangle.split.2x1") { model.showSummary = false }
                .buttonStyle(.borderedProminent)
            Button("Exportera Markdown…", systemImage: "square.and.arrow.up") { model.exportSummaryWithPanel() }
        }
    }

    private func verdicts(_ r: HDRCompareSummary.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Betyg").font(.headline)
            HStack(spacing: 24) {
                stat("Vinster", r.total.wins, .green)
                stat("Lika", r.total.ties, .secondary)
                stat("Förluster", r.total.losses, .red)
            }
            ForEach(r.byOpponent.sorted(by: { $0.key < $1.key }), id: \.key) { opp, t in
                Text("Mot \(opp): \(HDRCompareSummary.tallyText(t))").font(.callout).foregroundStyle(.secondary)
            }
            if !r.byCategory.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Kategori").gridColumnAlignment(.leading)
                        Text("Vinster"); Text("Lika"); Text("Förluster")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(r.byCategory, id: \.category) { cat, t in
                        GridRow {
                            Text(HDRCompareCategory.title(cat)).gridColumnAlignment(.leading)
                            Text("\(t.wins)"); Text("\(t.ties)"); Text("\(t.losses)")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func aspects(_ r: HDRCompareSummary.Result) -> some View {
        if !r.aspectsWhenLosing.isEmpty || !r.aspectsWhenWinning.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Aspekter").font(.headline)
                if !r.aspectsWhenLosing.isEmpty {
                    Text("När \(r.subject) förlorade").font(.subheadline).foregroundStyle(.secondary)
                    Text(r.aspectsWhenLosing.map { "\(HDRCompareSummary.aspectTitle($0.aspect)) (\($0.count))" }.joined(separator: ", "))
                }
                if !r.aspectsWhenWinning.isEmpty {
                    Text("När \(r.subject) vann").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    Text(r.aspectsWhenWinning.map { "\(HDRCompareSummary.aspectTitle($0.aspect)) (\($0.count))" }.joined(separator: ", "))
                }
            }
        }
    }

    private func metricsTable(_ r: HDRCompareSummary.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mått (medel / median)").font(.headline)
                Spacer()
                if let p = model.metricsProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 140)
                    Text("\(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                    Button("Avbryt") { model.cancelMetrics() }
                } else {
                    Button("Räkna om mått") { model.computeMetrics(force: true) }
                }
            }
            if r.metrics.isEmpty {
                Text(model.metricsProgress == nil ? "Inga mått ännu." : "Räknar mått i bakgrunden…")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(r.metrics, id: \.variant) { Text($0.variant).font(.caption.bold()) }
                    }
                    GridRow {
                        Text("Grupper").gridColumnAlignment(.leading)
                        ForEach(r.metrics, id: \.variant) { Text("\($0.groups)") }
                    }
                    GridRow {
                        Text("Dålig registrering").gridColumnAlignment(.leading)
                        ForEach(r.metrics, id: \.variant) { Text("\($0.badRegistrations)") }
                    }
                    ForEach(Array(r.columns.enumerated()), id: \.offset) { i, col in
                        GridRow {
                            Text(col.title).gridColumnAlignment(.leading)
                            ForEach(r.metrics, id: \.variant) { row in
                                if let c = row.cells[i] {
                                    Text("\(HDRCompareSummary.format(c.mean, col)) / \(HDRCompareSummary.format(c.median, col))")
                                } else {
                                    Text("–").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}
