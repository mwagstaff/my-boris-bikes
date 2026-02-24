//
//  My_Boris_Bikes_Watch_App_Extension.swift
//  My Boris Bikes Watch App Extension
//
//  Created by Mike Wagstaff on 10/08/2025.
//

// ************ WIDGET CHECKPOINT: Workingish... *******************
// TODO:
// Replace custom dock widgets with 3 "picker" widgets which allow you to pick a custom dock after you tap on them!

import WidgetKit
import SwiftUI
import CoreLocation
import AppIntents
import UIKit
import Foundation



// MARK: - Bundle Extension for App Icon
extension Bundle {
    var icon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return nil
    }
}


// MARK: - Navigation Intents for deep linking
@available(iOS 16.0, watchOS 9.0, *)
struct OpenDockDetailIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Dock Detail"
    static var description = IntentDescription("Opens the detail view for a specific dock")
    
    @Parameter(title: "Dock ID")
    var dockId: String
    
    @Parameter(title: "Dock Name") 
    var dockName: String
    
    init(dockId: String, dockName: String) {
        self.dockId = dockId
        self.dockName = dockName
    }
    
    init() {
        self.dockId = ""
        self.dockName = ""
    }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - Data Models
struct BorisBikesEntry: TimelineEntry {
    let date: Date
    let closestStation: WidgetBikePoint?
    let error: String?
    let isStaleData: Bool // Indicates if this is fallback data from a transient outage
    let dataTimestamp: Date? // When this bike data was last fetched from TfL

    init(date: Date, closestStation: WidgetBikePoint?, error: String?, isStaleData: Bool = false, dataTimestamp: Date? = nil) {
        self.date = date
        self.closestStation = closestStation
        self.error = error
        self.isStaleData = isStaleData
        self.dataTimestamp = dataTimestamp
    }
}

// MARK: - Data Models (duplicated from SharedModels for widget extension)
struct WidgetBikePoint: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let distance: Double? // Distance in meters
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return commonName
    }
    
    var totalBikes: Int {
        standardBikes + eBikes
    }
    
    var hasData: Bool {
        standardBikes + eBikes + emptySpaces > 0
    }
}

// Lightweight models and refresher to keep widget data current even when the app isn't opened
fileprivate struct APIBikePoint: Codable {
    let id: String
    let commonName: String
    let lat: Double
    let lon: Double
    let additionalProperties: [APIAdditionalProperty]
}

fileprivate struct APIAdditionalProperty: Codable {
    let key: String
    let value: String
}

fileprivate extension APIBikePoint {
    func toWidgetBikePoint(alias: String?) -> WidgetBikePoint {
        let standardBikes = Int(additionalProperties.first { $0.key == "NbStandardBikes" }?.value ?? "0") ?? 0
        let eBikes = Int(additionalProperties.first { $0.key == "NbEBikes" }?.value ?? "0") ?? 0
        let totalDocks = Int(additionalProperties.first { $0.key == "NbDocks" }?.value ?? "0") ?? 0
        let rawEmpty = Int(additionalProperties.first { $0.key == "NbEmptyDocks" }?.value ?? "0") ?? 0
        
        let totalBikes = standardBikes + eBikes
        let brokenDocks = max(0, totalDocks - (totalBikes + rawEmpty))
        let adjustedEmpty = max(0, totalDocks - totalBikes - brokenDocks)
        
        return WidgetBikePoint(
            id: id,
            commonName: commonName,
            alias: alias,
            standardBikes: standardBikes,
            eBikes: eBikes,
            emptySpaces: adjustedEmpty,
            distance: nil
        )
    }
}

fileprivate class WidgetDataRefresher {
    static let shared = WidgetDataRefresher()
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private var isFetching = false
    private var lastFetchDate: Date?
    
    func refreshIfNeeded(favorites: [FavoriteBikePoint]) {
        // Avoid excessive refreshes and concurrent fetches
        let now = Date()
        if isFetching { return }
        if let last = lastFetchDate, now.timeIntervalSince(last) < 60 { return }
        guard !favorites.isEmpty else { return }
        
        isFetching = true
        lastFetchDate = now
        
        Task {
            defer { isFetching = false }
            guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
            
            let aliasMap = favorites.reduce(into: [String: String]()) { result, favorite in
                if let alias = favorite.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alias.isEmpty {
                    result[favorite.id] = alias
                }
            }
            let ids = favorites.map { $0.id }
            let bikePoints = await fetchBikePoints(ids: ids, aliases: aliasMap)
            
            guard !bikePoints.isEmpty else { return }
            
            do {
                let data = try JSONEncoder().encode(bikePoints)
                let timestamp = Date().timeIntervalSince1970
                
                userDefaults.set(data, forKey: "bikepoints")
                userDefaults.set(data, forKey: "bikepoints_last_known_good")
                userDefaults.set(timestamp, forKey: "bikepoints_last_known_good_timestamp")
                userDefaults.set(timestamp, forKey: "widget_data_timestamp")
                
                // Store per-dock timestamps
                bikePoints.forEach { station in
                    let dockTimestampKey = "dock_\(station.id)_timestamp"
                    userDefaults.set(timestamp, forKey: dockTimestampKey)
                }
                
                userDefaults.synchronize()
                
                // Kick WidgetKit to pick up the fresh data
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
            }
        }
    }
    
    private func fetchBikePoints(ids: [String], aliases: [String: String]) async -> [WidgetBikePoint] {
        await withTaskGroup(of: WidgetBikePoint?.self) { group in
            for id in ids {
                group.addTask {
                    guard let url = URL(string: "https://api.tfl.gov.uk/BikePoint/\(id)") else { return nil }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let apiBikePoint = try JSONDecoder().decode(APIBikePoint.self, from: data)
                        let alias = aliases[id]
                        return apiBikePoint.toWidgetBikePoint(alias: alias)
                    } catch {
                        return nil
                    }
                }
            }
            
            var results: [WidgetBikePoint] = []
            for await result in group {
                if let station = result {
                    results.append(station)
                }
            }
            return results
        }
    }
}

