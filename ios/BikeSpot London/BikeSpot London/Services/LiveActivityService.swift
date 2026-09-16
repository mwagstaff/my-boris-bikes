//
//  LiveActivityService.swift
//  BikeSpot London
//
//  Manages Live Activities for real-time dock availability tracking
//

import ActivityKit
import Foundation
import UIKit
import UserNotifications
import os.log

struct DockActivityMonitoringConfiguration: Equatable {
    let bikePoint: BikePoint
    let scheduledJourneyId: String?
    let phase: ScheduledJourney.ActiveRun.Phase?
    let adHocJourneyId: String?
    let destinationDock: ScheduledJourneyDock?
}

struct DockActivityMonitoringRecoveryContext: Equatable {
    let activeDockId: String
    let activeDockName: String?
    let scheduledJourneyId: String?
    let phase: ScheduledJourney.ActiveRun.Phase?
    let adHocJourneyId: String?
    let destinationDockId: String?
    let destinationDockName: String?
}

enum DockActivityMonitoringResolver {
    private struct ResolutionContext {
        let primaryDockId: String
        let destinationDockId: String?
        let activeDockId: String
        let activeDockName: String?
        let destinationDockName: String?
        let phase: ScheduledJourney.ActiveRun.Phase?
    }

    static func resolve(
        attributes: DockActivityAttributes,
        state: DockActivityAttributes.ContentState,
        fallbackActiveDock: BikePoint? = nil,
        fallbackDestinationDock: ScheduledJourneyDock? = nil
    ) -> DockActivityMonitoringConfiguration? {
        guard let context = resolutionContext(attributes: attributes, state: state) else {
            return nil
        }

        let activeDock: BikePoint?
        if context.activeDockId == context.primaryDockId,
           let latitude = attributes.latitude,
           let longitude = attributes.longitude,
           isValidCoordinate(latitude: latitude, longitude: longitude),
           let dockName = context.activeDockName {
            activeDock = BikePoint(
                id: context.activeDockId,
                commonName: dockName,
                lat: latitude,
                lon: longitude
            )
        } else if context.activeDockId == context.destinationDockId,
                  let latitude = attributes.destinationLatitude,
                  let longitude = attributes.destinationLongitude,
                  isValidCoordinate(latitude: latitude, longitude: longitude),
                  let dockName = context.activeDockName {
            activeDock = BikePoint(
                id: context.activeDockId,
                commonName: dockName,
                lat: latitude,
                lon: longitude
            )
        } else if let fallbackActiveDock,
                  fallbackActiveDock.id == context.activeDockId,
                  isValidCoordinate(latitude: fallbackActiveDock.lat, longitude: fallbackActiveDock.lon),
                  !fallbackActiveDock.commonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeDock = fallbackActiveDock
        } else {
            activeDock = nil
        }

        guard let activeDock else { return nil }

        let destinationDock: ScheduledJourneyDock?
        if context.phase == .start {
            guard let destinationDockId = context.destinationDockId else { return nil }

            if let destinationDockName = context.destinationDockName,
               let latitude = attributes.destinationLatitude,
               let longitude = attributes.destinationLongitude,
               isValidCoordinate(latitude: latitude, longitude: longitude) {
                destinationDock = ScheduledJourneyDock(
                    id: destinationDockId,
                    name: destinationDockName,
                    latitude: latitude,
                    longitude: longitude
                )
            } else if let fallbackDestinationDock,
                      fallbackDestinationDock.id == destinationDockId,
                      isValidCoordinate(
                          latitude: fallbackDestinationDock.latitude,
                          longitude: fallbackDestinationDock.longitude
                      ),
                      !fallbackDestinationDock.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                destinationDock = fallbackDestinationDock
            } else {
                return nil
            }
        } else {
            destinationDock = nil
        }

        return DockActivityMonitoringConfiguration(
            bikePoint: activeDock,
            scheduledJourneyId: attributes.scheduledJourneyId,
            phase: context.phase,
            adHocJourneyId: attributes.adHocJourneyId,
            destinationDock: destinationDock
        )
    }

    static func recoveryContext(
        attributes: DockActivityAttributes,
        state: DockActivityAttributes.ContentState
    ) -> DockActivityMonitoringRecoveryContext? {
        guard let context = resolutionContext(attributes: attributes, state: state) else {
            return nil
        }
        return DockActivityMonitoringRecoveryContext(
            activeDockId: context.activeDockId,
            activeDockName: context.activeDockName,
            scheduledJourneyId: attributes.scheduledJourneyId,
            phase: context.phase,
            adHocJourneyId: attributes.adHocJourneyId,
            destinationDockId: context.destinationDockId,
            destinationDockName: context.destinationDockName
        )
    }

    private static func resolutionContext(
        attributes: DockActivityAttributes,
        state: DockActivityAttributes.ContentState
    ) -> ResolutionContext? {
        guard let primaryDockId = nonBlank(attributes.dockId) else { return nil }

        let mutablePhaseValue = nonBlank(state.activeJourneyPhase)
        let immutablePhaseValue = nonBlank(attributes.scheduledJourneyPhase)
        let phase: ScheduledJourney.ActiveRun.Phase?
        if let mutablePhaseValue {
            guard let parsed = ScheduledJourney.ActiveRun.Phase(rawValue: mutablePhaseValue) else {
                return nil
            }
            phase = parsed
        } else if let immutablePhaseValue {
            guard let parsed = ScheduledJourney.ActiveRun.Phase(rawValue: immutablePhaseValue) else {
                return nil
            }
            phase = parsed
        } else {
            phase = nil
        }

        let creationPhase: ScheduledJourney.ActiveRun.Phase?
        if let immutablePhaseValue {
            guard let parsed = ScheduledJourney.ActiveRun.Phase(rawValue: immutablePhaseValue) else {
                return nil
            }
            creationPhase = parsed
        } else {
            creationPhase = nil
        }

        let mutableDockId = state.resolvedDockId
        let destinationDockId = nonBlank(attributes.destinationDockId)
        let activeDockId = mutableDockId ?? primaryDockId

        switch (phase, creationPhase) {
        case (.some(.start), .some(.start)):
            guard activeDockId == primaryDockId, destinationDockId != nil else { return nil }
        case (.some(.end), .some(.start)):
            guard activeDockId == destinationDockId else { return nil }
        case (.some(.end), .some(.end)):
            guard activeDockId == primaryDockId else { return nil }
        case (nil, nil):
            guard activeDockId == primaryDockId else { return nil }
        default:
            return nil
        }

        let attributeDockName = activeDockId == destinationDockId
            ? nonBlank(attributes.destinationDockName)
            : nonBlank(attributes.dockName)
        let activeDockName = mutableDockId == nil
            ? attributeDockName
            : state.resolvedDockName ?? attributeDockName

        return ResolutionContext(
            primaryDockId: primaryDockId,
            destinationDockId: destinationDockId,
            activeDockId: activeDockId,
            activeDockName: activeDockName,
            destinationDockName: nonBlank(attributes.destinationDockName),
            phase: phase
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite &&
            longitude.isFinite &&
            (-90...90).contains(latitude) &&
            (-180...180).contains(longitude) &&
            (latitude != 0 || longitude != 0)
    }
}

struct LiveActivityTokenRegistrationKey: Hashable {
    let activityId: String
    let pushToken: String
}

struct LiveActivityTokenRegistrationTracker {
    private(set) var inFlight: Set<LiveActivityTokenRegistrationKey> = []
    private(set) var completed: Set<LiveActivityTokenRegistrationKey> = []

    mutating func begin(_ key: LiveActivityTokenRegistrationKey, force: Bool = false) -> Bool {
        guard !inFlight.contains(key) else { return false }
        guard force || !completed.contains(key) else { return false }
        inFlight.insert(key)
        return true
    }

    mutating func finish(_ key: LiveActivityTokenRegistrationKey, succeeded: Bool) {
        inFlight.remove(key)
        if succeeded {
            completed.insert(key)
        }
    }

    mutating func remove(activityId: String) {
        inFlight = Set(inFlight.filter { $0.activityId != activityId })
        completed = Set(completed.filter { $0.activityId != activityId })
    }
}

@MainActor
class LiveActivityService: ObservableObject {
    struct ActiveNotificationSession: Equatable {
        let dockId: String
        let dockName: String
        let expiresAt: Date?
        let scheduledJourneyId: String?
        let scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase?
        let adHocJourneyId: String?
    }

    private struct ActiveJourneyActivitySummary {
        let dockId: String
        let dockName: String
        let phase: ScheduledJourney.ActiveRun.Phase
        let scheduledJourneyId: String?
    }

    private struct DeviceEndResponse: Decodable {
        let success: Bool
        let endedCount: Int
        let remainingCount: Int
    }

    private struct DeviceNotificationStatusResponse: Decodable {
        struct Session: Decodable {
            let dockId: String
            let dockName: String
            let expiresAt: String?
            let scheduledJourneyId: String?
            let scheduledJourneyPhase: String?
            let adHocJourneyId: String?
        }

        let active: Bool
        let session: Session?
    }

