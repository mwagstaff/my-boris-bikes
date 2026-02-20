//
//  My_Boris_BikesApp.swift
//  My Boris Bikes
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import WidgetKit

@main
struct My_Boris_BikesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var selectedDockId: String?

    init() {
        // Initialize WatchConnectivity
        #if os(iOS)
        FavoritesService.shared.setupWatchConnectivity()
        #endif

        // Restore any active Live Activities from a previous session
        LiveActivityService.shared.restoreActivities()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab, selectedDockId: $selectedDockId)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Schedule the next background refresh when entering background
                BackgroundRefreshService.shared.scheduleAppRefresh()
            case .active:
                // When the app comes to foreground, reload widget timelines
                // so they pick up the freshest data from the main app
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "myborisbikes" else { return }

        switch url.host {
        case "favorites":
            selectedTab = 0 // Navigate to favorites tab
        case "map":
            selectedTab = 1 // Navigate to map tab
        case "dock":
            // Extract dock ID from path
            let dockId = url.pathComponents.last ?? ""
            selectedDockId = dockId
            selectedTab = 1 // Navigate to map tab to show the dock
        case "refresh":
            selectedTab = 0 // Navigate to favorites tab for refresh
            AppConstants.UserDefaults.sharedDefaults.set(true, forKey: AppConstants.UserDefaults.widgetRefreshRequestKey)
            NotificationCenter.default.post(name: .widgetRefreshRequested, object: nil)
        default:
            break
        }
    }
}
