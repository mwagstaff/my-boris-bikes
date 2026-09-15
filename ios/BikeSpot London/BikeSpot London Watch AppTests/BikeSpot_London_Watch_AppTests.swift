//
//  BikeSpot_London_Watch_AppTests.swift
//  BikeSpot London Watch AppTests
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import Combine
import Foundation
import Testing
import WatchConnectivity
@testable import BikeSpot_London_Watch_App

struct BikeSpot_London_Watch_AppTests {

    @Test @MainActor func journeyRefreshTimesOutAndIgnoresLateReplies() async {
        var reply: (@Sendable (Bool) -> Void)?
        let result = await WatchFavoritesService.waitForJourneyRefreshReply(timeout: .milliseconds(10)) {
            reply = $0
        }
        #expect(!result)
        reply?(true)
        reply?(false)
    }

    @Test @MainActor func journeyRefreshUsesTheFirstReply() async {
        let result = await WatchFavoritesService.waitForJourneyRefreshReply { reply in
            reply(true)
            reply(false)
        }
        #expect(result)
    }

    @Test @MainActor func cancellingJourneyRefreshDoesNotWaitForThePhoneOrTimeout() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            await WatchFavoritesService.waitForJourneyRefreshReply(timeout: .seconds(30)) { _ in
                continuation.yield(())
                continuation.finish()
            }
        }
        for await _ in started { break }
        let cancelledAt = ContinuousClock.now
        refresh.cancel()
        let result = await refresh.value
        #expect(!result)
        #expect(cancelledAt.duration(to: .now) < .seconds(5))
    }

    @Test @MainActor func openJourneyReceivesPhoneEditsWithoutAnotherCardTap() async throws {
        _ = WatchFavoritesService.shared
        let defaults = JourneyStore.defaults
        let keys = [JourneySimulation.key, "alternativeDocksMinBikes", "alternativeDocksMinEBikes",
                    "alternativeDocksMinSpaces", "alternativeDocksUseMinimumThresholds"]
        let originalValues = keys.map { ($0, defaults.object(forKey: $0)) }
        let realSnapshot = defaults.data(forKey: JourneyStore.snapshotKey)
        defer {
            for (key, value) in originalValues {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: JourneySimulation.key)
        defaults.set(5, forKey: "alternativeDocksMinBikes")
        defaults.set(3, forKey: "alternativeDocksMinEBikes")
        defaults.set(5, forKey: "alternativeDocksMinSpaces")
        defaults.set(true, forKey: "alternativeDocksUseMinimumThresholds")

        let now = Date().addingTimeInterval(-10)
        let start = JourneyDock(id: "watch-test-start", name: "Start dock", alias: "Home",
                                coordinate: JourneyCoordinate(latitude: 51.496, longitude: -0.143))
        let destination = JourneyDock(id: "watch-test-end", name: "Destination dock", alias: "Work",
                                      coordinate: JourneyCoordinate(latitude: 51.510, longitude: -0.120))
        let backup = JourneyDock(id: "watch-test-backup", name: "Backup dock", alias: "Backup",
                                 coordinate: JourneyCoordinate(latitude: 51.497, longitude: -0.142))
        let location = JourneyLocation(coordinate: start.coordinate!, accuracy: 5, date: now)
        var snapshot = JourneySnapshot.empty
        snapshot.generatedAt = now
        snapshot.bikeMetric = .bikes
        snapshot.minBikes = 5
        snapshot.minEBikes = 3
        snapshot.minSpaces = 5
        snapshot.active = JourneyRun(id: "watch-test-run", phase: .pickup, startDock: start,
                                     destinationDock: destination, startedAt: now,
                                     expiresAt: now.addingTimeInterval(1800))
        var simulation = JourneySimulation(updatedAt: now, expiresAt: now.addingTimeInterval(1800),
            snapshot: snapshot, availability: [
                start.id: JourneyAvailability(standardBikes: 6, eBikes: 4, spaces: 12, updatedAt: now),
                destination.id: JourneyAvailability(standardBikes: 5, eBikes: 2, spaces: 3, updatedAt: now),
                backup.id: JourneyAvailability(standardBikes: 12, eBikes: 4, spaces: 7, updatedAt: now)
            ], location: location, nearby: [destination, backup, start])
        let context = JourneyActivityContext(selection: snapshot.selection(location: location)!,
            availability: simulation.availability[start.id]!, updatedAt: now,
            expiresAt: simulation.expiresAt, isSimulation: true)
        let model = WatchJourneyViewModel(activityContext: context)
        #expect(model.state.availability?.standardBikes == 6)
        #expect(!model.state.hasLowActiveDockAvailability)

        var receivedUpdates = 0
        // This is the same notification/reload hook used by the visible Journey screen.
        let observer = NotificationCenter.default.publisher(for: Notification.Name("journeySnapshotChanged"))
            .sink { _ in
                receivedUpdates += 1
                model.reloadCached()
            }
        defer { observer.cancel() }

        let originalData = try JSONEncoder().encode(simulation)
        simulation.updatedAt = now.addingTimeInterval(1)
        simulation.availability[start.id]?.standardBikes = 3
        try await deliver(simulation)
        #expect(receivedUpdates >= 1)
        #expect(model.activityContext == context)
        #expect(model.state.availability?.standardBikes == 3)
        #expect(model.state.hasLowActiveDockAvailability)
        let receivedSimulation = try #require(JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key))
        #expect(receivedSimulation.alternativeDocks(from: start, metric: .bikes).map(\.id) == [backup.id, destination.id])
        #expect(receivedSimulation.alternativeDocks(from: start, metric: .bikes,
                                                   customDockIDs: [destination.id, backup.id]).map(\.id) == [destination.id, backup.id])

        await deliver(originalData)
        #expect(model.state.availability?.standardBikes == 3)

        simulation.updatedAt = now.addingTimeInterval(2)
        simulation.snapshot.bikeMetric = .eBikes
        simulation.availability[start.id]?.eBikes = 1
        try await deliver(simulation)
        #expect(model.state.selection?.metric == .eBikes)
        #expect(model.state.availability?.eBikes == 1)
        #expect(model.state.hasLowActiveDockAvailability)

        simulation.updatedAt = now.addingTimeInterval(3)
        simulation.snapshot.active?.phase = .riding
        try await deliver(simulation)
        #expect(model.state.selection?.dock.id == destination.id)
        #expect(model.state.selection?.metric == .spaces)
        #expect(model.state.availability?.spaces == 3)
        #expect(model.state.hasLowActiveDockAvailability)

        simulation.updatedAt = now.addingTimeInterval(4)
        simulation.availability[destination.id]?.spaces = 8
        try await deliver(simulation)
        #expect(model.state.availability?.spaces == 8)
        #expect(!model.state.hasLowActiveDockAvailability)

        simulation.updatedAt = now.addingTimeInterval(5)
        simulation.expiresAt = .distantPast
        try await deliver(simulation)
        #expect(model.state.selection == nil)
        await deliver(originalData)
        #expect(model.state.selection == nil)
        #expect(defaults.data(forKey: JourneyStore.snapshotKey) == realSnapshot)
    }

    @MainActor private func deliver(_ simulation: JourneySimulation) async throws {
        await deliver(try JSONEncoder().encode(simulation))
    }

    @MainActor private func deliver(_ data: Data) async {
        WatchFavoritesService.shared.session(WCSession.default,
            didReceiveMessage: [JourneySimulation.key: data], replyHandler: { _ in })
        // The delegate processes messages on the main queue. Drain that queued work
        // before assertions; no paired phone, transport request or timed sleep is needed.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
