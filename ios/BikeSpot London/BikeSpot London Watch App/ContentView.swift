//
//  ContentView.swift
//  BikeSpot London Watch App
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import CoreLocation
import SwiftUI
import WatchKit
import WidgetKit

struct WatchLoadingIndicator: Hashable {
    let dockName: String
    let id = UUID()
}

// Wrapper to navigate to WatchWidgetDetailView from a deep link tap
struct WidgetTapDestination: Hashable {
    let dockId: String
    let journeyMetricRawValue: String?
}

enum WatchHomeDestination: Hashable {
  case journeys
  case favourites
}

struct ContentView: View {
  @StateObject private var viewModel = WatchFavoritesViewModel()
  @StateObject private var favoriteJourneysViewModel = WatchFavoriteJourneysViewModel()
  @StateObject private var favoritesService = WatchFavoritesService.shared
  @StateObject private var locationService = WatchLocationService.shared
  @Binding var selectedDockId: String?
  @Binding var customWidgetContext: String?
  @Binding var journeyMetricRawValue: String?
  var activityContext: JourneyActivityContext? = nil
  @State private var navigationPath = NavigationPath()
  @State private var showingDockSelection = false
  @State private var navigationId = UUID()
  @State private var journeyState = JourneyDataSource.cached()

  var body: some View {
    contentView
  }
  
