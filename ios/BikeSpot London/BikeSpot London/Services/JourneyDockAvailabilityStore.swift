import Combine
import Foundation

@MainActor
final class JourneyDockAvailabilityStore: ObservableObject {
    @Published private(set) var bikePointsByID: [String: BikePoint]
    @Published private(set) var allBikePoints: [BikePoint]
    @Published private(set) var isRefreshing = false
    private var cancellable: AnyCancellable?
    private var refreshID = UUID()

    private let fetchAllBikePoints: (Bool) -> AnyPublisher<[BikePoint], NetworkError>
    private let fetchBikePoints: ([String], Bool) -> AnyPublisher<[BikePoint], NetworkError>
    private let didRefresh: ([BikePoint], [BikePoint]?) -> Void

    convenience init() {
        self.init(
            cachedBikePoints: AllBikePointsCache.shared.load(),
            fetchAllBikePoints: { TfLAPIService.shared.fetchAllBikePoints(cacheBusting: $0) },
            fetchBikePoints: { TfLAPIService.shared.fetchMultipleBikePoints(ids: $0, cacheBusting: $1) },
            didRefresh: { bikePoints, snapshot in
                if let snapshot {
                    AllBikePointsCache.shared.save(snapshot, savedAt: Date())
                }
                for bikePoint in bikePoints {
                    DockArrivalMonitoringService.shared.updateMonitoredDockIfNeeded(using: bikePoint)
                }
                Task {
                    await LiveActivityService.shared.updateActiveActivitiesIfNeeded(using: bikePoints)
                }
            }
        )
    }

    init(
        cachedBikePoints: [BikePoint],
        fetchAllBikePoints: @escaping (Bool) -> AnyPublisher<[BikePoint], NetworkError>,
        fetchBikePoints: @escaping ([String], Bool) -> AnyPublisher<[BikePoint], NetworkError>,
        didRefresh: @escaping ([BikePoint], [BikePoint]?) -> Void
    ) {
        self.fetchAllBikePoints = fetchAllBikePoints
        self.fetchBikePoints = fetchBikePoints
        self.didRefresh = didRefresh
        allBikePoints = cachedBikePoints
        bikePointsByID = [:]
    }

    func refresh(dockIDs: [String], cacheBusting: Bool = false) {
        let refreshID = UUID()
        self.refreshID = refreshID
        cancellable?.cancel()

        guard !dockIDs.isEmpty else {
            bikePointsByID = [:]
            isRefreshing = false
            return
        }

        let requestedIDs = Set(dockIDs)
        let uniqueDockIDs = Array(requestedIDs).sorted()

        let cachedBikePoints = allBikePoints.filter { requestedIDs.contains($0.id) }
        var availableBikePoints = bikePointsByID.filter { requestedIDs.contains($0.key) }
        for bikePoint in cachedBikePoints where availableBikePoints[bikePoint.id] == nil {
            availableBikePoints[bikePoint.id] = bikePoint
        }
        bikePointsByID = availableBikePoints
        isRefreshing = true

        // Nearby alternatives come from the full directory, so refreshing only
        // the journey's selected docks leaves their availability frozen in time.
        let allBikePointsPublisher = fetchAllBikePoints(cacheBusting)
            .map { $0.isEmpty ? nil : $0 }
            .replaceError(with: nil)
            .prepend(nil)
            .removeDuplicates()
        let selectedBikePointsPublisher = fetchBikePoints(uniqueDockIDs, cacheBusting)
            .replaceError(with: [])
            .prepend([])
            .removeDuplicates()

        cancellable = allBikePointsPublisher
            .combineLatest(selectedBikePointsPublisher)
            .sink(
                receiveCompletion: { [weak self] _ in
                    guard self?.refreshID == refreshID else { return }
                    self?.isRefreshing = false
                },
                receiveValue: { [weak self] snapshot, selectedBikePoints in
                    guard let self else { return }
                    guard self.refreshID == refreshID else { return }
                    // Each request can update the screen while the other is still pending.
                    guard snapshot != nil || !selectedBikePoints.isEmpty else { return }

                    var refreshedByID = Dictionary(uniqueKeysWithValues: (snapshot ?? []).map { ($0.id, $0) })
                    for bikePoint in selectedBikePoints {
                        refreshedByID[bikePoint.id] = bikePoint
                    }

                    // A successful targeted response takes precedence over the
                    // directory response, regardless of which request finishes first.
                    var mergedByID = Dictionary(uniqueKeysWithValues: (snapshot ?? self.allBikePoints).map { ($0.id, $0) })
                    mergedByID.merge(refreshedByID, uniquingKeysWith: { _, refreshed in refreshed })
                    self.allBikePoints = Array(mergedByID.values)
                    self.bikePointsByID = availableBikePoints.merging(
                        mergedByID.filter { requestedIDs.contains($0.key) },
                        uniquingKeysWith: { _, refreshed in refreshed }
                    )

                    let refreshedRequestedPoints = uniqueDockIDs.compactMap { refreshedByID[$0] }
                    // Partial refreshes must not mark old nearby counts as a fresh cache.
                    self.didRefresh(refreshedRequestedPoints, snapshot == nil ? nil : self.allBikePoints)
                }
            )
    }
}
