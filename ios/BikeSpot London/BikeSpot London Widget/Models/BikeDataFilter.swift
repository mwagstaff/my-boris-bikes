import Foundation

struct BikeAvailabilityCounts {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    var totalBikes: Int {
        standardBikes + eBikes
    }

    var hasAnyAvailability: Bool {
        totalBikes + emptySpaces > 0
    }
}

enum BikeDataFilter: String, CaseIterable, Identifiable {
    case both
    case bikesOnly
    case eBikesOnly

    static let userDefaultsKey = "bikeDataFilter"
    private static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var userDefaultsStore: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    var id: String { rawValue }

    var showsStandardBikes: Bool {
        self != .eBikesOnly
    }

    var showsEBikes: Bool {
        self != .bikesOnly
    }

    func filteredCounts(standardBikes: Int, eBikes: Int, emptySpaces: Int) -> BikeAvailabilityCounts {
        switch self {
        case .both:
            return BikeAvailabilityCounts(
                standardBikes: standardBikes,
                eBikes: eBikes,
                emptySpaces: emptySpaces
            )
        case .bikesOnly:
            return BikeAvailabilityCounts(
                standardBikes: standardBikes,
                eBikes: 0,
                emptySpaces: emptySpaces
            )
        case .eBikesOnly:
            return BikeAvailabilityCounts(
                standardBikes: 0,
                eBikes: eBikes,
                emptySpaces: emptySpaces
            )
        }
    }
}

enum LiveActivityPrimaryDisplay: String, CaseIterable, Identifiable {
    case bikes
    case eBikes
    case spaces

    static let userDefaultsKey = "liveActivityPrimaryDisplay"
    private static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var userDefaultsStore: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bikes: return "Bikes"
        case .eBikes: return "E-bikes"
        case .spaces: return "Spaces"
        }
    }

    static func availableCases(for filter: BikeDataFilter) -> [LiveActivityPrimaryDisplay] {
        switch filter {
        case .both: return [.bikes, .eBikes, .spaces]
        case .bikesOnly: return [.bikes, .spaces]
        case .eBikesOnly: return [.eBikes, .spaces]
        }
    }

    func primaryValue(standardBikes: Int, eBikes: Int, emptySpaces: Int) -> Int {
        switch self {
        case .bikes: return standardBikes
        case .eBikes: return eBikes
        case .spaces: return emptySpaces
        }
    }

    var colorRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .bikes: return (236.0/255, 0, 0)
        case .eBikes: return (12.0/255, 17.0/255, 177.0/255)
        case .spaces: return (117.0/255, 117.0/255, 117.0/255)
        }
    }
}

struct AlternativeDockSettings {
    static let minSpacesKey = "alternativeDocksMinSpaces"
    static let minBikesKey = "alternativeDocksMinBikes"
    static let minEBikesKey = "alternativeDocksMinEBikes"

    private static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var userDefaultsStore: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static let defaultMinSpaces = 3
    static let defaultMinBikes = 3
    static let defaultMinEBikes = 3
}

// MARK: - Live Activity Per-Dock Primary Display

struct LiveActivityDockSettings {
    private static let overridesKey = "liveActivityDockPrimaryDisplayOverrides"
    private static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var userDefaultsStore: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Get the primary display override for a specific dock
    static func getPrimaryDisplay(for dockId: String) -> LiveActivityPrimaryDisplay? {
        guard let dict = userDefaultsStore.dictionary(forKey: overridesKey) as? [String: String],
              let rawValue = dict[dockId],
              let display = LiveActivityPrimaryDisplay(rawValue: rawValue) else {
            return nil
        }
        return display
    }
}
