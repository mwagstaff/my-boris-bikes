//
//  WidgetDockRow.swift
//  My Boris Bikes Widget
//
//  Reusable row component for displaying dock information in widgets
//

import SwiftUI

struct WidgetDockRow: View {
    let bikePoint: WidgetBikePointData
    let showFullDetails: Bool

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptySpaces
        )
    }

    private var bikeItems: [(color: Color, count: Int)] {
        var items: [(Color, Int)] = []

        if bikeDataFilter.showsStandardBikes {
            items.append((Color(red: 236/255, green: 0/255, blue: 0/255), filteredCounts.standardBikes))
        }

        if bikeDataFilter.showsEBikes {
            items.append((Color(red: 12/255, green: 17/255, blue: 177/255), filteredCounts.eBikes))
        }

        return items
    }

    var body: some View {
        let isAlternative = bikePoint.isAlternative
        let donutSize: CGFloat = isAlternative ? 42 : 50
        let donutStroke: CGFloat = isAlternative ? 8 : 10
        let titleFontSize: CGFloat = isAlternative ? 12 : 14
        let subtitleFontSize: CGFloat = isAlternative ? 9 : 10
        let countFontSize: CGFloat = isAlternative ? 11 : 12

        Link(destination: URL(string: "myborisbikes://dock/\(bikePoint.id)")!) {
            HStack(spacing: isAlternative ? 10 : 12) {
                // Donut chart
                WidgetDonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptySpaces,
                    size: donutSize,
                    strokeWidth: donutStroke
                )

                if showFullDetails {
                    // Full details view
                    VStack(alignment: .leading, spacing: 4) {
                        // Dock name (with alias support)
                        if isAlternative {
                            Text("Alternative dock")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        if bikePoint.hasAlias {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bikePoint.displayName)
                                    .font(.system(size: titleFontSize, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Text(bikePoint.actualName)
                                    .font(.system(size: subtitleFontSize))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(bikePoint.displayName)
                                .font(.system(size: titleFontSize, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }

                        // Bike counts
                        HStack(spacing: 12) {
                            ForEach(Array(bikeItems.enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 8, height: 8)
                                    Text("\(item.count)")
                                        .font(.system(size: countFontSize, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Spaces
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(red: 117/255, green: 117/255, blue: 117/255))
                                    .frame(width: 8, height: 8)
                                Text("\(filteredCounts.emptySpaces)")
                                    .font(.system(size: countFontSize, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Distance indicator (visual + text)
                    if bikePoint.distance != nil {
                        WidgetDistanceIndicator(bikePoint: bikePoint, compact: isAlternative)
                    }
                }
            }
            .padding(.leading, isAlternative ? 28 : 16)
            .padding(.trailing, 16)
            .padding(.vertical, isAlternative ? 8 : 10)
            .background(Color.clear)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        WidgetDockRow(
            bikePoint: WidgetBikePointData(
                id: "1",
                displayName: "My Corner",
                actualName: "Hyde Park Corner, Hyde Park",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 250,
                lastUpdated: Date()
            ),
            showFullDetails: true
        )
        .background(Color.white)

        Divider()

        WidgetDockRow(
            bikePoint: WidgetBikePointData(
                id: "2",
                displayName: "Serpentine Car Park",
                actualName: "Serpentine Car Park, Hyde Park",
                standardBikes: 8,
                eBikes: 2,
                emptySpaces: 10,
                distance: 450,
                lastUpdated: Date()
            ),
            showFullDetails: true
        )
        .background(Color.white)
    }
}
