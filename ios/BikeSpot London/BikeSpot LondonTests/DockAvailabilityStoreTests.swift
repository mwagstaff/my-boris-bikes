import Combine
import Foundation
import Testing
@testable import BikeSpot_London

@MainActor
struct DockAvailabilityStoreTests {
    private let old = Date(timeIntervalSince1970: 1_000)
    private let fresh = Date(timeIntervalSince1970: 2_000)

    @Test func refreshingMapPublishesTheSamePrimaryAndAlternativeCountsToEverySubscriber() {
        let response = PassthroughSubject<[BikePoint], NetworkError>()
        let store = makeStore(directory: { response.eraseToAnyPublisher() })
        var map: [String: Int] = [:]
        var journeys: [String: Int] = [:]
        var favourites: [String: Int] = [:]
        let observers = [
            store.$snapshot.sink { map = $0.bikePointsByID.mapValues(\.totalBikes) },
            store.$snapshot.sink { journeys = $0.bikePointsByID.mapValues(\.totalBikes) },
            store.$snapshot.sink { favourites = $0.bikePointsByID.mapValues(\.totalBikes) }
        ]
        store.refresh(force: true)
        #expect(store.isRefreshing)
        response.send([point("start", bikes: 0), point("warwick", bikes: 1)])
        response.send(completion: .finished)
        #expect(map["warwick"] == 1)
        #expect(journeys == map)
        #expect(favourites == map)
        #expect(!store.isRefreshing)
        withExtendedLifetime(observers) {}
    }

    @Test func partialSuccessKeepsOldAlternativeAgeAndFailedRefreshKeepsCounts() {
        let store = makeStore(dock: { id in success(point(id, bikes: 0)) })
        store.refresh(dockIDs: ["start"], force: true)
        #expect(store.bikePointsByID["start"]?.totalBikes == 0)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 8)
        #expect(store.snapshot.checkedAtByID["start"] == fresh)
        #expect(store.snapshot.checkedAtByID["warwick"] == old)
        #expect(store.lastUpdateTime == old)
        #expect(store.isStale(at: fresh))
        #expect(store.refreshFailed)
        #expect(!store.isRefreshing)
    }