  @ViewBuilder
  private var contentView: some View {
    NavigationStack(path: $navigationPath) {
      mainContent
        .navigationTitle(rootTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          toolbarContent
        }
        .refreshable {
          await refreshAllData()
        }
        .navigationDestination(for: WatchHomeDestination.self) { destination in
          buildHomeDestination(destination)
        }
        .navigationDestination(for: WatchBikePoint.self) { bikePoint in
          buildDetailView(for: bikePoint)
        }
        .navigationDestination(for: WidgetTapDestination.self) { destination in
          WatchWidgetDetailView(
            primaryDockId: destination.dockId,
            journeyMetricRawValue: destination.journeyMetricRawValue
          )
        }
        .navigationDestination(for: WatchJourneyDestination.self) { destination in
          switch destination {
          case .activity: WatchJourneyView()
          case .alternatives: WatchJourneyView(showAlternatives: true)
          case .liveActivity(let context): WatchJourneyView(activityContext: context)
          }
        }
        .navigationDestination(for: WatchLoadingIndicator.self) { loadingIndicator in
          WatchLoadingView(dockName: loadingIndicator.dockName)
        }
        .onChange(of: selectedDockId) { _, newDockId in
          handleSelectedDockChange(newDockId)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("journeySnapshotChanged"))) { _ in
          journeyState = JourneyDataSource.cached()
        }
        .sheet(isPresented: $showingDockSelection) {
          buildDockSelectionView()
        }
    }
    .onAppear {
      handleViewAppearance()
    }
  }
  
  @ViewBuilder
  private var mainContent: some View {
    if hasActiveJourney {
      WatchJourneyView()
    } else if hasFavoriteJourneys && hasFavoriteDocks {
      WatchStartMenu()
    } else if hasFavoriteJourneys {
      WatchFavoriteJourneysList(
        journeys: favoritesService.favoriteJourneys,
        bikePointsByID: favoriteJourneysViewModel.bikePointsByID
      )
    } else if hasFavoriteDocks {
      WatchFavoritesList(bikePoints: viewModel.favoriteBikePoints)
    } else {
      WatchEmptyView()
    }
  }

  private var hasActiveJourney: Bool {
    guard let active = journeyState.snapshot.active else { return false }
    return active.expiresAt > Date()
  }

  private var hasFavoriteJourneys: Bool {
    !favoritesService.favoriteJourneys.isEmpty
  }

  private var hasFavoriteDocks: Bool {
    !favoritesService.favorites.isEmpty
  }

  private var rootTitle: String {
    if hasActiveJourney { return "Journey" }
    if hasFavoriteJourneys && hasFavoriteDocks { return "BikeSpot" }
    return hasFavoriteJourneys ? "Journeys" : "Favourites"
  }

  @ViewBuilder
  private func buildHomeDestination(_ destination: WatchHomeDestination) -> some View {
    switch destination {
    case .journeys:
      WatchFavoriteJourneysList(
        journeys: favoritesService.favoriteJourneys,
        bikePointsByID: favoriteJourneysViewModel.bikePointsByID
      )
      .navigationTitle("Journeys")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { await refreshAllData() }
    case .favourites:
      WatchFavoritesList(bikePoints: viewModel.favoriteBikePoints)
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshAllData() }
    }
  }
  
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if !hasActiveJourney {
      ToolbarItem(placement: .topBarTrailing) {
        WatchRefreshButton(
            isLoading: viewModel.isLoading || favoriteJourneysViewModel.isLoading,
            onRefresh: {
                Task {
                    await refreshAllData()
                }
            }
        )
      }
    }
  }
  
  @ViewBuilder
  private func buildDockSelectionView() -> some View {
    DockSelectionView(onDockSelected: { _, _ in })
  }
  
  private func handleSelectedDockChange(_ newDockId: String?) {
    guard let dockId = newDockId else { return }

    if dockId == "JOURNEY_ACTIVITY" || dockId == "JOURNEY_ALTERNATIVES" {
      navigationPath = NavigationPath()
      if dockId == "JOURNEY_ACTIVITY", let activityContext {
        navigationPath.append(WatchJourneyDestination.liveActivity(activityContext))
      } else {
        navigationPath.append(dockId == "JOURNEY_ALTERNATIVES" ? WatchJourneyDestination.alternatives : .activity)
      }
      customWidgetContext = nil
      journeyMetricRawValue = nil
      selectedDockId = nil
    } else if dockId == "SELECT_DOCK_MODE" {
      showingDockSelection = true
      selectedDockId = nil // Reset to prevent repeated navigation
    } else if customWidgetContext == nil {
      // Came from the closest-dock widget complication (myborisbikes://dock/{id})
      // Show the richer WatchWidgetDetailView with nearby alternatives
      navigationPath = NavigationPath()
      navigationId = UUID()
      navigationPath.append(WidgetTapDestination(dockId: dockId, journeyMetricRawValue: journeyMetricRawValue))
      journeyMetricRawValue = nil
      selectedDockId = nil
    } else if let selectedBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == dockId }) {
      // Came from a custom dock widget (myborisbikes://custom-dock/{widgetId}/{dockId})
      navigationPath = NavigationPath()
      navigationId = UUID()
      navigationPath.append(selectedBikePoint)
      selectedDockId = nil // Reset to prevent repeated navigation
    } else {
      // customWidgetContext is set but favourites data hasn't loaded yet (cold launch race).
      // Navigate immediately with a placeholder so the screen always opens;
      // CustomDockDetailView.syncWithMainAppData() will replace it with real data on appear.
      let placeholder = WatchBikePoint(
        id: dockId,
        commonName: "Loading…",
        alias: nil,
        lat: 0.0,
        lon: 0.0,
        additionalProperties: []
      )
      navigationPath = NavigationPath()
      navigationId = UUID()
      navigationPath.append(placeholder)
      selectedDockId = nil
    }
  }
  
  private func handleViewAppearance() {
    // A complication URL can arrive before the navigation stack's change observer is installed.
    handleSelectedDockChange(selectedDockId)
    // Debug app group access
    favoritesService.refreshFromiOS()
    journeyState = JourneyDataSource.cached()

    // Request data from iPhone via WatchConnectivity
    requestFavoritesFromiPhone()

    Task {
      await refreshAllData()
    }
  }

  @MainActor
  private func refreshAllData() async {
    async let favoritesRefresh: Void = viewModel.forceRefreshData()
    async let favoriteJourneysRefresh: Void = favoriteJourneysViewModel.refresh(cacheBusting: true)
    async let activeJourneyRefresh = JourneyDataSource.refresh()
    let (_, _, refreshedJourneyState) = await (favoritesRefresh, favoriteJourneysRefresh, activeJourneyRefresh)
    journeyState = refreshedJourneyState
  }

  private func requestFavoritesFromiPhone() {
    // This will be handled by the WatchConnectivity message receiving in WatchFavoritesService
  }
  
  @ViewBuilder
  private func buildDetailView(for bikePoint: WatchBikePoint) -> some View {
    if let widgetId = customWidgetContext {
        CustomDockDetailView(
            bikePoint: bikePoint, 
            widgetId: widgetId,
            onClearContext: {
                // Clear widget context and navigation path to return to main list
                customWidgetContext = nil
                navigationPath = NavigationPath()
                
                // Force immediate widget data refresh when returning to home screen
                triggerHomeScreenWidgetRefresh()
                
                // Also force widget timeline reloads as backup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            },
            onNavigateToNewDock: { selectedDock, shouldForceRefresh in
                // Navigate to the newly selected dock and clear navigation history
                navigateToNewDockFromWidget(selectedDock, widgetId: widgetId, forceRefresh: shouldForceRefresh)
            }
        )
        .id("\(bikePoint.id)-\(widgetId)-\(navigationId)")
    } else {
        WatchDockDetailView(bikePoint: bikePoint)
            .id("\(bikePoint.id)-regular-\(navigationId)")
    }
  }
  
  private func navigateToNewDockFromWidget(_ selectedDock: WatchFavoriteBikePoint, widgetId: String, forceRefresh: Bool = false) {
    
    // Clear navigation history first
    navigationPath = NavigationPath()
    customWidgetContext = widgetId
    navigationId = UUID() // Force view recreation
    
    
    // Trigger force refresh if requested
    if forceRefresh {
        
        // Show loading screen immediately
        let loadingIndicator = WatchLoadingIndicator(dockName: selectedDock.displayName)
        navigationPath.append(loadingIndicator)
        
        Task {
            let refreshedBikePoint = await viewModel.forceRefreshSingleDock(selectedDock.id)
            
            // Navigate to the refreshed dock data
            DispatchQueue.main.async {
                // Clear the loading screen and navigate to the dock detail
                self.navigationPath = NavigationPath()
                
                if let bikePoint = refreshedBikePoint {
                    self.navigationPath.append(bikePoint)
                } else {
                    self.navigateWithRealData(selectedDock)
                }
            }
        }
    } else {
        navigateWithRealData(selectedDock)
    }
  }
  
  private func navigateWithRealData(_ selectedDock: WatchFavoriteBikePoint) {
    
    // Try to find the real bike point data from the current favorites
    if let realBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == selectedDock.id }) {
        navigationPath.append(realBikePoint)
    } else {
        // Fallback to placeholder if real data not available
        let placeholderBikePoint = WatchBikePoint(
          id: selectedDock.id,
          commonName: selectedDock.commonName,
          alias: selectedDock.alias,
          lat: 0.0,
          lon: 0.0,
          additionalProperties: []
        )
        navigationPath.append(placeholderBikePoint)
    }
  }
  
  /// Triggers immediate widget refresh when returning to home screen
  private func triggerHomeScreenWidgetRefresh() {
    
    Task {
      // Get all current favorite data and immediately update widgets
      let currentFavorites = viewModel.favoriteBikePoints
      
      guard !currentFavorites.isEmpty else {
        return
      }
      
      await MainActor.run {
        let widgetService = WatchWidgetService.shared
        
        // Update with closest favorite
        let closestFavorite = currentFavorites.first!
        widgetService.updateClosestStation(closestFavorite)
        
        // Update all dock data
        widgetService.updateAllDockData(from: currentFavorites)
        
      }
    }
  }
}

