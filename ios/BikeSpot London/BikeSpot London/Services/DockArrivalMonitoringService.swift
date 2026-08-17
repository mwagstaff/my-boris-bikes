import CoreLocation
import Foundation
import UIKit
import UserNotifications
import os.log

enum DockArrivalHeuristics {
    static let temporaryFullAccuracyPurposeKey = "DockArrivalPreciseLocation"

    struct ArrivalEvidence: Equatable {
        let startedAt: Date
        let lastQualifyingAt: Date
        let closestMeasuredDistance: CLLocationDistance
        let qualifyingFixCount: Int
        let confirmationThreshold: CLLocationDistance
    }

    enum ArrivalEvidenceDecision: Equatable {
        case none
        case candidate(ArrivalEvidence)
        case confirmed
    }

    enum ArrivalPolicyKind: String {
        case startDock
        case endDock
        case regularDock
    }

    struct ArrivalPolicy: Equatable {
        let kind: ArrivalPolicyKind
        let arrivalThreshold: CLLocationDistance
        let acceptableHorizontalAccuracy: CLLocationAccuracy
        let usesCompensatedDistanceForConfirmation: Bool
        let confirmationDwellTime: TimeInterval
        let maximumThresholdExpansion: CLLocationDistance

        var resetDistanceThreshold: CLLocationDistance {
            effectiveArrivalThreshold +
                LiveActivityArrivalSettings.confirmationResetHysteresisMeters
        }

        func measuredArrivalDistance(
            rawDistance: CLLocationDistance,
            compensatedDistance: CLLocationDistance
        ) -> CLLocationDistance {
            usesCompensatedDistanceForConfirmation
                ? min(rawDistance, compensatedDistance)
                : rawDistance
        }

        func isInsideArrivalThreshold(
            rawDistance: CLLocationDistance,
            compensatedDistance: CLLocationDistance
        ) -> Bool {
            measuredArrivalDistance(
                rawDistance: rawDistance,
                compensatedDistance: compensatedDistance
            ) <= effectiveArrivalThreshold
        }

        func isInsideResetThreshold(
            rawDistance: CLLocationDistance,
            compensatedDistance: CLLocationDistance
        ) -> Bool {
            measuredArrivalDistance(
                rawDistance: rawDistance,
                compensatedDistance: compensatedDistance
            ) <= resetDistanceThreshold
        }

        var effectiveArrivalThreshold: CLLocationDistance {
            arrivalThreshold + maximumThresholdExpansion
        }
    }

    static func acceptableHorizontalAccuracy(
        for arrivalThreshold: CLLocationDistance
    ) -> CLLocationAccuracy {
        let scaledAccuracy = arrivalThreshold + 40
        return min(
            max(scaledAccuracy, LiveActivityArrivalSettings.minimumAcceptedHorizontalAccuracyMeters),
            LiveActivityArrivalSettings.maximumAcceptedHorizontalAccuracyMeters
        )
    }

    static func effectiveArrivalThreshold(
        for arrivalThreshold: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy
    ) -> CLLocationDistance {
        guard horizontalAccuracy > 0 else { return arrivalThreshold }

        let cappedAccuracy = min(horizontalAccuracy, acceptableHorizontalAccuracy(for: arrivalThreshold))
        let extraAllowance = max(0, cappedAccuracy - arrivalThreshold) * 0.8
        return arrivalThreshold + min(
            extraAllowance,
            LiveActivityArrivalSettings.maximumArrivalThresholdExpansionMeters
        )
    }

    static func effectiveActivationDistance(
        for activationDistance: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy
    ) -> CLLocationDistance {
        guard horizontalAccuracy > 0 else { return activationDistance }
        return activationDistance + min(
            horizontalAccuracy,
            LiveActivityArrivalSettings.maximumActivationAccuracyExpansionMeters
        )
    }

    static func compensatedDistance(
        from rawDistance: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy
    ) -> CLLocationDistance {
        guard horizontalAccuracy > 0 else { return rawDistance }
        return max(0, rawDistance - horizontalAccuracy)
    }

    static func arrivalPolicy(
        for phase: ScheduledJourney.ActiveRun.Phase?,
        configuredArrivalThreshold: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy
    ) -> ArrivalPolicy {
        switch phase {
        case .some(.start):
            let arrivalThreshold = configuredArrivalThreshold
            let accuracyAllowance = min(
                horizontalAccuracy * LiveActivityArrivalSettings.journeyStartAccuracyAllowanceMultiplier,
                LiveActivityArrivalSettings.journeyStartMaximumAccuracyAllowanceMeters
            )
            return ArrivalPolicy(
                kind: .startDock,
                arrivalThreshold: arrivalThreshold,
                acceptableHorizontalAccuracy: acceptableHorizontalAccuracy(for: arrivalThreshold),
                usesCompensatedDistanceForConfirmation: false,
                confirmationDwellTime: LiveActivityArrivalSettings.journeyStartConfirmationDwellTimeSeconds,
                maximumThresholdExpansion: max(0, accuracyAllowance)
            )
        case .some(.end):
            let arrivalThreshold = configuredArrivalThreshold
            let accuracyAllowance = min(
                horizontalAccuracy * LiveActivityArrivalSettings.journeyEndAccuracyAllowanceMultiplier,
                LiveActivityArrivalSettings.journeyEndMaximumAccuracyAllowanceMeters
            )
            return ArrivalPolicy(
                kind: .endDock,
                arrivalThreshold: arrivalThreshold,
                acceptableHorizontalAccuracy: min(
                    acceptableHorizontalAccuracy(for: arrivalThreshold),
                    LiveActivityArrivalSettings.journeyEndAcceptedHorizontalAccuracyMeters
                ),
                usesCompensatedDistanceForConfirmation: false,
                confirmationDwellTime: LiveActivityArrivalSettings.journeyEndConfirmationDwellTimeSeconds,
                maximumThresholdExpansion: max(0, accuracyAllowance)
            )
        case nil:
            let effectiveThreshold = effectiveArrivalThreshold(
                for: configuredArrivalThreshold,
                horizontalAccuracy: horizontalAccuracy
            )
            return ArrivalPolicy(
                kind: .regularDock,
                arrivalThreshold: configuredArrivalThreshold,
                acceptableHorizontalAccuracy: acceptableHorizontalAccuracy(for: configuredArrivalThreshold),
                usesCompensatedDistanceForConfirmation: true,
                confirmationDwellTime: LiveActivityArrivalSettings.confirmationDwellTimeSeconds,
                maximumThresholdExpansion: effectiveThreshold - configuredArrivalThreshold
            )
        }
    }

