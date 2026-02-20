//
//  SmallWidgetView.swift
//  My Boris Bikes Widget
//
//  Small widget view showing single dock with initials and donut chart
//

import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
    let entry: SimpleEntry

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    var body: some View {
        let favorites = entry.bikePoints.filter { !$0.isAlternative }
        if let firstDock = favorites.first {
            let filteredCounts = bikeDataFilter.filteredCounts(
                standardBikes: firstDock.standardBikes,
                eBikes: firstDock.eBikes,
                emptySpaces: firstDock.emptySpaces
            )

            let bikeItems: [(color: Color, count: Int)] = {
                var items: [(Color, Int)] = []

                if bikeDataFilter.showsStandardBikes {
                    items.append((Color(red: 236/255, green: 0/255, blue: 0/255), filteredCounts.standardBikes))
                }

                if bikeDataFilter.showsEBikes {
                    items.append((Color(red: 12/255, green: 17/255, blue: 177/255), filteredCounts.eBikes))
                }

                return items
            }()

            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    Link(destination: URL(string: "myborisbikes://refresh")!) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Link(destination: URL(string: "myborisbikes://dock/\(firstDock.id)")!) {
                    VStack(spacing: 6) {
                        // Initials at the top
                        Text(firstDock.initials)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)

                        // Donut chart
                        WidgetDonutChart(
                            standardBikes: firstDock.standardBikes,
                            eBikes: firstDock.eBikes,
                            emptySpaces: firstDock.emptySpaces,
                            size: 56,
                            strokeWidth: 12
                        )

                        // Bike counts breakdown
                        HStack(spacing: 6) {
                            ForEach(Array(bikeItems.enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 6, height: 6)
                                    Text("\(item.count)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                            }

                            // Spaces
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color(red: 117/255, green: 117/255, blue: 117/255))
                                    .frame(width: 6, height: 6)
                                Text("\(filteredCounts.emptySpaces)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                        }

                        WidgetRefreshStatusView(lastRefresh: entry.lastRefresh)
                    }
                }
            }
            .padding(8)
        } else {
            EmptyWidgetView(message: "No favourites")
        }
    }
}

#Preview {
    SmallWidgetView(
        entry: SimpleEntry(
            date: Date(),
            bikePoints: [
                WidgetBikePointData(
                    id: "1",
                    displayName: "Hyde Park Corner",
                    actualName: "Hyde Park Corner, Hyde Park",
                    standardBikes: 5,
                    eBikes: 3,
                    emptySpaces: 12,
                    distance: 250,
                    lastUpdated: Date()
                )
            ],
            sortMode: "distance",
            lastRefresh: Date()
        )
    )
}
