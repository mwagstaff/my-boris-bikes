// Standalone service checks; remote services and ActivityKit are replaced with test doubles.
import Foundation

@MainActor
enum AppConstants {
    enum UserDefaults {
        static let suiteName = "JourneyEditingChecks-\(UUID().uuidString)"
        static let sharedDefaults = Foundation.UserDefaults(suiteName: suiteName)!
        static let favoriteJourneysKey = "favoriteJourneys"
    }
}

@MainActor
final class FavoritesService {
    static let shared = FavoritesService()
    func forceSyncWithWatch() {}
}

@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()
    var canStartJourneyActivity = true
    var startedJourney: AdHocJourney?
    var activeDockID: String?
    var stoppedDockIDs: [String] = []
    func startAdHocJourney(_ journey: AdHocJourney) async {
        startedJourney = journey
        activeDockID = journey.activePhase == .end ? journey.endDock.id : journey.startDock.id
    }
    func isActivityActive(for dockID: String) -> Bool { activeDockID == dockID }
    func endLiveActivityFromUserAction(dockId: String, dockName: String?, reason: String) async {
        stoppedDockIDs.append(dockId)
        if activeDockID == dockId { activeDockID = nil }
    }
}

@MainActor
final class ScheduledJourneyService {
    static let shared = ScheduledJourneyService()
    var journeys: [ScheduledJourney] = []
    var errorMessage: String? = "Stop failed"
    var stopSucceeds = true
    var stopCount = 0
    func stop(_ journey: ScheduledJourney) async -> Bool {
        stopCount += 1
        return stopSucceeds
    }
}

