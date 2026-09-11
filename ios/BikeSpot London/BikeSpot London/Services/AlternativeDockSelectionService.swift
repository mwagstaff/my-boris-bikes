import CoreLocation
import Foundation

enum AlternativeDockPurpose {
    case bikes
    case eBikes
    case allBikes
    case spaces
}

struct AlternativeDockSelectionService {
    static let favoritePreviewCount = 3

    /// The editable Favourites list keeps saved positions, even when availability is zero or unknown.
    /// Availability-based recommendations for widgets and Live Activities use `alternatives` instead.
    static func savedAlternativesForFavorites(
        for primaryDockID: String,
        savedDocks: [ScheduledJourneyDock],
        allBikePoints: [BikePoint],
        showAll: Bool
    ) -> [BikePoint] {
        let byID = Dictionary(allBikePoints.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen: Set<String> = [primaryDockID]
        let ordered = savedDocks.filter { seen.insert($0.id).inserted }.map { dock in
            byID[dock.id] ?? BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude)
        }
        return showAll ? ordered : Array(ordered.prefix(favoritePreviewCount))
    }

    static func alternatives(
        for bikePoint: BikePoint,
        allBikePoints: [BikePoint],
        favorites: [FavoriteBikePoint],
        userLocation: CLLocation?,
        purpose: AlternativeDockPurpose,
        forceShow: Bool = false,
        maximumCount: Int? = nil,
        filterCustomDocksByAvailability: Bool = true
    ) -> [BikePoint] {
        let settings = settingsSnapshot()
        guard settings.enabled else { return [] }
        guard !allBikePoints.isEmpty else { return [] }
        guard forceShow || shouldShowAlternatives(for: bikePoint, purpose: purpose, settings: settings) else {
            return []
        }

        let customDockIDs = DockPreferencesService.shared.customDockIDs(for: bikePoint.id)
        let candidates = orderedCandidates(
            for: bikePoint,
            allBikePoints: allBikePoints,
            excludingFavoriteIDs: Set(favorites.map(\.id)),
            customDockIDs: customDockIDs
        )
        let displayedCandidates = customDockIDs != nil && !filterCustomDocksByAvailability
            ? candidates
            : candidates.filter { meetsRequirement($0, purpose: purpose, settings: settings) }

        return Array(displayedCandidates.prefix(max(1, maximumCount ?? settings.maxCount)))
    }

    /// Apply availability filtering and display limits after this shared membership/order policy.
    static func orderedCandidates(
        for bikePoint: BikePoint,
        allBikePoints: [BikePoint],
        excludingFavoriteIDs: Set<String>,
        customDockIDs: [String]?
    ) -> [BikePoint] {
        if let customDockIDs {
            let byID = Dictionary(allBikePoints.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            var seen: Set<String> = [bikePoint.id]
            return customDockIDs.compactMap { id in
                guard seen.insert(id).inserted, let candidate = byID[id], candidate.isAvailable else { return nil }
                return candidate
            }
        }

        let sourceLocation = CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon)
        return allBikePoints.filter { candidate in
            candidate.id != bikePoint.id && !excludingFavoriteIDs.contains(candidate.id) && candidate.isAvailable
        }.sorted { first, second in
            sourceLocation.distance(from: CLLocation(latitude: first.lat, longitude: first.lon))
                < sourceLocation.distance(from: CLLocation(latitude: second.lat, longitude: second.lon))
        }
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
