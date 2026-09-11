import Foundation
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

    private func decode(_ json: String) throws -> WatchDockPreferencesSnapshot {
        try JSONDecoder().decode(WatchDockPreferencesSnapshot.self, from: Data(json.utf8))
    }
}
