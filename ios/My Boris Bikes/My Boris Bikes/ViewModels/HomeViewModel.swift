import Foundation
import Combine
import CoreLocation

@MainActor
class HomeViewModel: BaseViewModel {
    @Published var favoriteBikePoints: [BikePoint] = []
    @Published var allBikePoints: [BikePoint] = []
    @Published var lastUpdateTime: Date?

    private var favoritesService: FavoritesService?
    private var locationService: LocationService?
    private var widgetService: WidgetService?
    private var refreshTimer: Timer?
    private var bikePointCache: [String: BikePoint] = [:]
    private var allBikePointsRequest: AnyCancellable?
    private var lastAllBikePointsRefreshTime: Date?
    private var isAllBikePointsRefreshInFlight = false
    private var isSetup = false
    
    func setup(favoritesService: FavoritesService, locationService: LocationService) {
        guard !isSetup else { return }
        isSetup = true

        self.favoritesService = favoritesService
        self.locationService = locationService
        self.widgetService = WidgetService.shared
        if allBikePoints.isEmpty {
            let cachedAllBikePoints = AllBikePointsCache.shared.load()
            if !cachedAllBikePoints.isEmpty {
                allBikePoints = cachedAllBikePoints
            }
        }

        favoritesService.$favorites
            .combineLatest(favoritesService.$sortMode)
            .sink { [weak self] favorites, _ in
                // Immediately update the displayed list to match the new favorites
                // This prevents UI/data inconsistencies during deletions
                self?.updateFavoriteBikePointsFromFavoritesList(favorites)
                Task { await self?.loadFavoriteData() }
            }
            .store(in: &cancellables)

        // Listen for recently added bike points to cache them immediately
        favoritesService.$recentlyAddedBikePoint
            .compactMap { $0 }
            .sink { [weak self] bikePoint in
                self?.cacheBikePoint(bikePoint)
            }
            .store(in: &cancellables)

        locationService.$location
            .sink { [weak self] _ in
                if favoritesService.sortMode == .distance {
                    self?.sortByDistance()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: AppConstants.UserDefaults.sharedDefaults
        )
        .sink { [weak self] _ in
            self?.loadAllBikePointsIfNeeded(forceRefresh: false)
            if let favoriteBikePoints = self?.favoriteBikePoints {
                self?.updateWidgetData(favoriteBikePoints)
            }
        }
        .store(in: &cancellables)

        // Load initial data immediately
        Task {
            await loadFavoriteData(forceRefresh: true)
        }

        startAutoRefresh()
    }
    
    func refreshData() async {
        // Force refresh to ensure we get fresh data during manual refresh
        await loadFavoriteData(forceRefresh: true)
    }
    
    func refreshIfStale() async {
        // Check if data is stale (older than 60 seconds)
        let staleThreshold: TimeInterval = 60
        
        if let lastUpdate = lastUpdateTime {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)
            if timeSinceLastUpdate > staleThreshold {
                await loadFavoriteData(forceRefresh: true)
            }
        } else {
            // No last update time means we haven't loaded data yet
            await loadFavoriteData(forceRefresh: true)
        }
    }

    func refreshAlternativeDockDataIfStale() {
        let cachedAllBikePoints = AllBikePointsCache.shared.load()
        if !cachedAllBikePoints.isEmpty {
            allBikePoints = cachedAllBikePoints
        }

        let staleThreshold = AppConstants.App.refreshInterval
        let isStale = lastAllBikePointsRefreshTime.map {
            Date().timeIntervalSince($0) >= staleThreshold
        } ?? true

        guard isStale else { return }
        loadAllBikePointsIfNeeded(forceRefresh: true)
    }
    
    func cacheBikePoint(_ bikePoint: BikePoint) {
        bikePointCache[bikePoint.id] = bikePoint
    }
    
    func cacheBikePoints(_ bikePoints: [BikePoint]) {
        for bikePoint in bikePoints {
            bikePointCache[bikePoint.id] = bikePoint
        }
    }
    
    private func updateFavoriteBikePointsFromFavoritesList(_ favorites: [FavoriteBikePoint]) {
        // Immediately filter the current favoriteBikePoints to match the updated favorites list
        // This prevents UI crashes when items are deleted
        let favoriteIds = Set(favorites.map { $0.id })
        favoriteBikePoints = favoriteBikePoints.filter { favoriteIds.contains($0.id) }
    }
    
    private func loadFavoriteData() async {
        await loadFavoriteData(forceRefresh: false)
    }
    
