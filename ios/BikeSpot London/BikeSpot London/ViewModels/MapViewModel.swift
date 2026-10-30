import Foundation
import SwiftUI
import MapKit
import Combine
import OSLog
import Observation

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
    let savedAt: Date?
    let tflDataStaleWarning: String?
}

@Observable
@MainActor
class MapViewModel {
    // MARK: - Published state (observed by SwiftUI views)

    var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )
    var visibleBikePoints: [MapBikePointSummary] = []
    var showsDetailedPins = true
    var shouldShowZoomMessage = false
    var lastUpdateTime: Date?
    var tflDataStaleWarning: String?

    // Inlined from BaseViewModel
    var isLoading = false

    // MARK: - Internal state (not observed)

    @ObservationIgnored private var locationService: LocationService?
    private var allBikePointsByID: [String: BikePoint] = [:]
    @ObservationIgnored private var allBikePointSummaries: [MapBikePointSummary] = []
    private let maxVisiblePoints = 50
    @ObservationIgnored private var currentMapCenter = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    @ObservationIgnored private var currentMapSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    @ObservationIgnored private var hasInitiallyeCentered = false
    @ObservationIgnored private var isSetup = false
    @ObservationIgnored private var hasPendingBikePointCenter = false
    @ObservationIgnored private var pendingDockId: String?
    @ObservationIgnored private var isMapInteractionActive = false
    @ObservationIgnored private var pendingProcessedMapData: ProcessedMapData?

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(subsystem: "com.myborisbikes.app", category: "MapViewModel")

    // MARK: - Setup

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

        let store = DockAvailabilityStore.shared
        store.$snapshot.sink { [weak self] snapshot in
            guard let self,
                  let processed = Self.processFetchedBikePoints(snapshot.allBikePoints,
                    savedAt: snapshot.oldestCheck(for: Array(snapshot.bikePointsByID.keys))) else { return }
            self.applyFreshProcessedMapData(processed)
        }.store(in: &cancellables)
        store.$isRefreshing.sink { [weak self] refreshing in
            self?.isLoading = refreshing
        }.store(in: &cancellables)
        store.refresh()
    }

    func refreshData() {
        logger.info("Manual refresh requested with cache busting")
        DockAvailabilityStore.shared.refresh(force: true)
    }

    // Tracks interaction without publishing camera state or rebuilding annotations per frame.
    func handleContinuousMapCameraChange(_ region: MKCoordinateRegion) {
        isMapInteractionActive = true
        currentMapCenter = region.center
        currentMapSpan = region.span
    }

    // Called from .onMapCameraChange(frequency: .onEnd) — fires once when panning settles.
    func handleMapCameraChange(_ region: MKCoordinateRegion) {
        isMapInteractionActive = false
        currentMapCenter = region.center
        currentMapSpan = region.span
        updateVisibleBikePoints()

        if let pendingProcessedMapData {
            self.pendingProcessedMapData = nil
            applyFreshProcessedMapData(pendingProcessedMapData)
        }
    }

    func endMapInteraction() {
        isMapInteractionActive = false
        if let pendingProcessedMapData {
            self.pendingProcessedMapData = nil
            applyFreshProcessedMapData(pendingProcessedMapData)
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
        updateRegion(for: CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon), showingDockDetail: true)
    }

    func centerOnBikePoint(id: String) {
        if let bikePoint = allBikePointsByID[id] {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        } else {
            pendingDockId = id
        }
    }

    var dockDirectory: [BikePoint] { Array(allBikePointsByID.values) }

    func bikePoint(for id: String) -> BikePoint? {
        allBikePointsByID[id]
    }

    // MARK: - Snapshot projection

    private func applyFreshProcessedMapData(_ processed: ProcessedMapData) {
        guard !isMapInteractionActive else {
            pendingProcessedMapData = processed
            return
        }

        allBikePointsByID = processed.bikePointsByID
        allBikePointSummaries = processed.summaries
        lastUpdateTime = processed.savedAt
        tflDataStaleWarning = processed.tflDataStaleWarning
        updateVisibleBikePoints()

        if let dockId = pendingDockId, let bikePoint = processed.bikePointsByID[dockId] {
            pendingDockId = nil
            centerOnBikePoint(bikePoint)
        }

        logger.info("Map data updated successfully")
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
        let shouldShowDetailedPins = spanAverage <= 0.012
        let visiblePointLimit = shouldShowDetailedPins ? 30 : maxVisiblePoints
        let dynamicDistance = max(500.0, min(3000.0, spanAverage * 50000.0))
        let maxDistanceSquared = dynamicDistance * dynamicDistance

        var closest: [(summary: MapBikePointSummary, distanceSquared: Double)] = []
        closest.reserveCapacity(visiblePointLimit)
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

            if closest.count < visiblePointLimit {
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

        let shouldShowZoom = totalNearbyPoints > visiblePointLimit && spanAverage > 0.005
        if showsDetailedPins != shouldShowDetailedPins {
            showsDetailedPins = shouldShowDetailedPins
        }
        if shouldShowZoomMessage != shouldShowZoom {
            shouldShowZoomMessage = shouldShowZoom
        }
        if visibleBikePoints != displayPoints {
            visibleBikePoints = displayPoints
        }
    }

    private func updateRegion(for location: CLLocation, showingDockDetail: Bool = false) {
        let newSpan = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        let newCenter = CLLocationCoordinate2D(
            latitude: location.coordinate.latitude - (showingDockDetail ? newSpan.latitudeDelta * 0.25 : 0),
            longitude: location.coordinate.longitude
        )

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
        savedAt: Date?
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

        let tflDataStaleWarning = detectTflApiStaleness(installedBikePoints, fetchedAt: savedAt ?? Date())

        return ProcessedMapData(
            bikePointsByID: bikePointsByID,
            summaries: summaries,
            savedAt: savedAt,
            tflDataStaleWarning: tflDataStaleWarning
        )
    }

    /// Returns a warning string when nearly all docks have old availability timestamps,
    /// indicating a TfL feed-wide stale data issue rather than normal per-dock variance.
    private static func detectTflApiStaleness(_ bikePoints: [BikePoint], fetchedAt: Date) -> String? {
        let staleRatio = BikePoint.staleAvailabilityDataRatio(
            in: bikePoints,
            fetchedAt: fetchedAt,
            staleAfter: AppConstants.App.tflApiStalenessThreshold
        )
        guard let staleRatio,
              staleRatio >= AppConstants.App.tflApiStaleDockWarningRatio else {
            return nil
        }

        return "Warning: TfL bike data may be out of date"
    }

}
