import CoreLocation
import Foundation
import Testing
@testable import BikeSpot_London

@MainActor
struct FavoriteJourneyTests {
    @Test func togglesAndPersistsFavoriteJourney() {
        let suiteName = "FavoriteJourneyTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let startDock = ScheduledJourneyDock(
            id: "BikePoints_1",
            name: "Start Dock",
            latitude: 51.5,
            longitude: -0.1
        )
        let endDock = ScheduledJourneyDock(
            id: "BikePoints_2",
            name: "End Dock",
            latitude: 51.6,
            longitude: -0.2
        )
        let service = FavoriteJourneyService(userDefaults: userDefaults)

        service.toggle(startDock: startDock, endDock: endDock)

        #expect(service.journeys.count == 1)
        #expect(service.isFavorite(startDock: startDock, endDock: endDock))
        #expect(service.isFavorite(startDock: endDock, endDock: startDock))

        let restoredService = FavoriteJourneyService(userDefaults: userDefaults)
        #expect(restoredService.journeys == service.journeys)

        restoredService.toggle(startDock: endDock, endDock: startDock)
        #expect(restoredService.journeys.isEmpty)
    }

    @Test func putsClosestDockFirst() {
        let westDock = ScheduledJourneyDock(
            id: "BikePoints_west",
            name: "West Dock",
            latitude: 51.5,
            longitude: -0.2
        )
        let eastDock = ScheduledJourneyDock(
            id: "BikePoints_east",
            name: "East Dock",
            latitude: 51.5,
            longitude: -0.1
        )
        let journey = FavoriteJourney(startDock: westDock, endDock: eastDock)
        let userLocation = CLLocation(latitude: 51.5, longitude: -0.11)

        let docks = journey.docksOrderedByDistance(from: userLocation)

        #expect(docks.first == eastDock)
        #expect(docks.second == westDock)
    }
}
