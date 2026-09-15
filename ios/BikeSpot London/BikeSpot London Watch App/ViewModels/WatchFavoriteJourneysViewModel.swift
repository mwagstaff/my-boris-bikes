import Combine
import Foundation

@MainActor
final class WatchFavoriteJourneysViewModel: ObservableObject {
    @Published private(set) var bikePointsByID: [String: WatchBikePoint] = [:]
    @Published private(set) var isLoading = false

    private let favoritesService = WatchFavoritesService.shared
    private let apiService = WatchTfLAPIService.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    init() {
        favoritesService.$favoriteJourneys
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
            .store(in: &cancellables)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh(cacheBusting: Bool = false) async {
        let ids = Array(Set(favoritesService.favoriteJourneys.flatMap {
            [$0.startDock.id, $0.endDock.id]
        }))
        guard !ids.isEmpty else {
            bikePointsByID = [:]
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard let bikePoints = try? await apiService
            .fetchMultipleBikePoints(ids: ids, cacheBusting: cacheBusting)
            .async() else { return }

        bikePointsByID = Dictionary(uniqueKeysWithValues: bikePoints.map { bikePoint in
            var updated = bikePoint
            updated.alias = favoritesService.alias(for: bikePoint.id)
            return (updated.id, updated)
        })
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
