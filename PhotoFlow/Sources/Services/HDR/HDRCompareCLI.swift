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
                    throw ParseError(message: "--method kräver radiance, base eller fusion")
                }
                method = parsed
            case "--out": out = try value(arg)
            case "--jpeg": jpeg = try value(arg)
            case "--window-source": windowSource = try value(arg)
            case "--hdr-debug": debugDir = try value(arg)
            default: throw ParseError(message: "Okänd flagga för hdr: \(arg)")
            }
            idx += 1
        }
        guard frames.count >= 2 else { throw ParseError(message: "--frames kräver minst två ramar") }
        guard let out else { throw ParseError(message: "--out krävs") }
        return HDRArguments(frames: frames, method: method, out: out, jpeg: jpeg,
                            windowSource: windowSource, debugDir: debugDir)
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
        return ["mode": "experiment", "export_format": "TIFF", "groups": triggerGroups]
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
