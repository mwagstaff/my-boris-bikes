//
//  My_Boris_Bikes_WidgetLiveActivity.swift
//  My Boris Bikes Widget
//
//  Live Activity UI for real-time dock availability tracking
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Helper Functions

private func extractInitials(from text: String) -> String {
    let words = text.split(separator: " ").filter { !$0.isEmpty }
    if words.isEmpty {
        return String(text.prefix(1)).uppercased()
    }
    let initials = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
    return initials.joined()
}

// MARK: - Live Activity Legend Item (local to this file)

private struct LiveActivityLegendItem: View {
    let color: Color
    let count: Int
    let label: String
    let threshold: Int

    private var textColor: Color {
        if count == 0 {
            return Color.red
        } else if count >= threshold {
            return Color.green
        } else {
            return Color.orange
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(count) \(label)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textColor)
        }
    }
}

// MARK: - Watch Smart Stack View (.small family, watchOS 11+ / iOS 18+)

@available(iOS 18.0, watchOS 11.0, *)
private struct WatchLiveActivityView: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes: Int = AlternativeDockSettings.defaultMinEBikes

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: state.standardBikes,
            eBikes: state.eBikes,
            emptySpaces: state.emptySpaces
        )
    }

    private let standardBikeColor = Color(red: 236/255, green: 0/255, blue: 0/255)
    private let eBikeColor        = Color(red: 12/255,  green: 17/255, blue: 177/255)
    private let emptySpaceColor   = Color(red: 117/255, green: 117/255, blue: 117/255)

    private var displayedAlternatives: [DockActivityAttributes.AlternativeDock] {
        Array(state.alternatives.prefix(3))
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary dock row: donut left, name + legend right
            HStack(spacing: 10) {
                WidgetDonutChart(
                    standardBikes: state.standardBikes,
                    eBikes: state.eBikes,
                    emptySpaces: state.emptySpaces,
                    size: 36,
                    strokeWidth: 7,
                    centerText: extractInitials(from: attributes.alias ?? attributes.dockName)
                )
                .fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    // Alias (or dock name if no alias)
                    Text(attributes.alias ?? attributes.dockName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    // Full dock name shown in caption when alias is set
                    if let alias = attributes.alias, !alias.isEmpty, alias != attributes.dockName {
                        Text(attributes.dockName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    HStack(spacing: 8) {
                        if bikeDataFilter.showsStandardBikes {
                            SmallLegendItem(color: standardBikeColor, count: filteredCounts.standardBikes, label: "bikes", threshold: minBikes)
                        }
                        if bikeDataFilter.showsEBikes {
                            SmallLegendItem(color: eBikeColor, count: filteredCounts.eBikes, label: "e-bikes", threshold: minEBikes)
                        }
                        SmallLegendItem(color: emptySpaceColor, count: filteredCounts.emptySpaces, label: "spaces", threshold: minSpaces)
                    }
                }

                Spacer(minLength: 0)
            }

            // Nearby alternatives: up to 3 donut charts centered horizontally
            if !displayedAlternatives.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.3))

                HStack {
                    Spacer(minLength: 0)
                    ForEach(displayedAlternatives, id: \.name) { alt in
                        WidgetDonutChart(
                            standardBikes: alt.standardBikes,
                            eBikes: alt.eBikes,
                            emptySpaces: alt.emptySpaces,
                            size: 27,
                            strokeWidth: 4.5,
                            centerText: extractInitials(from: alt.name)
                        )
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Explicit dark background so content is readable on the white Smart Stack card
        .background(Color.black)
        .foregroundColor(.white)
        // Tap opens the watch app and routes to WatchWidgetDetailView via the dock deep link
        .widgetURL(URL(string: "myborisbikes://dock/\(attributes.dockId)"))
    }
}

private struct SmallLegendItem: View {
    let color: Color
    let count: Int
    let label: String
    var threshold: Int = 0

    private var textColor: Color {
        if count == 0 { return .red }
        if threshold > 0 && count < threshold { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label.isEmpty ? "\(count)" : "\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
        }
    }
}

// MARK: - Lock Screen / Banner View

private struct DockLiveActivityView: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState

    @Environment(\.activityFamily) private var activityFamily

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes: Int = AlternativeDockSettings.defaultMinEBikes

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: state.standardBikes,
            eBikes: state.eBikes,
            emptySpaces: state.emptySpaces
        )
    }

    private let standardBikeColor = Color(red: 236/255, green: 0/255, blue: 0/255)
    private let eBikeColor = Color(red: 12/255, green: 17/255, blue: 177/255)
    private let emptySpaceColor = Color(red: 117/255, green: 117/255, blue: 117/255)

    var body: some View {
        // .small = Apple Watch Smart Stack (iOS 18+ / watchOS 11+)
        // .medium = iOS Lock Screen (default behaviour)
        if #available(iOS 18.0, watchOS 11.0, *), activityFamily == .small {
            WatchLiveActivityView(attributes: attributes, state: state)
                .activityBackgroundTint(Color.black)
        } else {
            lockScreenContent
                .activityBackgroundTint(Color(.systemBackground))
        }
    }

    private var lockScreenAlternatives: [DockActivityAttributes.AlternativeDock] {
        Array(state.alternatives.prefix(3))
    }

    @ViewBuilder
    private var lockScreenContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Primary dock row
            HStack(spacing: 14) {
                WidgetDonutChart(
                    standardBikes: state.standardBikes,
                    eBikes: state.eBikes,
                    emptySpaces: state.emptySpaces,
                    size: 42,
                    strokeWidth: 10,
                    centerText: extractInitials(from: attributes.alias ?? attributes.dockName)
                )
                .fixedSize()

                VStack(alignment: .leading, spacing: 4) {
                    if let alias = attributes.alias, !alias.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alias)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            Text(attributes.dockName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(attributes.dockName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                    }

                    HStack(spacing: 10) {
                        if bikeDataFilter.showsStandardBikes {
                            LiveActivityLegendItem(
                                color: standardBikeColor,
                                count: filteredCounts.standardBikes,
                                label: filteredCounts.standardBikes == 1 ? "bike" : "bikes",
                                threshold: minBikes
                            )
                        }
                        if bikeDataFilter.showsEBikes {
                            LiveActivityLegendItem(
                                color: eBikeColor,
                                count: filteredCounts.eBikes,
                                label: filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes",
                                threshold: minEBikes
                            )
                        }
                        LiveActivityLegendItem(
                            color: emptySpaceColor,
                            count: filteredCounts.emptySpaces,
                            label: filteredCounts.emptySpaces == 1 ? "space" : "spaces",
                            threshold: minSpaces
                        )
                    }
                }

                Spacer()
            }

            // Nearby alternatives: donut + name + vertical counts
            if !lockScreenAlternatives.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    ForEach(lockScreenAlternatives, id: \.name) { alt in
                        let altFiltered = bikeDataFilter.filteredCounts(
                            standardBikes: alt.standardBikes,
                            eBikes: alt.eBikes,
                            emptySpaces: alt.emptySpaces
                        )
                        HStack(spacing: 6) {
                            WidgetDonutChart(
                                standardBikes: alt.standardBikes,
                                eBikes: alt.eBikes,
                                emptySpaces: alt.emptySpaces,
                                size: 30,
                                strokeWidth: 5,
                                centerText: extractInitials(from: alt.name)
                            )
                            .fixedSize()

                            VStack(alignment: .leading, spacing: 1) {
                                Text(alt.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                if bikeDataFilter.showsStandardBikes {
                                    LiveActivityLegendItem(
                                        color: standardBikeColor,
                                        count: altFiltered.standardBikes,
                                        label: altFiltered.standardBikes == 1 ? "bike" : "bikes",
                                        threshold: minBikes
                                    )
                                }
                                if bikeDataFilter.showsEBikes {
                                    LiveActivityLegendItem(
                                        color: eBikeColor,
                                        count: altFiltered.eBikes,
                                        label: altFiltered.eBikes == 1 ? "e-bike" : "e-bikes",
                                        threshold: minEBikes
                                    )
                                }
                                LiveActivityLegendItem(
                                    color: emptySpaceColor,
                                    count: altFiltered.emptySpaces,
                                    label: altFiltered.emptySpaces == 1 ? "space" : "spaces",
                                    threshold: minSpaces
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Primary Display Number Views

private struct PrimaryDisplayText: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState
    let fontSize: CGFloat
    let fontWeight: Font.Weight

    @AppStorage(LiveActivityPrimaryDisplay.userDefaultsKey, store: LiveActivityPrimaryDisplay.userDefaultsStore)
    private var globalPrimaryDisplayRawValue: String = LiveActivityPrimaryDisplay.bikes.rawValue

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes: Int = AlternativeDockSettings.defaultMinEBikes

    private var primaryDisplay: LiveActivityPrimaryDisplay {
        // Check for per-dock override first, then fall back to global setting
        if let override = LiveActivityDockSettings.getPrimaryDisplay(for: attributes.dockId) {
            return override
        }
        return LiveActivityPrimaryDisplay(rawValue: globalPrimaryDisplayRawValue) ?? .bikes
    }

    private var currentValue: Int {
        primaryDisplay.primaryValue(standardBikes: state.standardBikes, eBikes: state.eBikes, emptySpaces: state.emptySpaces)
    }

    private var threshold: Int {
        switch primaryDisplay {
        case .bikes: return minBikes
        case .eBikes: return minEBikes
        case .spaces: return minSpaces
        }
    }

    private var displayColor: Color {
        if currentValue == 0 {
            return Color.red
        } else if currentValue >= threshold {
            return Color.green
        } else {
            return Color.orange
        }
    }

    var body: some View {
        Text("\(currentValue)")
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundColor(displayColor)
    }
}

// MARK: - Dynamic Island Views

private struct ExpandedLeadingView: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState

    var body: some View {
        WidgetDonutChart(
            standardBikes: state.standardBikes,
            eBikes: state.eBikes,
            emptySpaces: state.emptySpaces,
            size: 32,
            strokeWidth: 7,
            centerText: extractInitials(from: attributes.alias ?? attributes.dockName)
        )
    }
}

private struct ExpandedBottomView: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes: Int = AlternativeDockSettings.defaultMinEBikes

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: state.standardBikes,
            eBikes: state.eBikes,
            emptySpaces: state.emptySpaces
        )
    }

    private let standardBikeColor = Color(red: 236/255, green: 0/255, blue: 0/255)
    private let eBikeColor = Color(red: 12/255, green: 17/255, blue: 177/255)
    private let emptySpaceColor = Color(red: 117/255, green: 117/255, blue: 117/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributes.alias ?? attributes.dockName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 10) {
                if bikeDataFilter.showsStandardBikes {
                    LiveActivityLegendItem(
                        color: standardBikeColor,
                        count: filteredCounts.standardBikes,
                        label: filteredCounts.standardBikes == 1 ? "bike" : "bikes",
                        threshold: minBikes
                    )
                }
                if bikeDataFilter.showsEBikes {
                    LiveActivityLegendItem(
                        color: eBikeColor,
                        count: filteredCounts.eBikes,
                        label: filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes",
                        threshold: minEBikes
                    )
                }
                LiveActivityLegendItem(
                    color: emptySpaceColor,
                    count: filteredCounts.emptySpaces,
                    label: filteredCounts.emptySpaces == 1 ? "space" : "spaces",
                    threshold: minSpaces
                )
            }
        }
    }
}

