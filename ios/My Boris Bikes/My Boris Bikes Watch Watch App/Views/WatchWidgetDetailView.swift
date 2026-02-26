//
//  WatchWidgetDetailView.swift
//  My Boris Bikes Watch Watch App
//
//  Detail view shown when tapping the watch live activity/widget.
//  Displays the tapped primary dock and nearby alternatives as full cards.
//

import SwiftUI
import CoreLocation

/// Haversine distance in metres between two coordinates.
private func widgetHaversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6_371_000.0
    let phi1 = lat1 * .pi / 180
    let phi2 = lat2 * .pi / 180
    let deltaPhi = (lat2 - lat1) * .pi / 180
    let deltaLambda = (lon2 - lon1) * .pi / 180

    let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
        + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

struct WatchWidgetDetailView: View {
    let primaryDockId: String
    @StateObject private var viewModel = WatchFavoritesViewModel()
    @StateObject private var locationService = WatchLocationService.shared

    @State private var primaryBikePoint: WatchBikePoint?
    @State private var alternatives: [WatchBikePoint] = []
    @State private var isLoadingPrimary = true
    @State private var isLoadingAlternatives = false
    @State private var hasLoadedAlternatives = false
    @State private var alternativesLoadFailed = false
    @State private var hasLoadedInitialData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoadingPrimary {
                    loadingStateView
                } else if let station = primaryBikePoint {
                    primarySection(station)
                    alternativesSection
                } else {
                    unavailableStateView
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("Dock Info")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoadedInitialData else { return }
            hasLoadedInitialData = true
            await loadDockDetails()
        }
    }

    // MARK: - Primary dock section

    @ViewBuilder
    private func primarySection(_ station: WatchBikePoint) -> some View {
        DockAvailabilityCard(
            bikePoint: station,
            distanceString: distanceString(for: station),
            chartSize: 64
        )
    }

    // MARK: - Alternatives section

    @ViewBuilder
    private var alternativesSection: some View {
        if isLoadingAlternatives {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading alternatives…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nearby alternatives")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(.secondary)

                ForEach(alternatives, id: \.id) { alt in
                    DockAvailabilityCard(
                        bikePoint: alt,
                        distanceString: distanceString(for: alt),
                        chartSize: 52
                    )
                }
            }
        } else if hasLoadedAlternatives {
            Text(alternativesLoadFailed ? "Couldn’t load nearby alternatives." : "No nearby alternatives found.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var loadingStateView: some View {
        VStack(spacing: 8) {
            Text("Loading latest dock info...")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var unavailableStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Couldn’t load this dock")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func distanceString(for bikePoint: WatchBikePoint) -> String {
        locationService.distanceString(
            to: CLLocationCoordinate2D(latitude: bikePoint.lat, longitude: bikePoint.lon)
        )
    }

    private func loadDockDetails() async {
        await MainActor.run {
            isLoadingPrimary = true
            isLoadingAlternatives = false
            hasLoadedAlternatives = false
            alternativesLoadFailed = false
            alternatives = []
        }

        // Use existing in-memory favorites first for fast first paint.
        var primary = viewModel.favoriteBikePoints.first(where: { $0.id == primaryDockId })
        if primary == nil {
            primary = try? await WatchTfLAPIService.shared
                .fetchBikePoint(id: primaryDockId)
                .async()
        }
        if primary == nil {
            primary = try? await WatchTfLAPIService.shared
                .fetchBikePoint(id: primaryDockId, cacheBusting: true)
                .async()
        }

        if var resolved = primary, resolved.alias == nil {
            resolved.alias = WatchFavoritesService.shared.alias(for: resolved.id)
            primary = resolved
        }

        await MainActor.run {
            primaryBikePoint = primary
            isLoadingPrimary = false
        }

        // Refresh full favorites in the background for cache warming / widget freshness.
        Task { await viewModel.refreshData() }

        guard let primary else { return }
        await loadAlternatives(near: primary)
    }

    private func loadAlternatives(near primary: WatchBikePoint) async {
        let coordinate = CLLocationCoordinate2D(latitude: primary.lat, longitude: primary.lon)
        guard CLLocationCoordinate2DIsValid(coordinate),
              !(primary.lat == 0 && primary.lon == 0) else {
            return
        }

        await MainActor.run { isLoadingAlternatives = true }

        do {
            let nearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                lat: primary.lat,
                lon: primary.lon,
                radiusMeters: 500
            )
            var sortedAlternatives = nearby
                .filter { $0.id != primary.id && $0.isAvailable }
                .sorted {
                    widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $0.lat, lon2: $0.lon) <
                    widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $1.lat, lon2: $1.lon)
                }

            // If the immediate area has no suitable alternatives, widen the radius once.
            if sortedAlternatives.isEmpty {
                let expandedNearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                    lat: primary.lat,
                    lon: primary.lon,
                    radiusMeters: 1000
                )
                sortedAlternatives = expandedNearby
                    .filter { $0.id != primary.id && $0.isAvailable }
                    .sorted {
                        widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $0.lat, lon2: $0.lon) <
                        widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $1.lat, lon2: $1.lon)
                    }
            }

            let displayedAlternatives = sortedAlternatives
                .prefix(5)
                .map { dock in
                    var updated = dock
                    if updated.alias == nil {
                        updated.alias = WatchFavoritesService.shared.alias(for: updated.id)
                    }
                    return updated
                }

            await MainActor.run {
                alternatives = Array(displayedAlternatives)
                hasLoadedAlternatives = true
                alternativesLoadFailed = false
                isLoadingAlternatives = false
            }
        } catch {
            await MainActor.run {
                alternatives = []
                hasLoadedAlternatives = true
                alternativesLoadFailed = true
                isLoadingAlternatives = false
            }
        }
    }
}

