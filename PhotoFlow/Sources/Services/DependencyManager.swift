import Foundation
import AppKit

/// Manages checking and installing external tool dependencies.
@MainActor
class DependencyManager: ObservableObject {
    static let shared = DependencyManager()

    @Published var checks: [DependencyCheck] = []
    @Published var isChecking = false
    @Published var isInstalling: String? = nil  // name of tool being installed

    var allCriticalOK: Bool {
        let critical = checks.filter { $0.importance == .required }
        return !critical.isEmpty && critical.allSatisfy { $0.status == .ok }
    }

    var hasMissing: Bool {
        checks.contains { $0.status == .missing && $0.importance == .required }
    }

    // MARK: - Tool Definitions

    struct ToolDef {
        let name: String
        let description: String
        let importance: DependencyImportance
        let checkPaths: [String]
        let versionArgs: [String]?
        let installMethod: InstallMethod?
    }

    enum InstallMethod {
        case brew(formula: String)
        case download(url: String)
        case appStore
        case builtin
    }

    private let tools: [ToolDef] = [
        ToolDef(
            name: "Homebrew",
            description: "Pakethanterare (behövs för exiftool)",
            importance: .required,
            checkPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            versionArgs: ["--version"],
            installMethod: .download(url: "https://brew.sh")
        ),
        ToolDef(
            name: "exiftool",
            description: "EXIF-data och preview-extraktion",
            importance: .required,
            checkPaths: ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"],
            versionArgs: ["-ver"],
            installMethod: .brew(formula: "exiftool")
        ),
        ToolDef(
            name: "Adobe DNG Converter",
            description: "Konvertering NEF till DNG",
            importance: .required,
            checkPaths: ["/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"],
            versionArgs: nil,
            installMethod: .download(url: "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html")
        ),
        ToolDef(
            name: "python3",
            description: "Bracket-analys och gruppering",
            importance: .required,
            checkPaths: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"],
            versionArgs: ["--version"],
            installMethod: .brew(formula: "python3")
        ),
        ToolDef(
            name: "Adobe Lightroom Classic",
            description: "HDR-sammanslagning (alternativ)",
            importance: .optional,
            checkPaths: ["/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app"],
            versionArgs: nil,
            installMethod: .download(url: "https://www.adobe.com/products/photoshop-lightroom-classic.html")
        ),
        ToolDef(
            name: "sips",
            description: "Bildkonvertering (inbyggd i macOS)",
            importance: .optional,
            checkPaths: ["/usr/bin/sips"],
            versionArgs: nil,
            installMethod: .builtin
        ),
    ]

    // MARK: - Check

    func runChecks() {
        isChecking = true

        Task.detached { [tools] in
            var mutableResults: [DependencyCheck] = []

            for tool in tools {
                let result = Self.checkTool(tool)
                mutableResults.append(result)
            }

            let results = mutableResults

            await MainActor.run {
                self.checks = results
                self.isChecking = false
            }
        }
    }

    nonisolated private static func checkTool(_ tool: ToolDef) -> DependencyCheck {
        // For .app bundles, check existence only
        if let path = tool.checkPaths.first, path.contains(".app") {
            let exists = FileManager.default.fileExists(atPath: path)

            let appPath = tool.checkPaths.first!
                .components(separatedBy: ".app/").first.map { $0 + ".app" } ?? tool.checkPaths.first!
            let version = getAppVersion(appPath)

            return DependencyCheck(
                name: tool.name,
                description: tool.description,
                status: exists ? .ok : .missing,
                detail: exists ? path : installHint(tool),
                version: version,
                importance: tool.importance,
                installMethod: tool.installMethod
            )
        }

        // CLI tools
        guard let path = tool.checkPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return DependencyCheck(
                name: tool.name,
                description: tool.description,
                status: .missing,
                detail: installHint(tool),
                version: nil,
                importance: tool.importance,
                installMethod: tool.installMethod
            )
        }

        var version: String? = nil
        if let versionArgs = tool.versionArgs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = versionArgs
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let v = version, v.count > 80 { version = String(v.prefix(80)) }
            } catch {}
        }

        return DependencyCheck(
            name: tool.name,
            description: tool.description,
            status: .ok,
            detail: path,
            version: version,
            importance: tool.importance,
            installMethod: tool.installMethod
        )
    }

    nonisolated private static func installHint(_ tool: ToolDef) -> String {
        switch tool.installMethod {
        case .brew(let formula):
            return "Installera med: brew install \(formula)"
        case .download(let url):
            return "Ladda ner från: \(url)"
        case .appStore:
            return "Installera från App Store"
        case .builtin:
            return "Inbyggd i macOS — bör finnas"
        case nil:
            return "Manuell installation krävs"
        }
    }

    nonisolated private static func getAppVersion(_ appPath: String) -> String? {
        let plist = appPath + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    // MARK: - Install

    func install(_ check: DependencyCheck) {
        guard let method = check.installMethod else { return }
        isInstalling = check.name

        switch method {
        case .brew(let formula):
            installViaBrew(formula: formula, toolName: check.name)
        case .download(let url):
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
            isInstalling = nil
        case .appStore, .builtin:
            isInstalling = nil
        }
    }

    /// Install Homebrew itself
    func installHomebrew() {
        isInstalling = "Homebrew"

        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""]

            // Run in Terminal so user can see progress and enter password
            let script = """
            tell application "Terminal"
                activate
                do script "/bin/bash -c \\\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\""
            end tell
            """
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", script]
            try? osa.run()
            osa.waitUntilExit()

            await MainActor.run {
                self.isInstalling = nil
            }
        }
    }

    private func installViaBrew(formula: String, toolName: String) {
        Task.detached {
            // Find brew
            let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first { FileManager.default.fileExists(atPath: $0) }

            guard let brewPath else {
                await MainActor.run {
                    self.isInstalling = nil
                }
                return
            }

            // Run in Terminal so user can see progress
            let script = """
            tell application "Terminal"
                activate
                do script "\(brewPath) install \(formula) && echo '\\n\\n*** \(toolName) installerat! Du kan stänga detta fönster. ***'"
            end tell
            """
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", script]
            try? osa.run()
            osa.waitUntilExit()

            await MainActor.run {
                self.isInstalling = nil
            }
        }
    }
}