private struct CompactDonutView: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState

    var body: some View {
        WidgetDonutChart(
            standardBikes: state.standardBikes,
            eBikes: state.eBikes,
            emptySpaces: state.emptySpaces,
            size: 22,
            strokeWidth: 4.5,
            centerText: extractInitials(from: attributes.alias ?? attributes.dockName)
        )
        .padding(3)
    }
}

// MARK: - Live Activity Widget

struct My_Boris_Bikes_WidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DockActivityAttributes.self) { context in
            DockLiveActivityView(
                attributes: context.attributes,
                state: context.state
            )
            .activitySystemActionForegroundColor(Color.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PrimaryDisplayText(attributes: context.attributes, state: context.state, fontSize: 20, fontWeight: .bold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(
                        attributes: context.attributes,
                        state: context.state
                    )
                }
            } compactLeading: {
                CompactDonutView(attributes: context.attributes, state: context.state)
            } compactTrailing: {
                PrimaryDisplayText(attributes: context.attributes, state: context.state, fontSize: 14, fontWeight: .bold)
            } minimal: {
                PrimaryDisplayText(attributes: context.attributes, state: context.state, fontSize: 12, fontWeight: .bold)
            }
            .widgetURL(URL(string: "myborisbikes://dock/\(context.attributes.dockId)"))
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

// MARK: - Previews

extension DockActivityAttributes {
    fileprivate static var preview: DockActivityAttributes {
        DockActivityAttributes(
            dockId: "BikePoints_1",
            dockName: "Hyde Park Corner, Hyde Park",
            alias: "Hyde Park"
        )
    }
}

extension DockActivityAttributes.ContentState {
    fileprivate static var sample: DockActivityAttributes.ContentState {
        DockActivityAttributes.ContentState(
            standardBikes: 5,
            eBikes: 3,
            emptySpaces: 12,
            alternatives: [
                DockActivityAttributes.AlternativeDock(name: "Warwick Row", standardBikes: 2, eBikes: 1, emptySpaces: 7),
                DockActivityAttributes.AlternativeDock(name: "Victoria Station", standardBikes: 0, eBikes: 3, emptySpaces: 14),
                DockActivityAttributes.AlternativeDock(name: "Eccleston Square", standardBikes: 4, eBikes: 0, emptySpaces: 4),
            ]
        )
    }

    fileprivate static var lowBikes: DockActivityAttributes.ContentState {
        DockActivityAttributes.ContentState(
            standardBikes: 1,
            eBikes: 0,
            emptySpaces: 19
        )
    }
}

#Preview("Notification", as: .content, using: DockActivityAttributes.preview) {
    My_Boris_Bikes_WidgetLiveActivity()
} contentStates: {
    DockActivityAttributes.ContentState.sample
    DockActivityAttributes.ContentState.lowBikes
}
