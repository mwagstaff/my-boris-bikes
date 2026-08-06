import Foundation
import Combine
import CoreLocation

@MainActor
class WatchFavoritesViewModel: ObservableObject {
    @Published var favoriteBikePoints: [WatchBikePoint] = []
    @Published var isLoading = false
    @Published var hasError = false
    @Published var lastRefreshTime: Date?
    
    private var favoritesService = WatchFavoritesService.shared
    private var locationService = WatchLocationService.shared
    private var apiService = WatchTfLAPIService.shared
    private var widgetService = WatchWidgetService.shared
    
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    
    init() {
        setupSubscriptions()
        startAutoRefresh()
        startMonitoringWidgetRefreshRequests()
    }
    
    private func setupSubscriptions() {
        // Listen for changes in favorites or sort mode
        favoritesService.$favorites
            .combineLatest(favoritesService.$sortMode)
            .sink { [weak self] _, _ in
                Task { await self?.loadFavoriteData() }
            }
            .store(in: &cancellables)
        
        // Re-sort when location changes for distance sorting
        locationService.$location
            .sink { [weak self] _ in
                if self?.favoritesService.sortMode == .distance {
                    self?.sortFavoritesByDistance()
                }
            }
            .store(in: &cancellables)
    }
    
    private func loadFavoriteData() async {
        let favoriteIds = favoritesService.favorites.map { $0.id }
        let aliases = aliasMap()
        
        guard !favoriteIds.isEmpty else {
            favoriteBikePoints = []
            // Clear widget data when no favorites
            widgetService.clearWidgetData()
            return
        }
        
        isLoading = true
        hasError = false
        
        do {
            let bikePoints = try await apiService
                .fetchMultipleBikePoints(ids: favoriteIds)
                .async()
            
            let aliasedBikePoints = applyAliases(bikePoints, aliasMap: aliases)
            
            favoriteBikePoints = sortBikePoints(aliasedBikePoints)
            hasError = false
            lastRefreshTime = Date()
            
            // Validate bikePoints before updating widgets to prevent race conditions
            guard !bikePoints.isEmpty else {
                return
            }
            
            // Update widget with closest station data (pass user location for distance calculation)
            if let userLocation = locationService.location {
                let userCoordinate = (lat: userLocation.coordinate.latitude, lon: userLocation.coordinate.longitude)
                widgetService.updateClosestStation(from: aliasedBikePoints, userLocation: userCoordinate)
            } else {
                // Fallback: use first favorite if no location available
                widgetService.updateClosestStation(from: aliasedBikePoints)
            }
            
            // Also update individual dock data for configurable widgets
            widgetService.updateAllDockData(from: aliasedBikePoints)
        } catch {
            hasError = true
            
            // Check if we should start recovery mode
            if shouldStartRecovery() {
                startRecoveryRefresh()
            }
        }
        
        isLoading = false
    }
    
