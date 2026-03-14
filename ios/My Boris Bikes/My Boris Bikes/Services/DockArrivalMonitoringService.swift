import CoreLocation
import Foundation
import UIKit
import os.log

final class DockArrivalMonitoringService: NSObject {
    struct MonitoredDock: Codable, Equatable {
        let dockId: String
        let dockName: String
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static let shared = DockArrivalMonitoringService()

    private static let regionIdentifierPrefix = "live-activity-arrival-region-"
    private let monitoredDockStorageKey = "liveActivityArrivalMonitoredDock"
    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "DockArrival")
    private let locationManager = CLLocationManager()
    private let serverEventSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private var monitoredDock: MonitoredDock?
    private var isSendingArrivalRequest = false
    private var lastArrivalAttemptAt: Date?
    private var confirmationStartedAt: Date?
    private var firstPreciseInsideThresholdAt: Date?
    private var hasRequestedAlwaysAuthorizationThisSession = false

    private override init() {
        super.init()
        locationManager.delegate = self
        configureLowPowerTrackingProfile()
        locationManager.allowsBackgroundLocationUpdates = true
        monitoredDock = loadPersistedDock()
    }

    func requestAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            guard !hasRequestedAlwaysAuthorizationThisSession else {
                logger.info("Skipping repeated Always authorization request because iOS ignores subsequent calls in the same session")
                logLocationEvent(
                    "authorization_request_skipped",
                    message: "Always authorization already requested this session",
                    raw: ["authorizationStatus": authorizationStatusLabel(locationManager.authorizationStatus)]
                )
                return
            }