@main
struct JourneyEditingChecks {
    @MainActor static func main() async {
        let defaults = AppConstants.UserDefaults.sharedDefaults
        defer { defaults.removePersistentDomain(forName: AppConstants.UserDefaults.suiteName) }
        let start = ScheduledJourneyDock(id: "start", name: "Start", latitude: 51.5, longitude: -0.1)
        let end = ScheduledJourneyDock(id: "end", name: "End", latitude: 51.6, longitude: -0.2)
        let alternative = BikePoint(id: "alternative", commonName: "Alternative", lat: 51.51, lon: -0.11)
        let replacement = ScheduledJourneyDock(bikePoint: alternative)
        let favorites = FavoriteJourneyService(userDefaults: defaults)
        favorites.add(startDock: start, endDock: end)
        let favorite = favorites.journeys[0]
        favorites.update(favorite, startDock: start, endDock: replacement)
        precondition(favorites.journeys[0].id == favorite.id)
        precondition(favorites.journeys[0].createdAt == favorite.createdAt)
        precondition(favorites.journeys[0].endDock == replacement)
        precondition(FavoriteJourneyService(userDefaults: defaults).journeys == favorites.journeys)
        favorites.add(startDock: replacement, endDock: end)
        favorites.update(favorites.journeys[0], startDock: end, endDock: replacement)
        precondition(favorites.journeys.count == 1, "Editing into an existing reverse route merges duplicates")
        favorites.update(favorites.journeys[0], startDock: start, endDock: start)
        precondition(favorites.journeys[0].startDock == end, "Invalid same-dock edit leaves route intact")

        let adHoc = AdHocJourneyService.shared
        let activity = LiveActivityService.shared
        await adHoc.createAndStart(startDock: start, endDock: end)
        var current = adHoc.recentJourneys.first(where: \.isActive)!
        activity.canStartJourneyActivity = false
        var error = await adHoc.switchDock(to: alternative, for: .adHoc(current))
        precondition(error != nil && activity.stoppedDockIDs.isEmpty, "Disabled activities must not stop the current trip")
        activity.canStartJourneyActivity = true
        error = await adHoc.switchDock(to: alternative, for: .adHoc(current))
        precondition(error == nil)
        precondition(activity.startedJourney?.startDock == replacement && activity.startedJourney?.endDock == end)
        precondition(activity.startedJourney?.activePhase == .start && activity.activeDockID == alternative.id)
        current = adHoc.recentJourneys.first(where: \.isActive)!
        adHoc.markPhase(journeyId: current.id, phase: .end)
        error = await adHoc.switchDock(to: alternative, for: .adHoc(current))
        precondition(error != nil, "A stale start-phase action must not replace the destination")
        current = adHoc.recentJourneys.first(where: \.isActive)!
        let newEnd = BikePoint(id: "new-end", commonName: "New end", lat: 51.61, lon: -0.21)
        error = await adHoc.switchDock(to: newEnd, for: .adHoc(current))
        precondition(error == nil)
        precondition(activity.startedJourney?.startDock == replacement)
        precondition(activity.startedJourney?.endDock.id == newEnd.id)
        precondition(activity.startedJourney?.activePhase == .end && activity.activeDockID == newEnd.id)
        precondition(adHoc.recentJourneys.filter(\.isActive).count == 1)

        let scheduled = ScheduledJourney(
            id: "scheduled", deviceId: nil, startDock: start, endDock: end,
            weekdays: [1, 2, 3, 4, 5], startTime: "07:30", endTime: "09:30",
            timezone: "Europe/London", enabled: true, arrivalSettings: nil,
            activeRun: .init(phase: .end, dockId: end.id, dockName: end.name, startedAt: Date(), runKey: "run"),
            pausedRunKeys: nil, createdAt: nil, updatedAt: nil
        )
        let schedules = ScheduledJourneyService.shared
        schedules.journeys = [scheduled]
        schedules.stopSucceeds = false
        let before = activity.startedJourney
        error = await adHoc.switchDock(to: alternative, for: .scheduled(scheduled))
        precondition(error != nil && activity.startedJourney == before, "Failed scheduled stop must not start another trip")
        schedules.stopSucceeds = true
        error = await adHoc.switchDock(to: alternative, for: .scheduled(scheduled))
        precondition(error == nil && activity.startedJourney?.activePhase == .end)
        precondition(activity.startedJourney?.startDock == start && activity.startedJourney?.endDock == replacement)
        precondition(schedules.journeys[0] == scheduled, "An alternative never edits the recurring route")
        let history = JourneyHistoryService.shared
        let count = history.entries.count
        activity.canStartJourneyActivity = false
        let failedStart = await adHoc.createAndStart(startDock: start, endDock: end)
        precondition(!failedStart && history.entries.count == count, "Failed starts are not trips")
        activity.canStartJourneyActivity = true
        await adHoc.createAndStart(startDock: start, endDock: end)
        let firstRun = adHoc.recentJourneys.first(where: \.isActive)!
        await adHoc.stop(firstRun)
        let firstEntry = history.entries.first { $0.journeyID == firstRun.id }!
        precondition(firstEntry.endedAt != nil)
        await adHoc.start(firstRun)
        precondition(history.entries.count == count + 2, "Repeated routes retain both runs")
        precondition(history.entries.first?.id != firstEntry.id)
        precondition(JourneyHistoryService(defaults: defaults).entries == history.entries, "History survives relaunch")
        let finishedAt = firstEntry.endedAt
        history.finish(journeyID: firstRun.id, at: Date().addingTimeInterval(60))
        precondition(history.entries.first { $0.id == firstEntry.id }?.endedAt == finishedAt, "Completion is idempotent")
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-08-07T12:40:00Z")!
        let label = JourneyHistoryEntry.dateLabel(start: date, end: date.addingTimeInterval(22 * 60))
        precondition(label.contains("Friday, Aug 7th") && label.contains(" – "), "Dates include weekday, ordinal and time range")
        history.merge([firstEntry])
        precondition(history.entries.filter { $0.id == firstEntry.id }.count == 1)
        precondition(zip(history.entries, history.entries.dropFirst()).allSatisfy { $0.startedAt >= $1.startedAt })
        print("Passed journey editing checks: persistence, deduplication, phase preservation, stale actions and stop failures")
    }
}
