import CoreLocation
import Foundation

enum AlternativeDockPurpose {
    case bikes
    case eBikes
    case allBikes
    case spaces
}

struct AlternativeDockSelectionService {
    static func alternatives(
        for bikePoint: BikePoint,
        allBikePoints: [BikePoint],
        favorites: [FavoriteBikePoint],
        userLocation: CLLocation?,
        purpose: AlternativeDockPurpose,
        forceShow: Bool = false
    ) -> [BikePoint] {
        let settings = settingsSnapshot()
        guard settings.enabled else { return [] }
        guard !allBikePoints.isEmpty else { return [] }
        guard forceShow || shouldShowAlternatives(for: bikePoint, purpose: purpose, settings: settings) else {
            return []
        }

        let favoriteIds = Set(favorites.map(\.id))
        let candidates = allBikePoints.filter { candidate in
            candidate.id != bikePoint.id &&
                !favoriteIds.contains(candidate.id) &&
                candidate.isAvailable &&
                meetsRequirement(candidate, purpose: purpose, settings: settings)
        }

        let sourceLocation = CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon)
        let sorted = candidates.sorted { first, second in
            let firstLocation = CLLocation(latitude: first.lat, longitude: first.lon)
            let secondLocation = CLLocation(latitude: second.lat, longitude: second.lon)
            return sourceLocation.distance(from: firstLocation) < sourceLocation.distance(from: secondLocation)
        }

        return Array(sorted.prefix(max(1, settings.maxCount)))
    }

    private struct Settings {
        let enabled: Bool
        let minSpaces: Int
        let minBikes: Int
        let minEBikes: Int
        let maxCount: Int
        let useMinimumThresholds: Bool
    }

    private static func settingsSnapshot() -> Settings {
        let defaults = AlternativeDockSettings.userDefaultsStore
        let enabled = defaults.object(forKey: AlternativeDockSettings.enabledKey) as? Bool
            ?? AlternativeDockSettings.defaultEnabled
        let minSpaces = defaults.object(forKey: AlternativeDockSettings.minSpacesKey) as? Int
            ?? AlternativeDockSettings.defaultMinSpaces
        let minBikes = defaults.object(forKey: AlternativeDockSettings.minBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinBikes
        let minEBikes = defaults.object(forKey: AlternativeDockSettings.minEBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinEBikes
        let maxCount = defaults.object(forKey: AlternativeDockSettings.maxCountKey) as? Int
            ?? AlternativeDockSettings.defaultMaxAlternatives
        let useMinimumThresholds = defaults.object(forKey: AlternativeDockSettings.useMinimumThresholdsKey) as? Bool
            ?? AlternativeDockSettings.defaultUseMinimumThresholds

        return Settings(
            enabled: enabled,
            minSpaces: max(0, minSpaces),
            minBikes: max(0, minBikes),
            minEBikes: max(0, minEBikes),
            maxCount: max(1, maxCount),
            useMinimumThresholds: useMinimumThresholds
        )
    }

    private static func shouldShowAlternatives(
        for bikePoint: BikePoint,
        purpose: AlternativeDockPurpose,
        settings: Settings
    ) -> Bool {
        switch purpose {
        case .bikes:
            return bikePoint.standardBikes < settings.minBikes
        case .eBikes:
            return bikePoint.eBikes < settings.minEBikes
        case .allBikes:
            return bikePoint.standardBikes < settings.minBikes || bikePoint.eBikes < settings.minEBikes
        case .spaces:
            return bikePoint.emptyDocks < settings.minSpaces
        }
    }

    private static func meetsRequirement(
        _ bikePoint: BikePoint,
        purpose: AlternativeDockPurpose,
        settings: Settings
    ) -> Bool {
        if settings.useMinimumThresholds {
            switch purpose {
            case .bikes:
                return bikePoint.standardBikes >= settings.minBikes
            case .eBikes:
                return bikePoint.eBikes >= settings.minEBikes
            case .allBikes:
                return bikePoint.standardBikes >= settings.minBikes && bikePoint.eBikes >= settings.minEBikes
            case .spaces:
                return bikePoint.emptyDocks >= settings.minSpaces
            }
        }

        switch purpose {
        case .bikes:
            return bikePoint.standardBikes > 0
        case .eBikes:
            return bikePoint.eBikes > 0
        case .allBikes:
            return bikePoint.totalBikes > 0
        case .spaces:
            return bikePoint.emptyDocks > 0
        }
    }
}

