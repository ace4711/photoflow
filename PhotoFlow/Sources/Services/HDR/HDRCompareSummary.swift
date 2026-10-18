import Foundation

/// Sammanställning av betyg och mått för HDR-jämförelsen (vinst/oavgjort/förlust, aspekter,
/// måttabell) och dess Markdown-export. Rena funktioner, testbara utan bilder.
nonisolated enum HDRCompareSummary {
    struct Tally: Equatable, Sendable {
        var wins = 0, ties = 0, losses = 0
        var total: Int { wins + ties + losses }
    }

    struct Column: Equatable, Sendable {
        var id: String
        var title: String
        /// Antal decimaler i tabellen.
        var decimals: Int
        /// Procent: värdet är en andel 0…1 som visas som %.
        var percent = false
    }

    struct Cell: Equatable, Sendable {
        var mean: Double
        var median: Double
        var count: Int
    }

    struct MetricRow: Equatable, Sendable {
        var variant: String
        /// Antal grupper med mått för varianten.
        var groups: Int
        /// Grupper där registreringen flaggades som dålig.
        var badRegistrations: Int
        /// Parallell med `columns`; nil om måttet saknas för varianten.
        var cells: [Cell?]
    }

    struct Result: Equatable, Sendable {
        var subject: String
        var totalGroups: Int
        var ratedGroups: Int
        var total: Tally
        var byOpponent: [String: Tally]
        var byCategory: [(category: String, tally: Tally)]
        /// Aspekter som angavs när subject förlorade, flest först.
        var aspectsWhenLosing: [(aspect: String, count: Int)]
        var aspectsWhenWinning: [(aspect: String, count: Int)]
        var columns: [Column]
        var metrics: [MetricRow]

        static func == (l: Result, r: Result) -> Bool {
            l.subject == r.subject && l.totalGroups == r.totalGroups && l.ratedGroups == r.ratedGroups
                && l.total == r.total && l.byOpponent == r.byOpponent && l.columns == r.columns && l.metrics == r.metrics
                && l.byCategory.map(\.category) == r.byCategory.map(\.category)
                && l.byCategory.map(\.tally) == r.byCategory.map(\.tally)
                && l.aspectsWhenLosing.map(\.aspect) == r.aspectsWhenLosing.map(\.aspect)
                && l.aspectsWhenLosing.map(\.count) == r.aspectsWhenLosing.map(\.count)
                && l.aspectsWhenWinning.map(\.aspect) == r.aspectsWhenWinning.map(\.aspect)
                && l.aspectsWhenWinning.map(\.count) == r.aspectsWhenWinning.map(\.count)
        }
    }

    static let columns: [Column] = [
        Column(id: "clipHi", title: "Klippta högdagrar", decimals: 1, percent: true),
        Column(id: "clipLo", title: "Klippta skuggor", decimals: 1, percent: true),
        Column(id: "winClip", title: "Fönster: klippt", decimals: 1, percent: true),
        Column(id: "winSpread", title: "Fönster: luma p5–p95", decimals: 2),
        Column(id: "winCorr", title: "Fönster: struktur", decimals: 2),
        Column(id: "ghost", title: "Spökrutor", decimals: 1, percent: true),
        Column(id: "noise", title: "Brus σ", decimals: 4),
        Column(id: "castA", title: "Färgstick a*", decimals: 2),
        Column(id: "castB", title: "Färgstick b*", decimals: 2),
        Column(id: "median", title: "Medianluma", decimals: 2),
        Column(id: "contrast", title: "Lokal kontrast", decimals: 3),
        Column(id: "dEvsLR", title: "ΔE mot lr-auto", decimals: 2),
        Column(id: "dEvsRef", title: "ΔE mot ref", decimals: 2),
    ]

    /// Mått per kolumn ur en variants resultat.
    static func value(_ column: String, _ r: HDRCompareMetricsFile.VariantResult) -> Double? {
        let m = r.metrics
        switch column {
        case "clipHi": return m.clippedHighlights
        case "clipLo": return m.clippedShadows
        case "winClip": return m.window?.clippedFraction
        case "winSpread": return m.window?.lumaSpread
        case "winCorr": return m.window?.structureCorrelation
        case "ghost": return m.ghostTileFraction
        case "noise": return m.noiseSigma
        case "castA": return m.colorCast?.meanA
        case "castB": return m.colorCast?.meanB
        case "median": return m.tone.medianLuma
        case "contrast": return m.tone.localContrast
        case "dEvsLR": return r.vsLR?.deltaEMean
        case "dEvsRef": return r.vsRef?.deltaEMean
        default: return nil
        }
    }

    static func compute(manifest: HDRCompareManifest, verdicts: [HDRCompareVerdict],
                        metrics: HDRCompareMetricsFile?, subject: String = "pf-radiance") -> Result {
        let categoryOf = Dictionary(manifest.groups.map { ($0.id, $0.category ?? "") }, uniquingKeysWith: { a, _ in a })
        var total = Tally()
        var byOpponent: [String: Tally] = [:]
        var byCategory: [String: Tally] = [:]
        var losing: [String: Int] = [:], winning: [String: Int] = [:]
        var ratedGroups = Set<String>()

        for v in verdicts where v.involves(subject) && categoryOf[v.groupId] != nil {
            ratedGroups.insert(v.groupId)
            let opponent = v.left == subject ? v.right : v.left
            let outcome: Int  // 1 vinst, 0 lika, -1 förlust
            if let w = v.winner { outcome = w == subject ? 1 : -1 } else { outcome = 0 }
            func apply(_ t: inout Tally) {
                switch outcome { case 1: t.wins += 1; case -1: t.losses += 1; default: t.ties += 1 }
            }
            apply(&total)
            apply(&byOpponent[opponent, default: Tally()])
            apply(&byCategory[categoryOf[v.groupId] ?? "", default: Tally()])
            for a in v.aspects {
                if outcome == -1 { losing[a, default: 0] += 1 } else if outcome == 1 { winning[a, default: 0] += 1 }
            }
        }

        func sorted(_ d: [String: Int]) -> [(aspect: String, count: Int)] {
            d.map { (aspect: $0.key, count: $0.value) }.sorted { ($1.count, $0.aspect) < ($0.count, $1.aspect) }
        }

        return Result(
            subject: subject, totalGroups: manifest.groups.count, ratedGroups: ratedGroups.count,
            total: total, byOpponent: byOpponent,
            byCategory: byCategory.map { (category: $0.key, tally: $0.value) }.sorted { $0.category < $1.category },
            aspectsWhenLosing: sorted(losing), aspectsWhenWinning: sorted(winning),
            columns: columns, metrics: metricRows(manifest: manifest, metrics: metrics))
    }

    static func metricRows(manifest: HDRCompareManifest, metrics: HDRCompareMetricsFile?) -> [MetricRow] {
        guard let metrics else { return [] }
        let groupIDs = Set(manifest.groups.map(\.id))
        var variants = Set<String>()
        for (gid, perVariant) in metrics.groups where groupIDs.contains(gid) { variants.formUnion(perVariant.keys) }
        func rank(_ id: String) -> Int { HDRCompareManifest.Group.knownVariantOrder.firstIndex(of: id) ?? 99 }
        return variants.sorted { (rank($0), $0) < (rank($1), $1) }.map { variant in
            let results = metrics.groups.filter { groupIDs.contains($0.key) }.compactMap { $0.value[variant] }
            let bad = results.filter { $0.metrics.registration?.ok == false }.count
            let cells: [Cell?] = columns.map { col in
                // Fotografens ΔE mot sig själv och lr-auto mot lr-auto är meningslösa och finns inte i filen.
                let values = results.compactMap { value(col.id, $0) }.filter { $0.isFinite }
                guard !values.isEmpty else { return nil }
                let sortedValues = values.sorted()
                let mid = sortedValues.count / 2
                let median = sortedValues.count % 2 == 1 ? sortedValues[mid] : (sortedValues[mid - 1] + sortedValues[mid]) / 2
                return Cell(mean: values.reduce(0, +) / Double(values.count), median: median, count: values.count)
            }
            return MetricRow(variant: variant, groups: results.count, badRegistrations: bad, cells: cells)
        }
    }

    // MARK: - Formatering

    static func format(_ value: Double, _ column: Column) -> String {
        let v = column.percent ? value * 100 : value
        let s = String(format: "%.\(column.decimals)f", v)
        return (column.percent ? s + " %" : s).replacingOccurrences(of: ".", with: ",")
    }

    static func aspectTitle(_ raw: String) -> String {
        HDRCompareAspect(rawValue: raw)?.title ?? raw
    }

    static func tallyText(_ t: Tally) -> String {
        "\(t.wins) vinster, \(t.ties) lika, \(t.losses) förluster"
    }

    /// Kort Markdown-rapport (plan, avsnitt 5).
    static func markdown(_ r: Result, created: Date = Date()) -> String {
        var out: [String] = []
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        out.append("# HDR-jämförelse")
        out.append("")
        out.append("Skapad \(df.string(from: created)). \(r.ratedGroups) av \(r.totalGroups) grupper bedömda. Sett ur `\(r.subject)`.")
        out.append("")
        out.append("## Totalt")
        out.append("")
        out.append("- \(tallyText(r.total))")
        for (opp, t) in r.byOpponent.sorted(by: { $0.key < $1.key }) {
            out.append("- mot `\(opp)`: \(tallyText(t))")
        }
        if !r.byCategory.isEmpty {
            out.append("")
            out.append("## Per kategori")
            out.append("")
            out.append("| Kategori | Vinster | Lika | Förluster |")
            out.append("|---|---:|---:|---:|")
            for (cat, t) in r.byCategory {
                out.append("| \(HDRCompareCategory.title(cat)) | \(t.wins) | \(t.ties) | \(t.losses) |")
            }
        }
        if !r.aspectsWhenLosing.isEmpty {
            out.append("")
            out.append("## Aspekter som fällde `\(r.subject)`")
            out.append("")
            for (a, n) in r.aspectsWhenLosing { out.append("- \(aspectTitle(a)): \(n)") }
        }
        if !r.aspectsWhenWinning.isEmpty {
            out.append("")
            out.append("## Aspekter när `\(r.subject)` vann")
            out.append("")
            for (a, n) in r.aspectsWhenWinning { out.append("- \(aspectTitle(a)): \(n)") }
        }
        if !r.metrics.isEmpty {
            out.append("")
            out.append("## Mått (medel / median)")
            out.append("")
            out.append("| Mått | " + r.metrics.map { "`\($0.variant)`" }.joined(separator: " | ") + " |")
            out.append("|---|" + r.metrics.map { _ in "---:" }.joined(separator: "|") + "|")
            out.append("| Grupper | " + r.metrics.map { String($0.groups) }.joined(separator: " | ") + " |")
            out.append("| Dålig registrering | " + r.metrics.map { String($0.badRegistrations) }.joined(separator: " | ") + " |")
            for (i, col) in r.columns.enumerated() {
                let cells = r.metrics.map { row -> String in
                    guard let c = row.cells[i] else { return "–" }
                    return "\(format(c.mean, col)) / \(format(c.median, col))"
                }
                out.append("| \(col.title) | " + cells.joined(separator: " | ") + " |")
            }
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// `summary.json`: samma siffror som Markdown, maskinläsbart.
    static func jsonObject(_ r: Result) -> [String: Any] {
        func tally(_ t: Tally) -> [String: Int] { ["wins": t.wins, "ties": t.ties, "losses": t.losses] }
        return [
            "subject": r.subject, "totalGroups": r.totalGroups, "ratedGroups": r.ratedGroups,
            "total": tally(r.total),
            "byOpponent": r.byOpponent.mapValues(tally),
            "byCategory": Dictionary(r.byCategory.map { ($0.category, tally($0.tally)) }, uniquingKeysWith: { a, _ in a }),
            "aspectsWhenLosing": Dictionary(r.aspectsWhenLosing.map { ($0.aspect, $0.count) }, uniquingKeysWith: { a, _ in a }),
        ]
    }
}
