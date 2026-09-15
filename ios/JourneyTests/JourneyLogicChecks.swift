import Foundation

/// Standalone checks for the production shared model; no Xcode project build is required.
@main
struct JourneyLogicChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    static func main() throws {
        let now = date("2026-09-14T06:00:00Z") // Monday, 07:00 in London.
        let start = JourneyDock(id: "start", name: "Warwick Row",
                                coordinate: JourneyCoordinate(latitude: 51.49, longitude: -0.14))
        let end = JourneyDock(id: "end", name: "Station", alias: "🚉 Station",
                              coordinate: JourneyCoordinate(latitude: 51.51, longitude: -0.12))
        let nearby = JourneyDock(id: "nearby", name: "Near me",
                                 coordinate: JourneyCoordinate(latitude: 51.49001, longitude: -0.14001))
        let location = JourneyLocation(coordinate: start.coordinate!, accuracy: 5, date: now)
        var schedule = JourneySchedule(id: "weekday", startDock: start, destinationDock: end,
                                       weekdays: [1, 2, 3, 4, 5], startTime: "07:30", timezone: "Europe/London",
                                       enabled: true, pausedRunKeys: [], endTime: "09:30")
        check(schedule.nextOccurrence(at: now) == date("2026-09-14T06:30:00Z"), "Next departure uses schedule timezone")
        check(schedule.nextOccurrence(at: date("2026-09-14T07:00:00Z")) == date("2026-09-14T06:30:00Z"),
              "An open pickup window stays relevant when a phone push is delayed")
        schedule.pausedRunKeys = ["2026-09-14:07:30"]
        check(schedule.nextOccurrence(at: now) == date("2026-09-15T06:30:00Z"), "Skip completed or paused occurrence")
        schedule.pausedRunKeys = []
        check(schedule.nextOccurrence(at: date("2026-09-18T12:00:00Z")) == date("2026-09-21T06:30:00Z"),
              "Next journey can be days away")
        schedule.enabled = false
        check(schedule.nextOccurrence(at: now) == nil, "Disabled schedules are ineligible")
        schedule.enabled = true

        var overnight = schedule
        overnight.weekdays = [1]
        overnight.startTime = "23:30"
        overnight.endTime = "01:30"
        check(overnight.nextOccurrence(at: date("2026-09-14T23:15:00Z")) == date("2026-09-14T22:30:00Z"),
              "Overnight pickup uses previous day's weekday and run key")
        overnight.pausedRunKeys = ["2026-09-14:23:30"]
        check(overnight.nextOccurrence(at: date("2026-09-14T23:15:00Z")) == date("2026-09-21T22:30:00Z"),
              "Overnight completed occurrence is skipped")
        var dst = schedule
        dst.weekdays = [7]
        check(dst.nextOccurrence(at: date("2026-03-28T12:00:00Z")) == date("2026-03-29T06:30:00Z"),
              "Spring daylight saving time retains local departure hour")
        check(dst.nextOccurrence(at: date("2026-10-24T12:00:00Z")) == date("2026-10-25T07:30:00Z"),
              "Autumn daylight saving time retains local departure hour")
        dst.startTime = "01:30"
        dst.endTime = nil
        check(dst.nextOccurrence(at: date("2026-03-28T12:00:00Z")) == date("2026-04-05T00:30:00Z"),
              "A nonexistent local time is skipped rather than silently moved")

