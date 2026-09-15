//
//  WatchWidgetDetailView.swift
//  BikeSpot London Watch App
//
//  Detail view shown when tapping the watch live activity/widget.
//  Displays the tapped primary dock and nearby alternatives as full cards.
//

import SwiftUI
import CoreLocation

/// Haversine distance in metres between two coordinates.
private func widgetHaversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6_371_000.0
    let phi1 = lat1 * .pi / 180
    let phi2 = lat2 * .pi / 180
    let deltaPhi = (lat2 - lat1) * .pi / 180
    let deltaLambda = (lon2 - lon1) * .pi / 180

    let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
        + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

private enum WatchJourneyAlternativePurpose: String {
    case bikes
    case eBikes
    case allBikes
    case spaces

    var metric: JourneyMetric {
        switch self {
        case .bikes: return .bikes
        case .eBikes: return .eBikes
        case .allBikes: return .allBikes
        case .spaces: return .spaces
        }
    }
}

struct WatchWidgetDetailView: View {
    let primaryDockId: String
    let journeyMetricRawValue: String?
    let showsJourneyActions: Bool
    let autoRefresh: Bool
    let compactCards: Bool
    let alwaysShowsEndAction: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    init(primaryDockId: String, journeyMetricRawValue: String? = nil,
         showsJourneyActions: Bool = true, autoRefresh: Bool = false,
         compactCards: Bool = false, alwaysShowsEndAction: Bool = false) {
        self.showsJourneyActions = showsJourneyActions
        self.autoRefresh = autoRefresh
        self.compactCards = compactCards
        self.alwaysShowsEndAction = alwaysShowsEndAction
        self.primaryDockId = primaryDockId
        self.journeyMetricRawValue = journeyMetricRawValue
        _displayedDockId = State(initialValue: primaryDockId)
        _displayedJourneyMetricRawValue = State(initialValue: journeyMetricRawValue)
    }

    @StateObject private var viewModel = WatchFavoritesViewModel()
    @StateObject private var locationService = WatchLocationService.shared
    @ObservedObject private var favoritesService = WatchFavoritesService.shared

    @State private var primaryBikePoint: WatchBikePoint?
    @State private var primaryJourneyAvailability: JourneyAvailability?
    @State private var alternatives: [WatchBikePoint] = []
    @State private var isLoadingPrimary = true
    @State private var isLoadingAlternatives = false
    @State private var hasLoadedAlternatives = false
    @State private var alternativesLoadFailed = false
    @State private var isPerformingJourneyAction = false
    @State private var isRefreshing = false
    @State private var hasPendingRefresh = false
    @State private var journeyActionMessage: String?
    @State private var displayedDockId: String
    @State private var displayedJourneyMetricRawValue: String?

