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
    private var lastRoutineLocationLogAt: Date?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 5
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        monitoredDock = loadPersistedDock()
    }

    func requestAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
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
        lastRoutineLocationLogAt = nil
        logLocationEvent("monitor_begin", dock: dock, message: "Preparing dock arrival monitoring")

        guard isEnabled else {
            logger.info("Dock arrival monitoring preference is disabled; skipping monitoring for dock \(dock.dockId)")
            locationManager.stopUpdatingLocation()
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

        locationManager.stopUpdatingLocation()
        isSendingArrivalRequest = false
        lastArrivalAttemptAt = nil
        lastRoutineLocationLogAt = nil

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
        guard monitoredDock != nil else { return }

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

        logger.info("Starting background-capable location updates for dock arrival monitoring")
        logLocationEvent(
            "location_updates_started",
            dock: monitoredDock,
            message: "Started CLLocationManager updates",
            raw: ["authorizationStatus": authorizationStatusLabel(authorizationStatus)]
        )
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
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
        guard shouldAttemptArrival(for: location) else { return }

        let dockLocation = CLLocation(latitude: dock.latitude, longitude: dock.longitude)
        let distance = location.distance(from: dockLocation)
        let arrivalDistanceThreshold = LiveActivityArrivalSettings.configuredArrivalDistanceMeters()

        logger.info("Dock arrival check for \(dock.dockId, privacy: .public): \(distance, privacy: .public)m away")
        if lastRoutineLocationLogAt == nil || Date().timeIntervalSince(lastRoutineLocationLogAt!) >= 5 {
            lastRoutineLocationLogAt = Date()
            logLocationEvent(
                "location_update",
                dock: dock,
                location: location,
                distanceMeters: distance,
                message: "Evaluated dock arrival distance"
            )
        }

        guard distance <= arrivalDistanceThreshold else {
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

    private func notifyServerOfArrival(for dock: MonitoredDock) async {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("Cannot end live activity on arrival because APNs device token is unavailable")
            isSendingArrivalRequest = false
            logLocationEvent("arrival_request_failed", dock: dock, message: "APNs device token unavailable")
            return
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
                return
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
        } catch {
            logger.error("Failed to notify server of dock arrival: \(error.localizedDescription)")
            isSendingArrivalRequest = false
            logLocationEvent(
                "arrival_request_failed",
                dock: dock,
                message: "Network error: \(error.localizedDescription)"
            )
        }
    }

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

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Dock arrival monitoring location error: \(error.localizedDescription)")
        logLocationEvent("location_error", dock: monitoredDock, message: error.localizedDescription)
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
            locationManager.stopUpdatingLocation()
            logLocationEvent(
                "authorization_unavailable",
                dock: monitoredDock,
                message: "Location permission unavailable after authorization change"
            )
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
