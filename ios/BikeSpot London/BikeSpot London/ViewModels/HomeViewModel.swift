import Foundation
import Combine
import CoreLocation

@MainActor
class HomeViewModel: BaseViewModel {
    @Published var favoriteBikePoints: [BikePoint] = []
    @Published var allBikePoints: [BikePoint] = []
    @Published var lastUpdateTime: Date?
    @Published var tflDataStaleWarning: String?
    private var favoritesService: FavoritesService?
    private var locationService: LocationService?
    private var widgetService: WidgetService?
    private var isSetup = false

    func setup(favoritesService: FavoritesService, locationService: LocationService) {
        guard !isSetup else { return }
        isSetup = true
        self.favoritesService = favoritesService
        self.locationService = locationService
        widgetService = WidgetService.shared
        let store = DockAvailabilityStore.shared
        store.$snapshot.sink { [weak self] snapshot in
            self?.apply(snapshot)
        }.store(in: &cancellables)
        store.$isRefreshing.sink { [weak self] refreshing in
            self?.isLoading = refreshing
        }.store(in: &cancellables)
        favoritesService.$favorites.combineLatest(favoritesService.$sortMode)
            .sink { [weak self] favorites, _ in
                self?.apply(store.snapshot, favoriteIDs: favorites.map(\.id))
                store.refresh(dockIDs: favorites.map(\.id))
            }.store(in: &cancellables)
        locationService.$location.sink { [weak self] _ in
            if favoritesService.sortMode == .distance { self?.sortByDistance() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification,
            object: AppConstants.UserDefaults.sharedDefaults)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateWidgetData(self.favoriteBikePoints)
            }.store(in: &cancellables)
        store.refresh(dockIDs: favoritesService.favorites.map(\.id))
    }

    func refreshData() async {
        await DockAvailabilityStore.shared.refreshAndWait(
            dockIDs: favoritesService?.favorites.map(\.id) ?? [], force: true)
    }

    func refreshIfStale() async {
        await DockAvailabilityStore.shared.refreshAndWait(dockIDs: favoritesService?.favorites.map(\.id) ?? [])
    }

    func refreshAlternativeDockDataIfStale() {
        DockAvailabilityStore.shared.refresh()
    }

    private func apply(_ snapshot: DockAvailabilityStore.Snapshot, favoriteIDs: [String]? = nil) {
        allBikePoints = snapshot.allBikePoints.filter(\.isInstalled)
        let ids = favoriteIDs ?? favoritesService?.favorites.map(\.id) ?? []
        favoriteBikePoints = sortBikePoints(ids.compactMap { snapshot.bikePointsByID[$0] })
        lastUpdateTime = snapshot.oldestCheck(for: Array(snapshot.bikePointsByID.keys))
        let staleRatio = BikePoint.staleAvailabilityDataRatio(in: allBikePoints, fetchedAt: Date(),
            staleAfter: AppConstants.App.tflApiStalenessThreshold)
        tflDataStaleWarning = (staleRatio ?? 0) >= AppConstants.App.tflApiStaleDockWarningRatio
            ? "Warning: TfL bike data may be out of date" : nil
        updateWidgetData(favoriteBikePoints)
    }

    private func sortBikePoints(_ bikePoints: [BikePoint]) -> [BikePoint] {
        guard let favoritesService = favoritesService else { return bikePoints }

        switch favoritesService.sortMode {
        case .distance:
            return sortBikePointsByDistance(bikePoints)
        case .alphabetical:
            return bikePoints.sorted {
                let firstName = favoritesService.displayName(for: $0)
                let secondName = favoritesService.displayName(for: $1)
                return firstName.localizedCaseInsensitiveCompare(secondName) == .orderedAscending
            }
        }
    }
    
    private func sortBikePointsByDistance(_ bikePoints: [BikePoint]) -> [BikePoint] {
        guard let locationService = locationService,
              let userLocation = locationService.location else { return bikePoints }
        
        return bikePoints.sorted { point1, point2 in
            let distance1 = userLocation.distance(from: CLLocation(latitude: point1.lat, longitude: point1.lon))
            let distance2 = userLocation.distance(from: CLLocation(latitude: point2.lat, longitude: point2.lon))
            return distance1 < distance2
        }
    }
    
    private func sortByDistance() {
        guard let locationService = locationService,
              let userLocation = locationService.location else { return }
        
        let sorted = favoriteBikePoints.sorted { point1, point2 in
            let distance1 = userLocation.distance(from: CLLocation(latitude: point1.lat, longitude: point1.lon))
            let distance2 = userLocation.distance(from: CLLocation(latitude: point2.lat, longitude: point2.lon))
            return distance1 < distance2
        }
        
        favoriteBikePoints = sorted
    }
    
    private func updateWidgetData(_ bikePoints: [BikePoint]) {
        guard let favoritesService = favoritesService,
              let widgetService = widgetService else { return }

        widgetService.updateWidgetData(
            bikePoints: bikePoints,
            allBikePoints: allBikePoints,
            favorites: favoritesService.favorites,
            sortMode: favoritesService.sortMode,
            userLocation: locationService?.location
        )
    }

}
