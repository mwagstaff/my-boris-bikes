import Foundation
import Testing
@testable import BikeSpot_London

@MainActor
struct DockPreferencesTests {
    private func withStore(_ check: (DockPreferencesService, UserDefaults) throws -> Void) throws {
        let name = "DockPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try check(DockPreferencesService(userDefaults: defaults), defaults)
    }

    private func dock(_ id: String) -> ScheduledJourneyDock {
        ScheduledJourneyDock(id: id, name: "Official \(id)", latitude: 51.5, longitude: -0.1)
    }

    @Test func customEmptyAndAutomaticRemainDistinctAfterRelaunch() throws {
        try withStore { service, defaults in
            #expect(service.customDockIDs(for: "BikePoints_1") == nil)
            service.saveAlternatives(for: dock("BikePoints_1"), docks: [])
            let restored = DockPreferencesService(userDefaults: defaults)
            #expect(restored.customDockIDs(for: "BikePoints_1") == [])
            restored.saveAlternatives(for: dock("BikePoints_1"), docks: nil)
            #expect(DockPreferencesService(userDefaults: defaults).customDockIDs(for: "BikePoints_1") == nil)
        }
    }

    @Test func preservesOrderAndExcludesDuplicatesAndPrimaryDock() throws {
        try withStore { service, defaults in
            service.saveAlternatives(for: dock("BikePoints_1"), docks: [
                dock("BikePoints_3"), dock("BikePoints_1"), dock("BikePoints_2"), dock("BikePoints_3")
            ])
            #expect(service.customDockIDs(for: "BikePoints_1") == ["BikePoints_3", "BikePoints_2"])
            service.saveAlternatives(for: dock("BikePoints_1"), docks: [dock("BikePoints_2"), dock("BikePoints_3")])
            let restored = DockPreferencesService(userDefaults: defaults)
            #expect(restored.customDocks(for: "BikePoints_1") == [dock("BikePoints_2"), dock("BikePoints_3")])
            service.saveAlternatives(for: dock("BikePoints_4"), docks: [dock("BikePoints_3")])
            #expect(service.customDockIDs(for: "BikePoints_1") == ["BikePoints_2", "BikePoints_3"])
        }
    }

    @Test func aliasIsSharedWithoutRequiringAFavourite() throws {
        try withStore { service, defaults in
            service.saveAlternatives(for: dock("BikePoints_1"), docks: [dock("BikePoints_2")], aliases: ["BikePoints_2": "  By the office  "])
            service.saveAlternatives(for: dock("BikePoints_3"), docks: [dock("BikePoints_2")])
            #expect(service.alias(for: "BikePoints_2") == "By the office")
            #expect(service.customDocks(for: "BikePoints_1")?.first?.name == "Official BikePoints_2")
            service.updateAlias(for: "BikePoints_2", alias: "  ")
            let restored = DockPreferencesService(userDefaults: defaults)
            #expect(restored.alias(for: "BikePoints_2") == nil)
            #expect(restored.customDockIDs(for: "BikePoints_3") == ["BikePoints_2"])
        }
    }

    @Test func migratesFavouriteAliasesOnceWithoutRevivingRemovedNames() throws {
        let name = "DockAliasMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let favorite = FavoriteBikePoint(bikePoint: BikePoint(id: "BikePoints_2", commonName: "Official", lat: 51.5, lon: -0.1), alias: "My office")
        defaults.set(try JSONEncoder().encode([favorite]), forKey: AppConstants.UserDefaults.favoritesKey)
        let service = DockPreferencesService(userDefaults: defaults)
        #expect(service.alias(for: favorite.id) == "My office")
        service.updateAlias(for: favorite.id, alias: nil)
        #expect(DockPreferencesService(userDefaults: defaults).alias(for: favorite.id) == nil)
    }

    @Test func staleAcknowledgementCannotMarkNewerChangesSynced() throws {
        try withStore { service, _ in
            service.updateAlias(for: "BikePoints_2", alias: "First")
            let firstRevision = service.revision
            service.updateAlias(for: "BikePoints_2", alias: "Second")
            #expect(service.revision > firstRevision)
            service.markSynced(revision: firstRevision)
            #expect(service.hasPendingSync)
            service.markSynced(revision: service.revision)
            #expect(!service.hasPendingSync)
        }
    }

    @Test func serverPayloadPreservesEmptyListsAndExcludesCachedMetadata() throws {
        try withStore { service, _ in
            service.saveAlternatives(for: dock("BikePoints_1"), docks: [], aliases: ["BikePoints_2": "Office"])
            let payload = service.serverPayload
            #expect((payload["alternatives"] as? [String: [String]])?["BikePoints_1"] == [])
            #expect((payload["aliases"] as? [String: String])?["BikePoints_2"] == "Office")
            #expect(payload["docks"] == nil)
            #expect(payload["settings"] != nil)
        }
    }