// Helper struct for decoding favorites
struct FavoriteBikePoint: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let sortOrder: Int
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return commonName
    }
}

// MARK: - Colors matching app theme
struct WidgetColors {
    static let standardBike = Color(red: 236/255, green: 0/255, blue: 0/255)
    static let eBike = Color(red: 12/255, green: 17/255, blue: 177/255)
    static let emptySpace = Color(red: 117/255, green: 117/255, blue: 117/255)
}

// MARK: - Configuration Intent for Configurable Widget
@available(iOS 16.0, watchOS 9.0, *)
struct ConfigurableDockEntity: AppEntity {
    let id: String
    let name: String
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock"
    static var defaultQuery = ConfigurableDockQuery()
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct ConfigurableDockQuery: EntityQuery {
    func entities(for identifiers: [ConfigurableDockEntity.ID]) async throws -> [ConfigurableDockEntity] {
        let favorites = loadFavoritesForConfiguration()
        return favorites.filter { identifiers.contains($0.id) }
    }
    
    func suggestedEntities() async throws -> [ConfigurableDockEntity] {
        let entities = loadFavoritesForConfiguration()
        
        // If no favorites are available, return a placeholder to ensure widget appears in picker
        if entities.isEmpty {
            return [ConfigurableDockEntity(id: "no-favorites", name: "Add favorites in the main app")]
        }
        
        // Return suggested entities
        return entities
    }
    
    func defaultResult() async -> ConfigurableDockEntity? {
        let favorites = loadFavoritesForConfiguration()
        if favorites.isEmpty {
            return ConfigurableDockEntity(id: "no-favorites", name: "Add favorites in the main app")
        }
        return favorites.first
    }
    
    private func loadFavoritesForConfiguration() -> [ConfigurableDockEntity] {
        
        let appGroup = "group.dev.skynolimit.myborisbikes"
        
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return []
        }
        
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        guard let data = userDefaults.data(forKey: "favorites") else {
            return []
        }
        
        
        do {
            let favorites = try JSONDecoder().decode([FavoriteBikePoint].self, from: data)
            
            // Log each favorite
            favorites.forEach { favorite in
            }
            
            // Convert to ConfigurableDockEntity and sort alphabetically by name
            let entities = favorites
                .map { ConfigurableDockEntity(id: $0.id, name: $0.displayName) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            entities.forEach { entity in
            }
            
            return entities
            
        } catch {
            return []
        }
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct ConfigurableDockIntent: WidgetConfigurationIntent, AppIntent {
    static var title: LocalizedStringResource = "Choose Dock"
    static var description = IntentDescription("Choose which dock to display")
    
    @Parameter(title: "Dock", description: "Select a dock to display")
    var dock: ConfigurableDockEntity?
    
    init(dock: ConfigurableDockEntity? = nil) {
        self.dock = dock
    }
    
    init() {
        self.dock = nil
    }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - App Intent Configuration Refresh Helper
@available(iOS 16.0, watchOS 9.0, *)
struct ConfigurableDockRefreshManager {
    static func invalidateConfigurableWidgetRecommendations() {
        
        // Force reload of all configurable dock widgets to refresh their configuration options
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesConfigurableDockCircularComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesConfigurableDockRectangularComplication")
        
        // Force refresh of all widget timelines to pick up configuration changes
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
        }
        
    }
    
    static func startObservingFavoritesChanges() {
        
        // Remove any existing observers first to avoid duplicates
        NotificationCenter.default.removeObserver(self, name: .favoritesDidChange, object: nil)
        
        NotificationCenter.default.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { notification in
            
            // Immediate refresh
            invalidateConfigurableWidgetRecommendations()
            
            // Also trigger refreshes with delays to ensure data is propagated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                invalidateConfigurableWidgetRecommendations()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                invalidateConfigurableWidgetRecommendations()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                invalidateConfigurableWidgetRecommendations()
            }
        }
        
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let favoritesDidChange = Notification.Name("favoritesDidChange")
}

// MARK: - Timeline Provider
struct BorisBikesTimelineProvider: TimelineProvider {
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    
    init() {
    }
    
    func placeholder(in context: Context) -> BorisBikesEntry {
        return BorisBikesEntry(
            date: Date(),
            closestStation: WidgetBikePoint(
                id: "placeholder",
                commonName: "PLACEHOLDER",
                alias: nil,
                standardBikes: 1,
                eBikes: 1,
                emptySpaces: 1,
                distance: nil
            ),
            error: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BorisBikesEntry) -> ()) {
        let entry = loadCurrentData()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BorisBikesEntry>) -> ()) {
        var entries: [BorisBikesEntry] = []
        let currentDate = Date()
        
        // Create current entry
        let currentEntry = loadCurrentData()
        entries.append(currentEntry)
        
        // Determine refresh strategy based on data staleness and errors
        let (refreshInterval, policyInterval) = determineRefreshStrategy(for: currentEntry)
        
        // Create entries for next period with appropriate intervals
        let maxEntries = min(20, (5 * 60) / refreshInterval) // Cap at 20 entries or 5 minutes worth
        for i in 1...maxEntries {
            let entryDate = Calendar.current.date(byAdding: .second, value: i * refreshInterval, to: currentDate)!
            let entry = BorisBikesEntry(
                date: entryDate,
                closestStation: currentEntry.closestStation,
                error: currentEntry.error
            )
            entries.append(entry)
        }
        
        // Set timeline policy based on data freshness
        let nextUpdate = Calendar.current.date(byAdding: .second, value: policyInterval, to: currentDate)!
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        
        completion(timeline)
    }
    
    /// Gets last known good data for main widget during update locks
    private func getLastKnownGoodDataFromMainWidget() -> WidgetBikePoint? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return nil }
        
        guard let lastKnownGoodData = userDefaults.data(forKey: "widget_last_known_good_data") else {
            return nil
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: "widget_last_known_good_timestamp")
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
    
    /// Determines refresh strategy based on data freshness and connection status
    private func determineRefreshStrategy(for entry: BorisBikesEntry) -> (entryInterval: Int, policyInterval: Int) {
        // Check data age to determine refresh aggressiveness
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            // No app group access - use aggressive refresh to try to recover
            return (10, 15)
        }
        
        let dataTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
        let dataAge = Date().timeIntervalSince1970 - dataTimestamp
        
        // Determine if we have an error condition
        let hasError = entry.error != nil && entry.error != ""
        let hasStaleData = dataAge > 120 // Data older than 2 minutes
        let hasNoData = entry.closestStation == nil
        
        
        // Check if this is startup scenario to avoid aggressive refreshes
        let isStartup = dataTimestamp == 0
        
        if hasNoData || hasError {
            if isStartup {
                // During startup, use longer intervals to let initial data load complete
                return (120, 180)
            } else {
                // No data or error - moderate refresh to avoid rate limiting
                requestCacheBustedRefresh(reason: "No data or error")
                return (60, 90)
            }
        } else if hasStaleData {
            // Stale data - moderate refresh to avoid overwhelming API
            requestCacheBustedRefresh(reason: "Stale data (age: \(Int(dataAge))s)")
            return (90, 120)
        } else if dataAge > 60 {
            // Somewhat old data - normal refresh
            return (60, 90)
        } else {
            // Fresh data - normal refresh
            return (60, 60)
        }
    }
    
