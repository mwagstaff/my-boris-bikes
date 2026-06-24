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


private func displayDockId(attributes: DockActivityAttributes, state: DockActivityAttributes.ContentState) -> String {
    state.activeDockId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? state.activeDockId!
        : attributes.dockId
}

private func displayDockName(attributes: DockActivityAttributes, state: DockActivityAttributes.ContentState) -> String {
    state.activeDockName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? state.activeDockName!
        : attributes.dockName
}

private func displayAlias(attributes: DockActivityAttributes, state: DockActivityAttributes.ContentState) -> String? {
    if let alias = state.activeDockAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
        return alias
    }
    if let alias = attributes.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
        return alias
    }
    return nil
}

private func displayTitle(attributes: DockActivityAttributes, state: DockActivityAttributes.ContentState) -> String {
    displayAlias(attributes: attributes, state: state) ?? displayDockName(attributes: attributes, state: state)
}

private func activeJourneyPhase(attributes: DockActivityAttributes, state: DockActivityAttributes.ContentState) -> String? {
    if let phase = state.activeJourneyPhase?.trimmingCharacters(in: .whitespacesAndNewlines), !phase.isEmpty {
        return phase
    }
    if let phase = attributes.scheduledJourneyPhase?.trimmingCharacters(in: .whitespacesAndNewlines), !phase.isEmpty {
        return phase
    }
    return nil
}

private enum JourneyAvailabilityMetric {
    case standardBikes
    case eBikes
    case allBikes
    case spaces

    static func journeyMetric(
        attributes: DockActivityAttributes,
        state: DockActivityAttributes.ContentState,
        bikeDataFilter: BikeDataFilter
    ) -> JourneyAvailabilityMetric? {
        guard let phase = activeJourneyPhase(attributes: attributes, state: state) else {
            return nil
        }

        if phase == "end" {
            return .spaces
        }

        guard phase == "start" else {
            return nil
        }

        switch state.primaryDisplay {
        case LiveActivityPrimaryDisplay.bikes.rawValue:
            return .standardBikes
        case LiveActivityPrimaryDisplay.eBikes.rawValue:
            return .eBikes
        case "allBikes":
            return .allBikes
        default:
            switch bikeDataFilter {
            case .bikesOnly:
                return .standardBikes
            case .eBikesOnly:
                return .eBikes
            case .both:
                return .allBikes
            }
        }
    }

    var queryValue: String {
        switch self {
        case .standardBikes:
            return "bikes"
        case .eBikes:
            return "eBikes"
        case .allBikes:
            return "allBikes"
        case .spaces:
            return "spaces"
        }
    }
}

private struct JourneyAvailabilitySummary {
    let count: Int
    let label: String
    let threshold: Int

    init(
        metric: JourneyAvailabilityMetric,
        counts: BikeAvailabilityCounts,
        minBikes: Int,
        minEBikes: Int,
        minSpaces: Int
    ) {
        switch metric {
        case .standardBikes:
            count = counts.standardBikes
            label = counts.standardBikes == 1 ? "bike" : "bikes"
            threshold = minBikes
        case .eBikes:
            count = counts.eBikes
            label = counts.eBikes == 1 ? "e-bike" : "e-bikes"
            threshold = minEBikes
        case .allBikes:
            count = counts.totalBikes
            label = counts.totalBikes == 1 ? "bike" : "bikes"
            threshold = minBikes + minEBikes
        case .spaces:
            count = counts.emptySpaces
            label = counts.emptySpaces == 1 ? "space" : "spaces"
            threshold = minSpaces
        }
    }

    var color: Color {
        if count == 0 { return .red }
        if threshold > 0 && count < threshold { return .orange }
        return .green
    }

    var text: String {
        "\(count) \(label)"
    }
}

private struct AlternativeJourneyDockRow: View {
    let alternative: DockActivityAttributes.AlternativeDock
    let summary: JourneyAvailabilitySummary

