import SwiftUI
import CoreLocation
import WatchKit
import Foundation

struct WatchDockDetailView: View {
    @State private var displayedBikePoint: WatchBikePoint
    @StateObject private var locationService = WatchLocationService.shared
    @StateObject private var viewModel = WatchFavoritesViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var lastUpdateTime: Date?
    @State private var isRefreshing = false
    
    init(bikePoint: WatchBikePoint) {
        self._displayedBikePoint = State(initialValue: bikePoint)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with dock name
                VStack(spacing: 8) {
                    if let alias = resolvedAlias(for: displayedBikePoint) {
                        Text(alias)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        
                        Text(displayedBikePoint.commonName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text(displayedBikePoint.commonName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    
                    HStack(spacing: 8) {
                        WatchDistanceIndicator(
                            distance: locationService.distance(
                                to: CLLocationCoordinate2D(latitude: displayedBikePoint.lat, longitude: displayedBikePoint.lon)
                            ),
                            distanceString: locationService.distanceString(
                                to: CLLocationCoordinate2D(latitude: displayedBikePoint.lat, longitude: displayedBikePoint.lon)
                            )
                        )
                        Spacer()
                        if let updateTime = lastUpdateTime {
                            Text("Upd. \(formatUpdateTime(updateTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Upd. Unknown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Large donut chart
                VStack(spacing: 12) {
                    WatchDonutChart(
                        standardBikes: displayedBikePoint.standardBikes,
                        eBikes: displayedBikePoint.eBikes,
                        emptySpaces: displayedBikePoint.emptyDocks,
                        size: 40
                    )
                    
                    WatchDonutChartLegend(
                        standardBikes: displayedBikePoint.standardBikes,
                        eBikes: displayedBikePoint.eBikes,
                        emptySpaces: displayedBikePoint.emptyDocks
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("Dock Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Special logging for Stonecutter Street discrepancy investigation
            if displayedBikePoint.commonName.contains("Stonecutter") {
            }
            if displayedBikePoint.alias == nil,
               let alias = WatchFavoritesService.shared.alias(for: displayedBikePoint.id) {
                displayedBikePoint.alias = alias
            }
            
            loadLastUpdateTime()
            syncWithMainAppData()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: refreshDockData) {
                    if isRefreshing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
    }
    
    private func refreshDockData() {
        guard !isRefreshing else { return }
        
        Task {
            await MainActor.run {
                isRefreshing = true
            }
            
            // Use cache busting for manual refresh
            await refreshSpecificDockWithCacheBusting()
            
            await MainActor.run {
                isRefreshing = false
                loadLastUpdateTime()
            }
        }
    }
    
    private func refreshSingleDockData() {
        Task {
            // Refresh the specific dock data in the background
            await refreshSpecificDockWithCacheBusting()
            loadLastUpdateTime()
        }
    }
    
    private func syncWithMainAppData() {
        // Check if there's more recent data in the main app's viewModel
        if let currentBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == displayedBikePoint.id }) {
            displayedBikePoint = currentBikePoint
        } else {
            Task {
                await refreshSpecificDockWithCacheBusting()
            }
        }
    }
    
    private func refreshSpecificDockWithCacheBusting() async {
        let apiService = WatchTfLAPIService.shared
        let widgetService = WatchWidgetService.shared
        
        do {
            var refreshedBikePoint = try await apiService.fetchBikePoint(id: displayedBikePoint.id, cacheBusting: true).async()
            if refreshedBikePoint.alias == nil {
                refreshedBikePoint.alias = resolvedAlias(for: refreshedBikePoint)
            }
            
            await MainActor.run {
                // Update the displayed data
                self.displayedBikePoint = refreshedBikePoint
            }
            
            // Validate refreshed data before updating widgets to prevent race conditions
            guard refreshedBikePoint.isAvailable else {
                return
            }
            
            // Update the widget data
            widgetService.updateAllDockData(from: [refreshedBikePoint])
            
            // Also update the main app's data
            await viewModel.cacheBikePoint(refreshedBikePoint)
        } catch {
        }
    }
    
    private func loadLastUpdateTime() {
        // Try to get the last update time for this specific dock
        let appGroup = "group.dev.skynolimit.myborisbikes"
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        // Check for a timestamp specific to this dock
        let dockTimestampKey = "dock_\(displayedBikePoint.id)_timestamp"
        let timestamp = userDefaults.double(forKey: dockTimestampKey)
        
        if timestamp > 0 {
            lastUpdateTime = Date(timeIntervalSince1970: timestamp)
        } else {
            // Fallback to general widget data timestamp
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            if generalTimestamp > 0 {
                lastUpdateTime = Date(timeIntervalSince1970: generalTimestamp)
            } else {
                lastUpdateTime = nil
            }
        }
    }
    
    private func formatUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)
        
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func resolvedAlias(for bikePoint: WatchBikePoint) -> String? {
        if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return WatchFavoritesService.shared.alias(for: bikePoint.id)
    }
}

struct CustomDockDetailView: View {
    @State private var displayedBikePoint: WatchBikePoint
    let widgetId: String?
    @StateObject private var locationService = WatchLocationService.shared
    @StateObject private var viewModel = WatchFavoritesViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var lastUpdateTime: Date?
    @State private var showingDockSelection = false
    @State private var isRefreshing = false
    
    init(bikePoint: WatchBikePoint, widgetId: String?, onClearContext: (() -> Void)? = nil, onNavigateToNewDock: ((WatchFavoriteBikePoint, Bool) -> Void)? = nil) {
        self._displayedBikePoint = State(initialValue: bikePoint)
        self.widgetId = widgetId
        self.onClearContext = onClearContext
        self.onNavigateToNewDock = onNavigateToNewDock
    }
    
    // Add callback to notify parent about context clearing
    var onClearContext: (() -> Void)?
    
    // Add callback to notify parent to navigate to a new dock
    var onNavigateToNewDock: ((WatchFavoriteBikePoint, Bool) -> Void)?
    
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with dock name
                VStack(spacing: 8) {
                    if let alias = resolvedAlias(for: displayedBikePoint) {
                        Text(alias)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        
                        Text(displayedBikePoint.commonName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text(displayedBikePoint.commonName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    
                    HStack(spacing: 8) {
                        WatchDistanceIndicator(
                            distance: locationService.distance(
                                to: CLLocationCoordinate2D(latitude: displayedBikePoint.lat, longitude: displayedBikePoint.lon)
                            ),
                            distanceString: locationService.distanceString(
                                to: CLLocationCoordinate2D(latitude: displayedBikePoint.lat, longitude: displayedBikePoint.lon)
                            )
                        )
                        Spacer()
                        if let updateTime = lastUpdateTime {
                            Text("Upd. \(formatUpdateTime(updateTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Upd. Unknown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Large donut chart
                VStack(spacing: 12) {
                    WatchDonutChart(
                        standardBikes: displayedBikePoint.standardBikes,
                        eBikes: displayedBikePoint.eBikes,
                        emptySpaces: displayedBikePoint.emptyDocks,
                        size: 40
                    )
                    
                    WatchDonutChartLegend(
                        standardBikes: displayedBikePoint.standardBikes,
                        eBikes: displayedBikePoint.eBikes,
                        emptySpaces: displayedBikePoint.emptyDocks
                    )
                }
                
                // Widget configuration options (only show if accessed from custom dock widget)
                if widgetId != nil {
                    VStack(spacing: 12) {
                        Text("Widget Options")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            Button("Change favourite") {
                                if let widgetId = widgetId {
                                    InteractiveDockWidgetManager.shared.setPendingConfiguration(for: widgetId)
                                    showingDockSelection = true
                                }
                            }
                            .font(.system(.caption, design: .default, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("Dock Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if displayedBikePoint.alias == nil,
               let alias = WatchFavoritesService.shared.alias(for: displayedBikePoint.id) {
                displayedBikePoint.alias = alias
            }
            loadLastUpdateTime()
            syncWithMainAppData()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: refreshDockData) {
                    if isRefreshing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .sheet(isPresented: $showingDockSelection) {
            DockSelectionView(onDockSelected: { selectedDock, shouldForceRefresh in
                // Dismiss the sheet first, then navigate
                showingDockSelection = false
                
                // Brief delay to allow sheet dismissal, then navigate to the new dock
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navigateToNewDock(selectedDock, shouldForceRefresh)
                }
            })
        }
    }
    
    private func navigateToNewDock(_ selectedDock: WatchFavoriteBikePoint, _ shouldForceRefresh: Bool) {
        // Clear current context and navigate to the new dock
        onClearContext?()
        onNavigateToNewDock?(selectedDock, shouldForceRefresh)
    }
    
    private func refreshDockData() {
        guard !isRefreshing else { return }
        
        Task {
            await MainActor.run {
                isRefreshing = true
            }
            
            // Use cache busting for manual refresh
            await refreshSpecificDockWithCacheBusting()
            
            await MainActor.run {
                isRefreshing = false
                loadLastUpdateTime()
            }
        }
    }
    
    private func syncWithMainAppData() {
        // Check if there's more recent data in the main app's viewModel
        if let currentBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == displayedBikePoint.id }) {
            displayedBikePoint = currentBikePoint
        } else {
            Task {
                await refreshSpecificDockWithCacheBusting()
            }
        }
    }
    
    private func refreshSpecificDockWithCacheBusting() async {
        let apiService = WatchTfLAPIService.shared
        let widgetService = WatchWidgetService.shared
        
        do {
            var refreshedBikePoint = try await apiService.fetchBikePoint(id: displayedBikePoint.id, cacheBusting: true).async()
            if refreshedBikePoint.alias == nil {
                refreshedBikePoint.alias = resolvedAlias(for: refreshedBikePoint)
            }
            
            await MainActor.run {
                // Update the displayed data
                self.displayedBikePoint = refreshedBikePoint
            }
            
            // Validate refreshed data before updating widgets to prevent race conditions
            guard refreshedBikePoint.isAvailable else {
                return
            }
            
            // Update the widget data
            widgetService.updateAllDockData(from: [refreshedBikePoint])
            
            // Also update the main app's data
            await viewModel.cacheBikePoint(refreshedBikePoint)
        } catch {
        }
    }
    
    private func loadLastUpdateTime() {
        // Try to get the last update time for this specific dock
        let appGroup = "group.dev.skynolimit.myborisbikes"
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        
        // Check for a timestamp specific to this dock
        let dockTimestampKey = "dock_\(displayedBikePoint.id)_timestamp"
        let timestamp = userDefaults.double(forKey: dockTimestampKey)
        
        if timestamp > 0 {
            lastUpdateTime = Date(timeIntervalSince1970: timestamp)
        } else {
            // Fallback to general widget data timestamp
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            if generalTimestamp > 0 {
                lastUpdateTime = Date(timeIntervalSince1970: generalTimestamp)
            } else {
                lastUpdateTime = nil
            }
        }
    }
    
    private func formatUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)
        
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func resolvedAlias(for bikePoint: WatchBikePoint) -> String? {
        if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return WatchFavoritesService.shared.alias(for: bikePoint.id)
    }
}

#Preview {
    NavigationStack {
        CustomDockDetailView(
            bikePoint: WatchBikePoint(
                id: "test",
                commonName: "Test Station",
                alias: nil,
                lat: 51.5,
                lon: -0.1,
                additionalProperties: [
                    WatchAdditionalProperty(key: "NbStandardBikes", value: "5"),
                    WatchAdditionalProperty(key: "NbEBikes", value: "3"),
                    WatchAdditionalProperty(key: "NbEmptyDocks", value: "12"),
                    WatchAdditionalProperty(key: "Installed", value: "true"),
                    WatchAdditionalProperty(key: "Locked", value: "false")
                ]
            ),
            widgetId: "1",
            onClearContext: {}
        )
    }
}