    /// Requests that the main app perform a cache-busted refresh
    private func requestCacheBustedRefresh(reason: String) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        let requestKey = "cache_busted_refresh_request"
        let request: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "reason": reason,
            "source": "widget_timeline"
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            userDefaults.set(data, forKey: requestKey)
        } catch {
        }
    }
    
    private func loadCurrentData() -> BorisBikesEntry {
        
        // Note: Update locks removed to prevent data drought during refreshes
        
        
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return BorisBikesEntry(
                date: Date(),
                closestStation: WidgetBikePoint(
                    id: "no-access",
                    commonName: "No App Group Access",
                    alias: nil,
                    standardBikes: 0,
                    eBikes: 0,
                    emptySpaces: 0,
                    distance: nil
                ),
                error: "No app group access"
            )
        }
        
        
        let allKeys = userDefaults.dictionaryRepresentation().keys

        // Read the data timestamp so the complication can display when data was last fetched
        let rawTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
        let dataTimestamp: Date? = rawTimestamp > 0 ? Date(timeIntervalSince1970: rawTimestamp) : nil

        // Get favorites from UserDefaults
        guard let favoritesData = userDefaults.data(forKey: "favorites") else {

            // Check for last known good data before showing error
            if let fallbackStation = getLastKnownGoodDataFromWidget() {
                return BorisBikesEntry(date: Date(), closestStation: fallbackStation, error: nil, dataTimestamp: dataTimestamp)
            }

            return BorisBikesEntry(date: Date(), closestStation: nil, error: "No favorites data")
        }


        guard let favorites = try? JSONDecoder().decode([FavoriteBikePoint].self, from: favoritesData) else {
            return BorisBikesEntry(date: Date(), closestStation: nil, error: "Invalid favorites data")
        }

        // Trigger a background refresh if stored data may be stale
        WidgetDataRefresher.shared.refreshIfNeeded(favorites: favorites)

        guard !favorites.isEmpty else {

            // Check for last known good data before showing error
            if let fallbackStation = getLastKnownGoodDataFromWidget() {
                return BorisBikesEntry(date: Date(), closestStation: fallbackStation, error: nil, dataTimestamp: dataTimestamp)
            }

            return BorisBikesEntry(date: Date(), closestStation: nil, error: "No favorites found")
        }


        // Try to get cached bike point data from shared file first
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let fileURL = containerURL.appendingPathComponent("widget_data.json")

            if let fileData = try? Data(contentsOf: fileURL) {
                if let cachedStation = try? JSONDecoder().decode(WidgetBikePoint.self, from: fileData) {
                    return BorisBikesEntry(date: Date(), closestStation: cachedStation, error: nil, dataTimestamp: dataTimestamp)
                }
            }
        }

        // Fallback to UserDefaults
        if let cachedData = userDefaults.data(forKey: "widget_closest_station") {
            if let cachedStation = try? JSONDecoder().decode(WidgetBikePoint.self, from: cachedData) {
                return BorisBikesEntry(date: Date(), closestStation: cachedStation, error: nil, dataTimestamp: dataTimestamp)
            }
        }

        // Before showing error, check for last known good data (fallback for transient network issues)
        if let fallbackStation = getLastKnownGoodDataFromWidget() {
            return BorisBikesEntry(date: Date(), closestStation: fallbackStation, error: nil, dataTimestamp: dataTimestamp)
        }


        // Fallback: use first favorite with placeholder data BUT NO ERROR to avoid exclamation mark
        let firstFavorite = favorites.first!

        let widgetStation = WidgetBikePoint(
            id: firstFavorite.id,
            commonName: firstFavorite.commonName,
            alias: firstFavorite.alias,
            standardBikes: 0, // No data available
            eBikes: 0,
            emptySpaces: 0,
            distance: nil
        )

        return BorisBikesEntry(date: Date(), closestStation: widgetStation, error: nil)
    }
    
    // Check if data has changed since last update
    private func hasDataChanged() -> Bool {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return false }
        
        let currentTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
        let lastKnownTimestamp = userDefaults.double(forKey: "widget_last_update_timestamp")
        
        return currentTimestamp != lastKnownTimestamp
    }
    
    // Mark that we've processed the latest data
    private func markDataAsProcessed() {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        let currentTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
        userDefaults.set(currentTimestamp, forKey: "widget_last_update_timestamp")
    }
    
    // Helper function to get last known good data for fallback during transient network issues
    private func getLastKnownGoodDataFromWidget() -> WidgetBikePoint? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return nil }
        
        guard let lastKnownGoodData = userDefaults.data(forKey: "widget_last_known_good_data") else {
            return nil
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: "widget_last_known_good_timestamp")
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
    
    /// Gets last known good configurable widget data during update locks
    private func getLastKnownGoodConfigurableData() -> [WidgetBikePoint]? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return nil }
        
        guard let lastKnownGoodData = userDefaults.data(forKey: "bikepoints_last_known_good") else {
            return nil
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: "bikepoints_last_known_good_timestamp")
        let dataAge = Date().timeIntervalSince1970 - lastKnownGoodTimestamp
        
        // Only use fallback data if it's less than 10 minutes old
        guard dataAge < 600 else {
            return nil
        }
        
        do {
            let fallbackStations = try JSONDecoder().decode([WidgetBikePoint].self, from: lastKnownGoodData)
            return fallbackStations
        } catch {
            return nil
        }
    }
}