struct WatchEmptyView: View {
  @ObservedObject var favoritesService = WatchFavoritesService.shared

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "heart.slash")
        .font(.largeTitle)
        .foregroundColor(.gray)

      Text("No favourites")
        .font(.headline)

      if favoritesService.isConnectedToPhone {
        Text("Add favourite docks or journeys on your iPhone to see them here")
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      } else {
        VStack(spacing: 6) {
          HStack(spacing: 4) {
            Image(systemName: "iphone.slash")
              .font(.caption)
              .foregroundColor(.orange)
            Text("iPhone not connected")
              .font(.caption)
              .foregroundColor(.orange)
          }

          Text("Open the BikeSpot London app on your iPhone")
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
      }
    }
    .padding()
  }
}

struct WatchFavoritesList: View {
  let bikePoints: [WatchBikePoint]
  @StateObject private var locationService = WatchLocationService.shared

  private var sortedBikePoints: [WatchBikePoint] {
    guard let userLocation = locationService.location else { return bikePoints }
    return bikePoints.sorted { first, second in
      let firstDistance = userLocation.distance(from: CLLocation(latitude: first.lat, longitude: first.lon))
      let secondDistance = userLocation.distance(from: CLLocation(latitude: second.lat, longitude: second.lon))
      if firstDistance == secondDistance {
        return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
      }
      return firstDistance < secondDistance
    }
  }

