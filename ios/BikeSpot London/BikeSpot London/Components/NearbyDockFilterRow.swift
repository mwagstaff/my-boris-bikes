import SwiftUI

struct NearbyDockFilterRow: View {
    let bikePoint: BikePoint
    let isExpanded: Bool
    var onSeeAll: (() -> Void)? = nil
    let onToggleExpanded: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout())
            layout {
                Button(action: onToggleExpanded) {
                    HStack {
                        Text("Alternatives").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        Text("See all").font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isExpanded {
                Picker("Availability to find", selection: Binding(
                    get: { selectedDisplay },
                    set: { display in
                        AnalyticsService.shared.track(
                            action: .preferenceUpdate, screen: .favourites,
                            dock: AnalyticsDockInfo.from(bikePoint),
                            metadata: ["preference": "nearby_docks_primary_display_dock",
                                       "value": display.rawValue, "source": "favorites_row"]
                        )
                        liveActivityService.setPrimaryDisplay(display, for: bikePoint.id)
                    }
                )) {
                    ForEach(availableDisplays) { display in
                        Text(display.title).tag(display)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 0)
    }
}