        var snapshot = JourneySnapshot.empty
        snapshot.generatedAt = now
        snapshot.schedules = [schedule]
        snapshot.favorites = [end, start]
        snapshot.bikeMetric = .eBikes
        check(snapshot.selection(at: now, location: nil)?.dock.id == start.id, "Schedules work without location")
        check(snapshot.selection(at: now, location: nil)?.metric == .eBikes, "Pickup respects bike preference")
        snapshot.active = JourneyRun(id: "ad-hoc", phase: .pickup, startDock: end, destinationDock: start,
                                     startedAt: now, expiresAt: now.addingTimeInterval(3600))
        check(snapshot.selection(at: now, location: nil)?.dock.id == end.id, "Active ad hoc ride overrides scheduled departure")
        snapshot.active?.phase = .riding
        check(snapshot.selection(at: now, location: nil)?.dock.id == start.id, "Bike pickup switches dock")
        check(snapshot.selection(at: now, location: nil)?.metric == .spaces, "Bike pickup switches metric")
        snapshot.active?.expiresAt = now.addingTimeInterval(-1)
        check(snapshot.selection(at: now, location: nil)?.source == .scheduled, "Expired cached run is not shown forever")
        snapshot.active = nil
        snapshot.holidayMode = true
        check(snapshot.selection(at: now, location: location, nearby: [nearby])?.dock.id == start.id,
              "Holiday mode falls back to nearest favourite even if another dock is closer")
        snapshot.holidayMode = false
        snapshot.schedules = []
        check(snapshot.selection(at: now, location: location)?.source == .favorite, "No schedule falls back to favourite")
        snapshot.favorites = []
        check(snapshot.selection(at: now, location: location, nearby: [end, nearby])?.dock.id == nearby.id,
              "No favourites falls back to nearest dock")
        check(snapshot.selection(at: now, location: nil, nearby: [nearby]) == nil, "No location does not choose an arbitrary dock")
        check(snapshot.selection(at: now.addingTimeInterval(3601), location: location, nearby: [nearby]) == nil,
              "Old location does not silently claim a dock is nearest")