  var body: some View {
    List {
      ForEach(sortedBikePoints, id: \.id) { bikePoint in
        NavigationLink(value: bikePoint) {
          WatchFavoriteRow(
            bikePoint: bikePoint,
            distance: locationService.distanceString(
              to: CLLocationCoordinate2D(latitude: bikePoint.lat, longitude: bikePoint.lon)
            ),
            numericDistance: locationService.distance(
              to: CLLocationCoordinate2D(latitude: bikePoint.lat, longitude: bikePoint.lon)
            )
          )
        }
        .buttonStyle(PlainButtonStyle())
        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .listRowBackground(Color.clear)
      }
      
    }
    .listStyle(PlainListStyle())
  }
}

struct WatchFavoriteRow: View {
  let bikePoint: WatchBikePoint
  let distance: String
  let numericDistance: CLLocationDistance?

  var body: some View {
    HStack(spacing: 9) {
        WatchDonutChart(
          standardBikes: bikePoint.standardBikes,
          eBikes: bikePoint.eBikes,
          emptySpaces: bikePoint.emptyDocks,
          size: 32
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(bikePoint.displayName)
            .font(.system(.caption, weight: .semibold))
            .lineLimit(2)
            .minimumScaleFactor(0.75)

          WatchDistanceIndicator(
            distance: numericDistance,
            distanceString: distance
          )
        }
        .padding(.leading, 10)

        Spacer()
      }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.white.opacity(0.09), in: Capsule())
    .opacity(bikePoint.isAvailable ? 1.0 : 0.6)
  }
}

struct WatchConnectivityIndicator: View {
  let isConnected: Bool

  var body: some View {
    Image(systemName: isConnected ? "iphone" : "iphone.slash")
      .font(.caption)
      .foregroundColor(isConnected ? .green : .orange)
  }
}

struct WatchRefreshButton: View {
  let isLoading: Bool
  let onRefresh: () -> Void
  @State private var rotationAngle = 0.0

  var body: some View {
    Button(action: {
      // Rotate on tap
      withAnimation(.easeInOut(duration: 0.5)) {
        rotationAngle += 360
      }
      onRefresh()
    }) {
      HStack(spacing: 2) {
        if isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
        } else {
          Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(rotationAngle))
        }
      }
      .font(.caption2)
    }
    .buttonStyle(.bordered)
    .controlSize(.mini)
    .disabled(isLoading)
  }
}

struct WatchSortButton: View {
  let sortMode: WatchSortMode
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 2) {
        Image(systemName: sortMode == .distance ? "location" : "textformat.abc")
        // Text(sortMode.displayName)
      }
      .font(.caption2)
    }
    .buttonStyle(.bordered)
    .controlSize(.mini)
  }
}

#Preview {
  ContentView(
    selectedDockId: .constant(nil),
    customWidgetContext: .constant(nil),
    journeyMetricRawValue: .constant(nil)
  )
}
