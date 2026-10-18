import Foundation

/// Ren logik bakom `photoflow-cli hdr` och `photoflow-cli lr-trigger` (docs/plan-hdr-jamforelse.md,
/// fas 1–2): argumenttolkning, Lightroom-triggern och inläggningen av pluginets resultat i
/// `manifest.json`. Ligger i `Services` (inte i CLI-målet) så att den kan enhetstestas.
///
/// Manifestet hanteras som en vanlig JSON-ordbok så att fält som andra delar (mått, betyg,
/// jämförelsefönstret) lägger till bevaras orörda.
nonisolated enum HDRCompareCLI {

    struct ParseError: Error, Equatable, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: - hdr

    struct HDRArguments: Equatable {
        var frames: [String]
        var method: HDREngine.Method
        var out: String
        var jpeg: String?
        var windowSource: String?
        var debugDir: String?
        /// Lång sida (px) för renderingen; nil = motorns standard (6000).
        var maxDimension: Int? = nil
        /// Radianscache (`RadianceCache`): läses om den finns, skrivs annars.
        var radianceCache: String? = nil
        var sharpen = true
        /// Överstyrda parametrar för den lokala tonsättningen (`--tone nyckel=värde,…`).
        var toneOverrides: [String: Double] = [:]
        /// Överstyrda parametrar för radianssammanslagningen (`--radiance clipStart=…,clipEnd=…`).
        var radianceOverrides: [String: Double] = [:]

        /// JPEG-sökvägen: den angivna, annars TIFF-sökvägen med `.jpg`.
        var resolvedJPEG: String {
            jpeg ?? (out as NSString).deletingPathExtension + ".jpg"
        }
    }

    /// `--frames` tar alla värden fram till nästa `--flagga`.
    static func parseHDR(_ args: [String]) throws -> HDRArguments {
        var frames: [String] = []
        var method = HDREngine.Method.radiance
        var out: String?, jpeg: String?, windowSource: String?, debugDir: String?
        var maxDimension: Int?, radianceCache: String?
        var sharpen = true
        var toneOverrides: [String: Double] = [:], radianceOverrides: [String: Double] = [:]
        var idx = 0
        func value(_ flag: String) throws -> String {
            idx += 1
            guard idx < args.count, !args[idx].hasPrefix("--") else { throw ParseError(message: "\(flag) kräver ett värde") }
            return args[idx]
        }
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--frames":
                var taken = 0
                while idx + 1 < args.count, !args[idx + 1].hasPrefix("--") {
                    idx += 1
                    frames.append(args[idx])
                    taken += 1
                }
                if taken == 0 { throw ParseError(message: "--frames kräver minst en fil") }
            case "--method":
                let raw = try value(arg)
                guard let parsed = HDREngine.Method(rawValue: raw) else {
                    throw ParseError(message: "--method kräver radiance, radiance-v8, base eller fusion")
                }
                method = parsed
            case "--out": out = try value(arg)
            case "--jpeg": jpeg = try value(arg)
            case "--window-source": windowSource = try value(arg)
            case "--hdr-debug": debugDir = try value(arg)
            case "--max-dimension":
                guard let n = Int(try value(arg)), n >= 0 else { throw ParseError(message: "--max-dimension kräver ett heltal ≥ 0") }
                maxDimension = n
            case "--radiance-cache": radianceCache = try value(arg)
            case "--no-sharpen": sharpen = false
            case "--tone":
                for (key, v) in try parseToneOverrides(try value(arg)) { toneOverrides[key] = v }
            case "--radiance":
                for (key, v) in try parseRadianceOverrides(try value(arg)) { radianceOverrides[key] = v }
            default: throw ParseError(message: "Okänd flagga för hdr: \(arg)")
            }
            idx += 1
        }
        guard frames.count >= 2 else { throw ParseError(message: "--frames kräver minst två ramar") }
        guard let out else { throw ParseError(message: "--out krävs") }
        return HDRArguments(frames: frames, method: method, out: out, jpeg: jpeg,
                            windowSource: windowSource, debugDir: debugDir, maxDimension: maxDimension,
                            radianceCache: radianceCache, sharpen: sharpen, toneOverrides: toneOverrides,
                            radianceOverrides: radianceOverrides)
    }

    /// `nyckel=värde,nyckel=värde` → ordbok; nycklarna måste finnas i `SceneLinearLocalTone.Options`.
    static func parseToneOverrides(_ text: String) throws -> [String: Double] {
        var out: [String: Double] = [:]
        for part in text.split(separator: ",") where !part.isEmpty {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { throw ParseError(message: "--tone: ogiltigt par \(part)") }
            var probe = SceneLinearLocalTone.Options()
            guard probe.set(kv[0], v) else { throw ParseError(message: "--tone: okänd parameter \(kv[0])") }
            out[kv[0]] = v
        }
        return out
    }

    static func parseRadianceOverrides(_ text: String) throws -> [String: Double] {
        var out: [String: Double] = [:]
        for part in text.split(separator: ",") where !part.isEmpty {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { throw ParseError(message: "--radiance: ogiltigt par \(part)") }
            var probe = RadianceMerge.Options()
            guard probe.set(kv[0], v) else { throw ParseError(message: "--radiance: okänd parameter \(kv[0])") }
            out[kv[0]] = v
        }
        return out
    }

    // MARK: - hdr-compare

    struct CompareArguments: Equatable {
        var manifest: String
        /// Varianter i tabellen (och de som räknas om); tom = alla.
        var variants: [String]
        var against: String
        var force: Bool
        /// Tabell per grupp (utöver medianerna).
        var perGroup: Bool
    }

    static func parseCompare(_ args: [String]) throws -> CompareArguments {
        var manifest: String?, against = "lr-auto"
        var variants: [String] = []
        var force = false, perGroup = false
        var idx = 0
        func value(_ flag: String) throws -> String {
            idx += 1
            guard idx < args.count, !args[idx].hasPrefix("--") else { throw ParseError(message: "\(flag) kräver ett värde") }
            return args[idx]
        }
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--manifest": manifest = try value(arg)
            case "--variants": variants = try value(arg).split(separator: ",").map(String.init).filter { !$0.isEmpty }
            case "--against": against = try value(arg)
            case "--force": force = true
            case "--per-group": perGroup = true
            default: throw ParseError(message: "Okänd flagga för hdr-compare: \(arg)")
            }
            idx += 1
        }
        guard let manifest else { throw ParseError(message: "--manifest krävs") }
        return CompareArguments(manifest: manifest, variants: variants, against: against, force: force, perGroup: perGroup)
    }

    /// Kolumnerna i poängtabellen mot `lr-auto` (måtten i `HDRCompareMetrics`).
    static let scoreColumns: [HDRCompareSummary.Column] = [
        .init(id: "dEvsLR", title: "ΔE", decimals: 2),
        .init(id: "dEp95vsLR", title: "ΔE p95", decimals: 1),
        .init(id: "winClip", title: "Fönst klipp", decimals: 1, percent: true),
        .init(id: "winCorr", title: "Fönst strukt", decimals: 2),
        .init(id: "clipHi", title: "Klipp hö", decimals: 1, percent: true),
        .init(id: "clipLo", title: "Klipp sk", decimals: 1, percent: true),
        .init(id: "median", title: "Median", decimals: 3),
        .init(id: "p5", title: "p5", decimals: 3),
        .init(id: "p95", title: "p95", decimals: 3),
        .init(id: "contrast", title: "Lok kontr", decimals: 3),
        .init(id: "castA", title: "a*", decimals: 2),
        .init(id: "castB", title: "b*", decimals: 2),
    ]

    /// Poängtabellen (medianer över grupperna) som fast bredd-text.
    static func scoreTable(_ rows: [HDRCompareSummary.MetricRow], columns: [HDRCompareSummary.Column] = scoreColumns) -> String {
        let nameWidth = max(10, (rows.map(\.variant.count).max() ?? 0) + 1)
        func pad(_ s: String, _ w: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, w - s.count))
            return left ? s + fill : fill + s
        }
        var lines = [pad("variant", nameWidth, left: true) + pad("n", 4) + columns.map { pad($0.title, max(9, $0.title.count + 1)) }.joined()]
        for row in rows {
            var line = pad(row.variant, nameWidth, left: true) + pad("\(row.groups)", 4)
            for (col, cell) in zip(columns, row.cells) {
                let text = cell.map { HDRCompareSummary.format($0.median, col).replacingOccurrences(of: " %", with: "%") } ?? "–"
                line += pad(text, max(9, col.title.count + 1))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - lr-trigger

    struct LRTriggerArguments: Equatable {
        var manifest: String
        var wait: Bool
        /// Bara läsa `lr_status.json` och föra in resultatet (ingen ny trigger).
        var collect: Bool
        /// Överstyr Lightroom-bryggans mapp (test). Annars `PHOTOFLOW_LR_BRIDGE_DIR`, annars standardmappen.
        var bridgeDir: String?
        var timeoutSeconds: Double?
    }

    static func parseLRTrigger(_ args: [String]) throws -> LRTriggerArguments {
        var manifest: String?, bridge: String?, timeout: Double?
        var wait = false, collect = false
        var idx = 0
        func value(_ flag: String) throws -> String {
            idx += 1
            guard idx < args.count, !args[idx].hasPrefix("--") else { throw ParseError(message: "\(flag) kräver ett värde") }
            return args[idx]
        }
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--manifest": manifest = try value(arg)
            case "--wait": wait = true
            case "--collect": collect = true
            case "--bridge-dir": bridge = try value(arg)
            case "--timeout":
                guard let seconds = Double(try value(arg)), seconds > 0 else {
                    throw ParseError(message: "--timeout kräver ett antal sekunder > 0")
                }
                timeout = seconds
            default: throw ParseError(message: "Okänd flagga för lr-trigger: \(arg)")
            }
            idx += 1
        }
        guard let manifest else { throw ParseError(message: "--manifest krävs") }
        return LRTriggerArguments(manifest: manifest, wait: wait, collect: collect, bridgeDir: bridge, timeoutSeconds: timeout)
    }

    // MARK: - Lightroom-bryggan

    static let bridgeEnvironmentKey = "PHOTOFLOW_LR_BRIDGE_DIR"

    /// Samma mapp som `PipelineRunner+Lightroom` och pluginet (`~/Library/Application Support/PhotoFlow`),
    /// om den inte överstyrs med `--bridge-dir` eller `PHOTOFLOW_LR_BRIDGE_DIR`.
    static func bridgeDirectory(override: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override) }
        if let env = environment[bridgeEnvironmentKey], !env.isEmpty { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhotoFlow")
    }

    /// Absolut sökväg för ett manifestfält (relativt manifestets mapp om den inte redan är absolut).
    static func absolutePath(_ path: String, root: URL) -> String {
        path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
    }

    /// Relativ sökväg mot manifestets mapp när filen ligger under den, annars oförändrad.
    static func relativePath(_ path: String, root: URL) -> String {
        // Symlänkar (/tmp ↔ /private/tmp) löses upp på båda sidor så att jämförelsen stämmer.
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        for candidate in [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] {
            for prefix in [root.standardizedFileURL.path + "/", resolvedRoot] where candidate.hasPrefix(prefix) {
                return String(candidate.dropFirst(prefix.count))
            }
        }
        return path
    }

    /// Triggern i experimentläge: NEF-kopiorna i testkatalogen och en exportmapp (`out/<id>/`) per grupp.
    static func triggerPayload(manifest: [String: Any], root: URL) throws -> [String: Any] {
        guard let groups = manifest["groups"] as? [[String: Any]], !groups.isEmpty else {
            throw ParseError(message: "Manifestet saknar grupper")
        }
        var triggerGroups: [[String: Any]] = []
        for (index, group) in groups.enumerated() {
            guard let id = group["id"] as? String else { throw ParseError(message: "Grupp \(index + 1) saknar id") }
            let frames = (group["frames"] as? [[String: Any]])?.compactMap { $0["file"] as? String } ?? []
            guard frames.count >= 2 else { throw ParseError(message: "Grupp \(id) har färre än två ramar") }
            let exportDir = root.appendingPathComponent("out").appendingPathComponent(id).path
            triggerGroups.append([
                "group_id": index + 1,
                "id": id,
                "files": frames.map { absolutePath($0, root: root) },
                "output_dir": exportDir,
                "export_dir": exportDir,
            ])
        }
        // headless = false: Ctrl+Skift+H gav ingen sammanslagning i Lightroom Classic (provkört
        // 2026-10-18, 90 s väntan per grupp i onödan). Dialogen (Ctrl+H + Retur) fungerar och
        // använder de inställningar som senast valdes i den.
        return ["mode": "experiment", "export_format": "TIFF", "headless": false, "groups": triggerGroups]
    }

    /// För in pluginets `lr_status.json` i manifestet: varianterna `lr-auto` (Lightrooms egen export)
    /// och `lr-dng`, samt `lr` per grupp med utfall, framkallningsinställningar och DNG-sökväg.
    /// Returnerar antal grupper som fick ett lyckat resultat.
    @discardableResult
    static func merge(status: [String: Any], into manifest: inout [String: Any], root: URL) -> Int {
        guard let results = status["results"] as? [[String: Any]],
              var groups = manifest["groups"] as? [[String: Any]] else { return 0 }
        var okCount = 0
        for result in results {
            let id = result["id"] as? String
            let groupID = (result["group_id"] as? NSNumber)?.intValue
            guard let index = groups.firstIndex(where: { group in
                if let id { return group["id"] as? String == id }
                return false
            }) ?? groupID.flatMap({ $0 >= 1 && $0 <= groups.count ? $0 - 1 : nil }) else { continue }

            var group = groups[index]
            var variants = group["variants"] as? [String: Any] ?? [:]
            var lr: [String: Any] = [:]
            for key in ["status", "message", "develop", "seconds", "mergeMethod"] {
                if let value = result[key] { lr[key] = value }
            }
            if (result["status"] as? String) == "ok" {
                okCount += 1
                if let export = result["export"] as? String { variants["lr-auto"] = relativePath(export, root: root) }
                if let dng = result["dng"] as? String { variants["lr-dng"] = relativePath(dng, root: root) }
            }
            if let sourceDNG = result["sourceDng"] as? String { lr["sourceDng"] = sourceDNG }
            group["variants"] = variants
            group["lr"] = lr
            groups[index] = group
        }
        manifest["groups"] = groups
        var run: [String: Any] = [:]
        for key in ["plugin_version", "finished"] {
            if let value = status[key] { run[key] = value }
        }
        run["mergedAt"] = ISO8601DateFormatter().string(from: Date())
        manifest["lrRun"] = run
        return okCount
    }

    // MARK: - JSON-hjälp

    static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(message: "\(url.lastPathComponent) är inte ett JSON-objekt")
        }
        return object
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