    static func evaluateArrivalEvidence(
        existingEvidence: ArrivalEvidence?,
        timestamp: Date,
        rawDistance: CLLocationDistance,
        compensatedDistance: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy,
        speed: CLLocationSpeed,
        policy: ArrivalPolicy
    ) -> ArrivalEvidenceDecision {
        let measuredDistance = policy.measuredArrivalDistance(
            rawDistance: rawDistance,
            compensatedDistance: compensatedDistance
        )
        let isInsideArrival = policy.isInsideArrivalThreshold(
            rawDistance: rawDistance,
            compensatedDistance: compensatedDistance
        )
        let isStrongFix = policy.kind != .startDock &&
            horizontalAccuracy <= LiveActivityArrivalSettings.strongFixMaximumAccuracyMeters &&
            rawDistance <= policy.arrivalThreshold

        if isStrongFix {
            return .confirmed
        }

        guard var evidence = existingEvidence else {
            guard isInsideArrival else { return .none }
            return .candidate(ArrivalEvidence(
                startedAt: timestamp,
                lastQualifyingAt: timestamp,
                closestMeasuredDistance: measuredDistance,
                qualifyingFixCount: 1,
                confirmationThreshold: policy.effectiveArrivalThreshold
            ))
        }

        let elapsed = timestamp.timeIntervalSince(evidence.startedAt)
        if elapsed < 0 || elapsed > LiveActivityArrivalSettings.confirmationTimeoutSeconds {
            guard isInsideArrival else { return .none }
            return .candidate(ArrivalEvidence(
                startedAt: timestamp,
                lastQualifyingAt: timestamp,
                closestMeasuredDistance: measuredDistance,
                qualifyingFixCount: 1,
                confirmationThreshold: policy.effectiveArrivalThreshold
            ))
        }

        let retainedResetThreshold = evidence.confirmationThreshold +
            LiveActivityArrivalSettings.confirmationResetHysteresisMeters
        guard measuredDistance <= max(policy.resetDistanceThreshold, retainedResetThreshold) else {
            return .none
        }

        let closestDistance = min(evidence.closestMeasuredDistance, measuredDistance)
        let confirmationThreshold = isInsideArrival
            ? max(evidence.confirmationThreshold, policy.effectiveArrivalThreshold)
            : evidence.confirmationThreshold
        if isInsideArrival, timestamp > evidence.lastQualifyingAt {
            evidence = ArrivalEvidence(
                startedAt: evidence.startedAt,
                lastQualifyingAt: timestamp,
                closestMeasuredDistance: closestDistance,
                qualifyingFixCount: evidence.qualifyingFixCount + 1,
                confirmationThreshold: confirmationThreshold
            )
        } else {
            evidence = ArrivalEvidence(
                startedAt: evidence.startedAt,
                lastQualifyingAt: evidence.lastQualifyingAt,
                closestMeasuredDistance: closestDistance,
                qualifyingFixCount: evidence.qualifyingFixCount,
                confirmationThreshold: confirmationThreshold
            )
        }

        if evidence.qualifyingFixCount >= 2,
           elapsed >= policy.confirmationDwellTime {
            return .confirmed
        }

        let hasPlausibleWalkingSpeed = speed >= 0 &&
            speed <= LiveActivityArrivalSettings.maximumDepartureConfirmationSpeedMetersPerSecond
        if policy.kind == .endDock,
           hasPlausibleWalkingSpeed,
           elapsed >= policy.confirmationDwellTime,
           evidence.closestMeasuredDistance <= evidence.confirmationThreshold {
            return .confirmed
        }

        return .candidate(evidence)
    }
}

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
    private static let maximumPendingArrivalAge: TimeInterval = 24 * 60 * 60
    private static let localRoutineLocationLogInterval: TimeInterval = 30
    private let monitoredDockStorageKey = "liveActivityArrivalMonitoredDock"
    private let pendingArrivalStorageKey = "liveActivityPendingArrivalEvent"
    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "DockArrival")
    private let locationManager = CLLocationManager()
    private let serverEventSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private struct ArrivalResponse: Decodable {
        let success: Bool
        let dockId: String
        let endedCount: Int
        let confirmationSent: Bool
        let remainingCount: Int
        let message: String
        let duplicate: Bool?
    }

    private struct PersistedMonitoringState: Codable {
        let dock: MonitoredDock
        let scheduledJourneyId: String?
        let scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase?
        let adHocJourneyId: String?
        let scheduledDestinationDock: ScheduledJourneyDock?
    }

    private struct PendingArrivalEvent: Codable, Equatable {
        let eventId: String
        let dock: MonitoredDock
        let createdAt: Date
        let scheduledJourneyId: String?
        let adHocJourneyId: String?
        let liveActivityPushToken: String?
    }

    private enum TrackingMode: Equatable {
        case passiveRegion
        case coarseApproach
        case approach
        case precise
    }

    private var monitoredDock: MonitoredDock?
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var isSendingArrivalRequest = false
    private var lastRoutineLocationLogAt: Date?
    private var lastLocalRoutineLocationLogAt: Date?
    private var arrivalEvidence: DockArrivalHeuristics.ArrivalEvidence?
    private var trackingMode: TrackingMode = .passiveRegion
    private var hasConfiguredMonitoringThisProcess = false
    private var configuredAuthorizationStatus: CLAuthorizationStatus?
    private var configuredAccuracyAuthorization: CLAccuracyAuthorization?
    private var isDeliveringPendingArrival = false
    private var hasRequestedAlwaysAuthorizationThisSession = false
    private var hasRequestedTemporaryFullAccuracyThisSession = false
    private var scheduledJourneyId: String?
    private var scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase?
    private var adHocJourneyId: String?
    private var scheduledDestinationDock: ScheduledJourneyDock?
    private var destinationApproachSpaceAvailabilityRequested = false

    private override init() {
        super.init()
        locationManager.delegate = self
        configureLowPowerTrackingProfile()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
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

    func beginMonitoring(
        for bikePoint: BikePoint,
        scheduledJourneyId: String? = nil,
        phase: ScheduledJourney.ActiveRun.Phase? = nil,
        adHocJourneyId: String? = nil,
        destinationDock: ScheduledJourneyDock? = nil
    ) {
        let dock = MonitoredDock(
            dockId: bikePoint.id,
            dockName: bikePoint.commonName,
            latitude: bikePoint.lat,
            longitude: bikePoint.lon
        )
        let isReusingConfiguredSession = hasConfiguredMonitoringThisProcess &&
            monitoredDock == dock &&
            self.scheduledJourneyId == scheduledJourneyId &&
            self.scheduledJourneyPhase == phase &&
            self.adHocJourneyId == adHocJourneyId

        self.scheduledJourneyId = scheduledJourneyId
        self.scheduledJourneyPhase = phase
        self.adHocJourneyId = adHocJourneyId
        self.scheduledDestinationDock = destinationDock
        monitoredDock = dock
        persistMonitoringState(for: dock)

        if isReusingConfiguredSession {
            logLocationEvent(
                "monitor_begin_reused",
                dock: dock,
                message: "Reused active dock arrival monitoring without resetting confirmation state"
            )
            return
        }

        clearMonitoringConfigurationState()
        isSendingArrivalRequest = false
        lastRoutineLocationLogAt = nil
        lastLocalRoutineLocationLogAt = nil
        arrivalEvidence = nil
        trackingMode = .passiveRegion
        destinationApproachSpaceAvailabilityRequested = false
        hasRequestedTemporaryFullAccuracyThisSession = false
        logLocationEvent("monitor_begin", dock: dock, message: "Preparing dock arrival monitoring")

        guard shouldMonitorCurrentDock else {
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
        guard shouldMonitorCurrentDock else {
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
        if hasConfiguredMonitoringThisProcess {
            logLocationEvent(
                "monitor_restore_reused",
                dock: dock,
                message: "Monitoring was already active; preserved current confirmation state"
            )
            return
        }

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

        stopAllLocationUpdates()
        stopMonitoringDockRegion()
        stopBackgroundActivitySession()
        clearMonitoringConfigurationState()
        isSendingArrivalRequest = false
        lastRoutineLocationLogAt = nil
        lastLocalRoutineLocationLogAt = nil
        arrivalEvidence = nil
        trackingMode = .passiveRegion
        destinationApproachSpaceAvailabilityRequested = false
        hasRequestedTemporaryFullAccuracyThisSession = false
        if !preserveDock {
            monitoredDock = nil
            scheduledJourneyId = nil
            scheduledJourneyPhase = nil
            adHocJourneyId = nil
            scheduledDestinationDock = nil
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
        persistMonitoringState(for: dock)
        clearMonitoringConfigurationState()
        logLocationEvent(
            "monitor_dock_updated",
            dock: dock,
            message: "Updated monitored dock coordinates from latest bike point data",
            raw: [
                "latitude": dock.latitude,
                "longitude": dock.longitude
            ]
        )

        if shouldMonitorCurrentDock {
            startMonitoringIfPossible()
        }
    }

    private var isEnabled: Bool {
        let defaults = LiveActivityArrivalSettings.userDefaultsStore
        return defaults.object(forKey: LiveActivityArrivalSettings.enabledKey) as? Bool
            ?? LiveActivityArrivalSettings.defaultEnabled
    }

    // Read directly from shared defaults (rather than ScheduledJourneyService,
    // which is @MainActor) so this can be checked synchronously from
    // CLLocationManagerDelegate callbacks.
    private var isHolidayModeEnabled: Bool {
        AppConstants.UserDefaults.sharedDefaults.bool(forKey: AppConstants.UserDefaults.holidayModeEnabledKey)
    }

    private var shouldMonitorCurrentDock: Bool {
        !isHolidayModeEnabled && (scheduledJourneyPhase != nil || isEnabled)
    }

    var monitoredDockID: String? {
        monitoredDock?.dockId
    }

    private var debugDeviceIdentifier: String? {
        DeviceTokenHelper.apnsDeviceToken ?? DeviceTokenHelper.analyticsDeviceToken
    }

    private func configuredArrivalDistanceMeters(for phase: ScheduledJourney.ActiveRun.Phase?) -> CLLocationDistance {
        switch phase {
        case .some(.start):
            LiveActivityArrivalSettings.configuredStartArrivalDistanceMeters()
        case .some(.end):
            LiveActivityArrivalSettings.configuredEndArrivalDistanceMeters()
        case nil:
            LiveActivityArrivalSettings.configuredEndArrivalDistanceMeters()
        }
    }

    private func persistMonitoringState(for dock: MonitoredDock) {
        let encoder = JSONEncoder()
        let state = PersistedMonitoringState(
            dock: dock,
            scheduledJourneyId: scheduledJourneyId,
            scheduledJourneyPhase: scheduledJourneyPhase,
            adHocJourneyId: adHocJourneyId,
            scheduledDestinationDock: scheduledDestinationDock
        )
        guard let data = try? encoder.encode(state) else { return }
        AppConstants.UserDefaults.sharedDefaults.set(data, forKey: monitoredDockStorageKey)
    }

    private func loadPersistedDock() -> MonitoredDock? {
        guard let data = AppConstants.UserDefaults.sharedDefaults.data(forKey: monitoredDockStorageKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let state = try? decoder.decode(PersistedMonitoringState.self, from: data) {
            scheduledJourneyId = state.scheduledJourneyId
            scheduledJourneyPhase = state.scheduledJourneyPhase
            adHocJourneyId = state.adHocJourneyId
            scheduledDestinationDock = state.scheduledDestinationDock
            return state.dock
        }

        return try? decoder.decode(MonitoredDock.self, from: data)
    }

    private func persistPendingArrival(_ event: PendingArrivalEvent) {
        var events = loadPendingArrivals()
        guard !events.contains(where: { $0.eventId == event.eventId }) else { return }
        events.append(event)
        guard let data = try? JSONEncoder().encode(events) else { return }
        AppConstants.UserDefaults.sharedDefaults.set(data, forKey: pendingArrivalStorageKey)
    }

    private func loadPendingArrivals() -> [PendingArrivalEvent] {
        guard let data = AppConstants.UserDefaults.sharedDefaults.data(forKey: pendingArrivalStorageKey) else {
            return []
        }
        let decoder = JSONDecoder()
        if let events = try? decoder.decode([PendingArrivalEvent].self, from: data) {
            return events
        }
        if let legacyEvent = try? decoder.decode(PendingArrivalEvent.self, from: data) {
            return [legacyEvent]
        }
        return []
    }

    private func clearPendingArrival(eventId: String) {
        let remainingEvents = loadPendingArrivals().filter { $0.eventId != eventId }
        guard !remainingEvents.isEmpty else {
            AppConstants.UserDefaults.sharedDefaults.removeObject(forKey: pendingArrivalStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(remainingEvents) else { return }
        AppConstants.UserDefaults.sharedDefaults.set(data, forKey: pendingArrivalStorageKey)
    }

    @MainActor
    func retryPendingArrivalDeliveryIfNeeded() async {
        for event in loadPendingArrivals() {
            stopMonitoring(for: event.dock.dockId, reason: "pending_arrival_reconciliation")
            await MainActor.run {
                LiveActivityService.shared.endLiveActivity(
                    for: event.dock.dockId,
                    skipServerUnregister: true
                )
            }
            if let scheduledJourneyId = event.scheduledJourneyId {
                await ScheduledJourneyService.shared.complete(journeyId: scheduledJourneyId)
            }
            if let adHocJourneyId = event.adHocJourneyId {
                AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
            }
            if Date().timeIntervalSince(event.createdAt) > Self.maximumPendingArrivalAge {
                clearPendingArrival(eventId: event.eventId)
                logLocationEvent(
                    "arrival_delivery_expired",
                    dock: event.dock,
                    message: "Removed an arrival event after its server session window elapsed",
                    raw: ["arrivalEventId": event.eventId]
                )
                continue
            }
            _ = await deliverPendingArrival(event)
        }
    }

    func hasPendingArrival(for dockId: String) -> Bool {
        loadPendingArrivals().contains { $0.dock.dockId == dockId }
    }

    private func startMonitoringIfPossible() {
        guard let dock = monitoredDock else { return }

        clearMonitoringConfigurationState()

        guard shouldMonitorCurrentDock else {
            logger.info("Dock arrival monitoring skipped because holiday mode or preference is disabled")
            stopPreciseLocationUpdates()
            stopMonitoringDockRegion()
            return
        }

        guard CLLocationManager.locationServicesEnabled() else {
            logger.warning("Dock arrival monitoring unavailable because location services are disabled")
            logLocationEvent(
                "location_services_disabled",
                dock: dock,
                message: "System location services are disabled"
            )
            return
        }

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

        if authorizationStatus == .authorizedWhenInUse {
            logLocationEvent(
                "monitor_degraded_when_in_use_authorization",
                dock: dock,
                message: "Background dock arrival monitoring is less reliable without Always authorization"
            )
        }

        if #available(iOS 14.0, *), locationManager.accuracyAuthorization == .reducedAccuracy {
            requestTemporaryFullAccuracyIfNeeded()
            logger.warning("Dock arrival monitoring is running with reduced accuracy; region monitoring will not be reliable")
            logLocationEvent(
                "monitor_reduced_accuracy",
                dock: dock,
                message: "Reduced location accuracy prevents reliable region monitoring"
            )
            stopMonitoringDockRegion()
            // High-power tracking cannot improve fixes that iOS coarsens under
            // reduced accuracy, so use the low-power profile here.
            startContinuousLowSensitivityTracking(reason: "reduced_accuracy_authorization")
            markMonitoringConfigurationActive()
            return
        }

        stopAllLocationUpdates()
        stopBackgroundActivitySession()
        stopMonitoringDockRegion()
        resetConfirmationState()

        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            startMonitoringDockRegion(for: dock)
            logger.info("Starting region-based dock arrival monitoring")
            if let scheduledJourneyPhase {
                // A coarse standard stream is cheap and protects both journey
                // phases against delayed or missing region-entry delivery.
                startContinuousLowSensitivityTracking(
                    reason: scheduledJourneyPhase == .start
                        ? "journey_start_watchdog"
                        : "journey_end_approach"
                )
            } else {
                trackingMode = .passiveRegion
            }
        } else {
            logger.warning("Dock arrival region monitoring is unavailable; relying on continuous location updates")
            logLocationEvent(
                "region_monitoring_unavailable",
                dock: dock,
                message: "Region monitoring unavailable; using continuous location updates"
            )
            startContinuousLowSensitivityTracking(reason: "region_monitoring_unavailable")
        }
        markMonitoringConfigurationActive()
    }

    private func clearMonitoringConfigurationState() {
        hasConfiguredMonitoringThisProcess = false
        configuredAuthorizationStatus = nil
        configuredAccuracyAuthorization = nil
    }

    private func markMonitoringConfigurationActive() {
        hasConfiguredMonitoringThisProcess = true
        configuredAuthorizationStatus = locationManager.authorizationStatus
        configuredAccuracyAuthorization = locationManager.accuracyAuthorization
    }

    private func isMonitoringConfiguredForCurrentAuthorization(_ manager: CLLocationManager) -> Bool {
        hasConfiguredMonitoringThisProcess &&
            configuredAuthorizationStatus == manager.authorizationStatus &&
            configuredAccuracyAuthorization == manager.accuracyAuthorization
    }

    private func startBackgroundActivitySessionIfNeeded() {
        guard backgroundActivitySession == nil else { return }
        guard monitoredDock != nil else { return }

        if #available(iOS 17.0, *) {
            backgroundActivitySession = CLBackgroundActivitySession()
            logLocationEvent(
                "background_activity_session_started",
                dock: monitoredDock,
                message: "Started CLBackgroundActivitySession to keep background location active"
            )
        }
    }

    private func stopBackgroundActivitySession() {
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }

    private func shouldAttemptArrival(
        for location: CLLocation,
        policy: DockArrivalHeuristics.ArrivalPolicy
    ) -> Bool {
        if location.horizontalAccuracy < 0 {
            return false
        }

        let age = Date().timeIntervalSince(location.timestamp)
        if age > LiveActivityArrivalSettings.maximumLocationAgeSeconds ||
            age < -LiveActivityArrivalSettings.maximumFutureLocationOffsetSeconds {
            logLocationEvent(
                "location_ignored_stale",
                dock: monitoredDock,
                location: location,
                message: "Location timestamp is outside the accepted freshness window",
                raw: ["locationAgeSeconds": age]
            )
            return false
        }

        let acceptableAccuracy = policy.acceptableHorizontalAccuracy
        if location.horizontalAccuracy > acceptableAccuracy {
            logger.info("Ignoring imprecise location update for dock arrival monitoring (accuracy: \(location.horizontalAccuracy, privacy: .public)m)")
            logLocationEvent(
                "location_ignored_imprecise",
                dock: monitoredDock,
                location: location,
                message: "Horizontal accuracy too low for arrival detection",
                raw: [
                    "acceptableHorizontalAccuracyMeters": acceptableAccuracy,
                    "arrivalPolicy": policy.kind.rawValue
                ]
            )
            return false
        }

        return true
    }

    private func checkArrival(with location: CLLocation) {
        guard let dock = monitoredDock else { return }

        let dockLocation = CLLocation(latitude: dock.latitude, longitude: dock.longitude)
        let distance = location.distance(from: dockLocation)
        let compensatedDistance = DockArrivalHeuristics.compensatedDistance(
            from: distance,
            horizontalAccuracy: location.horizontalAccuracy
        )
        let arrivalDistanceThreshold = configuredArrivalDistanceMeters(for: scheduledJourneyPhase)
        let arrivalPolicy = DockArrivalHeuristics.arrivalPolicy(
            for: scheduledJourneyPhase,
            configuredArrivalThreshold: arrivalDistanceThreshold,
            horizontalAccuracy: location.horizontalAccuracy
        )
        let activationDistanceThreshold = LiveActivityArrivalSettings.preciseActivationDistanceMeters
        let effectiveActivationDistanceThreshold = DockArrivalHeuristics.effectiveActivationDistance(
            for: activationDistanceThreshold,
            horizontalAccuracy: location.horizontalAccuracy
        )
        let measuredArrivalDistance = arrivalPolicy.measuredArrivalDistance(
            rawDistance: distance,
            compensatedDistance: compensatedDistance
        )

        logger.info("Dock arrival check for \(dock.dockId, privacy: .public): \(distance, privacy: .public)m away")
        logRoutineLocationEventIfNeeded(
            dock: dock,
            location: location,
            distanceMeters: distance,
            activationDistanceThreshold: effectiveActivationDistanceThreshold
        )

        let activationDistance = min(distance, compensatedDistance)
        if activationDistance <= effectiveActivationDistanceThreshold,
           trackingMode == .coarseApproach || trackingMode == .passiveRegion {
            startApproachLocationUpdates(reason: "location_within_activation_distance")
        }
        let navigationActivationDistance = DockArrivalHeuristics.effectiveActivationDistance(
            for: LiveActivityArrivalSettings.navigationAccuracyActivationDistanceMeters,
            horizontalAccuracy: location.horizontalAccuracy
        )
        if activationDistance <= navigationActivationDistance,
           trackingMode != .precise {
            startPreciseLocationUpdates(reason: "location_within_navigation_accuracy_distance")
        }

        guard shouldAttemptArrival(for: location, policy: arrivalPolicy) else { return }

        let previousEvidence = arrivalEvidence
        let decision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: previousEvidence,
            timestamp: location.timestamp,
            rawDistance: distance,
            compensatedDistance: compensatedDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed,
            policy: arrivalPolicy
        )

        switch decision {
        case .none:
            arrivalEvidence = nil
            if previousEvidence != nil {
                logLocationEvent(
                    "arrival_confirmation_reset",
                    dock: dock,
                    location: location,
                    distanceMeters: measuredArrivalDistance,
                    message: "Moved outside confirmation hysteresis or candidate expired"
                )
            }
            return
        case .candidate(let evidence):
            arrivalEvidence = evidence
            if previousEvidence == nil {
                logLocationEvent(
                    "arrival_confirmation_started",
                    dock: dock,
                    location: location,
                    distanceMeters: measuredArrivalDistance,
                    message: "First in-threshold location received",
                    raw: [
                        "arrivalPolicy": arrivalPolicy.kind.rawValue,
                        "rawDistanceMeters": distance,
                        "compensatedDistanceMeters": compensatedDistance,
                        "effectiveArrivalThresholdMeters": arrivalPolicy.effectiveArrivalThreshold,
                        "configuredArrivalThresholdMeters": arrivalDistanceThreshold
                    ]
                )
            }
            return
        case .confirmed:
            arrivalEvidence = nil
        }

        isSendingArrivalRequest = true
        logLocationEvent(
            "arrival_threshold_met",
            dock: dock,
            location: location,
            distanceMeters: measuredArrivalDistance,
            message: "Arrival distance threshold met",
            raw: [
                "arrivalPolicy": arrivalPolicy.kind.rawValue,
                "rawDistanceMeters": distance,
                "compensatedDistanceMeters": compensatedDistance,
                "effectiveArrivalThresholdMeters": arrivalPolicy.effectiveArrivalThreshold,
                "configuredArrivalThresholdMeters": arrivalDistanceThreshold
            ]
        )

        // Register a background task token *before* dispatching async work.
        // The token inside postJSON only activates once the Task body runs —
        // without this outer token, iOS could suspend the app in the window
        // between Task dispatch and postJSON acquiring its own token.
        nonisolated(unsafe) var outerTaskId = UIBackgroundTaskIdentifier.invalid
        outerTaskId = UIApplication.shared.beginBackgroundTask(withName: "dock-arrival-detection") {
            guard outerTaskId != .invalid else { return }
            UIApplication.shared.endBackgroundTask(outerTaskId)
            outerTaskId = .invalid
        }

        Task {
            await notifyServerOfArrival(for: dock)
            await MainActor.run {
                guard outerTaskId != .invalid else { return }
                UIApplication.shared.endBackgroundTask(outerTaskId)
                outerTaskId = .invalid
            }
        }
    }

    @discardableResult
    private func notifyServerOfArrival(for dock: MonitoredDock) async -> Bool {
        if scheduledJourneyPhase == .start,
           let scheduledDestinationDock,
           (scheduledJourneyId != nil || adHocJourneyId != nil) {
            let startArrivalScheduledJourneyId = scheduledJourneyId
            let startArrivalAdHocJourneyId = adHocJourneyId
            let destinationDock = scheduledDestinationDock

            logger.info("Scheduled journey start dock reached; transitioning to end dock")
            logLocationEvent(
                "scheduled_start_arrival",
                dock: dock,
                message: "Start dock reached; transitioning scheduled journey to destination dock"
            )
            sendScheduledStartArrivalNotification(for: dock)
            stopMonitoring(reason: "scheduled_start_arrival")
            await LiveActivityService.shared.transitionScheduledJourneyToEndDock(
                journeyId: startArrivalScheduledJourneyId,
                adHocJourneyId: startArrivalAdHocJourneyId,
                endDock: destinationDock,
                delaySeconds: 0,
                transitionSource: "arrival"
            )
            return true
        }

        let completedScheduledJourneyId = scheduledJourneyPhase == .end ? scheduledJourneyId : nil
        let completedAdHocJourneyId = scheduledJourneyPhase == .end ? adHocJourneyId : nil
        let liveActivityPushToken = await MainActor.run {
            LiveActivityService.shared.pushTokenForArrival(for: dock.dockId)
        }
        let event = PendingArrivalEvent(
            eventId: UUID().uuidString,
            dock: dock,
            createdAt: Date(),
            scheduledJourneyId: completedScheduledJourneyId,
            adHocJourneyId: completedAdHocJourneyId,
            liveActivityPushToken: liveActivityPushToken
        )
        persistPendingArrival(event)
        logLocationEvent(
            "arrival_confirmed_locally",
            dock: dock,
            message: "Persisted confirmed arrival before server delivery",
            raw: ["arrivalEventId": event.eventId]
        )

        // Local completion must not depend on a network round trip. The durable
        // event above is retried until the server acknowledges the same event ID.
        stopMonitoring(reason: "arrival_confirmed_locally")
        await MainActor.run {
            LiveActivityService.shared.endLiveActivity(for: dock.dockId, skipServerUnregister: true)
        }
        if let completedScheduledJourneyId {
            await ScheduledJourneyService.shared.complete(journeyId: completedScheduledJourneyId)
        }
        if let completedAdHocJourneyId {
            await AdHocJourneyService.shared.complete(journeyId: completedAdHocJourneyId)
        }
        AnalyticsService.shared.track(
            action: .liveActivityEnd,
            screen: .app,
            dock: AnalyticsDockInfo(id: dock.dockId, name: dock.dockName),
            metadata: ["reason": "arrival"]
        )

        return await deliverPendingArrival(event)
    }

    @discardableResult
    @MainActor
    private func deliverPendingArrival(_ event: PendingArrivalEvent) async -> Bool {
        guard !isDeliveringPendingArrival else { return false }
        guard loadPendingArrivals().contains(where: { $0.eventId == event.eventId }) else { return true }
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logLocationEvent(
                "arrival_delivery_deferred",
                dock: event.dock,
                message: "APNs device token unavailable; retaining pending arrival",
                raw: ["arrivalEventId": event.eventId]
            )
            return false
        }

        isDeliveringPendingArrival = true
        defer { isDeliveringPendingArrival = false }

        var body: [String: Any] = [
            "arrivalEventId": event.eventId,
            "dockId": event.dock.dockId,
            "deviceToken": deviceToken,
            "buildType": PushEnvironment.buildType,
        ]
        if let liveActivityPushToken = event.liveActivityPushToken {
            body["pushToken"] = liveActivityPushToken
        }
        logLocationEvent(
            "arrival_request_started",
            dock: event.dock,
            message: "Sending persisted arrival request to server",
            raw: ["arrivalEventId": event.eventId]
        )

        do {
            let (data, httpResponse) = try await postJSON(
                path: AppConstants.Server.liveActivityArrivalEndpoint,
                body: body,
                requestHeaderToken: deviceToken,
                backgroundTaskName: "dock-arrival-request"
            )
            guard (200...299).contains(httpResponse.statusCode) else {
                logLocationEvent(
                    "arrival_request_failed",
                    dock: event.dock,
                    message: "Server returned HTTP \(httpResponse.statusCode)",
                    raw: ["arrivalEventId": event.eventId]
                )
                return false
            }

            let response = try JSONDecoder().decode(ArrivalResponse.self, from: data)
            guard response.success,
                  response.endedCount > 0 || response.duplicate == true else {
                logLocationEvent(
                    "arrival_request_unmatched",
                    dock: event.dock,
                    message: response.message,
                    raw: [
                        "arrivalEventId": event.eventId,
                        "endedCount": response.endedCount,
                        "remainingCount": response.remainingCount,
                    ]
                )
                return false
            }

            clearPendingArrival(eventId: event.eventId)
            logLocationEvent(
                "arrival_request_succeeded",
                dock: event.dock,
                message: response.duplicate == true
                    ? "Server replayed the previously accepted arrival"
                    : "Server accepted the arrival request",
                raw: [
                    "arrivalEventId": event.eventId,
                    "endedCount": response.endedCount,
                    "confirmationSent": response.confirmationSent,
                    "duplicate": response.duplicate ?? false,
                ]
            )
            await LiveActivityService.shared.refreshNotificationStatusFromServer()
            return true
        } catch {
            logger.error("Failed to deliver persisted dock arrival: \(error.localizedDescription)")
            logLocationEvent(
                "arrival_request_failed",
                dock: event.dock,
                message: "Network or response error: \(error.localizedDescription)",
                raw: ["arrivalEventId": event.eventId]
            )
            return false
        }
    }

    private func sendScheduledStartArrivalNotification(for dock: MonitoredDock) {
        let content = UNMutableNotificationContent()
        content.title = "Dock arrival"
        content.body = "Welcome to \(dock.dockName)!"
        content.sound = .default
        let minuteBucket = Int(Date().timeIntervalSince1970 / 60)

        let request = UNNotificationRequest(
            identifier: "scheduled-start-arrival-\(scheduledJourneyId ?? adHocJourneyId ?? dock.dockId)-\(minuteBucket)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to schedule start-dock arrival notification: \(error.localizedDescription)")
            }
        }
    }

    private func requestDestinationApproachSpaceAvailabilityIfNeeded(for dock: MonitoredDock, reason: String) {
        guard scheduledJourneyPhase == .end else { return }
        guard scheduledJourneyId != nil || adHocJourneyId != nil else { return }
        guard !destinationApproachSpaceAvailabilityRequested else { return }

        destinationApproachSpaceAvailabilityRequested = true
        let destinationDock = ScheduledJourneyDock(
            id: dock.dockId,
            name: dock.dockName,
            latitude: dock.latitude,
            longitude: dock.longitude
        )

        Task {
            let scheduled = await scheduleDestinationSpaceAvailabilityNotification(
                startDock: dock,
                destinationDock: destinationDock,
                delayMs: 0,
                triggerSource: "destination_approach"
            )
            if !scheduled {
                destinationApproachSpaceAvailabilityRequested = false
            }
        }

        logLocationEvent(
            "destination_approach_space_alert_requested",
            dock: dock,
            message: "Requested destination space availability notification on approach",
            raw: ["reason": reason]
        )
    }

    @discardableResult
    private func scheduleDestinationSpaceAvailabilityNotification(
        startDock: MonitoredDock,
        destinationDock: ScheduledJourneyDock,
        delayMs: Int? = nil,
        triggerSource: String = "start_arrival"
    ) async -> Bool {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("Cannot schedule destination space notification because APNs device token is unavailable")
            logLocationEvent(
                "scheduled_start_destination_space_alert_failed",
                dock: startDock,
                message: "APNs device token unavailable"
            )
            return false
        }

        var body: [String: Any] = [
            "startDockId": startDock.dockId,
            "startDockName": startDock.dockName,
            "endDock": [
                "id": destinationDock.id,
                "name": destinationDock.name,
                "latitude": destinationDock.latitude,
                "longitude": destinationDock.longitude,
            ],
            "deviceToken": deviceToken,
            "buildType": PushEnvironment.buildType,
            "triggerSource": triggerSource,
        ]
        if let delayMs {
            body["delayMs"] = delayMs
        }
        if let scheduledJourneyId {
            body["scheduledJourneyId"] = scheduledJourneyId
        }
        if let adHocJourneyId {
            body["adHocJourneyId"] = adHocJourneyId
        }

        do {
            let (_, httpResponse) = try await postJSON(
                path: AppConstants.Server.liveActivityStartArrivalEndpoint,
                body: body,
                requestHeaderToken: deviceToken,
                backgroundTaskName: "start-arrival-destination-space-alert"
            )

            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Unexpected status \(httpResponse.statusCode) when scheduling destination space notification")
                logLocationEvent(
                    "scheduled_start_destination_space_alert_failed",
                    dock: startDock,
                    message: "Server returned HTTP \(httpResponse.statusCode)"
                )
                return false
            }

            logLocationEvent(
                "scheduled_start_destination_space_alert_scheduled",
                dock: startDock,
                message: "Destination dock space availability notification scheduled",
                raw: [
                    "destinationDockId": destinationDock.id,
                    "destinationDockName": destinationDock.name,
                    "triggerSource": triggerSource,
                ]
            )
            return true
        } catch {
            logger.error("Failed to schedule destination space notification: \(error.localizedDescription)")
            logLocationEvent(
                "scheduled_start_destination_space_alert_failed",
                dock: startDock,
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
    ) async throws -> (Data, HTTPURLResponse) {
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

        nonisolated(unsafe) var backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        backgroundTaskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: backgroundTaskName) {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
            }
        }
        defer {
            let taskId = backgroundTaskId
            Task { @MainActor in
                guard taskId != .invalid else { return }
                UIApplication.shared.endBackgroundTask(taskId)
            }
        }

        let (data, response) = try await serverEventSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
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
        let eventTimestamp = Date()
        let shouldRecordLocally = shouldRecordLocationEventLocally(event, at: eventTimestamp)
        let shouldUpload = shouldUploadDebugEvent(event)
        guard shouldRecordLocally || shouldUpload else { return }

        let payloadDeviceId = debugDeviceIdentifier
        let clientTimestamp = ISO8601DateFormatter().string(from: eventTimestamp)
        let arrivalThresholdMeters = configuredArrivalDistanceMeters(for: scheduledJourneyPhase)

        if shouldRecordLocally {
            var metadata: [String: String] = [
                "arrivalThresholdMeters": String(arrivalThresholdMeters),
                "authorizationStatus": authorizationStatusLabel(locationManager.authorizationStatus),
                "trackingMode": trackingModeLabel,
            ]
            if let activeDock {
                metadata["dockId"] = activeDock.dockId
                metadata["dockName"] = activeDock.dockName
            }
            if let scheduledJourneyId {
                metadata["scheduledJourneyId"] = scheduledJourneyId
            }
            if let scheduledJourneyPhase {
                metadata["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
            }
            if let adHocJourneyId {
                metadata["adHocJourneyId"] = adHocJourneyId
            }
            if let location {
                metadata["horizontalAccuracyMeters"] = String(location.horizontalAccuracy)
                metadata["latitude"] = String(location.coordinate.latitude)
                metadata["longitude"] = String(location.coordinate.longitude)
                metadata["locationTimestamp"] = ISO8601DateFormatter().string(from: location.timestamp)
                metadata["speedMetersPerSecond"] = String(location.speed)
            }
            if let distanceMeters {
                metadata["distanceMeters"] = String(distanceMeters)
            }
            for (key, value) in raw {
                metadata[key] = String(describing: value)
            }

            let localMessage = message ?? event
            Task { @MainActor [event, localMessage, metadata] in
                var localMetadata = metadata.reduce(into: [String: Any?]()) { result, item in
                    result[item.key] = item.value
                }
                localMetadata["appState"] = self.applicationStateLabel()
                localMetadata["backgroundRefreshStatus"] = self.backgroundRefreshStatusLabel()
                TroubleshootingLogStore.shared.record(
                    category: "dock_arrival",
                    event: event,
                    message: localMessage,
                    metadata: localMetadata
                )
            }
        }

        guard shouldUpload else { return }

        Task {
            var body: [String: Any] = [
                "event": event,
                "clientTimestamp": clientTimestamp,
                "appState": await MainActor.run { self.applicationStateLabel() },
                "backgroundRefreshStatus": await MainActor.run { self.backgroundRefreshStatusLabel() },
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
                let (_, httpResponse) = try await postJSON(
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

    private func shouldRecordLocationEventLocally(_ event: String, at timestamp: Date) -> Bool {
        guard event == "location_update" else { return true }

        guard lastLocalRoutineLocationLogAt == nil ||
            timestamp.timeIntervalSince(lastLocalRoutineLocationLogAt ?? .distantPast) >= Self.localRoutineLocationLogInterval else {
            return false
        }

        lastLocalRoutineLocationLogAt = timestamp
        return true
    }

    private var trackingModeLabel: String {
        switch trackingMode {
        case .passiveRegion:
            return "passiveRegion"
        case .coarseApproach:
            return "coarseApproach"
        case .approach:
            return "approach"
        case .precise:
            return "precise"
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

    private func backgroundRefreshStatusLabel() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "available"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private func dockRegionIdentifier(for dockId: String) -> String {
        "\(Self.regionIdentifierPrefix)\(dockId)"
    }

    private func configuredRegionRadiusMeters() -> CLLocationDistance {
        let threshold = configuredArrivalDistanceMeters(for: scheduledJourneyPhase)
        let radius = max(
            threshold + LiveActivityArrivalSettings.regionRadiusBufferMeters,
            LiveActivityArrivalSettings.highFrequencyActivationDistanceMeters
        )
        return min(
            radius,
            min(
                locationManager.maximumRegionMonitoringDistance,
                LiveActivityArrivalSettings.preferredMaximumRegionRadiusMeters
            )
        )
    }

    private func configureLowPowerTrackingProfile() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    private func configureApproachTrackingProfile() {
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 20
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func configureHighPowerTrackingProfile() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func startContinuousLowSensitivityTracking(reason: String) {
        configureLowPowerTrackingProfile()
        trackingMode = .coarseApproach
        startBackgroundActivitySessionIfNeeded()
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
        logLocationEvent(
            "continuous_low_sensitivity_started",
            dock: monitoredDock,
            message: "Started continuous low-sensitivity location updates",
            raw: ["reason": reason]
        )
    }

    private func stopAllLocationUpdates() {
        locationManager.stopUpdatingLocation()
        configureLowPowerTrackingProfile()
        trackingMode = .passiveRegion
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
        logLocationEvent(
            "region_monitoring_started",
            dock: dock,
            message: "Monitoring near-dock activation region",
            raw: ["radiusMeters": configuredRegionRadiusMeters()]
        )
    }

    private func startApproachLocationUpdates(reason: String) {
        guard let dock = monitoredDock else { return }
        guard !isSendingArrivalRequest else { return }
        guard trackingMode != .precise else { return }

        configureApproachTrackingProfile()
        trackingMode = .approach
        startBackgroundActivitySessionIfNeeded()
        requestDestinationApproachSpaceAvailabilityIfNeeded(for: dock, reason: reason)
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
        logLocationEvent(
            "approach_updates_started",
            dock: monitoredDock,
            message: "Started balanced near-dock location updates",
            raw: ["reason": reason]
        )
    }

    private func startPreciseLocationUpdates(reason: String) {
        guard let dock = monitoredDock else { return }
        guard !isSendingArrivalRequest else { return }

        configureHighPowerTrackingProfile()
        trackingMode = .precise
        startBackgroundActivitySessionIfNeeded()
        requestDestinationApproachSpaceAvailabilityIfNeeded(for: dock, reason: reason)
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
        logLocationEvent(
            "precise_updates_started",
            dock: monitoredDock,
            message: "Started navigation-grade final-approach updates",
            raw: ["reason": reason]
        )
    }

    private func stopPreciseLocationUpdates() {
        resetConfirmationState()
        stopAllLocationUpdates()
        stopBackgroundActivitySession()
    }

    /// Drops back from continuous high-accuracy updates. Scheduled journey
    /// phases retain a coarse stream to protect against delayed geofence delivery.
    private func deEscalateTracking(reason: String) {
        guard !isSendingArrivalRequest else { return }

        let hasArmedDockRegion = locationManager.monitoredRegions.contains {
            $0.identifier.hasPrefix(Self.regionIdentifierPrefix)
        }

        if scheduledJourneyPhase != nil || !hasArmedDockRegion {
            startContinuousLowSensitivityTracking(reason: reason)
        } else {
            stopAllLocationUpdates()
            stopBackgroundActivitySession()
        }
    }

    private func resetConfirmationState() {
        arrivalEvidence = nil
    }

    private func logRoutineLocationEventIfNeeded(
        dock: MonitoredDock,
        location: CLLocation,
        distanceMeters: CLLocationDistance,
        activationDistanceThreshold: CLLocationDistance
    ) {
        let now = Date()
        let shouldLog =
            lastRoutineLocationLogAt == nil ||
            now.timeIntervalSince(lastRoutineLocationLogAt ?? .distantPast) >= 15 ||
            distanceMeters <= activationDistanceThreshold

        guard shouldLog else { return }

        lastRoutineLocationLogAt = now
        logLocationEvent(
            "location_update",
            dock: dock,
            location: location,
            distanceMeters: distanceMeters,
            message: "Received location update while monitoring dock arrival"
        )
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
        startApproachLocationUpdates(reason: reason)
    }

    private func handleDockRegionExit(reason: String, region: CLRegion?) {
        guard let dock = monitoredDock else { return }
        logger.info("Exited dock monitoring region for \(dock.dockId, privacy: .public) (\(reason, privacy: .public))")
        if arrivalEvidence != nil {
            logLocationEvent(
                "region_exited",
                dock: dock,
                message: "Left near-dock activation region; preserving recent arrival evidence",
                raw: [
                    "reason": reason,
                    "regionIdentifier": region?.identifier ?? "unknown"
                ]
            )
        }
        deEscalateTracking(reason: reason)
    }

    private func shouldUploadDebugEvent(_ event: String) -> Bool {
        #if DEBUG
        guard AppConstants.UserDefaults.sharedDefaults.bool(
            forKey: AppConstants.UserDefaults.liveActivityUseDevAPIKey
        ) else {
            return false
        }
        return event != "location_update"
        #else
        return false
        #endif
    }

    private func requestTemporaryFullAccuracyIfNeeded() {
        guard monitoredDock != nil else { return }

        guard #available(iOS 14.0, *) else { return }
        guard locationManager.accuracyAuthorization == .reducedAccuracy else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard !hasRequestedTemporaryFullAccuracyThisSession else { return }

        hasRequestedTemporaryFullAccuracyThisSession = true
        locationManager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: DockArrivalHeuristics.temporaryFullAccuracyPurposeKey
        )
        logLocationEvent(
            "temporary_full_accuracy_requested",
            dock: monitoredDock,
            message: "Requested temporary full accuracy for dock arrival monitoring"
        )
    }

    private func accuracyAuthorizationLabel(_ manager: CLLocationManager) -> String {
        guard #available(iOS 14.0, *) else {
            return "unsupported"
        }

        switch manager.accuracyAuthorization {
        case .fullAccuracy:
            return "fullAccuracy"
        case .reducedAccuracy:
            return "reducedAccuracy"
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
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard let dock = monitoredDock,
              region.identifier == dockRegionIdentifier(for: dock.dockId) else {
            return
        }

        logLocationEvent(
            "region_monitoring_ready",
            dock: dock,
            message: "Core Location confirmed the dock region monitor is ready",
            raw: ["regionIdentifier": region.identifier]
        )
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isSendingArrivalRequest else { return }
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !isSendingArrivalRequest else { break }
            checkArrival(with: location)
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        logLocationEvent(
            "location_updates_paused",
            dock: monitoredDock,
            message: "Core Location paused the coarse approach stream"
        )
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        logLocationEvent(
            "location_updates_resumed",
            dock: monitoredDock,
            message: "Core Location resumed location delivery"
        )
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
        stopAllLocationUpdates()
        stopBackgroundActivitySession()
        stopMonitoringDockRegion()
        guard shouldMonitorCurrentDock else { return }
        startContinuousLowSensitivityTracking(reason: "region_monitoring_failed")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Dock arrival monitoring authorization changed to \(status.rawValue)")
        logLocationEvent(
            "authorization_changed",
            dock: monitoredDock,
            message: authorizationStatusLabel(status),
            raw: ["accuracyAuthorization": accuracyAuthorizationLabel(manager)]
        )

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            if isMonitoringConfiguredForCurrentAuthorization(manager) {
                logger.info("Preserving dock monitoring because authorization configuration is unchanged")
                logLocationEvent(
                    "authorization_configuration_reused",
                    dock: monitoredDock,
                    message: "Authorization callback did not require monitoring to restart",
                    raw: ["accuracyAuthorization": accuracyAuthorizationLabel(manager)]
                )
                return
            }
            startMonitoringIfPossible()
        case .denied, .restricted:
            logger.warning("Dock arrival monitoring disabled because location permission is unavailable")
            clearMonitoringConfigurationState()
            stopPreciseLocationUpdates()
            stopMonitoringDockRegion()
            logLocationEvent(
                "authorization_unavailable",
                dock: monitoredDock,
                message: "Location permission unavailable after authorization change"
            )
        case .notDetermined:
            clearMonitoringConfigurationState()
            hasRequestedAlwaysAuthorizationThisSession = false
            hasRequestedTemporaryFullAccuracyThisSession = false
            break
        @unknown default:
            break
        }
    }
}
