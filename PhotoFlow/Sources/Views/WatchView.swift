import SwiftUI

struct WatchView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @StateObject private var watcher = WatchService()
    @ObservedObject var settings = AppSettings.shared
    @State private var showSettings = false

    var body: some View {
        HSplitView {
            // Left: status panel
            VStack(spacing: 24) {
                Spacer()

                // Animated watch icon
                ZStack {
                    Circle()
                        .fill(watcher.isWatching ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                        .frame(width: 120, height: 120)

                    Circle()
                        .stroke(watcher.isWatching ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 2)
                        .frame(width: 140, height: 140)
                        .scaleEffect(watcher.isWatching ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: watcher.isWatching)

                    Image(systemName: "eye")
                        .font(.system(size: 48))
                        .foregroundColor(watcher.isWatching ? .blue : .gray)
                        .symbolEffect(.pulse, isActive: watcher.isWatching)
                }

                Text("Bevakningslage")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                // Monitored paths
                VStack(spacing: 8) {
                    if let inputDir = settings.inputDirectory {
                        MonitoredPathRow(
                            icon: "folder",
                            label: "Inputmapp",
                            path: inputDir.path,
                            isActive: watcher.isWatching
                        )
                    } else {
                        MonitoredPathRow(
                            icon: "folder.badge.questionmark",
                            label: "Inputmapp",
                            path: "Ej konfigurerad - öppna inställningar",
                            isActive: false
                        )
                    }

                    if let outputDir = settings.outputDirectory {
                        MonitoredPathRow(
                            icon: "folder.badge.gear",
                            label: "Outputmapp",
                            path: outputDir.path,
                            isActive: watcher.isWatching
                        )
                    }

                    if !watcher.detectedVolumes.isEmpty {
                        ForEach(watcher.detectedVolumes, id: \.path) { volume in
                            MonitoredPathRow(
                                icon: "sdcard",
                                label: volume.lastPathComponent,
                                path: volume.path,
                                isActive: true
                            )
                        }
                    } else {
                        MonitoredPathRow(
                            icon: "sdcard",
                            label: "Minneskort",
                            path: "Inget anslutet",
                            isActive: false
                        )
                    }
                }
                .padding(.horizontal, 20)

                // New files indicator
                if watcher.newFilesFound > 0 {
                    HStack {
                        Image(systemName: "photo.stack.fill")
                            .foregroundColor(.orange)
                        Text("\(watcher.newFilesFound) nya filer hittade")
                            .fontWeight(.semibold)
                    }
                    .font(.title3)
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                }

                Spacer()

                // Controls
                HStack(spacing: 16) {
                    Button(action: goBack) {
                        Label("Tillbaka", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { showSettings = true }) {
                        Label("Installningar", systemImage: "gearshape.fill")
                    }
                    .buttonStyle(.bordered)

                    if watcher.isWatching {
                        Button(action: { watcher.stopWatching() }) {
                            Label("Stoppa", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(action: { startWatching() }) {
                            Label("Starta", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .padding(.bottom, 24)
            }
            .frame(minWidth: 400, idealWidth: 500)

            // Right: live log
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "text.justify.left")
                    Text("Bevakningslogg")
                        .font(.headline)
                    Spacer()
                    if let lastCheck = watcher.lastCheckTime {
                        Text("Senast: \(lastCheck, formatter: timeFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(watcher.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: line))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: watcher.logLines.count) { _, _ in
                        let lastIndex = watcher.logLines.count - 1
                        if lastIndex >= 0 {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 400, idealWidth: 500)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .frame(width: 640, height: 520)
        }
        .onAppear {
            startWatching()
        }
        .onDisappear {
            watcher.stopWatching()
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("HITTADE") { return .orange }
        if line.contains("VARNING") { return .yellow }
        if line.contains("Startar") { return .green }
        if line.contains("Kunde inte") { return .red }
        return .primary
    }

    private func startWatching() {
        watcher.onNewFilesDetected = { [weak runner] sourceDir, files in
            guard settings.autoStartPipeline else { return }
            Task { @MainActor in
                pipeline.appMode = .processing
                let outputDir = settings.outputDirectory ?? sourceDir.appendingPathComponent("processed")
                runner?.start(inputDir: sourceDir, outputDir: outputDir)
            }
        }
        watcher.startWatching()
    }

    private func goBack() {
        watcher.stopWatching()
        pipeline.appMode = .launcher
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}

struct MonitoredPathRow: View {
    let icon: String
    let label: String
    let path: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isActive ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