    var body: some View {
        HStack(spacing: 6) {
            WidgetDonutChart(
                standardBikes: alternative.standardBikes,
                eBikes: alternative.eBikes,
                emptySpaces: alternative.emptySpaces,
                size: 30,
                strokeWidth: 5,
                centerText: extractInitials(from: alternative.name)
            )
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(alternative.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(summary.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(summary.color)
                    .lineLimit(1)
            }
        }
    }
}

private struct JourneyDockAvailabilityRow: View {
    let attributes: DockActivityAttributes
    let state: DockActivityAttributes.ContentState
    let summary: JourneyAvailabilitySummary
    let donutSize: CGFloat
    let strokeWidth: CGFloat
    let labelFontSize: CGFloat
    let dockFontSize: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            WidgetDonutChart(
                standardBikes: state.standardBikes,
                eBikes: state.eBikes,
                emptySpaces: state.emptySpaces,
                size: donutSize,
                strokeWidth: strokeWidth,
                centerText: extractInitials(from: displayTitle(attributes: attributes, state: state))
            )
            .fixedSize()

            Text(summary.text)
                .font(.system(size: labelFontSize, weight: .semibold))
                .foregroundColor(summary.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(displayDockName(attributes: attributes, state: state))
                .font(.system(size: dockFontSize, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
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

    private var journeySummary: JourneyAvailabilitySummary? {
        guard let metric = JourneyAvailabilityMetric.journeyMetric(
            attributes: attributes,
            state: state,
            bikeDataFilter: bikeDataFilter
        ) else {
            return nil
        }
        return JourneyAvailabilitySummary(
            metric: metric,
            counts: filteredCounts,
            minBikes: minBikes,
            minEBikes: minEBikes,
            minSpaces: minSpaces
        )
    }

    private var journeyMetric: JourneyAvailabilityMetric? {
        JourneyAvailabilityMetric.journeyMetric(
            attributes: attributes,
            state: state,
            bikeDataFilter: bikeDataFilter
        )
    }

    private var watchDetailURL: URL? {
        var components = URLComponents()
        components.scheme = "myborisbikes"
        components.host = "dock"
        components.path = "/\(displayDockId(attributes: attributes, state: state))"
        components.queryItems = [
            URLQueryItem(name: "bikeFilter", value: bikeDataFilter.rawValue),
            URLQueryItem(name: "minBikes", value: String(minBikes)),
            URLQueryItem(name: "minEBikes", value: String(minEBikes)),
            URLQueryItem(name: "minSpaces", value: String(minSpaces))
        ]
        if let journeyMetric {
            components.queryItems?.append(URLQueryItem(name: "journeyMetric", value: journeyMetric.queryValue))
        }
        return components.url
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary dock row: donut left, name + legend right
            if let journeySummary {
                JourneyDockAvailabilityRow(
                    attributes: attributes,
                    state: state,
                    summary: journeySummary,
                    donutSize: 36,
                    strokeWidth: 7,
                    labelFontSize: 13,
                    dockFontSize: 13,
                    spacing: 8
                )
            } else {
                HStack(spacing: 10) {
                    WidgetDonutChart(
                        standardBikes: state.standardBikes,
                        eBikes: state.eBikes,
                        emptySpaces: state.emptySpaces,
                        size: 36,
                        strokeWidth: 7,
                        centerText: extractInitials(from: displayTitle(attributes: attributes, state: state))
                    )
                    .fixedSize()

                    VStack(alignment: .leading, spacing: 2) {
                        // Alias (or dock name if no alias)
                        Text(displayTitle(attributes: attributes, state: state))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        // Full dock name shown in caption when alias is set
                        if let alias = displayAlias(attributes: attributes, state: state), alias != displayDockName(attributes: attributes, state: state) {
                            Text(displayDockName(attributes: attributes, state: state))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        HStack(spacing: 8) {
                            if bikeDataFilter.showsStandardBikes {
                                SmallLegendItem(
                                    color: standardBikeColor,
                                    count: filteredCounts.standardBikes,
                                    label: filteredCounts.standardBikes == 1 ? "bike" : "bikes",
                                    threshold: minBikes
                                )
                            }
                            if bikeDataFilter.showsEBikes {
                                SmallLegendItem(
                                    color: eBikeColor,
                                    count: filteredCounts.eBikes,
                                    label: filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes",
                                    threshold: minEBikes
                                )
                            }
                            SmallLegendItem(
                                color: emptySpaceColor,
                                count: filteredCounts.emptySpaces,
                                label: filteredCounts.emptySpaces == 1 ? "space" : "spaces",
                                threshold: minSpaces
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }
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
        .widgetURL(watchDetailURL)
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
                .widgetURL(lockScreenDetailURL)
        }
    }

    private var lockScreenAlternatives: [DockActivityAttributes.AlternativeDock] {
        Array(state.alternatives.prefix(3))
    }

    private var journeySummary: JourneyAvailabilitySummary? {
        guard let metric = JourneyAvailabilityMetric.journeyMetric(
            attributes: attributes,
            state: state,
            bikeDataFilter: bikeDataFilter
        ) else {
            return nil
        }
        return JourneyAvailabilitySummary(
            metric: metric,
            counts: filteredCounts,
            minBikes: minBikes,
            minEBikes: minEBikes,
            minSpaces: minSpaces
        )
    }

    private var journeyMetric: JourneyAvailabilityMetric? {
        JourneyAvailabilityMetric.journeyMetric(
            attributes: attributes,
            state: state,
            bikeDataFilter: bikeDataFilter
        )
    }

    private var lockScreenDetailURL: URL? {
        URL(string: "myborisbikes://journeys")
    }

    private func journeySummary(for alternative: DockActivityAttributes.AlternativeDock) -> JourneyAvailabilitySummary? {
        guard let journeyMetric else { return nil }
        let counts = bikeDataFilter.filteredCounts(
            standardBikes: alternative.standardBikes,
            eBikes: alternative.eBikes,
            emptySpaces: alternative.emptySpaces
        )
        return JourneyAvailabilitySummary(
            metric: journeyMetric,
            counts: counts,
            minBikes: minBikes,
            minEBikes: minEBikes,
            minSpaces: minSpaces
        )
    }

    @ViewBuilder
    private var lockScreenContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Primary dock row
                if let journeySummary {
                    JourneyDockAvailabilityRow(
                        attributes: attributes,
                        state: state,
                        summary: journeySummary,
                        donutSize: 42,
                        strokeWidth: 10,
                        labelFontSize: 16,
                        dockFontSize: 16,
                        spacing: 10
                    )
                } else {
                    HStack(spacing: 14) {
                        WidgetDonutChart(
                            standardBikes: state.standardBikes,
                            eBikes: state.eBikes,
                            emptySpaces: state.emptySpaces,
                            size: 42,
                            strokeWidth: 10,
                            centerText: extractInitials(from: displayTitle(attributes: attributes, state: state))
                        )
                        .fixedSize()

                        VStack(alignment: .leading, spacing: 4) {
                            if let alias = displayAlias(attributes: attributes, state: state) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alias)
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)
                                    Text(displayDockName(attributes: attributes, state: state))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(displayDockName(attributes: attributes, state: state))
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
                            if let summary = journeySummary(for: alt) {
                                AlternativeJourneyDockRow(
                                    alternative: alt,
                                    summary: summary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Text("Tap to manage")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(standardBikeColor)
        }
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
        if let rawValue = state.primaryDisplay,
           let display = LiveActivityPrimaryDisplay(rawValue: rawValue) {
            return display
        }
        // Check for per-dock override first, then fall back to global setting
        if let override = LiveActivityDockSettings.getPrimaryDisplay(for: displayDockId(attributes: attributes, state: state)) {
            return override
        }
        return LiveActivityPrimaryDisplay(rawValue: globalPrimaryDisplayRawValue) ?? .bikes
    }

    private var currentValue: Int {
        if state.primaryDisplay == "allBikes" {
            return state.standardBikes + state.eBikes
        }
        return primaryDisplay.primaryValue(standardBikes: state.standardBikes, eBikes: state.eBikes, emptySpaces: state.emptySpaces)
    }

    private var threshold: Int {
        if state.primaryDisplay == "allBikes" {
            return minBikes + minEBikes
        }
        switch primaryDisplay {
        case .bikes:
            return minBikes
        case .eBikes:
            return minEBikes
        case .spaces:
            return minSpaces
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
            centerText: extractInitials(from: displayTitle(attributes: attributes, state: state))
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
            Text(displayTitle(attributes: attributes, state: state))
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
            centerText: extractInitials(from: displayTitle(attributes: attributes, state: state))
        )
        .padding(3)
    }
}

// MARK: - Live Activity Widget

struct My_Boris_Bikes_WidgetLiveActivity: Widget {
    private var appLaunchURL: URL? {
        URL(string: "myborisbikes://journeys")
    }

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
            .widgetURL(appLaunchURL)
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
