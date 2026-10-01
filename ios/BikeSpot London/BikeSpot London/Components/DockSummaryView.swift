import SwiftUI

extension BikePoint {
    var hasAvailabilityData: Bool {
        additionalProperties.contains {
            $0.key == "NbStandardBikes" || $0.key == "NbEBikes" || $0.key == "NbEmptyDocks"
        }
    }
}

struct DockSummaryView: View {
    let bikePoint: BikePoint
    let name: String
    let distance: String
    var isFavourite = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                DonutChart(standardBikes: bikePoint.standardBikes,
                           eBikes: bikePoint.eBikes, emptySpaces: bikePoint.emptyDocks,
                           size: isFavourite ? 54 : 44, strokeWidth: isFavourite ? 7 : 6,
                           hasAvailability: bikePoint.hasAvailabilityData)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isFavourite && name != bikePoint.commonName {
                        Text(bikePoint.commonName).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    Label(distance, systemImage: "location")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if bikePoint.hasAvailabilityData {
                DonutChartLegend(standardBikes: bikePoint.standardBikes,
                                 eBikes: bikePoint.eBikes, emptySpaces: bikePoint.emptyDocks)
                if !bikePoint.isAvailable {
                    Label("Dock unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Availability unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
    }
}
