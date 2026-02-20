//
//  ContentView.swift
//  My Boris Bikes
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Binding var selectedTab: Int
    @Binding var selectedDockId: String?

    @StateObject private var locationService = LocationService.shared
    @StateObject private var favoritesService = FavoritesService.shared
    @StateObject private var bannerService = BannerService.shared
    @StateObject private var liveActivityService = LiveActivityService.shared
    @State private var selectedTabIndex = 0
    @State private var selectedBikePointForMap: BikePoint?
    @State private var isServiceBannerDismissed = false

    private var shouldShowLocationBanner: Bool {
        locationService.authorizationStatus == .denied ||
        locationService.authorizationStatus == .restricted ||
        (locationService.authorizationStatus == .notDetermined && locationService.error != nil) ||
        (locationService.authorizationStatus == .authorizedWhenInUse && locationService.location == nil && locationService.error != nil)
    }

    private var shouldShowServiceBanner: Bool {
        bannerService.currentBanner != nil && !isServiceBannerDismissed
    }
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTabIndex) {
                HomeView(
                    onBikePointSelected: { bikePoint in
                        selectedDockId = nil
                        selectedBikePointForMap = bikePoint
                        selectedTabIndex = 1
                    },
                    onShowServiceStatus: {
                        isServiceBannerDismissed = false
                    }
                )
                .tabItem {
                    Image(systemName: "star")
                    Text("Favourites")
                }
                .tag(0)

                MapView(
                    selectedBikePoint: $selectedBikePointForMap,
                    selectedDockId: $selectedDockId,
                    onShowServiceStatus: {
                        isServiceBannerDismissed = false
                    }
                )
                .tabItem {
                    Image(systemName: "map")
                    Text("Map")
                }
                .tag(1)

                PreferencesView()
                    .tabItem {
                        Image(systemName: "gearshape")
                        Text("Preferences")
                    }
                    .tag(2)

                AboutView()
                    .tabItem {
                        Image(systemName: "info.circle")
                        Text("About")
                    }
                    .tag(3)
            }
            .environmentObject(locationService)
            .environmentObject(favoritesService)
            .environmentObject(bannerService)
            .environmentObject(liveActivityService)
            .sheet(isPresented: Binding(
                get: { shouldShowServiceBanner },
                set: { if !$0 { isServiceBannerDismissed = true } }
            )) {
                if let banner = bannerService.currentBanner {
                    ServiceStatusBanner(
                        banner: banner,
                        onDismiss: {
                            isServiceBannerDismissed = true
                        }
                    )
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.hidden)
                    .interactiveDismissDisabled(false)
                }
            }

            // Location permission banner overlay
            if shouldShowLocationBanner {
                VStack {
                    LocationPermissionBanner(
                        locationService: locationService,
                        onRequestPermission: handleLocationPermissionRequest
                    )
                    Spacer()
                }
            }
        }
        .onAppear {
            locationService.requestLocationPermission()
            // Fetch banner config on app launch
            bannerService.fetchBannerConfig()
            AnalyticsService.shared.trackAppLaunch(screen: analyticsScreen(for: selectedTabIndex))

            // Debug: Force sync with watch on app launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                #if os(iOS)
                favoritesService.forceSyncWithWatch()
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Fetch banner config when returning to foreground
            bannerService.fetchBannerConfig()
            // Reset dismissal state when returning to foreground
            isServiceBannerDismissed = false
        }
        .onChange(of: bannerService.currentBanner) { _, newBanner in
            // Reset dismissal state when banner content changes
            if newBanner != nil {
                isServiceBannerDismissed = false
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            selectedTabIndex = newTab
        }
        .onChange(of: selectedTabIndex) { _, newTab in
            AnalyticsService.shared.track(action: .screenView, screen: analyticsScreen(for: newTab))
        }
        .onChange(of: selectedDockId) { _, newDockId in
            if newDockId != nil {
                // Ensure map tab is visible for dock deep links
                selectedTabIndex = 1
            }
        }
    }
    
    private func handleLocationPermissionRequest() {
        switch locationService.authorizationStatus {
        case .notDetermined:
            locationService.requestLocationPermission()
        case .denied, .restricted:
            openAppSettings()
        default:
            locationService.startLocationUpdates()
        }
    }
    
    private func openAppSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl)
        }
    }

    private func analyticsScreen(for tabIndex: Int) -> AnalyticsScreen {
        switch tabIndex {
        case 0:
            return .favourites
        case 1:
            return .map
        case 2:
            return .preferences
        case 3:
            return .about
        default:
            return .unknown
        }
    }
}

#Preview {
    ContentView(selectedTab: .constant(0), selectedDockId: .constant(nil))
}
