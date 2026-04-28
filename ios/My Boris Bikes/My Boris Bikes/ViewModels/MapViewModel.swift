import Foundation
import SwiftUI
import MapKit
import Combine
import OSLog

struct MapBikePointSummary: Identifiable, Equatable, Sendable {
    let id: String
    let commonName: String
    let lat: Double
    let lon: Double
    let standardBikes: Int
    let eBikes: Int
    let emptyDocks: Int
    let totalDocks: Int
    let isAvailable: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

private struct ProcessedMapData: Sendable {
    let bikePointsByID: [String: BikePoint]
    let summaries: [MapBikePointSummary]
    let savedAt: Date
    let monitoredDock: BikePoint?
}

@MainActor
class MapViewModel: BaseViewModel {
    enum FetchTrigger {
        case initial
        case manual
        case background
        case retry
    }

    @Published var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )
    @Published var visibleBikePoints: [MapBikePointSummary] = []
    @Published var shouldShowZoomMessage = false
    @Published var lastUpdateTime: Date?
    @Published var staleDataWarningMessage: String?

    private var locationService: LocationService?
    private var allBikePointsByID: [String: BikePoint] = [:]
    private var allBikePointSummaries: [MapBikePointSummary] = []
    private let maxVisiblePoints = 50
    private var currentMapCenter = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    private var currentMapSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    private var updateTimer: Timer?
    private var interactionIdleTimer: Timer?
    private var backgroundUpdateTimer: Timer?
    private var transientRetryTimer: Timer?
    private var activeFetchCancellable: AnyCancellable?
    private var currentFetchRequestID = 0
    private var transientRetryAttemptCount = 0
    private let logger = Logger(subsystem: "com.myborisbikes.app", category: "MapViewModel")
    private var hasInitiallyeCentered = false
    private var isSetup = false
    private var hasPendingBikePointCenter = false
    private var pendingDockId: String?
    private var isUserInteractingWithMap = false
    private var pendingProcessedMapData: ProcessedMapData?
    private var pendingFetchTrigger: FetchTrigger?

    func setup(locationService: LocationService) {
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
                if let self = self, !self.hasInitiallyeCentered && !self.hasPendingBikePointCenter {
                    self.logger.info("First location received, centering map")
                    self.hasInitiallyeCentered = true
                    self.updateRegion(for: location)
                } else {
                    self?.logger.info("Location updated but not auto-centering (already centered initially or centering on bike point)")
                }
            }
            .store(in: &cancellables)

        if locationService.authorizationStatus == .authorizedWhenInUse || locationService.authorizationStatus == .authorizedAlways {
            logger.info("Location already authorized, starting location updates")
            locationService.startLocationUpdates()
        } else {
            logger.info("Location not authorized, requesting permission")
            locationService.requestLocationPermission()
        }