    private func sortBikePoints(_ bikePoints: [WatchBikePoint]) -> [WatchBikePoint] {
        switch favoritesService.sortMode {
        case .distance:
            return sortBikePointsByDistance(bikePoints)
        case .alphabetical:
            return bikePoints.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }
    
    private func aliasMap() -> [String: String] {
        favoritesService.favorites.reduce(into: [String: String]()) { result, favorite in
            if let alias = favorite.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty {
                result[favorite.id] = alias
            }
        }
    }
    
    private func applyAliases(_ bikePoints: [WatchBikePoint], aliasMap: [String: String]) -> [WatchBikePoint] {
        bikePoints.map { bikePoint in
            var updatedBikePoint = bikePoint
            if let alias = aliasMap[bikePoint.id] {
                updatedBikePoint.alias = alias
            }
            return updatedBikePoint
        }
    }
    
    private func sortBikePointsByDistance(_ bikePoints: [WatchBikePoint]) -> [WatchBikePoint] {
        guard let userLocation = locationService.location else { return bikePoints }
        
        return bikePoints.sorted { point1, point2 in
            let distance1 = userLocation.distance(from: CLLocation(latitude: point1.lat, longitude: point1.lon))
            let distance2 = userLocation.distance(from: CLLocation(latitude: point2.lat, longitude: point2.lon))
            return distance1 < distance2
        }
    }
    
    private func sortFavoritesByDistance() {
        favoriteBikePoints = sortBikePointsByDistance(favoriteBikePoints)
    }
    
    func toggleSortMode() {
        let newMode: WatchSortMode = favoritesService.sortMode == .distance ? .alphabetical : .distance
        favoritesService.updateSortMode(newMode)
    }
    
    /// Cache a single bike point and update the UI if it's in favorites
    func cacheBikePoint(_ bikePoint: WatchBikePoint) async {
        // If this bike point is in our favorites, update it
        if let index = favoriteBikePoints.firstIndex(where: { $0.id == bikePoint.id }) {
            var updatedBikePoint = bikePoint
            if updatedBikePoint.alias == nil {
                updatedBikePoint.alias = aliasMap()[bikePoint.id]
            }
            await MainActor.run {
                favoriteBikePoints[index] = updatedBikePoint
            }
        }
    }
    
    func refreshData() async {
        // Refresh favorites from iOS app
        favoritesService.refreshFromiOS()
        await loadFavoriteDataWithCacheBusting()
    }
    
    private func loadFavoriteDataWithCacheBusting() async {
        let favoriteIds = favoritesService.favorites.map { $0.id }
        let aliases = aliasMap()
        
        guard !favoriteIds.isEmpty else {
            favoriteBikePoints = []
            // Clear widget data when no favorites
            widgetService.clearWidgetData()
            return
        }
        
        isLoading = true
        hasError = false
        
        do {
            let bikePoints = try await apiService
                .fetchMultipleBikePoints(ids: favoriteIds, cacheBusting: true)
                .async()
            
            let aliasedBikePoints = applyAliases(bikePoints, aliasMap: aliases)
            
            favoriteBikePoints = sortBikePoints(aliasedBikePoints)
            hasError = false
            lastRefreshTime = Date()
            
            // Validate bikePoints before updating widgets to prevent race conditions
            guard !bikePoints.isEmpty else {
                return
            }
            
            // Update widget with closest station data (pass user location for distance calculation)
            if let userLocation = locationService.location {
                let userCoordinate = (lat: userLocation.coordinate.latitude, lon: userLocation.coordinate.longitude)
                widgetService.updateClosestStation(from: aliasedBikePoints, userLocation: userCoordinate)
            } else {
                // Fallback: use first favorite if no location available
                widgetService.updateClosestStation(from: aliasedBikePoints)
            }
            
            // Also update individual dock data for configurable widgets
            widgetService.updateAllDockData(from: aliasedBikePoints)
        } catch {
            hasError = true
            
            // Check if we should start recovery mode
            if shouldStartRecovery() {
                startRecoveryRefresh()
            }
        }
        
        isLoading = false
    }
    
    func forceRefreshData() async {
        // Clear the API cache to ensure fresh data from TfL API
        apiService.clearCache()
        
        // Refresh favorites from iOS app first, but preserve existing ones if sync fails
        favoritesService.refreshFromiOS(preserveExisting: true)
        
        // Also trigger sync request to phone app
        favoritesService.attemptAutomaticSync()
        
        // Small delay to allow sync to complete
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Load data which will now fetch fresh data from TfL API with cache busting
        await loadFavoriteDataWithCacheBusting()
    }
    
    func forceRefreshSingleDock(_ dockId: String) async -> WatchBikePoint? {
        
        isLoading = true
        hasError = false
        let aliases = aliasMap()
        
        do {
            // Clear cache for this specific dock
            apiService.clearCache()
            
            let bikePoint = try await apiService.fetchSingleBikePoint(id: dockId, cacheBusting: true).async()
            
            if var bikePoint = bikePoint {
                bikePoint.alias = aliases[bikePoint.id]
                // Update the dock in our current favorites list
                if let index = favoriteBikePoints.firstIndex(where: { $0.id == dockId }) {
                    favoriteBikePoints[index] = bikePoint
                } else {
                    // Add to favorites if not already there
                    favoriteBikePoints.append(bikePoint)
                }
                
                // Validate bike point before updating widgets to prevent race conditions
                guard bikePoint.isAvailable else {
                    hasError = false
                    isLoading = false
                    return bikePoint // Still return the bikePoint for UI update
                }
                
                // Update widget data
                widgetService.updateAllDockData(from: [bikePoint])
                lastRefreshTime = Date()
                hasError = false
                
                isLoading = false
                return bikePoint
            } else {
                hasError = true
                isLoading = false
                return nil
            }
        } catch {
            hasError = true
            isLoading = false
            return nil
        }
    }
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task {
                await self?.loadFavoriteData()
            }
        }
    }
    
    /// Starts an aggressive refresh cycle when connection issues are detected
    func startRecoveryRefresh() {
        // Cancel existing timer
        refreshTimer?.invalidate()
        
        // Start aggressive 15-second refresh cycle
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task {
                await self?.loadFavoriteData()
                
                // Check if we have valid data now
                if let self = self, !self.hasError && !self.favoriteBikePoints.isEmpty {
                    await MainActor.run {
                        self.returnToNormalRefresh()
                    }
                }
            }
        }
    }
    
    /// Returns to normal 30-second refresh cycle
    private func returnToNormalRefresh() {
        refreshTimer?.invalidate()
        startAutoRefresh()
    }
    
    /// Checks if we should trigger recovery mode based on data staleness
    private func shouldStartRecovery() -> Bool {
        // Start recovery if we have errors or no data and it's been more than 2 minutes since last successful refresh
        if hasError || favoriteBikePoints.isEmpty {
            if let lastRefresh = lastRefreshTime {
                let timeSinceLastRefresh = Date().timeIntervalSince(lastRefresh)
                return timeSinceLastRefresh > 120 // 2 minutes
            }
            return true // No last refresh time, definitely need recovery
        }
        return false
    }
    
    /// Monitors UserDefaults for cache-busted refresh requests from widgets
    private func startMonitoringWidgetRefreshRequests() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkForWidgetRefreshRequests()
        }
    }
    
    private func checkForWidgetRefreshRequests() {
        guard let userDefaults = UserDefaults(suiteName: "group.dev.skynolimit.myborisbikes") else { return }
        
        let requestKey = "cache_busted_refresh_request"
        guard let data = userDefaults.data(forKey: requestKey) else { return }
        
        do {
            if let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let timestamp = request["timestamp"] as? TimeInterval,
               let reason = request["reason"] as? String,
               let source = request["source"] as? String {
                
                // Check if this request is recent (within last 60 seconds) and not already processed
                let requestAge = Date().timeIntervalSince1970 - timestamp
                if requestAge < 60.0 && requestAge > 0 {
                    // Clear the request to avoid processing it again
                    userDefaults.removeObject(forKey: requestKey)
                    
                    // Perform cache-busted refresh
                    Task {
                        await self.loadFavoriteDataWithCacheBusting()
                    }
                }
            }
        } catch {
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
}

// Extension to convert Publisher to async
extension Publisher {
    func async() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = first()
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    cancellable?.cancel()
                }, receiveValue: { value in
                    continuation.resume(returning: value)
                })
        }
    }
}