            hasRequestedAlwaysAuthorizationThisSession = true
            logger.info("Requesting Always location authorization for dock arrival monitoring")
            logLocationEvent(
                "authorization_requested",
                message: "Requesting Always location authorization",
                raw: ["authorizationStatus": authorizationStatusLabel(locationManager.authorizationStatus)]
            )
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            logger.warning("Dock arrival monitoring unavailable because Always location access was denied or restricted")
            logLocationEvent(
                "authorization_unavailable",
                message: "Always location authorization denied or restricted",
                raw: ["authorizationStatus": authorizationStatusLabel(locationManager.authorizationStatus)]
            )
        @unknown default:
            logger.warning("Dock arrival monitoring encountered unknown location authorization status")
        }
    }

    func beginMonitoring(for bikePoint: BikePoint) {
        let dock = MonitoredDock(
            dockId: bikePoint.id,
            dockName: bikePoint.commonName,
            latitude: bikePoint.lat,
            longitude: bikePoint.lon
        )

        monitoredDock = dock
        persistDock(dock)
        lastArrivalAttemptAt = nil
        isSendingArrivalRequest = false
        confirmationStartedAt = nil
        firstPreciseInsideThresholdAt = nil
        logLocationEvent("monitor_begin", dock: dock, message: "Preparing dock arrival monitoring")

        guard isEnabled else {
            logger.info("Dock arrival monitoring preference is disabled; skipping monitoring for dock \(dock.dockId)")
            stopPreciseLocationUpdates()
            stopMonitoringDockRegion()
            logLocationEvent("monitor_skipped_disabled", dock: dock, message: "Arrival monitoring disabled in preferences")
            return
        }

        requestAuthorizationIfNeeded()
        startMonitoringIfPossible()
    }

    func restoreMonitoringIfNeeded(activeDockIds: Set<String>) {
        guard isEnabled else {
            stopMonitoring(reason: "preference_disabled", preserveDock: true)
            return
        }

        guard let dock = monitoredDock ?? loadPersistedDock() else {
            return
        }

        guard activeDockIds.contains(dock.dockId) else {
            stopMonitoring(reason: "no_active_live_activity")
            return
        }

        monitoredDock = dock
        logLocationEvent("monitor_restore", dock: dock, message: "Restored dock arrival monitoring state")
        requestAuthorizationIfNeeded()
        startMonitoringIfPossible()
    }

    func stopMonitoring(for dockId: String? = nil, reason: String, preserveDock: Bool = false) {
        if let dockId, monitoredDock?.dockId != dockId {
            return
        }

        if let activeDock = monitoredDock {
            logger.info("Stopping dock arrival monitoring for dock \(activeDock.dockId, privacy: .public) (\(reason, privacy: .public))")
        }
        logLocationEvent("monitor_stop", dock: monitoredDock, message: reason)

        stopPreciseLocationUpdates()
        stopMonitoringDockRegion()
        isSendingArrivalRequest = false
        lastArrivalAttemptAt = nil
        confirmationStartedAt = nil
        firstPreciseInsideThresholdAt = nil

        if !preserveDock {
            monitoredDock = nil
            AppConstants.UserDefaults.sharedDefaults.removeObject(forKey: monitoredDockStorageKey)
        }
    }

    func handlePreferenceChange(activeDockIds: Set<String>) {
        if isEnabled {
            restoreMonitoringIfNeeded(activeDockIds: activeDockIds)
        } else {
            stopMonitoring(reason: "preference_disabled", preserveDock: true)
        }
    }

    func updateMonitoredDockIfNeeded(using bikePoint: BikePoint) {
        guard var dock = monitoredDock, dock.dockId == bikePoint.id else { return }

        guard dock.latitude != bikePoint.lat || dock.longitude != bikePoint.lon || dock.dockName != bikePoint.commonName else {
            return
        }

        dock = MonitoredDock(
            dockId: bikePoint.id,
            dockName: bikePoint.commonName,
            latitude: bikePoint.lat,
            longitude: bikePoint.lon
        )
        monitoredDock = dock
        persistDock(dock)
        logLocationEvent(
            "monitor_dock_updated",
            dock: dock,
            message: "Updated monitored dock coordinates from latest bike point data",
            raw: [
                "latitude": dock.latitude,
                "longitude": dock.longitude
            ]
        )

        if isEnabled {
            startMonitoringIfPossible()
        }
    }

    private var isEnabled: Bool {
        let defaults = LiveActivityArrivalSettings.userDefaultsStore
        return defaults.object(forKey: LiveActivityArrivalSettings.enabledKey) as? Bool
            ?? LiveActivityArrivalSettings.defaultEnabled
    }

    private var debugDeviceIdentifier: String? {
        DeviceTokenHelper.apnsDeviceToken ?? DeviceTokenHelper.analyticsDeviceToken
    }

    private func persistDock(_ dock: MonitoredDock) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(dock) else { return }
        AppConstants.UserDefaults.sharedDefaults.set(data, forKey: monitoredDockStorageKey)
    }

    private func loadPersistedDock() -> MonitoredDock? {
        guard let data = AppConstants.UserDefaults.sharedDefaults.data(forKey: monitoredDockStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(MonitoredDock.self, from: data)
    }

    private func startMonitoringIfPossible() {
        guard let dock = monitoredDock else { return }

        let authorizationStatus = locationManager.authorizationStatus
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            logger.info("Dock arrival monitoring waiting for location authorization")
            logLocationEvent(
                "monitor_waiting_for_authorization",
                dock: monitoredDock,
                message: "Waiting for location authorization",
                raw: ["authorizationStatus": authorizationStatusLabel(authorizationStatus)]
            )
            return
        }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            logger.warning("Dock arrival region monitoring is unavailable; falling back to precise location updates")
            logLocationEvent(
                "region_monitoring_unavailable",
                dock: dock,
                message: "Region monitoring unavailable; using precise updates fallback"
            )
            startPreciseLocationUpdates(reason: "region_monitoring_unavailable")
            return
        }

        stopPreciseLocationUpdates()
        stopMonitoringDockRegion()
        startMonitoringDockRegion(for: dock)
        locationManager.requestLocation()

        logger.info("Starting low-power region monitoring for dock arrival monitoring")
        logLocationEvent(
            "location_updates_started",
            dock: dock,
            message: "Started dock region monitoring",
            raw: ["authorizationStatus": authorizationStatusLabel(authorizationStatus)]
        )
    }

    private func shouldAttemptArrival(for location: CLLocation) -> Bool {
        if location.horizontalAccuracy < 0 {
            return false
        }

        if location.horizontalAccuracy > LiveActivityArrivalSettings.maximumAcceptedHorizontalAccuracyMeters {
            logger.info("Ignoring imprecise location update for dock arrival monitoring (accuracy: \(location.horizontalAccuracy, privacy: .public)m)")
            logLocationEvent(
                "location_ignored_imprecise",
                dock: monitoredDock,
                location: location,
                message: "Horizontal accuracy too low for arrival detection"
            )
            return false
        }

        if let lastArrivalAttemptAt,
           Date().timeIntervalSince(lastArrivalAttemptAt) < LiveActivityArrivalSettings.minimumRetryIntervalSeconds {
            return false
        }

        return true
    }

    private func checkArrival(with location: CLLocation) {
        guard let dock = monitoredDock else { return }

        let dockLocation = CLLocation(latitude: dock.latitude, longitude: dock.longitude)
        let distance = location.distance(from: dockLocation)
        let arrivalDistanceThreshold = LiveActivityArrivalSettings.configuredArrivalDistanceMeters()
        let activationDistanceThreshold = configuredRegionRadiusMeters()
        let resetDistanceThreshold = arrivalDistanceThreshold + LiveActivityArrivalSettings.confirmationResetHysteresisMeters

        logger.info("Dock arrival check for \(dock.dockId, privacy: .public): \(distance, privacy: .public)m away")

        if confirmationStartedAt == nil, distance <= activationDistanceThreshold {
            startPreciseLocationUpdates(reason: "location_within_activation_distance")
        }

        guard shouldAttemptArrival(for: location) else { return }

        guard let confirmationStartedAt else {
            logger.info("Ignoring precise location update because confirmation mode is inactive")
            return
        }

        if Date().timeIntervalSince(confirmationStartedAt) >= LiveActivityArrivalSettings.confirmationTimeoutSeconds {
            logger.info("Dock arrival confirmation timed out for dock \(dock.dockId, privacy: .public); reverting to region monitoring")
            logLocationEvent(
                "arrival_confirmation_timeout",
                dock: dock,
                location: location,
                distanceMeters: distance,
                message: "Precise confirmation window expired"
            )
            stopPreciseLocationUpdates()
            return
        }

        guard distance <= resetDistanceThreshold else {
            if firstPreciseInsideThresholdAt != nil {
                logger.info("Dock arrival confirmation reset because user moved outside threshold window")
                logLocationEvent(
                    "arrival_confirmation_reset",
                    dock: dock,
                    location: location,
                    distanceMeters: distance,
                    message: "Moved outside confirmation threshold"
                )
            }
            firstPreciseInsideThresholdAt = nil
            return
        }

        guard distance <= arrivalDistanceThreshold else {
            firstPreciseInsideThresholdAt = nil
            return
        }

        if firstPreciseInsideThresholdAt == nil {
            firstPreciseInsideThresholdAt = Date()
            logLocationEvent(
                "arrival_confirmation_started",
                dock: dock,
                location: location,
                distanceMeters: distance,
                message: "First precise in-threshold location received"
            )
            return
        }

        guard Date().timeIntervalSince(firstPreciseInsideThresholdAt ?? Date()) >= LiveActivityArrivalSettings.confirmationDwellTimeSeconds else {
            return
        }

        isSendingArrivalRequest = true
        lastArrivalAttemptAt = Date()
        logLocationEvent(
            "arrival_threshold_met",
            dock: dock,
            location: location,
            distanceMeters: distance,
            message: "Arrival distance threshold met"
        )

        Task {
            await notifyServerOfArrival(for: dock)
        }
    }

    @discardableResult
    private func notifyServerOfArrival(for dock: MonitoredDock) async -> Bool {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("Cannot end live activity on arrival because APNs device token is unavailable")
            isSendingArrivalRequest = false
            logLocationEvent("arrival_request_failed", dock: dock, message: "APNs device token unavailable")
            return false
        }

        let body: [String: Any] = [
            "dockId": dock.dockId,
            "deviceToken": deviceToken,
            "buildType": PushEnvironment.buildType,
        ]

        logLocationEvent("arrival_request_started", dock: dock, message: "Sending arrival request to server")

        do {
            let httpResponse = try await postJSON(
                path: AppConstants.Server.liveActivityArrivalEndpoint,
                body: body,
                requestHeaderToken: deviceToken,
                backgroundTaskName: "dock-arrival-request"
            )

            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Unexpected status \(httpResponse.statusCode) when ending live activity on arrival")
                isSendingArrivalRequest = false
                logLocationEvent(
                    "arrival_request_failed",
                    dock: dock,
                    message: "Server returned HTTP \(httpResponse.statusCode)"
                )
                return false
            }

            logger.info("Server confirmed dock arrival for dock \(dock.dockId, privacy: .public); ending local live activity")
            logLocationEvent("arrival_request_succeeded", dock: dock, message: "Server accepted arrival request")
            AnalyticsService.shared.track(
                action: .liveActivityEnd,
                screen: .app,
                dock: AnalyticsDockInfo(id: dock.dockId, name: dock.dockName),
                metadata: ["reason": "arrival"]
            )

            await MainActor.run {
                LiveActivityService.shared.endLiveActivity(for: dock.dockId, skipServerUnregister: true)
            }
            stopMonitoring(reason: "arrival_confirmed")
            await LiveActivityService.shared.refreshNotificationStatusFromServer()
            return true
        } catch {
            logger.error("Failed to notify server of dock arrival: \(error.localizedDescription)")
            isSendingArrivalRequest = false
            logLocationEvent(
                "arrival_request_failed",
                dock: dock,
                message: "Network error: \(error.localizedDescription)"
            )
            return false
        }
    }