        loadCachedBikePointsIfAvailable()
        observeNetworkChanges()
        loadBikePoints(trigger: .initial)
        startBackgroundUpdates()
    }

    func refreshData() {
        logger.info("Manual refresh requested with cache busting")
        loadBikePoints(trigger: .manual)
    }

    func handleMapCameraChange(_ region: MKCoordinateRegion) {
        currentMapCenter = region.center
        currentMapSpan = region.span
        isUserInteractingWithMap = true

        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateVisibleBikePoints()
            }
        }

        interactionIdleTimer?.invalidate()
        interactionIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.completeMapInteraction()
            }
        }
    }

    func centerOnNearestBikePoint() {
        guard let userCoordinate = locationService?.location?.coordinate else {
            logger.warning("No user location available - service: \(self.locationService != nil, privacy: .public)")
            return
        }

        guard let nearestBikePoint = allBikePointSummaries.min(by: {
            squaredDistanceMeters(from: userCoordinate, to: $0.coordinate)
                < squaredDistanceMeters(from: userCoordinate, to: $1.coordinate)
        }) else {
            logger.warning("No nearest bike point found")
            return
        }

        logger.info("Centering on nearest bike point: \(nearestBikePoint.commonName, privacy: .public)")
        updateRegion(for: CLLocation(latitude: nearestBikePoint.lat, longitude: nearestBikePoint.lon))
    }

    func centerOnUserLocation() {
        guard let userLocation = locationService?.location else {
            logger.warning("No user location available - service: \(self.locationService != nil, privacy: .public)")
            return
        }

        logger.info("Centering on location: \(userLocation.coordinate.latitude, privacy: .public), \(userLocation.coordinate.longitude, privacy: .public)")
        updateRegion(for: userLocation)
    }

    func centerOnBikePoint(_ bikePoint: BikePoint) {
        logger.info("Centering on bike point: \(bikePoint.commonName, privacy: .public)")
        hasPendingBikePointCenter = true
        hasInitiallyeCentered = true
        updateRegion(for: CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon))
    }

    func centerOnBikePoint(id: String) {
        if let bikePoint = allBikePointsByID[id] {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        } else {
            pendingDockId = id
        }
    }

    func bikePoint(for id: String) -> BikePoint? {
        allBikePointsByID[id]
    }

    private func startBackgroundUpdates() {
        backgroundUpdateTimer?.invalidate()
        let interval = backgroundRefreshInterval

        backgroundUpdateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.logger.info("Background update triggered")
                self?.loadBikePoints(trigger: .background)
            }
        }
        logger.info("Background updates started with interval: \(interval, privacy: .public)s")
    }

    private var backgroundRefreshInterval: TimeInterval {
        if TfLAPIService.shared.isConstrainedConnection {
            return 180
        }
        if TfLAPIService.shared.isExpensiveConnection {
            return 90
        }
        return AppConstants.App.refreshInterval
    }

    private var retryInterval: TimeInterval {
        let baseInterval = AppConstants.App.mapTransientRetryInterval
        if TfLAPIService.shared.isConstrainedConnection {
            return max(baseInterval * 4, 30)
        }
        if TfLAPIService.shared.isExpensiveConnection {
            return max(baseInterval * 2, 16)
        }
        return baseInterval
    }

    private func observeNetworkChanges() {
        TfLAPIService.shared.$isExpensiveConnection
            .combineLatest(TfLAPIService.shared.$isConstrainedConnection)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.logger.info(
                    "Network conditions changed. Expensive: \(TfLAPIService.shared.isExpensiveConnection, privacy: .public), constrained: \(TfLAPIService.shared.isConstrainedConnection, privacy: .public)"
                )
                self.startBackgroundUpdates()
                if self.transientRetryTimer != nil {
                    self.scheduleTransientRetry(forceRestart: true)
                }
            }
            .store(in: &cancellables)
    }

    private func loadBikePoints(trigger: FetchTrigger) {
        if isUserInteractingWithMap, trigger != .manual {
            logger.info("Deferring map fetch until interaction ends")
            pendingFetchTrigger = trigger
            return
        }

        if activeFetchCancellable != nil {
            if trigger == .manual {
                logger.info("Cancelling in-flight map request for manual refresh")
                activeFetchCancellable?.cancel()
                activeFetchCancellable = nil
                isLoading = false
            } else {
                logger.info("Skipping map fetch because another request is already in flight")
                return
            }
        }

        let cacheBusting = trigger == .manual
        currentFetchRequestID += 1
        let requestID = currentFetchRequestID
        isLoading = true
        clearError()

        if cacheBusting {
            logger.info("Loading bike points with cache busting")
        }

        activeFetchCancellable = TfLAPIService.shared
            .fetchAllBikePoints(
                cacheBusting: cacheBusting,
                timeoutInterval: AppConstants.App.mapFetchTimeout
            )
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    guard requestID == self.currentFetchRequestID else { return }
                    self.activeFetchCancellable = nil
                    self.isLoading = false

                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        let usedFallback = self.handleFetchFailure(error, trigger: trigger)
                        if !usedFallback {
                            self.setError(error)
                            self.scheduleTransientRetry()
                        }
                    }

                    self.runPendingFetchIfNeeded()
                },
                receiveValue: { [weak self] bikePoints in
                    guard let self else { return }
                    guard requestID == self.currentFetchRequestID else { return }

                    let monitoredDockID = DockArrivalMonitoringService.shared.monitoredDockID

                    DispatchQueue.global(qos: .userInitiated).async { [weak self, bikePoints] in
                        let processed = Self.processFetchedBikePoints(
                            bikePoints,
                            monitoredDockID: monitoredDockID,
                            savedAt: Date()
                        )

                        Task { @MainActor in
                            guard let self else { return }
                            guard requestID == self.currentFetchRequestID else { return }

                            guard let processed else {
                                let usedFallback = self.handleFetchFailure(NetworkError.noData, trigger: trigger)
                                if !usedFallback {
                                    self.setError(NetworkError.noData)
                                    self.scheduleTransientRetry()
                                }
                                return
                            }

                            self.applyProcessedMapData(processed)
                        }
                    }
                }
            )
    }

    private func loadCachedBikePointsIfAvailable() {
        guard let cachedSnapshot = AllBikePointsCache.shared.loadSnapshot() else { return }

        guard let processed = Self.processFetchedBikePoints(
            cachedSnapshot.bikePoints,
            monitoredDockID: DockArrivalMonitoringService.shared.monitoredDockID,
            savedAt: cachedSnapshot.savedAt ?? Date()
        ) else {
            return
        }

        allBikePointsByID = processed.bikePointsByID
        allBikePointSummaries = processed.summaries
        lastUpdateTime = cachedSnapshot.savedAt
        updateVisibleBikePoints()
        logger.info("Loaded \(processed.summaries.count, privacy: .public) cached bike points for map startup")
    }

    private func applyProcessedMapData(_ processed: ProcessedMapData) {
        if isUserInteractingWithMap {
            logger.info("Deferring map data application until interaction ends")
            pendingProcessedMapData = processed
            return
        }

        applyFreshProcessedMapData(processed)
    }

    private func applyFreshProcessedMapData(_ processed: ProcessedMapData) {
        allBikePointsByID = processed.bikePointsByID
        allBikePointSummaries = processed.summaries
        lastUpdateTime = processed.savedAt
        staleDataWarningMessage = nil
        AllBikePointsCache.shared.save(Array(processed.bikePointsByID.values), savedAt: processed.savedAt)
        updateVisibleBikePoints()
        stopTransientRetry()

        if let monitoredDock = processed.monitoredDock {
            DockArrivalMonitoringService.shared.updateMonitoredDockIfNeeded(using: monitoredDock)
        }

        if let dockId = pendingDockId, let bikePoint = processed.bikePointsByID[dockId] {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        }

        logger.info("Map data updated successfully")
        clearErrorOnSuccess()
    }

    private func handleFetchFailure(_ error: Error, trigger: FetchTrigger) -> Bool {
        if isUserInteractingWithMap {
            pendingProcessedMapData = nil
        }

        if !allBikePointsByID.isEmpty {
            logger.warning("Keeping in-memory bike points due to TfL fetch issue: \(error.localizedDescription, privacy: .public)")
            updateStaleDataWarning(savedAt: lastUpdateTime)
            if trigger != .manual {
                scheduleTransientRetry()
            }
            return true
        }

        guard let cachedSnapshot = AllBikePointsCache.shared.loadSnapshot(),
              let processed = Self.processFetchedBikePoints(
                cachedSnapshot.bikePoints,
                monitoredDockID: DockArrivalMonitoringService.shared.monitoredDockID,
                savedAt: cachedSnapshot.savedAt ?? Date()
              ) else {
            staleDataWarningMessage = nil
            return false
        }

        allBikePointsByID = processed.bikePointsByID
        allBikePointSummaries = processed.summaries
        lastUpdateTime = cachedSnapshot.savedAt
        updateVisibleBikePoints()
        updateStaleDataWarning(savedAt: cachedSnapshot.savedAt)

        if let monitoredDock = processed.monitoredDock {
            DockArrivalMonitoringService.shared.updateMonitoredDockIfNeeded(using: monitoredDock)
        }

        if let dockId = pendingDockId, let bikePoint = processed.bikePointsByID[dockId] {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        }

        logger.warning("Using cached bike points due to TfL fetch issue: \(error.localizedDescription, privacy: .public)")
        if trigger != .manual {
            scheduleTransientRetry()
        }
        return true
    }

    private func updateStaleDataWarning(savedAt: Date?) {
        guard let savedAt else {
            staleDataWarningMessage = nil
            return
        }

        let cacheAge = Date().timeIntervalSince(savedAt)
        staleDataWarningMessage = cacheAge > AppConstants.App.staleDataWarningThreshold
            ? "We're having problems getting data from TfL. Dock information may be out of date."
            : nil
    }

    private func scheduleTransientRetry(forceRestart: Bool = false) {
        if forceRestart {
            stopTransientRetry()
        } else if transientRetryTimer != nil {
            return
        }

        logger.info("Starting transient map retry loop")
        transientRetryAttemptCount = 0
        transientRetryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.transientRetryAttemptCount < 8 else {
                    self.logger.info("Stopping transient retry loop after max attempts")
                    self.stopTransientRetry()
                    return
                }
                guard self.activeFetchCancellable == nil else { return }
                self.transientRetryAttemptCount += 1
                self.logger.info("Transient retry: attempting map refresh")
                self.loadBikePoints(trigger: .retry)
            }
        }
    }

    private func stopTransientRetry() {
        transientRetryTimer?.invalidate()
        transientRetryTimer = nil
        transientRetryAttemptCount = 0
    }

    private func completeMapInteraction() {
        isUserInteractingWithMap = false
        updateVisibleBikePoints()

        if let pendingProcessedMapData {
            self.pendingProcessedMapData = nil
            applyFreshProcessedMapData(pendingProcessedMapData)
        }

        runPendingFetchIfNeeded()
    }

    private func runPendingFetchIfNeeded() {
        guard activeFetchCancellable == nil, !isUserInteractingWithMap, let pendingFetchTrigger else { return }
        self.pendingFetchTrigger = nil
        loadBikePoints(trigger: pendingFetchTrigger)
    }

    private func updateVisibleBikePoints() {
        guard !allBikePointSummaries.isEmpty else {
            if !visibleBikePoints.isEmpty {
                visibleBikePoints = []
            }
            shouldShowZoomMessage = false
            return
        }

        let spanAverage = (currentMapSpan.latitudeDelta + currentMapSpan.longitudeDelta) / 2
        let dynamicDistance = max(500.0, min(3000.0, spanAverage * 50000.0))
        let maxDistanceSquared = dynamicDistance * dynamicDistance

        var closest: [(summary: MapBikePointSummary, distanceSquared: Double)] = []
        closest.reserveCapacity(maxVisiblePoints)
        var totalNearbyPoints = 0
        var farthestIndex = 0
        var farthestDistanceSquared = -1.0

        for summary in allBikePointSummaries {
            let distanceSquared = squaredDistanceMeters(
                from: currentMapCenter,
                to: summary.coordinate
            )

            guard distanceSquared <= maxDistanceSquared else { continue }
            totalNearbyPoints += 1

            if closest.count < maxVisiblePoints {
                closest.append((summary, distanceSquared))
                if distanceSquared > farthestDistanceSquared {
                    farthestDistanceSquared = distanceSquared
                    farthestIndex = closest.count - 1
                }
                continue
            }

            guard distanceSquared < farthestDistanceSquared else { continue }
            closest[farthestIndex] = (summary, distanceSquared)

            farthestIndex = 0
            farthestDistanceSquared = closest[0].distanceSquared
            for index in closest.indices where closest[index].distanceSquared > farthestDistanceSquared {
                farthestDistanceSquared = closest[index].distanceSquared
                farthestIndex = index
            }
        }

        let displayPoints = closest
            .sorted { $0.distanceSquared < $1.distanceSquared }
            .map(\.summary)

        let shouldShowZoom = totalNearbyPoints > maxVisiblePoints && spanAverage > 0.005
        if shouldShowZoomMessage != shouldShowZoom {
            shouldShowZoomMessage = shouldShowZoom
        }
        if visibleBikePoints != displayPoints {
            visibleBikePoints = displayPoints
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

        updateVisibleBikePoints()
    }

    private func squaredDistanceMeters(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> Double {
        let metersPerDegreeLatitude = 111_320.0
        let averageLatitudeRadians = ((source.latitude + destination.latitude) * 0.5) * .pi / 180
        let metersPerDegreeLongitude = max(1, cos(averageLatitudeRadians) * metersPerDegreeLatitude)

        let deltaLatitudeMeters = (destination.latitude - source.latitude) * metersPerDegreeLatitude
        let deltaLongitudeMeters = (destination.longitude - source.longitude) * metersPerDegreeLongitude
        return (deltaLatitudeMeters * deltaLatitudeMeters) + (deltaLongitudeMeters * deltaLongitudeMeters)
    }

    private static func processFetchedBikePoints(
        _ bikePoints: [BikePoint],
        monitoredDockID: String?,
        savedAt: Date
    ) -> ProcessedMapData? {
        let installedBikePoints = bikePoints.filter(\.isInstalled)
        guard !installedBikePoints.isEmpty else { return nil }

        let bikePointsByID = Dictionary(uniqueKeysWithValues: installedBikePoints.map { ($0.id, $0) })
        let summaries = installedBikePoints.map { bikePoint in
            MapBikePointSummary(
                id: bikePoint.id,
                commonName: bikePoint.commonName,
                lat: bikePoint.lat,
                lon: bikePoint.lon,
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptyDocks: bikePoint.emptyDocks,
                totalDocks: bikePoint.totalDocks,
                isAvailable: bikePoint.isAvailable
            )
        }

        return ProcessedMapData(
            bikePointsByID: bikePointsByID,
            summaries: summaries,
            savedAt: savedAt,
            monitoredDock: monitoredDockID.flatMap { bikePointsByID[$0] }
        )
    }

    deinit {
        updateTimer?.invalidate()
        interactionIdleTimer?.invalidate()
        backgroundUpdateTimer?.invalidate()
        transientRetryTimer?.invalidate()
        activeFetchCancellable?.cancel()
    }
}
