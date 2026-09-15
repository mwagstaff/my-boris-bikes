import CoreLocation
import SwiftUI

struct WatchStartMenu: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                menuLink(title: "Journeys", systemImage: "figure.outdoor.cycle", destination: .journeys)
                menuLink(title: "Favourites", systemImage: "star", destination: .favourites)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func menuLink(
        title: String,
        systemImage: String,
        destination: WatchHomeDestination
    ) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct WatchFavoriteJourneysList: View {
    let journeys: [WatchFavoriteJourney]
    let bikePointsByID: [String: WatchBikePoint]
    @ObservedObject private var locationService = WatchLocationService.shared

    private var sortedJourneys: [WatchFavoriteJourney] {
        guard let location = locationService.location else { return journeys }
        return journeys.sorted { first, second in
            let firstDistance = first.closestDockDistance(from: location) ?? .greatestFiniteMagnitude
            let secondDistance = second.closestDockDistance(from: location) ?? .greatestFiniteMagnitude
            if firstDistance == secondDistance {
                let firstName = first.docksOrderedByDistance(from: location).start.displayName
                let secondName = second.docksOrderedByDistance(from: location).start.displayName
                return firstName.localizedCaseInsensitiveCompare(secondName) == .orderedAscending
            }
            return firstDistance < secondDistance
        }
    }

    var body: some View {
        List {
            ForEach(sortedJourneys) { journey in
                WatchFavoriteJourneyRow(
                    journey: journey,
                    bikePointsByID: bikePointsByID,
                    userLocation: locationService.location
                )
                .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }
}

private struct WatchFavoriteJourneyRow: View {
    let journey: WatchFavoriteJourney
    let bikePointsByID: [String: WatchBikePoint]
    let userLocation: CLLocation?

    private var docks: (start: WatchFavoriteJourneyDock, destination: WatchFavoriteJourneyDock) {
        journey.docksOrderedByDistance(from: userLocation)
    }

    private var startBikePoint: WatchBikePoint? {
        bikePointsByID[docks.start.id]
    }

    private var distance: CLLocationDistance? {
        journey.closestDockDistance(from: userLocation)
    }

    var body: some View {
        HStack(spacing: 9) {
            WatchDonutChart(
                standardBikes: startBikePoint?.standardBikes ?? 0,
                eBikes: startBikePoint?.eBikes ?? 0,
                emptySpaces: startBikePoint?.emptyDocks ?? 0,
                size: 36
            )

            Text("\(docks.start.displayName) → \(docks.destination.displayName)")
                .font(.system(.caption, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)

            WatchDistanceIndicator(
                distance: distance,
                distanceString: distance.map(distanceString) ?? "?"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Journey from \(docks.start.displayName) to \(docks.destination.displayName)")
    }

    private func distanceString(_ distance: CLLocationDistance) -> String {
        distance < 1_000
            ? String(format: "%.0fm", distance)
            : String(format: "%.1fmi", distance * 0.000621371)
    }
}
