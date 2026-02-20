//
//  WatchWidgetDetailView.swift
//  My Boris Bikes Watch Watch App
//
//  Detail view shown when tapping a watch screen lock widget complication.
//  Displays the primary dock large with the donut chart, and nearby
//  favourite alternatives in a compact list beneath.
//

import SwiftUI
import CoreLocation

struct WatchWidgetDetailView: View {
    let primaryDockId: String
    @StateObject private var viewModel = WatchFavoritesViewModel()
    @StateObject private var locationService = WatchLocationService.shared

    private var primaryBikePoint: WatchBikePoint? {
        viewModel.favoriteBikePoints.first(where: { $0.id == primaryDockId })
            ?? viewModel.favoriteBikePoints.first
    }

    private var alternatives: [WatchBikePoint] {
        viewModel.favoriteBikePoints.filter { $0.id != (primaryBikePoint?.id ?? primaryDockId) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let station = primaryBikePoint {
                    primarySection(station)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

                if !alternatives.isEmpty {
                    Divider()
                    alternativesSection
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("Dock Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await viewModel.refreshData() }
        }
    }

    // MARK: - Primary dock section

    @ViewBuilder
    private func primarySection(_ station: WatchBikePoint) -> some View {
        VStack(alignment: .center, spacing: 8) {
            // Dock name
            Text(station.displayName)
                .font(.system(.headline, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            // Large donut chart
            WatchDonutChart(
                standardBikes: station.standardBikes,
                eBikes: station.eBikes,
                emptySpaces: station.emptyDocks,
                size: 70
            )
            .frame(maxWidth: .infinity, alignment: .center)

            // Legend
            WatchDonutChartLegend(
                standardBikes: station.standardBikes,
                eBikes: station.eBikes,
                emptySpaces: station.emptyDocks
            )
        }
    }

    // MARK: - Alternatives section

    @ViewBuilder
    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nearby")
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            ForEach(alternatives, id: \.id) { alt in
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