// MARK: - Configurable Timeline Provider
@available(iOS 16.0, watchOS 9.0, *)
struct ConfigurableDockTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = BorisBikesEntry
    typealias Intent = ConfigurableDockIntent

    private let appGroup = "group.dev.skynolimit.myborisbikes"

    init() {
    }

    func placeholder(in context: Context) -> Entry {
        BorisBikesEntry(
            date: Date(),
            closestStation: WidgetBikePoint(
                id: "placeholder",
                commonName: "Select Dock",
                alias: nil,
                standardBikes: 1,
                eBikes: 1,
                emptySpaces: 1,
                distance: nil
            ),
            error: nil
        )
    }

    func snapshot(for configuration: ConfigurableDockIntent, in context: Context) async -> Entry {
        return loadDataForDock(configuration.dock)
    }

    func timeline(for configuration: ConfigurableDockIntent, in context: Context) async -> Timeline<Entry> {

        var entries: [Entry] = []
        let currentDate = Date()

        // Load current data
        let currentEntry = loadDataForDock(configuration.dock)
        entries.append(currentEntry)

        // Determine refresh strategy based on data staleness
        let (refreshInterval, policyInterval) = determineConfigurableRefreshStrategy(for: currentEntry, dock: configuration.dock)

        // Create entries for next period with appropriate intervals
        let maxEntries = min(20, (5 * 60) / refreshInterval)
        for i in 1...maxEntries {
            if let entryDate = Calendar.current.date(byAdding: .second, value: i * refreshInterval, to: currentDate) {
                entries.append(
                    BorisBikesEntry(
                        date: entryDate,
                        closestStation: currentEntry.closestStation,
                        error: currentEntry.error
                    )
                )
            }
        }

        let nextUpdate = Calendar.current.date(byAdding: .second, value: policyInterval, to: currentDate)!
        return Timeline(entries: entries, policy: .after(nextUpdate))
    }
    
    /// Determines refresh strategy for configurable dock widgets based on data freshness
    private func determineConfigurableRefreshStrategy(for entry: BorisBikesEntry, dock: ConfigurableDockEntity?) -> (entryInterval: Int, policyInterval: Int) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return (10, 15)
        }
        
        // Check individual dock timestamp if available
        var dataAge: TimeInterval = Double.greatestFiniteMagnitude
        if let dock = dock {
            let dockTimestampKey = "dock_\(dock.id)_timestamp"
            let dockTimestamp = userDefaults.double(forKey: dockTimestampKey)
            if dockTimestamp > 0 {
                dataAge = Date().timeIntervalSince1970 - dockTimestamp
            }
        }
        
        // Fallback to general widget data timestamp
        if dataAge == Double.greatestFiniteMagnitude {
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            if generalTimestamp > 0 {
                dataAge = Date().timeIntervalSince1970 - generalTimestamp
            } else {
                dataAge = 300 // Assume very stale if no timestamp
            }
        }
        
        let hasError = entry.error != nil && entry.error != ""
        let hasStaleData = dataAge > 120
        let hasNoData = entry.closestStation == nil
        
        
        if hasNoData || hasError {
            requestCacheBustedRefreshForConfigurable(reason: "No data or error", dockName: dock?.name)
            return (30, 45)
        } else if hasStaleData {
            requestCacheBustedRefreshForConfigurable(reason: "Stale data (age: \(Int(dataAge))s)", dockName: dock?.name)
            return (45, 60)
        } else if dataAge > 60 {
            return (30, 45)
        } else {
            return (30, 30)
        }
    }
    
    /// Requests that the main app perform a cache-busted refresh for configurable widgets
    private func requestCacheBustedRefreshForConfigurable(reason: String, dockName: String?) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        let requestKey = "cache_busted_refresh_request"
        let request: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "reason": reason,
            "source": "configurable_widget",
            "dock": dockName ?? "unknown"
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            userDefaults.set(data, forKey: requestKey)
        } catch {
        }
    }

    func recommendations() -> [AppIntentRecommendation<ConfigurableDockIntent>] {
        
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return []
        }
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        guard let data = userDefaults.data(forKey: "favorites") else {
            return []
        }
        
        
        do {
            let favorites = try JSONDecoder().decode([FavoriteBikePoint].self, from: data)
            
            let recommendations = favorites.map { favorite in
                let entity = ConfigurableDockEntity(id: favorite.id, name: favorite.displayName)
                let intent = ConfigurableDockIntent(dock: entity)
                return AppIntentRecommendation(intent: intent, description: favorite.displayName)
            }
            
            favorites.forEach { favorite in
            }
            
            return recommendations
            
        } catch {
            
            if let rawString = String(data: data, encoding: .utf8) {
            }
            
            return []
        }
    }

    private func loadDataForDock(_ selectedDock: ConfigurableDockEntity?) -> Entry {
        guard let dock = selectedDock else {
            return BorisBikesEntry(
                date: Date(),
                closestStation: WidgetBikePoint(
                    id: "noDock",
                    commonName: "No Dock Selected",
                    alias: nil,
                    standardBikes: 0,
                    eBikes: 0,
                    emptySpaces: 0,
                    distance: nil
                ),
                error: "No dock selected"
            )
        }

        // Handle the case when no favorites are configured
        if dock.id == "no-favorites" {
            return BorisBikesEntry(
                date: Date(),
                closestStation: nil,
                error: "Add favorites in the main app first"
            )
        }

        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return BorisBikesEntry(
                date: Date(),
                closestStation: nil,
                error: "No app group access"
            )
        }
        
        if let favoritesData = userDefaults.data(forKey: "favorites"),
           let favorites = try? JSONDecoder().decode([FavoriteBikePoint].self, from: favoritesData) {
            WidgetDataRefresher.shared.refreshIfNeeded(favorites: favorites)
        }
        
        // Try to get current data first
        var bikePoints: [WidgetBikePoint] = []
        if let data = userDefaults.data(forKey: "bikepoints"),
           let currentBikePoints = try? JSONDecoder().decode([WidgetBikePoint].self, from: data) {
            bikePoints = currentBikePoints
        } else {
            // No current data - check for last known good data
            if let fallbackData = userDefaults.data(forKey: "bikepoints_last_known_good") {
                let fallbackTimestamp = userDefaults.double(forKey: "bikepoints_last_known_good_timestamp")
                let dataAge = Date().timeIntervalSince1970 - fallbackTimestamp
                
                // Only use fallback data if it's less than 10 minutes old
                if dataAge < 600, 
                   let fallbackBikePoints = try? JSONDecoder().decode([WidgetBikePoint].self, from: fallbackData) {
                    bikePoints = fallbackBikePoints
                }
            }
            
            // Still no data available
            if bikePoints.isEmpty {
                return BorisBikesEntry(
                    date: Date(),
                    closestStation: nil,
                    error: "No bike point data available"
                )
            }
        }

        if let station = bikePoints.first(where: { $0.id == dock.id }) {
            return BorisBikesEntry(date: Date(), closestStation: station, error: nil)
        } else {
            return BorisBikesEntry(date: Date(), closestStation: nil, error: "Dock not found")
        }
    }
}

