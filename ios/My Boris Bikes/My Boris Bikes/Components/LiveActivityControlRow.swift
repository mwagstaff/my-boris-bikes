import SwiftUI
import UIKit

struct LiveActivityControlRow: View {
    let bikePoint: BikePoint
    @ObservedObject var liveActivityService = LiveActivityService.shared
    @StateObject private var locationService = LocationService.shared

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(LiveActivityArrivalSettings.enabledKey, store: LiveActivityArrivalSettings.userDefaultsStore)
    private var liveActivityAutoEndOnArrival: Bool = LiveActivityArrivalSettings.defaultEnabled

    @State private var currentDisplay: LiveActivityPrimaryDisplay = .bikes

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var availableDisplays: [LiveActivityPrimaryDisplay] {
        LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
    }

    private var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private var shouldShowAlwaysAuthorizationWarning: Bool {
        liveActivityService.isActivityActive(for: bikePoint.id) &&
        liveActivityAutoEndOnArrival &&
        locationService.authorizationStatus != .authorizedAlways
    }

    var body: some View {
        let isActivityActive = liveActivityService.isActivityActive(for: bikePoint.id)
        VStack(spacing: 0) {
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

            if shouldShowAlwaysAuthorizationWarning, let settingsURL {
                Divider()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .padding(.top, 2)

                    Text(.init("[Location permissions](\(settingsURL.absoluteString)) need to be \"Always\" for auto-end to work."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .tint(.orange)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .onAppear {
            currentDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
        }
    }
}