    static let shared = LiveActivityService()
    private let serverSessionTokensKey = "liveActivityServerSessionTokensByDock"
    private let availabilityFreshnessSeconds: TimeInterval = 120

    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "LiveActivity")

    /// Active live activities keyed by dock ID
    @Published var activeActivities: [String: Activity<DockActivityAttributes>] = [:]

    /// Notify observers when per-dock primary display changes
    @Published private(set) var primaryDisplayChangeToken = UUID()
    @Published private(set) var activeNotificationSession: ActiveNotificationSession?

    var currentNotificationSession: ActiveNotificationSession? {
        if let activity = activeActivities.values.first {
            let state = activity.content.state
            let phase = ScheduledJourney.ActiveRun.Phase(
                rawValue: state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            )
            return ActiveNotificationSession(
                dockId: state.resolvedDockId ?? activity.attributes.dockId,
                dockName: state.resolvedDockName ?? activity.attributes.dockName,
                expiresAt: activity.content.staleDate,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                scheduledJourneyPhase: phase,
                adHocJourneyId: activity.attributes.adHocJourneyId
            )
        }

        return activeNotificationSession
    }

    private func activeJourneyActivitySummary() -> ActiveJourneyActivitySummary? {
        let activityCandidates = Array(activeActivities.values) +
            Activity<DockActivityAttributes>.activities.filter { isTrackableActivityState($0.activityState) }

        for activity in activityCandidates {
            let state = activity.content.state
            guard let phase = ScheduledJourney.ActiveRun.Phase(
                rawValue: state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            ) else {
                continue
            }

            return ActiveJourneyActivitySummary(
                dockId: state.resolvedDockId ?? activity.attributes.dockId,
                dockName: state.resolvedDockName ?? activity.attributes.dockName,
                phase: phase,
                scheduledJourneyId: activity.attributes.scheduledJourneyId
            )
        }

        if let session = activeNotificationSession,
           let phase = session.scheduledJourneyPhase {
            return ActiveJourneyActivitySummary(
                dockId: session.dockId,
                dockName: session.dockName,
                phase: phase,
                scheduledJourneyId: session.scheduledJourneyId
            )
        }

        return nil
    }

    /// Track stale dates for active activities (keyed by dock ID)
    private var staleDates: [String: Date] = [:]

    /// Track the newest TfL availability timestamp applied locally so older fetches cannot
    /// overwrite fresher Live Activity content when `/Place/:id` and `/BikePoint` disagree.
    private var localActivityAvailabilityModifiedAt: [String: Date] = [:]

    /// Track observation tasks to cancel them when activities end
    private var observationTasks: [String: [Task<Void, Never>]] = [:]
    private var observedActivityIdsByDock: [String: String] = [:]
    private var activityObservedAtById: [String: Date] = [:]
    private var tokenRegistrationTracker = LiveActivityTokenRegistrationTracker()
    private var activityUpdatesTask: Task<Void, Never>?
    private var arrivalMonitoringRecoveryTask: Task<Void, Never>?
    private var arrivalMonitoringRecoveryGeneration: UUID?
    private var arrivalMonitoringAuthorityActivityId: String?
    private var dockPreferencesObserver: NSObjectProtocol?
    private var dockPreferencesRefreshTask: Task<Void, Never>?

    /// Server base URL for the live activity API
    var serverBaseURL: String {
        AppConstants.Server.baseURL
    }

    /// Build type determines APNS environment (sandbox vs production)
    var buildType: String {
        PushEnvironment.buildType
    }

    private init() {
        dockPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .dockPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dockPreferencesRefreshTask?.cancel()
                self.dockPreferencesRefreshTask = Task { [weak self] in
                    guard let self else { return }
                    let bikePoints = await self.fetchAllBikePointsForAlternatives()
                    guard !Task.isCancelled else { return }
                    await self.updateActiveActivitiesIfNeeded(using: bikePoints, refreshPreferences: true)
                }
            }
        }
    }

    deinit {
        // Cancel all observation tasks when service is deallocated
        for (dockId, tasks) in observationTasks {
            for task in tasks {
                task.cancel()
            }
            logger.info("Deinit: Cancelled \(tasks.count) observation task(s) for dock \(dockId)")
        }
        activityUpdatesTask?.cancel()
        arrivalMonitoringRecoveryTask?.cancel()
        dockPreferencesRefreshTask?.cancel()
        if let dockPreferencesObserver { NotificationCenter.default.removeObserver(dockPreferencesObserver) }
    }

    // MARK: - Helper Methods

    /// Cancel all observation tasks for a specific dock to prevent memory leaks
    private func cancelObservationTasks(for dockId: String) {
        if let tasks = observationTasks[dockId] {
            for task in tasks {
                task.cancel()
            }
            observationTasks.removeValue(forKey: dockId)
            logger.info("Cancelled \(tasks.count) observation task(s) for dock \(dockId)")
        }
        if let activityId = observedActivityIdsByDock.removeValue(forKey: dockId) {
            activityObservedAtById.removeValue(forKey: activityId)
            tokenRegistrationTracker.remove(activityId: activityId)
        }
    }

    private func notifyPrimaryDisplayChanged() {
        primaryDisplayChangeToken = UUID()
    }

    private func parseServerISODate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractionalSeconds.date(from: rawValue) {
            return parsed
        }

        let fallbackFormatter = ISO8601DateFormatter()
        return fallbackFormatter.date(from: rawValue)
    }

    private func configuredLiveActivityExpirySeconds() -> TimeInterval {
        let configuredSeconds = AppConstants.UserDefaults.sharedDefaults.double(
            forKey: AppConstants.UserDefaults.liveActivityAutoRemoveDurationKey
        )
        let fallbackSeconds = configuredSeconds > 0
            ? configuredSeconds
            : AppConstants.LiveActivity.defaultAutoRemoveDurationSeconds
        return min(fallbackSeconds, AppConstants.LiveActivity.maxNotificationWindowSeconds)
    }

    private func logLiveActivityDiagnosticEvent(
        _ event: String,
        dockId: String? = nil,
        dockName: String? = nil,
        scheduledJourneyId: String? = nil,
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil,
        message: String? = nil,
        raw: [String: Any] = [:]
    ) {
        let clientTimestamp = ISO8601DateFormatter().string(from: Date())
        let deviceId = DeviceTokenHelper.apnsDeviceToken ?? DeviceTokenHelper.analyticsDeviceToken
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:
            appState = "active"
        case .inactive:
            appState = "inactive"
        case .background:
            appState = "background"
        @unknown default:
            appState = "unknown"
        }

        Task {
            var body: [String: Any] = [
                "event": event,
                "clientTimestamp": clientTimestamp,
                "appState": appState,
                "backgroundRefreshStatus": "live_activity_service",
            ]
            if let deviceId {
                body["deviceId"] = deviceId
            }
            if let dockId {
                body["dockId"] = dockId
            }
            if let dockName {
                body["dockName"] = dockName
            }
            if let message {
                body["message"] = message
            }

            var mergedRaw = raw
            if let scheduledJourneyId {
                mergedRaw["scheduledJourneyId"] = scheduledJourneyId
            }
            if let scheduledJourneyPhase {
                mergedRaw["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
            }
            if !mergedRaw.isEmpty {
                body["raw"] = mergedRaw
            }

            guard let url = URL(string: serverBaseURL + AppConstants.Server.backgroundLocationEventEndpoint) else {
                return
            }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let deviceId {
                    request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    logger.warning("Live activity diagnostic event \(event) returned HTTP \(httpResponse.statusCode)")
                }
            } catch {
                logger.error("Failed to send live activity diagnostic event \(event): \(error.localizedDescription)")
            }
        }
    }

    private func trackedServerSessionsByDock() -> [String: String] {
        AppConstants.UserDefaults.sharedDefaults.dictionary(forKey: serverSessionTokensKey) as? [String: String] ?? [:]
    }

    private func saveTrackedServerSessionsByDock(_ sessions: [String: String]) {
        AppConstants.UserDefaults.sharedDefaults.set(sessions, forKey: serverSessionTokensKey)
    }

    private func trackServerSession(dockId: String, pushToken: String) {
        var sessions = trackedServerSessionsByDock()
        sessions[dockId] = pushToken
        saveTrackedServerSessionsByDock(sessions)
    }

    private func untrackServerSession(dockId: String, pushToken: String?) {
        var sessions = trackedServerSessionsByDock()
        if let pushToken {
            guard sessions[dockId] == pushToken else { return }
        }
        sessions.removeValue(forKey: dockId)
        saveTrackedServerSessionsByDock(sessions)
    }

    private func clearLocallyTrackedActivity(for dockId: String) {
        LiveActivityDockSettings.clearPrimaryDisplay(for: dockId)
        activeActivities.removeValue(forKey: dockId)
        staleDates.removeValue(forKey: dockId)
        localActivityAvailabilityModifiedAt.removeValue(forKey: dockId)
        cancelObservationTasks(for: dockId)
        DockArrivalMonitoringService.shared.stopMonitoring(for: dockId, reason: "live_activity_cleared")
    }

    private func completeAdHocJourneyIfNeeded(for activity: Activity<DockActivityAttributes>) {
        guard let adHocJourneyId = activity.attributes.adHocJourneyId else { return }
        AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
    }

    private func reconcileTrackedServerSessions(activeDockIds: Set<String>) {
        let trackedSessions = trackedServerSessionsByDock()
        guard !trackedSessions.isEmpty else { return }

        for (dockId, pushToken) in trackedSessions where !activeDockIds.contains(dockId) {
            logger.info("Found tracked server session for non-active dock \(dockId); unregistering to stop notifications")
            Task { [weak self] in
                await self?.unregisterFromServer(dockId: dockId, pushToken: pushToken)
            }
        }
    }

    /// End all active activities except the specified dock (if provided)
    private func endAllActivities(except dockId: String?) {
        let activeDockIds = activeActivities.keys.filter { $0 != dockId }
        guard !activeDockIds.isEmpty else { return }

        for activeDockId in activeDockIds {
            logger.info("Ending existing live activity for dock \(activeDockId) to enforce single active activity")
            endLiveActivity(for: activeDockId)
        }
    }

    /// End a specific activity instance without relying on stored state
    private func endActivityInstance(
        _ activity: Activity<DockActivityAttributes>,
        dockId: String,
        skipServerUnregister: Bool = false
    ) async {
        if !skipServerUnregister {
            JourneySyncService.shared.markEnded(journeyId: activity.attributes.scheduledJourneyId ?? activity.attributes.adHocJourneyId, activityId: activity.id)
        }
        completeAdHocJourneyIfNeeded(for: activity)

        if !skipServerUnregister, let pushToken = activity.pushToken {
            let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
            await unregisterFromServer(dockId: dockId, pushToken: tokenString)
        }

        clearLocallyTrackedActivity(for: dockId)
        notifyPrimaryDisplayChanged()

        let finalState = activity.content.state
        let finalContent = ActivityContent(state: finalState, staleDate: nil)
        await activity.end(finalContent, dismissalPolicy: .immediate)
        logger.info("Ended extra live activity for dock \(dockId)")
    }

    private func scheduledJourneyPhase(
        for activity: Activity<DockActivityAttributes>
    ) -> ScheduledJourney.ActiveRun.Phase? {
        ScheduledJourney.ActiveRun.Phase(
            rawValue: activity.content.state.activeJourneyPhase
                ?? activity.attributes.scheduledJourneyPhase
                ?? ""
        )
    }

    private func isTrackableActivityState(_ state: ActivityState) -> Bool {
        state == .active || state == .stale
    }

    private func registerActivityTokenIfNeeded(
        for activity: Activity<DockActivityAttributes>,
        pushToken: Data,
        source: String,
        force: Bool = false,
        alternatives: [DockActivityAttributes.AlternativeDock]? = nil,
        attempt: Int = 1
    ) async {
        let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
        let key = LiveActivityTokenRegistrationKey(
            activityId: activity.id,
            pushToken: tokenString
        )
        guard tokenRegistrationTracker.begin(key, force: force) else {
            logLiveActivityDiagnosticEvent(
                "live_activity_server_registration_deduplicated",
                dockId: activity.content.state.resolvedDockId ?? activity.attributes.dockId,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase(for: activity),
                message: "Skipped a duplicate ActivityKit token registration",
                raw: [
                    "activityId": activity.id,
                    "pushTokenPrefix": String(tokenString.prefix(8)),
                    "source": source,
                ]
            )
            return
        }

        let state = activity.content.state
        let dockId = state.resolvedDockId ?? activity.attributes.dockId
        let dockName = state.resolvedDockName ?? activity.attributes.dockName
        let phase = scheduledJourneyPhase(for: activity)
        let observedAt = activityObservedAtById[activity.id] ?? Date()
        let tokenLatencySeconds = max(0, Date().timeIntervalSince(observedAt))
        logLiveActivityDiagnosticEvent(
            "live_activity_push_token_registration_started",
            dockId: dockId,
            dockName: dockName,
            scheduledJourneyId: activity.attributes.scheduledJourneyId,
            scheduledJourneyPhase: phase,
            message: "Registering an ActivityKit update token without blocking on availability enrichment",
            raw: [
                "activityId": activity.id,
                "pushTokenPrefix": String(tokenString.prefix(8)),
                "source": source,
                "tokenLatencySeconds": tokenLatencySeconds,
                "attempt": attempt,
            ]
        )

        let succeeded = await registerWithServer(
            dockId: dockId,
            pushToken: tokenString,
            dockName: dockName,
            alternatives: alternatives ?? state.alternatives,
            currentState: state,
            scheduledJourneyId: activity.attributes.scheduledJourneyId,
            scheduledJourneyPhase: phase,
            adHocJourneyId: activity.attributes.adHocJourneyId
        )
        tokenRegistrationTracker.finish(key, succeeded: succeeded)
        guard !succeeded,
              attempt < 3,
              isTrackableActivityState(activity.activityState) else {
            return
        }

        let retryDelayNanoseconds = UInt64(attempt * 2) * 1_000_000_000
        try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        guard !Task.isCancelled else { return }
        await registerActivityTokenIfNeeded(
            for: activity,
            pushToken: pushToken,
            source: "\(source)_retry",
            force: force,
            alternatives: alternatives,
            attempt: attempt + 1
        )
    }

    private func ensureActivityObservation(
        for activity: Activity<DockActivityAttributes>,
        source: String
    ) {
        let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        guard observedActivityIdsByDock[dockId] != activity.id || observationTasks[dockId] == nil else {
            if let pushToken = activity.pushToken {
                Task { [weak self] in
                    await self?.registerActivityTokenIfNeeded(
                        for: activity,
                        pushToken: pushToken,
                        source: "\(source)_existing_observer"
                    )
                }
            }
            return
        }

        cancelObservationTasks(for: dockId)
        observedActivityIdsByDock[dockId] = activity.id
        activityObservedAtById[activity.id] = activityObservedAtById[activity.id] ?? Date()
        let phase = scheduledJourneyPhase(for: activity)
        logLiveActivityDiagnosticEvent(
            "live_activity_observation_started",
            dockId: dockId,
            dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName,
            scheduledJourneyId: activity.attributes.scheduledJourneyId,
            scheduledJourneyPhase: phase,
            message: "Started ActivityKit token and state observation",
            raw: [
                "activityId": activity.id,
                "pushTokenAvailable": activity.pushToken != nil,
                "source": source,
            ]
        )

        let pushTokenTask = Task { [weak self] in
            for await pushToken in activity.pushTokenUpdates {
                guard let self else { break }
                await self.registerActivityTokenIfNeeded(
                    for: activity,
                    pushToken: pushToken,
                    source: "\(source)_push_token_update"
                )
            }
        }

        let stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { break }
                let currentDockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
                if state == .stale {
                    self.logLiveActivityDiagnosticEvent(
                        "live_activity_content_stale",
                        dockId: currentDockId,
                        dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName,
                        scheduledJourneyId: activity.attributes.scheduledJourneyId,
                        scheduledJourneyPhase: self.scheduledJourneyPhase(for: activity),
                        message: "Activity availability content is stale; keeping the journey active while awaiting a refresh",
                        raw: ["activityId": activity.id]
                    )
                } else if state == .dismissed || state == .ended {
                    JourneySyncService.shared.markEnded(journeyId: activity.attributes.scheduledJourneyId ?? activity.attributes.adHocJourneyId, activityId: activity.id)
                    if let adHocJourneyId = activity.attributes.adHocJourneyId {
                        AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
                    }
                    self.clearLocallyTrackedActivity(for: currentDockId)
                    self.notifyPrimaryDisplayChanged()
                    await ScheduledJourneyService.shared.refresh()
                    JourneySyncService.shared.publish()
                    if let pushToken = activity.pushToken {
                        let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                        await self.unregisterFromServer(dockId: currentDockId, pushToken: tokenString)
                    }
                    break
                }
            }
        }

        let contentTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard let self else { break }
                let currentDockId = content.state.resolvedDockId ?? activity.attributes.dockId
                self.staleDates[currentDockId] = content.staleDate
                JourneySyncService.shared.publish()
                self.logLiveActivityDiagnosticEvent(
                    "live_activity_content_update_received",
                    dockId: currentDockId,
                    dockName: content.state.resolvedDockName ?? activity.attributes.dockName,
                    scheduledJourneyId: activity.attributes.scheduledJourneyId,
                    scheduledJourneyPhase: self.scheduledJourneyPhase(for: activity),
                    message: "Received updated Live Activity availability content",
                    raw: [
                        "activityId": activity.id,
                        "standardBikes": content.state.standardBikes,
                        "eBikes": content.state.eBikes,
                        "emptySpaces": content.state.emptySpaces,
                        "availabilityUpdatedAtEpochSeconds": content.state.availabilityUpdatedAtEpochSeconds ?? -1,
                        "staleDate": content.staleDate?.ISO8601Format() ?? "none",
                    ]
                )
            }
        }

        observationTasks[dockId] = [pushTokenTask, stateTask, contentTask]

        if let pushToken = activity.pushToken {
            Task { [weak self] in
                await self?.registerActivityTokenIfNeeded(
                    for: activity,
                    pushToken: pushToken,
                    source: "\(source)_initial_token"
                )
            }
        } else {
            logLiveActivityDiagnosticEvent(
                "live_activity_initial_push_token_missing",
                dockId: dockId,
                dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                scheduledJourneyPhase: phase,
                message: "ActivityKit update token was not yet available; the async observer remains armed",
                raw: [
                    "activityId": activity.id,
                    "source": source,
                ]
            )
        }
    }

    // MARK: - Public API

    func startLiveActivity(
        for bikePoint: BikePoint,
        alias: String?,
        alternatives: [BikePoint] = [],
        scheduledJourneyId: String? = nil,
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil,
        adHocJourneyId: String? = nil,
        destinationDock: ScheduledJourneyDock? = nil
    ) {
        let dockId = bikePoint.id
        let alias = DockPreferencesService.shared.alias(for: dockId) ?? alias

        if scheduledJourneyPhase == nil,
           let activeJourney = activeJourneyActivitySummary() {
            logger.warning("Ignoring regular live activity start for \(dockId) because journey activity is active for \(activeJourney.dockId)")
            TroubleshootingLogStore.shared.record(
                category: "live_activity",
                event: "regular_start_blocked_active_journey",
                message: "Ignored regular Live Activity start while a journey Live Activity is active.",
                metadata: [
                    "requestedDockId": dockId,
                    "requestedDockName": bikePoint.commonName,
                    "activeDockId": activeJourney.dockId,
                    "activeDockName": activeJourney.dockName,
                    "activeJourneyPhase": activeJourney.phase.rawValue,
                ]
            )
            logLiveActivityDiagnosticEvent(
                "live_activity_regular_start_blocked_active_journey",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: activeJourney.scheduledJourneyId,
                scheduledJourneyPhase: activeJourney.phase,
                message: "Ignored regular live activity start while a journey is active",
                raw: [
                    "activeDockId": activeJourney.dockId,
                    "activeDockName": activeJourney.dockName,
                ]
            )
            return
        }

        // Enforce a single active live activity across the app
        endAllActivities(except: dockId)

        // End existing activity for this dock if one exists
        if activeActivities[dockId] != nil {
            logLiveActivityDiagnosticEvent(
                "live_activity_start_duplicate_existing_activity",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "Start requested for a dock that already has an active local activity; ending existing activity instead"
            )
            endLiveActivity(for: dockId)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("Live Activities are not enabled on this device")
            logLiveActivityDiagnosticEvent(
                "live_activity_start_blocked_authorization",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "ActivityAuthorizationInfo reported Live Activities disabled"
            )
            return
        }

        let attributes = DockActivityAttributes(
            dockId: dockId,
            dockName: bikePoint.commonName,
            alias: alias,
            scheduledJourneyId: scheduledJourneyId,
            scheduledJourneyPhase: scheduledJourneyPhase?.rawValue,
            adHocJourneyId: adHocJourneyId,
            latitude: bikePoint.lat,
            longitude: bikePoint.lon,
            destinationDockId: destinationDock?.id,
            destinationDockName: destinationDock?.name,
            destinationLatitude: destinationDock?.latitude,
            destinationLongitude: destinationDock?.longitude
        )

        let selectedAlternatives: [BikePoint]
        if DockPreferencesService.shared.customDockIDs(for: dockId) != nil {
            let candidates = Dictionary(
                (AllBikePointsCache.shared.load() + alternatives + [bikePoint]).map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let purpose: AlternativeDockPurpose
            switch scheduledJourneyPrimaryDisplay(dockId: dockId, scheduledJourneyPhase: scheduledJourneyPhase) {
            case "spaces": purpose = .spaces
            case "eBikes": purpose = .eBikes
            case "allBikes": purpose = .allBikes
            default: purpose = .bikes
            }
            selectedAlternatives = AlternativeDockSelectionService.alternatives(
                for: bikePoint,
                allBikePoints: Array(candidates.values),
                favorites: FavoritesService.shared.favorites,
                userLocation: nil,
                purpose: purpose
            )
        } else {
            selectedAlternatives = alternatives
        }

        // Store up to 5 nearby alternatives; the watch view caps display at 2–3 based on filter preference.
        let alternativeDocks = selectedAlternatives.prefix(5).map(alternativeSnapshot)

        let initialState = DockActivityAttributes.ContentState(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            alternatives: Array(alternativeDocks),
            activeDockId: dockId,
            activeDockName: bikePoint.commonName,
            activeDockAlias: alias,
            activeJourneyPhase: scheduledJourneyPhase?.rawValue,
            primaryDisplay: scheduledJourneyPrimaryDisplay(
                dockId: dockId,
                scheduledJourneyPhase: scheduledJourneyPhase
            ),
            availabilityUpdatedAtEpochSeconds: Int(Date().timeIntervalSince1970),
            rideStartedAtEpochSeconds: scheduledJourneyPhase == .end ? Date().timeIntervalSince1970 : nil
        )

        // `staleDate` represents availability freshness. The server separately owns
        // the configured session expiry and sends an explicit end event at that time.
        let finalExpirySeconds = configuredLiveActivityExpirySeconds()
        let staleDate = Date().addingTimeInterval(availabilityFreshnessSeconds)

        let content = ActivityContent(state: initialState, staleDate: staleDate)

        do {
            TroubleshootingLogStore.shared.record(
                category: "live_activity",
                event: "start_requesting",
                message: "Requesting ActivityKit Live Activity.",
                metadata: [
                    "dockId": dockId,
                    "dockName": bikePoint.commonName,
                    "scheduledJourneyId": scheduledJourneyId,
                    "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                    "standardBikes": bikePoint.standardBikes,
                    "eBikes": bikePoint.eBikes,
                    "emptySpaces": bikePoint.emptyDocks,
                    "alternativesCount": alternativeDocks.count,
                    "expirySeconds": Int(finalExpirySeconds),
                ]
            )
            logLiveActivityDiagnosticEvent(
                "live_activity_start_requesting",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "Requesting ActivityKit live activity",
                raw: [
                    "standardBikes": bikePoint.standardBikes,
                    "eBikes": bikePoint.eBikes,
                    "emptySpaces": bikePoint.emptyDocks,
                    "alternativesCount": alternativeDocks.count,
                ]
            )
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )

            activeActivities[dockId] = activity
            staleDates[dockId] = staleDate
            logger.info("Started live activity for dock \(dockId) with stale date: \(staleDate)")
            TroubleshootingLogStore.shared.record(
                category: "live_activity",
                event: "start_succeeded",
                message: "ActivityKit Live Activity request succeeded.",
                metadata: [
                    "dockId": dockId,
                    "dockName": bikePoint.commonName,
                    "activityId": activity.id,
                    "scheduledJourneyId": scheduledJourneyId,
                    "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                ]
            )
            logLiveActivityDiagnosticEvent(
                "live_activity_start_succeeded",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "ActivityKit live activity request succeeded",
                raw: ["activityId": activity.id]
            )
            if let scheduledJourneyId, let scheduledJourneyPhase {
                DockArrivalMonitoringService.shared.beginMonitoring(
                    for: bikePoint,
                    scheduledJourneyId: scheduledJourneyId,
                    phase: scheduledJourneyPhase,
                    adHocJourneyId: adHocJourneyId,
                    destinationDock: destinationDock
                )
            } else if let scheduledJourneyPhase {
                DockArrivalMonitoringService.shared.beginMonitoring(
                    for: bikePoint,
                    phase: scheduledJourneyPhase,
                    adHocJourneyId: adHocJourneyId,
                    destinationDock: destinationDock
                )
            } else {
                DockArrivalMonitoringService.shared.beginMonitoring(for: bikePoint)
            }

            ensureActivityObservation(for: activity, source: "local_start")
        } catch {
            logger.error("Failed to start live activity: \(error.localizedDescription)")
            TroubleshootingLogStore.shared.record(
                category: "live_activity",
                event: "start_failed",
                message: "ActivityKit Live Activity request failed: \(error.localizedDescription)",
                metadata: [
                    "dockId": dockId,
                    "dockName": bikePoint.commonName,
                    "scheduledJourneyId": scheduledJourneyId,
                    "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                ]
            )
            logLiveActivityDiagnosticEvent(
                "live_activity_start_failed",
                dockId: dockId,
                dockName: bikePoint.commonName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "ActivityKit live activity request failed: \(error.localizedDescription)"
            )
        }
    }

    func endLiveActivity(for dockId: String, skipServerUnregister: Bool = false) {
        guard let activity = activeActivities[dockId] else { return }
        if !skipServerUnregister {
            JourneySyncService.shared.markEnded(journeyId: activity.attributes.scheduledJourneyId ?? activity.attributes.adHocJourneyId, activityId: activity.id)
        }

        // Remove from active tracking synchronously to prevent double-end races
        activeActivities.removeValue(forKey: dockId)
        staleDates.removeValue(forKey: dockId)
        localActivityAvailabilityModifiedAt.removeValue(forKey: dockId)

        // Cancel observation tasks before ending so state observer doesn't react to .ended.
        // Journey activities can be re-keyed from their immutable attribute dock to the current dock.
        cancelObservationTasks(for: dockId)
        if activity.attributes.dockId != dockId {
            cancelObservationTasks(for: activity.attributes.dockId)
        }
        completeAdHocJourneyIfNeeded(for: activity)

        // Clear the per-dock override
        LiveActivityDockSettings.clearPrimaryDisplay(for: dockId)
        notifyPrimaryDisplayChanged()
        DockArrivalMonitoringService.shared.stopMonitoring(for: dockId, reason: "live_activity_ended")

        let finalState = activity.content.state
        let finalContent = ActivityContent(state: finalState, staleDate: nil)

        let pushTokenString = activity.pushToken.map { $0.map { String(format: "%02x", $0) }.joined() }
        Task {
            await activity.end(finalContent, dismissalPolicy: .immediate)
            if !skipServerUnregister, let tokenString = pushTokenString {
                await unregisterFromServer(dockId: dockId, pushToken: tokenString)
            }
            await refreshNotificationStatusFromServer()
            logger.info("Ended live activity for dock \(dockId)")
        }
    }

    /// Ends every currently active Live Activity tied to a scheduled journey (leaving
    /// ad hoc journey activities untouched). Used when holiday mode is enabled so
    /// nothing scheduled-journey-related lingers in the Dynamic Island/Lock Screen.
    func endAllScheduledJourneyActivities(reason: String) async {
        let dockIds = activeActivities.compactMap { dockId, activity in
            activity.attributes.scheduledJourneyId != nil ? dockId : nil
        }
        guard !dockIds.isEmpty else { return }
        logger.info("Ending \(dockIds.count) scheduled journey live activities (\(reason))")
        for dockId in dockIds {
            endLiveActivity(for: dockId)
        }
    }

    /// Ends every in-progress journey and notification when holiday mode is enabled.
    func endAllActivitiesAndNotifications(reason: String) async {
        let activities = activeActivityCandidates()
        logger.info("Ending \(activities.count) live activities and notifications (\(reason))")

        _ = await endAllLiveActivityNotificationsOnServer()

        for activity in activities {
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
            await endActivityInstance(activity, dockId: dockId, skipServerUnregister: true)
        }

        saveTrackedServerSessionsByDock([:])
        activeNotificationSession = nil
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        DockArrivalMonitoringService.shared.stopMonitoring(reason: reason)
    }

    func isActivityActive(for dockId: String) -> Bool {
        activeActivities[dockId] != nil
    }

    func pushTokenForArrival(for dockId: String) -> String? {
        activeActivities[dockId]?.pushToken.map {
            $0.map { String(format: "%02x", $0) }.joined()
        }
    }

    func activeJourneyPhase(for dockId: String) -> ScheduledJourney.ActiveRun.Phase? {
        if let activity = activeActivities[dockId] {
            return ScheduledJourney.ActiveRun.Phase(
                rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            )
        }

        if let session = activeNotificationSession, session.dockId == dockId {
            return session.scheduledJourneyPhase
        }

        return nil
    }

    func updateActiveActivitiesIfNeeded(using bikePoints: [BikePoint], refreshPreferences: Bool = false) async {
        guard refreshPreferences || !bikePoints.isEmpty else { return }

        let bikePointsById = Dictionary(
            bikePoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bikePointsByName = Dictionary(
            bikePoints.map { ($0.commonName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var selectionBikePointsById = Dictionary(
            AllBikePointsCache.shared.load().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        selectionBikePointsById.merge(bikePointsById, uniquingKeysWith: { _, latest in latest })

        var activitiesById: [String: Activity<DockActivityAttributes>] = activeActivities
        for activity in Activity<DockActivityAttributes>.activities where isTrackableActivityState(activity.activityState) {
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
            activitiesById[dockId] = activity
        }

        for (dockId, activity) in activitiesById {
            guard !Task.isCancelled else { return }
            let currentState = activity.content.state
            let activeDockId = currentState.resolvedDockId ?? activity.attributes.dockId
            let fallbackBikePoint = refreshPreferences
                ? DockActivityMonitoringResolver.resolve(attributes: activity.attributes, state: currentState)?.bikePoint
                : nil
            guard let bikePoint = bikePointsById[activeDockId] ?? fallbackBikePoint else { continue }
            if !refreshPreferences,
               let incomingModifiedAt = bikePoint.availabilityDataModifiedAt,
               let appliedModifiedAt = localActivityAvailabilityModifiedAt[activeDockId],
               incomingModifiedAt < appliedModifiedAt {
                logger.info(
                    "Skipping older live activity refresh for dock \(activeDockId): incoming=\(incomingModifiedAt), applied=\(appliedModifiedAt)"
                )
                continue
            }

            let refreshedAlternatives: [DockActivityAttributes.AlternativeDock]
            if refreshPreferences || DockPreferencesService.shared.customDockIDs(for: activeDockId) != nil {
                refreshedAlternatives = AlternativeDockSelectionService.alternatives(
                    for: bikePoint,
                    allBikePoints: Array(selectionBikePointsById.values),
                    favorites: FavoritesService.shared.favorites,
                    userLocation: nil,
                    purpose: alternativePurpose(for: activity)
                )
                .prefix(5)
                .map(alternativeSnapshot)
            } else {
                refreshedAlternatives = currentState.alternatives.map { alternative in
                    // Only legacy snapshots without IDs may fall back to matching official names.
                    let refreshed = alternative.id.map { bikePointsById[$0] } ?? bikePointsByName[alternative.name]
                    guard let refreshed else { return alternative }
                    return alternativeSnapshot(for: refreshed)
                }
            }

            let availabilityChanged =
                currentState.standardBikes != bikePoint.standardBikes ||
                currentState.eBikes != bikePoint.eBikes ||
                currentState.emptySpaces != bikePoint.emptyDocks
            let alternativesChanged = refreshedAlternatives != currentState.alternatives

            let alias = DockPreferencesService.shared.alias(for: activeDockId)
            let updatedState = DockActivityAttributes.ContentState(
                standardBikes: refreshPreferences ? currentState.standardBikes : bikePoint.standardBikes,
                eBikes: refreshPreferences ? currentState.eBikes : bikePoint.eBikes,
                emptySpaces: refreshPreferences ? currentState.emptySpaces : bikePoint.emptyDocks,
                alternatives: refreshedAlternatives,
                activeDockId: currentState.activeDockId ?? activeDockId,
                activeDockName: currentState.activeDockName ?? bikePoint.commonName,
                activeDockAlias: alias,
                activeJourneyPhase: currentState.activeJourneyPhase,
                primaryDisplay: currentState.primaryDisplay,
                availabilityUpdatedAtEpochSeconds: refreshPreferences
                    ? currentState.availabilityUpdatedAtEpochSeconds
                    : Int(Date().timeIntervalSince1970),
                journeyProgress: currentState.journeyProgress,
                rideStartedAtEpochSeconds: currentState.rideStartedAtEpochSeconds
            )
            guard refreshPreferences || availabilityChanged || alternativesChanged || updatedState.resolvedAlias != currentState.resolvedAlias else {
                continue
            }
            let staleDate = refreshPreferences
                ? activity.content.staleDate
                : Date().addingTimeInterval(availabilityFreshnessSeconds)

            await activity.update(ActivityContent(state: updatedState, staleDate: staleDate))
            if dockId != activeDockId {
                activeActivities.removeValue(forKey: dockId)
                staleDates.removeValue(forKey: dockId)
                localActivityAvailabilityModifiedAt.removeValue(forKey: dockId)
            }
            activeActivities[activeDockId] = activity
            staleDates[activeDockId] = staleDate
            if !refreshPreferences, let incomingModifiedAt = bikePoint.availabilityDataModifiedAt {
                localActivityAvailabilityModifiedAt[activeDockId] = incomingModifiedAt
            }
            if refreshPreferences, let pushToken = activity.pushToken {
                await updateSessionConfigurationOnServer(
                    dockId: activeDockId,
                    pushToken: pushToken.map { String(format: "%02x", $0) }.joined(),
                    dockName: updatedState.resolvedDockName ?? bikePoint.commonName,
                    primaryDisplay: getPrimaryDisplay(for: activeDockId),
                    alternatives: refreshedAlternatives,
                    currentState: updatedState,
                    scheduledJourneyPhase: scheduledJourneyPhase(for: activity)
                )
            }
            logger.info(
                "Locally refreshed live activity for dock \(activeDockId): bikes=\(bikePoint.standardBikes), eBikes=\(bikePoint.eBikes), spaces=\(bikePoint.emptyDocks)"
            )
        }
    }

    func endLiveActivityFromUserAction(dockId: String, dockName: String?, reason: String) async {
        let trimmedDockId = dockId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDockId.isEmpty else { return }

        let trimmedDockName = dockName?.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Ending live activity from user action (\(reason)) for dock \(trimmedDockId)")

        let endedLocally: Bool
        if activeActivities[trimmedDockId] != nil {
            endLiveActivity(for: trimmedDockId, skipServerUnregister: true)
            endedLocally = true
        } else if let activity = Activity<DockActivityAttributes>.activities.first(where: {
            $0.attributes.dockId == trimmedDockId && $0.activityState != .dismissed && $0.activityState != .ended
        }) {
            await endActivityInstance(activity, dockId: trimmedDockId, skipServerUnregister: true)
            await refreshNotificationStatusFromServer()
            endedLocally = true
        } else {
            clearLocallyTrackedActivity(for: trimmedDockId)
            notifyPrimaryDisplayChanged()
            endedLocally = false
        }

        let mutedOnServer = await endLiveActivityNotificationsOnServer(for: trimmedDockId)
        AnalyticsService.shared.track(
            action: .liveActivityEnd,
            screen: .app,
            dock: AnalyticsDockInfo(id: trimmedDockId, name: trimmedDockName),
            metadata: [
                "reason": reason,
                "endedLocally": endedLocally,
                "mutedOnServer": mutedOnServer,
            ]
        )
    }

    func performWatchJourneyAction(action: String, dockId: String) async -> Bool {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDockId = dockId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty, !trimmedDockId.isEmpty else { return false }

        switch trimmedAction {
        case "advance":
            return await advanceJourneyFromStart(dockId: trimmedDockId, source: "watch")
        case "end":
            if currentNotificationSession == nil {
                await refreshNotificationStatusFromServer()
            }
            guard let session = currentNotificationSession else { return false }
            await endLiveActivityFromUserAction(
                dockId: session.dockId,
                dockName: session.dockName,
                reason: "watch_journey_end"
            )
            if let scheduledJourneyId = session.scheduledJourneyId {
                await ScheduledJourneyService.shared.complete(journeyId: scheduledJourneyId)
            }
            if let adHocJourneyId = session.adHocJourneyId {
                AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
            }
            return true
        default:
            return false
        }
    }

    func refreshNotificationStatusFromServer() async {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            activeNotificationSession = nil
            return
        }

        let urlString = "\(serverBaseURL)\(AppConstants.Server.liveActivityDeviceStatusEndpoint)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid notification status URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")

        let body: [String: String] = [
            "deviceToken": deviceToken,
            "buildType": buildType,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.warning("Non-HTTP response while checking notification status")
                return
            }

            guard httpResponse.statusCode == 200 else {
                logger.warning("Unexpected status (\(httpResponse.statusCode)) while checking notification status")
                return
            }

            let decoded = try JSONDecoder().decode(DeviceNotificationStatusResponse.self, from: data)

            if decoded.active, let session = decoded.session {
                activeNotificationSession = ActiveNotificationSession(
                    dockId: session.dockId,
                    dockName: session.dockName,
                    expiresAt: parseServerISODate(session.expiresAt),
                    scheduledJourneyId: session.scheduledJourneyId,
                    scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase(rawValue: session.scheduledJourneyPhase ?? ""),
                    adHocJourneyId: session.adHocJourneyId
                )
            } else {
                activeNotificationSession = nil
            }
        } catch {
            logger.error("Failed to refresh notification status: \(error.localizedDescription)")
        }
    }

    func startActivityUpdateObservation() {
        guard activityUpdatesTask == nil else { return }
        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<DockActivityAttributes>.activityUpdates {
                guard let self else { break }
                await self.handleObservedActivity(activity)
            }
        }
    }

    func startScheduledJourney(
        _ journey: ScheduledJourney,
        phase: ScheduledJourney.ActiveRun.Phase,
        manuallyActivated: Bool = false
    ) async {
        let dock = phase == .start ? journey.startDock : journey.endDock
        let destination = phase == .start ? journey.endDock : nil
        TroubleshootingLogStore.shared.record(
            category: "scheduled_journey",
            event: manuallyActivated ? "manual_start_live_activity" : "remote_start_live_activity",
            message: "Starting Live Activity for scheduled journey.",
            metadata: [
                "journeyId": journey.id,
                "phase": phase.rawValue,
                "dockId": dock.id,
                "dockName": dock.name,
                "startTime": journey.startTime,
                "endTime": journey.endTime,
                "timezone": journey.timezone,
            ]
        )

        let bikePoint = await fetchBikePointIfPossible(dock: dock)
        let alternatives = await scheduledJourneyAlternatives(for: bikePoint, phase: phase)
        startLiveActivity(
            for: bikePoint,
            alias: nil,
            alternatives: alternatives,
            scheduledJourneyId: journey.id,
            scheduledJourneyPhase: phase,
            destinationDock: destination
        )

        if manuallyActivated {
            AnalyticsService.shared.track(
                action: .liveActivityStart,
                screen: .profile,
                dock: AnalyticsDockInfo(id: dock.id, name: dock.name),
                metadata: ["source": "scheduled_journey_manual_activate"]
            )
        }
    }

    func startAdHocJourney(_ journey: AdHocJourney) async {
        let bikePoint = await fetchBikePointIfPossible(dock: journey.startDock)
        let alternatives = await scheduledJourneyAlternatives(for: bikePoint, phase: .start)
        startLiveActivity(
            for: bikePoint,
            alias: nil,
            alternatives: alternatives,
            scheduledJourneyPhase: .start,
            adHocJourneyId: journey.id,
            destinationDock: journey.endDock
        )
    }

    func advanceJourneyFromStart(dockId: String, source: String = "unknown") async -> Bool {
        guard let activity = activeActivities[dockId] ?? activeActivities.values.first(where: {
            $0.attributes.scheduledJourneyPhase == ScheduledJourney.ActiveRun.Phase.start.rawValue
        }),
              activity.attributes.scheduledJourneyPhase == ScheduledJourney.ActiveRun.Phase.start.rawValue,
              let destinationDockId = activity.attributes.destinationDockId,
              let destinationDockName = activity.attributes.destinationDockName,
              let destinationLatitude = activity.attributes.destinationLatitude,
              let destinationLongitude = activity.attributes.destinationLongitude else {
            return false
        }

        let endDock = ScheduledJourneyDock(
            id: destinationDockId,
            name: destinationDockName,
            latitude: destinationLatitude,
            longitude: destinationLongitude
        )
        TroubleshootingLogStore.shared.record(
            category: "scheduled_journey",
            event: "manual_advance",
            message: "Manually advanced the journey from its start dock to its destination.",
            metadata: [
                "source": source,
                "fromDockId": activity.content.state.resolvedDockId ?? activity.attributes.dockId,
                "toDockId": endDock.id,
                "scheduledJourneyId": activity.attributes.scheduledJourneyId,
                "adHocJourneyId": activity.attributes.adHocJourneyId,
            ]
        )
        logLiveActivityDiagnosticEvent(
            "scheduled_journey_manual_advance",
            dockId: activity.content.state.resolvedDockId ?? activity.attributes.dockId,
            dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName,
            scheduledJourneyId: activity.attributes.scheduledJourneyId,
            scheduledJourneyPhase: .start,
            message: "Journey manually advanced to its destination dock",
            raw: [
                "source": source,
                "destinationDockId": endDock.id,
            ]
        )
        await transitionScheduledJourneyToEndDock(
            journeyId: activity.attributes.scheduledJourneyId,
            adHocJourneyId: activity.attributes.adHocJourneyId,
            endDock: endDock,
            delaySeconds: 0
        )
        return true
    }

    func advanceScheduledJourneyFromStart(dockId: String) async -> Bool {
        await advanceJourneyFromStart(dockId: dockId, source: "scheduled_journey_action")
    }

    private func scheduledStartActivity(
        journeyId: String?,
        adHocJourneyId: String?
    ) -> Activity<DockActivityAttributes>? {
        activeActivityCandidates().first { activity in
            let phase = ScheduledJourney.ActiveRun.Phase(
                rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            )
            return phase == .start
                && (journeyId == nil || activity.attributes.scheduledJourneyId == journeyId)
                && (adHocJourneyId == nil || activity.attributes.adHocJourneyId == adHocJourneyId)
        }
    }

    private func activeActivityFallback() -> Activity<DockActivityAttributes>? {
        activeActivityCandidates().first
    }

    private func activeActivityCandidates() -> [Activity<DockActivityAttributes>] {
        var seenActivityIds = Set<String>()
        var candidates: [Activity<DockActivityAttributes>] = []

        for activity in activeActivities.values {
            guard seenActivityIds.insert(activity.id).inserted else { continue }
            candidates.append(activity)
        }

        for activity in Activity<DockActivityAttributes>.activities where isTrackableActivityState(activity.activityState) {
            guard seenActivityIds.insert(activity.id).inserted else { continue }
            candidates.append(activity)
        }

        return candidates
    }

    func transitionScheduledJourneyToEndDock(
        journeyId: String?,
        adHocJourneyId: String? = nil,
        endDock: ScheduledJourneyDock,
        delaySeconds: UInt64 = 60,
        transitionSource: String = "manual"
    ) async {
        let current = scheduledStartActivity(
            journeyId: journeyId,
            adHocJourneyId: adHocJourneyId
        ) ?? activeActivityFallback()

        let rideStartedAt = current?.content.state.rideStartedAtEpochSeconds ?? Date().timeIntervalSince1970

        logLiveActivityDiagnosticEvent(
            "scheduled_transition_to_end_started",
            dockId: endDock.id,
            dockName: endDock.name,
            scheduledJourneyId: journeyId,
            scheduledJourneyPhase: .end,
            message: "Starting background-safe scheduled journey handoff to destination dock",
            raw: ["activeLocalActivities": activeActivities.count]
        )

        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        logLiveActivityDiagnosticEvent(
            "scheduled_transition_phase_update_started",
            dockId: endDock.id,
            dockName: endDock.name,
            scheduledJourneyId: journeyId,
            scheduledJourneyPhase: .end,
            message: "Updating scheduled journey server phase to destination"
        )
        if let journeyId {
            await ScheduledJourneyService.shared.updatePhase(
                journeyId: journeyId,
                phase: .end,
                transitionSource: transitionSource
            )
        }
        if let adHocJourneyId {
            AdHocJourneyService.shared.markPhase(journeyId: adHocJourneyId, phase: .end)
        }

        let endBikePoint = await fetchBikePointIfPossible(dock: endDock)
        let alternatives = await scheduledJourneyAlternatives(for: endBikePoint, phase: .end)
        let alternativeDocks = alternatives.prefix(5).map(alternativeSnapshot)
        let updatedState = DockActivityAttributes.ContentState(
            standardBikes: endBikePoint.standardBikes,
            eBikes: endBikePoint.eBikes,
            emptySpaces: endBikePoint.emptyDocks,
            alternatives: Array(alternativeDocks),
            activeDockId: endBikePoint.id,
            activeDockName: endBikePoint.commonName,
            activeDockAlias: DockPreferencesService.shared.alias(for: endBikePoint.id),
            activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue,
            primaryDisplay: LiveActivityPrimaryDisplay.spaces.rawValue,
            availabilityUpdatedAtEpochSeconds: Int(Date().timeIntervalSince1970),
            rideStartedAtEpochSeconds: rideStartedAt
        )
        let staleDate = Date().addingTimeInterval(availabilityFreshnessSeconds)

        if let current {
            let originalDockId = current.attributes.dockId
            let originalDockName = current.attributes.dockName
            logLiveActivityDiagnosticEvent(
                "scheduled_transition_existing_activity_update_started",
                dockId: endBikePoint.id,
                dockName: endBikePoint.commonName,
                scheduledJourneyId: journeyId,
                scheduledJourneyPhase: .end,
                message: "Updating existing journey Live Activity content state instead of starting a new activity",
                raw: [
                    "originalDockId": originalDockId,
                    "originalDockName": originalDockName,
                    "alternativesCount": alternativeDocks.count,
                ]
            )

            await current.update(ActivityContent(state: updatedState, staleDate: staleDate))

            activeActivities.removeValue(forKey: originalDockId)
            activeActivities[endBikePoint.id] = current
            staleDates.removeValue(forKey: originalDockId)
            staleDates[endBikePoint.id] = staleDate
            if let tasks = observationTasks.removeValue(forKey: originalDockId) {
                observationTasks[endBikePoint.id] = tasks
            }
            if let observedActivityId = observedActivityIdsByDock.removeValue(forKey: originalDockId) {
                observedActivityIdsByDock[endBikePoint.id] = observedActivityId
            }
            LiveActivityDockSettings.clearPrimaryDisplay(for: originalDockId)
            LiveActivityDockSettings.setPrimaryDisplay(.spaces, for: endBikePoint.id)
            notifyPrimaryDisplayChanged()

            if let pushToken = current.pushToken {
                let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                await updateSessionConfigurationOnServer(
                    dockId: originalDockId,
                    pushToken: tokenString,
                    dockName: endBikePoint.commonName,
                    primaryDisplay: .spaces,
                    targetDockId: endBikePoint.id,
                    alternatives: Array(alternativeDocks),
                    currentState: updatedState,
                    scheduledJourneyPhase: .end
                )
                untrackServerSession(dockId: originalDockId, pushToken: tokenString)
                trackServerSession(dockId: endBikePoint.id, pushToken: tokenString)
            } else {
                logLiveActivityDiagnosticEvent(
                    "scheduled_transition_existing_activity_missing_push_token",
                    dockId: endBikePoint.id,
                    dockName: endBikePoint.commonName,
                    scheduledJourneyId: journeyId,
                    scheduledJourneyPhase: .end,
                    message: "Updated local Live Activity but could not migrate server polling because ActivityKit push token is unavailable"
                )
            }
        } else {
            logLiveActivityDiagnosticEvent(
                "scheduled_transition_no_existing_activity_fallback_start",
                dockId: endBikePoint.id,
                dockName: endBikePoint.commonName,
                scheduledJourneyId: journeyId,
                scheduledJourneyPhase: .end,
                message: "No existing journey Live Activity found; falling back to destination activity request"
            )
            startLiveActivity(
                for: endBikePoint,
                alias: nil,
                alternatives: alternatives,
                scheduledJourneyId: journeyId,
                scheduledJourneyPhase: .end,
                adHocJourneyId: adHocJourneyId,
                destinationDock: nil
            )
        }

        DockArrivalMonitoringService.shared.beginMonitoring(
            for: endBikePoint,
            scheduledJourneyId: journeyId,
            phase: .end,
            adHocJourneyId: adHocJourneyId,
            destinationDock: nil
        )

        logLiveActivityDiagnosticEvent(
            "scheduled_transition_existing_activity_update_completed",
            dockId: endBikePoint.id,
            dockName: endBikePoint.commonName,
            scheduledJourneyId: journeyId,
            scheduledJourneyPhase: .end,
            message: "Journey Live Activity now tracks destination dock"
        )
    }

    private func applyArrivalMonitoringConfiguration(
        _ configuration: DockActivityMonitoringConfiguration,
        source: DockArrivalMonitoringReconciliationSource
    ) {
        DockArrivalMonitoringService.shared.reconcileMonitoring(
            for: configuration.bikePoint,
            scheduledJourneyId: configuration.scheduledJourneyId,
            phase: configuration.phase,
            adHocJourneyId: configuration.adHocJourneyId,
            destinationDock: configuration.destinationDock,
            source: source
        )
    }

    private func reconcileArrivalMonitoring(
        for activity: Activity<DockActivityAttributes>,
        source: DockArrivalMonitoringReconciliationSource
    ) {
        arrivalMonitoringRecoveryTask?.cancel()
        arrivalMonitoringRecoveryTask = nil
        arrivalMonitoringRecoveryGeneration = nil
        arrivalMonitoringAuthorityActivityId = activity.id

        if let configuration = DockActivityMonitoringResolver.resolve(
            attributes: activity.attributes,
            state: activity.content.state
        ) {
            applyArrivalMonitoringConfiguration(configuration, source: source)
            return
        }

        guard let recoveryContext = DockActivityMonitoringResolver.recoveryContext(
            attributes: activity.attributes,
            state: activity.content.state
        ) else {
            DockArrivalMonitoringService.shared.stopMonitoring(
                reason: "invalid_live_activity_context",
                preserveDock: true
            )
            recordArrivalMonitoringResolutionFailure(
                activity: activity,
                source: source,
                reason: "invalid_activity_context"
            )
            return
        }

        let restoredPersistedMonitoring = DockArrivalMonitoringService.shared.restoreMonitoringIfNeeded(
            matchingActiveDockId: recoveryContext.activeDockId,
            scheduledJourneyId: recoveryContext.scheduledJourneyId,
            phase: recoveryContext.phase,
            adHocJourneyId: recoveryContext.adHocJourneyId,
            destinationDockId: recoveryContext.destinationDockId,
            source: source
        )
        if !restoredPersistedMonitoring {
            DockArrivalMonitoringService.shared.stopMonitoring(
                reason: "persisted_context_mismatch",
                preserveDock: true
            )
        }

        TroubleshootingLogStore.shared.record(
            category: "dock_arrival",
            event: "activity_monitoring_context_fetch_started",
            message: "Activity attributes were incomplete; fetching dock coordinates before monitoring.",
            metadata: [
                "source": source.rawValue,
                "activityId": activity.id,
                "activeDockId": recoveryContext.activeDockId,
                "destinationDockId": recoveryContext.destinationDockId,
                "restoredPersistedMonitoring": restoredPersistedMonitoring,
            ]
        )

        let generation = UUID()
        arrivalMonitoringRecoveryGeneration = generation
        arrivalMonitoringRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.recoverArrivalMonitoring(
                for: activity,
                context: recoveryContext,
                source: source,
                generation: generation
            )
        }
    }

    private func recoverArrivalMonitoring(
        for activity: Activity<DockActivityAttributes>,
        context: DockActivityMonitoringRecoveryContext,
        source: DockArrivalMonitoringReconciliationSource,
        generation: UUID
    ) async {
        defer {
            if arrivalMonitoringRecoveryGeneration == generation {
                arrivalMonitoringRecoveryTask = nil
                arrivalMonitoringRecoveryGeneration = nil
            }
        }

        async let fetchedActiveDock = fetchBikePointForMonitoring(
            dockId: context.activeDockId,
            fallbackName: context.activeDockName
        )

        let fetchedDestinationDock: ScheduledJourneyDock?
        if context.phase == .start,
           let destinationDockId = context.destinationDockId {
            let destinationBikePoint = await fetchBikePointForMonitoring(
                dockId: destinationDockId,
                fallbackName: context.destinationDockName
            )
            fetchedDestinationDock = destinationBikePoint.map { ScheduledJourneyDock(bikePoint: $0) }
        } else {
            fetchedDestinationDock = nil
        }

        let activeDock = await fetchedActiveDock
        guard !Task.isCancelled,
              arrivalMonitoringRecoveryGeneration == generation,
              arrivalMonitoringAuthorityActivityId == activity.id,
              isTrackableActivityState(activity.activityState),
              activeActivities.values.contains(where: { $0.id == activity.id }) else {
            TroubleshootingLogStore.shared.record(
                category: "dock_arrival",
                event: "activity_monitoring_context_fetch_discarded",
                message: "Discarded fetched dock context because another Live Activity became authoritative.",
                metadata: [
                    "source": source.rawValue,
                    "activityId": activity.id,
                    "activeDockId": context.activeDockId,
                ]
            )
            return
        }

        let attributes = activity.attributes
        let latestState = activity.content.state
        guard DockActivityMonitoringResolver.recoveryContext(
            attributes: attributes,
            state: latestState
        ) == context else {
            TroubleshootingLogStore.shared.record(
                category: "dock_arrival",
                event: "activity_monitoring_context_fetch_discarded",
                message: "Discarded fetched dock context because the activity stage changed during recovery.",
                metadata: [
                    "source": source.rawValue,
                    "activityId": activity.id,
                    "activeDockId": context.activeDockId,
                ]
            )
            return
        }

        guard let configuration = DockActivityMonitoringResolver.resolve(
            attributes: attributes,
            state: latestState,
            fallbackActiveDock: activeDock,
            fallbackDestinationDock: fetchedDestinationDock
        ) else {
            recordArrivalMonitoringResolutionFailure(
                activity: activity,
                source: source,
                reason: "invalid_or_unavailable_dock_context"
            )
            return
        }

        applyArrivalMonitoringConfiguration(configuration, source: source)
    }

    private func fetchBikePointForMonitoring(
        dockId: String,
        fallbackName: String?
    ) async -> BikePoint? {
        let urlString = "\(AppConstants.API.baseURL)\(AppConstants.API.placeEndpoint)/\(dockId)?cb=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let decoded = try? JSONDecoder().decode(BikePoint.self, from: data),
                  decoded.id == dockId,
                  decoded.lat.isFinite,
                  decoded.lon.isFinite,
                  (-90...90).contains(decoded.lat),
                  (-180...180).contains(decoded.lon),
                  decoded.lat != 0 || decoded.lon != 0 else {
                return nil
            }

            let trimmedName = decoded.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty
                ? fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                : trimmedName
            guard !resolvedName.isEmpty else { return nil }
            return BikePoint(
                id: decoded.id,
                commonName: resolvedName,
                lat: decoded.lat,
                lon: decoded.lon,
                additionalProperties: decoded.additionalProperties
            )
        } catch {
            return nil
        }
    }

    private func recordArrivalMonitoringResolutionFailure(
        activity: Activity<DockActivityAttributes>,
        source: DockArrivalMonitoringReconciliationSource,
        reason: String
    ) {
        let activeDockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        let phase = DockActivityMonitoringResolver.recoveryContext(
            attributes: activity.attributes,
            state: activity.content.state
        )?.phase
        TroubleshootingLogStore.shared.record(
            category: "dock_arrival",
            event: "activity_monitoring_context_unresolved",
            message: "Could not derive a safe dock arrival monitoring target from the active Live Activity.",
            metadata: [
                "source": source.rawValue,
                "reason": reason,
                "activityId": activity.id,
                "activeDockId": activeDockId,
                "phase": phase?.rawValue,
                "attributeDockId": activity.attributes.dockId,
                "destinationDockId": activity.attributes.destinationDockId,
            ]
        )
        logLiveActivityDiagnosticEvent(
            "live_activity_monitoring_context_unresolved",
            dockId: activeDockId,
            dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName,
            scheduledJourneyId: activity.attributes.scheduledJourneyId,
            scheduledJourneyPhase: phase,
            message: "Could not derive a safe dock arrival monitoring target",
            raw: [
                "source": source.rawValue,
                "reason": reason,
                "activityId": activity.id,
            ]
        )
    }

    private func handleObservedActivity(_ activity: Activity<DockActivityAttributes>) async {
        let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        activeActivities[dockId] = activity
        staleDates[dockId] = activity.content.staleDate
        reconcileArrivalMonitoring(for: activity, source: .activityObserved)
        // ActivityKit can surface a remotely push-started activity before its update
        // token is available. Arm the async observer before doing any network work.
        ensureActivityObservation(for: activity, source: "activity_observed")
        let scheduledJourneyPhase = scheduledJourneyPhase(for: activity)
        let alternatives = await updateScheduledJourneyAlternativesIfNeeded(
            for: activity,
            phase: scheduledJourneyPhase
        )

        if let pushToken = activity.pushToken {
            await registerActivityTokenIfNeeded(
                for: activity,
                pushToken: pushToken,
                source: "activity_observed_enriched",
                force: true,
                alternatives: alternatives
            )
        }
    }

    private func updateScheduledJourneyAlternativesIfNeeded(
        for activity: Activity<DockActivityAttributes>,
        phase: ScheduledJourney.ActiveRun.Phase?
    ) async -> [DockActivityAttributes.AlternativeDock] {
        guard let phase,
              let configuration = DockActivityMonitoringResolver.resolve(
                  attributes: activity.attributes,
                  state: activity.content.state
              ) else {
            return activity.content.state.alternatives
        }

        let activeDockId = configuration.bikePoint.id
        let activeDockName = configuration.bikePoint.commonName
        let dock = ScheduledJourneyDock(
            id: activeDockId,
            name: activeDockName,
            latitude: configuration.bikePoint.lat,
            longitude: configuration.bikePoint.lon
        )
        let bikePoint = await fetchBikePointIfPossible(dock: dock)
        let alternatives = await scheduledJourneyAlternatives(for: bikePoint, phase: phase)
        guard !Task.isCancelled,
              (activity.content.state.resolvedDockId ?? activity.attributes.dockId) == activeDockId,
              scheduledJourneyPhase(for: activity) == phase else {
            return activity.content.state.alternatives
        }
        let alternativeDocks = alternatives.prefix(5).map(alternativeSnapshot)

        let updatedState = DockActivityAttributes.ContentState(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            alternatives: Array(alternativeDocks),
            activeDockId: activeDockId,
            activeDockName: activeDockName,
            activeDockAlias: DockPreferencesService.shared.alias(for: activeDockId),
            activeJourneyPhase: phase.rawValue,
            primaryDisplay: activity.content.state.primaryDisplay,
            availabilityUpdatedAtEpochSeconds: Int(Date().timeIntervalSince1970),
            journeyProgress: activity.content.state.journeyProgress,
            rideStartedAtEpochSeconds: activity.content.state.rideStartedAtEpochSeconds
        )
        let updatedContent = ActivityContent(
            state: updatedState,
            staleDate: Date().addingTimeInterval(availabilityFreshnessSeconds)
        )
        await activity.update(updatedContent)
        staleDates[activeDockId] = updatedContent.staleDate
        return updatedState.alternatives
    }

    private func alternativeSnapshot(for bikePoint: BikePoint) -> DockActivityAttributes.AlternativeDock {
        DockActivityAttributes.AlternativeDock(
            name: bikePoint.commonName,
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            id: bikePoint.id,
            alias: DockPreferencesService.shared.alias(for: bikePoint.id)
        )
    }

    private func alternativePurpose(for activity: Activity<DockActivityAttributes>) -> AlternativeDockPurpose {
        if let phase = scheduledJourneyPhase(for: activity) {
            return scheduledJourneyAlternativePurpose(for: phase)
        }
        let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        switch getPrimaryDisplay(for: dockId) {
        case .bikes: return .bikes
        case .eBikes: return .eBikes
        case .spaces: return .spaces
        }
    }

    private func acknowledgeDockPreferences(from data: Data) {
        struct Response: Decodable {
            let dockPreferencesRevision: Int64?
        }
        if let response = try? JSONDecoder().decode(Response.self, from: data),
           let revision = response.dockPreferencesRevision {
            DockPreferencesService.shared.markSynced(revision: revision)
        }
    }

    private func fetchBikePointIfPossible(dock: ScheduledJourneyDock) async -> BikePoint {
        let urlString = "\(AppConstants.API.baseURL)\(AppConstants.API.placeEndpoint)/\(dock.id)?cb=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else {
            return BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude)
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return (try? JSONDecoder().decode(BikePoint.self, from: data))
                ?? BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude)
        } catch {
            return BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude)
        }
    }

    private func scheduledJourneyAlternatives(
        for bikePoint: BikePoint,
        phase: ScheduledJourney.ActiveRun.Phase
    ) async -> [BikePoint] {
        let allBikePoints = await fetchAllBikePointsForAlternatives()
        return AlternativeDockSelectionService.alternatives(
            for: bikePoint,
            allBikePoints: allBikePoints,
            favorites: FavoritesService.shared.favorites,
            userLocation: nil,
            purpose: scheduledJourneyAlternativePurpose(for: phase)
        )
    }

    private func scheduledJourneyAlternativePurpose(
        for phase: ScheduledJourney.ActiveRun.Phase
    ) -> AlternativeDockPurpose {
        switch phase {
        case .end:
            return .spaces
        case .start:
            let rawFilter = AppConstants.UserDefaults.sharedDefaults.string(
                forKey: BikeDataFilter.userDefaultsKey
            ) ?? BikeDataFilter.both.rawValue
            switch BikeDataFilter(rawValue: rawFilter) ?? .both {
            case .bikesOnly:
                return .bikes
            case .eBikesOnly:
                return .eBikes
            case .both:
                return .allBikes
            }
        }
    }

    private func fetchAllBikePointsForAlternatives() async -> [BikePoint] {
        let cached = AllBikePointsCache.shared.load()
        if !cached.isEmpty {
            return cached
        }

        var urlString = AppConstants.API.baseURL + AppConstants.API.bikePointEndpoint
        urlString += "?cb=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let bikePoints = try JSONDecoder()
                .decode([LiveActivityFailableBikePoint].self, from: data)
                .compactMap(\.value)
                .filter(\.isInstalled)
            AllBikePointsCache.shared.save(bikePoints)
            return bikePoints
        } catch {
            logger.error("Failed to fetch all bike points for scheduled journey alternatives: \(error.localizedDescription)")
            return []
        }
    }

    func handleDeviceTokenRegistration() async {
        let runningActivities = Activity<DockActivityAttributes>.activities

        for activity in runningActivities where isTrackableActivityState(activity.activityState) {
            guard let pushToken = activity.pushToken else { continue }
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
            logger.info(
                "Re-registering active live activity for dock \(dockId) after APNs device token update"
            )
            ensureActivityObservation(for: activity, source: "device_token_registration")
            await registerActivityTokenIfNeeded(
                for: activity,
                pushToken: pushToken,
                source: "device_token_registration",
                force: true
            )
        }

        await refreshNotificationStatusFromServer()
    }

