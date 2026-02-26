//
//  ContentView.swift
//  My Boris Bikes
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import UIKit
import Combine

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
    private let notificationStatusRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var shouldShowLocationBanner: Bool {
        locationService.authorizationStatus == .denied ||
        locationService.authorizationStatus == .restricted ||
        (locationService.authorizationStatus == .notDetermined && locationService.error != nil) ||
        (locationService.authorizationStatus == .authorizedWhenInUse && locationService.location == nil && locationService.error != nil)
    }

    private var shouldShowServiceBanner: Bool {
        bannerService.currentBanner != nil && !isServiceBannerDismissed
    }

    private var notificationSession: LiveActivityService.ActiveNotificationSession? {
        liveActivityService.activeNotificationSession
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

            VStack(spacing: 8) {
                if let notificationSession {
                    ActiveNotificationsBanner(
                        dockName: notificationSession.dockName,
                        onTap: { handleNotificationBannerTap(for: notificationSession.dockId) }
                    )
                    .padding(.horizontal)
                }

                if shouldShowLocationBanner {
                    LocationPermissionBanner(
                        locationService: locationService,
                        onRequestPermission: handleLocationPermissionRequest
                    )
                }

                Spacer()
            }
        }
        .onAppear {
            locationService.requestLocationPermission()
            // Fetch banner config on app launch
            bannerService.fetchBannerConfig()
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
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
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
            // Reset dismissal state when returning to foreground
            isServiceBannerDismissed = false
        }
        .onReceive(notificationStatusRefreshTimer) { _ in
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
        }
        .onChange(of: bannerService.currentBanner) { _, newBanner in
            // Reset dismissal state when banner content changes
            if newBanner != nil {
                isServiceBannerDismissed = false
            }
        }
        .onChange(of: liveActivityService.activeActivities.count) { _, _ in
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
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

    private func handleNotificationBannerTap(for dockId: String) {
        selectedBikePointForMap = nil
        selectedDockId = dockId
        selectedTab = 1
        selectedTabIndex = 1
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

private struct ActiveNotificationsBanner: View {
    let dockName: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.white)
                Text("Notifications active for \(dockName) | Tap to manage")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications active for \(dockName). Tap to manage")
    }
}

#Preview {
    ContentView(selectedTab: .constant(0), selectedDockId: .constant(nil))
}
