import SwiftUI
import CoreLocation
import WatchKit
import Foundation

// MARK: - Shared nearby-alternatives helpers

/// Haversine distance in metres between two coordinates.
private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6_371_000.0
    let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
    let Δφ = (lat2 - lat1) * .pi / 180
    let Δλ = (lon2 - lon1) * .pi / 180
    let a = sin(Δφ/2) * sin(Δφ/2) + cos(φ1) * cos(φ2) * sin(Δλ/2) * sin(Δλ/2)
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

// MARK: - WatchDockDetailView

struct WatchDockDetailView: View {
    @State private var displayedBikePoint: WatchBikePoint
    @StateObject private var locationService = WatchLocationService.shared
    @StateObject private var viewModel = WatchFavoritesViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var lastUpdateTime: Date?
    @State private var isRefreshing = false
    @State private var nearbyAlternatives: [WatchBikePoint] = []
    @State private var isLoadingAlternatives = false
    @State private var alternativesFetched = false

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

                // Nearby alternatives
                nearbyAlternativesSection
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
            Task { await fetchNearbyAlternatives() }
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

    // MARK: Nearby alternatives section

    @ViewBuilder
    private var nearbyAlternativesSection: some View {
        if isLoadingAlternatives {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Finding nearby docks…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !nearbyAlternatives.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("Nearby alternatives")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)
                ForEach(nearbyAlternatives, id: \.id) { alt in
                    AlternativeDockRow(
                        bikePoint: alt,
                        distanceString: locationService.distanceString(
                            to: CLLocationCoordinate2D(latitude: alt.lat, longitude: alt.lon)
                        )
                    )
                }
            }
        }
    }

    // MARK: Private helpers

    private func fetchNearbyAlternatives() async {
        guard !alternativesFetched, displayedBikePoint.lat != 0 else { return }
        alternativesFetched = true
        await MainActor.run { isLoadingAlternatives = true }
        let primaryId = displayedBikePoint.id
        let primaryLat = displayedBikePoint.lat
        let primaryLon = displayedBikePoint.lon
        do {
            let nearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                lat: primaryLat, lon: primaryLon, radiusMeters: 500
            )
            let alternatives = Array(
                nearby
                    .filter { $0.id != primaryId && $0.isAvailable }
                    .sorted {
                        haversineDistance(lat1: primaryLat, lon1: primaryLon, lat2: $0.lat, lon2: $0.lon) <
                        haversineDistance(lat1: primaryLat, lon1: primaryLon, lat2: $1.lat, lon2: $1.lon)
                    }
                    .prefix(5)
            )
            await MainActor.run {
                nearbyAlternatives = alternatives
                isLoadingAlternatives = false
            }
        } catch {
            await MainActor.run {
                alternativesFetched = false // allow retry
                isLoadingAlternatives = false
            }
        }
    }

    private func refreshDockData() {
        guard !isRefreshing else { return }

        Task {
            await MainActor.run {
                isRefreshing = true
            }
            await refreshSpecificDockWithCacheBusting()
            await MainActor.run {
                isRefreshing = false
                loadLastUpdateTime()
            }
        }
    }

    private func syncWithMainAppData() {
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
                self.displayedBikePoint = refreshedBikePoint
            }
            // Now we have valid coordinates — fetch alternatives if not yet done
            await fetchNearbyAlternatives()

            guard refreshedBikePoint.isAvailable else { return }
            widgetService.updateAllDockData(from: [refreshedBikePoint])
            await viewModel.cacheBikePoint(refreshedBikePoint)
        } catch {
        }
    }

    private func loadLastUpdateTime() {
        let appGroup = "group.dev.skynolimit.myborisbikes"
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        let dockTimestampKey = "dock_\(displayedBikePoint.id)_timestamp"
        let timestamp = userDefaults.double(forKey: dockTimestampKey)
        if timestamp > 0 {
            lastUpdateTime = Date(timeIntervalSince1970: timestamp)
        } else {
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            lastUpdateTime = generalTimestamp > 0 ? Date(timeIntervalSince1970: generalTimestamp) : nil
        }
    }

    private func formatUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
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
    @State private var nearbyAlternatives: [WatchBikePoint] = []
    @State private var isLoadingAlternatives = false
    @State private var alternativesFetched = false

    init(bikePoint: WatchBikePoint, widgetId: String?, onClearContext: (() -> Void)? = nil, onNavigateToNewDock: ((WatchFavoriteBikePoint, Bool) -> Void)? = nil) {
        self._displayedBikePoint = State(initialValue: bikePoint)
        self.widgetId = widgetId
        self.onClearContext = onClearContext
        self.onNavigateToNewDock = onNavigateToNewDock
    }

    var onClearContext: (() -> Void)?
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

                // Nearby alternatives
                nearbyAlternativesSection

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
            Task { await fetchNearbyAlternatives() }
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
                showingDockSelection = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navigateToNewDock(selectedDock, shouldForceRefresh)
                }
            })
        }
    }

    // MARK: Nearby alternatives section

    @ViewBuilder
    private var nearbyAlternativesSection: some View {
        if isLoadingAlternatives {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Finding nearby docks…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !nearbyAlternatives.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("Nearby alternatives")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)
                ForEach(nearbyAlternatives, id: \.id) { alt in
                    AlternativeDockRow(
                        bikePoint: alt,
                        distanceString: locationService.distanceString(
                            to: CLLocationCoordinate2D(latitude: alt.lat, longitude: alt.lon)
                        )
                    )
                }
            }
        }
    }

    // MARK: Private helpers

    private func fetchNearbyAlternatives() async {
        guard !alternativesFetched, displayedBikePoint.lat != 0 else { return }
        alternativesFetched = true
        await MainActor.run { isLoadingAlternatives = true }
        let primaryId = displayedBikePoint.id
        let primaryLat = displayedBikePoint.lat
        let primaryLon = displayedBikePoint.lon
        do {
            let nearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                lat: primaryLat, lon: primaryLon, radiusMeters: 500
            )
            let alternatives = Array(
                nearby
                    .filter { $0.id != primaryId && $0.isAvailable }
                    .sorted {
                        haversineDistance(lat1: primaryLat, lon1: primaryLon, lat2: $0.lat, lon2: $0.lon) <
                        haversineDistance(lat1: primaryLat, lon1: primaryLon, lat2: $1.lat, lon2: $1.lon)
                    }
                    .prefix(5)
            )
            await MainActor.run {
                nearbyAlternatives = alternatives
                isLoadingAlternatives = false
            }
        } catch {
            await MainActor.run {
                alternativesFetched = false
                isLoadingAlternatives = false
            }
        }
    }

    private func navigateToNewDock(_ selectedDock: WatchFavoriteBikePoint, _ shouldForceRefresh: Bool) {
        onClearContext?()
        onNavigateToNewDock?(selectedDock, shouldForceRefresh)
    }

    private func refreshDockData() {
        guard !isRefreshing else { return }

        Task {
            await MainActor.run { isRefreshing = true }
            await refreshSpecificDockWithCacheBusting()
            await MainActor.run {
                isRefreshing = false
                loadLastUpdateTime()
            }
        }
    }

    private func syncWithMainAppData() {
        if let currentBikePoint = viewModel.favoriteBikePoints.first(where: { $0.id == displayedBikePoint.id }) {
            displayedBikePoint = currentBikePoint
        } else {
            Task { await refreshSpecificDockWithCacheBusting() }
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
                self.displayedBikePoint = refreshedBikePoint
            }
            // Now we have valid coordinates — fetch alternatives if not yet done
            await fetchNearbyAlternatives()

            guard refreshedBikePoint.isAvailable else { return }
            widgetService.updateAllDockData(from: [refreshedBikePoint])
            await viewModel.cacheBikePoint(refreshedBikePoint)
        } catch {
        }
    }

    private func loadLastUpdateTime() {
        let appGroup = "group.dev.skynolimit.myborisbikes"
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }
        let dockTimestampKey = "dock_\(displayedBikePoint.id)_timestamp"
        let timestamp = userDefaults.double(forKey: dockTimestampKey)
        if timestamp > 0 {
            lastUpdateTime = Date(timeIntervalSince1970: timestamp)
        } else {
            let generalTimestamp = userDefaults.double(forKey: "widget_data_timestamp")
            lastUpdateTime = generalTimestamp > 0 ? Date(timeIntervalSince1970: generalTimestamp) : nil
        }
    }

    private func formatUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
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
