//
//  LargeWidgetView.swift
//  My Boris Bikes Widget
//
//  Large widget view showing up to 5 docks with full details
//

import SwiftUI
import WidgetKit

struct LargeWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        let groups = favoriteGroups(from: entry.bikePoints)

        if groups.isEmpty {
            EmptyWidgetView(message: "No favourites")
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("My Boris Bikes")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if entry.sortMode == "distance" {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    WidgetRefreshStatusView(lastRefresh: entry.lastRefresh)
                    Link(destination: URL(string: "myborisbikes://refresh")!) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Docks list
                VStack(spacing: 0) {
                    let visibleGroups = limitedGroups(from: groups)
                    ForEach(visibleGroups) { group in
                        WidgetDockRow(bikePoint: group.favorite, showFullDetails: true)

                        if !group.alternatives.isEmpty {
                            WidgetAlternativeRow(alternatives: group.alternatives)
                        }

                        if group.id != visibleGroups.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func favoriteGroups(from bikePoints: [WidgetBikePointData]) -> [WidgetFavoriteGroup] {
        var groups: [WidgetFavoriteGroup] = []
        var currentFavorite: WidgetBikePointData?
        var currentAlternatives: [WidgetBikePointData] = []

        for bikePoint in bikePoints {
            if bikePoint.isAlternative {
                currentAlternatives.append(bikePoint)
            } else {
                if let favorite = currentFavorite {
                    groups.append(
                        WidgetFavoriteGroup(
                            id: favorite.id,
                            favorite: favorite,
                            alternatives: currentAlternatives
                        )
                    )
                }
                currentFavorite = bikePoint
                currentAlternatives = []
            }
        }

        if let favorite = currentFavorite {
            groups.append(
                WidgetFavoriteGroup(
                    id: favorite.id,
                    favorite: favorite,
                    alternatives: currentAlternatives
                )
            )
        }

        return groups
    }

    private func limitedGroups(from groups: [WidgetFavoriteGroup]) -> [WidgetFavoriteGroup] {
        let groupsWithAlternatives = groups.filter { !$0.alternatives.isEmpty }.count
        let maxRows: Int
        switch groupsWithAlternatives {
        case 0:
            maxRows = 4
        case 1:
            maxRows = 3
        default:
            maxRows = 2
        }
        return Array(groups.prefix(maxRows))
    }
}

private struct WidgetFavoriteGroup: Identifiable {
    let id: String
    let favorite: WidgetBikePointData
    let alternatives: [WidgetBikePointData]
}

#Preview {
    LargeWidgetView(
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
                ),
                WidgetBikePointData(
                    id: "3",
                    displayName: "Wellington Arch",
                    actualName: "Wellington Arch, Hyde Park Corner",
                    standardBikes: 3,
                    eBikes: 5,
                    emptySpaces: 15,
                    distance: 680,
                    lastUpdated: Date()
                ),
                WidgetBikePointData(
                    id: "4",
                    displayName: "Speakers Corner",
                    actualName: "Speakers Corner, Hyde Park",
                    standardBikes: 12,
                    eBikes: 1,
                    emptySpaces: 7,
                    distance: 890,
                    lastUpdated: Date()
                ),
                WidgetBikePointData(
                    id: "5",
                    displayName: "Marble Arch",
                    actualName: "Marble Arch, Edgware Road",
                    standardBikes: 6,
                    eBikes: 4,
                    emptySpaces: 9,
                    distance: 1020,
                    lastUpdated: Date()
                )
            ],
            sortMode: "distance",
            lastRefresh: Date()
        )
    )
}