#if DEBUG
    func debugSimulateArrival(dockId: String, dockName: String) async -> (success: Bool, message: String) {
        let dock = MonitoredDock(
            dockId: dockId,
            dockName: dockName,
            latitude: 0,
            longitude: 0
        )

        isSendingArrivalRequest = true
        lastArrivalAttemptAt = Date()

        let success = await notifyServerOfArrival(for: dock)
        let message = success
            ? "Simulated arrival for \(dockName)."
            : "Simulated arrival failed for \(dockName). Check server logs and push events."
        return (success, message)
    }
#endif

    private func postJSON(
        path: String,
        body: [String: Any],
        requestHeaderToken: String?,
        backgroundTaskName: String
    ) async throws -> HTTPURLResponse {
        let urlString = "\(AppConstants.Server.baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let requestHeaderToken {
            request.setValue(requestHeaderToken, forHTTPHeaderField: "X-Device-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let backgroundTaskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: backgroundTaskName) { [logger] in
                logger.warning("Background task expired while sending \(backgroundTaskName, privacy: .public)")
            }
        }
        defer {
            Task { @MainActor in
                guard backgroundTaskId != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
            }
        }

        let (_, response) = try await serverEventSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse
    }

    private func logLocationEvent(
        _ event: String,
        dock: MonitoredDock? = nil,
        location: CLLocation? = nil,
        distanceMeters: CLLocationDistance? = nil,
        message: String? = nil,
        raw: [String: Any] = [:]
    ) {
        let activeDock = dock ?? monitoredDock
        let payloadDeviceId = debugDeviceIdentifier
        let clientTimestamp = ISO8601DateFormatter().string(from: Date())
        let arrivalThresholdMeters = LiveActivityArrivalSettings.configuredArrivalDistanceMeters()

        guard shouldUploadDebugEvent(event) else { return }

        Task {
            var body: [String: Any] = [
                "event": event,
                "clientTimestamp": clientTimestamp,
                "appState": await MainActor.run { self.applicationStateLabel() },
                "arrivalThresholdMeters": arrivalThresholdMeters,
                "authorizationStatus": authorizationStatusLabel(locationManager.authorizationStatus),
            ]

            if let payloadDeviceId {
                body["deviceId"] = payloadDeviceId
            }
            if let activeDock {
                body["dockId"] = activeDock.dockId
                body["dockName"] = activeDock.dockName
            }
            if let location {
                body["horizontalAccuracyMeters"] = location.horizontalAccuracy
            }
            if let distanceMeters {
                body["distanceMeters"] = distanceMeters
            }
            if let message {
                body["message"] = message
            }
            if !raw.isEmpty {
                body["raw"] = raw
            }

            do {
                let httpResponse = try await postJSON(
                    path: AppConstants.Server.backgroundLocationEventEndpoint,
                    body: body,
                    requestHeaderToken: payloadDeviceId,
                    backgroundTaskName: "dock-arrival-debug"
                )
                if !(200...299).contains(httpResponse.statusCode) {
                    logger.warning("Background location debug event returned HTTP \(httpResponse.statusCode)")
                }
            } catch {
                logger.error("Failed to send background location debug event: \(error.localizedDescription)")
            }
        }
    }

    private func applicationStateLabel() -> String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func dockRegionIdentifier(for dockId: String) -> String {
        "\(Self.regionIdentifierPrefix)\(dockId)"
    }

    private func configuredRegionRadiusMeters() -> CLLocationDistance {
        let threshold = LiveActivityArrivalSettings.configuredArrivalDistanceMeters()
        let radius = max(
            threshold + LiveActivityArrivalSettings.regionRadiusBufferMeters,
            LiveActivityArrivalSettings.highFrequencyActivationDistanceMeters
        )
        return min(radius, locationManager.maximumRegionMonitoringDistance)
    }

    private func configureLowPowerTrackingProfile() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    private func configureHighPowerTrackingProfile() {
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 5
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func stopMonitoringDockRegion() {
        for region in locationManager.monitoredRegions {
            guard region.identifier.hasPrefix(Self.regionIdentifierPrefix) else { continue }
            locationManager.stopMonitoring(for: region)
        }
    }

    private func startMonitoringDockRegion(for dock: MonitoredDock) {
        let region = CLCircularRegion(
            center: dock.coordinate,
            radius: configuredRegionRadiusMeters(),
            identifier: dockRegionIdentifier(for: dock.dockId)
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true

        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
        logLocationEvent(
            "region_monitoring_started",
            dock: dock,
            message: "Monitoring near-dock activation region",
            raw: ["radiusMeters": configuredRegionRadiusMeters()]
        )
    }

    private func startPreciseLocationUpdates(reason: String) {
        guard monitoredDock != nil else { return }
        guard !isSendingArrivalRequest else { return }

        configureHighPowerTrackingProfile()

        if confirmationStartedAt == nil {
            confirmationStartedAt = Date()
            firstPreciseInsideThresholdAt = nil
            logLocationEvent(
                "precise_updates_started",
                dock: monitoredDock,
                message: "Started precise location confirmation",
                raw: ["reason": reason]
            )
        }

        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
    }

    private func stopPreciseLocationUpdates() {
        locationManager.stopUpdatingLocation()
        configureLowPowerTrackingProfile()
        confirmationStartedAt = nil
        firstPreciseInsideThresholdAt = nil
    }

    private func handleDockRegionEntry(reason: String, region: CLRegion?) {
        guard let dock = monitoredDock else { return }
        logger.info("Entered dock monitoring region for \(dock.dockId, privacy: .public) (\(reason, privacy: .public))")
        logLocationEvent(
            "region_entered",
            dock: dock,
            message: "Near-dock activation region triggered",
            raw: [
                "reason": reason,
                "regionIdentifier": region?.identifier ?? "unknown"
            ]
        )
        startPreciseLocationUpdates(reason: reason)
    }

    private func handleDockRegionExit(reason: String, region: CLRegion?) {
        guard let dock = monitoredDock else { return }
        logger.info("Exited dock monitoring region for \(dock.dockId, privacy: .public) (\(reason, privacy: .public))")
        if confirmationStartedAt != nil || firstPreciseInsideThresholdAt != nil {
            logLocationEvent(
                "region_exited",
                dock: dock,
                message: "Left near-dock activation region; stopping precise confirmation",
                raw: [
                    "reason": reason,
                    "regionIdentifier": region?.identifier ?? "unknown"
                ]
            )
        }
        stopPreciseLocationUpdates()
    }

    private func shouldUploadDebugEvent(_ event: String) -> Bool {
        switch event {
        case "location_update", "location_ignored_imprecise":
            return false
        default:
            return true
        }
    }

    private func authorizationStatusLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorizedAlways"
        case .authorizedWhenInUse:
            return "authorizedWhenInUse"
        @unknown default:
            return "unknown"
        }
    }
}

