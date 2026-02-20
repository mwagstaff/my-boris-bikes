//
//  MediumWidgetView.swift
//  My Boris Bikes Widget
//
//  Medium widget view showing up to 2 docks with full details
//

import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        let favorites = entry.bikePoints.filter { !$0.isAlternative }
        if favorites.isEmpty {
            EmptyWidgetView(message: "No favourites")
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("My Boris Bikes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if entry.sortMode == "distance" {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    WidgetRefreshStatusView(lastRefresh: entry.lastRefresh)
                    Link(destination: URL(string: "myborisbikes://refresh")!) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                // Docks list (max 2 for medium widget)
                VStack(spacing: 0) {
                    ForEach(Array(favorites.prefix(2))) { bikePoint in
                        WidgetDockRow(bikePoint: bikePoint, showFullDetails: true)
                        if bikePoint.id != favorites.prefix(2).last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    MediumWidgetView(
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
                ),
                WidgetBikePointData(
                    id: "2",
                    displayName: "Serpentine Car Park",
                    actualName: "Serpentine Car Park, Hyde Park",
                    standardBikes: 8,
                    eBikes: 2,
                    emptySpaces: 10,
                    distance: 450,
                    lastUpdated: Date()
                )
            ],
            sortMode: "distance",
            lastRefresh: Date()
        )
    )
}
