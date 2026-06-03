import Foundation
import os.log

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
    }

    func createAndStart(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) async {
        let journey = AdHocJourney(
            startDock: startDock,
            endDock: endDock,
            lastStartedAt: Date(),
            activePhase: .start
        )
        upsert(journey)
        await LiveActivityService.shared.startAdHocJourney(journey)
    }

    func start(_ journey: AdHocJourney) async {
        var updated = journey
        updated.lastStartedAt = Date()
        updated.activePhase = .start
        upsert(updated)
        await LiveActivityService.shared.startAdHocJourney(updated)
    }

    func startReturn(_ journey: AdHocJourney) async {
        let returnJourney = AdHocJourney(
            startDock: journey.endDock,
            endDock: journey.startDock,
            lastStartedAt: Date(),
            activePhase: .start
        )
        upsert(returnJourney)
        await LiveActivityService.shared.startAdHocJourney(returnJourney)
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
        guard let index = recentJourneys.firstIndex(where: { $0.id == journeyId }) else { return }
        recentJourneys[index].activePhase = nil
        recentJourneys[index].lastStartedAt = recentJourneys[index].lastStartedAt ?? Date()
        sortAndTrim()
        persist()
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
