import ActivityKit
import Combine
import CoreLocation
import Foundation

@MainActor
final class JourneySyncService {
    static let shared = JourneySyncService()
    private var observations = Set<AnyCancellable>()
    private var isStarted = false
    private var lastProgressPush = Date.distantPast
    private var progressTask: Task<Void, Never>?
    private var firstSeenActivities: [String: Date] = [:]
    private var endedJourneys = JourneyStore.read([String: Date].self, key: "journeyEndedLocally") ?? [:]

    private var endedActivityIDs = JourneyStore.read([String: Date].self, key: "journeyEndedActivityIDs") ?? [:]

    func markEnded(journeyId: String?, activityId: String? = nil) {
        if let activityId {
            endedActivityIDs = endedActivityIDs.filter { Date().timeIntervalSince($0.value) < 8 * 86_400 }
            endedActivityIDs[activityId] = Date()
            JourneyStore.write(endedActivityIDs, key: "journeyEndedActivityIDs")
        }
        guard let journeyId else { publish(); return }
        endedJourneys = endedJourneys.filter { Date().timeIntervalSince($0.value) < 8 * 86_400 }
        endedJourneys[journeyId] = Date()
        JourneyStore.write(endedJourneys, key: "journeyEndedLocally")
        publish()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let scheduled = ScheduledJourneyService.shared
        let live = LiveActivityService.shared
        Publishers.CombineLatest4(scheduled.$journeys, AdHocJourneyService.shared.$recentJourneys,
                                  live.$activeActivities, live.$activeNotificationSession)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observations)
        FavoritesService.shared.$favorites
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observations)
        publish()
    }

    func publish() {
        guard isStarted else { return }
        let scheduled = ScheduledJourneyService.shared
        let preferences = DockPreferencesService.shared
        let settings = preferences.snapshot.settings
        let old = JourneyStore.snapshot
        let metric: JourneyMetric
        let filter = BikeDataFilter(rawValue: BikeDataFilter.userDefaultsStore.string(forKey: BikeDataFilter.userDefaultsKey) ?? "both") ?? .both
        switch filter {
        case .bikesOnly: metric = .bikes
        case .eBikesOnly: metric = .eBikes
        case .both: metric = .allBikes
        }
        let schedules = scheduled.journeys.map { journey in
            var schedule = JourneySchedule(id: journey.id, startDock: dock(journey.startDock), destinationDock: dock(journey.endDock),
                            weekdays: journey.weekdays, startTime: journey.startTime, timezone: journey.timezone,
                            enabled: journey.enabled, pausedRunKeys: journey.pausedRunKeys ?? [], endTime: journey.endTime)
            if let ended = endedJourneys[journey.id], let occurrence = schedule.nextOccurrence(at: ended),
               occurrence <= ended, let key = schedule.runKey(for: occurrence) {
                // Suppress only an already-open occurrence; an early manual ride must not consume a later schedule.
                schedule.pausedRunKeys.append(key)
            }
            return schedule
        }
        let favorites = FavoritesService.shared.favorites.map { favorite in
            JourneyDock(id: favorite.id, name: favorite.name, alias: preferences.alias(for: favorite.id),
                        coordinate: preferences.snapshot.docks[favorite.id].map {
                            JourneyCoordinate(latitude: $0.latitude, longitude: $0.longitude)
                        })
        }
        var snapshot = JourneySnapshot(generatedAt: old.generatedAt, active: activeRun(previous: old.active),
                                       schedules: schedules, favorites: favorites, holidayMode: scheduled.isHolidayModeEnabled,
                                       bikeMetric: metric, minBikes: settings.minBikes, minEBikes: settings.minEBikes,
                                       minSpaces: settings.minSpaces, useMinimumThresholds: settings.useMinimumThresholds)
        snapshot.siriDestination = old.siriDestination
        snapshot.siriHasAmbiguousJourney = hasAmbiguousJourneys()
        snapshot.siriHasUnresolvedJourney = hasUnresolvedJourney()
        snapshot.siriSchemaVersion = 1
        guard snapshot != old else { return }
        snapshot.generatedAt = max(Date(), old.generatedAt.addingTimeInterval(0.001))
        JourneyStore.write(snapshot, key: JourneyStore.snapshotKey)
        FavoritesService.shared.forceSyncWithWatch()
    }

    /// The phone is the sole writer of Siri defaults. Nil is an explicit, synced clear.
    func setSiriDestination(_ dock: JourneyDock?) {
        var snapshot = JourneyStore.snapshot
        snapshot.siriDestination = dock
        snapshot.siriSchemaVersion = 1
        snapshot.generatedAt = max(Date(), snapshot.generatedAt.addingTimeInterval(0.001))
        JourneyStore.write(snapshot, key: JourneyStore.snapshotKey)
        FavoritesService.shared.forceSyncWithWatch()
    }

    private func hasUnresolvedJourney() -> Bool {
        LiveActivityService.shared.activeActivities.values.contains { activity in
            guard (activity.activityState == .active || activity.activityState == .stale), endedActivityIDs[activity.id] == nil else { return false }
            let attributes = activity.attributes
            guard (activity.content.state.activeJourneyPhase ?? attributes.scheduledJourneyPhase) != nil else { return false }
            let id = attributes.scheduledJourneyId ?? attributes.adHocJourneyId ?? activity.id
            guard (firstSeenActivities[activity.id] ?? Date()) > (endedJourneys[id] ?? .distantPast) else { return false }
            if ScheduledJourneyService.shared.journeys.contains(where: { $0.id == attributes.scheduledJourneyId })
                || AdHocJourneyService.shared.recentJourneys.contains(where: { $0.id == attributes.adHocJourneyId }) { return false }
            return attributes.destinationDockId == nil
        }
    }

    private func hasAmbiguousJourneys() -> Bool {
        let now = Date()
        var ids = Set<String>()
        for journey in ScheduledJourneyService.shared.journeys where journey.activeRun != nil {
            let start = journey.activeRun?.startedAt ?? journey.updatedAt ?? .distantPast
            if start > (endedJourneys[journey.id] ?? .distantPast), now.timeIntervalSince(start) < 8 * 3600 {
                ids.insert(journey.id)
            }
        }
        for journey in AdHocJourneyService.shared.recentJourneys where journey.isActive {
            let start = journey.lastStartedAt ?? journey.createdAt
            if start > (endedJourneys[journey.id] ?? .distantPast), now.timeIntervalSince(start) < 8 * 3600 {
                ids.insert(journey.id)
            }
        }
        for activity in LiveActivityService.shared.activeActivities.values
            where activity.activityState == .active || activity.activityState == .stale {
            guard endedActivityIDs[activity.id] == nil else { continue }
            let attributes = activity.attributes
            guard (activity.content.state.activeJourneyPhase ?? attributes.scheduledJourneyPhase) != nil else { continue }
            let id = attributes.scheduledJourneyId ?? attributes.adHocJourneyId ?? activity.id
            if (firstSeenActivities[activity.id] ?? now) > (endedJourneys[id] ?? .distantPast) { ids.insert(id) }
        }
        return ids.count > 1
    }

    func updateLocation(_ location: CLLocation) {
        guard isStarted else { return }
        let sample = JourneyLocation(coordinate: JourneyCoordinate(latitude: location.coordinate.latitude,
                                                                    longitude: location.coordinate.longitude),
                                     accuracy: location.horizontalAccuracy, date: location.timestamp)
        guard sample.isUsable(at: Date()), sample.date > (JourneyStore.location?.date ?? .distantPast) else { return }
        JourneyStore.write(sample, key: JourneyStore.locationKey)
        guard let run = JourneyStore.snapshot.active, run.phase == .riding, run.expiresAt > Date(),
              let progress = JourneyProgress.calculate(start: run.startDock.coordinate,
                                                       destination: run.destinationDock.coordinate, location: sample),
              Date().timeIntervalSince(lastProgressPush) >= 20 else { return }
        lastProgressPush = Date()
        var snapshot = JourneyStore.snapshot
        snapshot.active?.progress = progress
        snapshot.generatedAt = Date()
        JourneyStore.write(snapshot, key: JourneyStore.snapshotKey)
        FavoritesService.shared.forceSyncWithWatch()
        progressTask?.cancel()
        progressTask = Task {
            await LiveActivityService.shared.updateJourneyProgress(progress, journeyId: run.id)
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    private func dock(_ value: ScheduledJourneyDock) -> JourneyDock {
        JourneyDock(id: value.id, name: value.name, alias: DockPreferencesService.shared.alias(for: value.id),
                    coordinate: JourneyCoordinate(latitude: value.latitude, longitude: value.longitude))
    }

    private func activeRun(previous: JourneyRun?) -> JourneyRun? {
        let scheduled = ScheduledJourneyService.shared.journeys
        let adHoc = AdHocJourneyService.shared.recentJourneys
        let live = LiveActivityService.shared
        let activities = live.activeActivities.values.filter {
            ($0.activityState == .active || $0.activityState == .stale) && endedActivityIDs[$0.id] == nil
        }
        if let activity = activities.first(where: { ($0.content.state.activeJourneyPhase ?? $0.attributes.scheduledJourneyPhase) != nil }) {
            let attributes = activity.attributes
            let state = activity.content.state
            guard let phase = JourneyRun.Phase(rawValue: state.activeJourneyPhase ?? attributes.scheduledJourneyPhase ?? "") else { return nil }
            let journey = scheduled.first { $0.id == attributes.scheduledJourneyId }
            let recent = adHoc.first { $0.id == attributes.adHocJourneyId }
            let start = journey.map { dock($0.startDock) } ?? recent.map { dock($0.startDock) }
                ?? JourneyDock(id: attributes.dockId, name: attributes.dockName, alias: attributes.alias,
                               coordinate: attributes.latitude.flatMap { lat in attributes.longitude.map { JourneyCoordinate(latitude: lat, longitude: $0) } })
            let destination = journey.map { dock($0.endDock) } ?? recent.map { dock($0.endDock) }
                ?? attributes.destinationDockId.map { id in
                    JourneyDock(id: id, name: attributes.destinationDockName ?? id,
                                alias: DockPreferencesService.shared.alias(for: id),
                                coordinate: attributes.destinationLatitude.flatMap { lat in
                                    attributes.destinationLongitude.map { JourneyCoordinate(latitude: lat, longitude: $0) }
                                })
                }
            guard let destination else { return nil }
            let id = attributes.scheduledJourneyId ?? attributes.adHocJourneyId ?? activity.id
            let firstSeen = firstSeenActivities[activity.id] ?? Date()
            firstSeenActivities[activity.id] = firstSeen
            let startedAt = journey?.activeRun?.startedAt ?? recent?.lastStartedAt
                ?? (previous?.id == id ? previous?.startedAt : nil) ?? firstSeen
            guard startedAt > (endedJourneys[id] ?? .distantPast) else { return nil }
            let availability = JourneyAvailability(standardBikes: state.standardBikes, eBikes: state.eBikes,
                                                   spaces: state.emptySpaces,
                                                   updatedAt: state.availabilityUpdatedAtEpochSeconds.map { Date(timeIntervalSince1970: Double($0)) } ?? .distantPast)
            let dockId = phase == .riding ? destination.id : start.id
            if availability.updatedAt > (JourneyStore.availability(for: dockId)?.updatedAt ?? .distantPast) {
                JourneyStore.write(availability, key: "journeyAvailability.\(dockId)")
            }
            let cachedProgress = previous?.id == id && previous?.startedAt == startedAt ? previous?.progress : nil
            let progress = [state.journeyProgress, cachedProgress].compactMap { $0 }
                .max { $0.updatedAtEpochSeconds < $1.updatedAtEpochSeconds }
            return JourneyRun(id: id, phase: phase, startDock: start, destinationDock: destination,
                              startedAt: startedAt, expiresAt: startedAt.addingTimeInterval(8 * 3600),
                              progress: progress,
                              rideStartedAt: state.rideStartedAtEpochSeconds.map { Date(timeIntervalSince1970: $0) }
                                ?? (previous?.id == id && previous?.startedAt == startedAt ? previous?.rideStartedAt : nil))
        }
        // Notification-only journeys and schedules restored from the server still drive complications.
        let session = live.activeNotificationSession
        let candidates: [JourneyRun] = scheduled.compactMap { journey in
            guard let active = journey.activeRun, let phase = JourneyRun.Phase(rawValue: active.phase.rawValue) else { return nil }
            let start = active.startedAt ?? journey.updatedAt ?? (previous?.id == journey.id ? previous?.startedAt : nil) ?? .distantPast
            return JourneyRun(id: journey.id, phase: phase, startDock: dock(journey.startDock), destinationDock: dock(journey.endDock),
                              startedAt: start, expiresAt: start.addingTimeInterval(8 * 3600))
        } + adHoc.compactMap { journey in
            guard let phase = journey.activePhase,
                  let resolved = JourneyRun.Phase(rawValue: phase.rawValue) else { return nil }
            let start = journey.lastStartedAt ?? journey.createdAt
            return JourneyRun(id: journey.id, phase: resolved, startDock: dock(journey.startDock), destinationDock: dock(journey.endDock),
                              startedAt: start, expiresAt: start.addingTimeInterval(8 * 3600))
        }
        var result = candidates.filter { $0.expiresAt > Date() && $0.startedAt > (endedJourneys[$0.id] ?? .distantPast) }
            .max { $0.startedAt < $1.startedAt }
        if let phase = session?.scheduledJourneyPhase,
           session?.scheduledJourneyId == result?.id || session?.adHocJourneyId == result?.id {
            result?.phase = JourneyRun.Phase(rawValue: phase.rawValue) ?? .pickup
        }
        if result?.id == previous?.id && result?.startedAt == previous?.startedAt { result?.progress = previous?.progress }
        return result
    }
}