    @Test func directorySuccessUpdatesAlternativesEvenWhenTargetedRequestFails() {
        let store = makeStore(directory: { success([point("start", bikes: 0), point("warwick", bikes: 1)]) })
        store.refresh(dockIDs: ["start"], force: true)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 1)
        #expect(store.lastUpdateTime == fresh)
        #expect(!store.isStale(at: fresh))
    }

    @Test(arguments: [false, true])
    func targetedResponseWinsRegardlessOfCompletionOrder(directoryFirst: Bool) {
        let directory = PassthroughSubject<[BikePoint], NetworkError>()
        let dock = PassthroughSubject<BikePoint, NetworkError>()
        let store = makeStore(directory: { directory.eraseToAnyPublisher() }, dock: { _ in dock.eraseToAnyPublisher() })
        store.refresh(dockIDs: ["warwick"])
        if directoryFirst { directory.send([point("warwick", bikes: 8)]) }
        dock.send(point("warwick", bikes: 1))
        if !directoryFirst { directory.send([point("warwick", bikes: 8)]) }
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 1)
    }

    @Test func olderRequestsAndOlderSourceDataCannotOverwriteNewerCounts() {
        let store = makeStore()
        store.accept([point("warwick", bikes: 1, modified: fresh)], checkedAt: fresh)
        store.accept([point("warwick", bikes: 8, modified: old)], checkedAt: fresh.addingTimeInterval(2), directory: true)
        store.accept([point("warwick", bikes: 9)], checkedAt: old)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 1)
        #expect(store.snapshot.checkedAtByID["warwick"] == fresh)
    }

    @Test func liveActivityCountsReachScreensAndSurviveAnOlderDirectoryResponse() {
        let store = makeStore()
        store.acceptPushedCounts(id: "warwick", standardBikes: 1, eBikes: 0, spaces: 19, checkedAt: fresh)
        store.accept([point("warwick", bikes: 8), point("start", bikes: 7)], checkedAt: old.addingTimeInterval(30), directory: true)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 1)
        #expect(store.bikePointsByID["warwick"]?.emptyDocks == 19)
        #expect(store.lastUpdateTime == old.addingTimeInterval(30)) // Primary remains older than the pushed alternative.
    }

    @Test func pushBeforeDirectoryMetadataIsRetainedWithoutInventingCoordinates() {
        let store = DockAvailabilityStore(fetchDirectory: { failure() }, fetchDock: { _ in failure() })
        store.acceptPushedCounts(id: "warwick", standardBikes: 1, eBikes: 0, spaces: 19, checkedAt: fresh)
        #expect(store.bikePointsByID["warwick"] == nil)
        store.accept([point("warwick", bikes: 8)], checkedAt: old, directory: true)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 1)
        #expect(store.bikePointsByID["warwick"]?.lat == 51.5)
        #expect(store.lastUpdateTime == fresh)
    }

    @Test func destinationSpacesDoNotFalselyRefreshBikeCounts() {
        let store = makeStore()
        store.acceptPushedSpaces(id: "warwick", spaces: 19, checkedAt: fresh)
        #expect(store.bikePointsByID["warwick"]?.emptyDocks == 19)
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 8)
        #expect(store.snapshot.checkedAtByID["warwick"] == old)
        store.accept([point("warwick", bikes: 3)], checkedAt: old.addingTimeInterval(5))
        #expect(store.bikePointsByID["warwick"]?.emptyDocks == 19)
    }

    @Test func delayedFullPushDoesNotReplaceNewerDestinationSpaces() {
        let store = makeStore()
        store.acceptPushedSpaces(id: "warwick", spaces: 19, checkedAt: fresh)
        store.acceptPushedCounts(id: "warwick", standardBikes: 5, eBikes: 0, spaces: 15,
            checkedAt: fresh.addingTimeInterval(-1))
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 5)
        #expect(store.bikePointsByID["warwick"]?.emptyDocks == 19)
    }

    @Test func simultaneousTabRefreshesCoalesceAndDoNotCancelEachOther() {
        let directory = PassthroughSubject<[BikePoint], NetworkError>()
        let dock = PassthroughSubject<BikePoint, NetworkError>()
        var directoryCalls = 0
        var dockCalls = 0
        let store = makeStore(directory: {
            directoryCalls += 1
            return directory.eraseToAnyPublisher()
        }, dock: { _ in
            dockCalls += 1
            return dock.eraseToAnyPublisher()
        })
        store.refresh(dockIDs: ["warwick"], force: true)
        store.refresh(dockIDs: ["warwick", "warwick"], force: true)
        #expect(directoryCalls == 1)
        #expect(dockCalls == 1)
        dock.send(point("warwick", bikes: 1))
        dock.send(completion: .finished)
        #expect(store.isRefreshing)
        directory.send([point("start", bikes: 0)])
        directory.send(completion: .finished)
        #expect(!store.isRefreshing)
    }

    @Test func cancellingWorkClearsSpinnerAndAllowsForegroundRetry() {
        let response = PassthroughSubject<[BikePoint], NetworkError>()
        var calls = 0
        let store = makeStore(directory: { calls += 1; return response.eraseToAnyPublisher() })
        store.refresh(force: true)
        store.cancelRequests()
        response.send([point("warwick", bikes: 99)])
        #expect(store.bikePointsByID["warwick"]?.totalBikes == 8)
        #expect(!store.isRefreshing)
        store.refresh(force: true)
        #expect(calls == 2)
        #expect(store.isRefreshing)
    }

    @Test func emptyResponseDoesNotAdvanceTimestamps() {
        let store = makeStore(directory: { success([]) })
        store.refresh(force: true)
        #expect(store.lastUpdateTime == old)
        #expect(store.snapshot.directoryCheckedAt == old)
        #expect(store.refreshFailed)
    }

    @Test func freshnessExpiresAndAutomaticRefreshRetriesFailuresWithoutSpinning() {
        var date = old
        var calls = 0
        let store = DockAvailabilityStore(cachedBikePoints: [point("warwick", bikes: 8)], cachedAt: old,
            fetchDirectory: { calls += 1; return failure() }, fetchDock: { _ in failure() }, now: { date })
        store.refresh()
        #expect(calls == 0)
        date = old.addingTimeInterval(30)
        #expect(store.isStale(at: date))
        store.refresh()
        store.refresh()
        #expect(calls == 1)
        date = date.addingTimeInterval(8)
        store.refresh()
        #expect(calls == 2)
        #expect(!store.isRefreshing)
    }

    @Test func directoryRequestUsesCanonicalURLAndBypassesCachedResponses() throws {
        for force in [false, true] {
            let request = try #require(TfLAPIService.directoryRequest(cacheBusting: force, timeoutInterval: 12))
            #expect(request.url?.path == "/BikePoint")
            #expect(request.url?.query == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(request.timeoutInterval == 12)
        }
    }

    @Test func cacheRoundTripPreservesSourceTimestampsAndPerDockAges() throws {
        let original = point("warwick", bikes: 1, modified: fresh)
        let decoded = try JSONDecoder().decode(BikePoint.self, from: JSONEncoder().encode(original))
        #expect(decoded.availabilityDataModifiedAt == fresh)
        let store = DockAvailabilityStore(cachedBikePoints: [decoded, point("start", bikes: 0)], cachedAt: old,
            checkedAtByID: ["warwick": fresh, "start": old], fetchDirectory: { failure() }, fetchDock: { _ in failure() })
        #expect(store.lastUpdateTime == old)
        #expect(!store.isStale(at: fresh, dockIDs: ["warwick"]))
        #expect(store.isStale(at: fresh, dockIDs: ["start"]))
    }

    private func makeStore(directory: @escaping () -> AnyPublisher<[BikePoint], NetworkError> = { failure() },
                           dock: @escaping (String) -> AnyPublisher<BikePoint, NetworkError> = { _ in failure() }) -> DockAvailabilityStore {
        DockAvailabilityStore(cachedBikePoints: [point("start", bikes: 7), point("warwick", bikes: 8)],
            cachedAt: old, fetchDirectory: directory, fetchDock: dock, now: { fresh })
    }

    private func point(_ id: String, bikes: Int, modified: Date? = nil) -> BikePoint {
        BikePoint(id: id, commonName: id, lat: 51.5, lon: -0.1, additionalProperties: [
            AdditionalProperty(key: "Installed", value: "true"),
            AdditionalProperty(key: "NbStandardBikes", value: String(bikes), modified: modified),
            AdditionalProperty(key: "NbEBikes", value: "0", modified: modified),
            AdditionalProperty(key: "NbEmptyDocks", value: String(20 - bikes), modified: modified),
            AdditionalProperty(key: "NbDocks", value: "20")
        ])
    }
}

private func success<T>(_ value: T) -> AnyPublisher<T, NetworkError> {
    Just(value).setFailureType(to: NetworkError.self).eraseToAnyPublisher()
}

private func failure<T>() -> AnyPublisher<T, NetworkError> {
    Fail(error: NetworkError.offline).eraseToAnyPublisher()
}