    private func loadFavoriteData(forceRefresh: Bool = false) async {
        guard let favoritesService = favoritesService else { return }
        
        let favoriteIds = favoritesService.favorites.map { $0.id }
        guard !favoriteIds.isEmpty else {
            favoriteBikePoints = []
            allBikePoints = []
            lastAllBikePointsRefreshTime = nil
            return
        }
        
        // Determine which IDs to fetch
        let idsToFetch: [String]
        if forceRefresh || bikePointCache.isEmpty {
            // Fetch all favorites if forcing refresh or no cache
            idsToFetch = favoriteIds
        } else {
            // Only fetch missing IDs
            idsToFetch = favoriteIds.filter { bikePointCache[$0] == nil }
        }
        
        // Show cached data immediately if available and not forcing refresh
        if !forceRefresh && !bikePointCache.isEmpty {
            let cachedBikePoints = favoriteIds.compactMap { bikePointCache[$0] }
            if !cachedBikePoints.isEmpty {
                favoriteBikePoints = sortBikePoints(cachedBikePoints)
                // Update widget with cached data
                updateWidgetData(cachedBikePoints)
            }
        }
        
        // Fetch fresh data if needed
        if !idsToFetch.isEmpty {
            isLoading = true
            clearError()
            
            TfLAPIService.shared
                .fetchMultipleBikePoints(ids: idsToFetch, cacheBusting: forceRefresh)
                .sink(
                    receiveCompletion: { [weak self] completion in
                        self?.isLoading = false
                        if case .failure(let error) = completion {
                            self?.setError(error)
                        }
                    },
                    receiveValue: { [weak self] newBikePoints in
                        // Update cache with new data
                        for bikePoint in newBikePoints {
                            self?.bikePointCache[bikePoint.id] = bikePoint
                        }
                        
                        // Combine cached and new data
                        let allBikePoints = favoriteIds.compactMap { self?.bikePointCache[$0] }
                        self?.favoriteBikePoints = self?.sortBikePoints(allBikePoints) ?? []
                        
                        // Update last refresh time
                        self?.lastUpdateTime = Date()

                        // Clear any existing errors on successful data load
                        self?.clearErrorOnSuccess()

                        // Update widget data
                        self?.updateWidgetData(allBikePoints)

                        self?.loadAllBikePointsIfNeeded(forceRefresh: forceRefresh)
                    }
                )
                .store(in: &cancellables)
        } else if forceRefresh {
            // If forcing refresh but no data to fetch, just update timestamp
            lastUpdateTime = Date()
            clearErrorOnSuccess()

            // Update widget with all cached data
            let allCachedBikePoints = favoriteIds.compactMap { bikePointCache[$0] }
            if !allCachedBikePoints.isEmpty {
                updateWidgetData(allCachedBikePoints)
            }

            loadAllBikePointsIfNeeded(forceRefresh: forceRefresh)
        } else {
            // No new data to fetch and not forcing refresh
            // Still update widget with cached data in case it wasn't updated before
            let allCachedBikePoints = favoriteIds.compactMap { bikePointCache[$0] }
            if !allCachedBikePoints.isEmpty {
                updateWidgetData(allCachedBikePoints)
            }

            loadAllBikePointsIfNeeded(forceRefresh: forceRefresh)
        }
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
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.App.refreshInterval, repeats: true) { [weak self] _ in
            Task {
                self?.loadAllBikePointsIfNeeded(forceRefresh: false)
                // Always force refresh to ensure fresh data at every interval
                await self?.loadFavoriteData(forceRefresh: true)
            }
        }
        // Fire the timer immediately to ensure first update happens right away
        refreshTimer?.fire()
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

    private func loadAllBikePointsIfNeeded(forceRefresh: Bool) {
        let defaults = AlternativeDockSettings.userDefaultsStore
        let isEnabled = defaults.bool(forKey: AlternativeDockSettings.enabledKey)
        let widgetEnabled = defaults.object(forKey: AlternativeDockSettings.widgetEnabledKey) as? Bool
            ?? AlternativeDockSettings.defaultWidgetEnabled
        guard isEnabled || widgetEnabled else { return }
        let intervalElapsed = lastAllBikePointsRefreshTime.map {
            Date().timeIntervalSince($0) >= AppConstants.App.refreshInterval
        } ?? true
        guard forceRefresh || allBikePoints.isEmpty || intervalElapsed else { return }
        guard !isAllBikePointsRefreshInFlight else { return }

        isAllBikePointsRefreshInFlight = true
        let shouldBypassCache = forceRefresh || intervalElapsed
        allBikePointsRequest = TfLAPIService.shared
            .fetchAllBikePoints(cacheBusting: shouldBypassCache)
            .sink(
                receiveCompletion: { [weak self] _ in
                    self?.isAllBikePointsRefreshInFlight = false
                },
                receiveValue: { [weak self] bikePoints in
                    let installedBikePoints = bikePoints.filter { $0.isInstalled }
                    guard !installedBikePoints.isEmpty else { return }
                    self?.allBikePoints = installedBikePoints
                    self?.lastAllBikePointsRefreshTime = Date()
                    AllBikePointsCache.shared.save(installedBikePoints)
                    if let favoriteBikePoints = self?.favoriteBikePoints {
                        self?.updateWidgetData(favoriteBikePoints)
                    }
                }
            )
    }

    deinit {
        refreshTimer?.invalidate()
        allBikePointsRequest?.cancel()
    }
}