// MARK: - Simple Widget Manager for Extension
@available(iOS 16.0, watchOS 9.0, *)
class SimpleWidgetManager {
    static let shared = SimpleWidgetManager()
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let widgetConfigPrefix = "widget_dock_"
    
    private init() {}
    
    func getSelectedDockId(for configurationId: String) -> String? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return nil
        }
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let widgetKeys = allKeys.filter { $0.hasPrefix(widgetConfigPrefix) }
        
        let key = widgetConfigPrefix + configurationId
        let selectedId = userDefaults.string(forKey: key)
        
        
        return selectedId
    }
}

// MARK: - Custom Dock Timeline Provider
@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockTimelineProvider: TimelineProvider {
    typealias Entry = BorisBikesEntry
    
    let widgetId: String
    private let appGroup = "group.dev.skynolimit.myborisbikes"

    init(widgetId: String) {
        self.widgetId = widgetId
    }

    func placeholder(in context: Context) -> Entry {
        BorisBikesEntry(
            date: Date(),
            closestStation: WidgetBikePoint(
                id: "placeholder",
                commonName: "Custom Dock \(widgetId)",
                alias: nil,
                standardBikes: 1,
                eBikes: 1,
                emptySpaces: 1,
                distance: nil
            ),
            error: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> ()) {
        let entry = loadDataForWidget()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {

        var entries: [Entry] = []
        let currentDate = Date()

        // Load current data
        let currentEntry = loadDataForWidget()
        entries.append(currentEntry)

        // Determine refresh strategy based on data staleness
        let (refreshInterval, policyInterval) = determineInteractiveRefreshStrategy(for: currentEntry)

        // Create entries for next period with appropriate intervals
        let maxEntries = min(20, (5 * 60) / refreshInterval)
        for i in 1...maxEntries {
            if let entryDate = Calendar.current.date(byAdding: .second, value: i * refreshInterval, to: currentDate) {
                entries.append(
                    BorisBikesEntry(
                        date: entryDate,
                        closestStation: currentEntry.closestStation,
                        error: currentEntry.error
                    )
                )
            }
        }

        let nextUpdate = Calendar.current.date(byAdding: .second, value: policyInterval, to: currentDate)!
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
    
    /// Determines refresh strategy for interactive dock widgets based on data freshness
    private func determineInteractiveRefreshStrategy(for entry: BorisBikesEntry) -> (entryInterval: Int, policyInterval: Int) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            // No app group access - be very aggressive
            return (5, 10)
        }
        
        // Check if this is showing placeholder "Custom Dock" data
        let isShowingPlaceholder = entry.closestStation?.displayName.contains("Custom Dock") == true
        
        if isShowingPlaceholder {
            // VERY aggressive refresh for placeholder data to get real data ASAP
            requestCacheBustedRefreshForInteractive(reason: "Showing placeholder Custom Dock data", widgetId: widgetId)
            return (5, 10) // Refresh every 5-10 seconds until we get real data
        }
        
        // Check dock-specific timestamp for this widget
        let dockTimestampKey = "dock_\(widgetId)_timestamp"
        let dockTimestamp = userDefaults.double(forKey: dockTimestampKey)
        
        var dataAge: TimeInterval = 300 // Default to very stale
        if dockTimestamp > 0 {
            dataAge = Date().timeIntervalSince1970 - dockTimestamp
        } else {
            // Fallback to general widget timestamp
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            if generalTimestamp > 0 {
                dataAge = Date().timeIntervalSince1970 - generalTimestamp
            }
        }
        
        let hasError = entry.error != nil && entry.error != ""
        let hasStaleData = dataAge > 60 // Reduced from 120 to 60 seconds
        let hasNoData = entry.closestStation == nil
        
        if hasNoData || hasError {
            requestCacheBustedRefreshForInteractive(reason: "No data or error", widgetId: widgetId)
            return (10, 15) // More aggressive than before
        } else if hasStaleData {
            requestCacheBustedRefreshForInteractive(reason: "Stale data (age: \(Int(dataAge))s)", widgetId: widgetId)
            return (15, 30) // More aggressive than before
        } else if dataAge > 30 {
            return (30, 45) // More aggressive refresh
        } else {
            return (45, 60) // Normal refresh when data is fresh
        }
    }
    
    /// Requests that the main app perform a cache-busted refresh for interactive widgets
    private func requestCacheBustedRefreshForInteractive(reason: String, widgetId: String) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        let requestKey = "cache_busted_refresh_request"
        let request: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "reason": reason,
            "source": "interactive_widget",
            "widget_id": widgetId
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            userDefaults.set(data, forKey: requestKey)
        } catch {
        }
    }

    private func loadDataForWidget() -> BorisBikesEntry {
        // Note: Update locks removed to prevent data drought during refreshes
        
        // Check if this widget has a configured dock
        let selectedDockId = SimpleWidgetManager.shared.getSelectedDockId(for: widgetId)
        
        guard let dockId = selectedDockId else {
            // Widget not configured yet
            return BorisBikesEntry(
                date: Date(),
                closestStation: WidgetBikePoint(
                    id: "not-configured",
                    commonName: "Custom Dock \(widgetId)",
                    alias: nil,
                    standardBikes: 0,
                    eBikes: 0,
                    emptySpaces: 0,
                    distance: nil
                ),
                error: "Tap to configure"
            )
        }

        // Load bike point data for the configured dock
        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            return BorisBikesEntry(
                date: Date(),
                closestStation: WidgetBikePoint(
                    id: dockId,
                    commonName: "Custom Dock \(widgetId)",
                    alias: nil,
                    standardBikes: 0,
                    eBikes: 0,
                    emptySpaces: 0,
                    distance: nil
                ),
                error: "No app group access"
            )
        }
        
        if let favoritesData = userDefaults.data(forKey: "favorites"),
           let favorites = try? JSONDecoder().decode([FavoriteBikePoint].self, from: favoritesData) {
            WidgetDataRefresher.shared.refreshIfNeeded(favorites: favorites)
        }
        
        // Try to get current data first
        var bikePoints: [WidgetBikePoint] = []
        if let data = userDefaults.data(forKey: "bikepoints"),
           let currentBikePoints = try? JSONDecoder().decode([WidgetBikePoint].self, from: data) {
            bikePoints = currentBikePoints
        } else {
            // No current data - check for last known good data
            if let fallbackData = userDefaults.data(forKey: "bikepoints_last_known_good") {
                let fallbackTimestamp = userDefaults.double(forKey: "bikepoints_last_known_good_timestamp")
                let dataAge = Date().timeIntervalSince1970 - fallbackTimestamp
                
                // Only use fallback data if it's less than 10 minutes old
                if dataAge < 600, 
                   let fallbackBikePoints = try? JSONDecoder().decode([WidgetBikePoint].self, from: fallbackData) {
                    bikePoints = fallbackBikePoints
                }
            }
            
            // Still no data available
            if bikePoints.isEmpty {
                return BorisBikesEntry(
                    date: Date(),
                    closestStation: WidgetBikePoint(
                        id: dockId,
                        commonName: "Custom Dock \(widgetId)",
                        alias: nil,
                        standardBikes: 0,
                        eBikes: 0,
                        emptySpaces: 0,
                        distance: nil
                    ),
                    error: "No data available"
                )
            }
        }

        
        if let station = bikePoints.first(where: { $0.id == dockId }) {
            return BorisBikesEntry(date: Date(), closestStation: station, error: nil)
        } else {
            let availableIds = bikePoints.map { $0.id }
            
            return BorisBikesEntry(
                date: Date(),
                closestStation: WidgetBikePoint(
                    id: dockId,
                    commonName: "Custom Dock \(widgetId)",
                    alias: nil,
                    standardBikes: 0,
                    eBikes: 0,
                    emptySpaces: 0,
                    distance: nil
                ),
                error: "Dock not found"
            )
        }
    }
    
    /// Gets last known good configurable widget data during update locks
    private func getLastKnownGoodConfigurableData() -> [WidgetBikePoint]? {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return nil }
        
        guard let lastKnownGoodData = userDefaults.data(forKey: "bikepoints_last_known_good") else {
            return nil
        }
        
        let lastKnownGoodTimestamp = userDefaults.double(forKey: "bikepoints_last_known_good_timestamp")
        let dataAge = Date().timeIntervalSince1970 - lastKnownGoodTimestamp
        
        // Only use fallback data if it's less than 10 minutes old
        guard dataAge < 600 else {
            return nil
        }
        
        do {
            let fallbackStations = try JSONDecoder().decode([WidgetBikePoint].self, from: lastKnownGoodData)
            return fallbackStations
        } catch {
            return nil
        }
    }
}

