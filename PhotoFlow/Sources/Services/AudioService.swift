import AppKit
import AVFoundation
import Combine

@MainActor
class AudioService: ObservableObject {
    static let shared = AudioService()

    private let synthesizer = AVSpeechSynthesizer()
    private let settings = AppSettings.shared

    // Countdown state — observed by PipelineProgressView
    @Published var countdownSeconds: Int = 0
    @Published var countdownMessage: String = ""
    @Published var isCountingDown: Bool = false

    private var countdownTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    private init() {}

    func speak(_ text: String) {
        guard settings.speechEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "sv-SE")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func playSound(_ name: String) {
        guard settings.soundEnabled else { return }
        NSSound(named: .init(name))?.play()
    }

    // MARK: - Simple sounds (no speech, no countdown)

    func playStepComplete() {
        playSound("Glass")
    }

    func playError() {
        playSound("Basso")
        speak("Ett fel har uppstått")
    }

    func playAccept() {
        playSound("Pop")
    }

    func playReject() {
        playSound("Frog")
    }

    // MARK: - Smart notification with countdown

    /// Start a countdown before speaking. If user is active (mouse/keyboard), cancel it.
    func notifyWithCountdown(sound: String, message: String, seconds: Int = 15) {
        cancelCountdown()

        playSound(sound)
        countdownMessage = message
        countdownSeconds = seconds
        isCountingDown = true

        // Monitor for user activity
        startActivityMonitors()

        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.countdownSeconds = remaining
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.countdownSeconds = 0
                self?.isCountingDown = false
                self?.stopActivityMonitors()
                self?.speak(message)
            }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownSeconds = 0
        countdownMessage = ""
        stopActivityMonitors()
    }

    private func startActivityMonitors() {
        stopActivityMonitors()

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.userBecameActive()
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.userBecameActive()
            }
            return event
        }
    }

    private func stopActivityMonitors() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func userBecameActive() {
        guard isCountingDown else { return }
        cancelCountdown()
    }

    // MARK: - High-level notifications

    func playNeedsAttention() {
        notifyWithCountdown(sound: "Sosumi", message: "Behöver din hjälp", seconds: 15)
    }

    func playAllDone() {
        notifyWithCountdown(sound: "Hero", message: "Allt är klart!", seconds: 10)
    }
}
