import CoreLocation
import Foundation
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

    private var monitoredDock: MonitoredDock?
    private var isSendingArrivalRequest = false
    private var lastArrivalAttemptAt: Date?

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
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            logger.warning("Dock arrival monitoring unavailable because Always location access was denied or restricted")
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

        guard isEnabled else {
            logger.info("Dock arrival monitoring preference is disabled; skipping monitoring for dock \(dock.dockId)")
            locationManager.stopUpdatingLocation()
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

        locationManager.stopUpdatingLocation()
        isSendingArrivalRequest = false
        lastArrivalAttemptAt = nil

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
            return
        }

        logger.info("Starting background-capable location updates for dock arrival monitoring")
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
    }

    private func shouldAttemptArrival(for location: CLLocation) -> Bool {
        if location.horizontalAccuracy < 0 {
            return false
        }

        if location.horizontalAccuracy > LiveActivityArrivalSettings.maximumAcceptedHorizontalAccuracyMeters {
            logger.info("Ignoring imprecise location update for dock arrival monitoring (accuracy: \(location.horizontalAccuracy, privacy: .public)m)")
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

        logger.info("Dock arrival check for \(dock.dockId, privacy: .public): \(distance, privacy: .public)m away")

        guard distance <= LiveActivityArrivalSettings.arrivalDistanceMeters else {
            return
        }

        isSendingArrivalRequest = true
        lastArrivalAttemptAt = Date()

        Task {
            await notifyServerOfArrival(for: dock)
        }
    }

    private func notifyServerOfArrival(for dock: MonitoredDock) async {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("Cannot end live activity on arrival because APNs device token is unavailable")
            isSendingArrivalRequest = false
            return
        }

        let urlString = "\(AppConstants.Server.baseURL)\(AppConstants.Server.liveActivityArrivalEndpoint)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid live activity arrival URL: \(urlString)")
            isSendingArrivalRequest = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")

        let body: [String: Any] = [
            "dockId": dock.dockId,
            "deviceToken": deviceToken,
            "buildType": PushEnvironment.buildType,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.warning("Non-HTTP response received when ending live activity on arrival")
                isSendingArrivalRequest = false
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Unexpected status \(httpResponse.statusCode) when ending live activity on arrival")
                isSendingArrivalRequest = false
                return
            }

            logger.info("Server confirmed dock arrival for dock \(dock.dockId, privacy: .public); ending local live activity")
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
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Dock arrival monitoring authorization changed to \(status.rawValue)")

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            startMonitoringIfPossible()
        case .denied, .restricted:
            logger.warning("Dock arrival monitoring disabled because location permission is unavailable")
            locationManager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
