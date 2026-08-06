import SwiftUI

struct NearbyDockFilterRow: View {
    let bikePoint: BikePoint
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    @ObservedObject private var liveActivityService = LiveActivityService.shared

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(LiveActivityPrimaryDisplay.userDefaultsKey, store: LiveActivityPrimaryDisplay.userDefaultsStore)
    private var liveActivityPrimaryDisplayRawValue: String = LiveActivityPrimaryDisplay.bikes.rawValue

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var availableDisplays: [LiveActivityPrimaryDisplay] {
        LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
    }

    private var selectedDisplay: LiveActivityPrimaryDisplay {
        let storedDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
        if availableDisplays.contains(storedDisplay) {
            return storedDisplay
        }

        let globalDisplay = LiveActivityPrimaryDisplay(rawValue: liveActivityPrimaryDisplayRawValue) ?? .bikes
        return availableDisplays.contains(globalDisplay) ? globalDisplay : (availableDisplays.first ?? .bikes)
    }

    var body: some View {
        let highlightColor = Color(.systemGreen)
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(highlightColor)

            Text(isExpanded ? "Nearby alternatives" : "Show nearby alternatives")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            if isExpanded {
                ForEach(availableDisplays) { display in
                    let isSelected = selectedDisplay == display
                    Button {
                        AnalyticsService.shared.track(
                            action: .preferenceUpdate,
                            screen: .favourites,
                            dock: AnalyticsDockInfo.from(bikePoint),
                            metadata: [
                                "preference": "nearby_docks_primary_display_dock",
                                "value": display.rawValue,
                                "source": "favorites_row"
                            ]
                        )
                        liveActivityService.setPrimaryDisplay(display, for: bikePoint.id)
                    } label: {
                        Text(display.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .white : highlightColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? highlightColor : highlightColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? highlightColor : highlightColor.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Show")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(highlightColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(highlightColor.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleExpanded()
        }
    }
}
