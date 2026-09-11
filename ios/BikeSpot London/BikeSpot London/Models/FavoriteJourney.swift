import CoreLocation
import Foundation

struct FavoriteJourney: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        startDock: ScheduledJourneyDock,
        endDock: ScheduledJourneyDock,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startDock = startDock
        self.endDock = endDock
        self.createdAt = createdAt
    }

    func matches(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) -> Bool {
        let matchesSavedDirection = self.startDock.id == startDock.id && self.endDock.id == endDock.id
        let matchesReverseDirection = self.startDock.id == endDock.id && self.endDock.id == startDock.id
        return matchesSavedDirection || matchesReverseDirection
    }

    func docksOrderedByDistance(
        from userLocation: CLLocation?
    ) -> (first: ScheduledJourneyDock, second: ScheduledJourneyDock) {
        guard let userLocation else { return (startDock, endDock) }

        let startDistance = userLocation.distance(from: location(for: startDock))
        let endDistance = userLocation.distance(from: location(for: endDock))
        return endDistance < startDistance ? (endDock, startDock) : (startDock, endDock)
    }

    func closestDockDistance(from userLocation: CLLocation) -> CLLocationDistance {
        min(
            userLocation.distance(from: location(for: startDock)),
            userLocation.distance(from: location(for: endDock))
        )
    }

    private func location(for dock: ScheduledJourneyDock) -> CLLocation {
        CLLocation(latitude: dock.latitude, longitude: dock.longitude)
    }
}
