//
//  LiveActivityService.swift
//  My Boris Bikes
//
//  Manages Live Activities for real-time dock availability tracking
//

import ActivityKit
import Foundation
import os.log

@MainActor
class LiveActivityService: ObservableObject {
    struct ActiveNotificationSession: Equatable {
        let dockId: String
        let dockName: String
        let expiresAt: Date?
    }

    private struct DeviceNotificationStatusResponse: Decodable {
        struct Session: Decodable {
            let dockId: String
            let dockName: String
            let expiresAt: String?
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

    /// Track stale dates for active activities (keyed by dock ID)
    private var staleDates: [String: Date] = [:]

    /// Track observation tasks to cancel them when activities end
    private var observationTasks: [String: [Task<Void, Never>]] = [:]

    /// Server base URL for the live activity API
    var serverBaseURL: String {
        AppConstants.Server.baseURL
    }

    /// Build type determines APNS environment (sandbox vs production)
    var buildType: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
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
        cancelObservationTasks(for: dockId)
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
    private func endActivityInstance(_ activity: Activity<DockActivityAttributes>, dockId: String) async {
        if let pushToken = activity.pushToken {
            let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
            await unregisterFromServer(dockId: dockId, pushToken: tokenString)
        }

        LiveActivityDockSettings.clearPrimaryDisplay(for: dockId)
        notifyPrimaryDisplayChanged()

        let finalState = DockActivityAttributes.ContentState(
            standardBikes: 0,
            eBikes: 0,
            emptySpaces: 0
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)
        await activity.end(finalContent, dismissalPolicy: .immediate)
        logger.info("Ended extra live activity for dock \(dockId)")
    }

    // MARK: - Public API

    func startLiveActivity(for bikePoint: BikePoint, alias: String?, alternatives: [BikePoint] = []) {
        let dockId = bikePoint.id

        // Enforce a single active live activity across the app
        endAllActivities(except: dockId)

        // End existing activity for this dock if one exists
        if activeActivities[dockId] != nil {
            endLiveActivity(for: dockId)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("Live Activities are not enabled on this device")
            return
        }

        let attributes = DockActivityAttributes(
            dockId: dockId,
            dockName: bikePoint.commonName,
            alias: alias
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
            alternatives: Array(alternativeDocks)
        )

        // Calculate stale date based on configured duration, capped to notification window max.
        let finalExpirySeconds = configuredLiveActivityExpirySeconds()
        let staleDate = Date().addingTimeInterval(finalExpirySeconds)

        let content = ActivityContent(state: initialState, staleDate: staleDate)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )

            activeActivities[dockId] = activity
            staleDates[dockId] = staleDate
            logger.info("Started live activity for dock \(dockId) with stale date: \(staleDate)")

            // Register immediately if the token is already available.
            // In some launches the first push token can be present synchronously and
            // we should not rely solely on the async updates sequence.
            if let pushToken = activity.pushToken {
                let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                logger.info("Initial push token for dock \(dockId): \(tokenString)")
                Task { [weak self] in
                    guard let self else { return }
                    await self.registerWithServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: bikePoint.commonName,
                        alternatives: activity.content.state.alternatives
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
                    await self.registerWithServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: bikePoint.commonName,
                        alternatives: activity.content.state.alternatives
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
        }
    }

    func endLiveActivity(for dockId: String) {
        guard let activity = activeActivities[dockId] else { return }

        // Remove from active tracking synchronously to prevent double-end races
        activeActivities.removeValue(forKey: dockId)
        staleDates.removeValue(forKey: dockId)

        // Cancel observation tasks before ending so state observer doesn't react to .ended
        cancelObservationTasks(for: dockId)

        // Clear the per-dock override
        LiveActivityDockSettings.clearPrimaryDisplay(for: dockId)
        notifyPrimaryDisplayChanged()

        let finalState = DockActivityAttributes.ContentState(
            standardBikes: 0,
            eBikes: 0,
            emptySpaces: 0
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)

        let pushTokenString = activity.pushToken.map { $0.map { String(format: "%02x", $0) }.joined() }
        Task {
            await activity.end(finalContent, dismissalPolicy: .immediate)
            if let tokenString = pushTokenString {
                await unregisterFromServer(dockId: dockId, pushToken: tokenString)
            }
            logger.info("Ended live activity for dock \(dockId)")
        }
    }

    func isActivityActive(for dockId: String) -> Bool {
        activeActivities[dockId] != nil
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
                    expiresAt: parseServerISODate(session.expiresAt)
                )
            } else {
                activeNotificationSession = nil
            }
        } catch {
            logger.error("Failed to refresh notification status: \(error.localizedDescription)")
        }
    }

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
                let preservedStaleDate = self.staleDates[dockId]
                let newContent = ActivityContent(state: currentState, staleDate: preservedStaleDate)
                await activity.update(newContent)
                self.logger.info("Updated live activity display for dock \(dockId)")

                if let pushToken = activity.pushToken {
                    let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                    await self.updateSessionConfigurationOnServer(
                        dockId: dockId,
                        pushToken: tokenString,
                        dockName: activity.attributes.dockName,
                        primaryDisplay: display
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
        let runningDockIds = Set(runningActivities.map { $0.attributes.dockId })

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
            let dockId = activity.attributes.dockId

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
                        await self.registerWithServer(
                            dockId: dockId,
                            pushToken: tokenString,
                            dockName: activity.attributes.dockName,
                            alternatives: activity.content.state.alternatives
                        )
                    }
                }

                let pushTokenTask = Task { [weak self] in
                    for await pushToken in activity.pushTokenUpdates {
                        guard let self = self else { break }
                        let tokenString = pushToken.map { String(format: "%02x", $0) }.joined()
                        self.logger.info("Restored push token for dock \(dockId): \(tokenString)")
                        await self.registerWithServer(
                            dockId: dockId,
                            pushToken: tokenString,
                            dockName: activity.attributes.dockName,
                            alternatives: activity.content.state.alternatives
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

    private func registerWithServer(
        dockId: String,
        pushToken: String,
        dockName: String,
        alternatives: [DockActivityAttributes.AlternativeDock]
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
        let primaryDisplayRawValue = getPrimaryDisplay(for: dockId).rawValue
        let minimumThresholds = minimumThresholdsPayload()

        let body: [String: Any] = [
            "dockId": dockId,
            "dockName": dockName,
            "pushToken": pushToken,
            "buildType": buildType,
            "expirySeconds": finalExpirySeconds,
            "alternatives": serializedAlternatives,
            "primaryDisplay": primaryDisplayRawValue,
            "minimumThresholds": minimumThresholds,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                trackServerSession(dockId: dockId, pushToken: pushToken)
                let activeThreshold = minimumThresholds[primaryDisplayRawValue] ?? 0
                logger.info("Registered live activity with server for dock \(dockId) (expires in \(Int(finalExpirySeconds))s, alternatives: \(serializedAlternatives.count), primaryDisplay: \(primaryDisplayRawValue), minimumThreshold: \(activeThreshold))")
                await refreshNotificationStatusFromServer()
            } else {
                logger.warning("Server returned unexpected response for dock \(dockId)")
            }
        } catch {
            logger.error("Failed to register with server: \(error.localizedDescription)")
        }
    }

    private func updateSessionConfigurationOnServer(
        dockId: String,
        pushToken: String,
        dockName: String?,
        primaryDisplay: LiveActivityPrimaryDisplay
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
        if let dockName, !dockName.isEmpty {
            body["dockName"] = dockName
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
}
