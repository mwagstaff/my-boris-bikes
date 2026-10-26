import Foundation

struct StartingScreenResetPolicy {
    static let defaultMinutes = 5
    private var backgroundedAt: Date?

    mutating func enteredBackground(at date: Date = Date()) {
        backgroundedAt = date
    }

    mutating func explicitNavigation() {
        backgroundedAt = nil
    }

    mutating func shouldResetOnReturn(afterMinutes minutes: Int, at date: Date = Date()) -> Bool {
        defer { backgroundedAt = nil }
        guard minutes > 0, let backgroundedAt else { return false }
        return date.timeIntervalSince(backgroundedAt) >= Double(minutes) * 60
    }
}
