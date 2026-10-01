import SwiftUI
import UIKit

struct LiveActivityControlRow: View {
    let bikePoint: BikePoint
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        switch liveActivityService.activeJourneyPhase(for: bikePoint.id) {
        case .start:
            return LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
                .filter { $0 != .spaces }
        case .end:
            return [.spaces]
        case nil:
            return LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
        }
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
        VStack(spacing: 0) {
            let layout = compact && !dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 8))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                Label("Live Activity", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if compact {
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    availabilityPicker.pickerStyle(.menu).labelsHidden()
                } else {
                    availabilityPicker.pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 0 : 8)

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
        .onAppear {
            currentDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
        }
        .onChange(of: liveActivityService.primaryDisplayChangeToken) { _, _ in
            currentDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
        }
    }

    private var availabilityPicker: some View {
        Picker("Live Activity availability", selection: Binding(
            get: { currentDisplay },
            set: { display in
                AnalyticsService.shared.track(
                    action: .preferenceUpdate, screen: .favourites,
                    dock: AnalyticsDockInfo.from(bikePoint),
                    metadata: ["preference": "live_activity_primary_display_dock",
                               "value": display.rawValue, "source": "favorites_row"]
                )
                liveActivityService.setPrimaryDisplay(display, for: bikePoint.id)
                currentDisplay = display
            }
        )) {
            ForEach(availableDisplays) { display in Text(display.title).tag(display) }
        }
    }
}
