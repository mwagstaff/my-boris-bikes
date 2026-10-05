import Foundation
import os.log

enum CurrentActiveJourney {
    case scheduled(ScheduledJourney)
    case adHoc(AdHocJourney)

    var activityDate: Date {
        switch self {
        case .scheduled(let journey):
            return journey.activeRun?.startedAt ?? journey.updatedAt ?? .distantPast
        case .adHoc(let journey):
            return journey.lastStartedAt ?? journey.createdAt
        }
    }
}

@MainActor
final class AdHocJourneyService: ObservableObject {
    static let shared = AdHocJourneyService()

    @Published private(set) var recentJourneys: [AdHocJourney] = []

    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "AdHocJourneys")
    private let storageKey = "recentAdHocJourneys"
    private let maxStoredJourneys = 10
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
        if !AppConstants.UserDefaults.sharedDefaults.bool(forKey: "journeyHistoryMigrated") {
            for journey in recentJourneys {
                guard let startedAt = journey.lastStartedAt else { continue }
                recordHistory(journey, startedAt: startedAt)
            }
            AppConstants.UserDefaults.sharedDefaults.set(true, forKey: "journeyHistoryMigrated")
        }
    }

    func save(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) {
        upsert(AdHocJourney(startDock: startDock, endDock: endDock))
    }

    @discardableResult
    func createAndStart(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock,
                        kind: JourneyHistoryEntry.Kind? = nil) async -> Bool {
        guard LiveActivityService.shared.canStartJourneyActivity, !Task.isCancelled else { return false }
        let journey = AdHocJourney(
            startDock: startDock,
            endDock: endDock,
            lastStartedAt: Date(),
            activePhase: .start
        )
        upsert(journey)
        await LiveActivityService.shared.startAdHocJourney(journey)
        guard LiveActivityService.shared.isActivityActive(for: startDock.id), !Task.isCancelled else {
            complete(journeyId: journey.id)
            return false
        }
        recordHistory(journey, startedAt: journey.lastStartedAt ?? Date(), kind: kind)
        return true
    }

    /// Alternative choices affect this run only, including runs started from a schedule.
    func switchDock(to bikePoint: BikePoint, for activeJourney: CurrentActiveJourney) async -> String? {
        guard LiveActivityService.shared.canStartJourneyActivity else {
            return "Enable Live Activities for BikeSpot London in Settings to watch another dock."
        }
        let startDock: ScheduledJourneyDock
        let endDock: ScheduledJourneyDock
        let phase: ScheduledJourney.ActiveRun.Phase
        let scheduledService = ScheduledJourneyService.shared
        switch activeJourney {
        case .scheduled(let journey):
            guard let current = scheduledService.journeys.first(where: { $0.id == journey.id }),
                  let currentPhase = current.activeRun?.phase,
                  currentPhase == journey.activeRun?.phase else { return "The journey has changed. Please try again." }
            startDock = current.startDock
            endDock = current.endDock
            phase = currentPhase
            guard bikePoint.id != startDock.id, bikePoint.id != endDock.id else { return nil }
            guard !Task.isCancelled else { return nil }
            guard await scheduledService.stop(current) else {
                return scheduledService.errorMessage ?? "Couldn’t stop watching the previous dock. Try again."
            }
        case .adHoc(let journey):
            guard let current = recentJourneys.first(where: { $0.id == journey.id }),
                  let currentPhase = current.activePhase,
                  currentPhase == journey.activePhase else { return "The journey has changed. Please try again." }
            startDock = current.startDock
            endDock = current.endDock
            phase = currentPhase
            guard bikePoint.id != startDock.id, bikePoint.id != endDock.id else { return nil }
            guard !Task.isCancelled else { return nil }
            await stop(current)
        }
        guard !Task.isCancelled else { return nil }
        let replacement = ScheduledJourneyDock(bikePoint: bikePoint)
        let started = await continueJourney(
            startDock: phase == .start ? replacement : startDock,
            endDock: phase == .end ? replacement : endDock,
            phase: phase
        )
        return started ? nil : "The previous dock is no longer being watched. The updated route is saved in ad-hoc journeys; try starting it again."
    }

    /// Continue a single trip with changed docks without changing its saved route.
    private func continueJourney(
        startDock: ScheduledJourneyDock,
        endDock: ScheduledJourneyDock,
        phase: ScheduledJourney.ActiveRun.Phase
    ) async -> Bool {
        guard startDock.id != endDock.id, !Task.isCancelled else { return false }
        let journey = AdHocJourney(
            startDock: startDock, endDock: endDock, lastStartedAt: Date(), activePhase: phase
        )
        upsert(journey)
        await LiveActivityService.shared.startAdHocJourney(journey)
        let dock = phase == .start ? startDock : endDock
        guard LiveActivityService.shared.isActivityActive(for: dock.id) else {
            complete(journeyId: journey.id)
            return false
        }
        recordHistory(journey, startedAt: journey.lastStartedAt ?? Date())
        return true
    }

    func start(_ journey: AdHocJourney) async {
        await createAndStart(startDock: journey.startDock, endDock: journey.endDock)
    }

    func startReturn(_ journey: AdHocJourney) async {
        await createAndStart(startDock: journey.endDock, endDock: journey.startDock)
    }

    func stop(_ journey: AdHocJourney) async {
        let docks = [journey.startDock, journey.endDock]
            .reduce(into: [ScheduledJourneyDock]()) { uniqueDocks, dock in
                guard !uniqueDocks.contains(where: { $0.id == dock.id }) else { return }
                uniqueDocks.append(dock)
            }

        for dock in docks {
            await LiveActivityService.shared.endLiveActivityFromUserAction(
                dockId: dock.id,
                dockName: dock.name,
                reason: "ad_hoc_journey_stop"
            )
        }

        complete(journeyId: journey.id)
    }

    func markPhase(journeyId: String, phase: ScheduledJourney.ActiveRun.Phase) {
        guard let index = recentJourneys.firstIndex(where: { $0.id == journeyId }) else { return }
        recentJourneys[index].activePhase = phase
        recentJourneys[index].lastStartedAt = recentJourneys[index].lastStartedAt ?? Date()
        persist()
    }

    func complete(journeyId: String) {
        JourneyHistoryService.shared.finish(journeyID: journeyId)
        guard let index = recentJourneys.firstIndex(where: { $0.id == journeyId }) else { return }
        recentJourneys[index].activePhase = nil
        recentJourneys[index].lastStartedAt = recentJourneys[index].lastStartedAt ?? Date()
        sortAndTrim()
        persist()
    }

    func reconcileActivePhases(activeJourneyIds: Set<String>) {
        var changed = false
        for index in recentJourneys.indices where recentJourneys[index].activePhase != nil {
            guard !activeJourneyIds.contains(recentJourneys[index].id) else { continue }
            recentJourneys[index].activePhase = nil
            changed = true
        }

        guard changed else { return }
        sortAndTrim()
        persist()
    }

    private func recordHistory(_ journey: AdHocJourney, startedAt: Date, kind: JourneyHistoryEntry.Kind? = nil) {
        let resolvedKind: JourneyHistoryEntry.Kind = kind ?? (FavoriteJourneyService.shared.isFavorite(
            startDock: journey.startDock, endDock: journey.endDock) ? .favourite : .adHoc)
        JourneyHistoryService.shared.record(id: "ad-hoc-\(journey.id)", journeyID: journey.id,
            start: journey.startDock, end: journey.endDock, startedAt: startedAt, kind: resolvedKind)
    }

    private func upsert(_ journey: AdHocJourney) {
        recentJourneys.removeAll { existing in
            existing.id == journey.id ||
            (existing.startDock.id == journey.startDock.id && existing.endDock.id == journey.endDock.id)
        }
        recentJourneys.insert(journey, at: 0)
        sortAndTrim()
        persist()
    }

    private func sortAndTrim() {
        recentJourneys.sort {
            ($0.lastStartedAt ?? $0.createdAt) > ($1.lastStartedAt ?? $1.createdAt)
        }
        if recentJourneys.count > maxStoredJourneys {
            recentJourneys = Array(recentJourneys.prefix(maxStoredJourneys))
        }
    }

    private func load() {
        guard let data = AppConstants.UserDefaults.sharedDefaults.data(forKey: storageKey) else { return }
        do {
            recentJourneys = try decoder.decode([AdHocJourney].self, from: data)
        } catch {
            logger.warning("Failed to load ad-hoc journey history: \(error.localizedDescription)")
            recentJourneys = []
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(recentJourneys)
            AppConstants.UserDefaults.sharedDefaults.set(data, forKey: storageKey)
        } catch {
            logger.warning("Failed to persist ad-hoc journey history: \(error.localizedDescription)")
        }
    }
}
