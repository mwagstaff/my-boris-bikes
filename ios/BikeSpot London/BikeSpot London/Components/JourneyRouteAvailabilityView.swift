import SwiftUI

/// Compact pickup and return availability, in the same order as the displayed route.
struct JourneyRouteAvailabilityView: View {
    let startBikePoint: BikePoint?
    let endBikePoint: BikePoint?
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var filterRawValue = BikeDataFilter.both.rawValue
    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes = AlternativeDockSettings.defaultMinBikes
    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes = AlternativeDockSettings.defaultMinEBikes
    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces = AlternativeDockSettings.defaultMinSpaces

    private var filter: BikeDataFilter { BikeDataFilter(rawValue: filterRawValue) ?? .both }
    private var bikeThreshold: Int {
        switch filter {
        case .both: return minBikes + minEBikes
        case .bikesOnly: return minBikes
        case .eBikesOnly: return minEBikes
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                dock(startBikePoint, isEnd: false)
                dock(endBikePoint, isEnd: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                dock(startBikePoint, isEnd: false)
                dock(endBikePoint, isEnd: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dock(_ point: BikePoint?, isEnd: Bool) -> some View {
        let known = point?.hasAvailabilityData == true && point?.isAvailable == true
        let bikes = filter.filteredCounts(standardBikes: point?.standardBikes ?? 0,
            eBikes: point?.eBikes ?? 0, emptySpaces: point?.emptyDocks ?? 0).totalBikes
        let count = isEnd ? point?.emptyDocks ?? 0 : bikes
        let unit = isEnd ? (count == 1 ? "space" : "spaces")
            : filter == .eBikesOnly ? (count == 1 ? "e-bike" : "e-bikes") : (count == 1 ? "bike" : "bikes")
        return HStack(spacing: 6) {
            SimplifiedDonutChart(standardBikes: point?.standardBikes ?? 0,
                eBikes: point?.eBikes ?? 0, emptySpaces: point?.emptyDocks ?? 0,
                size: 32, displayMode: isEnd ? .spaces : .bikes,
                bikeDataFilter: filter, hasAvailability: known)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(isEnd ? "End dock" : "Start dock").font(.caption2).foregroundStyle(.secondary)
                AvailabilityPill(count: known ? count : nil, label: unit,
                    symbol: isEnd ? "parkingsign.circle" : filter == .eBikesOnly ? "bolt.fill" : "bicycle",
                    threshold: isEnd ? minSpaces : bikeThreshold)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
