import Foundation
import CoreLocation
import Testing
@testable import BikeSpot_London_Watch_App

struct WatchDockPreferencesTests {
    @Test func missingListUsesAutomaticButEmptyListStaysCustom() throws {
        let snapshot = try decode(#"{"revision":0,"alternatives":{"start":[]},"aliases":{}}"#)
        #expect(snapshot.customDockIDs(for: "other") == nil)
        #expect(snapshot.customDockIDs(for: "start") == [])
    }

    @Test func savedOrderSurvivesRemovingPrimaryAndDuplicates() throws {
        let snapshot = try decode(#"{"revision":17,"alternatives":{"start":["far","start","near","far",""]},"aliases":{}}"#)
        #expect(snapshot.customDockIDs(for: "start") == ["far", "near"])
    }

    @Test func journeyOnlyPreferencesAndAliasesDecodeWithoutFavorites() throws {
        let snapshot = try decode(#"{"revision":1788940800000,"alternatives":{"journeyEnd":["alternate"]},"aliases":{"alternate":"Office backup"},"docks":{"alternate":{"id":"alternate"}},"settings":{"enabled":true,"minSpaces":3,"maxCount":2,"useMinimumThresholds":false}}"#)
        #expect(snapshot.revision == 1788940800000)
        #expect(snapshot.customDockIDs(for: "journeyEnd") == ["alternate"])
        #expect(snapshot.aliases["alternate"] == "Office backup")
        #expect(snapshot.settings?.maxCount == 2)
    }

    @Test func favoriteJourneyUsesNearestEndpointAsItsStart() {
        let journey = WatchFavoriteJourney(
            id: "commute",
            startDock: WatchFavoriteJourneyDock(
                id: "far",
                commonName: "Far Dock",
                alias: "Office",
                lat: 51.530,
                lon: -0.120
            ),
            endDock: WatchFavoriteJourneyDock(
                id: "near",
                commonName: "Near Dock",
                alias: "Home",
                lat: 51.500,
                lon: -0.120
            )
        )
        let location = CLLocation(latitude: 51.501, longitude: -0.120)

        let ordered = journey.docksOrderedByDistance(from: location)

        #expect(ordered.start.id == "near")
        #expect(ordered.destination.id == "far")
        #expect(ordered.start.displayName == "Home")
    }

    @Test func favoriteJourneyWirePayloadPreservesAliases() throws {
        let data = Data(#"[{"id":"commute","startDock":{"id":"a","commonName":"Alpha Dock","alias":"Home","lat":51.5,"lon":-0.1},"endDock":{"id":"b","commonName":"Beta Dock","alias":"Work","lat":51.51,"lon":-0.11}}]"#.utf8)

        let journeys = try JSONDecoder().decode([WatchFavoriteJourney].self, from: data)

        #expect(journeys.first?.startDock.displayName == "Home")
        #expect(journeys.first?.endDock.displayName == "Work")
    }

    private func decode(_ json: String) throws -> WatchDockPreferencesSnapshot {
        try JSONDecoder().decode(WatchDockPreferencesSnapshot.self, from: Data(json.utf8))
    }
}
