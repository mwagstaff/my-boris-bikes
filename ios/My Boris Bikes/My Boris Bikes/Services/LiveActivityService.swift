//
//  LiveActivityService.swift
//  My Boris Bikes
//
//  Manages Live Activities for real-time dock availability tracking
//

import ActivityKit
import Foundation
import UIKit
import os.log

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
        }

        let active: Bool
        let session: Session?
    }

    static let shared = LiveActivityService()
    private let serverSessionTokensKey = "liveActivityServerSessionTokensByDock"

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

    /// Track stale dates for active activities (keyed by dock ID)
    private var staleDates: [String: Date] = [:]

    /// Track the newest TfL availability timestamp applied locally so older fetches cannot
    /// overwrite fresher Live Activity content when `/Place/:id` and `/BikePoint` disagree.
    private var localActivityAvailabilityModifiedAt: [String: Date] = [:]

    /// Track observation tasks to cancel them when activities end
    private var observationTasks: [String: [Task<Void, Never>]] = [:]
    private var activityUpdatesTask: Task<Void, Never>?

    /// Server base URL for the live activity API
    var serverBaseURL: String {
        AppConstants.Server.baseURL
    }

    /// Build type determines APNS environment (sandbox vs production)
    var buildType: String {
        PushEnvironment.buildType
    }

    private init() {}

    deinit {
        // Cancel all observation tasks when service is deallocated
        for (dockId, tasks) in observationTasks {
            for task in tasks {
                task.cancel()
            }
            logger.info("Deinit: Cancelled \(tasks.count) observation task(s) for dock \(dockId)")
        }
        activityUpdatesTask?.cancel()
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

        // Store up to 5 nearby alternatives; the watch view caps display at 2–3 based on filter preference
        let alternativeDocks = alternatives.prefix(5).map {
            DockActivityAttributes.AlternativeDock(
                name: $0.commonName,
                standardBikes: $0.standardBikes,
                eBikes: $0.eBikes,
                emptySpaces: $0.emptyDocks
            )
        }

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
            )
        )

        // Calculate stale date based on configured duration, capped to notification window max.
        let finalExpirySeconds = configuredLiveActivityExpirySeconds()
        let staleDate = Date().addingTimeInterval(finalExpirySeconds)

        let content = ActivityContent(state: initialState, staleDate: staleDate)

        do {
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

            // Register immediately if the token is already available.
            // In some launches the first push token can be present synchronously and
            // we should not rely solely on the async updates sequence.
            if let pushToken = activity.pushToken {
                let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                logger.info("Initial push token for dock \(dockId): \(tokenString)")
                logLiveActivityDiagnosticEvent(
                    "live_activity_initial_push_token_available",
                    dockId: dockId,
                    dockName: bikePoint.commonName,
                    scheduledJourneyId: scheduledJourneyId,
                    scheduledJourneyPhase: scheduledJourneyPhase,
                    message: "Initial ActivityKit push token was available synchronously",
                    raw: ["pushTokenPrefix": String(tokenString.prefix(8))]
                )
                Task { [weak self] in
                    guard let self else { return }
                    await self.registerWithServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: bikePoint.commonName,
                        alternatives: activity.content.state.alternatives,
                        currentState: initialState,
                        scheduledJourneyId: scheduledJourneyId,
                        scheduledJourneyPhase: scheduledJourneyPhase
                    )
                }
            }

            // Cancel any existing observation tasks for this dock
            cancelObservationTasks(for: dockId)

            // Observe push token updates
            let pushTokenTask = Task { [weak self] in
                for await pushToken in activity.pushTokenUpdates {
                    guard let self = self else { break }
                    let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                    self.logger.info("Push token for dock \(dockId): \(tokenString)")
                    self.logLiveActivityDiagnosticEvent(
                        "live_activity_push_token_update",
                        dockId: dockId,
                        dockName: bikePoint.commonName,
                        scheduledJourneyId: scheduledJourneyId,
                        scheduledJourneyPhase: scheduledJourneyPhase,
                        message: "Received ActivityKit push token update",
                        raw: ["pushTokenPrefix": String(tokenString.prefix(8))]
                    )
                    await self.registerWithServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: bikePoint.commonName,
                        alternatives: activity.content.state.alternatives,
                        currentState: activity.content.state,
                        scheduledJourneyId: scheduledJourneyId,
                        scheduledJourneyPhase: scheduledJourneyPhase
                    )
                }
            }

            // Observe activity state changes (e.g., user dismisses, activity goes stale)
            let stateTask = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard let self = self else { break }
                    if state == .stale {
                        self.logger.info("Activity for dock \(dockId) is stale — ending immediately")
                        AnalyticsService.shared.track(
                            action: .liveActivityEnd,
                            screen: .unknown,
                            dock: AnalyticsDockInfo(id: dockId),
                            metadata: ["reason": "stale"]
                        )
                        await MainActor.run { self.endLiveActivity(for: dockId) }
                        break
                    } else if state == .dismissed || state == .ended {
                        self.logger.info("Activity for dock \(dockId) ended (state: \(String(describing: state)))")
                        AnalyticsService.shared.track(
                            action: .liveActivityEnd,
                            screen: .unknown,
                            dock: AnalyticsDockInfo(id: dockId),
                            metadata: [
                                "reason": state == .dismissed ? "dismissed" : "ended"
                            ]
                        )
                        await MainActor.run {
                            if let adHocJourneyId = activity.attributes.adHocJourneyId {
                                AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
                            }
                            self.clearLocallyTrackedActivity(for: dockId)
                            self.notifyPrimaryDisplayChanged()
                        }
                        // Notify server to stop polling
                        if let pushToken = activity.pushToken {
                            let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                            await self.unregisterFromServer(dockId: dockId, pushToken: tokenString)
                        }
                        break
                    }
                }
            }

            // Store tasks so they can be cancelled later
            observationTasks[dockId] = [pushTokenTask, stateTask]
        } catch {
            logger.error("Failed to start live activity: \(error.localizedDescription)")
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

    func isActivityActive(for dockId: String) -> Bool {
        activeActivities[dockId] != nil
    }

    func updateActiveActivitiesIfNeeded(using bikePoints: [BikePoint]) async {
        guard !bikePoints.isEmpty else { return }

        let bikePointsById = Dictionary(
            bikePoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bikePointsByName = Dictionary(
            bikePoints.map { ($0.commonName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var activitiesById: [String: Activity<DockActivityAttributes>] = activeActivities
        for activity in Activity<DockActivityAttributes>.activities where activity.activityState == .active {
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
            activitiesById[dockId] = activity
        }

        for (dockId, activity) in activitiesById {
            let currentState = activity.content.state
            let activeDockId = currentState.resolvedDockId ?? activity.attributes.dockId
            guard let bikePoint = bikePointsById[activeDockId] else { continue }
            if let incomingModifiedAt = bikePoint.availabilityDataModifiedAt,
               let appliedModifiedAt = localActivityAvailabilityModifiedAt[activeDockId],
               incomingModifiedAt < appliedModifiedAt {
                logger.info(
                    "Skipping older live activity refresh for dock \(activeDockId): incoming=\(incomingModifiedAt), applied=\(appliedModifiedAt)"
                )
                continue
            }

            let refreshedAlternatives = currentState.alternatives.map { alternative in
                guard let refreshed = bikePointsByName[alternative.name] else {
                    return alternative
                }

                return DockActivityAttributes.AlternativeDock(
                    name: alternative.name,
                    standardBikes: refreshed.standardBikes,
                    eBikes: refreshed.eBikes,
                    emptySpaces: refreshed.emptyDocks
                )
            }

            let availabilityChanged =
                currentState.standardBikes != bikePoint.standardBikes ||
                currentState.eBikes != bikePoint.eBikes ||
                currentState.emptySpaces != bikePoint.emptyDocks
            let alternativesChanged = refreshedAlternatives != currentState.alternatives

            guard availabilityChanged || alternativesChanged else { continue }

            let updatedState = DockActivityAttributes.ContentState(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                alternatives: refreshedAlternatives,
                activeDockId: currentState.activeDockId ?? activeDockId,
                activeDockName: currentState.activeDockName ?? bikePoint.commonName,
                activeDockAlias: currentState.activeDockAlias,
                activeJourneyPhase: currentState.activeJourneyPhase,
                primaryDisplay: currentState.primaryDisplay
            )
            let staleDate = staleDates[dockId] ?? activity.content.staleDate

            await activity.update(ActivityContent(state: updatedState, staleDate: staleDate))
            if dockId != activeDockId {
                activeActivities.removeValue(forKey: dockId)
                staleDates.removeValue(forKey: dockId)
                localActivityAvailabilityModifiedAt.removeValue(forKey: dockId)
            }
            activeActivities[activeDockId] = activity
            staleDates[activeDockId] = staleDate
            if let incomingModifiedAt = bikePoint.availabilityDataModifiedAt {
                localActivityAvailabilityModifiedAt[activeDockId] = incomingModifiedAt
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
                    adHocJourneyId: nil
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

    func advanceJourneyFromStart(dockId: String) async -> Bool {
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
        await transitionScheduledJourneyToEndDock(
            journeyId: activity.attributes.scheduledJourneyId,
            adHocJourneyId: activity.attributes.adHocJourneyId,
            endDock: endDock,
            delaySeconds: 0
        )
        return true
    }

    func advanceScheduledJourneyFromStart(dockId: String) async -> Bool {
        await advanceJourneyFromStart(dockId: dockId)
    }

    func transitionScheduledJourneyToEndDock(
        journeyId: String?,
        adHocJourneyId: String? = nil,
        endDock: ScheduledJourneyDock,
        delaySeconds: UInt64 = 60
    ) async {
        let current = activeActivities.values.first { activity in
            let phase = ScheduledJourney.ActiveRun.Phase(
                rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            )
            return phase == .start
                && (journeyId == nil || activity.attributes.scheduledJourneyId == journeyId)
                && (adHocJourneyId == nil || activity.attributes.adHocJourneyId == adHocJourneyId)
        } ?? activeActivities.values.first

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
            await ScheduledJourneyService.shared.updatePhase(journeyId: journeyId, phase: .end)
        }
        if let adHocJourneyId {
            AdHocJourneyService.shared.markPhase(journeyId: adHocJourneyId, phase: .end)
        }

        let endBikePoint = await fetchBikePointIfPossible(dock: endDock)
        let alternatives = await scheduledJourneyAlternatives(for: endBikePoint, phase: .end)
        let alternativeDocks = alternatives.prefix(5).map {
            DockActivityAttributes.AlternativeDock(
                name: $0.commonName,
                standardBikes: $0.standardBikes,
                eBikes: $0.eBikes,
                emptySpaces: $0.emptyDocks
            )
        }
        let updatedState = DockActivityAttributes.ContentState(
            standardBikes: endBikePoint.standardBikes,
            eBikes: endBikePoint.eBikes,
            emptySpaces: endBikePoint.emptyDocks,
            alternatives: Array(alternativeDocks),
            activeDockId: endBikePoint.id,
            activeDockName: endBikePoint.commonName,
            activeDockAlias: nil,
            activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue,
            primaryDisplay: LiveActivityPrimaryDisplay.spaces.rawValue
        )
        let staleDate = current?.content.staleDate ?? Date().addingTimeInterval(configuredLiveActivityExpirySeconds())

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

    private func handleObservedActivity(_ activity: Activity<DockActivityAttributes>) async {
        let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        let dockName = activity.content.state.resolvedDockName ?? activity.attributes.dockName
        activeActivities[dockId] = activity
        staleDates[dockId] = activity.content.staleDate
        let scheduledJourneyPhase = ScheduledJourney.ActiveRun.Phase(
            rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
        )
        let alternatives = await updateScheduledJourneyAlternativesIfNeeded(
            for: activity,
            phase: scheduledJourneyPhase
        )

        if let pushToken = activity.pushToken {
            let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
            await registerWithServer(
                dockId: dockId,
                pushToken: tokenString,
                dockName: dockName,
                alternatives: alternatives,
                currentState: activity.content.state,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase
            )
        }

        if let phase = scheduledJourneyPhase,
           let latitude = activity.attributes.latitude,
           let longitude = activity.attributes.longitude {
            let bikePoint = BikePoint(
                id: dockId,
                commonName: dockName,
                lat: latitude,
                lon: longitude
            )
            let destinationDock: ScheduledJourneyDock?
            if let destinationDockId = activity.attributes.destinationDockId,
               let destinationDockName = activity.attributes.destinationDockName,
               let destinationLatitude = activity.attributes.destinationLatitude,
               let destinationLongitude = activity.attributes.destinationLongitude {
                destinationDock = ScheduledJourneyDock(
                    id: destinationDockId,
                    name: destinationDockName,
                    latitude: destinationLatitude,
                    longitude: destinationLongitude
                )
            } else {
                destinationDock = nil
            }
            DockArrivalMonitoringService.shared.beginMonitoring(
                for: bikePoint,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                phase: phase,
                adHocJourneyId: activity.attributes.adHocJourneyId,
                destinationDock: destinationDock
            )
        }
    }

    private func updateScheduledJourneyAlternativesIfNeeded(
        for activity: Activity<DockActivityAttributes>,
        phase: ScheduledJourney.ActiveRun.Phase?
    ) async -> [DockActivityAttributes.AlternativeDock] {
        guard let phase,
              let latitude = activity.attributes.latitude,
              let longitude = activity.attributes.longitude else {
            return activity.content.state.alternatives
        }

        let activeDockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
        let activeDockName = activity.content.state.resolvedDockName ?? activity.attributes.dockName
        guard activeDockId == activity.attributes.dockId else {
            // The journey has already transitioned to a mutable destination dock. The immutable
            // attributes still describe the original dock, so recomputing alternatives from them
            // would regress the content state.
            return activity.content.state.alternatives
        }

        let dock = ScheduledJourneyDock(
            id: activeDockId,
            name: activeDockName,
            latitude: latitude,
            longitude: longitude
        )
        let bikePoint = await fetchBikePointIfPossible(dock: dock)
        let alternatives = await scheduledJourneyAlternatives(for: bikePoint, phase: phase)
        let alternativeDocks = alternatives.prefix(5).map {
            DockActivityAttributes.AlternativeDock(
                name: $0.commonName,
                standardBikes: $0.standardBikes,
                eBikes: $0.eBikes,
                emptySpaces: $0.emptyDocks
            )
        }

        let updatedState = DockActivityAttributes.ContentState(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            alternatives: Array(alternativeDocks),
            activeDockId: activeDockId,
            activeDockName: activeDockName,
            activeDockAlias: activity.content.state.resolvedAlias,
            activeJourneyPhase: phase.rawValue,
            primaryDisplay: activity.content.state.primaryDisplay
        )
        let updatedContent = ActivityContent(
            state: updatedState,
            staleDate: activity.content.staleDate
        )
        await activity.update(updatedContent)
        return updatedState.alternatives
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

        for activity in runningActivities where activity.activityState == .active {
            guard let pushToken = activity.pushToken else { continue }
            let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
            let scheduledJourneyPhase = ScheduledJourney.ActiveRun.Phase(
                rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
            )
            let dockId = activity.content.state.resolvedDockId ?? activity.attributes.dockId
            let dockName = activity.content.state.resolvedDockName ?? activity.attributes.dockName
            let alternatives = await updateScheduledJourneyAlternativesIfNeeded(
                for: activity,
                phase: scheduledJourneyPhase
            )
            logger.info(
                "Re-registering active live activity for dock \(dockId) after APNs device token update"
            )
            await registerWithServer(
                dockId: dockId,
                pushToken: tokenString,
                dockName: dockName,
                alternatives: alternatives,
                currentState: activity.content.state,
                scheduledJourneyId: activity.attributes.scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase
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
                    primaryDisplay: display.rawValue
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
        if let override = LiveActivityDockSettings.getPrimaryDisplay(for: dockId) {
            return override
        }
        let globalRawValue = AppConstants.UserDefaults.sharedDefaults.string(forKey: LiveActivityPrimaryDisplay.userDefaultsKey) ?? LiveActivityPrimaryDisplay.bikes.rawValue
        return LiveActivityPrimaryDisplay(rawValue: globalRawValue) ?? .bikes
    }

    /// Restore activities that may still be running from a previous app session
    func restoreActivities() {
        let runningActivities = Activity<DockActivityAttributes>.activities
        let runningDockIds = Set(runningActivities.map { $0.content.state.resolvedDockId ?? $0.attributes.dockId })

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
            let dockName = activity.content.state.resolvedDockName ?? activity.attributes.dockName

            // End stale activities immediately rather than restoring them
            if activity.activityState == .stale {
                logger.info("Restored live activity for dock \(dockId) is stale — ending immediately")
                Task { [weak self] in
                    await self?.endActivityInstance(activity, dockId: dockId)
                }
                continue
            }

            if activity.activityState == .active {
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

                // Cancel any existing observation tasks
                cancelObservationTasks(for: dockId)

                // Re-register restored activities with the server so push updates
                // resume even after process/server restarts.
                if let pushToken = activity.pushToken {
                    let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                    Task { [weak self] in
                        guard let self else { return }
                        let scheduledJourneyPhase = ScheduledJourney.ActiveRun.Phase(
                            rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
                        )
                        let alternatives = await self.updateScheduledJourneyAlternativesIfNeeded(
                            for: activity,
                            phase: scheduledJourneyPhase
                        )
                        await self.registerWithServer(
                            dockId: dockId,
                            pushToken: tokenString,
                            dockName: dockName,
                            alternatives: alternatives,
                            currentState: activity.content.state,
                            scheduledJourneyId: activity.attributes.scheduledJourneyId,
                            scheduledJourneyPhase: scheduledJourneyPhase
                        )
                    }
                }

                let pushTokenTask = Task { [weak self] in
                    for await pushToken in activity.pushTokenUpdates {
                        guard let self = self else { break }
                        let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                        self.logger.info("Restored push token for dock \(dockId): \(tokenString)")
                        let scheduledJourneyPhase = ScheduledJourney.ActiveRun.Phase(
                            rawValue: activity.content.state.activeJourneyPhase ?? activity.attributes.scheduledJourneyPhase ?? ""
                        )
                        let alternatives = await self.updateScheduledJourneyAlternativesIfNeeded(
                            for: activity,
                            phase: scheduledJourneyPhase
                        )
                        await self.registerWithServer(
                            dockId: dockId,
                            pushToken: tokenString,
                            dockName: dockName,
                            alternatives: alternatives,
                            currentState: activity.content.state,
                            scheduledJourneyId: activity.attributes.scheduledJourneyId,
                            scheduledJourneyPhase: scheduledJourneyPhase
                        )
                    }
                }

                // Re-observe state changes
                let stateTask = Task { [weak self] in
                    for await state in activity.activityStateUpdates {
                        guard let self = self else { break }
                        if state == .stale {
                            self.logger.info("Restored activity for dock \(dockId) is stale — ending immediately")
                            await MainActor.run { self.endLiveActivity(for: dockId) }
                            break
                        } else if state == .dismissed || state == .ended {
                            await MainActor.run {
                                if let adHocJourneyId = activity.attributes.adHocJourneyId {
                                    AdHocJourneyService.shared.complete(journeyId: adHocJourneyId)
                                }
                                self.clearLocallyTrackedActivity(for: dockId)
                                self.notifyPrimaryDisplayChanged()
                            }
                            // Notify server to stop polling
                            if let pushToken = activity.pushToken {
                                let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                                await self.unregisterFromServer(dockId: dockId, pushToken: tokenString)
                            }
                            break
                        }
                    }
                }

                // Store task so it can be cancelled later
                observationTasks[dockId] = [pushTokenTask, stateTask]
            }
        }

        if !runningActivities.isEmpty {
            logger.info("Restored \(self.activeActivities.count) live activities")
        }

        DockArrivalMonitoringService.shared.restoreMonitoringIfNeeded(
            activeDockIds: Set(self.activeActivities.keys)
        )

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
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil
    ) async {
        let urlString = "\(serverBaseURL)/live-activity/start"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid server URL: \(urlString)")
            return
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

        let serializedAlternatives: [[String: Any]] = alternatives.map { alternative in
            [
                "name": alternative.name,
                "standardBikes": alternative.standardBikes,
                "eBikes": alternative.eBikes,
                "emptySpaces": alternative.emptySpaces,
            ]
        }
        let primaryDisplayRawValue = scheduledJourneyPrimaryDisplay(
            dockId: dockId,
            scheduledJourneyPhase: scheduledJourneyPhase
        )
        let minimumThresholds = minimumThresholdsPayload()

        var body: [String: Any] = [
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
        }
        if let scheduledJourneyId {
            body["scheduledJourneyId"] = scheduledJourneyId
        }
        if let scheduledJourneyPhase {
            body["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                trackServerSession(dockId: dockId, pushToken: pushToken)
                let activeThreshold = primaryDisplayRawValue == "allBikes"
                    ? (minimumThresholds[LiveActivityPrimaryDisplay.bikes.rawValue] ?? 0) + (minimumThresholds[LiveActivityPrimaryDisplay.eBikes.rawValue] ?? 0)
                    : minimumThresholds[primaryDisplayRawValue] ?? 0
                logger.info("Registered live activity with server for dock \(dockId) (expires in \(Int(finalExpirySeconds))s, alternatives: \(serializedAlternatives.count), primaryDisplay: \(primaryDisplayRawValue), minimumThreshold: \(activeThreshold))")
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
            } else {
                logger.warning("Server returned unexpected response for dock \(dockId)")
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
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
            }
        } catch {
            logger.error("Failed to register with server: \(error.localizedDescription)")
            logLiveActivityDiagnosticEvent(
                "live_activity_server_registration_failed_network",
                dockId: dockId,
                dockName: dockName,
                scheduledJourneyId: scheduledJourneyId,
                scheduledJourneyPhase: scheduledJourneyPhase,
                message: "Failed to register live activity with server: \(error.localizedDescription)",
                raw: ["pushTokenPrefix": String(pushToken.prefix(8))]
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
        scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase? = nil
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
            "dockId": dockId,
            "pushToken": pushToken,
            "primaryDisplay": primaryDisplay.rawValue,
            "minimumThresholds": minimumThresholdsPayload(),
        ]
        if let targetDockId, !targetDockId.isEmpty {
            body["targetDockId"] = targetDockId
        }
        if let dockName, !dockName.isEmpty {
            body["dockName"] = dockName
        }
        if let alternatives {
            body["alternatives"] = alternatives.map { alternative in
                [
                    "name": alternative.name,
                    "standardBikes": alternative.standardBikes,
                    "eBikes": alternative.eBikes,
                    "emptySpaces": alternative.emptySpaces,
                ]
            }
        }
        if let currentState {
            body["standardBikes"] = currentState.standardBikes
            body["eBikes"] = currentState.eBikes
            body["emptySpaces"] = currentState.emptySpaces
            body["activeDockId"] = currentState.activeDockId
            body["activeDockName"] = currentState.activeDockName
            body["activeDockAlias"] = currentState.activeDockAlias
            body["activeJourneyPhase"] = currentState.activeJourneyPhase
        }
        if let scheduledJourneyPhase {
            body["scheduledJourneyPhase"] = scheduledJourneyPhase.rawValue
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
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
}

private struct LiveActivityFailableBikePoint: Decodable {
    let value: BikePoint?

    init(from decoder: Decoder) throws {
        value = try? BikePoint(from: decoder)
    }
}
