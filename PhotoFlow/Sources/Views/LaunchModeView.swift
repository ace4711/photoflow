import SwiftUI

struct LaunchModeView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject var settings = AppSettings.shared

    @State private var nefCount: Int = 0
    @State private var hasProcessedOutput: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer()

                // Logo with input → PhotoFlow → output
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        // Input folder
                        VStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.blue)
                            Text("Input")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            if let inputDir = settings.inputDirectory {
                                Text(inputDir.lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 120)

                        // Pulsing arrow left
                        Image(systemName: "chevron.right")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.accentColor.opacity(0.5))
                            .symbolEffect(.pulse, options: .repeating)
                            .padding(.horizontal, 8)

                        // Center logo
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 72))
                                .foregroundColor(.accentColor)
                            Text("PhotoFlow")
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                        }

                        // Pulsing arrow right
                        Image(systemName: "chevron.right")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.accentColor.opacity(0.5))
                            .symbolEffect(.pulse, options: .repeating)
                            .padding(.horizontal, 8)

                        // Output folder
                        VStack(spacing: 6) {
                            Image(systemName: "folder.fill.badge.gearshape")
                                .font(.system(size: 36))
                                .foregroundColor(.green)
                            Text("Output")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            if let outputDir = settings.outputDirectory {
                                Text(outputDir.lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 120)
                    }
                }

                Spacer().frame(height: 60)

                // Mode cards
                HStack(spacing: 32) {
                    ModeCard(
                        icon: "eye",
                        title: "Bevaka",
                        subtitle: "Övervakar inputmappar och SD-kort.\nStartar bearbetning automatiskt\nnär nya bilder hittas.",
                        accentColor: .blue,
                        action: startWatchMode
                    )

                    ModeCard(
                        icon: "hand.tap",
                        title: "Manuellt",
                        subtitle: "Välj en mapp med NEF-filer\noch kör pipelinen manuellt.\nBra för granskning och gallring.",
                        accentColor: .orange,
                        action: startManualMode
                    )

                    ModeCard(
                        icon: "folder.badge.questionmark",
                        title: "Granska befintlig",
                        subtitle: "Öppna en redan bearbetad mapp\nför att granska bracket-grupper\noch gallra bilder.",
                        accentColor: .green,
                        action: openExistingSession
                    )
                }
                .padding(.horizontal, 60)

                Spacer().frame(height: 40)

                // Quick action button
                if settings.inputDirectory != nil && nefCount > 0 {
                    if hasProcessedOutput {
                        Button(action: { reprocessInput() }) {
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 36))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Bearbeta om")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                    Text("\(nefCount) NEF-filer till ny output")
                                        .font(.system(size: 16))
                                        .opacity(0.85)
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.orange)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: { processInput() }) {
                            HStack(spacing: 16) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 40))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Starta bearbetning")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                    Text("\(nefCount) NEF-filer redo")
                                        .font(.system(size: 16))
                                        .opacity(0.85)
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.accentColor)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Settings button - top right
            Button(action: { showSettings = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                    Text("Inställningar")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .frame(width: 700, height: 620)
        }
        .onAppear { refreshFileCount() }
        .onChange(of: settings.inputDirectoryPath) { _, _ in refreshFileCount() }
        .onChange(of: settings.outputDirectoryPath) { _, _ in refreshFileCount() }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { refreshFileCount() }
        }
    }

    private func refreshFileCount() {
        guard let inputDir = settings.inputDirectory else {
            nefCount = 0
            hasProcessedOutput = false
            return
        }

        // Count NEF files - check directly first, then subdirectories
        let files = (try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? []
        var count = files.filter { $0.pathExtension.uppercased() == "NEF" }.count

        if count == 0 {
            // Search subdirectories
            let subdirs = files.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "processed" }
            for sub in subdirs {
                let subFiles = (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                count += subFiles.filter { $0.pathExtension.uppercased() == "NEF" }.count
            }
        }
        nefCount = count

        // Check if output already has data
        let outputDir = settings.outputDirectory ?? inputDir.appendingPathComponent("processed")
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        hasProcessedOutput = FileManager.default.fileExists(atPath: groupsJSON.path)
    }

    private func processInput() {
        guard let inputDir = settings.inputDirectory else { return }
        pipeline.appMode = .processing
        runner.start(inputDir: inputDir, outputDir: settings.outputDirectory)
    }

    private func reprocessInput() {
        guard let inputDir = settings.inputDirectory else { return }
        pipeline.appMode = .processing
        runner.start(inputDir: inputDir, outputDir: settings.outputDirectory)
    }

    private func startWatchMode() {
        pipeline.appMode = .watching
    }

    private func startManualMode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Välj mappen med NEF-filer"
        panel.prompt = "Välj"

        if let dir = settings.inputDirectory {
            panel.directoryURL = dir
        }

        if panel.runModal() == .OK, let url = panel.url {
            pipeline.appMode = .processing
            runner.start(inputDir: url, outputDir: settings.outputDirectory)
        }
    }

    private func openExistingSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Välj mappen som innehåller NEF-filerna (med 'processed'-underkatalog)"
        panel.prompt = "Öppna"

        if panel.runModal() == .OK, let url = panel.url {
            pipeline.appMode = .interactive
            runner.loadExistingSession(inputDir: url, outputDir: settings.outputDirectory)
        }
    }

}

struct DirectoryRow: View {
    let icon: String
    let label: String
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(label + ":")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let accentColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(accentColor)

                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .frame(width: 240, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering
                          ? accentColor.opacity(0.12)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? accentColor : Color.secondary.opacity(0.2), lineWidth: isHovering ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
