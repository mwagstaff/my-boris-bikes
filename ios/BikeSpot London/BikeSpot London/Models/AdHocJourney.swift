import Foundation

struct AdHocJourney: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    var createdAt: Date
    var lastStartedAt: Date?
    var activePhase: ScheduledJourney.ActiveRun.Phase?

    var isActive: Bool {
        activePhase != nil
    }

    init(
        id: String = UUID().uuidString,
        startDock: ScheduledJourneyDock,
        endDock: ScheduledJourneyDock,
        createdAt: Date = Date(),
        lastStartedAt: Date? = nil,
        activePhase: ScheduledJourney.ActiveRun.Phase? = nil
    ) {
        self.id = id
        self.startDock = startDock
        self.endDock = endDock
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
        self.activePhase = activePhase
    }
}
