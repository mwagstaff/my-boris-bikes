import SwiftUI

struct LiveActivityControlRow: View {
    let bikePoint: BikePoint
    @ObservedObject var liveActivityService = LiveActivityService.shared

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @State private var currentDisplay: LiveActivityPrimaryDisplay = .bikes

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var availableDisplays: [LiveActivityPrimaryDisplay] {
        LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
    }

    var body: some View {
        let isActivityActive = liveActivityService.isActivityActive(for: bikePoint.id)
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13))
                .foregroundColor(.blue)
                .symbolEffect(.pulse, isActive: isActivityActive)

            Text("Live Activity")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            ForEach(availableDisplays) { display in
                let isSelected = currentDisplay == display
                Button {
                    AnalyticsService.shared.track(
                        action: .preferenceUpdate,
                        screen: .favourites,
                        dock: AnalyticsDockInfo.from(bikePoint),
                        metadata: [
                            "preference": "live_activity_primary_display_dock",
                            "value": display.rawValue,
                            "source": "favorites_row"
                        ]
                    )
                    liveActivityService.setPrimaryDisplay(display, for: bikePoint.id)
                    currentDisplay = display
                } label: {
                    Text(display.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.blue : Color.blue.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.blue : Color.blue.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .onAppear {
            currentDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
        }
    }
}
