import SwiftUI

struct PreferencesView: View {
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.enabledKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksEnabled: Bool = false

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksMinSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksMinBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksMinEBikes: Int = AlternativeDockSettings.defaultMinEBikes

    @AppStorage(AlternativeDockSettings.distanceThresholdMilesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksDistanceThresholdMiles: Double = AlternativeDockSettings.defaultDistanceThresholdMiles

    @AppStorage(AlternativeDockSettings.maxCountKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksMaxCount: Int = AlternativeDockSettings.defaultMaxAlternatives

    @AppStorage(AlternativeDockSettings.widgetEnabledKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksWidgetEnabled: Bool = AlternativeDockSettings.defaultWidgetEnabled

    @AppStorage(AlternativeDockSettings.useStartingPointLogicKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksUseStartingPointLogic: Bool = AlternativeDockSettings.defaultUseStartingPointLogic

    @AppStorage(AlternativeDockSettings.useMinimumThresholdsKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksUseMinimumThresholds: Bool = AlternativeDockSettings.defaultUseMinimumThresholds

    @AppStorage(LiveActivityPrimaryDisplay.userDefaultsKey, store: LiveActivityPrimaryDisplay.userDefaultsStore)
    private var liveActivityPrimaryDisplayRawValue: String = LiveActivityPrimaryDisplay.bikes.rawValue

    private var liveActivityPrimaryDisplay: LiveActivityPrimaryDisplay {
        LiveActivityPrimaryDisplay(rawValue: liveActivityPrimaryDisplayRawValue) ?? .bikes
    }

    private var liveActivityPrimaryDisplayBinding: Binding<LiveActivityPrimaryDisplay> {
        Binding(
            get: { liveActivityPrimaryDisplay },
            set: { liveActivityPrimaryDisplayRawValue = $0.rawValue }
        )
    }

#if DEBUG
    @AppStorage(AppConstants.UserDefaults.liveActivityUseDevAPIKey, store: AppConstants.UserDefaults.sharedDefaults)
    private var liveActivityUseDevAPI: Bool = false

    @AppStorage(AppConstants.UserDefaults.liveActivityAutoRemoveDurationKey, store: AppConstants.UserDefaults.sharedDefaults)
    private var liveActivityAutoRemoveDurationSeconds: Double = AppConstants.LiveActivity.defaultAutoRemoveDurationSeconds

    @State private var debugRefreshStatus: String = "Not run yet"
    @State private var isDebugRefreshing = false
#endif

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var bikeDataFilterBinding: Binding<BikeDataFilter> {
        Binding(
            get: { bikeDataFilter },
            set: { bikeDataFilterRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bike Types") {
                    Picker("Show availability for", selection: bikeDataFilterBinding) {
                        ForEach(BikeDataFilter.allCases) { filter in
                            Text(filter.title)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bikeDataFilterRawValue) { _, _ in
                        // Reset primary display if current selection is no longer valid
                        let validCases = LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
                        if !validCases.contains(liveActivityPrimaryDisplay) {
                            liveActivityPrimaryDisplayRawValue = validCases.first?.rawValue ?? LiveActivityPrimaryDisplay.bikes.rawValue
                        }
                        trackPreferenceChange(key: BikeDataFilter.userDefaultsKey, value: bikeDataFilterRawValue)
                    }

                    Text("Show information on standard bikes, e-bikes, or both.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Live Activity") {
                    Picker("Primary number", selection: liveActivityPrimaryDisplayBinding) {
                        ForEach(LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)) { display in
                            Text(display.title)
                                .tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: liveActivityPrimaryDisplayRawValue) { _, newValue in
                        trackPreferenceChange(key: LiveActivityPrimaryDisplay.userDefaultsKey, value: newValue)
                    }

                    Text("The default number shown on the Dynamic Island and lock screen Live Activity.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

#if DEBUG
                    Picker("API Environment", selection: $liveActivityUseDevAPI) {
                        Text(LiveActivityAPIEnvironment.production.rawValue)
                            .tag(false)
                        Text(LiveActivityAPIEnvironment.development.rawValue)
                            .tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: liveActivityUseDevAPI) { _, newValue in
                        trackPreferenceChange(key: AppConstants.UserDefaults.liveActivityUseDevAPIKey, value: newValue)
                    }

                    Text(liveActivityUseDevAPI ? LiveActivityAPIEnvironment.development.description : LiveActivityAPIEnvironment.production.description)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Picker("Auto-remove duration", selection: $liveActivityAutoRemoveDurationSeconds) {
                        Text("1 minute (test)")
                            .tag(AppConstants.LiveActivity.debugAutoRemoveDurationSeconds)
                        Text("2 hours (default)")
                            .tag(AppConstants.LiveActivity.defaultAutoRemoveDurationSeconds)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: liveActivityAutoRemoveDurationSeconds) { _, newValue in
                        trackPreferenceChange(key: AppConstants.UserDefaults.liveActivityAutoRemoveDurationKey, value: newValue)
                    }

                    Text("Live activities will automatically end after this duration.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
#endif
                }

                Section("Alternative Docks") {
                    Text("Check your favourite docks have free bikes or spaces, depending on starting point distance.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        
                    Toggle("Show nearby alternatives", isOn: $alternativeDocksEnabled)
                        .onChange(of: alternativeDocksEnabled) { _, newValue in
                            trackPreferenceChange(key: AlternativeDockSettings.enabledKey, value: newValue)
                            if !newValue {
                                alternativeDocksWidgetEnabled = false
                                alternativeDocksUseStartingPointLogic = false
                            }
                        }

                    Toggle("Show in widgets (large only)", isOn: $alternativeDocksWidgetEnabled)
                        .disabled(!alternativeDocksEnabled)
                        .onChange(of: alternativeDocksWidgetEnabled) { _, newValue in
                            trackPreferenceChange(key: AlternativeDockSettings.widgetEnabledKey, value: newValue)
                        }

                    Group {
                        Stepper(value: $alternativeDocksMaxCount, in: 1...10) {
                            Text("Alternatives to show: \(alternativeDocksMaxCount)")
                        }
                        .onChange(of: alternativeDocksMaxCount) { _, newValue in
                            trackPreferenceChange(key: AlternativeDockSettings.maxCountKey, value: newValue)
                        }

                        Stepper(value: $alternativeDocksMinSpaces, in: 0...20) {
                            Text("Minimum free spaces: \(alternativeDocksMinSpaces)")
                        }
                        .onChange(of: alternativeDocksMinSpaces) { _, newValue in
                            trackPreferenceChange(key: AlternativeDockSettings.minSpacesKey, value: newValue)
                        }

                        if bikeDataFilter.showsStandardBikes {
                            Stepper(value: $alternativeDocksMinBikes, in: 0...20) {
                                Text("Minimum bikes: \(alternativeDocksMinBikes)")
                            }
                            .onChange(of: alternativeDocksMinBikes) { _, newValue in
                                trackPreferenceChange(key: AlternativeDockSettings.minBikesKey, value: newValue)
                            }
                        }

                        if bikeDataFilter.showsEBikes {
                            Stepper(value: $alternativeDocksMinEBikes, in: 0...20) {
                                Text("Minimum e-bikes: \(alternativeDocksMinEBikes)")
                            }
                            .onChange(of: alternativeDocksMinEBikes) { _, newValue in
                                trackPreferenceChange(key: AlternativeDockSettings.minEBikesKey, value: newValue)
                            }
                        }

                        Toggle("Use minimum thresholds for alternatives", isOn: $alternativeDocksUseMinimumThresholds)
                            .onChange(of: alternativeDocksUseMinimumThresholds) { _, newValue in
                                trackPreferenceChange(key: AlternativeDockSettings.useMinimumThresholdsKey, value: newValue)
                            }

                        Text("When off, alternatives are shown if they have any bikes or free spaces, even if they are below your minimum thresholds.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Toggle("Treat nearby docks as starting point", isOn: $alternativeDocksUseStartingPointLogic)
                            .onChange(of: alternativeDocksUseStartingPointLogic) { _, newValue in
                                trackPreferenceChange(key: AlternativeDockSettings.useStartingPointLogicKey, value: newValue)
                            }

                        Text("When enabled, nearby docks only use bike availability criteria, and distant docks only use the free spaces criteria. When disabled, alternatives appear if either bikes or spaces criteria is not met.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Picker("Starting point distance", selection: $alternativeDocksDistanceThresholdMiles) {
                            ForEach(AlternativeDockSettings.distanceOptions, id: \.self) { distance in
                                Text(distanceLabel(distance))
                                    .tag(distance)
                            }
                        }
                        .disabled(!alternativeDocksUseStartingPointLogic)
                        .onChange(of: alternativeDocksDistanceThresholdMiles) { _, newValue in
                            trackPreferenceChange(key: AlternativeDockSettings.distanceThresholdMilesKey, value: newValue)
                        }
                    }
                    .disabled(!alternativeDocksEnabled)
                }

#if DEBUG
                Section("Debug") {
                    Button(isDebugRefreshing ? "Refreshing…" : "Run Background Refresh") {
                        isDebugRefreshing = true
                        debugRefreshStatus = "Running..."
                        BackgroundRefreshService.shared.runImmediateRefresh { success, message in
                            let timestamp = DateFormatter.localizedString(
                                from: Date(),
                                dateStyle: .none,
                                timeStyle: .short
                            )
                            debugRefreshStatus = "\(timestamp) — \(message)"
                            if !success {
                                debugRefreshStatus += " (failed)"
                            }
                            isDebugRefreshing = false
                        }
                    }
                    .disabled(isDebugRefreshing)

                    Text(debugRefreshStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
#endif
            }
            .navigationTitle("Preferences")
        }
    }

    private func distanceLabel(_ distance: Double) -> String {
        if distance == 1.0 {
            return "1 mile"
        }
        return String(format: "%.1f miles", distance)
    }

    private func trackPreferenceChange(key: String, value: Any) {
        AnalyticsService.shared.track(
            action: .preferenceUpdate,
            screen: .preferences,
            metadata: [
                "preference": key,
                "value": value
            ]
        )
    }
}

#Preview {
    PreferencesView()
}
