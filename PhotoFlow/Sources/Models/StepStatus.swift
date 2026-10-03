import Foundation

enum StepPhase: Equatable {
    case idle
    case watching
    case queued
    case active
    case needsAttention
    case paused
    case complete
    case error(String)
    case disabled
}

struct StepStatus {
    var phase: StepPhase = .idle
    var newCount: Int = 0
    var queuedCount: Int = 0
    var processedCount: Int = 0
    var totalCount: Int = 0
    var lastUpdated: Date?
    var startedAt: Date?
    var lastDuration: TimeInterval?
    var logEntries: [LogLine] = []
    /// Prognos för tid kvar (`PipelineState.eta`), satt av vyn vid visning —
    /// sparas inte i tillståndet eftersom den ändras med klockan.
    var estimatedRemaining: TimeInterval?

    private var estimateSuffix: String {
        estimatedRemaining.map { " · ~\(StepTiming.format($0)) kvar" } ?? ""
    }

    /// Formatted duration string, e.g. "2m 13s" or "45s"
    var durationText: String? {
        guard let duration = lastDuration, duration > 0 else { return nil }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .watching:
            if newCount > 0 { return "\(newCount) nya filer" }
            return "Bevakar..."
        case .queued:
            if let estimate = estimatedRemaining {
                return "I kö · ~\(StepTiming.format(estimate))"
            }
            return queuedCount > 0 ? "\(queuedCount) i kö" : "I kö"
        case .active:
            if totalCount > 0 {
                if estimatedRemaining != nil {
                    return "\(processedCount)/\(totalCount)\(estimateSuffix)"
                }
                let remaining = totalCount - processedCount
                return "\(processedCount)/\(totalCount) (\(remaining) kvar)"
            }
            return "Arbetar...\(estimateSuffix)"
        case .needsAttention:
            return "Vantar pa dig"
        case .paused:
            if totalCount > 0 {
                return "Pausad \(processedCount)/\(totalCount)"
            }
            return "Pausad"
        case .complete:
            if totalCount > 0 {
                if let dt = durationText {
                    return "\(totalCount) klara · \(dt)"
                }
                return "\(totalCount) klara"
            }
            if let dt = durationText {
                return "Klar · \(dt)"
            }
            return "Klar"
        case .error(let msg):
            return msg
        case .disabled:
            return "Avaktiverad"
        }
    }

    var isError: Bool {
        if case .error = phase { return true }
        return false
    }

    static let idle = StepStatus()
}
