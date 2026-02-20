//
//  My_Boris_Bikes_WatchApp.swift
//  My Boris Bikes Watch Watch App
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import WidgetKit

@main
struct My_Boris_Bikes_Watch_Watch_AppApp: App {
    @State private var selectedDockId: String?
    @State private var customWidgetContext: String?
    
    init() {
        // Initialize WatchConnectivity
        WatchFavoritesService.shared.setupWatchConnectivity()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(selectedDockId: $selectedDockId, customWidgetContext: $customWidgetContext)
                .environmentObject(WatchFavoritesService.shared)
                .environmentObject(WatchLocationService.shared)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onChange(of: customWidgetContext) { newValue in
                }
        }
    }
    
    private func handleDeepLink(_ url: URL) {
        
        // Handle myborisbikes://dock/{dockId}
        if url.scheme == "myborisbikes",
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
        else if url.scheme == "myborisbikes",
                url.host == "configure-widget",
                url.pathComponents.count > 1 {
            let widgetId = url.pathComponents[1]
            
            InteractiveDockWidgetManager.shared.setPendingConfiguration(for: widgetId)
            
            // Set a special flag to show dock selection mode
            selectedDockId = "SELECT_DOCK_MODE"
        }
        // Handle myborisbikes://custom-dock/{widgetId}/{dockId} (for configured widget tap)
        else if url.scheme == "myborisbikes",
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
        else if url.scheme == "myborisbikes",
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