// MARK: - Custom Dock Widget View
@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidgetView: View {
    let entry: BorisBikesEntry
    let widgetId: String

    init(entry: BorisBikesEntry, widgetId: String) {
        self.entry = entry
        self.widgetId = widgetId
    }

    var body: some View {
        Group {
            if let station = entry.closestStation {
                if entry.error == "Tap to configure" {
                    VStack(spacing: 2) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                        
                        Text("Dock \(widgetId)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .widgetURL(URL(string: "myborisbikes://configure-widget/\(widgetId)"))
                } else {
                    ZStack {
                        WidgetDonutChart(
                            standardBikes: station.standardBikes,
                            eBikes: station.eBikes,
                            emptySpaces: station.emptySpaces,
                            name: station.displayName,
                            size: 40
                        )
                    }
                    .widgetURL(URL(string: "myborisbikes://custom-dock/\(widgetId)/\(station.id)"))
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundColor(.red)
                    
                    Text("No data")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .widgetURL(URL(string: "myborisbikes://configure-widget/\(widgetId)"))
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Donut Chart Widget View
struct WidgetDonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let name: String
    let size: CGFloat

    // Reads the same key the phone app writes so the complication honours the user's preference
    @AppStorage(WidgetBikeFilter.userDefaultsKey, store: WidgetBikeFilter.store)
    private var filterRawValue: String = WidgetBikeFilter.both.rawValue

    private var filter: WidgetBikeFilter {
        WidgetBikeFilter(rawValue: filterRawValue) ?? .both
    }

    // Apply filter — empty spaces are always shown regardless of bike-type preference
    private var displayedStandard: Int { filter.visibleStandard(standardBikes) }
    private var displayedEBike: Int    { filter.visibleEBike(eBikes) }
    private var displayedEmpty: Int    { emptySpaces }

    private let strokeWidth: CGFloat = 6

    init(standardBikes: Int, eBikes: Int, emptySpaces: Int, name: String, size: CGFloat) {
        self.standardBikes = standardBikes
        self.eBikes = eBikes
        self.emptySpaces = emptySpaces
        self.name = name
        self.size = size
    }

    private var total: Int { displayedStandard + displayedEBike + displayedEmpty }

    private var standardPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(displayedStandard) / Double(total)
    }

    private var eBikePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(displayedEBike) / Double(total)
    }

    private var hasData: Bool { total > 0 }

    var body: some View {
        ZStack {
            // If no data is available, show a "refreshing" indicator
            if !hasData {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundColor(.secondary)
            } else {
                // Background circle (empty spaces)
                Circle()
                    .stroke(WidgetColors.emptySpace.opacity(0.4), lineWidth: strokeWidth)
                    .frame(width: size, height: size)

                // E-bikes section (blue) - outer layer
                if displayedEBike > 0 {
                    Circle()
                        .trim(from: 0, to: eBikePercentage + standardPercentage)
                        .stroke(WidgetColors.eBike, lineWidth: strokeWidth)
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                }

                // Standard bikes section (red) - inner layer
                if displayedStandard > 0 {
                    Circle()
                        .trim(from: 0, to: standardPercentage)
                        .stroke(WidgetColors.standardBike, lineWidth: strokeWidth)
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                }

                // Center: first 2 initials of the dock name
                let initials = name
                    .split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { $0.first }
                    .map { String($0) }
                    .joined()
                    .prefix(2)

                VStack(spacing: 0) {
                    Text(initials)
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Bike data filter (mirrored from watch app — reads same UserDefaults key)
// "both" = show standard + e-bikes, "bikesOnly" = standard only, "eBikesOnly" = e-bikes only
fileprivate enum WidgetBikeFilter: String {
    case both, bikesOnly, eBikesOnly

    static let userDefaultsKey = "bikeDataFilter"
    static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var store: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    var showsStandard: Bool { self != .eBikesOnly }
    var showsEBike: Bool    { self != .bikesOnly }

    func visibleStandard(_ n: Int) -> Int { showsStandard ? n : 0 }
    func visibleEBike(_ n: Int) -> Int    { showsEBike    ? n : 0 }
}

// MARK: - Rectangular Widget View
struct BorisBikesRectangularComplicationView: View {
    var entry: BorisBikesTimelineProvider.Entry

    @AppStorage(WidgetBikeFilter.userDefaultsKey, store: WidgetBikeFilter.store)
    private var filterRawValue: String = WidgetBikeFilter.both.rawValue

    private var filter: WidgetBikeFilter {
        WidgetBikeFilter(rawValue: filterRawValue) ?? .both
    }

    var body: some View {
        Group {
            if let station = entry.closestStation {
                VStack(alignment: .leading, spacing: 3) {
                    // Top row: donut chart left, dock name right
                    HStack(alignment: .center, spacing: 6) {
                        WidgetDonutChart(
                            standardBikes: station.standardBikes,
                            eBikes: station.eBikes,
                            emptySpaces: station.emptySpaces,
                            name: station.displayName,
                            size: 28
                        )

                        Text(station.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                        Spacer(minLength: 4)
                        if let ts = entry.dataTimestamp {
                            Text(ts, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }

                    // Bottom row: availability labels + last updated time (for debugging)
                    HStack(alignment: .center, spacing: 0) {
                        RectangularWidgetLegend(
                            standardBikes: station.standardBikes,
                            eBikes: station.eBikes,
                            emptySpaces: station.emptySpaces,
                            filter: filter
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            } else if entry.error != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Data")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)

                        Text("Tap to refresh")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading...")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
    
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)

                        Text("Getting data")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}

fileprivate struct RectangularWidgetLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let filter: WidgetBikeFilter

    var body: some View {
        HStack(spacing: 8) {
            if filter.showsStandard {
                RectangularLegendItem(
                    color: WidgetColors.standardBike,
                    count: filter.visibleStandard(standardBikes),
                    label: "bikes"
                )
            }
            if filter.showsEBike {
                RectangularLegendItem(
                    color: WidgetColors.eBike,
                    count: filter.visibleEBike(eBikes),
                    label: "e-bikes"
                )
            }
            RectangularLegendItem(color: WidgetColors.emptySpace, count: emptySpaces, label: "spaces")
        }
    }
}

struct RectangularLegendItem: View {
    let color: Color
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(count) \(label)")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}






struct BorisBikesCircularComplicationView: View {
    var entry: BorisBikesTimelineProvider.Entry

    init(entry: BorisBikesTimelineProvider.Entry) {
        self.entry = entry
    }

    var body: some View {
        Group {
            if let station = entry.closestStation {
                if #available(iOS 16.0, watchOS 9.0, *) {
                    ZStack {
                        WidgetDonutChart(
                            standardBikes: station.standardBikes,
                            eBikes: station.eBikes,
                            emptySpaces: station.emptySpaces,
                            name: station.displayName,
                            size: 40
                        )
                    }
                    .widgetURL(URL(string: "myborisbikes://dock/\(station.id)"))
                } else {
                    ZStack {
                        WidgetDonutChart(
                            standardBikes: station.standardBikes,
                            eBikes: station.eBikes,
                            emptySpaces: station.emptySpaces,
                            name: station.displayName,
                            size: 40
                        )
                    }
                }
            } else if entry.error != nil {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.orange)
                    
                    Text("No data")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .onAppear {
                }
            } else {
                // Loading state
                VStack(spacing: 2) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    Text("Loading")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .onAppear {
        }
    }
}

@main
struct MyBorisBikesWidgetBundle: WidgetBundle {
    init() {
        
        // Start observing favorites changes for automatic configuration updates
        if #available(iOS 16.0, watchOS 9.0, *) {
            ConfigurableDockRefreshManager.startObservingFavoritesChanges()
        }
    }
    
    var body: some Widget {
        MyBorisBikesClosestDockCircularComplication()
        MyBorisBikesClosestDockRectangularComplication()
        MyBorisBikesSimpleComplication()
        if #available(iOS 16.0, watchOS 9.0, *) {
            CustomDockWidget1()
            CustomDockWidget2()
            CustomDockWidget3()
            CustomDockWidget4()
            CustomDockWidget5()
            CustomDockWidget6()
        }
    }
}

struct MyBorisBikesClosestDockCircularComplication: Widget {
    let kind: String = "MyBorisBikesClosestDockCircularComplication"
    
    init() {
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BorisBikesTimelineProvider()) { entry in
            BorisBikesCircularComplicationView(entry: entry)
        }
        .configurationDisplayName("Closest Favourite")
        .description("Shows closest favorite dock with bike availability")
        .supportedFamilies([.accessoryCircular])
    }
}

struct MyBorisBikesClosestDockRectangularComplication: Widget {
    let kind: String = "MyBorisBikesClosestDockRectangularComplication"
    
    init() {
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BorisBikesTimelineProvider()) { entry in
            BorisBikesRectangularComplicationView(entry: entry)
                .widgetURL(entry.closestStation != nil ? URL(string: "myborisbikes://dock/\(entry.closestStation!.id)") : nil)
        }
        .configurationDisplayName("Closest Favourite Detail")
        .description("Shows closest favorite dock with detailed bike availability")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Simple Launcher Complication
struct SimpleBorisBikesTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BorisBikesEntry {
        BorisBikesEntry(date: Date(), closestStation: nil, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BorisBikesEntry) -> ()) {
        let entry = BorisBikesEntry(date: Date(), closestStation: nil, error: nil)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BorisBikesEntry>) -> ()) {
        let currentDate = Date()
        
        // Simple timeline with just one entry that refreshes every hour
        let entry = BorisBikesEntry(date: currentDate, closestStation: nil, error: nil)
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        
        completion(timeline)
    }
}

struct BorisBikesSimpleComplicationView: View {
    var entry: SimpleBorisBikesTimelineProvider.Entry

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "bicycle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.red)
        }
        .containerBackground(.clear, for: .widget)
    }
}

struct MyBorisBikesSimpleComplication: Widget {
    let kind: String = "MyBorisBikesSimpleComplication"

    init() {
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SimpleBorisBikesTimelineProvider()) { entry in
            BorisBikesSimpleComplicationView(entry: entry)
        }
        .configurationDisplayName("View Favorites")
        .description("Tap to open My Boris Bikes app")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Custom Dock Widgets (6 widgets)

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget1: Widget {
    let kind: String = "CustomDockWidget1"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "1")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "1")
        }
        .configurationDisplayName("Custom Dock 1")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget2: Widget {
    let kind: String = "CustomDockWidget2"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "2")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "2")
        }
        .configurationDisplayName("Custom Dock 2")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget3: Widget {
    let kind: String = "CustomDockWidget3"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "3")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "3")
        }
        .configurationDisplayName("Custom Dock 3")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget4: Widget {
    let kind: String = "CustomDockWidget4"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "4")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "4")
        }
        .configurationDisplayName("Custom Dock 4")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget5: Widget {
    let kind: String = "CustomDockWidget5"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "5")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "5")
        }
        .configurationDisplayName("Custom Dock 5")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct CustomDockWidget6: Widget {
    let kind: String = "CustomDockWidget6"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CustomDockTimelineProvider(widgetId: "6")) { entry in
            CustomDockWidgetView(entry: entry, widgetId: "6")
        }
        .configurationDisplayName("Custom Dock 6")
        .description("Configurable dock widget - tap to set up your preferred dock")
        .supportedFamilies([.accessoryCircular])
    }
}

