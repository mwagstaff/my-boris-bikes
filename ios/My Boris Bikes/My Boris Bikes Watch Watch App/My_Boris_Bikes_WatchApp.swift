//
//  My_Boris_Bikes_WatchApp.swift
//  My Boris Bikes Watch Watch App
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import WidgetKit
import WatchKit

private enum WatchDeepLinkPreferenceKeys {
    static let minSpacesKey = "alternativeDocksMinSpaces"
    static let minBikesKey = "alternativeDocksMinBikes"
    static let minEBikesKey = "alternativeDocksMinEBikes"
}

@main
struct My_Boris_Bikes_Watch_Watch_AppApp: App {
    @State private var selectedDockId: String?
    @State private var customWidgetContext: String?

    private static let backgroundRefreshTaskIdentifier = "dev.skynolimit.myborisbikes.watch-complication-refresh"

    init() {
        // Initialize WatchConnectivity
        WatchFavoritesService.shared.setupWatchConnectivity()
        // NOTE: Do NOT call scheduleWatchBackgroundRefresh() here.
        // WKApplication.scheduleBackgroundRefresh requires the SwiftUI .backgroundTask
        // handler to be registered first, which only happens after `body` is evaluated.
        // Scheduling is deferred to .onAppear below.
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedDockId: $selectedDockId, customWidgetContext: $customWidgetContext)
                .environmentObject(WatchFavoritesService.shared)
                .environmentObject(WatchLocationService.shared)
                .onAppear {
                    // Schedule the first background refresh now that the scene —
                    // including the .backgroundTask handler below — is fully registered.
                    Self.scheduleWatchBackgroundRefresh()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onChange(of: customWidgetContext) { newValue in
                }
        }
        // Independent watch-side background refresh — fires approximately every 15 minutes.
        // This keeps complications current even when the paired iPhone is unreachable.
        .backgroundTask(.appRefresh(Self.backgroundRefreshTaskIdentifier)) {
            // Reschedule before doing work so the chain never breaks
            Self.scheduleWatchBackgroundRefresh()
            await performWatchBackgroundRefresh()
        }
    }

    /// Asks watchOS to schedule a background app refresh ~15 minutes from now.
    static func scheduleWatchBackgroundRefresh() {
        let fireDate = Date(timeIntervalSinceNow: 15 * 60)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: fireDate, userInfo: nil) { error in
            if let error = error {
                print("WatchApp: Failed to schedule background refresh: \(error)")
            }
        }
    }

    /// Fetches fresh dock data from TfL and writes it to the shared app group so that
    /// the widget extension can display up-to-date complications.
    private func performWatchBackgroundRefresh() async {
        let favoritesService = WatchFavoritesService.shared
        let widgetService = WatchWidgetService.shared
        let apiService = WatchTfLAPIService.shared
        let favorites = favoritesService.favorites

        guard !favorites.isEmpty else { return }

        let ids = favorites.map { $0.id }
        let bikePoints = await fetchFreshBikePoints(ids: ids, apiService: apiService)
        guard !bikePoints.isEmpty else { return }

        await MainActor.run {
            widgetService.updateAllDockData(from: bikePoints)
            widgetService.updateClosestStation(from: bikePoints)
            WidgetCenter.shared.reloadAllTimelines()
        }
        print("WatchApp: Background refresh completed — \(bikePoints.count) docks updated")
    }

    private func fetchFreshBikePoints(ids: [String], apiService: WatchTfLAPIService) async -> [WatchBikePoint] {
        await withTaskGroup(of: WatchBikePoint?.self) { group in
            for id in ids {
                group.addTask {
                    try? await apiService.fetchBikePoint(id: id, cacheBusting: true).async()
                }
            }
            var results: [WatchBikePoint] = []
            for await result in group {
                if let bp = result { results.append(bp) }
            }
            return results
        }
    }
    
    private func handleDeepLink(_ url: URL) {
        let supportsWatchRouting = url.scheme == "myborisbikes" || url.scheme == "myborisbikeswatch"

        if supportsWatchRouting {
            applyPreferenceOverrides(from: url)
        }
        
        // Handle myborisbikes://dock/{dockId}
        if supportsWatchRouting,
           url.host == "dock",
           url.pathComponents.count > 1 {
            let dockId = url.pathComponents[1]
            customWidgetContext = nil // Clear widget context for regular dock navigation
            selectedDockId = dockId
            
            // Force immediate widget data updates after regular dock navigation
            triggerImmediateWidgetDataUpdate(for: dockId)
            
            // Also force widget timeline reloads as backup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        // Handle myborisbikes://configure-widget/{widgetId} (for widget tap-to-configure)
        else if supportsWatchRouting,
                url.host == "configure-widget",
                url.pathComponents.count > 1 {
            let widgetId = url.pathComponents[1]
            
            InteractiveDockWidgetManager.shared.setPendingConfiguration(for: widgetId)
            
            // Set a special flag to show dock selection mode
            selectedDockId = "SELECT_DOCK_MODE"
        }
        // Handle myborisbikes://custom-dock/{widgetId}/{dockId} (for configured widget tap)
        else if supportsWatchRouting,
                url.host == "custom-dock",
                url.pathComponents.count > 2 {
            let widgetId = url.pathComponents[1]
            let dockId = url.pathComponents[2]
            
            // Store widget context for custom detail view
            customWidgetContext = widgetId
            selectedDockId = dockId
            
            
            // Force immediate widget data updates after deep link navigation
            triggerImmediateWidgetDataUpdate(for: dockId)
            
            // Also force widget timeline reloads as backup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        // Handle myborisbikes://selectdock?widget={widgetId} (for widget tap-to-configure - legacy support)
        else if supportsWatchRouting,
                url.host == "selectdock" {
            
            // Extract widget ID from URL parameters
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let widgetId = components?.queryItems?.first(where: { $0.name == "widget" })?.value
            
            if let widgetId = widgetId {
                InteractiveDockWidgetManager.shared.setPendingConfiguration(for: widgetId)
            }
            
            // Set a special flag to show dock selection mode
            selectedDockId = "SELECT_DOCK_MODE"
        }
    }

    private func applyPreferenceOverrides(from url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let defaults = UserDefaults(suiteName: "group.dev.skynolimit.myborisbikes") else {
            return
        }

        let items = components.queryItems ?? []
        func value(for name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        var didUpdate = false

        if let bikeFilterRaw = value(for: "bikeFilter"),
           BikeDataFilter(rawValue: bikeFilterRaw) != nil {
            defaults.set(bikeFilterRaw, forKey: BikeDataFilter.userDefaultsKey)
            didUpdate = true
        }

        if let minBikesRaw = value(for: "minBikes"),
           let minBikes = Int(minBikesRaw),
           minBikes >= 0 {
            defaults.set(minBikes, forKey: WatchDeepLinkPreferenceKeys.minBikesKey)
            didUpdate = true
        }

        if let minEBikesRaw = value(for: "minEBikes"),
           let minEBikes = Int(minEBikesRaw),
           minEBikes >= 0 {
            defaults.set(minEBikes, forKey: WatchDeepLinkPreferenceKeys.minEBikesKey)
            didUpdate = true
        }

        if let minSpacesRaw = value(for: "minSpaces"),
           let minSpaces = Int(minSpacesRaw),
           minSpaces >= 0 {
            defaults.set(minSpaces, forKey: WatchDeepLinkPreferenceKeys.minSpacesKey)
            didUpdate = true
        }

        if didUpdate {
            defaults.synchronize()
        }
    }
    
    /// Triggers immediate widget data update for the specified dock to prevent exclamation triangles
    private func triggerImmediateWidgetDataUpdate(for dockId: String) {
        
        Task {
            // Get fresh data for the specific dock immediately
            let apiService = WatchTfLAPIService.shared
            let widgetService = WatchWidgetService.shared
            
            do {
                // Force fresh API call for this dock
                let freshBikePoint = try await apiService.fetchBikePoint(id: dockId, cacheBusting: true).async()
                
                await MainActor.run {
                    // Immediately update widget data
                    widgetService.updateClosestStation(freshBikePoint)
                    widgetService.updateAllDockData(from: [freshBikePoint])
                    
                }
            } catch {
                
                // Fallback: try to get cached data and update widgets anyway
                await MainActor.run {
                    let viewModel = WatchFavoritesViewModel()
                    if let cachedBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == dockId }) {
                        widgetService.updateClosestStation(cachedBikePoint)
                        widgetService.updateAllDockData(from: [cachedBikePoint])
                    }
                }
            }
        }
    }
}
