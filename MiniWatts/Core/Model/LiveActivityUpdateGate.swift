import Foundation

/// Coalesces sensor ticks while allowing pause/resume and setting changes through
/// immediately. This only schedules local submissions; iOS controls presentation.
nonisolated struct LiveActivityUpdateGate {
    private(set) var lastSentAt: Date?

    mutating func shouldSend(at date: Date, changed: Bool, force: Bool = false) -> Bool {
        if !force, let lastSentAt {
            let elapsed = date.timeIntervalSince(lastSentAt)
            if elapsed >= 0 && (elapsed < 1 || (!changed && elapsed < 20)) { return false }
        }
        lastSentAt = date
        return true
    }

    mutating func reset() { lastSentAt = nil }
}
