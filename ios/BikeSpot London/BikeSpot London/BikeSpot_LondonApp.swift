//
//  BikeSpot_LondonApp.swift
//  BikeSpot London
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import WidgetKit

@main
struct BikeSpot_LondonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var selectedDockId: String?
    @State private var startingScreenResetPolicy = StartingScreenResetPolicy()
    @AppStorage(AppConstants.UserDefaults.startingScreenResetMinutesKey, store: AppConstants.UserDefaults.sharedDefaults)
    private var startingScreenResetMinutes = StartingScreenResetPolicy.defaultMinutes

    init() {
        let startingTab = AppConstants.UserDefaults.sharedDefaults.integer(
            forKey: AppConstants.UserDefaults.defaultStartingScreenKey
        )
        _selectedTab = State(initialValue: (0...2).contains(startingTab) ? startingTab : 0)

        // Observe dock preference edits even when the app opens directly into a journey.
        _ = WidgetService.shared
        // Initialize WatchConnectivity
        #if os(iOS)
        FavoritesService.shared.setupWatchConnectivity()
        #endif

        // Restore any active Live Activities from a previous session
        LiveActivityService.shared.restoreActivities()
        LiveActivityService.shared.startActivityUpdateObservation()
        ScheduledJourneyService.shared.startPushToStartTokenObservation()
        JourneySyncService.shared.start()
        Task {
            await ScheduledJourneyService.shared.refresh()
            await DockArrivalMonitoringService.shared.retryPendingArrivalDeliveryIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab, selectedDockId: $selectedDockId)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            DockAvailabilityStore.shared.handleScenePhase(newPhase)
            if let baseURL = URL(string: AppConstants.Server.baseURL) {
                LondonBackgroundService.shared.handleScenePhase(newPhase, baseURL: baseURL)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                startingScreenResetPolicy.enteredBackground()
                // Schedule the next background refresh when entering background
                BackgroundRefreshService.shared.scheduleAppRefresh()
            case .active:
                if startingScreenResetPolicy.shouldResetOnReturn(afterMinutes: startingScreenResetMinutes) {
                    let startingTab = AppConstants.UserDefaults.sharedDefaults.integer(
                        forKey: AppConstants.UserDefaults.defaultStartingScreenKey
                    )
                    selectedDockId = nil
                    selectedTab = (0...2).contains(startingTab) ? startingTab : 0
                }
                DockArrivalMonitoringService.shared.handleApplicationDidBecomeActive()
                // Reconcile local/server live activity state after foregrounding
                LiveActivityService.shared.restoreActivities()
                Task {
                    await ScheduledJourneyService.shared.refresh()
            await DockArrivalMonitoringService.shared.retryPendingArrivalDeliveryIfNeeded()
                }
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

        // A destination received before activation must override the inactivity reset.
        if let host = url.host, ["favorites", "map", "journeys", "journey", "dock", "refresh"].contains(host) {
            startingScreenResetPolicy.explicitNavigation()
        }

        switch url.host {
        case "app":
            break
        case "favorites":
            selectedTab = 0 // Navigate to favorites tab
        case "map":
            selectedTab = 1 // Navigate to map tab
        case "journeys", "journey":
            selectedDockId = nil
            selectedTab = 2 // Navigate to journeys tab
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
