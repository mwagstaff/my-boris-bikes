import Combine
import Foundation
import Testing
@testable import BikeSpot_London

@MainActor
struct JourneyDockAvailabilityStoreTests {
    @Test func refreshesNearbyDocksThatAreNotExplicitlyRequestedOnEveryRefresh() throws {
        let start = try bikePoint("start", bikes: 0)
        let oldBuckinghamGate = try bikePoint("buckingham-gate", bikes: 12, spaces: 3)
        let freshBuckinghamGate = try bikePoint("buckingham-gate", bikes: 6, spaces: 9)
        let nextBuckinghamGate = try bikePoint("buckingham-gate", bikes: 4, spaces: 11)
        var directory = [start, freshBuckinghamGate]
        var directoryRequests: [Bool] = []
        var requestedIDs: [[String]] = []
        var targetedCacheBusting: [Bool] = []
        var savedSnapshots: [[BikePoint]] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [start, oldBuckinghamGate],
            fetchAllBikePoints: { cacheBusting in
                directoryRequests.append(cacheBusting)
                return success(directory)
            },
            fetchBikePoints: { ids, cacheBusting in
                requestedIDs.append(ids)
                targetedCacheBusting.append(cacheBusting)
                return success([start])
            },
            didRefresh: { _, snapshot in
                if let snapshot { savedSnapshots.append(snapshot) }
            }
        )

        store.refresh(dockIDs: [start.id, start.id], cacheBusting: true)

        #expect(store.allBikePoints.first { $0.id == oldBuckinghamGate.id } == freshBuckinghamGate)
        #expect(store.bikePointsByID[start.id] == start)
        #expect(store.bikePointsByID[oldBuckinghamGate.id] == nil)
        #expect(!store.isRefreshing)
        #expect(!savedSnapshots.isEmpty)
        #expect(savedSnapshots.first?.first { $0.id == oldBuckinghamGate.id } == freshBuckinghamGate)

        directory = [start, nextBuckinghamGate]
        store.refresh(dockIDs: [start.id], cacheBusting: true)

