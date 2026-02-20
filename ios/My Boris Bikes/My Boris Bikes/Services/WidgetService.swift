//
//  WidgetService.swift
//  My Boris Bikes
//
//  Service for managing widget data and updates
//

import Foundation
import WidgetKit
import CoreLocation

@MainActor
class WidgetService: ObservableObject {
    static let shared = WidgetService()

    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let widgetDataKey = "ios_widget_data"
    private let userDefaults: UserDefaults?
    private var cachedAllBikePoints: [BikePoint] = []

    private init() {
        self.userDefaults = UserDefaults(suiteName: appGroup)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    /// Updates widget data with current bike point information
    func updateWidgetData(
        bikePoints: [BikePoint],
        allBikePoints: [BikePoint],
        favorites: [FavoriteBikePoint],
        sortMode: SortMode,
        userLocation: CLLocation?
    ) {
        debugLog("WidgetService: updateWidgetData called with \(bikePoints.count) bike points, \(favorites.count) favorites")
        if !allBikePoints.isEmpty {
            cachedAllBikePoints = allBikePoints
        }
        let effectiveAllBikePoints = allBikePoints.isEmpty ? cachedAllBikePoints : allBikePoints
        var widgetBikePoints: [WidgetBikePointData] = []

        let favoriteBikePointsById = Dictionary(uniqueKeysWithValues: bikePoints.map { ($0.id, $0) })

        // Create widget data for each favorite
        for favorite in favorites {
            if let bikePoint = favoriteBikePointsById[favorite.id] {
                let distance = distanceFromUser(userLocation, to: bikePoint)

                let widgetData = WidgetBikePointData(
                    id: bikePoint.id,
                    displayName: favorite.displayName,
                    actualName: bikePoint.commonName,
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    distance: distance,
                    lastUpdated: Date()
                )
                widgetBikePoints.append(widgetData)
            }
        }

        // Sort according to current sort mode
        let sortedFavorites = sortWidgetData(widgetBikePoints, mode: sortMode, favorites: favorites)

        let alternatives = alternativeSettings()
        var orderedWidgetBikePoints: [WidgetBikePointData] = []
        let favoriteIds = Set(favorites.map { $0.id })

        if alternatives.enabled && effectiveAllBikePoints.isEmpty {
            debugLog("WidgetService: Skipping widget update until all-bike-points data is available for alternatives")
            return
        }

        let startingPointFavoriteIds = startingPointFavoriteIds(
            favoriteBikePoints: bikePoints,
            userLocation: userLocation,
            thresholdMeters: alternatives.thresholdMeters
        )

        var alternativeItemCount = 0

        for favoriteData in sortedFavorites {
            orderedWidgetBikePoints.append(favoriteData)

            guard alternatives.enabled,
                  let favoriteBikePoint = favoriteBikePointsById[favoriteData.id],
                  !effectiveAllBikePoints.isEmpty else { continue }

            let alternativeBikePoints = alternativesForWidget(
                favorite: favoriteBikePoint,
                favoriteIds: favoriteIds,
                startingPointFavoriteIds: startingPointFavoriteIds,
                allBikePoints: effectiveAllBikePoints,
                userLocation: userLocation,
                settings: alternatives,
                bikeDataFilter: bikeDataFilterSetting()
            )

            let alternativeWidgetData = alternativeBikePoints.map { bikePoint in
                WidgetBikePointData(
                    id: bikePoint.id,
                    displayName: bikePoint.commonName,
                    actualName: bikePoint.commonName,
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    distance: distanceFromUser(userLocation, to: bikePoint),
                    lastUpdated: Date(),
                    isAlternative: true,
                    parentFavoriteId: favoriteData.id
                )
            }

            alternativeItemCount += alternativeWidgetData.count
            orderedWidgetBikePoints.append(contentsOf: alternativeWidgetData)
        }

        debugLog("WidgetService: Created \(orderedWidgetBikePoints.count) widget bike points (\(alternativeItemCount) alternatives)")
        if alternatives.enabled && effectiveAllBikePoints.isEmpty {
            debugLog("WidgetService: Alternatives enabled, but no all-bike-points data available")
        }

        // Create widget data container
        let widgetData = WidgetData(
            bikePoints: orderedWidgetBikePoints,
            sortMode: sortMode.rawValue,
            lastRefresh: Date()
        )

        // Save to shared UserDefaults
        saveWidgetData(widgetData)

        // Reload all widget timelines
        reloadWidgets()
    }

    private func distanceFromUser(_ userLocation: CLLocation?, to bikePoint: BikePoint) -> Double? {
        guard let userLocation = userLocation else { return nil }
        return userLocation.distance(from: CLLocation(
            latitude: bikePoint.lat,
            longitude: bikePoint.lon
        ))
    }

    private func bikeDataFilterSetting() -> BikeDataFilter {
        let rawValue = BikeDataFilter.userDefaultsStore.string(forKey: BikeDataFilter.userDefaultsKey)
        return BikeDataFilter(rawValue: rawValue ?? BikeDataFilter.both.rawValue) ?? .both
    }

    private func alternativeSettings() -> AlternativeSettingsSnapshot {
        let defaults = AlternativeDockSettings.userDefaultsStore
        let enabled = defaults.object(forKey: AlternativeDockSettings.widgetEnabledKey) as? Bool
            ?? AlternativeDockSettings.defaultWidgetEnabled
        let minSpaces = defaults.object(forKey: AlternativeDockSettings.minSpacesKey) as? Int
            ?? AlternativeDockSettings.defaultMinSpaces
        let minBikes = defaults.object(forKey: AlternativeDockSettings.minBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinBikes
        let minEBikes = defaults.object(forKey: AlternativeDockSettings.minEBikesKey) as? Int
            ?? AlternativeDockSettings.defaultMinEBikes
        let thresholdMiles = defaults.object(forKey: AlternativeDockSettings.distanceThresholdMilesKey) as? Double
            ?? AlternativeDockSettings.defaultDistanceThresholdMiles
        let maxCount = defaults.object(forKey: AlternativeDockSettings.maxCountKey) as? Int
            ?? AlternativeDockSettings.defaultMaxAlternatives
        let useMinimumThresholds = defaults.object(forKey: AlternativeDockSettings.useMinimumThresholdsKey) as? Bool
            ?? AlternativeDockSettings.defaultUseMinimumThresholds

        return AlternativeSettingsSnapshot(
            enabled: enabled,
            minSpaces: minSpaces,
            minBikes: minBikes,
            minEBikes: minEBikes,
            maxCount: max(1, maxCount),
            thresholdMeters: thresholdMiles * AlternativeDockSettings.metersPerMile,
            useMinimumThresholds: useMinimumThresholds
        )
    }

    private func alternativesForWidget(
        favorite: BikePoint,
        favoriteIds: Set<String>,
        startingPointFavoriteIds: Set<String>,
        allBikePoints: [BikePoint],
        userLocation: CLLocation?,
        settings: AlternativeSettingsSnapshot,
        bikeDataFilter: BikeDataFilter
    ) -> [BikePoint] {
        let needsBikes = !hasSufficientBikes(
            bikePoint: favorite,
            settings: settings,
            bikeDataFilter: bikeDataFilter
        )
        let needsSpaces = favorite.emptyDocks < settings.minSpaces

        let shouldShowAlternatives: Bool
        let requiresBikes: Bool
        let requiresSpaces: Bool

        if useStartingPointLogic() {
            let isStartingPoint = startingPointFavoriteIds.contains(favorite.id)

            if isStartingPoint {
                shouldShowAlternatives = needsBikes
                requiresBikes = needsBikes
                requiresSpaces = false
            } else {
                shouldShowAlternatives = needsSpaces
                requiresBikes = false
                requiresSpaces = needsSpaces
            }
        } else {
            shouldShowAlternatives = needsBikes || needsSpaces
            requiresBikes = needsBikes
            requiresSpaces = needsSpaces
        }

        guard shouldShowAlternatives else { return [] }

        let candidates = allBikePoints.filter { bikePoint in
            bikePoint.id != favorite.id &&
            !favoriteIds.contains(bikePoint.id) &&
            bikePoint.isAvailable
        }

        let filteredCandidates = candidates.filter { bikePoint in
            let meetsBikes = settings.useMinimumThresholds
                ? hasSufficientBikes(
                    bikePoint: bikePoint,
                    settings: settings,
                    bikeDataFilter: bikeDataFilter
                )
                : hasAnyBikes(bikePoint: bikePoint, bikeDataFilter: bikeDataFilter)
            let meetsSpaces = settings.useMinimumThresholds
                ? bikePoint.emptyDocks >= settings.minSpaces
                : bikePoint.emptyDocks > 0

            switch (requiresBikes, requiresSpaces) {
            case (true, true):
                return meetsBikes || meetsSpaces
            case (true, false):
                return meetsBikes
            case (false, true):
                return meetsSpaces
            case (false, false):
                return true
            }
        }

        let favoriteLocation = CLLocation(latitude: favorite.lat, longitude: favorite.lon)
        let sorted = filteredCandidates.sorted { first, second in
            let firstDistance = favoriteLocation.distance(from: CLLocation(latitude: first.lat, longitude: first.lon))
            let secondDistance = favoriteLocation.distance(from: CLLocation(latitude: second.lat, longitude: second.lon))
            return firstDistance < secondDistance
        }

        let maxAlternatives = min(settings.maxCount, 3)
        return Array(sorted.prefix(maxAlternatives))
    }

    private func startingPointFavoriteIds(
        favoriteBikePoints: [BikePoint],
        userLocation: CLLocation?,
        thresholdMeters: Double
    ) -> Set<String> {
        guard useStartingPointLogic() else { return [] }
        guard !favoriteBikePoints.isEmpty else { return [] }
        guard let userLocation = userLocation else {
            return Set(favoriteBikePoints.map { $0.id })
        }

        let favoritesWithinThreshold = favoriteBikePoints.filter { favorite in
            let favoriteLocation = CLLocation(latitude: favorite.lat, longitude: favorite.lon)
            return userLocation.distance(from: favoriteLocation) <= thresholdMeters
        }

        if !favoritesWithinThreshold.isEmpty {
            return Set(favoritesWithinThreshold.map { $0.id })
        }

        if let nearestFavorite = favoriteBikePoints.min(by: { first, second in
            let firstLocation = CLLocation(latitude: first.lat, longitude: first.lon)
            let secondLocation = CLLocation(latitude: second.lat, longitude: second.lon)
            return userLocation.distance(from: firstLocation) < userLocation.distance(from: secondLocation)
        }) {
            return [nearestFavorite.id]
        }

        return []
    }

    private func useStartingPointLogic() -> Bool {
        let defaults = AlternativeDockSettings.userDefaultsStore
        return defaults.object(forKey: AlternativeDockSettings.useStartingPointLogicKey) as? Bool
            ?? AlternativeDockSettings.defaultUseStartingPointLogic
    }

    private func isStartingPoint(
        userLocation: CLLocation?,
        bikePoint: BikePoint,
        thresholdMeters: Double
    ) -> Bool {
        guard let userLocation = userLocation else { return true }
        let bikeLocation = CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon)
        return userLocation.distance(from: bikeLocation) <= thresholdMeters
    }

    private func hasSufficientBikes(
        bikePoint: BikePoint,
        settings: AlternativeSettingsSnapshot,
        bikeDataFilter: BikeDataFilter
    ) -> Bool {
        switch bikeDataFilter {
        case .bikesOnly:
            return bikePoint.standardBikes >= settings.minBikes
        case .eBikesOnly:
            return bikePoint.eBikes >= settings.minEBikes
        case .both:
            return bikePoint.standardBikes >= settings.minBikes &&
                bikePoint.eBikes >= settings.minEBikes
        }
    }

    private func hasAnyBikes(
        bikePoint: BikePoint,
        bikeDataFilter: BikeDataFilter
    ) -> Bool {
        switch bikeDataFilter {
        case .bikesOnly:
            return bikePoint.standardBikes > 0
        case .eBikesOnly:
            return bikePoint.eBikes > 0
        case .both:
            return bikePoint.totalBikes > 0
        }
    }

    /// Sorts widget data according to the specified mode
    private func sortWidgetData(
        _ data: [WidgetBikePointData],
        mode: SortMode,
        favorites: [FavoriteBikePoint]
    ) -> [WidgetBikePointData] {
        switch mode {
        case .distance:
            return data.sorted { (lhs, rhs) in
                // Sort by distance, putting items without distance at the end
                if let lhsDistance = lhs.distance, let rhsDistance = rhs.distance {
                    return lhsDistance < rhsDistance
                } else if lhs.distance != nil {
                    return true
                } else if rhs.distance != nil {
                    return false
                } else {
                    return lhs.displayName < rhs.displayName
                }
            }

        case .alphabetical:
            return data.sorted { $0.displayName < $1.displayName }
        }
    }

    /// Saves widget data to shared UserDefaults
    private func saveWidgetData(_ data: WidgetData) {
        guard let userDefaults = userDefaults else {
            debugLog("WidgetService: Unable to access app group UserDefaults")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(data)
            userDefaults.set(encoded, forKey: widgetDataKey)
            userDefaults.synchronize()
            debugLog("WidgetService: Widget data saved successfully")
        } catch {
            debugLog("WidgetService: Failed to encode widget data: \(error)")
        }
    }

    /// Retrieves widget data from shared UserDefaults
    func loadWidgetData() -> WidgetData? {
        guard let userDefaults = userDefaults,
              let data = userDefaults.data(forKey: widgetDataKey) else {
            debugLog("WidgetService: No widget data found")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let widgetData = try decoder.decode(WidgetData.self, from: data)
            debugLog("WidgetService: Widget data loaded successfully")
            return widgetData
        } catch {
            debugLog("WidgetService: Failed to decode widget data: \(error)")
            return nil
        }
    }

    /// Triggers a reload of all widget timelines
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        debugLog("WidgetService: Widget timelines reloaded")
    }

    /// Clears all widget data
    func clearWidgetData() {
        userDefaults?.removeObject(forKey: widgetDataKey)
        userDefaults?.synchronize()
        reloadWidgets()
        debugLog("WidgetService: Widget data cleared")
    }
}

private struct AlternativeSettingsSnapshot {
    let enabled: Bool
    let minSpaces: Int
    let minBikes: Int
    let minEBikes: Int
    let maxCount: Int
    let thresholdMeters: Double
    let useMinimumThresholds: Bool
}
