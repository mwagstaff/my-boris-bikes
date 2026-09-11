import Foundation
import Testing
@testable import BikeSpot_London

struct AlternativeDockLiveActivityTests {
    @Test func legacyAlternativeSnapshotStillDecodes() throws {
        let data = Data(#"{"name":"Old Street","standardBikes":2,"eBikes":1,"emptySpaces":4}"#.utf8)
        let alternative = try JSONDecoder().decode(DockActivityAttributes.AlternativeDock.self, from: data)

        #expect(alternative.id == nil)
        #expect(alternative.alias == nil)
        #expect(alternative.displayName == "Old Street")
        #expect(alternative.stableIdentifier == "Old Street")
    }

    @Test func aliasRoundTripKeepsOfficialNameAndDockIdentity() throws {
        let original = DockActivityAttributes.AlternativeDock(
            name: "Old Street, St Luke's",
            standardBikes: 2,
            eBikes: 1,
            emptySpaces: 4,
            id: "BikePoints_001",
            alias: "Office"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DockActivityAttributes.AlternativeDock.self, from: data)

        #expect(decoded == original)
        #expect(decoded.displayName == "Office")
        #expect(decoded.name == "Old Street, St Luke's")
        #expect(decoded.stableIdentifier == "BikePoints_001")
        #expect(decoded.serverPayload["id"] as? String == "BikePoints_001")
        #expect(decoded.serverPayload["alias"] as? String == "Office")
        #expect(decoded.serverPayload["name"] as? String == "Old Street, St Luke's")
    }

    @Test func duplicateAliasesKeepDistinctDockIdentities() {
        let first = DockActivityAttributes.AlternativeDock(
            name: "First Dock", standardBikes: 1, eBikes: 0, emptySpaces: 3, id: "1", alias: "Office"
        )
        let second = DockActivityAttributes.AlternativeDock(
            name: "Second Dock", standardBikes: 1, eBikes: 0, emptySpaces: 3, id: "2", alias: "Office"
        )

        #expect(first.displayName == second.displayName)
        #expect(first.stableIdentifier != second.stableIdentifier)
    }

    @Test func blankAliasUsesOfficialName() throws {
        let data = Data(#"{"id":"1","name":"Old Street","alias":"  ","standardBikes":2,"eBikes":1,"emptySpaces":4}"#.utf8)
        let alternative = try JSONDecoder().decode(DockActivityAttributes.AlternativeDock.self, from: data)

        #expect(alternative.displayName == "Old Street")
        #expect(alternative.stableIdentifier == "1")
    }

    @Test func longAlternativeNamesAndAliasesFitDisplayBudget() throws {
        let alternative = DockActivityAttributes.AlternativeDock(
            name: String(repeating: "Dock ", count: 300),
            standardBikes: 2,
            eBikes: 1,
            emptySpaces: 4,
            id: "BikePoints_001",
            alias: String(repeating: "🚲", count: 300)
        )

        #expect(alternative.name.utf8.count == 120)
        #expect(alternative.alias == String(repeating: "🚲", count: 30))
        #expect((alternative.serverPayload["alias"] as? String)?.utf8.count == 120)
        let state = DockActivityAttributes.ContentState(
            standardBikes: 2,
            eBikes: 1,
            emptySpaces: 4,
            alternatives: Array(repeating: alternative, count: 5),
            activeDockAlias: String(repeating: "🚲", count: 300)
        )
        #expect(state.activeDockAlias?.utf8.count == 120)
        #expect(try JSONEncoder().encode(state).count < 4096)
        let attributes = DockActivityAttributes(
            dockId: "BikePoints_001", dockName: "Primary Dock", alias: String(repeating: "🚲", count: 300)
        )
        #expect(attributes.alias?.utf8.count == 120)
    }

    @Test func decodingLongNamesNeverSplitsUnicodeScalars() throws {
        let name = String(repeating: "a", count: 119) + "🚲"
        let data = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "alias": String(repeating: "京", count: 80),
            "standardBikes": 2,
            "eBikes": 1,
            "emptySpaces": 4,
        ])
        let alternative = try JSONDecoder().decode(DockActivityAttributes.AlternativeDock.self, from: data)

        #expect(alternative.name == String(repeating: "a", count: 119))
        #expect(alternative.alias == String(repeating: "京", count: 40))
        let stateData = try JSONSerialization.data(withJSONObject: [
            "standardBikes": 2, "eBikes": 1, "emptySpaces": 4, "activeDockAlias": name,
        ])
        let state = try JSONDecoder().decode(DockActivityAttributes.ContentState.self, from: stateData)
        #expect(state.activeDockAlias == String(repeating: "a", count: 119))
    }
}