private struct DockAvailabilityCard: View {
    let bikePoint: WatchBikePoint
    let distanceString: String
    let chartSize: CGFloat

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            VStack(spacing: 2) {
                Text(bikePoint.displayName)
                    .font(.system(.headline, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)

                if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alias.isEmpty,
                   alias != bikePoint.commonName {
                    Text(bikePoint.commonName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }

            if !distanceString.isEmpty {
                Text(distanceString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            WatchDonutChart(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                size: chartSize
            )
            .frame(maxWidth: .infinity, alignment: .center)

            WatchThresholdLegend(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
        )
    }
}

private enum WatchThresholdSettings {
    static let minSpacesKey = "alternativeDocksMinSpaces"
    static let minBikesKey = "alternativeDocksMinBikes"
    static let minEBikesKey = "alternativeDocksMinEBikes"

    static let defaultMinSpaces = 3
    static let defaultMinBikes = 3
    static let defaultMinEBikes = 3
}

private struct WatchThresholdLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(WatchThresholdSettings.minBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minBikes: Int = WatchThresholdSettings.defaultMinBikes

    @AppStorage(WatchThresholdSettings.minEBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minEBikes: Int = WatchThresholdSettings.defaultMinEBikes

    @AppStorage(WatchThresholdSettings.minSpacesKey, store: BikeDataFilter.userDefaultsStore)
    private var minSpaces: Int = WatchThresholdSettings.defaultMinSpaces

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: standardBikes,
            eBikes: eBikes,
            emptySpaces: emptySpaces
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            if bikeDataFilter.showsStandardBikes {
                WatchThresholdLegendItem(
                    color: .red,
                    count: filteredCounts.standardBikes,
                    label: filteredCounts.standardBikes == 1 ? "bike" : "bikes",
                    threshold: minBikes
                )
            }
            if bikeDataFilter.showsEBikes {
                WatchThresholdLegendItem(
                    color: .blue,
                    count: filteredCounts.eBikes,
                    label: filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes",
                    threshold: minEBikes
                )
            }
            WatchThresholdLegendItem(
                color: .gray.opacity(0.6),
                count: filteredCounts.emptySpaces,
                label: filteredCounts.emptySpaces == 1 ? "space" : "spaces",
                threshold: minSpaces
            )
        }
    }
}

private struct WatchThresholdLegendItem: View {
    let color: Color
    let count: Int
    let label: String
    let threshold: Int

    private var textColor: Color {
        if count == 0 { return .red }
        if threshold > 0 && count < threshold { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(textColor)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(textColor)
                .lineLimit(1)
        }
        .frame(minWidth: 34)
    }
}

// MARK: - Compact alternative row

struct AlternativeDockRow: View {
    let bikePoint: WatchBikePoint
    let distanceString: String

    var body: some View {
        HStack(spacing: 6) {
            WatchDonutChart(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                size: 24
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(bikePoint.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 6) {
                    WatchDonutChartLegend(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks
                    )
                    .scaleEffect(0.85, anchor: .leading)

                    if !distanceString.isEmpty {
                        Text(distanceString)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        WatchWidgetDetailView(primaryDockId: "BikePoints_1")
    }
}
