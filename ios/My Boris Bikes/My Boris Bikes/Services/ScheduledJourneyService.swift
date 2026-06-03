import ActivityKit
import Foundation
import os.log

@MainActor
final class ScheduledJourneyService: ObservableObject {
    static let shared = ScheduledJourneyService()

    @Published private(set) var journeys: [ScheduledJourney] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private struct ListResponse: Decodable {
        let journeys: [ScheduledJourney]
    }

    private struct JourneyResponse: Decodable {
        let journey: ScheduledJourney
    }

    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "ScheduledJourneys")
    private let pushToStartTokenStorageKey = "scheduled_journey_push_to_start_token"
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var pushToStartTask: Task<Void, Never>?

    private init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: rawValue) {
                return date
            }
            let fallback = ISO8601DateFormatter()
            if let date = fallback.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    deinit {
        pushToStartTask?.cancel()
    }

    var deviceId: String {
        DeviceTokenHelper.scheduledJourneyDeviceId
    }

    func startPushToStartTokenObservation() {
        guard pushToStartTask == nil else { return }
        pushToStartTask = Task { [weak self] in
            for await token in Activity<DockActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { break }
                let tokenString = token.map { String(format: "%02x", $0) }.joined()
                UserDefaults.standard.set(tokenString, forKey: self.pushToStartTokenStorageKey)
                await self.registerDevice(pushToStartToken: tokenString)
            }
        }
    }

    func registerDevice(pushToStartToken: String? = nil) async {
        let effectivePushToStartToken = pushToStartToken
            ?? UserDefaults.standard.string(forKey: pushToStartTokenStorageKey)
        var body: [String: Any] = [
            "deviceId": deviceId,
            "buildType": PushEnvironment.buildType,
            "timezone": TimeZone.current.identifier,
            "bikeDataFilter": currentBikeDataFilterRawValue(),
        ]
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            body["deviceToken"] = deviceToken
        }
        if let pushToStartToken {
            body["pushToStartToken"] = pushToStartToken
        } else if let storedToken = effectivePushToStartToken {
            body["pushToStartToken"] = storedToken
        }

        do {
            _ = try await request(
                path: "/scheduled-journeys/device/register",
                method: "POST",
                body: body,
                responseType: EmptyResponse.self
            )
            TroubleshootingLogStore.shared.record(
                category: "scheduled_journey",
                event: "device_registered",
                message: "Registered device for scheduled journeys.",
                metadata: [
                    "deviceId": deviceId,
                    "buildType": PushEnvironment.buildType,
                    "hasApnsDeviceToken": DeviceTokenHelper.apnsDeviceToken != nil,
                    "hasPushToStartToken": effectivePushToStartToken != nil,
                    "pushToStartTokenPrefix": effectivePushToStartToken.map { String($0.prefix(8)) },
                ]
            )
        } catch {
            logger.error("Failed to register scheduled journey device: \(error.localizedDescription)")
            TroubleshootingLogStore.shared.record(
                category: "scheduled_journey",
                event: "device_registration_failed",
                message: "Failed to register device for scheduled journeys: \(error.localizedDescription)",
                metadata: [
                    "deviceId": deviceId,
                    "buildType": PushEnvironment.buildType,
                    "hasApnsDeviceToken": DeviceTokenHelper.apnsDeviceToken != nil,
                    "hasPushToStartToken": effectivePushToStartToken != nil,
                ]
            )
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await request(
                path: "/scheduled-journeys?deviceId=\(deviceId)",
                method: "GET",
                body: nil,
                responseType: ListResponse.self
            )
            journeys = response.journeys
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createJourney(from draft: ScheduledJourneyDraft) async throws -> ScheduledJourney {
        guard let startDock = draft.startDock, let endDock = draft.endDock else {
            throw ScheduledJourneyError.invalidDraft
        }

        var body = scheduledJourneyPayload(
            startDock: startDock,
            endDock: endDock,
            draft: draft
        )
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            body["deviceToken"] = deviceToken
        }
        if let pushToStartToken = UserDefaults.standard.string(forKey: pushToStartTokenStorageKey) {
            body["pushToStartToken"] = pushToStartToken
        }

        let response = try await request(
            path: "/scheduled-journeys",
            method: "POST",
            body: body,
            responseType: JourneyResponse.self
        )
        await refresh()
        return response.journey
    }

    func update(_ journey: ScheduledJourney, from draft: ScheduledJourneyDraft) async throws -> ScheduledJourney {
        guard let startDock = draft.startDock, let endDock = draft.endDock else {
            throw ScheduledJourneyError.invalidDraft
        }

        let response = try await request(
            path: "/scheduled-journeys/\(journey.id)",
            method: "PUT",
            body: scheduledJourneyPayload(
                startDock: startDock,
                endDock: endDock,
                draft: draft
            ),
            responseType: JourneyResponse.self
        )
        await refresh()
        return response.journey
    }

    private func scheduledJourneyPayload(
        startDock: ScheduledJourneyDock,
        endDock: ScheduledJourneyDock,
        draft: ScheduledJourneyDraft
    ) -> [String: Any] {
        [
            "deviceId": deviceId,
            "startDock": dockPayload(startDock),
            "endDock": dockPayload(endDock),
            "weekdays": draft.weekdays,
            "startTime": draft.startTime,
            "endTime": draft.endTime,
            "timezone": draft.timezone,
            "enabled": draft.enabled,
            "buildType": PushEnvironment.buildType,
            "bikeDataFilter": currentBikeDataFilterRawValue(),
        ]
    }

    private func currentBikeDataFilterRawValue() -> String {
        BikeDataFilter.userDefaultsStore.string(forKey: BikeDataFilter.userDefaultsKey)
            ?? BikeDataFilter.both.rawValue
    }

    func delete(_ journey: ScheduledJourney) async {
        do {
            _ = try await request(
                path: "/scheduled-journeys/\(journey.id)?deviceId=\(deviceId)",
                method: "DELETE",
                body: nil,
                responseType: EmptyResponse.self
            )
            journeys.removeAll { $0.id == journey.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ journey: ScheduledJourney) async {
        do {
            _ = try await request(
                path: "/scheduled-journeys/\(journey.id)/stop",
                method: "POST",
                body: baseDeviceBody(),
                responseType: JourneyResponse.self
            )
            if let activeDockId = journey.activeRun?.dockId {
                await LiveActivityService.shared.endLiveActivityFromUserAction(
                    dockId: activeDockId,
                    dockName: journey.activeRun?.dockName,
                    reason: "scheduled_journey_stop"
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activate(_ journey: ScheduledJourney) async {
        TroubleshootingLogStore.shared.record(
            category: "scheduled_journey",
            event: "manual_activation_started",
            message: "Manual activation started for scheduled journey.",
            metadata: [
                "journeyId": journey.id,
                "startDock": journey.startDock.name,
                "endDock": journey.endDock.name,
                "startTime": journey.startTime,
                "endTime": journey.endTime,
                "timezone": journey.timezone,
            ]
        )
        await LiveActivityService.shared.startScheduledJourney(journey, phase: .start, manuallyActivated: true)
        do {
            _ = try await request(
                path: "/scheduled-journeys/\(journey.id)/activate",
                method: "POST",
                body: baseDeviceBody(merging: ["remoteStart": false]),
                responseType: JourneyResponse.self
            )
            TroubleshootingLogStore.shared.record(
                category: "scheduled_journey",
                event: "manual_activation_server_updated",
                message: "Server active-run state updated after manual activation.",
                metadata: ["journeyId": journey.id]
            )
            await refresh()
        } catch {
            logger.warning("Server manual activation update failed: \(error.localizedDescription)")
            TroubleshootingLogStore.shared.record(
                category: "scheduled_journey",
                event: "manual_activation_server_update_failed",
                message: "Server manual activation update failed: \(error.localizedDescription)",
                metadata: ["journeyId": journey.id]
            )
        }
    }

    func updatePhase(
        journeyId: String,
        phase: ScheduledJourney.ActiveRun.Phase,
        transitionSource: String? = nil
    ) async {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "phase": phase.rawValue,
        ]
        if let transitionSource {
            body["transitionSource"] = transitionSource
        }

        do {
            _ = try await request(
                path: "/scheduled-journeys/\(journeyId)/phase",
                method: "POST",
                body: body,
                responseType: JourneyResponse.self
            )
            await refresh()
        } catch {
            logger.warning("Failed to update scheduled journey phase: \(error.localizedDescription)")
        }
    }

    func complete(journeyId: String) async {
        do {
            _ = try await request(
                path: "/scheduled-journeys/\(journeyId)/complete",
                method: "POST",
                body: baseDeviceBody(),
                responseType: JourneyResponse.self
            )
            await refresh()
        } catch {
            logger.warning("Failed to complete scheduled journey: \(error.localizedDescription)")
        }
    }

    func journey(withId id: String) -> ScheduledJourney? {
        journeys.first { $0.id == id }
    }

    private func dockPayload(_ dock: ScheduledJourneyDock) -> [String: Any] {
        [
            "id": dock.id,
            "name": dock.name,
            "latitude": dock.latitude,
            "longitude": dock.longitude,
        ]
    }

    private func baseDeviceBody(merging extraValues: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "buildType": PushEnvironment.buildType,
        ]
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            body["deviceToken"] = deviceToken
        }
        for (key, value) in extraValues {
            body[key] = value
        }
        return body
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?,
        responseType: T.Type
    ) async throws -> T {
        guard let url = URL(string: AppConstants.Server.baseURL + path) else {
            throw ScheduledJourneyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if let deviceToken = DeviceTokenHelper.apnsDeviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScheduledJourneyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(ServerError.self, from: data).error)
                ?? "Server returned HTTP \(httpResponse.statusCode)"
            throw ScheduledJourneyError.server(serverMessage)
        }

        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct EmptyResponse: Decodable {}

private struct ServerError: Decodable {
    let error: String
}

enum ScheduledJourneyError: LocalizedError {
    case invalidDraft
    case invalidURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidDraft:
            return "Choose both a start and end dock."
        case .invalidURL:
            return "The scheduled journey server URL is invalid."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .server(let message):
            return message
        }
    }
}