    @Test func customSelectionKeepsOrderAndAllowsOtherFavourites() throws {
        let primary = try bikePoint("BikePoints_1", longitude: -0.1)
        let nearest = try bikePoint("BikePoints_2", longitude: -0.101)
        let preferred = try bikePoint("BikePoints_3", longitude: -0.11)
        let locked = try bikePoint("BikePoints_4", longitude: -0.12, locked: true)
        let all = [primary, nearest, preferred, locked]
        let selected = AlternativeDockSelectionService.orderedCandidates(
            for: primary, allBikePoints: all, excludingFavoriteIDs: [preferred.id],
            customDockIDs: [preferred.id, locked.id, "BikePoints_99", nearest.id, primary.id, preferred.id]
        )
        #expect(selected.map(\.id) == [preferred.id, nearest.id])
        let automatic = AlternativeDockSelectionService.orderedCandidates(
            for: primary, allBikePoints: all, excludingFavoriteIDs: [preferred.id], customDockIDs: nil
        )
        #expect(automatic.map(\.id) == [nearest.id])
        let empty = AlternativeDockSelectionService.orderedCandidates(
            for: primary, allBikePoints: all, excludingFavoriteIDs: [], customDockIDs: []
        )
        #expect(empty.isEmpty)
    }

    @Test func favouritePreviewKeepsTheSecondChoiceWithZeroSpaces() throws {
        let ids = ["BikePoints_1", "BikePoints_2", "BikePoints_3", "BikePoints_4"]
        let saved = ids.map(dock)
        let first = try bikePoint(ids[0], longitude: -0.12, bikes: 18, spaces: 1)
        let second = try bikePoint(ids[1], longitude: -0.101, bikes: 7, spaces: 0)
        let third = try bikePoint(ids[2], longitude: -0.11, bikes: 13, spaces: 1)
        let fourth = try bikePoint(ids[3], longitude: -0.13, bikes: 9, spaces: 7)
        // Fresh catalogue order and distance must not change the saved positions.
        let fresh = [fourth, third, first, second]
        let preview = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: fresh, showAll: false
        )
        #expect(preview.map(\.id) == Array(ids.prefix(3)))
        #expect(preview[1].emptyDocks == 0)
        #expect(preview[1].standardBikes == 7)
        let expanded = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: fresh, showAll: true
        )
        #expect(expanded.map(\.id) == ids)
        #expect(saved.map(\.id) == ids)
    }

    @Test func favouritePreviewKeepsMissingAndUnavailableDockPositions() throws {
        let saved = [dock("BikePoints_1"), dock("BikePoints_2"), dock("BikePoints_3"), dock("BikePoints_4")]
        let first = try bikePoint(saved[0].id, longitude: -0.1, spaces: 2)
        let locked = try bikePoint(saved[2].id, longitude: -0.11, locked: true)
        let fourth = try bikePoint(saved[3].id, longitude: -0.12, spaces: 5)
        let preview = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: [first, fourth, locked], showAll: false
        )
        #expect(preview.map(\.id) == Array(saved.prefix(3).map(\.id)))
        #expect(preview[1].commonName == saved[1].name)
        #expect(preview[1].additionalProperties.isEmpty)
        #expect(preview[2].isLocked)

        let recovered = try bikePoint(saved[1].id, longitude: -0.105, bikes: 3, spaces: 4)
        let refreshed = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: [first, recovered, locked, fourth], showAll: false
        )
        #expect(refreshed.map(\.id) == preview.map(\.id))
        #expect(refreshed[1].emptyDocks == 4)
    }

    @Test func favouritePreviewCollapsesWithoutChangingSavedOrder() throws {
        let saved = (1...6).map { dock("BikePoints_\($0)") }
        let expanded = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: [], showAll: true
        )
        let collapsed = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: saved, allBikePoints: [], showAll: false
        )
        #expect(expanded.map(\.id) == saved.map(\.id))
        #expect(collapsed.map(\.id) == Array(saved.prefix(3).map(\.id)))
        let empty = AlternativeDockSelectionService.savedAlternativesForFavorites(
            for: "BikePoints_99", savedDocks: [], allBikePoints: [], showAll: true
        )
        #expect(empty.isEmpty)
    }

    private func bikePoint(_ id: String, longitude: Double, locked: Bool = false, bikes: Int = 0, spaces: Int = 0) throws -> BikePoint {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "commonName": id, "lat": 51.5, "lon": longitude,
            "additionalProperties": [
                ["key": "Installed", "value": "true"],
                ["key": "Locked", "value": locked ? "true" : "false"],
                ["key": "NbStandardBikes", "value": String(bikes)],
                ["key": "NbEBikes", "value": "0"],
                ["key": "NbEmptyDocks", "value": String(spaces)],
                ["key": "NbDocks", "value": String(bikes + spaces)]
            ]
        ])
        return try JSONDecoder().decode(BikePoint.self, from: data)
    }
}
