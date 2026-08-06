import Foundation
import WidgetKit

/// Service to share data between the watch app and its widgets
class WatchWidgetService {
    static let shared = WatchWidgetService()
    
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let userDefaults: UserDefaults
    private let updateQueue = DispatchQueue(label: "widget.update.queue", qos: .userInitiated)
    
    // Keys for widget data sharing
    private let closestStationKey = "widget_closest_station"
    private let dataTimestampKey = "widget_data_timestamp"
    private let lastKnownGoodDataKey = "widget_last_known_good_data"
    private let lastKnownGoodTimestampKey = "widget_last_known_good_timestamp"
    private let updateInProgressKey = "widget_update_in_progress"
    private let updateLockKey = "widget_update_lock"
    
    private init() {
        self.userDefaults = UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
    }
    
    /// Updates the closest station data for the widget with immediate forced refresh
    func updateClosestStation(_ bikePoint: WatchBikePoint) {
        // Immediate synchronous update for critical widget data
        updateClosestStationSync(bikePoint)
        
        // Force immediate widget refresh with multiple strategies
        forceImmediateWidgetRefresh()
    }
    
    private func updateClosestStationSync(_ bikePoint: WatchBikePoint) {
        // Don't set update lock to prevent data drought - just write new data atomically
        // This ensures widgets always have some data available during updates
        let alias = resolvedAlias(for: bikePoint)
        
        let widgetStation = WidgetBikePoint(
            id: bikePoint.id,
            commonName: bikePoint.commonName,
            alias: alias,
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            distance: nil // Could be calculated if needed
        )
        
        do {
            let data = try JSONEncoder().encode(widgetStation)
            
            // Validate encoded data before clearing old data
            guard !data.isEmpty else {
                releaseUpdateLock()
                return
            }
            
            // Verify data can be decoded before committing the update
            let testDecode = try JSONDecoder().decode(WidgetBikePoint.self, from: data)
            guard testDecode.id == widgetStation.id else {
                releaseUpdateLock()
                return
            }
            
            // Special logging for Stonecutter Street discrepancy investigation
            if widgetStation.commonName.contains("Stonecutter") {
            }
            
            // Data is valid, proceed with atomic update
            userDefaults.set(data, forKey: closestStationKey)
            userDefaults.set(Date().timeIntervalSince1970, forKey: dataTimestampKey)
            
            // Also store as last known good data for fallback during transient errors
            userDefaults.set(data, forKey: lastKnownGoodDataKey)
            userDefaults.set(Date().timeIntervalSince1970, forKey: lastKnownGoodTimestampKey)
            
            // Alternative approach: Write to a file in the shared container
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
                let fileURL = containerURL.appendingPathComponent("widget_data.json")
                
                do {
                    try data.write(to: fileURL)
                } catch {
                }
            }
            
            // Still try UserDefaults as backup
            userDefaults.synchronize()
            
            // Verify the data was written
            if userDefaults.data(forKey: closestStationKey) == nil {
                releaseUpdateLock()
                return
            }
            
            // No update lock to release - data is written atomically
            
            
        } catch {
            // No update lock to release
        }
    }
    
    /// Updates the closest station from a list of bike points (finds closest by distance or first favorite)
    func updateClosestStation(from bikePoints: [WatchBikePoint], userLocation: (lat: Double, lon: Double)? = nil) {
        guard !bikePoints.isEmpty else {
            return
        }
        
        let closestStation: WatchBikePoint
        
        if let userLoc = userLocation {
            // Calculate distances and find the closest dock
            
            let stationWithDistances = bikePoints.map { bikePoint in
                let distance = calculateDistance(
                    from: (userLoc.lat, userLoc.lon),
                    to: (bikePoint.lat, bikePoint.lon)
                )
                return (bikePoint: bikePoint, distance: distance)
            }
            
            // Sort by distance and get the closest
            let sortedByDistance = stationWithDistances.sorted { $0.distance < $1.distance }
            closestStation = sortedByDistance.first!.bikePoint
        } else {
            // Fallback: use the first one (already sorted by favorites in the main app)
            closestStation = bikePoints.first!
        }
        
        updateClosestStation(closestStation)
    }
    
    /// Updates individual dock data for configurable widgets with immediate forced refresh
    func updateAllDockData(from bikePoints: [WatchBikePoint]) {
        // Immediate synchronous update for critical widget data
        updateAllDockDataSync(from: bikePoints)
        
        // Force immediate widget refresh with multiple strategies
        forceImmediateWidgetRefresh()
    }
    
    private func updateAllDockDataSync(from bikePoints: [WatchBikePoint]) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return
        }
        
        // Validate input data before proceeding
        guard !bikePoints.isEmpty else {
            return
        }
        
        // Convert to WidgetBikePoint format
        let widgetStations: [WidgetBikePoint] = bikePoints.map { bikePoint in
            let alias = resolvedAlias(for: bikePoint)
            return WidgetBikePoint(
                id: bikePoint.id,
                commonName: bikePoint.commonName,
                alias: alias,
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                distance: nil
            )
        }
        
        // Write consolidated data for configurable widgets with atomic update
        do {
            let data = try JSONEncoder().encode(widgetStations)
            
            // Perform atomic update: validate encoded data before clearing old data
            guard !data.isEmpty else {
                return
            }
            
            // Verify data can be decoded before committing the update
            let testDecode = try JSONDecoder().decode([WidgetBikePoint].self, from: data)
            guard testDecode.count == widgetStations.count else {
                return
            }
            
            // Data is valid, proceed with atomic update
            userDefaults.set(data, forKey: "bikepoints")
            
            // Also store as last known good data for configurable widgets
            userDefaults.set(data, forKey: "bikepoints_last_known_good")
            userDefaults.set(Date().timeIntervalSince1970, forKey: "bikepoints_last_known_good_timestamp")
            
            // No update lock to release
            
        } catch {
            // No update lock to release
            return // Abort update on any encoding/validation error
        }
        
        // Store individual dock timestamps
        let currentTimestamp = Date().timeIntervalSince1970
        for bikePoint in bikePoints {
            let dockTimestampKey = "dock_\(bikePoint.id)_timestamp"
            userDefaults.set(currentTimestamp, forKey: dockTimestampKey)
        }
        
        // Also write individual files (for potential future use)
        for widgetStation in widgetStations {
            do {
                let data = try JSONEncoder().encode(widgetStation)
                let fileURL = containerURL.appendingPathComponent("configurable_widget_\(widgetStation.id).json")
                try data.write(to: fileURL)
            } catch {
            }
        }
    }
    
    private func resolvedAlias(for bikePoint: WatchBikePoint) -> String? {
        if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        
        // Fallback to stored favorites on the watch if the bike point doesn't carry an alias
        return WatchFavoritesService.shared.alias(for: bikePoint.id)
    }
    
    /// Calculate distance between two coordinates using Haversine formula
    private func calculateDistance(from coord1: (lat: Double, lon: Double), to coord2: (lat: Double, lon: Double)) -> Double {
        let earthRadius = 6371000.0 // Earth's radius in meters
        
        let lat1Rad = coord1.lat * .pi / 180
        let lat2Rad = coord2.lat * .pi / 180
        let deltaLatRad = (coord2.lat - coord1.lat) * .pi / 180
        let deltaLonRad = (coord2.lon - coord1.lon) * .pi / 180
        
        let a = sin(deltaLatRad / 2) * sin(deltaLatRad / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(deltaLonRad / 2) * sin(deltaLonRad / 2)
        
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        
        return earthRadius * c
    }
    
    /// Clears the widget data (e.g., when no favorites)
    func clearWidgetData() {
        // Only clear if we don't have any valid data to preserve
        // This prevents race conditions during data updates
        let hasValidClosestStation = userDefaults.data(forKey: closestStationKey) != nil
        let hasValidBikepoints = userDefaults.data(forKey: "bikepoints") != nil
        
        // Only clear if we're explicitly clearing for no favorites scenario
        // Don't clear during transient updates that might cause race conditions
        if !hasValidClosestStation && !hasValidBikepoints {
        }
        
        userDefaults.removeObject(forKey: closestStationKey)
        userDefaults.removeObject(forKey: dataTimestampKey)
        userDefaults.removeObject(forKey: "bikepoints") // Clear configurable widget data
        
        // Clear individual dock timestamps
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let dockTimestampKeys = allKeys.filter { $0.hasPrefix("dock_") && $0.hasSuffix("_timestamp") }
        for key in dockTimestampKeys {
            userDefaults.removeObject(forKey: key)
        }
        
        // Also clear the shared file
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let fileURL = containerURL.appendingPathComponent("widget_data.json")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Reload all widget timelines
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockCircularComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockRectangularComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockCircularComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockRectangularComplication")
    }
    
    /// Retrieves last known good data if current data is unavailable or too old
    /// Returns nil if no fallback data is available or if it's too old (>5 minutes)
    func getLastKnownGoodData() -> WidgetBikePoint? {
        guard let lastKnownGoodData = userDefaults.data(forKey: lastKnownGoodDataKey) else {
            return nil
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: lastKnownGoodTimestampKey)
        let dataAge = Date().timeIntervalSince1970 - lastKnownGoodTimestamp
        
        // Only use fallback data if it's less than 10 minutes old
        guard dataAge < 600 else {
            return nil
        }
        
        do {
            let fallbackStation = try JSONDecoder().decode(WidgetBikePoint.self, from: lastKnownGoodData)
            return fallbackStation
        } catch {
            return nil
        }
    }
    
    /// Retrieves last known good configurable widget data
    /// Returns empty array if no fallback data is available or if it's too old (>5 minutes)
    func getLastKnownGoodConfigurableData() -> [WidgetBikePoint] {
        guard let lastKnownGoodData = userDefaults.data(forKey: "bikepoints_last_known_good") else {
            return []
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: "bikepoints_last_known_good_timestamp")
        let dataAge = Date().timeIntervalSince1970 - lastKnownGoodTimestamp
        
        // Only use fallback data if it's less than 10 minutes old
        guard dataAge < 600 else {
            return []
        }
        
        do {
            let fallbackStations = try JSONDecoder().decode([WidgetBikePoint].self, from: lastKnownGoodData)
            return fallbackStations
        } catch {
            return []
        }
    }
    
    /// Releases the update lock to allow widgets to read data
    private func releaseUpdateLock() {
        userDefaults.removeObject(forKey: updateInProgressKey)
        userDefaults.removeObject(forKey: updateLockKey)
        userDefaults.synchronize()
    }
    
    /// Checks if an update is currently in progress
    func isUpdateInProgress() -> Bool {
        guard userDefaults.bool(forKey: updateInProgressKey) else { return false }
        
        let lockTimestamp = userDefaults.double(forKey: updateLockKey)
        let lockAge = Date().timeIntervalSince1970 - lockTimestamp
        
        // Consider locks older than 10 seconds as stale and remove them
        if lockAge > 10.0 {
            releaseUpdateLock()
            return false
        }
        
        return true
    }
    
    /// Forces immediate widget refresh using multiple strategies to bypass timeline delays
    private func forceImmediateWidgetRefresh() {
        
        // Check if we're in startup phase (no cached data yet)
        let hasExistingData = userDefaults.data(forKey: closestStationKey) != nil
        let startupDelay: TimeInterval = hasExistingData ? 0.0 : 2.0
        
        if !hasExistingData {
        }
        
        // Strategy 1: Delayed timeline reload to prevent startup exclamation triangles
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay) {
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockCircularComplication")
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockRectangularComplication")
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockCircularComplication")
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockRectangularComplication")
        }
        
        // Strategy 2: Force synchronize UserDefaults immediately
        userDefaults.synchronize()
        
        // Strategy 3: Staggered reloads to ensure widgets get fresh data (with startup delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay + 0.2) {
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockCircularComplication")
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesInteractiveDockRectangularComplication")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay + 0.5) {
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockCircularComplication")
            WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesClosestDockRectangularComplication")
        }
        
        // Strategy 4: Final reload after a longer delay (only if not startup)
        if hasExistingData {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        
    }
}
