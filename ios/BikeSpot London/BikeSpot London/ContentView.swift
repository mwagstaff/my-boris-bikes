//
//  ContentView.swift
//  BikeSpot London
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import SwiftUI
import UIKit
import Combine
import UserNotifications
import os.log

struct ContentView: View {
    @Binding var selectedTab: Int
    @Binding var selectedDockId: String?

    @StateObject private var locationService = LocationService.shared
    @StateObject private var favoritesService = FavoritesService.shared
    @StateObject private var bannerService = BannerService.shared
    @StateObject private var liveActivityService = LiveActivityService.shared
    private let scheduledJourneyService = ScheduledJourneyService.shared
    private let adHocJourneyService = AdHocJourneyService.shared
    @State private var hasActiveJourney = ScheduledJourneyService.shared.journeys.contains { $0.isActive }
        || AdHocJourneyService.shared.recentJourneys.contains { $0.isActive }
    @State private var isHolidayModeEnabled = ScheduledJourneyService.shared.isHolidayModeEnabled
    @State private var selectedBikePointForMap: BikePoint?
    @State private var journeyDockUseAction: ((BikePoint) -> Void)?
    @State private var isServiceBannerDismissed = false
    private let logger = Logger(subsystem: "dev.skynolimit.myborisbikes", category: "JourneyBadge")
    private let notificationStatusRefreshTimer = Timer.publish(every: 60, tolerance: 6, on: .main, in: .common).autoconnect()

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
        guard let session = liveActivityService.currentNotificationSession,
              session.scheduledJourneyPhase == nil,
              session.scheduledJourneyId == nil,
              session.adHocJourneyId == nil else { return nil }
        return session
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                HomeView(
                    onBikePointSelected: { bikePoint in
                        journeyDockUseAction = nil
                        selectedDockId = nil
                        selectedBikePointForMap = bikePoint
                        selectedTab = 1
                    },
                    onShowServiceStatus: {
                        isServiceBannerDismissed = false
                    },
                    onJourneyStarted: {
                        selectedTab = 2
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
                    journeyDockUseAction: $journeyDockUseAction,
                    onShowServiceStatus: {
                        isServiceBannerDismissed = false
                    },
                    onJourneyStarted: { selectedTab = 2 }
                )
                .tabItem {
                    Image(systemName: "map")
                    Text("Map")
                }
                .tag(1)

                JourneysView { dockId, useDock in
                    journeyDockUseAction = useDock
                    selectedBikePointForMap = nil
                    selectedDockId = dockId
                    selectedTab = 1
                }
                    .tabItem {
                        Image(systemName: "figure.outdoor.cycle")
                        Text("Journeys")
                    }
                    .badge(hasActiveJourney ? "" : nil)
                    .tag(2)

                ProfileView()
                    .tabItem {
                        Image(systemName: "person.crop.circle")
                        Text("Profile")
                    }
                    .tag(3)
            }
            .environmentObject(locationService)
            .environmentObject(favoritesService)
            .environmentObject(bannerService)
            .environmentObject(liveActivityService)
            .environmentObject(scheduledJourneyService)
            .environmentObject(adHocJourneyService)
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

            if shouldShowLocationBanner {
                LocationPermissionBanner(
                    locationService: locationService,
                    onRequestPermission: handleLocationPermissionRequest
                )
            }
        }
        .overlay(alignment: .bottom) {
            if isHolidayModeEnabled || notificationSession != nil {
                VStack(spacing: 8) {
                    if isHolidayModeEnabled {
                        HolidayModeBanner {
                            Task { await scheduledJourneyService.setHolidayMode(false) }
                        }
                    }
                    if let notificationSession {
                        ActiveNotificationsBanner(
                            session: notificationSession,
                            onTap: {
                                handleNotificationBannerTap(notificationSession)
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 64)
            }
        }
        .onAppear {
            locationService.requestLocationPermission()
            // Fetch banner config on app launch
            bannerService.fetchBannerConfig()
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
            Task {
                await scheduledJourneyService.registerDevice()
                await scheduledJourneyService.refresh()
            }
            AnalyticsService.shared.trackAppLaunch(screen: analyticsScreen(for: selectedTab))

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
            // Skip the server poll while backgrounded; the willEnterForeground
            // handler above refreshes on return.
            guard UIApplication.shared.applicationState != .background else { return }
            Task { await liveActivityService.refreshNotificationStatusFromServer() }
        }
        // Loading changes during Journeys' appearance must not rebuild the tab
        // container while UIKit is still committing the user's tab selection.
        .onReceive(Publishers.CombineLatest(
            scheduledJourneyService.$journeys,
            adHocJourneyService.$recentJourneys
        ).map { scheduled, adHoc in
            scheduled.contains { $0.isActive } || adHoc.contains { $0.isActive }
        }.removeDuplicates()) { hasActiveJourney = $0 }
        .onReceive(scheduledJourneyService.$isHolidayModeEnabled.removeDuplicates()) {
            isHolidayModeEnabled = $0
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
            AnalyticsService.shared.track(action: .screenView, screen: analyticsScreen(for: newTab))
        }
        .onChange(of: selectedDockId) { _, newDockId in
            if newDockId != nil {
                // Ensure map tab is visible for dock deep links
                selectedTab = 1
            }
        }
        .task(id: hasActiveJourney) {
            await updateAppIconBadge()
        }
    }

    private func handleNotificationBannerTap(_ session: LiveActivityService.ActiveNotificationSession) {
        Task {
            await liveActivityService.endLiveActivityFromUserAction(
                dockId: session.dockId,
                dockName: session.dockName,
                reason: "app_banner"
            )
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
            return .journeys
        case 3:
            return .profile
        default:
            return .unknown
        }
    }

    private func updateAppIconBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(hasActiveJourney ? 1 : 0)
        } catch {
            logger.warning("Failed to update journey app icon badge: \(error.localizedDescription)")
        }
    }
}

private struct HolidayModeBanner: View {
    let onTap: () -> Void

    private let message = "Holiday mode enabled | Tap to disable"

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "beach.umbrella.fill")
                    .foregroundColor(.white)
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.replacingOccurrences(of: " | ", with: ". "))
    }
}

private struct ActiveNotificationsBanner: View {
    let session: LiveActivityService.ActiveNotificationSession
    let onTap: () -> Void

    private var message: String {
        "Notifications active for \(session.dockName) | Tap to end"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.white)
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppConstants.Colors.standardBike.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.replacingOccurrences(of: " | ", with: ". "))
    }
}

#Preview {
    ContentView(selectedTab: .constant(0), selectedDockId: .constant(nil))
}
