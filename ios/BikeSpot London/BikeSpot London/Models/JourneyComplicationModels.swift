import Foundation

// Shared by iPhone, Watch, complications and the Live Activity extension.
struct JourneyCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0)
    }

    func distance(to other: Self) -> Double {
        let radians = Double.pi / 180
        let a = pow(sin((other.latitude - latitude) * radians / 2), 2)
            + cos(latitude * radians) * cos(other.latitude * radians)
            * pow(sin((other.longitude - longitude) * radians / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
    }
}

struct JourneyLocation: Codable, Equatable, Sendable {
    var coordinate: JourneyCoordinate
    var accuracy: Double
    var date: Date

    func isUsable(at now: Date, maximumAge: TimeInterval = 120) -> Bool {
        coordinate.isValid && accuracy >= 0 && accuracy <= 100
            && now.timeIntervalSince(date) >= -10 && now.timeIntervalSince(date) <= maximumAge
    }
}

struct JourneyProgress: Codable, Hashable, Sendable {
    var percent: Int
    var remainingMeters: Double
    var updatedAtEpochSeconds: Double

    var fractionComplete: Double { min(1, max(0, Double(percent) / 100)) }

    /// Matches the Watch Favourites distance indicator's units, threshold and rounding.
    var remainingDistanceText: String {
        guard remainingMeters.isFinite, remainingMeters >= 0 else { return "—" }
        return remainingMeters < 1000
            ? String(format: "%.0fm", remainingMeters)
            : String(format: "%.1fmi", remainingMeters * 0.000621371)
    }

    static func calculate(start: JourneyCoordinate?, destination: JourneyCoordinate?, location: JourneyLocation,
                          now: Date = Date(), arrived: Bool = false) -> Self? {
        guard let start, let destination, start.isValid, destination.isValid,
              location.isUsable(at: now) else { return nil }
        let total = start.distance(to: destination)
        guard total >= 50 else { return nil }
        let remaining = location.coordinate.distance(to: destination)
        return Self(percent: arrived ? 100 : Int(min(99, max(0, (1 - remaining / total) * 100))),
                    remainingMeters: remaining, updatedAtEpochSeconds: location.date.timeIntervalSince1970)
    }

    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - updatedAtEpochSeconds
        return age >= -10 && age <= 120
    }
}

struct JourneyDock: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var alias: String?
    var coordinate: JourneyCoordinate?

    var displayName: String {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }

    var identifier: String {
        // Keep complete emoji graphemes, including flags, skin tones and joined families.
        if let emoji = displayName.first(where: { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }
        }) { return String(emoji) }
        let words = displayName.split { !$0.isLetter && !$0.isNumber }
        return String(words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined().prefix(2))
    }
}

enum JourneyMetric: String, Codable, Sendable {
    case bikes, eBikes, allBikes, spaces

    func count(in availability: JourneyAvailability) -> Int {
        switch self {
        case .bikes: return availability.standardBikes
        case .eBikes: return availability.eBikes
        case .allBikes: return availability.standardBikes + availability.eBikes
        case .spaces: return availability.spaces
        }
    }

    func label(count: Int) -> String {
        switch self {
        case .bikes, .allBikes: return count == 1 ? "bike" : "bikes"
        case .eBikes: return count == 1 ? "e-bike" : "e-bikes"
        case .spaces: return count == 1 ? "space" : "spaces"
        }
    }
}

struct JourneyAvailability: Codable, Hashable, Sendable {
    var standardBikes: Int
    var eBikes: Int
    var spaces: Int
    var updatedAt: Date
    var total: Int { standardBikes + eBikes + spaces }

    /// Match the existing availability charts: omit unselected bike types from the ring.
    func filtered(for metric: JourneyMetric) -> Self {
        Self(standardBikes: metric == .eBikes ? 0 : standardBikes,
             eBikes: metric == .bikes ? 0 : eBikes, spaces: spaces, updatedAt: updatedAt)
    }
    func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > 120 }
}

struct JourneyRun: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case pickup = "start", riding = "end" }
    var id: String
    var phase: Phase
    var startDock: JourneyDock
    var destinationDock: JourneyDock
    var startedAt: Date
    var expiresAt: Date
    var progress: JourneyProgress?
    var rideStartedAt: Date? = nil
    var dock: JourneyDock { phase == .riding ? destinationDock : startDock }
}

struct JourneySmartStackPresentation {
    enum Stage { case collection, riding, approaching }
    var phase: JourneyRun.Phase
    var progress: JourneyProgress?
    var now = Date()

    var stage: Stage {
        guard phase == .riding else { return .collection }
        guard let progress, progress.isFresh(at: now), progress.remainingMeters.isFinite,
              progress.remainingMeters >= 0, progress.remainingMeters <= 500 else { return .riding }
        return .approaching
    }
}

/// A Live Activity tap can reach the Watch before the companion's background sync.
struct JourneyActivityHandoff: Codable {
    var run: JourneyRun
    var availability: JourneyAvailability
    var bikeMetric: JourneyMetric