        #expect(store.allBikePoints.first { $0.id == oldBuckinghamGate.id } == nextBuckinghamGate)
        #expect(directoryRequests == [true, true])
        #expect(requestedIDs == [[start.id], [start.id]])
        #expect(targetedCacheBusting == [true, true])
        #expect(savedSnapshots.last?.first { $0.id == oldBuckinghamGate.id } == nextBuckinghamGate)
    }

    @Test(arguments: [false, true])
    func targetedCountsTakePrecedenceRegardlessOfResponseOrder(directoryFirst: Bool) throws {
        let oldStart = try bikePoint("start", bikes: 1)
        let directoryStart = try bikePoint("start", bikes: 3)
        let targetedStart = try bikePoint("start", bikes: 7)
        let nearby = try bikePoint("buckingham-gate", bikes: 6)
        let directoryResponse = PassthroughSubject<[BikePoint], NetworkError>()
        let targetedResponse = PassthroughSubject<[BikePoint], NetworkError>()
        var refreshes: [([BikePoint], [BikePoint]?)] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [oldStart],
            fetchAllBikePoints: { _ in directoryResponse.eraseToAnyPublisher() },
            fetchBikePoints: { _, _ in targetedResponse.eraseToAnyPublisher() },
            didRefresh: { refreshes.append(($0, $1)) }
        )

        store.refresh(dockIDs: [oldStart.id])
        #expect(store.isRefreshing)

        if directoryFirst {
            directoryResponse.send([directoryStart, nearby])
            directoryResponse.send(completion: .finished)
        } else {
            targetedResponse.send([targetedStart])
            targetedResponse.send(completion: .finished)
        }
        #expect(refreshes.count == 1)
        #expect(store.isRefreshing)
        #expect(store.bikePointsByID[oldStart.id] == (directoryFirst ? directoryStart : targetedStart))
        if directoryFirst {
            #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        }

        if directoryFirst {
            targetedResponse.send([targetedStart])
            targetedResponse.send(completion: .finished)
        } else {
            directoryResponse.send([directoryStart, nearby])
            directoryResponse.send(completion: .finished)
        }

        #expect(store.bikePointsByID[oldStart.id] == targetedStart)
        #expect(store.allBikePoints.first { $0.id == oldStart.id } == targetedStart)
        #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        #expect(!store.isRefreshing)
        #expect(refreshes.count == 2)
        #expect(refreshes.last?.0 == [targetedStart])
        #expect(refreshes.last?.1?.first { $0.id == oldStart.id } == targetedStart)
    }

    @Test func successfulDirectoryRefreshReplacesOldPrimaryCountsWhenTargetedRequestFails() throws {
        let oldStart = try bikePoint("start", bikes: 1)
        let freshStart = try bikePoint("start", bikes: 7)
        let oldNearby = try bikePoint("buckingham-gate", bikes: 12)
        let freshNearby = try bikePoint("buckingham-gate", bikes: 6)
        var savedSnapshot: [BikePoint]?
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [oldStart, oldNearby],
            fetchAllBikePoints: { _ in success([freshStart, freshNearby]) },
            fetchBikePoints: { _, _ in failure() },
            didRefresh: { _, snapshot in savedSnapshot = snapshot }
        )

        store.refresh(dockIDs: [oldStart.id])

        #expect(store.bikePointsByID[oldStart.id] == freshStart)
        #expect(store.allBikePoints.first { $0.id == oldNearby.id } == freshNearby)
        #expect(savedSnapshot?.first { $0.id == oldStart.id } == freshStart)
        #expect(savedSnapshot?.first { $0.id == oldNearby.id } == freshNearby)
        #expect(!store.isRefreshing)
    }

    @Test func failedDirectoryRefreshKeepsNearbyCountsWithoutSavingAPartialSnapshot() throws {
        let oldStart = try bikePoint("start", bikes: 1)
        let freshStart = try bikePoint("start", bikes: 7)
        let oldNearby = try bikePoint("buckingham-gate", bikes: 12)
        var refreshes: [([BikePoint], [BikePoint]?)] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [oldStart, oldNearby],
            fetchAllBikePoints: { _ in failure() },
            fetchBikePoints: { _, _ in success([freshStart]) },
            didRefresh: { refreshes.append(($0, $1)) }
        )

        store.refresh(dockIDs: [oldStart.id])

        #expect(store.bikePointsByID[oldStart.id] == freshStart)
        #expect(store.allBikePoints.first { $0.id == oldStart.id } == freshStart)
        #expect(store.allBikePoints.first { $0.id == oldNearby.id } == oldNearby)
        #expect(refreshes.count == 1)
        #expect(refreshes.first?.0 == [freshStart])
        #expect(refreshes.first?.1 == nil)
        #expect(!store.isRefreshing)
    }

    @Test func failureOfBothRequestsPreservesLastKnownAvailability() throws {
        let start = try bikePoint("start", bikes: 7)
        let nearby = try bikePoint("buckingham-gate", bikes: 6)
        var refreshCount = 0
        var savedSnapshots: [[BikePoint]] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [start, nearby],
            fetchAllBikePoints: { _ in failure() },
            fetchBikePoints: { _, _ in failure() },
            didRefresh: { _, snapshot in
                refreshCount += 1
                if let snapshot { savedSnapshots.append(snapshot) }
            }
        )

        store.refresh(dockIDs: [start.id])

        #expect(store.bikePointsByID[start.id] == start)
        #expect(store.allBikePoints.first { $0.id == start.id } == start)
        #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        #expect(refreshCount == 0)
        #expect(savedSnapshots.isEmpty)
        #expect(!store.isRefreshing)
    }

    @Test func emptyDirectoryResponseKeepsNearbyDocksAndDoesNotSaveAPartialSnapshot() throws {
        let oldStart = try bikePoint("start", bikes: 1)
        let freshStart = try bikePoint("start", bikes: 7)
        let nearby = try bikePoint("buckingham-gate", bikes: 6)
        var savedSnapshots: [[BikePoint]] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [oldStart, nearby],
            fetchAllBikePoints: { _ in success([]) },
            fetchBikePoints: { _, _ in success([freshStart]) },
            didRefresh: { _, snapshot in
                if let snapshot { savedSnapshots.append(snapshot) }
            }
        )

        store.refresh(dockIDs: [oldStart.id])

        #expect(store.bikePointsByID[oldStart.id] == freshStart)
        #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        #expect(savedSnapshots.isEmpty)
        #expect(!store.isRefreshing)
    }

    @Test func newerRefreshCancelsOlderResponses() throws {
        let oldStart = try bikePoint("start", bikes: 1)
        let supersededStart = try bikePoint("start", bikes: 3)
        let freshStart = try bikePoint("start", bikes: 7)
        let nearby = try bikePoint("buckingham-gate", bikes: 6)
        let directoryResponses = (0..<2).map { _ in PassthroughSubject<[BikePoint], NetworkError>() }
        let targetedResponses = (0..<2).map { _ in PassthroughSubject<[BikePoint], NetworkError>() }
        var directoryRequests = 0
        var targetedRequests = 0
        var refreshes: [([BikePoint], [BikePoint]?)] = []
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [oldStart],
            fetchAllBikePoints: { _ in
                defer { directoryRequests += 1 }
                return directoryResponses[directoryRequests].eraseToAnyPublisher()
            },
            fetchBikePoints: { _, _ in
                defer { targetedRequests += 1 }
                return targetedResponses[targetedRequests].eraseToAnyPublisher()
            },
            didRefresh: { refreshes.append(($0, $1)) }
        )

        store.refresh(dockIDs: [oldStart.id])
        store.refresh(dockIDs: [oldStart.id])
        directoryResponses[0].send([supersededStart])
        targetedResponses[0].send([supersededStart])
        directoryResponses[0].send(completion: .finished)
        targetedResponses[0].send(completion: .finished)

        #expect(store.bikePointsByID[oldStart.id] == oldStart)
        #expect(store.isRefreshing)
        #expect(refreshes.isEmpty)

        directoryResponses[1].send([freshStart, nearby])
        targetedResponses[1].send([freshStart])
        directoryResponses[1].send(completion: .finished)
        targetedResponses[1].send(completion: .finished)

        #expect(store.bikePointsByID[oldStart.id] == freshStart)
        #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        #expect(!refreshes.isEmpty)
        #expect(!store.isRefreshing)
    }

    @Test func noActiveDocksSkipsFetchingAndCancelsAnExistingRefresh() throws {
        let start = try bikePoint("start", bikes: 1)
        let nearby = try bikePoint("buckingham-gate", bikes: 6)
        let directoryResponse = PassthroughSubject<[BikePoint], NetworkError>()
        let targetedResponse = PassthroughSubject<[BikePoint], NetworkError>()
        var directoryRequests = 0
        var targetedRequests = 0
        var refreshCount = 0
        let store = JourneyDockAvailabilityStore(
            cachedBikePoints: [start, nearby],
            fetchAllBikePoints: { _ in
                directoryRequests += 1
                return directoryResponse.eraseToAnyPublisher()
            },
            fetchBikePoints: { _, _ in
                targetedRequests += 1
                return targetedResponse.eraseToAnyPublisher()
            },
            didRefresh: { _, _ in refreshCount += 1 }
        )

        store.refresh(dockIDs: [])
        #expect(directoryRequests == 0)
        #expect(targetedRequests == 0)
        #expect(!store.isRefreshing)

        store.refresh(dockIDs: [start.id])
        #expect(store.isRefreshing)
        store.refresh(dockIDs: [])
        directoryResponse.send([start, nearby])
        targetedResponse.send([start])
        directoryResponse.send(completion: .finished)
        targetedResponse.send(completion: .finished)

        #expect(directoryRequests == 1)
        #expect(targetedRequests == 1)
        #expect(store.bikePointsByID.isEmpty)
        #expect(store.allBikePoints.first { $0.id == nearby.id } == nearby)
        #expect(refreshCount == 0)
        #expect(!store.isRefreshing)
    }

    private func success(_ bikePoints: [BikePoint]) -> AnyPublisher<[BikePoint], NetworkError> {
        Just(bikePoints).setFailureType(to: NetworkError.self).eraseToAnyPublisher()
    }

    private func failure() -> AnyPublisher<[BikePoint], NetworkError> {
        Fail(error: NetworkError.offline).eraseToAnyPublisher()
    }

    private func bikePoint(_ id: String, bikes: Int, spaces: Int = 9) throws -> BikePoint {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "commonName": id == "buckingham-gate" ? "Buckingham Gate, Westminster" : id,
            "lat": 51.5,
            "lon": -0.1,
            "additionalProperties": [
                ["key": "Installed", "value": "true"],
                ["key": "Locked", "value": "false"],
                ["key": "NbStandardBikes", "value": String(bikes)],
                ["key": "NbEBikes", "value": "0"],
                ["key": "NbEmptyDocks", "value": String(spaces)],
                ["key": "NbDocks", "value": String(bikes + spaces)]
            ]
        ])
        return try JSONDecoder().decode(BikePoint.self, from: data)
    }
}
