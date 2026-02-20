//
//  ContentView.swift
//  My Boris Bikes Watch Watch App
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
}

struct ContentView: View {
  @StateObject private var viewModel = WatchFavoritesViewModel()
  @StateObject private var favoritesService = WatchFavoritesService.shared
  @StateObject private var locationService = WatchLocationService.shared
  @Binding var selectedDockId: String?
  @Binding var customWidgetContext: String?
  @State private var navigationPath = NavigationPath()
  @State private var showingDockSelection = false
  @State private var navigationId = UUID()

  var body: some View {
    contentView
  }
  
  @ViewBuilder
  private var contentView: some View {
    NavigationStack(path: $navigationPath) {
      mainContent
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          toolbarContent
        }
        .refreshable {
          await viewModel.forceRefreshData()
        }
        .navigationDestination(for: WatchBikePoint.self) { bikePoint in
          buildDetailView(for: bikePoint)
        }
        .navigationDestination(for: WidgetTapDestination.self) { destination in
          WatchWidgetDetailView(primaryDockId: destination.dockId)
        }
        .navigationDestination(for: WatchLoadingIndicator.self) { loadingIndicator in
          WatchLoadingView(dockName: loadingIndicator.dockName)
        }
        .onChange(of: selectedDockId, perform: handleSelectedDockChange)
        .onChange(of: customWidgetContext) { newContext in
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
    VStack(spacing: 0) {
      if viewModel.favoriteBikePoints.isEmpty {
        WatchEmptyView()
      } else {
        WatchFavoritesList(bikePoints: viewModel.favoriteBikePoints, selectedDockId: $selectedDockId, navigationPath: $navigationPath)
      }
    }
  }
  
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
        WatchRefreshButton(
            isLoading: viewModel.isLoading,
            onRefresh: {
                Task {
                    await viewModel.forceRefreshData()
                }
            }
        )
    }

    ToolbarItem(placement: .topBarTrailing) {
        WatchSortButton(
            sortMode: favoritesService.sortMode,
            onToggle: viewModel.toggleSortMode
        )
    }
  }
  
  @ViewBuilder
  private func buildDockSelectionView() -> some View {
    DockSelectionView(onDockSelected: { _, _ in })
  }
  
  private func handleSelectedDockChange(_ newDockId: String?) {
    guard let dockId = newDockId else { return }

    if dockId == "SELECT_DOCK_MODE" {
      showingDockSelection = true
      selectedDockId = nil // Reset to prevent repeated navigation
    } else if customWidgetContext == nil {
      // Came from the closest-dock widget complication (myborisbikes://dock/{id})
      // Show the richer WatchWidgetDetailView with nearby alternatives
      navigationPath = NavigationPath()
      navigationId = UUID()
      navigationPath.append(WidgetTapDestination(dockId: dockId))
      selectedDockId = nil
    } else if let selectedBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == dockId }) {
      // Came from a custom dock widget (myborisbikes://custom-dock/{widgetId}/{dockId})
      navigationPath = NavigationPath()
      navigationId = UUID()
      navigationPath.append(selectedBikePoint)
      selectedDockId = nil // Reset to prevent repeated navigation
    }
  }
  
  private func handleViewAppearance() {
    // Debug app group access
    favoritesService.refreshFromiOS()

    // Request data from iPhone via WatchConnectivity
    requestFavoritesFromiPhone()

    Task {
      await viewModel.refreshData()
    }
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

      Text("No Favorites")
        .font(.headline)

      if favoritesService.isConnectedToPhone {
        Text("Add favorites on your iPhone to see them here")
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

          Text("Open the Boris Bikes app on your iPhone")
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
  @Binding var selectedDockId: String?
  @Binding var navigationPath: NavigationPath
  @StateObject private var locationService = WatchLocationService.shared

  var body: some View {
    List {
      ForEach(bikePoints, id: \.id) { bikePoint in
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
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        WatchDonutChart(
          standardBikes: bikePoint.standardBikes,
          eBikes: bikePoint.eBikes,
          emptySpaces: bikePoint.emptyDocks,
          size: 32
        )

        VStack(alignment: .leading, spacing: 2) {
          if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
             !alias.isEmpty {
            Text(alias)
              .font(.system(.body, weight: .semibold))
              .lineLimit(1)
            
            Text(bikePoint.commonName)
              .font(.system(.caption2))
              .foregroundColor(.secondary)
              .lineLimit(2)
          } else {
            Text(bikePoint.commonName)
              .font(.system(.caption, design: .default, weight: .medium))
              .lineLimit(2)
          }

          WatchDistanceIndicator(
            distance: numericDistance,
            distanceString: distance
          )
        }
        .padding(.leading, 10)

        Spacer()
      }

        WatchDonutChartLegend(
          standardBikes: bikePoint.standardBikes,
          eBikes: bikePoint.eBikes,
          emptySpaces: bikePoint.emptyDocks
        )
    }
    .padding(.vertical, 4)
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
  ContentView(selectedDockId: .constant(nil), customWidgetContext: .constant(nil))
}