extension DockArrivalMonitoringService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isSendingArrivalRequest else { return }
        guard let latestLocation = locations.last else { return }
        checkArrival(with: latestLocation)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(Self.regionIdentifierPrefix) else { return }
        handleDockRegionEntry(reason: "didEnterRegion", region: region)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier.hasPrefix(Self.regionIdentifierPrefix) else { return }
        handleDockRegionExit(reason: "didExitRegion", region: region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(Self.regionIdentifierPrefix) else { return }

        switch state {
        case .inside:
            handleDockRegionEntry(reason: "didDetermineState_inside", region: region)
        case .outside:
            handleDockRegionExit(reason: "didDetermineState_outside", region: region)
        case .unknown:
            logger.info("Dock arrival region state is unknown for \(region.identifier, privacy: .public)")
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Dock arrival monitoring location error: \(error.localizedDescription)")
        logLocationEvent("location_error", dock: monitoredDock, message: error.localizedDescription)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        logger.error("Dock arrival region monitoring failed: \(error.localizedDescription)")
        logLocationEvent(
            "region_monitoring_failed",
            dock: monitoredDock,
            message: error.localizedDescription,
            raw: ["regionIdentifier": region?.identifier ?? "unknown"]
        )
        startPreciseLocationUpdates(reason: "region_monitoring_failed")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Dock arrival monitoring authorization changed to \(status.rawValue)")
        logLocationEvent(
            "authorization_changed",
            dock: monitoredDock,
            message: authorizationStatusLabel(status)
        )

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            startMonitoringIfPossible()
        case .denied, .restricted:
            logger.warning("Dock arrival monitoring disabled because location permission is unavailable")
            stopPreciseLocationUpdates()
            stopMonitoringDockRegion()
            logLocationEvent(
                "authorization_unavailable",
                dock: monitoredDock,
                message: "Location permission unavailable after authorization change"
            )
        case .notDetermined:
            hasRequestedAlwaysAuthorizationThisSession = false
            break
        @unknown default:
            break
        }
    }
}