#if DEBUG
    func simulateArrivalTrigger() async -> (success: Bool, message: String) {
        if let activity = activeActivities.values.first {
            return await DockArrivalMonitoringService.shared.debugSimulateArrival(
                dockId: activity.content.state.resolvedDockId ?? activity.attributes.dockId,
                dockName: activity.content.state.resolvedDockName ?? activity.attributes.dockName
            )
        }

        if let session = activeNotificationSession {
            return await DockArrivalMonitoringService.shared.debugSimulateArrival(
                dockId: session.dockId,
                dockName: session.dockName
            )
        }

        return (false, "No active live activity to simulate arrival for.")
    }
#endif

    /// Set the primary display override for a specific dock's live activity
    func setPrimaryDisplay(_ display: LiveActivityPrimaryDisplay, for dockId: String) {
        LiveActivityDockSettings.setPrimaryDisplay(display, for: dockId)
        notifyPrimaryDisplayChanged()
        logger.info("Set primary display to \(display.rawValue) for dock \(dockId)")

        // Force update the activity to reflect the change immediately
        if let activity = activeActivities[dockId] {
            Task { [weak self] in
                guard let self else { return }
                // Get current state and create a new content with the same data
                // IMPORTANT: Preserve the original stale date so the activity still expires
                let currentState = activity.content.state
                let updatedState = DockActivityAttributes.ContentState(
                    standardBikes: currentState.standardBikes,
                    eBikes: currentState.eBikes,
                    emptySpaces: currentState.emptySpaces,
                    alternatives: currentState.alternatives,
                    activeDockId: currentState.activeDockId,
                    activeDockName: currentState.activeDockName,
                    activeDockAlias: currentState.activeDockAlias,
                    activeJourneyPhase: currentState.activeJourneyPhase,
                    primaryDisplay: display.rawValue,
                    availabilityUpdatedAtEpochSeconds: currentState.availabilityUpdatedAtEpochSeconds,
                    journeyProgress: currentState.journeyProgress,
                    rideStartedAtEpochSeconds: currentState.rideStartedAtEpochSeconds
                )
                let preservedStaleDate = self.staleDates[dockId]
                let newContent = ActivityContent(state: updatedState, staleDate: preservedStaleDate)
                await activity.update(newContent)
                self.logger.info("Updated live activity display for dock \(dockId)")

                if let pushToken = activity.pushToken {
                    let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                    await self.updateSessionConfigurationOnServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: updatedState.resolvedDockName ?? activity.attributes.dockName,
                        primaryDisplay: display,
                        currentState: updatedState
                    )
                }
            }
        }
    }

    /// Get the current primary display for a specific dock (override or global default)
    func getPrimaryDisplay(for dockId: String) -> LiveActivityPrimaryDisplay {
        if let journeyPhase = activeJourneyPhase(for: dockId) {
            switch journeyPhase {
            case .start:
                return preferredJourneyStartPrimaryDisplay()
            case .end:
                return .spaces
            }
        }

        if let override = LiveActivityDockSettings.getPrimaryDisplay(for: dockId) {
            return override
        }
        let globalRawValue = AppConstants.UserDefaults.sharedDefaults.string(forKey: LiveActivityPrimaryDisplay.userDefaultsKey) ?? LiveActivityPrimaryDisplay.bikes.rawValue
        return LiveActivityPrimaryDisplay(rawValue: globalRawValue) ?? .bikes
    }

    private func preferredJourneyStartPrimaryDisplay() -> LiveActivityPrimaryDisplay {
        let rawFilter = AppConstants.UserDefaults.sharedDefaults.string(
            forKey: BikeDataFilter.userDefaultsKey
        ) ?? BikeDataFilter.both.rawValue
        switch BikeDataFilter(rawValue: rawFilter) ?? .both {
        case .bikesOnly:
            return .bikes
        case .eBikesOnly:
            return .eBikes
        case .both:
            let globalRawValue = AppConstants.UserDefaults.sharedDefaults.string(
                forKey: LiveActivityPrimaryDisplay.userDefaultsKey
            ) ?? LiveActivityPrimaryDisplay.bikes.rawValue
            let globalDisplay = LiveActivityPrimaryDisplay(rawValue: globalRawValue) ?? .bikes
            return globalDisplay == .spaces ? .bikes : globalDisplay
        }
    }

    /// Restore activities that may still be running from a previous app session
    func restoreActivities() {
        let runningActivities = Activity<DockActivityAttributes>.activities
        let runningDockIds = Set(runningActivities.map { $0.content.state.resolvedDockId ?? $0.attributes.dockId })
        let activeAdHocJourneyIds = Set(runningActivities.compactMap(\.attributes.adHocJourneyId))
        AdHocJourneyService.shared.reconcileActivePhases(activeJourneyIds: activeAdHocJourneyIds)

        // If local in-memory tracking says an activity exists but the system no longer has it
        // (e.g. user swiped it away while app was suspended), clear local state.
        let inactiveTrackedDockIds = Set(activeActivities.keys).subtracting(runningDockIds)
        for dockId in inactiveTrackedDockIds {
            logger.info("Clearing local tracking for dock \(dockId) because no active system live activity was found")
            clearLocallyTrackedActivity(for: dockId)
        }

        // Best-effort reconciliation: if we have a previously tracked server session for a dock
        // that no longer has an active activity, unregister it to stop notifications.
        reconcileTrackedServerSessions(activeDockIds: runningDockIds)

        var keptDockId: String?
        for activity in runningActivities {
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId

            if DockArrivalMonitoringService.shared.hasPendingArrival(for: dockId) {
                logger.info("Ending restored live activity for dock \(dockId) because its arrival is pending delivery")
                Task { [weak self] in
                    await self?.endActivityInstance(
                        activity,
                        dockId: dockId,
                        skipServerUnregister: true
                    )
                }
                continue
            }

            if activity.activityState == .stale {
                logger.info("Restoring stale live activity for dock \(dockId) while awaiting fresh availability")
            }

            if isTrackableActivityState(activity.activityState) {
                if let keptDockId {
                    logger.info("Found additional live activity for dock \(dockId); ending to enforce single activity (keeping \(keptDockId))")
                    Task { [weak self] in
                        await self?.endActivityInstance(activity, dockId: dockId)
                    }
                    continue
                }

                keptDockId = dockId
                activeActivities[dockId] = activity

                // Restore the stale date from the activity content
                if let staleDate = activity.content.staleDate {
                    staleDates[dockId] = staleDate
                    logger.info("Restored live activity for dock \(dockId) with stale date: \(staleDate)")
                } else {
                    logger.info("Restored live activity for dock \(dockId)")
                }

                let reconciliationSource: DockArrivalMonitoringReconciliationSource =
                    UIApplication.shared.applicationState == .active ? .foreground : .activityRestored
                reconcileArrivalMonitoring(for: activity, source: reconciliationSource)
                ensureActivityObservation(for: activity, source: "activity_restored")
            }
        }

        if !runningActivities.isEmpty {
            logger.info("Restored \(self.activeActivities.count) live activities")
        }

        if keptDockId == nil {
            arrivalMonitoringRecoveryTask?.cancel()
            arrivalMonitoringRecoveryTask = nil
            arrivalMonitoringRecoveryGeneration = nil
            arrivalMonitoringAuthorityActivityId = nil
            DockArrivalMonitoringService.shared.restoreMonitoringIfNeeded(activeDockIds: [])
        }

        Task { [weak self] in
            await self?.refreshNotificationStatusFromServer()
        }
    }

    // MARK: - Server Communication

    private func minimumThresholdsPayload() -> [String: Int] {
        let defaults = AppConstants.UserDefaults.sharedDefaults
        let minBikes = defaults.object(forKey: AlternativeDockSettings.minBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinBikes
        let minEBikes = defaults.object(forKey: AlternativeDockSettings.minEBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinEBikes
        let minSpaces = defaults.object(forKey: AlternativeDockSettings.minSpacesKey) as? Int
            ?? AlternativeDockSettings.defaultMinSpaces

        return [
            "bikes": max(0, minBikes),
            "eBikes": max(0, minEBikes),
            "spaces": max(0, minSpaces),
        ]
    }

    private func scheduledJourneyPrimaryDisplay(
        dockId: String,
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase?
    ) -> String {
        guard let scheduledJourneyPhase else {
            return getPrimaryDisplay(for: dockId).rawValue
        }

        switch scheduledJourneyPhase {
        case .end:
            return LiveActivityPrimaryDisplay.spaces.rawValue
        case .start:
            let rawFilter = AppConstants.UserDefaults.sharedDefaults.string(
                forKey: BikeDataFilter.userDefaultsKey
            ) ?? BikeDataFilter.both.rawValue
            let filter = BikeDataFilter(rawValue: rawFilter) ?? .both
            switch filter {
            case .bikesOnly:
                return LiveActivityPrimaryDisplay.bikes.rawValue
            case .eBikesOnly:
                return LiveActivityPrimaryDisplay.eBikes.rawValue
            case .both:
                return "allBikes"
            }
        }
    }

    private func registerWithServer(
        dockId: String,
        pushToken: String,
        dockName: String,
        alternatives: [DockActivityAttributes.AlternativeDock],
        currentState: DockActivityAttributes.ContentState? = nil,
        scheduledJourneyId: String? = nil,
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil,
        adHocJourneyId: String? = nil
    ) async -> Bool {
        let urlString = "\(serverBaseURL)/live-activity/start"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid server URL: \(urlString)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add APNs device token so the server can send availability alert pushes.
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        } else {
            logger.warning("APNs device token unavailable while registering live activity; availability alerts may be skipped")
        }

        request.timeoutInterval = 10

        // Get the auto-removal duration from settings (capped to the max notification window)
        let finalExpirySeconds = configuredLiveActivityExpirySeconds()

        let serializedAlternatives = alternatives.map(\.serverPayload)
        let primaryDisplayRawValue = scheduledJourneyPrimaryDisplay(
            dockId: dockId,
            scheduledJourneyPhase: scheduledJourneyPhase
        )
        let minimumThresholds = minimumThresholdsPayload()

        var body: [String: Any] = [
            "deviceId": DeviceTokenHelper.scheduledJourneyDeviceId,
            "dockPreferences": DockPreferencesService.shared.serverPayload,
            "dockId": dockId,
            "dockName": dockName,
            "pushToken": pushToken,
            "buildType": buildType,
            "expirySeconds": finalExpirySeconds,
            "alternatives": serializedAlternatives,
            "primaryDisplay": primaryDisplayRawValue,
            "minimumThresholds": minimumThresholds,
        ]
        if let currentState {
            body["standardBikes"] = currentState.standardBikes
            body["eBikes"] = currentState.eBikes
            body["emptySpaces"] = currentState.emptySpaces
            body["activeDockId"] = currentState.activeDockId
            body["activeDockName"] = currentState.activeDockName
            body["activeDockAlias"] = currentState.activeDockAlias
            body["activeJourneyPhase"] = currentState.activeJourneyPhase
            body["rideStartedAtEpochSeconds"] = currentState.rideStartedAtEpochSeconds
            if let progress = currentState.journeyProgress,
               let data = try? JSONEncoder().encode(progress) {
                body["journeyProgress"] = try? JSONSerialization.jsonObject(with: data)
            }
            body["availabilityUpdatedAtEpochSeconds"] = currentState.availabilityUpdatedAtEpochSeconds
        }
        if let scheduledJourneyId {
            body["scheduledJourneyId"] = scheduledJourneyId
        }
        if let scheduledJourneyPhase {
            body["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
        }
        if let adHocJourneyId {
            body["adHocJourneyId"] = adHocJourneyId
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                acknowledgeDockPreferences(from: data)
                trackServerSession(dockId: dockId, pushToken: pushToken)
                let activeThreshold = primaryDisplayRawValue == "allBikes"
                    ? (minimumThresholds[LiveActivityPrimaryDisplay.bikes.rawValue] ?? 0) + (minimumThresholds[LiveActivityPrimaryDisplay.eBikes.rawValue] ?? 0)
                    : minimumThresholds[primaryDisplayRawValue] ?? 0
                logger.info("Registered live activity with server for dock \(dockId) (expires in \(Int(finalExpirySeconds))s, alternatives: \(serializedAlternatives.count), primaryDisplay: \(primaryDisplayRawValue), minimumThreshold: \(activeThreshold))")
                TroubleshootingLogStore.shared.record(
                    category: "live_activity",
                    event: "server_registration_succeeded",
                    message: "Registered Live Activity push token with server.",
                    metadata: [
                        "dockId": dockId,
                        "dockName": dockName,
                        "pushTokenPrefix": String(pushToken.prefix(8)),
                        "primaryDisplay": primaryDisplayRawValue,
                        "scheduledJourneyId": scheduledJourneyId,
                        "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                        "alternativesCount": serializedAlternatives.count,
                        "expirySeconds": Int(finalExpirySeconds),
                    ]
                )
                logLiveActivityDiagnosticEvent(
                    "live_activity_server_registration_succeeded",
                    dockId: dockId,
                    dockName: dockName,
                    scheduledJourneyId: scheduledJourneyId,
                    scheduledJourneyPhase: scheduledJourneyPhase,
                    message: "Registered ActivityKit token with live activity server",
                    raw: [
                        "pushTokenPrefix": String(pushToken.prefix(8)),
                        "primaryDisplay": primaryDisplayRawValue,
                        "alternativesCount": serializedAlternatives.count,
                    ]
                )
                await refreshNotificationStatusFromServer()
                return true
            } else {
                logger.warning("Server returned unexpected response for dock \(dockId)")
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                TroubleshootingLogStore.shared.record(
                    category: "live_activity",
                    event: "server_registration_failed_status",
                    message: "Server returned unexpected response while registering Live Activity.",
                    metadata: [
                        "dockId": dockId,
                        "dockName": dockName,
                        "pushTokenPrefix": String(pushToken.prefix(8)),
                        "statusCode": statusCode,
                        "scheduledJourneyId": scheduledJourneyId,
                        "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                    ]
                )
                logLiveActivityDiagnosticEvent(
                    "live_activity_server_registration_failed_status",
                    dockId: dockId,
                    dockName: dockName,
                    scheduledJourneyId: scheduledJourneyId,
                    scheduledJourneyPhase: scheduledJourneyPhase,
                    message: "Server returned unexpected response while registering live activity",
                    raw: [
                        "pushTokenPrefix": String(pushToken.prefix(8)),
                        "statusCode": statusCode,
                    ]
                )
                return false
            }
        } catch {
            logger.error("Failed to register with server: \(error.localizedDescription)")
            TroubleshootingLogStore.shared.record(
                category: "live_activity",
                event: "server_registration_failed_network",
                message: "Failed to register Live Activity with server: \(error.localizedDescription)",
                metadata: [
                    "dockId": dockId,
                    "dockName": dockName,
                    "pushTokenPrefix": String(pushToken.prefix(8)),
                    "scheduledJourneyId": scheduledJourneyId,
                    "scheduledJourneyPhase": scheduledJourneyPhase?.rawValue,
                ]
            )
            logLiveActivityDiagnosticEvent(
                "live_activity_server_registration_failed_network",
                dockId: dockId,
                dockName: dockName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "Failed to register live activity with server: \(error.localizedDescription)",
                raw: ["pushTokenPrefix": String(pushToken.prefix(8))]
            )
            return false
        }
    }

    /// Location refreshes retain the actual availability timestamp and stale date.
    func updateJourneyProgress(_ progress: JourneyProgress, journeyId: String) async {
        guard let activity = activeActivities.values.first(where: {
            $0.attributes.scheduledJourneyId == journeyId || $0.attributes.adHocJourneyId == journeyId || $0.id == journeyId
        }), scheduledJourneyPhase(for: activity) == .end else { return }
        var state = activity.content.state
        state.journeyProgress = progress
        await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        guard !Task.isCancelled, scheduledJourneyPhase(for: activity) == .end,
              activity.activityState == .active || activity.activityState == .stale else { return }
        if let token = activity.pushToken {
            // Send only progress: re-sending cached counts would overwrite the server's fresher dock data.
            let dockId = state.resolvedDockId ?? activity.attributes.dockId
            await updateSessionConfigurationOnServer(
                dockId: dockId, pushToken: token.map { String(format: "%02x", $0) }.joined(),
                dockName: state.resolvedDockName ?? activity.attributes.dockName,
                primaryDisplay: .spaces, progress: progress
            )
        }
    }

    private func updateSessionConfigurationOnServer(
        dockId: String,
        pushToken: String,
        dockName: String?,
        primaryDisplay: LiveActivityPrimaryDisplay,
        targetDockId: String? = nil,
        alternatives: [DockActivityAttributes.AlternativeDock]? = nil,
        currentState: DockActivityAttributes.ContentState? = nil,
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil,
        progress: JourneyProgress? = nil
    ) async {
        let urlString = "\(serverBaseURL)/live-activity/session/update"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid server URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        }

        var body: [String: Any] = [
            "deviceId": DeviceTokenHelper.scheduledJourneyDeviceId,
            "dockPreferences": DockPreferencesService.shared.serverPayload,
            "dockId": dockId,
            "pushToken": pushToken,
            "primaryDisplay": scheduledJourneyPhase.map {
                scheduledJourneyPrimaryDisplay(dockId: targetDockId ?? dockId, scheduledJourneyPhase: $0)
            } ?? primaryDisplay.rawValue,
            "minimumThresholds": minimumThresholdsPayload(),
        ]
        if let progress, let data = try? JSONEncoder().encode(progress) {
            body["progressOnly"] = true
            body["journeyProgress"] = try? JSONSerialization.jsonObject(with: data)
        }
        if let targetDockId, !targetDockId.isEmpty {
            body["targetDockId"] = targetDockId
        }
        if let dockName, !dockName.isEmpty {
            body["dockName"] = dockName
        }
        if let alternatives {
            body["alternatives"] = alternatives.map(\.serverPayload)
        }
        if let currentState {
            body["standardBikes"] = currentState.standardBikes
            body["eBikes"] = currentState.eBikes
            body["emptySpaces"] = currentState.emptySpaces
            body["activeDockId"] = currentState.activeDockId
            body["activeDockName"] = currentState.activeDockName
            body["activeDockAlias"] = currentState.activeDockAlias
            body["activeJourneyPhase"] = currentState.activeJourneyPhase
            body["rideStartedAtEpochSeconds"] = currentState.rideStartedAtEpochSeconds
            if let progress = currentState.journeyProgress,
               let data = try? JSONEncoder().encode(progress) {
                body["journeyProgress"] = try? JSONSerialization.jsonObject(with: data)
            }
        }
        if let scheduledJourneyPhase {
            body["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                acknowledgeDockPreferences(from: data)
                logger.info("Updated live activity server session for dock \(dockId) with primaryDisplay \(primaryDisplay.rawValue)")
            } else {
                logger.warning("Server returned unexpected response while updating live activity session for dock \(dockId)")
            }
        } catch {
            logger.error("Failed to update live activity server session: \(error.localizedDescription)")
        }
    }

    private func unregisterFromServer(dockId: String, pushToken: String) async {
        let urlString = "\(serverBaseURL)/live-activity/end"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add APNs device token so server can correlate this session with alerts.
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        }

        request.timeoutInterval = 10

        let body: [String: String] = [
            "dockId": dockId,
            "pushToken": pushToken,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode
                if (200...299).contains(statusCode) || statusCode == 404 {
                    untrackServerSession(dockId: dockId, pushToken: pushToken)
                    logger.info("Unregistered live activity from server for dock \(dockId) (status \(statusCode))")
                    await refreshNotificationStatusFromServer()
                } else {
                    logger.warning("Server returned unexpected response while unregistering live activity for dock \(dockId) (status \(statusCode))")
                }
            } else {
                logger.warning("Server returned unexpected non-HTTP response while unregistering live activity for dock \(dockId)")
            }
        } catch {
            logger.error("Failed to unregister from server: \(error.localizedDescription)")
        }
    }

    private func endLiveActivityNotificationsOnServer(for dockId: String) async -> Bool {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("APNs device token unavailable while muting live activity notifications for dock \(dockId)")
            return false
        }

        let urlString = "\(serverBaseURL)\(AppConstants.Server.liveActivityDeviceEndEndpoint)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid live activity device end URL: \(urlString)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "dockId": dockId,
            "deviceToken": deviceToken,
            "buildType": buildType,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.warning("Non-HTTP response while muting live activity notifications for dock \(dockId)")
                return false
            }

            guard httpResponse.statusCode == 200 else {
                logger.warning("Unexpected status (\(httpResponse.statusCode)) while muting live activity notifications for dock \(dockId)")
                return false
            }

            let decoded = try JSONDecoder().decode(DeviceEndResponse.self, from: data)
            untrackServerSession(dockId: dockId, pushToken: nil)
            await refreshNotificationStatusFromServer()
            logger.info(
                "Muted live activity notifications for dock \(dockId) via device action (ended: \(decoded.endedCount), remaining: \(decoded.remainingCount))"
            )
            return decoded.success
        } catch {
            logger.error("Failed to mute live activity notifications for dock \(dockId): \(error.localizedDescription)")
            return false
        }
    }

    private func endAllLiveActivityNotificationsOnServer() async -> Bool {
        guard let deviceToken = DeviceTokenHelper.apnsDeviceToken else {
            logger.warning("APNs device token unavailable while muting all live activity notifications")
            return false
        }

        let urlString = "\(serverBaseURL)\(AppConstants.Server.liveActivityDeviceEndAllEndpoint)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid live activity device end-all URL: \(urlString)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "deviceToken": deviceToken,
            "buildType": buildType,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.warning("Unexpected response while muting all live activity notifications")
                return false
            }

            let decoded = try JSONDecoder().decode(DeviceEndResponse.self, from: data)
            logger.info("Muted all live activity notifications (ended: \(decoded.endedCount), remaining: \(decoded.remainingCount))")
            return decoded.success
        } catch {
            logger.error("Failed to mute all live activity notifications: \(error.localizedDescription)")
            return false
        }
    }
}

private struct LiveActivityFailableBikePoint: Decodable {
    let value: BikePoint?

    init(from decoder: Decoder) throws {
        value = try? BikePoint(from: decoder)
    }
}
