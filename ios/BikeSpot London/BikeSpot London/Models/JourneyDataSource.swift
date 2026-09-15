import Foundation

struct JourneyDisplayState {
    var snapshot: JourneySnapshot
    var selection: JourneySelection?
    var availability: JourneyAvailability?
    var location: JourneyLocation?
    var isSimulation = false

    var progress: JourneyProgress? {
        guard let run = selection?.run, run.phase == .riding else { return nil }
        if isSimulation { return run.progress }
        if let location,
           let progress = JourneyProgress.calculate(start: run.startDock.coordinate,
                                                     destination: run.destinationDock.coordinate, location: location) {
            return progress
        }
        return run.progress
    }

    var hasLowActiveDockAvailability: Bool {
        guard let selection, selection.source == .active, let availability else { return false }
        if selection.metric == .allBikes {
            return availability.standardBikes < snapshot.minBikes || availability.eBikes < snapshot.minEBikes
        }
        return selection.metric.count(in: availability) < snapshot.threshold(for: selection.metric)
    }
}

enum JourneyDataSource {
    private struct DockAliases: Decodable { var aliases: [String: String] }
    private struct DockIndex: Codable {
        var docks: [JourneyDock]
        var date: Date
    }

    static func cached(at now: Date = Date()) -> JourneyDisplayState {
        if var simulation = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key), simulation.expiresAt > now {
            simulation.snapshot.applyAvailabilityPreferences()
            let selection = simulation.snapshot.selection(at: now, location: simulation.location, nearby: simulation.nearby)
            return JourneyDisplayState(snapshot: simulation.snapshot, selection: selection,
                                       availability: selection.flatMap { simulation.availability[$0.dock.id] },
                                       location: simulation.location, isSimulation: true)
        }
        var snapshot = JourneyStore.snapshot
        snapshot.applyAvailabilityPreferences()
        let aliases = JourneyStore.read(DockAliases.self, key: "dockPreferences")?.aliases
            ?? JourneyStore.read(DockAliases.self, key: "dockPreferences.v1")?.aliases ?? [:]
        let index = (JourneyStore.read(DockIndex.self, key: "journeyDockIndex")?.docks ?? []).map { value in
            var dock = value
            dock.alias = aliases[dock.id]
            return dock
        }
        snapshot.favorites = snapshot.favorites.map { favorite in
            var dock = favorite
            if dock.coordinate?.isValid != true {
                dock.coordinate = index.first { $0.id == dock.id }?.coordinate
            }
            return dock
        }
        let selection = snapshot.selection(at: now, location: JourneyStore.location, nearby: index)
        return JourneyDisplayState(snapshot: snapshot, selection: selection,
                                   availability: selection.flatMap { JourneyStore.availability(for: $0.dock.id) },
                                   location: JourneyStore.location)
    }

    static func activityState(_ context: JourneyActivityContext, at now: Date = Date(),
                              defaults: UserDefaults = JourneyStore.defaults) -> JourneyDisplayState {
        var snapshot = JourneyStore.read(JourneySnapshot.self, key: JourneyStore.snapshotKey, defaults: defaults) ?? .empty
        var selection: JourneySelection? = context.expiresAt > now ? context.selection : nil
        var availability: JourneyAvailability? = context.availability
        if context.isSimulation,
           let simulation = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key, defaults: defaults),
           simulation.updatedAt >= context.updatedAt {
            snapshot = simulation.snapshot
            selection = simulation.expiresAt > now
                ? snapshot.selection(at: now, location: simulation.location, nearby: simulation.nearby) : nil
            availability = selection.flatMap { simulation.availability[$0.dock.id] }
        }
        if !context.isSimulation, selection != nil {
            if let tappedRun = context.selection.run, snapshot.generatedAt >= context.updatedAt {
                if let run = snapshot.active, run.id == tappedRun.id, run.startedAt == tappedRun.startedAt,
                   run.expiresAt > now {
                    selection = JourneySelection(dock: run.dock,
                        metric: run.phase == .riding ? .spaces : snapshot.bikeMetric, source: .active, run: run)
                } else {
                    selection = nil
                }
                if selection?.dock.id != context.selection.dock.id { availability = nil }
            }
            if let selection,
               let cached = JourneyStore.read(JourneyAvailability.self, key: "journeyAvailability.\(selection.dock.id)", defaults: defaults),
               cached.updatedAt > (availability?.updatedAt ?? .distantPast) { availability = cached }
        }
        snapshot.applyAvailabilityPreferences(from: defaults)
        return JourneyDisplayState(snapshot: snapshot, selection: selection, availability: availability,
            location: context.isSimulation ? nil : JourneyStore.read(JourneyLocation.self, key: JourneyStore.locationKey, defaults: defaults),
            isSimulation: context.isSimulation)
    }

    static func refresh(activityContext: JourneyActivityContext? = nil) async -> JourneyDisplayState {
        var state = activityContext.map { activityState($0) } ?? cached()
        guard !state.isSimulation else { return state }
        // The index supplies coordinates for favourites and supports the no-favourites fallback.
        if activityContext == nil && (state.selection == nil || state.selection?.source == .nearby || state.selection?.source == .favorite) {
            let index = JourneyStore.read(DockIndex.self, key: "journeyDockIndex")
            if index == nil || Date().timeIntervalSince(index!.date) > 86_400 {
                do {
                    let points = try await request([APIJourneyDock].self, path: "/BikePoint")
                    try Task.checkCancellation()
                    let docks = points.filter(\.isAvailable).map(\.dock)
                    if !docks.isEmpty { JourneyStore.write(DockIndex(docks: docks, date: Date()), key: "journeyDockIndex") }
                } catch { /* Keep the previous index when offline. */ }
                state = cached()
            }
        }
        guard !Task.isCancelled, let selection = state.selection else { return state }
        do {
            let point = try await request(APIJourneyDock.self, path: "/BikePoint/\(selection.dock.id)")
            try Task.checkCancellation()
            if point.isAvailable, let availability = point.availability {
                JourneyStore.write(availability, key: "journeyAvailability.\(selection.dock.id)")
            } else {
                JourneyStore.defaults.removeObject(forKey: "journeyAvailability.\(selection.dock.id)")
            }
        } catch { /* A failed request must not turn last-known availability into zero. */ }
        // Re-resolve after suspension: pickup, completion or a newer sync may have changed the dock.
        return activityContext.map { activityState($0) } ?? cached()
    }

    private static func request<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: "https://api.tfl.gov.uk" + path) else { throw URLError(.badURL) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct APIJourneyDock: Decodable {
    struct Property: Decodable { var key: String; var value: String }
    var id: String
    var commonName: String
    var lat: Double
    var lon: Double
    var additionalProperties: [Property]

    private func value(_ key: String) -> String? { additionalProperties.first { $0.key == key }?.value }
    var isAvailable: Bool { value("Installed")?.lowercased() != "false" && value("Locked")?.lowercased() != "true" }
    var dock: JourneyDock {
        JourneyDock(id: id, name: commonName, coordinate: JourneyCoordinate(latitude: lat, longitude: lon))
    }
    var availability: JourneyAvailability? {
        guard let standard = value("NbStandardBikes").flatMap(Int.init),
              let electric = value("NbEBikes").flatMap(Int.init),
              let spaces = value("NbEmptyDocks").flatMap(Int.init),
              standard >= 0, electric >= 0, spaces >= 0 else { return nil }
        return JourneyAvailability(standardBikes: standard, eBikes: electric, spaces: spaces, updatedAt: Date())
    }
}

#if DEBUG
struct JourneyTestSettings: Equatable {
    var phase = "pickup"
    var progress = 25.0
    var spaces = 8
    var bikes = 6
    var eBikes = 4
    var metric: JourneyMetric = .eBikes
    var stale = false
    var elapsedMinutes = 6

    var simulation: JourneySimulation {
        JourneySimulation.make(phase: phase, progress: progress, spaces: spaces, bikes: bikes, eBikes: eBikes,
                               metric: metric, stale: stale, elapsedMinutes: elapsedMinutes)
    }
}
#endif

/// An isolated, expiring fixture. It never starts/stops a real ride or sends arrival events.
/// Receiving and displaying a phone's test must also work in a Release Watch app.
struct JourneySimulation: Codable {
    static let key = "journeySimulation.v1"
    var updatedAt: Date
    var expiresAt: Date
    var snapshot: JourneySnapshot
    var availability: [String: JourneyAvailability]
    var location: JourneyLocation
    var nearby: [JourneyDock]
    var initialElapsedMinutes: Int? = nil

    func alternativeDocks(from primary: JourneyDock, metric: JourneyMetric,
                          customDockIDs: [String]? = nil, limit: Int = 3) -> [JourneyDock] {
        let docksByID = Dictionary(nearby.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates: [JourneyDock]
        if let customDockIDs {
            candidates = customDockIDs.compactMap { docksByID[$0] }
        } else {
            candidates = nearby.sorted { first, second in
                let firstDistance = primary.coordinate.flatMap { origin in first.coordinate.map { origin.distance(to: $0) } } ?? .infinity
                let secondDistance = primary.coordinate.flatMap { origin in second.coordinate.map { origin.distance(to: $0) } } ?? .infinity
                return firstDistance == secondDistance ? first.id < second.id : firstDistance < secondDistance
            }
        }

        var seen = Set<String>()
        return Array(candidates.filter { dock in
            guard dock.id != primary.id, seen.insert(dock.id).inserted,
                  let availability = availability[dock.id] else { return false }
            if customDockIDs != nil { return true }
            if !snapshot.useMinimumThresholds { return metric.count(in: availability) > 0 }
            if metric == .allBikes {
                return availability.standardBikes >= snapshot.minBikes && availability.eBikes >= snapshot.minEBikes
            }
            return metric.count(in: availability) >= snapshot.threshold(for: metric)
        }.prefix(max(0, limit)))
    }
}

#if DEBUG
extension JourneySimulation {
    static func make(phase: String = "pickup", progress: Double = 0, spaces: Int = 8,
                     bikes: Int = 6, eBikes: Int = 4, metric: JourneyMetric = .eBikes, stale: Bool = false,
                     defaults: UserDefaults = JourneyStore.defaults, elapsedMinutes: Int = 6) -> Self {
        let now = Date()
        let start = JourneyDock(id: "journey-demo-start", name: "Warwick Row", alias: "🏠 Home",
                                coordinate: JourneyCoordinate(latitude: 51.496, longitude: -0.143))
        let end = JourneyDock(id: "journey-demo-end", name: "Station", alias: "🚉 Station",
                              coordinate: JourneyCoordinate(latitude: 51.510, longitude: -0.120))
        let nearby = JourneyDock(id: "journey-demo-nearby", name: "Victoria Street",
                                 coordinate: JourneyCoordinate(latitude: 51.497, longitude: -0.142))
        var snapshot = JourneySnapshot.empty
        snapshot.applyAvailabilityPreferences(from: defaults)
        snapshot.generatedAt = now
        snapshot.bikeMetric = metric
        snapshot.favorites = phase == "noFavorites" ? [] : [start, end]
        let fraction = phase == "arrived" ? 1 : phase == "pickup" ? 0 : min(1, max(0, progress / 100))
        let coordinate = JourneyCoordinate(latitude: start.coordinate!.latitude + 0.014 * fraction,
                                            longitude: start.coordinate!.longitude + 0.023 * fraction)
        let location = JourneyLocation(coordinate: coordinate, accuracy: 5, date: now)
        if phase == "pickup" || phase == "riding" || phase == "arrived" {
            snapshot.active = JourneyRun(id: "journey-demo", phase: phase == "pickup" ? .pickup : .riding,
                                         startDock: start, destinationDock: end, startedAt: now,
                                         expiresAt: now.addingTimeInterval(3600),
                                         progress: JourneyProgress.calculate(start: start.coordinate, destination: end.coordinate,
                                                                             location: location, arrived: phase == "arrived"),
                                         rideStartedAt: phase == "pickup" ? nil : now.addingTimeInterval(-Double(elapsedMinutes) * 60))
        } else if phase == "upcoming" || phase == "finished" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/London")!
            let date = now.addingTimeInterval(3600)
            snapshot.schedules = [JourneySchedule(id: "journey-demo-next", startDock: start, destinationDock: end,
                                                 weekdays: [1, 2, 3, 4, 5, 6, 7],
                                                 startTime: String(format: "%02d:%02d", calendar.component(.hour, from: date),
                                                                   calendar.component(.minute, from: date)),
                                                 timezone: "Europe/London", enabled: true, pausedRunKeys: [])]
        }
        if snapshot.active?.phase == .riding,
           let previous = JourneyStore.read(Self.self, key: key, defaults: defaults), previous.expiresAt > now,
           previous.snapshot.active?.phase == .riding, previous.initialElapsedMinutes == elapsedMinutes,
           let previousRideStartedAt = previous.snapshot.active?.rideStartedAt {
            snapshot.active?.rideStartedAt = previousRideStartedAt
        }
        let availabilityDate = stale ? now.addingTimeInterval(-600) : now
        return Self(updatedAt: now, expiresAt: now.addingTimeInterval(1800), snapshot: snapshot,
                    availability: [
                        start.id: JourneyAvailability(standardBikes: bikes, eBikes: eBikes, spaces: 12, updatedAt: availabilityDate),
                        end.id: JourneyAvailability(standardBikes: 5, eBikes: 2, spaces: spaces, updatedAt: availabilityDate),
                        nearby.id: JourneyAvailability(standardBikes: 12, eBikes: 4, spaces: 7, updatedAt: availabilityDate)
                    ], location: location, nearby: [nearby, start, end], initialElapsedMinutes: elapsedMinutes)
    }
}
#endif