        let halfway = JourneyLocation(coordinate: JourneyCoordinate(latitude: 51.50, longitude: -0.13), accuracy: 10, date: now)
        let progress = JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: halfway, now: now)!
        check((49...50).contains(progress.percent), "Direct distance reports approximately halfway")
        check(progress.remainingMeters > 1000, "Progress includes distance remaining in metres")
        check(JourneyProgress(percent: 25, remainingMeters: 1000, updatedAtEpochSeconds: 0).fractionComplete == 0.25,
              "A quarter journey fills a quarter of the progress bar")
        check(JourneyProgress(percent: -1, remainingMeters: 1000, updatedAtEpochSeconds: 0).fractionComplete == 0,
              "Progress bar never underflows")
        check(JourneyProgress(percent: 101, remainingMeters: 0, updatedAtEpochSeconds: 0).fractionComplete == 1,
              "Progress bar never overflows")
        var card = JourneySmartStackPresentation(phase: .riding, progress: progress, now: now)
        check(card.stage == .riding, "Mid-ride Smart Stack identifies the riding stage")
        card.progress = JourneyProgress(percent: 85, remainingMeters: 500, updatedAtEpochSeconds: now.timeIntervalSince1970)
        check(card.stage == .approaching, "Smart Stack identifies approach within 500 metres")
        card.progress?.remainingMeters = 501
        check(card.stage == .riding, "Outside the approach threshold remains in the riding stage")
        card.progress?.remainingMeters = 100
        card.progress?.updatedAtEpochSeconds = now.addingTimeInterval(-121).timeIntervalSince1970
        check(card.stage == .riding, "Stale location does not claim the rider is approaching")
        card.progress?.updatedAtEpochSeconds = now.timeIntervalSince1970
        card.phase = .pickup
        check(card.stage == .collection, "Collection shows bike availability even when close to the destination")
        var distanceProgress = JourneyProgress(percent: 25, remainingMeters: 999, updatedAtEpochSeconds: now.timeIntervalSince1970)
        check(distanceProgress.remainingDistanceText == "999m", "Watch journey uses metres below the Favourites threshold")
        distanceProgress.remainingMeters = 1000
        check(distanceProgress.remainingDistanceText == "0.6mi", "Watch journey switches to miles at the Favourites threshold")
        distanceProgress.remainingMeters = 1609.344
        check(distanceProgress.remainingDistanceText == "1.0mi", "Watch journey rounds miles to one decimal place")
        distanceProgress.remainingMeters = 0
        check(distanceProgress.remainingDistanceText == "0m", "Arrival distance is zero metres")
        distanceProgress.remainingMeters = -1
        check(distanceProgress.remainingDistanceText == "—", "Negative distance is unavailable")
        distanceProgress.remainingMeters = .infinity
        check(distanceProgress.remainingDistanceText == "—", "Non-finite distance is unavailable")
        let atDestination = JourneyLocation(coordinate: end.coordinate!, accuracy: 5, date: now)
        check(JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: atDestination, now: now)?.percent == 99,
              "Proximity alone never claims confirmed arrival")
        check(JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: atDestination, now: now, arrived: true)?.percent == 100,
              "Confirmed arrival shows 100 percent")
        check(JourneyProgress.calculate(start: start.coordinate, destination: start.coordinate, location: halfway, now: now) == nil,
              "Zero-length route is not divided by zero")
        check(JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: halfway, now: now.addingTimeInterval(121)) == nil,
              "Old GPS fix is rejected")
        var inaccurate = halfway
        inaccurate.accuracy = 500
        check(JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: inaccurate, now: now) == nil,
              "Imprecise GPS fix is rejected")
        check(!progress.isFresh(at: now.addingTimeInterval(121)), "Old progress stops being presented as live")
        let away = JourneyLocation(coordinate: JourneyCoordinate(latitude: 51.48, longitude: -0.15), accuracy: 5, date: now)
        check(JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate, location: away, now: now)?.percent == 0,
              "A detour cannot create negative progress")

        check(start.identifier == "WR", "Dock code has at most two initials")
        check(end.identifier == "🚉", "Prefer dock emoji")
        var emoji = end
        emoji.alias = "🚴🏽‍♀️ Work"
        check(emoji.identifier == "🚴🏽‍♀️", "Joined emoji stays intact")
        emoji.alias = "🇬🇧 London"
        check(emoji.identifier == "🇬🇧", "Flag stays intact")
        let counts = JourneyAvailability(standardBikes: 8, eBikes: 3, spaces: 0, updatedAt: now)
        check(JourneyMetric.eBikes.count(in: counts) == 3, "E-bike count excludes standard bikes")
        check(JourneyMetric.spaces.count(in: counts) == 0, "A genuine zero remains available data")
        check(JourneyMetric.spaces.label(count: 1) == "space", "Singular label")

        let mixedDock = JourneyAvailability(standardBikes: 6, eBikes: 4, spaces: 12, updatedAt: now)
        let bikesChart = mixedDock.filtered(for: .bikes)
        let electricChart = mixedDock.filtered(for: .eBikes)
        check(bikesChart.standardBikes == 6 && bikesChart.eBikes == 0 && bikesChart.spaces == 12,
              "Bikes-only collection chart excludes the e-bike segment")
        check(electricChart.standardBikes == 0 && electricChart.eBikes == 4 && electricChart.spaces == 12,
              "E-bikes-only collection chart excludes the standard bike segment")
        check(mixedDock.filtered(for: .allBikes) == mixedDock && JourneyMetric.allBikes.count(in: mixedDock) == 10,
              "Both preference keeps both segments and the combined count")
        check(mixedDock.filtered(for: .spaces) == mixedDock,
              "Destination-space charts keep the complete dock composition")
        check(bikesChart.updatedAt == now && electricChart.updatedAt == now,
              "Filtering bike types preserves availability freshness")
        let noPreferredBikes = JourneyAvailability(standardBikes: 0, eBikes: 4, spaces: 0, updatedAt: now).filtered(for: .bikes)
        check(noPreferredBikes.total == 0 && JourneyMetric.bikes.count(in: noPreferredBikes) == 0,
              "An unselected bike type cannot fill an empty preferred-bike chart")

        let suiteName = "JourneyLogicChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(5, forKey: "alternativeDocksMinSpaces")
        defaults.set(7, forKey: "alternativeDocksMinBikes")
        defaults.set(6, forKey: "alternativeDocksMinEBikes")
        var preferences = JourneySnapshot.empty
        preferences.applyAvailabilityPreferences(from: defaults)
        check(preferences.threshold(for: .spaces) == 5, "Spaces labels use the saved minimum")
        check(4 < preferences.threshold(for: .spaces), "Four spaces is low availability below a minimum of five")
        check(preferences.threshold(for: .bikes) == 7 && preferences.threshold(for: .eBikes) == 6,
              "Bike and e-bike labels use their separate saved minimums")
        defaults.set(false, forKey: "alternativeDocksUseMinimumThresholds")
        preferences.applyAvailabilityPreferences(from: defaults)
        check(!preferences.useMinimumThresholds, "Journey preferences read a saved disabled minimum-filter setting")
        check(preferences.threshold(for: .spaces) == 5,
              "Disabling alternative-dock filtering does not disable label threshold colours")
        check(preferences.threshold(for: .allBikes) == 13, "Combined bikes use the same threshold sum as existing labels")
        defaults.removeObject(forKey: "alternativeDocksUseMinimumThresholds")
        preferences.applyAvailabilityPreferences(from: defaults)
        check(!preferences.useMinimumThresholds, "Missing local settings preserve the synced minimum-filter preference")
        defaults.set(true, forKey: "alternativeDocksUseMinimumThresholds")
        preferences.applyAvailabilityPreferences(from: defaults)
        check(preferences.useMinimumThresholds, "Re-enabling minimum filtering updates the journey snapshot")
        let fresh = try JSONEncoder().encode(snapshot)
        check(JourneyStore.receive(fresh, defaults: defaults), "Receive valid snapshot")
        snapshot.generatedAt = now.addingTimeInterval(-1)
        let older = try JSONEncoder().encode(snapshot)
        check(!JourneyStore.receive(older, defaults: defaults), "Queued older phone sync cannot overwrite new state")
        check(!JourneyStore.receive(Data("invalid".utf8), defaults: defaults), "Malformed sync is ignored")
        let handoffRun = JourneyRun(id: "handoff", phase: .riding, startDock: start, destinationDock: end,
                                    startedAt: now, expiresAt: now.addingTimeInterval(3600))
        var handoff = JourneyActivityHandoff(run: handoffRun, availability: counts, bikeMetric: .spaces)
        check(handoff.apply(at: now, defaults: defaults), "Live Activity tap supplies journey before Watch sync")
        check(JourneyStore.read(JourneySnapshot.self, key: JourneyStore.snapshotKey, defaults: defaults)?.active?.destinationDock.id == end.id,
              "Cold-launch handoff uses destination, not an unrelated nearest dock")
        handoff.availability.updatedAt = now.addingTimeInterval(-1)
        check(!handoff.apply(at: now, defaults: defaults), "Old tapped activity cannot replace newer journey state")
        handoff.availability.updatedAt = now.addingTimeInterval(1000)
        check(!handoff.apply(at: now, defaults: defaults), "Future-dated link cannot block subsequent genuine sync")

        let tappedSelection = JourneySelection(dock: end, metric: .spaces, source: .active, run: handoffRun)
        let tappedContext = JourneyActivityContext(selection: tappedSelection, availability: counts, updatedAt: now,
                                                   expiresAt: now.addingTimeInterval(1800), isSimulation: true)
        var link = URLComponents(string: "myborisbikes://journey")!
        link.queryItems = [tappedContext.queryItem!]
        let decodedContext = JourneyActivityContext.from(link.url!, at: now)!
        check(decodedContext == tappedContext, "Tap link carries the exact dock, phase and counts")
        let cacheBeforeTap = defaults.data(forKey: JourneyStore.snapshotKey)
        let tappedState = JourneyDataSource.activityState(decodedContext, at: now, defaults: defaults)
        check(tappedState.selection?.dock.id == end.id && tappedState.selection?.metric == .spaces,
              "A test tap opens destination spaces without a synced test fixture")
        check(tappedState.selection?.run?.phase == .riding && tappedState.isSimulation,
              "A test tap immediately selects the full-screen riding page in all build configurations")
        check(defaults.data(forKey: JourneyStore.snapshotKey) == cacheBeforeTap,
              "Opening a test card never overwrites the real journey")
        check(JourneyDataSource.activityState(tappedContext, at: now.addingTimeInterval(1801), defaults: defaults).selection == nil,
              "An expired card reports ended instead of opening an unrelated nearby dock")
        link.queryItems = [URLQueryItem(name: "activity", value: "invalid")]
        check(JourneyActivityContext.from(link.url!, at: now) == nil, "Malformed activity context is rejected")

        // Exercise the phone-to-Watch fixture contract without DEBUG. The Watch's
        // normal launch scheme is Release, even when the phone runs its test UI.
        var wireSnapshot = JourneySnapshot.empty
        wireSnapshot.generatedAt = now
        wireSnapshot.bikeMetric = .bikes
        wireSnapshot.minBikes = 5
        wireSnapshot.minEBikes = 2
        wireSnapshot.minSpaces = 5
        wireSnapshot.useMinimumThresholds = true
        wireSnapshot.active = JourneyRun(id: "test-wire", phase: .pickup, startDock: start, destinationDock: end,
                                         startedAt: now, expiresAt: now.addingTimeInterval(3600))
        var wireFixture = JourneySimulation(updatedAt: now, expiresAt: now.addingTimeInterval(1800),
            snapshot: wireSnapshot, availability: [
                start.id: JourneyAvailability(standardBikes: 6, eBikes: 4, spaces: 12, updatedAt: now),
                end.id: JourneyAvailability(standardBikes: 5, eBikes: 2, spaces: 3, updatedAt: now),
                nearby.id: JourneyAvailability(standardBikes: 12, eBikes: 4, spaces: 7, updatedAt: now)
            ], location: location, nearby: [end, start, nearby])
        let originalWireData = try JSONEncoder().encode(wireFixture)
        let collectionContext = JourneyActivityContext(selection: wireSnapshot.selection(at: now, location: location)!,
            availability: wireFixture.availability[start.id]!, updatedAt: now,
            expiresAt: wireFixture.expiresAt, isSimulation: true)
        check(JourneyStore.receiveSimulation(originalWireData, defaults: defaults),
              "Every Watch build accepts a phone test fixture")
        check(JourneyDataSource.activityState(collectionContext, at: now, defaults: defaults).availability?.standardBikes == 6,
              "An opened test card initially displays six bikes")
        wireFixture.updatedAt = now.addingTimeInterval(1)
        wireFixture.availability[start.id]?.standardBikes = 3
        let threeBikeData = try JSONEncoder().encode(wireFixture)
        check(JourneyStore.receiveSimulation(threeBikeData, defaults: defaults),
              "A manual or automatic sync accepts newer test availability")
        let threeBikeState = JourneyDataSource.activityState(collectionContext, at: now, defaults: defaults)
        check(threeBikeState.availability?.standardBikes == 3 && threeBikeState.hasLowActiveDockAvailability,
              "The already-open six-bike card changes to three bikes and compact alternatives")
        check(!JourneyStore.receiveSimulation(originalWireData, defaults: defaults),
              "A queued older sync cannot restore six bikes")
        check(wireFixture.alternativeDocks(from: start, metric: .bikes).map(\.id) == [nearby.id, end.id],
              "Collection alternatives exclude the start dock and sort qualifying docks nearest first")
        check(wireFixture.alternativeDocks(from: start, metric: .eBikes, limit: 1).map(\.id) == [nearby.id],
              "E-bike alternatives use the preferred metric and display limit")
        check(wireFixture.alternativeDocks(from: end, metric: .spaces).map(\.id) == [nearby.id, start.id],
              "Riding alternatives use destination proximity and available spaces")
        check(wireFixture.alternativeDocks(from: start, metric: .spaces,
              customDockIDs: [end.id, start.id, nearby.id, end.id]).map(\.id) == [end.id, nearby.id],
              "Custom alternatives retain saved order and low counts, excluding the primary and duplicates")
        check(wireFixture.alternativeDocks(from: start, metric: .bikes, customDockIDs: []).isEmpty,
              "An explicitly empty custom list does not fall back to nearby docks")
        var bothBikeTypes = threeBikeState
        bothBikeTypes.selection?.metric = .allBikes
        bothBikeTypes.availability?.standardBikes = 30
        bothBikeTypes.availability?.eBikes = 0
        check(bothBikeTypes.hasLowActiveDockAvailability,
              "Plentiful standard bikes do not hide an e-bike shortage when both types are preferred")
        bothBikeTypes.availability?.standardBikes = 0
        bothBikeTypes.availability?.eBikes = 30
        check(bothBikeTypes.hasLowActiveDockAvailability,
              "Plentiful e-bikes do not hide a standard-bike shortage when both types are preferred")
        bothBikeTypes.snapshot.useMinimumThresholds = false
        check(bothBikeTypes.hasLowActiveDockAvailability,
              "Disabling alternative filtering still highlights a shortage at the active dock")
        bothBikeTypes.availability?.standardBikes = bothBikeTypes.snapshot.minBikes
        bothBikeTypes.availability?.eBikes = bothBikeTypes.snapshot.minEBikes
        check(!bothBikeTypes.hasLowActiveDockAvailability,
              "Meeting each preferred bike threshold restores the full journey display")
        var noMinimumFixture = wireFixture
        noMinimumFixture.snapshot.useMinimumThresholds = false
        noMinimumFixture.availability[nearby.id]?.standardBikes = 1
        noMinimumFixture.availability[end.id]?.standardBikes = 0
        check(noMinimumFixture.alternativeDocks(from: start, metric: .bikes).map(\.id) == [nearby.id],
              "Disabling minimum filtering accepts one bike but excludes empty docks")

        wireFixture.updatedAt = now.addingTimeInterval(2)
        wireFixture.snapshot.bikeMetric = .eBikes
        wireFixture.availability[start.id]?.eBikes = 1
        let electricData = try JSONEncoder().encode(wireFixture)
        check(JourneyStore.receiveSimulation(electricData, defaults: defaults),
              "A test preference change arrives through the same receive path")
        let electricState = JourneyDataSource.activityState(collectionContext, at: now, defaults: defaults)
        check(electricState.selection?.metric == .eBikes && electricState.availability?.eBikes == 1,
              "The open card switches bike preference without another tap")
        wireFixture.updatedAt = now.addingTimeInterval(3)
        wireFixture.snapshot.active?.phase = .riding
        let ridingData = try JSONEncoder().encode(wireFixture)
        check(JourneyStore.receiveSimulation(ridingData, defaults: defaults),
              "A riding-stage edit arrives through the same receive path")
        let ridingState = JourneyDataSource.activityState(collectionContext, at: now, defaults: defaults)
        check(ridingState.selection?.dock.id == end.id && ridingState.selection?.metric == .spaces &&
              ridingState.availability?.spaces == 3 && ridingState.hasLowActiveDockAvailability,
              "An open collection screen transitions to three destination spaces and compact alternatives")
        wireFixture.updatedAt = now.addingTimeInterval(4)
        wireFixture.expiresAt = .distantPast
        let stoppedData = try JSONEncoder().encode(wireFixture)
        check(JourneyStore.receiveSimulation(stoppedData, defaults: defaults),
              "Every Watch build accepts a stopped-test tombstone")
        check(!JourneyStore.receiveSimulation(originalWireData, defaults: defaults) &&
              JourneyDataSource.activityState(collectionContext, at: now, defaults: defaults).selection == nil,
              "Stopping the test clears the open activity and older messages cannot restart it")
        check(!JourneyStore.receiveSimulation(Data("invalid".utf8), defaults: defaults),
              "Malformed test sync is ignored")
        check(defaults.data(forKey: JourneyStore.snapshotKey) == cacheBeforeTap,
              "Test updates and stop messages preserve the real journey cache")

        var realContext = tappedContext
        realContext.isSimulation = false
        var realSnapshot = JourneySnapshot.empty
        realSnapshot.generatedAt = now.addingTimeInterval(-1)
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        check(JourneyDataSource.activityState(realContext, at: now, defaults: defaults).selection == tappedSelection,
              "An older empty snapshot cannot erase a newer tapped real journey")

        realSnapshot.generatedAt = now.addingTimeInterval(1)
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        let endedRealState = JourneyDataSource.activityState(realContext, at: now, defaults: defaults)
        check(endedRealState.selection == nil && endedRealState.availability == nil,
              "A newer completion sync clears the open real journey and its old availability")

        realSnapshot.active = handoffRun
        realSnapshot.active?.id = "replacement-journey"
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        check(JourneyDataSource.activityState(realContext, at: now, defaults: defaults).selection == nil,
              "Starting a different journey ends the old tapped activity context")
        realSnapshot.active?.id = handoffRun.id
        realSnapshot.active?.startedAt = now.addingTimeInterval(1)
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        check(JourneyDataSource.activityState(realContext, at: now, defaults: defaults).selection == nil,
              "A new run of the same saved journey does not revive its previous activity")

        realSnapshot.active = handoffRun
        realSnapshot.active?.phase = .pickup
        realSnapshot.bikeMetric = .eBikes
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        let changedRealState = JourneyDataSource.activityState(realContext, at: now, defaults: defaults)
        check(changedRealState.selection?.dock.id == start.id && changedRealState.selection?.metric == .eBikes &&
              changedRealState.availability == nil,
              "A newer same-run state changes the dock and metric without reusing the old dock's counts")
        realSnapshot.active?.expiresAt = now.addingTimeInterval(-1)
        JourneyStore.write(realSnapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        check(JourneyDataSource.activityState(realContext, at: now, defaults: defaults).selection == nil,
              "An expired real run ends the tapped activity before the tap itself expires")

        realContext.selection = JourneySelection(dock: end, metric: .bikes, source: .favorite)
        check(JourneyDataSource.activityState(realContext, at: now, defaults: defaults).selection == realContext.selection,
              "An unrelated active journey does not invalidate a favourite-dock card")
        defaults.set(cacheBeforeTap, forKey: JourneyStore.snapshotKey)

#if DEBUG
        for metric in [JourneyMetric.bikes, .eBikes, .allBikes] {
            let collection = JourneySimulation.make(phase: "pickup", bikes: 6, eBikes: 4, metric: metric, defaults: defaults)
            let selection = collection.snapshot.selection(location: collection.location)!
            let availability = collection.availability[selection.dock.id]!
            check(selection.metric == metric && metric.count(in: availability) == (metric == .bikes ? 6 : metric == .eBikes ? 4 : 10),
                  "Collection simulation preserves the selected bike preference and count")
            let context = JourneyActivityContext(selection: selection, availability: availability, updatedAt: collection.updatedAt,
                                                  expiresAt: collection.expiresAt, isSimulation: true)
            var url = URLComponents(string: "myborisbikes://journey")!
            url.queryItems = [context.queryItem!]
            check(JourneyActivityContext.from(url.url!)?.selection.metric == metric,
                  "The Watch activity tap preserves the test bike preference")
        }
        var staleTest = JourneySimulation.make(phase: "pickup", bikes: 6, eBikes: 4, metric: .eBikes, defaults: defaults)
        staleTest.updatedAt = Date().addingTimeInterval(-2)
        let staleSelection = staleTest.snapshot.selection(location: staleTest.location)!
        let staleContext = JourneyActivityContext(
            selection: staleSelection,
            availability: staleTest.availability[staleSelection.dock.id]!,
            updatedAt: staleTest.updatedAt,
            expiresAt: staleTest.expiresAt,
            isSimulation: true
        )
        let refreshedTest = JourneySimulation.make(phase: "pickup", bikes: 7, eBikes: 4, metric: .bikes, defaults: defaults)
        JourneyStore.write(refreshedTest, key: JourneySimulation.key, defaults: defaults)
        let refreshedState = JourneyDataSource.activityState(staleContext, defaults: defaults)
        check(refreshedState.selection?.metric == .bikes && refreshedState.availability?.standardBikes == 7,
              "A newer Watch sync replaces the tapped test card's stale preference and count")

        let lowSpacesTest = JourneySimulation.make(phase: "riding", spaces: 3, defaults: defaults)
        JourneyStore.write(lowSpacesTest, key: JourneySimulation.key, defaults: defaults)
        let lowSpacesSelection = lowSpacesTest.snapshot.selection(location: lowSpacesTest.location)!
        let lowSpacesContext = JourneyActivityContext(
            selection: lowSpacesSelection,
            availability: lowSpacesTest.availability[lowSpacesSelection.dock.id]!,
            updatedAt: lowSpacesTest.updatedAt,
            expiresAt: lowSpacesTest.expiresAt,
            isSimulation: true
        )
        let lowSpacesState = JourneyDataSource.activityState(lowSpacesContext, defaults: defaults)
        check(lowSpacesState.hasLowActiveDockAvailability,
              "A test journey below the space threshold uses the compact alternatives view")

        let preferredTest = JourneySimulation.make(phase: "riding", spaces: 4, defaults: defaults)
        check(preferredTest.snapshot.threshold(for: .spaces) == 5,
              "Test journeys inherit the user's space threshold")
        check(preferredTest.snapshot.threshold(for: .bikes) == 7 && preferredTest.snapshot.threshold(for: .eBikes) == 6,
              "Test journeys inherit both bike thresholds")
        JourneyStore.write(preferredTest, key: JourneySimulation.key, defaults: defaults)
        let updatedTest = JourneySimulation.make(phase: "riding", progress: 90, spaces: 0, defaults: defaults)
        check(updatedTest.snapshot.active?.rideStartedAt == preferredTest.snapshot.active?.rideStartedAt,
              "Changing test position or availability does not reset elapsed ride time")
        let adjustedTest = JourneySimulation.make(phase: "riding", defaults: defaults, elapsedMinutes: 30)
        check(adjustedTest.snapshot.active?.rideStartedAt != preferredTest.snapshot.active?.rideStartedAt,
              "Explicit test ride-time control adjusts the timer")
        let simulated = JourneySimulation.make(phase: "riding", progress: 50, spaces: 0)
        check(simulated.snapshot.active?.phase == .riding, "Simulator uses production riding state")
        let selected = simulated.snapshot.selection(location: simulated.location)!
        check(selected.metric == .spaces && simulated.availability[selected.dock.id]?.spaces == 0, "Simulator tests zero destination spaces")
        let finished = JourneySimulation.make(phase: "finished")
        check(finished.snapshot.active == nil && finished.snapshot.selection(location: finished.location)?.source == .scheduled,
              "Finishing a test switches to the next schedule")
        let arrived = JourneySimulation.make(phase: "arrived")
        check(arrived.snapshot.active?.progress?.percent == 100, "Simulator can test confirmed arrival")
        check(simulated.expiresAt.timeIntervalSince(simulated.updatedAt) == 1800, "Test override expires")
#endif
        print("Passed \(checks) Journey logic checks")
    }
}