    @AppStorage(WatchThresholdSettings.minBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minBikes: Int = WatchThresholdSettings.defaultMinBikes

    @AppStorage(WatchThresholdSettings.minEBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minEBikes: Int = WatchThresholdSettings.defaultMinEBikes

    @AppStorage(WatchThresholdSettings.minSpacesKey, store: BikeDataFilter.userDefaultsStore)
    private var minSpaces: Int = WatchThresholdSettings.defaultMinSpaces

    @AppStorage(WatchThresholdSettings.useMinimumThresholdsKey, store: BikeDataFilter.userDefaultsStore)
    private var useMinimumThresholds: Bool = WatchThresholdSettings.defaultUseMinimumThresholds

    private var journeyPurpose: WatchJourneyAlternativePurpose? {
        guard let displayedJourneyMetricRawValue else { return nil }
        return WatchJourneyAlternativePurpose(rawValue: displayedJourneyMetricRawValue)
    }

    private var journeyActions: [WatchJourneyAction] {
        guard showsJourneyActions, let journeyPurpose else { return [] }
        if journeyPurpose == .spaces { return [.end] }
        return alwaysShowsEndAction ? [.advance, .end] : [.advance]
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear
                        .frame(height: 0)
                        .id("top")

                    if isLoadingPrimary {
                        loadingStateView
                    } else if let station = primaryBikePoint {
                        primarySection(station)
                        alternativesSection
                        journeyActionSection(scrollProxy: scrollProxy)
                    } else {
                        unavailableStateView
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(compactCards ? "Journey" : "Dock Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: favoritesService.dockPreferencesRevision) { _, _ in
            guard isVisible, scenePhase == .active else { return }
            Task { await refreshJourneyAndDock() }
        }
        .task(id: isVisible && scenePhase == .active) {
            guard isVisible, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refreshJourneyAndDock()
                guard autoRefresh else { return }
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .toolbar {
            if autoRefresh {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchRefreshButton(isLoading: isRefreshing) {
                        Task { await refreshJourneyAndDock() }
                    }
                    .accessibilityLabel("Refresh journey")
                }
            }
        }
    }

    // MARK: - Primary dock section

    @ViewBuilder
    private func primarySection(_ station: WatchBikePoint) -> some View {
        if compactCards {
            CompactJourneyDockAvailabilityCard(
                dockName: station.displayName,
                availability: primaryJourneyAvailability ?? journeyAvailability(for: station),
                distanceString: distanceString(for: station),
                metric: journeyPurpose?.metric ?? .allBikes,
                threshold: threshold(for: journeyPurpose),
                isPrimary: true
            )
        } else {
            DockAvailabilityCard(
                bikePoint: station,
                distanceString: distanceString(for: station),
                chartSize: 64,
                journeyPurpose: journeyPurpose
            )
        }
    }

    // MARK: - Alternatives section

    @ViewBuilder
    private var alternativesSection: some View {
        if isLoadingAlternatives {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading alternatives...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(favoritesService.customDockIDs(for: displayedDockId) == nil ? "Nearby alternatives" : "Preferred alternatives")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(.secondary)

                ForEach(alternatives, id: \.id) { alt in
                    if compactCards {
                        CompactJourneyDockAvailabilityCard(
                            dockName: alt.displayName,
                            availability: journeyAvailability(for: alt),
                            distanceString: distanceString(for: alt),
                            metric: journeyPurpose?.metric ?? .allBikes,
                            threshold: threshold(for: journeyPurpose),
                            isPrimary: false
                        )
                    } else {
                        DockAvailabilityCard(
                            bikePoint: alt,
                            distanceString: distanceString(for: alt),
                            chartSize: 52,
                            journeyPurpose: journeyPurpose
                        )
                    }
                }
            }
        } else if hasLoadedAlternatives {
            Text(alternativesLoadFailed ? "Couldn’t load alternatives." :
                    favoritesService.customDockIDs(for: displayedDockId) == nil
                        ? "No nearby alternatives found." : "No preferred alternatives available.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func journeyActionSection(scrollProxy: ScrollViewProxy) -> some View {
        if !journeyActions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(journeyActions) { action in
                    if action == .advance {
                        journeyActionButton(action, scrollProxy: scrollProxy)
                            .buttonStyle(.borderedProminent)
                    } else {
                        journeyActionButton(action, scrollProxy: scrollProxy)
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                }

                if let journeyActionMessage {
                    Text(journeyActionMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if !favoritesService.isConnectedToPhone {
                    Text("Requires iPhone connection.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, 4)
        }
    }

    private func journeyActionButton(
        _ action: WatchJourneyAction,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        Button {
            Task { await performJourneyAction(action, scrollProxy: scrollProxy) }
        } label: {
            HStack(spacing: 5) {
                if isPerformingJourneyAction { ProgressView().controlSize(.mini) }
                Text(action.title).font(.system(.caption, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isPerformingJourneyAction)
    }

    private func threshold(for purpose: WatchJourneyAlternativePurpose?) -> Int {
        switch purpose {
        case .bikes: return minBikes
        case .eBikes: return minEBikes
        case .allBikes: return minBikes + minEBikes
        case .spaces: return minSpaces
        case nil: return 0
        }
    }

    @ViewBuilder
    private var loadingStateView: some View {
        VStack(spacing: 8) {
            Text("Loading latest dock info...")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var unavailableStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Couldn’t load this dock")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func distanceString(for bikePoint: WatchBikePoint) -> String {
        locationService.distanceString(
            to: CLLocationCoordinate2D(latitude: bikePoint.lat, longitude: bikePoint.lon)
        )
    }

    private func journeyAvailability(for bikePoint: WatchBikePoint) -> JourneyAvailability {
        JourneyAvailability(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            spaces: bikePoint.emptyDocks,
            updatedAt: Date()
        )
    }

    private func refreshJourneyAndDock() async {
        guard isVisible, scenePhase == .active else { return }
        guard !isRefreshing else {
            hasPendingRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let shouldRefreshAgain = hasPendingRefresh && isVisible && scenePhase == .active
            hasPendingRefresh = false
            if shouldRefreshAgain { Task { await refreshJourneyAndDock() } }
        }

        if journeyPurpose != nil {
            _ = await WatchFavoritesService.shared.requestJourneyRefreshFromPhone()
        }
        guard !Task.isCancelled else { return }
        await loadDockDetails(preservingContent: primaryBikePoint != nil)
    }

    private func loadDockDetails(preservingContent: Bool = false) async {
        if !preservingContent {
            await MainActor.run {
                isLoadingPrimary = true
                isLoadingAlternatives = false
                hasLoadedAlternatives = false
                alternativesLoadFailed = false
                alternatives = []
            }
        }
        // Use existing in-memory favorites first for fast first paint.
        var primary = viewModel.favoriteBikePoints.first(where: { $0.id == displayedDockId })
        let isJourneyDock = journeyPurpose != nil
        var freshJourneyAvailability: JourneyAvailability?
        if preservingContent || isJourneyDock {
            if let refreshed = try? await WatchTfLAPIService.shared.fetchBikePoint(id: displayedDockId, cacheBusting: true).async() {
                primary = refreshed
                if isJourneyDock { freshJourneyAvailability = journeyAvailability(for: refreshed) }
            } else {
                primary = primaryBikePoint ?? primary
            }
        }
        if primary == nil {
            primary = try? await WatchTfLAPIService.shared
                .fetchBikePoint(id: displayedDockId)
                .async()
        }
        if primary == nil && !isJourneyDock {
            primary = try? await WatchTfLAPIService.shared
                .fetchBikePoint(id: displayedDockId, cacheBusting: true)
                .async()
        }

        if var resolved = primary {
            resolved.alias = WatchFavoritesService.shared.alias(for: resolved.id)
            primary = resolved
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            primaryBikePoint = primary
            isLoadingPrimary = false
            if let primary, isJourneyDock {
                let cached = JourneyStore.availability(for: primary.id)
                if let freshJourneyAvailability,
                   freshJourneyAvailability.updatedAt > (cached?.updatedAt ?? .distantPast) {
                    // Only a fresh network response can advance the shared timestamp.
                    JourneyStore.write(freshJourneyAvailability, key: "journeyAvailability.\(primary.id)")
                    primaryJourneyAvailability = freshJourneyAvailability
                    NotificationCenter.default.post(name: Notification.Name("journeySnapshotChanged"), object: nil)
                } else {
                    // An offline/cache fallback must not replace the parent's newer count.
                    primaryJourneyAvailability = cached ?? freshJourneyAvailability
                }
            }
        }

        // Refresh full favorites in the background for cache warming / widget freshness.
        Task { await viewModel.refreshData() }

        guard let primary else { return }
        await loadAlternatives(near: primary)
    }

    private func loadAlternatives(near primary: WatchBikePoint) async {
        let preferencesRevision = favoritesService.dockPreferencesRevision
        let customDockIDs = favoritesService.customDockIDs(for: primary.id)
        let coordinate = CLLocationCoordinate2D(latitude: primary.lat, longitude: primary.lon)
        guard customDockIDs != nil || (CLLocationCoordinate2DIsValid(coordinate) &&
              !(primary.lat == 0 && primary.lon == 0)) else {
            return
        }

        await MainActor.run { isLoadingAlternatives = true }

        do {
            var sortedAlternatives: [WatchBikePoint]
            if let customDockIDs {
                let chosenDocks = favoritesService.customAlternativesEnabled
                    ? try await WatchTfLAPIService.shared.fetchBikePointsInOrder(ids: customDockIDs)
                    : []
                // Keep the user's configured order and show their choices even when a
                // preferred alternative is currently below the availability threshold.
                sortedAlternatives = chosenDocks.filter(\.isAvailable)
            } else {
                let nearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                    lat: primary.lat,
                    lon: primary.lon,
                    radiusMeters: 500
                )
                sortedAlternatives = sortedAlternativeCandidates(from: nearby, primary: primary)

                // If the immediate area has no suitable alternatives, widen the radius once.
                if sortedAlternatives.isEmpty {
                    let expandedNearby = try await WatchTfLAPIService.shared.fetchNearbyBikePoints(
                        lat: primary.lat,
                        lon: primary.lon,
                        radiusMeters: 1000
                    )
                    sortedAlternatives = sortedAlternativeCandidates(from: expandedNearby, primary: primary)
                }
            }

            try Task.checkCancellation()
            let displayLimit = journeyPurpose == nil ? 5 : 3
            let displayedAlternatives = sortedAlternatives
                .prefix(customDockIDs == nil ? displayLimit : favoritesService.customAlternativeLimit(maximum: displayLimit))
                .map { dock in
                    var updated = dock
                    updated.alias = WatchFavoritesService.shared.alias(for: updated.id)
                    return updated
                }

            await MainActor.run {
                guard !Task.isCancelled,
                      primary.id == displayedDockId,
                      preferencesRevision == favoritesService.dockPreferencesRevision else { return }
                alternatives = Array(displayedAlternatives)
                hasLoadedAlternatives = true
                alternativesLoadFailed = false
                isLoadingAlternatives = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard primary.id == displayedDockId,
                      preferencesRevision == favoritesService.dockPreferencesRevision else { return }
                alternatives = []
                hasLoadedAlternatives = true
                alternativesLoadFailed = true
                isLoadingAlternatives = false
            }
        }
    }

    private func sortedAlternativeCandidates(
        from nearby: [WatchBikePoint],
        primary: WatchBikePoint
    ) -> [WatchBikePoint] {
        nearby
            .filter { candidate in
                candidate.id != primary.id &&
                    candidate.isAvailable &&
                    meetsJourneyRequirement(candidate)
            }
            .sorted {
                widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $0.lat, lon2: $0.lon) <
                    widgetHaversineDistance(lat1: primary.lat, lon1: primary.lon, lat2: $1.lat, lon2: $1.lon)
            }
    }

    private func meetsJourneyRequirement(_ bikePoint: WatchBikePoint) -> Bool {
        guard let journeyPurpose else {
            return bikePoint.isAvailable
        }

        if useMinimumThresholds {
            switch journeyPurpose {
            case .bikes:
                return bikePoint.standardBikes >= minBikes
            case .eBikes:
                return bikePoint.eBikes >= minEBikes
            case .allBikes:
                return bikePoint.standardBikes >= minBikes && bikePoint.eBikes >= minEBikes
            case .spaces:
                return bikePoint.emptyDocks >= minSpaces
            }
        }

        switch journeyPurpose {
        case .bikes:
            return bikePoint.standardBikes > 0
        case .eBikes:
            return bikePoint.eBikes > 0
        case .allBikes:
            return bikePoint.totalBikes > 0
        case .spaces:
            return bikePoint.emptyDocks > 0
        }
    }

    private func performJourneyAction(_ action: WatchJourneyAction, scrollProxy: ScrollViewProxy) async {
        await MainActor.run {
            isPerformingJourneyAction = true
            journeyActionMessage = nil
        }

        let result = await WatchFavoritesService.shared.performJourneyAction(
            action: action.rawValue,
            dockId: displayedDockId
        )

        await MainActor.run {
            isPerformingJourneyAction = false
            journeyActionMessage = result.success ? action.successMessage : "Couldn’t update journey."
        }

        guard result.success else { return }

        updateCachedJourney(after: action.rawValue)

        if action == .advance, let nextDockId = result.dockId {
            await MainActor.run {
                displayedDockId = nextDockId
                displayedJourneyMetricRawValue = result.journeyMetricRawValue ?? WatchJourneyAlternativePurpose.spaces.rawValue
                journeyActionMessage = nil
                withAnimation {
                    scrollProxy.scrollTo("top", anchor: .top)
                }
            }
            await loadDockDetails()
        }
    }
}

private enum WatchJourneyAction: String, Identifiable {
    case advance
    case end

    var id: String { rawValue }

    var title: String {
        switch self {
        case .advance:
            return "Next leg"
        case .end:
            return "End journey"
        }
    }

    var successMessage: String {
        switch self {
        case .advance:
            return "Journey advanced."
        case .end:
            return "Journey ended."
        }
    }
}

struct CompactJourneyDockAvailabilityCard: View {
    let dockName: String
    let availability: JourneyAvailability
    let distanceString: String?
    let metric: JourneyMetric
    let threshold: Int
    let isPrimary: Bool

    private var isLow: Bool {
        // Compact primary cards are shown only when the journey dock is low.
        // With both bike types selected, a shortage of either type is enough.
        isPrimary || metric.count(in: availability) < threshold
    }

    var body: some View {
        HStack(spacing: 9) {
            JourneyDonut(availability: availability, metric: metric, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(dockName)
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 5) {
                    JourneyAvailabilityLabel(
                        availability: availability,
                        metric: metric,
                        threshold: threshold,
                        isLowAvailability: isLow
                    )
                    if let distanceString, distanceString != "?" {
                        Text(distanceString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isPrimary && isLow ? Color.orange.opacity(0.18) : Color.white.opacity(0.09),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dockName), \(metric.count(in: availability)) \(metric.label(count: metric.count(in: availability)))\(isLow ? ", low availability" : "")")
    }
}

private struct DockAvailabilityCard: View {
    let bikePoint: WatchBikePoint
    let distanceString: String
    let chartSize: CGFloat
    let journeyPurpose: WatchJourneyAlternativePurpose?

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            VStack(spacing: 2) {
                Text(bikePoint.displayName)
                    .font(.system(.headline, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)

                if let alias = bikePoint.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alias.isEmpty,
                   alias != bikePoint.commonName {
                    Text(bikePoint.commonName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }

            if !distanceString.isEmpty {
                Text(distanceString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            WatchDonutChart(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                size: chartSize,
                centerValue: centerValue
            )
            .frame(maxWidth: .infinity, alignment: .center)

            WatchThresholdLegend(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                journeyPurpose: journeyPurpose
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var displayedStandardBikes: Int {
        switch journeyPurpose {
        case .spaces:
            return 0
        case .eBikes:
            return 0
        case .bikes, .allBikes, .none:
            return bikePoint.standardBikes
        }
    }

    private var displayedEBikes: Int {
        switch journeyPurpose {
        case .spaces:
            return 0
        case .bikes:
            return 0
        case .eBikes, .allBikes, .none:
            return bikePoint.eBikes
        }
    }

    private var displayedEmptySpaces: Int {
        journeyPurpose == nil || journeyPurpose == .spaces ? bikePoint.emptyDocks : 0
    }

    private var centerValue: Int {
        if journeyPurpose == .spaces {
            return bikePoint.emptyDocks
        }
        return displayedStandardBikes + displayedEBikes
    }
}

private enum WatchThresholdSettings {
    static let minSpacesKey = "alternativeDocksMinSpaces"
    static let minBikesKey = "alternativeDocksMinBikes"
    static let minEBikesKey = "alternativeDocksMinEBikes"
    static let useMinimumThresholdsKey = "alternativeDocksUseMinimumThresholds"

    static let defaultMinSpaces = 3
    static let defaultMinBikes = 3
    static let defaultMinEBikes = 3
    static let defaultUseMinimumThresholds = false
}

private struct WatchThresholdLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let journeyPurpose: WatchJourneyAlternativePurpose?

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(WatchThresholdSettings.minBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minBikes: Int = WatchThresholdSettings.defaultMinBikes

    @AppStorage(WatchThresholdSettings.minEBikesKey, store: BikeDataFilter.userDefaultsStore)
    private var minEBikes: Int = WatchThresholdSettings.defaultMinEBikes

    @AppStorage(WatchThresholdSettings.minSpacesKey, store: BikeDataFilter.userDefaultsStore)
    private var minSpaces: Int = WatchThresholdSettings.defaultMinSpaces

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: standardBikes,
            eBikes: eBikes,
            emptySpaces: emptySpaces
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsStandardBikes {
                WatchThresholdLegendItem(
                    color: .red,
                    count: filteredCounts.standardBikes,
                    label: filteredCounts.standardBikes == 1 ? "bike" : "bikes",
                    threshold: minBikes
                )
            }
            if showsEBikes {
                WatchThresholdLegendItem(
                    color: .blue,
                    count: filteredCounts.eBikes,
                    label: filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes",
                    threshold: minEBikes
                )
            }
            if showsSpaces {
                WatchThresholdLegendItem(
                    color: .gray.opacity(0.6),
                    count: filteredCounts.emptySpaces,
                    label: filteredCounts.emptySpaces == 1 ? "space" : "spaces",
                    threshold: minSpaces
                )
            }
        }
    }

    private var showsStandardBikes: Bool {
        switch journeyPurpose {
        case .spaces, .eBikes:
            return false
        case .bikes, .allBikes:
            return bikeDataFilter.showsStandardBikes
        case .none:
            return bikeDataFilter.showsStandardBikes
        }
    }

    private var showsEBikes: Bool {
        switch journeyPurpose {
        case .spaces, .bikes:
            return false
        case .eBikes, .allBikes:
            return bikeDataFilter.showsEBikes
        case .none:
            return bikeDataFilter.showsEBikes
        }
    }

    private var showsSpaces: Bool {
        journeyPurpose == nil || journeyPurpose == .spaces
    }
}

private struct WatchThresholdLegendItem: View {
    let color: Color
    let count: Int
    let label: String
    let threshold: Int

    private var textColor: Color {
        if count == 0 { return .red }
        if threshold > 0 && count < threshold { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(textColor)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(textColor)
                .lineLimit(1)
        }
        .frame(minWidth: 34)
    }
}

// MARK: - Compact alternative row

struct AlternativeDockRow: View {
    let bikePoint: WatchBikePoint
    let distanceString: String

    var body: some View {
        HStack(spacing: 6) {
            WatchDonutChart(
                standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes,
                emptySpaces: bikePoint.emptyDocks,
                size: 24
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(bikePoint.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 6) {
                    WatchDonutChartLegend(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks
                    )
                    .scaleEffect(0.85, anchor: .leading)

                    if !distanceString.isEmpty {
                        Text(distanceString)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        WatchWidgetDetailView(primaryDockId: "BikePoints_1")
    }
}
