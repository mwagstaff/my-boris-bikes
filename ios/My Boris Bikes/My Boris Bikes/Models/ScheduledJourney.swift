import Foundation

struct ScheduledJourneyDock: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double

    init(id: String, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(bikePoint: BikePoint) {
        self.id = bikePoint.id
        self.name = bikePoint.commonName
        self.latitude = bikePoint.lat
        self.longitude = bikePoint.lon
    }
}

struct ScheduledJourney: Codable, Identifiable, Equatable, Sendable {
    struct ActiveRun: Codable, Equatable, Sendable {
        let phase: Phase
        let dockId: String
        let dockName: String
        let startedAt: Date?
        let runKey: String?

        enum Phase: String, Codable, Sendable {
            case start
            case end
        }
    }

    let id: String
    let deviceId: String?
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    let weekdays: [Int]
    let startTime: String
    let endTime: String
    let timezone: String
    let enabled: Bool
    let activeRun: ActiveRun?
    let pausedRunKeys: [String]?
    let createdAt: Date?
    let updatedAt: Date?

    var isActive: Bool {
        activeRun != nil
    }

    var isStartPhase: Bool {
        activeRun?.phase == .start
    }
}

struct ScheduledJourneyDraft: Encodable, Equatable {
    var startDock: ScheduledJourneyDock?
    var endDock: ScheduledJourneyDock?
    var weekdays: [Int] = [1, 2, 3, 4, 5]
    var startTime: String = "07:30"
    var endTime: String = "09:30"
    var timezone: String = TimeZone.current.identifier
    var enabled: Bool = true

    static func returnJourney(from journey: ScheduledJourney) -> ScheduledJourneyDraft {
        ScheduledJourneyDraft(
            startDock: journey.endDock,
            endDock: journey.startDock,
            weekdays: journey.weekdays,
            startTime: "16:30",
            endTime: "18:30",
            timezone: journey.timezone,
            enabled: true
        )
    }
}

