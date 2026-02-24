import Foundation
import SwiftUI
import MapKit
import Combine
import OSLog

@MainActor
class MapViewModel: BaseViewModel {
    @Published var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278), // London center
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // More zoomed in
        )
    )
    @Published var visibleBikePoints: [BikePoint] = []
    @Published var shouldShowZoomMessage = false
    @Published var lastUpdateTime: Date?
    @Published var staleDataWarningMessage: String?
    
    private var locationService: LocationService?
    private var allBikePoints: [BikePoint] = []
    private let maxVisiblePoints = 50 // Limit for performance
    private var currentMapCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    private var currentMapSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    private var updateTimer: Timer?
    private var backgroundUpdateTimer: Timer?
    private var transientRetryTimer: Timer?
    private var transientRetryAttemptCount = 0
    private let logger = Logger(subsystem: "com.myborisbikes.app", category: "MapViewModel")
    private var hasInitiallyeCentered = false // Track if we've already centered on user location
    private var isSetup = false // Track if setup has already been called
    private var hasPendingBikePointCenter = false // Track if we need to center on a specific bike point
    private var pendingDockId: String?
    
    func setup(locationService: LocationService) {
        // Prevent multiple setups
        guard !isSetup else {
            logger.info("MapViewModel already set up, skipping duplicate setup")
            return
        }
        
        isSetup = true
        self.locationService = locationService
        logger.info("Setting up MapViewModel with auth status: \(locationService.authorizationStatus.rawValue, privacy: .public)")
        
        locationService.$location
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.logger.info("New location: \(location.coordinate.latitude, privacy: .public), \(location.coordinate.longitude, privacy: .public)")
                // Only auto-center on the first location update, not subsequent ones, and not if we're centering on a specific bike point
                if let self = self, !self.hasInitiallyeCentered && !self.hasPendingBikePointCenter {
                    self.logger.info("First location received, centering map")
                    self.hasInitiallyeCentered = true
                    self.updateRegion(for: location)
                } else {
                    self?.logger.info("Location updated but not auto-centering (already centered initially or centering on bike point)")
                }
            }
            .store(in: &cancellables)
        
        // Ensure location updates are started if authorized
        if locationService.authorizationStatus == .authorizedWhenInUse || locationService.authorizationStatus == .authorizedAlways {
            logger.info("Location already authorized, starting location updates")
            locationService.startLocationUpdates()
        } else {
            logger.info("Location not authorized, requesting permission")
            locationService.requestLocationPermission()
        }
        
        loadCachedBikePointsIfAvailable()
        loadBikePoints()
        startBackgroundUpdates()
    }
    
    func refreshData() {
        logger.info("Manual refresh requested with cache busting")
        loadBikePoints(cacheBusting: true)
    }
    
    private func startBackgroundUpdates() {
        var updateCount = 0
        // Set up timer for regular background updates every 30 seconds
        backgroundUpdateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                updateCount += 1
                // Use cache busting every 4th background update (every 2 minutes) to ensure fresh data
                let useCacheBusting = updateCount % 4 == 0
                if useCacheBusting {
                    self?.logger.info("Background update triggered with cache busting")
                } else {
                    self?.logger.info("Background update triggered")
                }
                self?.loadBikePoints(cacheBusting: useCacheBusting)
            }
        }
        // Fire the timer immediately to ensure first update happens right away
        backgroundUpdateTimer?.fire()
        logger.info("Background updates started (30 second interval, with cache busting every 2 minutes)")
    }
    
    func updateMapRegion(_ region: MKCoordinateRegion) {
        // Update the current map center and span, then refresh visible points with debouncing
        currentMapCenter = region.center
        currentMapSpan = region.span
        
        // Cancel existing timer and create a new one for debouncing
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateVisibleBikePoints()
            }
        }
    }
    
    private func updateRegion(for location: CLLocation) {
        let newCenter = location.coordinate
        let newSpan = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        
        currentMapCenter = newCenter
        currentMapSpan = newSpan
        
        withAnimation(.easeInOut(duration: 1.0)) {
            position = .region(
                MKCoordinateRegion(
                    center: newCenter,
                    span: newSpan
                )
            )
        }
        
        // Update visible points after region change
        updateVisibleBikePoints()
    }

    // Function to center the map on the nearest bike point
    func centerOnNearestBikePoint() {
        guard let locationService = locationService,
              let userLocation = locationService.location else {
            logger.warning("No user location available - service: \(self.locationService != nil, privacy: .public)")
            return
        }

        // Calculate the distance to the nearest bike point
        let nearestBikePoint = allBikePoints.min { (point1, point2) -> Bool in
            let distance1 = userLocation.distance(from: CLLocation(latitude: point1.lat, longitude: point1.lon))
            let distance2 = userLocation.distance(from: CLLocation(latitude: point2.lat, longitude: point2.lon))
            return distance1 < distance2
        }

        // If there is a nearest bike point, center the map on it
        if let nearestBikePoint = nearestBikePoint {
            logger.info("Centering on nearest bike point: \(nearestBikePoint.commonName, privacy: .public)")
            updateRegion(for: CLLocation(latitude: nearestBikePoint.lat, longitude: nearestBikePoint.lon))
        } else {
            logger.warning("No nearest bike point found")
        }
    }
    
    func centerOnUserLocation() {
        guard let locationService = locationService,
              let userLocation = locationService.location else {
            logger.warning("No user location available - service: \(self.locationService != nil, privacy: .public)")
            return
        }
        
        logger.info("Centering on location: \(userLocation.coordinate.latitude, privacy: .public), \(userLocation.coordinate.longitude, privacy: .public)")
        updateRegion(for: userLocation)
    }
    
    func centerOnBikePoint(_ bikePoint: BikePoint) {
        logger.info("Centering on bike point: \(bikePoint.commonName, privacy: .public)")
        let location = CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon)
        
        // Set flag to prevent automatic centering on user location
        hasPendingBikePointCenter = true
        hasInitiallyeCentered = true // Prevent future auto-centering on user location
        
        updateRegion(for: location)
    }

    func centerOnBikePoint(id: String) {
        if let bikePoint = allBikePoints.first(where: { $0.id == id }) {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        } else {
            pendingDockId = id
        }
    }
    
    private func loadBikePoints(cacheBusting: Bool = false) {
        isLoading = true
        clearError()
        
        if cacheBusting {
            logger.info("Loading bike points with cache busting")
        }
        
        TfLAPIService.shared
            .fetchAllBikePoints(
                cacheBusting: cacheBusting,
                timeoutInterval: AppConstants.App.mapFetchTimeout
            )
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoading = false
                    if case .failure(let error) = completion {
                        let usedFallback = self?.handleFetchFailure(error) ?? false
                        if !usedFallback {
                            self?.setError(error)
                            self?.scheduleTransientRetry()
                        }
                    }
                },
                receiveValue: { [weak self] bikePoints in
                    let installedBikePoints = bikePoints.filter { $0.isInstalled }
                    guard !installedBikePoints.isEmpty else {
                        let usedFallback = self?.handleFetchFailure(NetworkError.noData) ?? false
                        if !usedFallback {
                            self?.setError(NetworkError.noData)
                            self?.scheduleTransientRetry()
                        }
                        return
                    }

                    self?.applyFreshBikePoints(installedBikePoints)
                }
            )
            .store(in: &cancellables)
    }

    private func loadCachedBikePointsIfAvailable() {
        guard let cachedSnapshot = AllBikePointsCache.shared.loadSnapshot() else { return }

        let installedBikePoints = cachedSnapshot.bikePoints.filter { $0.isInstalled }
        guard !installedBikePoints.isEmpty else { return }

        allBikePoints = installedBikePoints
        lastUpdateTime = cachedSnapshot.savedAt
        updateVisibleBikePoints()
        logger.info("Loaded \(installedBikePoints.count, privacy: .public) cached bike points for map startup")
    }

    private func applyFreshBikePoints(_ bikePoints: [BikePoint]) {
        let updateDate = Date()
        allBikePoints = bikePoints
        lastUpdateTime = updateDate
        staleDataWarningMessage = nil
        AllBikePointsCache.shared.save(bikePoints, savedAt: updateDate)
        updateVisibleBikePoints()
        stopTransientRetry()

        if let dockId = pendingDockId,
           let bikePoint = bikePoints.first(where: { $0.id == dockId }) {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        }

        logger.info("Map data updated successfully")
        clearErrorOnSuccess()
    }

    private func handleFetchFailure(_ error: Error) -> Bool {
        if !allBikePoints.isEmpty {
            logger.warning("Keeping in-memory bike points due to TfL fetch issue: \(error.localizedDescription, privacy: .public)")
            updateStaleDataWarning(savedAt: lastUpdateTime)
            scheduleTransientRetry()
            return true
        }

        guard let cachedSnapshot = AllBikePointsCache.shared.loadSnapshot() else {
            staleDataWarningMessage = nil
            return false
        }

        let installedBikePoints = cachedSnapshot.bikePoints.filter { $0.isInstalled }
        guard !installedBikePoints.isEmpty else {
            staleDataWarningMessage = nil
            return false
        }

        allBikePoints = installedBikePoints
        lastUpdateTime = cachedSnapshot.savedAt
        updateVisibleBikePoints()
        updateStaleDataWarning(savedAt: cachedSnapshot.savedAt)

        if let dockId = pendingDockId,
           let bikePoint = installedBikePoints.first(where: { $0.id == dockId }) {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        }

        logger.warning("Using cached bike points due to TfL fetch issue: \(error.localizedDescription, privacy: .public)")
        scheduleTransientRetry()
        return true
    }

    private func updateStaleDataWarning(savedAt: Date?) {
        guard let savedAt else {
            staleDataWarningMessage = nil
            return
        }

        let cacheAge = Date().timeIntervalSince(savedAt)
        if cacheAge > AppConstants.App.staleDataWarningThreshold {
            staleDataWarningMessage = "We're having problems getting data from TfL. Dock information may be out of date."
        } else {
            staleDataWarningMessage = nil
        }
    }

    private func scheduleTransientRetry() {
        guard transientRetryTimer == nil else { return }

        logger.info("Starting transient map retry loop")
        transientRetryAttemptCount = 0
        transientRetryTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.App.mapTransientRetryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.transientRetryAttemptCount < 8 else {
                    self.logger.info("Stopping transient retry loop after max attempts")
                    self.stopTransientRetry()
                    return
                }
                guard !self.isLoading else { return }
                self.transientRetryAttemptCount += 1
                self.logger.info("Transient retry: attempting map refresh")
                self.loadBikePoints(cacheBusting: true)
            }
        }
    }

    private func stopTransientRetry() {
        transientRetryTimer?.invalidate()
        transientRetryTimer = nil
        transientRetryAttemptCount = 0
    }
    
    private func updateVisibleBikePoints() {
        guard !allBikePoints.isEmpty else { return }
        
        let centerLocation = CLLocation(latitude: currentMapCenter.latitude, longitude: currentMapCenter.longitude)
        
        // Calculate dynamic search distance based on zoom level
        // Smaller span (more zoomed in) = smaller search area
        let spanAverage = (currentMapSpan.latitudeDelta + currentMapSpan.longitudeDelta) / 2
        let dynamicDistance = max(500, min(3000, spanAverage * 50000)) // Between 500m and 3km
        
        // Filter bike points within dynamic distance and sort by distance
        let nearbyPointsWithDistance = allBikePoints
            .compactMap { bikePoint -> (BikePoint, CLLocationDistance)? in
                let pointLocation = CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon)
                let distance = centerLocation.distance(from: pointLocation)
                
                guard distance <= dynamicDistance else { return nil }
                return (bikePoint, distance)
            }
            .sorted { $0.1 < $1.1 } // Sort by distance
        
        // Check if we need to show zoom message (more points available than we can display)
        let totalNearbyPoints = nearbyPointsWithDistance.count
        shouldShowZoomMessage = totalNearbyPoints > maxVisiblePoints && spanAverage > 0.005 // Only show if not zoomed in enough
        
        // Take only the maximum number we can display
        let displayPoints = Array(nearbyPointsWithDistance.prefix(maxVisiblePoints).map { $0.0 })
        
        visibleBikePoints = displayPoints
    }
    
    deinit {
        updateTimer?.invalidate()
        backgroundUpdateTimer?.invalidate()
        transientRetryTimer?.invalidate()
    }
}