    var activityContext: JourneyActivityContext {
        JourneyActivityContext(selection: JourneySelection(dock: run.dock,
            metric: run.phase == .riding ? .spaces : bikeMetric, source: .active, run: run),
            availability: availability, updatedAt: availability.updatedAt, expiresAt: run.expiresAt)
    }

    @discardableResult
    func apply(at now: Date = Date(), defaults: UserDefaults = JourneyStore.defaults) -> Bool {
        var snapshot = JourneyStore.read(JourneySnapshot.self, key: JourneyStore.snapshotKey, defaults: defaults) ?? .empty
        guard run.expiresAt > now, run.expiresAt <= availability.updatedAt.addingTimeInterval(8 * 3600),
              availability.updatedAt <= now.addingTimeInterval(10), availability.updatedAt >= snapshot.generatedAt,
              availability.standardBikes >= 0, availability.eBikes >= 0, availability.spaces >= 0 else { return false }
        snapshot.active = run
        snapshot.bikeMetric = bikeMetric == .spaces ? snapshot.bikeMetric : bikeMetric
        snapshot.generatedAt = availability.updatedAt
        JourneyStore.write(snapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        let key = "journeyAvailability.\(run.dock.id)"
        if availability.updatedAt > (JourneyStore.read(JourneyAvailability.self, key: key, defaults: defaults)?.updatedAt ?? .distantPast) {
            JourneyStore.write(availability, key: key, defaults: defaults)
        }
        return true
    }
}

/// Carries the tapped card's exact selection, independently of companion sync or build configuration.
/// Test contexts are display-only and never replace the real journey cache.
struct JourneyActivityContext: Codable, Hashable, Sendable {
    var selection: JourneySelection
    var availability: JourneyAvailability
    var updatedAt: Date
    var expiresAt: Date
    var isSimulation = false

    var queryItem: URLQueryItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return URLQueryItem(name: "activity", value: data.base64EncodedString())
    }

    static func from(_ url: URL, at now: Date = Date()) -> Self? {
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "activity" })?.value,
              encoded.utf8.count <= 16_384, let data = Data(base64Encoded: encoded),
              let context = try? JSONDecoder().decode(Self.self, from: data),
              context.updatedAt <= now.addingTimeInterval(10), context.expiresAt >= context.updatedAt,
              context.expiresAt <= context.updatedAt.addingTimeInterval(8 * 3600),
              context.availability.standardBikes >= 0, context.availability.eBikes >= 0,
              context.availability.spaces >= 0 else { return nil }
        return context
    }
}

struct JourneySchedule: Codable, Equatable, Sendable {
    var id: String
    var startDock: JourneyDock
    var destinationDock: JourneyDock
    var weekdays: [Int] // ISO weekday: Monday = 1.
    var startTime: String
    var timezone: String
    var enabled: Bool
    var pausedRunKeys: [String]
    var endTime: String? = nil

    func runKey(for date: Date) -> String? {
        guard let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d:%@", day.year!, day.month!, day.day!, startTime)
    }

    func nextOccurrence(at now: Date) -> Date? {
        guard enabled, !weekdays.isEmpty, let zone = TimeZone(identifier: timezone) else { return nil }
        let parts = startTime.split(separator: ":").compactMap { Int($0) }
        guard startTime.count == 5, parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        // Each paused key can exclude at most one more day; include a complete following week.
        for offset in -1...(8 + pausedRunKeys.count) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains((calendar.component(.weekday, from: day) + 5) % 7 + 1),
                  let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day,
                                           matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
                  calendar.isDate(date, inSameDayAs: day) else { continue }
            if date < now {
                // A still-open pickup window remains relevant while the phone's start push is delayed.
                let end = endTime?.split(separator: ":").compactMap { Int($0) } ?? []
                guard end.count == 2, (0...23).contains(end[0]), (0...59).contains(end[1]) else { continue }
                let overnight = end[0] * 60 + end[1] <= parts[0] * 60 + parts[1]
                guard let endDay = calendar.date(byAdding: .day, value: overnight ? 1 : 0, to: day),
                      let endDate = calendar.date(bySettingHour: end[0], minute: end[1], second: 0, of: endDay),
                      now < endDate else { continue }
            }
            let key = runKey(for: day)!
            if !pausedRunKeys.contains(key) { return date }
        }
        return nil
    }
}

