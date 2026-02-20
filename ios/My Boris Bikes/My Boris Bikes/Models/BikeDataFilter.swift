import Foundation

struct BikeAvailabilityCounts {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    var totalBikes: Int {
        standardBikes + eBikes
    }

    var hasAnyBikes: Bool {
        totalBikes > 0
    }

    var hasAnyAvailability: Bool {
        totalBikes + emptySpaces > 0
    }
}

enum BikeDataFilter: String, CaseIterable, Identifiable {
    case both
    case bikesOnly
    case eBikesOnly

    static let userDefaultsKey = AppConstants.UserDefaults.bikeDataFilterKey
    static var userDefaultsStore: UserDefaults {
        AppConstants.UserDefaults.sharedDefaults
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both:
            return "Both"
        case .bikesOnly:
            return "Bikes"
        case .eBikesOnly:
            return "E-bikes"
        }
    }

    var showsStandardBikes: Bool {
        self != .eBikesOnly
    }

    var showsEBikes: Bool {
        self != .bikesOnly
    }

    var noBikesMessage: String {
        switch self {
        case .eBikesOnly:
            return "No e-bikes currently available"
        case .bikesOnly, .both:
            return "No bikes currently available"
        }
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

    static let userDefaultsKey = AppConstants.UserDefaults.liveActivityPrimaryDisplayKey
    static var userDefaultsStore: UserDefaults {
        AppConstants.UserDefaults.sharedDefaults
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bikes: return "Bikes"
        case .eBikes: return "E-bikes"
        case .spaces: return "Spaces"
        }
    }

    /// Returns the available options based on the current bike data filter.
    static func availableCases(for filter: BikeDataFilter) -> [LiveActivityPrimaryDisplay] {
        switch filter {
        case .both: return [.bikes, .eBikes, .spaces]
        case .bikesOnly: return [.bikes, .spaces]
        case .eBikesOnly: return [.eBikes, .spaces]
        }
    }

    /// Returns the primary count value from the given counts.
    func primaryValue(standardBikes: Int, eBikes: Int, emptySpaces: Int) -> Int {
        switch self {
        case .bikes: return standardBikes
        case .eBikes: return eBikes
        case .spaces: return emptySpaces
        }
    }

    /// Returns the color associated with this display type.
    var colorRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .bikes: return (236.0/255, 0, 0)
        case .eBikes: return (12.0/255, 17.0/255, 177.0/255)
        case .spaces: return (117.0/255, 117.0/255, 117.0/255)
        }
    }
}

struct AlternativeDockSettings {
    static let enabledKey = AppConstants.UserDefaults.alternativeDocksEnabledKey
    static let minSpacesKey = AppConstants.UserDefaults.alternativeDocksMinSpacesKey
    static let minBikesKey = AppConstants.UserDefaults.alternativeDocksMinBikesKey
    static let minEBikesKey = AppConstants.UserDefaults.alternativeDocksMinEBikesKey
    static let distanceThresholdMilesKey = AppConstants.UserDefaults.alternativeDocksDistanceThresholdMilesKey
    static let maxCountKey = AppConstants.UserDefaults.alternativeDocksMaxCountKey
    static let widgetEnabledKey = AppConstants.UserDefaults.alternativeDocksWidgetEnabledKey
    static let useStartingPointLogicKey = AppConstants.UserDefaults.alternativeDocksUseStartingPointLogicKey
    static let useMinimumThresholdsKey = AppConstants.UserDefaults.alternativeDocksUseMinimumThresholdsKey

    static var userDefaultsStore: UserDefaults {
        AppConstants.UserDefaults.sharedDefaults
    }

    static let defaultMinSpaces = 3
    static let defaultMinBikes = 3
    static let defaultMinEBikes = 3
    static let defaultDistanceThresholdMiles = 1.0
    static let defaultMaxAlternatives = 3
    static let defaultWidgetEnabled = true
    static let defaultUseStartingPointLogic = false
    static let defaultUseMinimumThresholds = false
    static let metersPerMile = 1609.344

    static var distanceOptions: [Double] {
        Array(stride(from: 0.5, through: 5.0, by: 0.5))
    }
}

// MARK: - Live Activity Per-Dock Primary Display

struct LiveActivityDockSettings {
    private static let overridesKey = "liveActivityDockPrimaryDisplayOverrides"

    static var userDefaultsStore: UserDefaults {
        AppConstants.UserDefaults.sharedDefaults
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

    /// Set the primary display override for a specific dock
    static func setPrimaryDisplay(_ display: LiveActivityPrimaryDisplay, for dockId: String) {
        var dict = userDefaultsStore.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        dict[dockId] = display.rawValue
        userDefaultsStore.set(dict, forKey: overridesKey)
    }

    /// Clear the primary display override for a specific dock
    static func clearPrimaryDisplay(for dockId: String) {
        var dict = userDefaultsStore.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        dict.removeValue(forKey: dockId)
        userDefaultsStore.set(dict, forKey: overridesKey)
    }
}
