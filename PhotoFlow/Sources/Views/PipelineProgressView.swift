import SwiftUI

struct PipelineProgressView: View {
    @EnvironmentObject var pipeline: PipelineState
    @EnvironmentObject var runner: RunnerWrapper
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Big step indicator
            VStack(spacing: 16) {
                ZStack {
                    Image(systemName: pipeline.currentStep.systemImage)
                        .font(.system(size: 72))
                        .foregroundColor(pipeline.isPaused ? .orange : .accentColor)
                        .symbolEffect(.pulse, isActive: pipeline.isRunning && !pipeline.isPaused)

                    if pipeline.isPaused {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 30, height: 30))
                            .offset(x: 36, y: 28)
                    }
                }

                Text(pipeline.isPaused ? "Pausad" : pipeline.currentStep.title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(pipeline.isPaused ? .orange : .primary)

                Text(pipeline.statusMessage)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                AddressBanner()
            }

            // Detailed merge visualization
            if settings.detailedProgress && pipeline.currentStep == .mergingHDR && !pipeline.currentMergeInputURLs.isEmpty {
                mergeVisualization
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeInOut(duration: 0.3), value: pipeline.currentMergeGroupId)
            }

            // Progress
            VStack(spacing: 12) {
                if pipeline.totalFiles > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(pipeline.currentFileIndex)")
                            .font(.system(size: 72, weight: .bold, design: .monospaced))
                            .foregroundColor(pipeline.isPaused ? .orange : .accentColor)
                        Text("av \(pipeline.totalFiles)")
                            .font(.system(size: 32, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: pipeline.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 500)
                    .scaleEffect(y: 3)
                    .tint(pipeline.isPaused ? .orange : .accentColor)

                Text(pipeline.progressPercent)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Pause / Cancel buttons
            if pipeline.isRunning {
                HStack(spacing: 16) {
                    Button(action: { runner.togglePause() }) {
                        HStack(spacing: 8) {
                            Image(systemName: pipeline.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 18))
                            Text(pipeline.isPaused ? "Fortsätt" : "Pausa")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(pipeline.isPaused ? Color.green : Color.orange)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { runner.cancel() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16))
                            Text("Avbryt")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Error message
            if let error = pipeline.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .overlay(alignment: .bottom) {
            CountdownOverlay()
                .padding(.bottom, 30)
        }
    }

    // MARK: - Merge visualization

    private var mergeVisualization: some View {
        VStack(spacing: 16) {
            if let groupId = pipeline.currentMergeGroupId {
                Text("Grupp \(groupId)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 0) {
                // Input images
                HStack(spacing: 8) {
                    ForEach(Array(pipeline.currentMergeInputURLs.enumerated()), id: \.offset) { _, url in
                        MergeThumbnail(url: url, label: nil)
                    }
                }

                // Arrow
                VStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text("Mertens")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)

                // Output image
                if let outputURL = pipeline.currentMergeOutputURL {
                    MergeThumbnail(url: outputURL, label: "HDR", accentColor: .orange)
                } else {
                    // Placeholder while processing
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.1))
                                .frame(width: 140, height: 100)
                            ProgressView()
                        }
                        Text("Bearbetar...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Merge Thumbnail

struct MergeThumbnail: View {
    let url: URL
    var label: String? = nil
    var accentColor: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            LocalThumbnailView(url: url)
                .frame(width: 140, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(label != nil ? accentColor : Color.clear, lineWidth: 2)
                )

            if let label {
                Text(label)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundColor(accentColor)
            } else {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