struct JourneySnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var active: JourneyRun?
    var schedules: [JourneySchedule]
    var favorites: [JourneyDock]
    var holidayMode: Bool
    var bikeMetric: JourneyMetric
    var minBikes: Int
    var minEBikes: Int
    var minSpaces: Int
    var useMinimumThresholds: Bool
    // Optional additions preserve snapshots from older phone/Watch installations.
    var siriDestination: JourneyDock? = nil
    var siriHasAmbiguousJourney: Bool? = nil
    var siriHasUnresolvedJourney: Bool? = nil
    var siriSchemaVersion: Int? = nil

    static let empty = Self(generatedAt: .distantPast, active: nil, schedules: [], favorites: [],
                            holidayMode: false, bikeMetric: .bikes, minBikes: 3, minEBikes: 3,
                            minSpaces: 3, useMinimumThresholds: true)

    func threshold(for metric: JourneyMetric) -> Int {
        // The alternatives filter toggle does not disable availability label colours.
        switch metric {
        case .bikes: return minBikes
        case .eBikes: return minEBikes
        case .allBikes: return minBikes + minEBikes
        case .spaces: return minSpaces
        }
    }

    mutating func applyAvailabilityPreferences(from defaults: UserDefaults = JourneyStore.defaults) {
        minBikes = max(0, defaults.object(forKey: "alternativeDocksMinBikes") as? Int ?? minBikes)
        minEBikes = max(0, defaults.object(forKey: "alternativeDocksMinEBikes") as? Int ?? minEBikes)
        minSpaces = max(0, defaults.object(forKey: "alternativeDocksMinSpaces") as? Int ?? minSpaces)
        useMinimumThresholds = defaults.object(forKey: "alternativeDocksUseMinimumThresholds") as? Bool ?? useMinimumThresholds
    }

    func selection(at now: Date = Date(), location: JourneyLocation?, nearby: [JourneyDock] = []) -> JourneySelection? {
        if let active, active.expiresAt > now {
            return JourneySelection(dock: active.dock, metric: active.phase == .riding ? .spaces : bikeMetric,
                                    source: .active, run: active, scheduledAt: nil)
        }
        if !holidayMode {
            var next: (schedule: JourneySchedule, date: Date)?
            for schedule in schedules {
                guard let date = schedule.nextOccurrence(at: now) else { continue }
                if let current = next,
                   current.date < date || (current.date == date && current.schedule.id < schedule.id) { continue }
                next = (schedule, date)
            }
            if let next {
                return JourneySelection(dock: next.schedule.startDock, metric: bikeMetric,
                                        source: .scheduled, run: nil, scheduledAt: next.date)
            }
        }
        guard let location, location.isUsable(at: now, maximumAge: 3600) else { return nil }
        let candidates = favorites.isEmpty ? nearby : favorites
        guard let dock = candidates.filter({ $0.coordinate?.isValid == true }).min(by: {
            location.coordinate.distance(to: $0.coordinate!) < location.coordinate.distance(to: $1.coordinate!)
        }) else { return nil }
        return JourneySelection(dock: dock, metric: bikeMetric, source: favorites.isEmpty ? .nearby : .favorite,
                                run: nil, scheduledAt: nil)
    }
}

struct JourneySelection: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case active, scheduled, favorite, nearby }
    var dock: JourneyDock
    var metric: JourneyMetric
    var source: Source
    var run: JourneyRun?
    var scheduledAt: Date?

}

enum JourneyStore {
    static let snapshotKey = "journeySnapshot.v1"
    static let locationKey = "journeyLocation.v1"
    static let widgetKind = "BikeSpotJourney"
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.dev.skynolimit.myborisbikes") ?? .standard }

    static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults = defaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, key: String, defaults: UserDefaults = defaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value), defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }

    static var syncPayload: [String: Any] {
        var payload: [String: Any] = [:]
        payload[snapshotKey] = defaults.data(forKey: snapshotKey)
        payload[locationKey] = defaults.data(forKey: locationKey)
        let docks = [snapshot.active?.startDock, snapshot.active?.destinationDock].compactMap { $0 }
            + snapshot.schedules.map(\.startDock)
        let availability = docks.reduce(into: [String: JourneyAvailability]()) { result, dock in
            result[dock.id] = self.availability(for: dock.id)
        }
        payload["journeyAvailability"] = try? JSONEncoder().encode(availability)
        payload[JourneySimulation.key] = defaults.data(forKey: JourneySimulation.key)
        return payload
    }

    @discardableResult
    static func receiveSimulation(_ data: Data, defaults: UserDefaults = defaults) -> Bool {
        guard let incoming = try? JSONDecoder().decode(JourneySimulation.self, from: data),
              incoming.updatedAt > (read(JourneySimulation.self, key: JourneySimulation.key, defaults: defaults)?.updatedAt ?? .distantPast)
        else { return false }
        defaults.set(data, forKey: JourneySimulation.key)
        return true
    }

    @discardableResult
    static func receive(_ data: Data, defaults: UserDefaults = defaults) -> Bool {
        guard let incoming = try? JSONDecoder().decode(JourneySnapshot.self, from: data),
              incoming.generatedAt > (read(JourneySnapshot.self, key: snapshotKey, defaults: defaults)?.generatedAt ?? .distantPast)
        else { return false }
        defaults.set(data, forKey: snapshotKey)
        return true
    }

    static var snapshot: JourneySnapshot { read(JourneySnapshot.self, key: snapshotKey) ?? .empty }
    static var location: JourneyLocation? { read(JourneyLocation.self, key: locationKey) }
    static func availability(for id: String) -> JourneyAvailability? {
        read(JourneyAvailability.self, key: "journeyAvailability.\(id)")
    }
}