#Preview(as: .accessoryCircular) {
    MyBorisBikesClosestDockCircularComplication()
} timeline: {
    BorisBikesEntry(
        date: .now,
        closestStation: WidgetBikePoint(
            id: "test",
            commonName: "Test Station",
            alias: nil,
            standardBikes: 5,
            eBikes: 3,
            emptySpaces: 12,
            distance: 200
        ),
        error: nil
    )
    BorisBikesEntry(
        date: .now,
        closestStation: nil,
        error: "No favorites"
    )
}

#Preview(as: .accessoryRectangular) {
    MyBorisBikesClosestDockRectangularComplication()
} timeline: {
    BorisBikesEntry(
        date: .now,
        closestStation: WidgetBikePoint(
            id: "test",
            commonName: "Hyde Park Corner, Hyde Park",
            alias: nil,
            standardBikes: 5,
            eBikes: 3,
            emptySpaces: 12,
            distance: 200
        ),
        error: nil
    )
    BorisBikesEntry(
        date: .now,
        closestStation: WidgetBikePoint(
            id: "test2",
            commonName: "Very Long Station Name That Might Wrap",
            alias: nil,
            standardBikes: 0,
            eBikes: 0,
            emptySpaces: 20,
            distance: 500
        ),
        error: nil
    )
    BorisBikesEntry(
        date: .now,
        closestStation: nil,
        error: "No favorites"
    )
}    
