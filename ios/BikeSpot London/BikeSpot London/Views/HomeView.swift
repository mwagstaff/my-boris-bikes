import SwiftUI
import CoreLocation
import UIKit
import Combine

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var favoriteJourneyService = FavoriteJourneyService.shared
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var bannerService: BannerService
    @EnvironmentObject var scheduledJourneyService: ScheduledJourneyService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAddJourney = false
    @State private var journeyRestoreIconScale = 1.0
    @AppStorage(
        AppConstants.UserDefaults.favoriteJourneysSectionHiddenKey,
        store: AppConstants.UserDefaults.sharedDefaults
    ) private var isJourneySectionHidden = false
    let onBikePointSelected: ((BikePoint) -> Void)?
    let onShowServiceStatus: (() -> Void)?
    let onJourneyStarted: (() -> Void)?

    init(
        onBikePointSelected: ((BikePoint) -> Void)? = nil,
        onShowServiceStatus: (() -> Void)? = nil,
        onJourneyStarted: (() -> Void)? = nil
    ) {
        self.onBikePointSelected = onBikePointSelected
        self.onShowServiceStatus = onShowServiceStatus
        self.onJourneyStarted = onJourneyStarted
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    if favoritesService.favorites.isEmpty && favoriteJourneyService.journeys.isEmpty {
                        EmptyFavoritesView()
                    } else {
                        FavoritesListView(
                            bikePoints: viewModel.favoriteBikePoints,
                            allBikePoints: viewModel.allBikePoints,
                            favoriteJourneys: favoriteJourneyService.journeys,
                            showsJourneySection: !isJourneySectionHidden,
                            lastUpdateTime: viewModel.lastUpdateTime,
                            tflDataStaleWarning: viewModel.tflDataStaleWarning,
                            onBikePointSelected: onBikePointSelected,
                            onJourneyStarted: onJourneyStarted,
                            onHideJourneySection: { setJourneySectionHidden(true) }
                        )
                    }
                }
                .navigationTitle("Favourites")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if let banner = bannerService.currentBanner {
                            ServiceStatusButton(severity: banner.severity) {
                                onShowServiceStatus?()
                            }
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isJourneySectionHidden && !favoriteJourneyService.journeys.isEmpty {
                            Button {
                                setJourneySectionHidden(false)
                            } label: {
                                Image(systemName: "figure.outdoor.cycle")
                                    .scaleEffect(journeyRestoreIconScale)
                            }
                            .accessibilityLabel("Show favourite journeys")
                            .task(id: isJourneySectionHidden) {
                                await pulseJourneyRestoreIcon()
                            }
                        }
                    }
                }
                .sheet(isPresented: $isShowingAddJourney) {
                    AddJourneyView()
                }
                .refreshable {
                    await viewModel.refreshData()
                }
                .onAppear {
                    viewModel.setup(
                        favoritesService: favoritesService,
                        locationService: locationService
                    )
                    viewModel.refreshAlternativeDockDataIfStale()
                    handleWidgetRefreshRequest()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    Task {
                        await viewModel.refreshIfStale()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .widgetRefreshRequested)) { _ in
                    Task {
                        await viewModel.refreshData()
                    }
                }
                
                // Error banner at the top
                if let errorMessage = viewModel.errorMessage {
                    VStack {
                        ErrorBanner(
                            message: errorMessage,
                            onDismiss: {
                                viewModel.clearError()
                            }
                        )
                        Spacer()
                    }
                }
            }
        }
    }

    private func handleWidgetRefreshRequest() {
        let defaults = AppConstants.UserDefaults.sharedDefaults
        if defaults.bool(forKey: AppConstants.UserDefaults.widgetRefreshRequestKey) {
            defaults.set(false, forKey: AppConstants.UserDefaults.widgetRefreshRequestKey)
            Task {
                await viewModel.refreshData()
            }
        }
    }

    private func setJourneySectionHidden(_ hidden: Bool) {
        if reduceMotion {
            isJourneySectionHidden = hidden
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                isJourneySectionHidden = hidden
            }
        }
    }

    @MainActor
    private func pulseJourneyRestoreIcon() async {
        journeyRestoreIconScale = 1
        guard isJourneySectionHidden, !reduceMotion else { return }

        await Task.yield()
        withAnimation(.easeOut(duration: 0.14)) {
            journeyRestoreIconScale = 1.18
        }
        try? await Task.sleep(nanoseconds: 140_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            journeyRestoreIconScale = 1
        }
    }
}

struct EmptyFavoritesView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.slash")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            
            Text("No Favorites Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Use the map to find and add bike points to your favorites")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

struct FavoritesListView: View {
    let bikePoints: [BikePoint]
    let allBikePoints: [BikePoint]
    let favoriteJourneys: [FavoriteJourney]
    let showsJourneySection: Bool
    let lastUpdateTime: Date?
    let tflDataStaleWarning: String?
    let onBikePointSelected: ((BikePoint) -> Void)?
    let onJourneyStarted: (() -> Void)?
    let onHideJourneySection: () -> Void
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var locationService: LocationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    @State private var editingBikePoint: BikePoint?
    @State private var editingAlternatives: BikePoint?
    @ObservedObject private var dockPreferences = DockPreferencesService.shared
    @State private var isShowingAllFavoriteJourneys = false
    @State private var alternativeBikePointOverrides: [String: BikePoint] = [:]
    @State private var expandedNearbyAlternatives: Set<String> = []
    @State private var showingAllCustomAlternatives: Set<String> = []
    @State private var dismissedAutoExpandedAlternatives: Set<String> = []
    @State private var alternativeDockRefreshRequest: AnyCancellable?
    @ObservedObject private var liveActivityService = LiveActivityService.shared
    private let alternativeRefreshTimer = Timer.publish(
        every: AppConstants.App.refreshInterval,
        tolerance: AppConstants.App.refreshInterval * 0.1,
        on: .main,
        in: .common
    ).autoconnect()

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

    @AppStorage(AlternativeDockSettings.useStartingPointLogicKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksUseStartingPointLogic: Bool = AlternativeDockSettings.defaultUseStartingPointLogic

    @AppStorage(AlternativeDockSettings.useMinimumThresholdsKey, store: AlternativeDockSettings.userDefaultsStore)
    private var alternativeDocksUseMinimumThresholds: Bool = AlternativeDockSettings.defaultUseMinimumThresholds

    @AppStorage(LiveActivityPrimaryDisplay.userDefaultsKey, store: LiveActivityPrimaryDisplay.userDefaultsStore)
    private var liveActivityPrimaryDisplayRawValue: String = LiveActivityPrimaryDisplay.bikes.rawValue

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var globalPrimaryDisplay: LiveActivityPrimaryDisplay {
        LiveActivityPrimaryDisplay(rawValue: liveActivityPrimaryDisplayRawValue) ?? .bikes
    }

    private func effectivePrimaryDisplay(for dockId: String) -> LiveActivityPrimaryDisplay {
        let preferredDisplay = liveActivityService.getPrimaryDisplay(for: dockId)
        let availableDisplays = LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
        return availableDisplays.contains(preferredDisplay) ? preferredDisplay : globalPrimaryDisplay
    }

    private var alternativeDockMap: [String: [BikePoint]] {
        guard alternativeDocksEnabled else { return [:] }

        let favoriteIds = Set(bikePoints.map { $0.id })
        let startingPointIds = startingPointFavoriteIds()
        return Dictionary(uniqueKeysWithValues: bikePoints.map { favorite in
            if let savedDocks = dockPreferences.customDocks(for: favorite.id) {
                let availableData = Array(availableBikePointsByID
                    .merging(alternativeBikePointOverrides, uniquingKeysWith: { _, refreshed in refreshed }).values)
                return (favorite.id, AlternativeDockSelectionService.savedAlternativesForFavorites(
                    for: favorite.id,
                    savedDocks: savedDocks,
                    allBikePoints: availableData,
                    showAll: showingAllCustomAlternatives.contains(favorite.id)
                ))
            }
            let display = effectivePrimaryDisplay(for: favorite.id)
            let hasLiveActivity = liveActivityService.isActivityActive(for: favorite.id)
            let isExpanded = expandedNearbyAlternatives.contains(favorite.id)
            return (favorite.id, alternatives(
                for: favorite,
                favoriteIds: favoriteIds,
                startingPointFavoriteIds: startingPointIds,
                primaryDisplay: display,
                hasLiveActivity: hasLiveActivity,
                forceShow: isExpanded
            ))
        })
    }

    private var displayedAlternativeDockMap: [String: [BikePoint]] {
        Dictionary(uniqueKeysWithValues: alternativeDockMap.map { key, alternatives in
            (key, alternatives.map { alternativeBikePointOverrides[$0.id] ?? $0 })
        })
    }

    private var liveActivityStartAlternativeDockMap: [String: [BikePoint]] {
        guard alternativeDocksEnabled else { return [:] }
        guard !allBikePoints.isEmpty else { return [:] }

        let favoriteIds = Set(bikePoints.map { $0.id })
        let startingPointIds = startingPointFavoriteIds()
        return Dictionary(uniqueKeysWithValues: bikePoints.map { favorite in
            let display = effectivePrimaryDisplay(for: favorite.id)
            return (favorite.id, alternatives(
                for: favorite,
                favoriteIds: favoriteIds,
                startingPointFavoriteIds: startingPointIds,
                primaryDisplay: display,
                hasLiveActivity: true
            ))
        })
    }

    private var displayedLiveActivityStartAlternativeDockMap: [String: [BikePoint]] {
        Dictionary(uniqueKeysWithValues: liveActivityStartAlternativeDockMap.map { key, alternatives in
            (key, alternatives.map { alternativeBikePointOverrides[$0.id] ?? $0 })
        })
    }

    private var alternativeDockIDsSignature: String {
        Set(alternativeDockMap.values.flatMap { $0.map(\.id) })
            .sorted()
            .joined(separator: ",")
    }

    /// Changes when allBikePoints is refreshed, triggering a re-fetch of alternative dock data
    private var allBikePointsSignature: String {
        "\(allBikePoints.count)-\(allBikePoints.first?.id ?? "")-\(allBikePoints.last?.id ?? "")"
    }

    private var autoExpandedDockIDsSignature: String {
        autoExpandedAlternativeDockIds
            .sorted()
            .joined(separator: ",")
    }

    private var favoriteIDsSignature: String {
        bikePoints.map(\.id)
            .sorted()
            .joined(separator: ",")
    }

    private var favoriteJourneysByDistance: [FavoriteJourney] {
        guard let userLocation = locationService.location else { return favoriteJourneys }

        return favoriteJourneys.sorted { first, second in
            let firstDistance = first.closestDockDistance(from: userLocation)
            let secondDistance = second.closestDockDistance(from: userLocation)

            if firstDistance == secondDistance {
                let firstDock = first.docksOrderedByDistance(from: userLocation).first
                let secondDock = second.docksOrderedByDistance(from: userLocation).first
                return firstDock.name.localizedCaseInsensitiveCompare(secondDock.name) == .orderedAscending
            }

            return firstDistance < secondDistance
        }
    }

    private var nearbyFavoriteJourneys: [FavoriteJourney] {
        guard let userLocation = locationService.location else { return [] }
        return favoriteJourneysByDistance.filter {
            $0.closestDockDistance(from: userLocation) <= 1_000
        }
    }

    private var collapsedFavoriteJourneys: [FavoriteJourney] {
        guard locationService.location != nil else { return [] }
        return nearbyFavoriteJourneys.isEmpty
            ? Array(favoriteJourneysByDistance.prefix(1))
            : nearbyFavoriteJourneys
    }

    private var displayedFavoriteJourneys: [FavoriteJourney] {
        isShowingAllFavoriteJourneys ? favoriteJourneysByDistance : collapsedFavoriteJourneys
    }

    private var hasAdditionalFavoriteJourneys: Bool {
        collapsedFavoriteJourneys.count < favoriteJourneys.count
    }

    private var collapsedFavoriteJourneysLabel: String {
        locationService.location != nil && nearbyFavoriteJourneys.isEmpty
            ? "Nearest only"
            : "Nearby only"
    }

    private var collapsedFavoriteJourneysAccessibilityLabel: String {
        locationService.location != nil && nearbyFavoriteJourneys.isEmpty
            ? "Show nearest favourite journey"
            : "Show nearby favourite journeys only"
    }

    private var availableBikePointsByID: [String: BikePoint] {
        (allBikePoints + bikePoints).reduce(into: [:]) { result, bikePoint in
            result[bikePoint.id] = bikePoint
        }
    }
    
    private var autoExpandedAlternativeDockIds: Set<String> {
        guard alternativeDocksEnabled else { return [] }
        let startingPointIds = startingPointFavoriteIds()

        return Set(bikePoints.compactMap { favorite in
            let hasLiveActivity = liveActivityService.isActivityActive(for: favorite.id)
            let display = effectivePrimaryDisplay(for: favorite.id)
            return shouldShowAlternatives(
                for: favorite,
                primaryDisplay: display,
                startingPointFavoriteIds: startingPointIds,
                hasLiveActivity: hasLiveActivity
            ) ? favorite.id : nil
        })
    }

    var body: some View {
        let autoExpandedDockIds = autoExpandedAlternativeDockIds
        List {
            if showsJourneySection && !favoriteJourneys.isEmpty {
                let bikePointsByID = availableBikePointsByID
                favoriteJourneysSection(bikePointsByID: bikePointsByID)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            ForEach(bikePoints, id: \.id) { bikePoint in
                let alternatives = displayedAlternativeDockMap[bikePoint.id] ?? []
                let hasMoreCustomAlternatives = (dockPreferences.customDockIDs(for: bikePoint.id)?.count ?? 0)
                    > AlternativeDockSelectionService.favoritePreviewCount
                let isShowingAllCustomAlternatives = showingAllCustomAlternatives.contains(bikePoint.id)
                let liveActivityAlternatives = displayedLiveActivityStartAlternativeDockMap[bikePoint.id] ?? []
                let hasFavoriteLiveActivity = liveActivityService.isActivityActive(for: bikePoint.id)
                let isNearbyAlternativesExpanded = isNearbyAlternativesExpanded(
                    for: bikePoint.id,
                    autoExpandedDockIds: autoExpandedDockIds
                )
                Section {
                    FavoriteRowView(
                        bikePoint: bikePoint,
                        distance: locationService.distanceString(to: bikePoint.coordinate),
                        onTap: {
                            onBikePointSelected?(bikePoint)
                        },
                        liveActivityAlternatives: liveActivityAlternatives
                    )
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                        dimensions.width - 16
                    }
                    .listRowSeparator(.hidden, edges: .bottom)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            AnalyticsService.shared.track(
                                action: .favoriteRemove,
                                screen: .favourites,
                                dock: AnalyticsDockInfo.from(bikePoint),
                                metadata: ["source": "swipe"]
                            )
                            favoritesService.removeFavorite(bikePoint.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            editingBikePoint = bikePoint
                        } label: {
                            Label("Edit Name", systemImage: "pencil")
                        }
                        .tint(.blue)

                        Button { editingAlternatives = bikePoint } label: {
                            Label("Alternatives", systemImage: "list.bullet")
                        }
                        .tint(.indigo)
                    }

                    AlternativeDocksEditButton(dock: ScheduledJourneyDock(bikePoint: bikePoint))
                        .font(.footnote)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)

                    if hasFavoriteLiveActivity {
                        LiveActivityControlRow(bikePoint: bikePoint)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    } else {
                        NearbyDockFilterRow(
                            bikePoint: bikePoint,
                            isExpanded: isNearbyAlternativesExpanded,
                            onToggleExpanded: {
                                toggleNearbyAlternatives(
                                    for: bikePoint.id,
                                    autoExpandedDockIds: autoExpandedDockIds
                                )
                            }
                        )
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                            .listRowSeparator(.hidden)
                    }

                    if isNearbyAlternativesExpanded {
                        if alternativeDocksEnabled && allBikePoints.isEmpty && dockPreferences.customDockIDs(for: bikePoint.id) == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading alternatives…")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 32, bottom: 6, trailing: 16))
                        } else if !alternatives.isEmpty {
                            ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, alternative in
                                let isLastAlternative = index == alternatives.count - 1 && !hasMoreCustomAlternatives
                                let hasLiveActivity = liveActivityService.isActivityActive(for: alternative.id)
                                AlternativeDockRowView(
                                    bikePoint: alternative,
                                    distance: locationService.distanceString(to: alternative.coordinate),
                                    onTap: {
                                        onBikePointSelected?(alternative)
                                    }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button { editingBikePoint = alternative } label: {
                                        Label("Edit Name", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                    dimensions.width - 16
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: isLastAlternative ? 16 : 4, trailing: 16))
                                .listRowSeparator(isLastAlternative && !hasLiveActivity ? .visible : .hidden)

                                if hasLiveActivity {
                                    LiveActivityControlRow(bikePoint: alternative)
                                        .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                            dimensions.width - 16
                                        }
                                        .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: isLastAlternative ? 16 : 8, trailing: 16))
                                        .listRowSeparator(isLastAlternative ? .visible : .hidden)
                                }
                            }
                            if hasMoreCustomAlternatives {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                        expandedNearbyAlternatives.insert(bikePoint.id)
                                        dismissedAutoExpandedAlternatives.remove(bikePoint.id)
                                        if isShowingAllCustomAlternatives {
                                            showingAllCustomAlternatives.remove(bikePoint.id)
                                        } else {
                                            showingAllCustomAlternatives.insert(bikePoint.id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(isShowingAllCustomAlternatives ? "View fewer alternate docks" : "View more alternate docks")
                                        Image(systemName: isShowingAllCustomAlternatives ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                    .frame(minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(isShowingAllCustomAlternatives ? "Expanded" : "Collapsed")
                                .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 8, trailing: 16))
                            }
                        } else {
                            Text(dockPreferences.customDockIDs(for: bikePoint.id) == nil
                                 ? "No nearby alternatives currently available"
                                 : "No custom alternatives selected.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .listRowInsets(EdgeInsets(top: 2, leading: 32, bottom: 12, trailing: 16))
                        }
                    }
                }
            }
            .onDelete(perform: removeFavorites)
        }
        .listStyle(PlainListStyle())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let warning = tflDataStaleWarning {
                    TflDataWarningBanner(message: warning)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                if let lastUpdate = lastUpdateTime {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Updated \(formatTime(lastUpdate))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))
                        Spacer()
                    }
                    .padding(.bottom, 8)
                    .background(.clear)
                }
            }
        }
        .sheet(item: $editingAlternatives) { bikePoint in
            AlternativeDocksEditor(dock: ScheduledJourneyDock(bikePoint: bikePoint))
        }
        .sheet(item: $editingBikePoint) { bikePoint in
                FavoriteAliasEditor(
                    bikePoint: bikePoint,
                    initialAlias: favoritesService.alias(for: bikePoint.id) ?? "",
                    onSave: { alias in
                        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                        AnalyticsService.shared.track(
                            action: .favoriteAliasUpdate,
                            screen: .favourites,
                            dock: AnalyticsDockInfo.from(bikePoint),
                            metadata: [
                                "has_alias": (trimmedAlias?.isEmpty == false)
                            ]
                        )
                        favoritesService.updateAlias(for: bikePoint.id, alias: alias)
                        editingBikePoint = nil
                    },
                    onRemove: {
                        AnalyticsService.shared.track(
                            action: .favoriteAliasRemove,
                            screen: .favourites,
                            dock: AnalyticsDockInfo.from(bikePoint)
                        )
                        favoritesService.updateAlias(for: bikePoint.id, alias: nil)
                        editingBikePoint = nil
                    },
                onCancel: {
                    editingBikePoint = nil
                }
            )
        }
        .onAppear {
            refreshVisibleAlternativeDockData()
        }
        .onChange(of: dockPreferences.revision) { _, _ in
            refreshVisibleAlternativeDockData()
            pruneExpandedAlternatives()
        }
        .onChange(of: alternativeDockIDsSignature) { _, _ in
            refreshVisibleAlternativeDockData()
            pruneExpandedAlternatives()
        }
        .onChange(of: allBikePointsSignature) { _, _ in
            refreshVisibleAlternativeDockData()
        }
        .onChange(of: autoExpandedDockIDsSignature) { _, _ in
            pruneExpandedAlternatives()
        }
        .onChange(of: favoriteIDsSignature) { _, _ in
            pruneExpandedAlternatives()
        }
        .onChange(of: hasAdditionalFavoriteJourneys) { _, hasAdditionalJourneys in
            if !hasAdditionalJourneys {
                isShowingAllFavoriteJourneys = false
            }
        }
        .onChange(of: alternativeDocksEnabled) { _, _ in
            refreshVisibleAlternativeDockData()
            if !alternativeDocksEnabled {
                expandedNearbyAlternatives.removeAll()
                showingAllCustomAlternatives.removeAll()
                dismissedAutoExpandedAlternatives.removeAll()
            }
        }
        .onReceive(alternativeRefreshTimer) { _ in
            // Skip network refreshes while backgrounded; data is refreshed by
            // the willEnterForeground handler on return.
            guard UIApplication.shared.applicationState != .background else { return }
            refreshVisibleAlternativeDockData()
        }
        .onDisappear {
            alternativeDockRefreshRequest?.cancel()
        }
    }

    private func favoriteJourneysSection(bikePointsByID: [String: BikePoint]) -> some View {
        Section {
            if displayedFavoriteJourneys.isEmpty {
                Text("Current location unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayedFavoriteJourneys) { journey in
                    let docks = journey.docksOrderedByDistance(from: locationService.location)
                    let distance = locationService.location.map { journey.closestDockDistance(from: $0) }

                    FavoriteJourneyCompactRow(
                        startDock: docks.first,
                        endDock: docks.second,
                        startBikePoint: bikePointsByID[docks.first.id],
                        bikeDataFilter: bikeDataFilter,
                        distance: distance,
                        distanceString: locationService.distanceString(to: docks.first.favoriteCoordinate),
                        onStart: {
                            onJourneyStarted?()
                            Task {
                                await adHocJourneyService.createAndStart(
                                    startDock: docks.first,
                                    endDock: docks.second
                                )
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Journeys")

                Spacer(minLength: 8)

                if hasAdditionalFavoriteJourneys {
                    Button(action: toggleAllFavoriteJourneys) {
                        HStack(spacing: 3) {
                            Text(isShowingAllFavoriteJourneys ? collapsedFavoriteJourneysLabel : "View all")
                            Image(systemName: isShowingAllFavoriteJourneys ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isShowingAllFavoriteJourneys
                            ? collapsedFavoriteJourneysAccessibilityLabel
                            : "View all favourite journeys"
                    )
                }

                Button(action: onHideJourneySection) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide favourite journeys")
            }
            .textCase(nil)
        }
    }

    private func toggleAllFavoriteJourneys() {
        if reduceMotion {
            isShowingAllFavoriteJourneys.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                isShowingAllFavoriteJourneys.toggle()
            }
        }
    }
    
    private func removeFavorites(offsets: IndexSet) {
        // Create array of IDs to remove
        let bikePointsToRemove = offsets.map { bikePoints[$0] }
        let idsToRemove = bikePointsToRemove.map { $0.id }

        for bikePoint in bikePointsToRemove {
            AnalyticsService.shared.track(
                action: .favoriteRemove,
                screen: .favourites,
                dock: AnalyticsDockInfo.from(bikePoint),
                metadata: ["source": "bulk_delete"]
            )
        }

        // Remove from favorites service
        for id in idsToRemove {
            favoritesService.removeFavorite(id)
        }
    }

    private func refreshVisibleAlternativeDockData() {
        guard alternativeDocksEnabled else {
            alternativeDockRefreshRequest?.cancel()
            alternativeDockRefreshRequest = nil
            alternativeBikePointOverrides.removeAll()
            return
        }

        let customIDs = bikePoints.flatMap { dockPreferences.customDockIDs(for: $0.id) ?? [] }
        let ids = Set(alternativeDockMap.values.flatMap { $0.map(\.id) } + customIDs)
        guard !ids.isEmpty else {
            alternativeDockRefreshRequest?.cancel()
            alternativeDockRefreshRequest = nil
            alternativeBikePointOverrides.removeAll()
            return
        }

        alternativeBikePointOverrides = alternativeBikePointOverrides.filter { ids.contains($0.key) }
        alternativeDockRefreshRequest?.cancel()
        alternativeDockRefreshRequest = TfLAPIService.shared
            .fetchMultipleBikePoints(ids: Array(ids), cacheBusting: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [self] bikePoints in
                    let refreshed = bikePoints.reduce(into: [String: BikePoint]()) { result, bikePoint in
                        result[bikePoint.id] = bikePoint
                    }
                    var updatedOverrides = self.alternativeBikePointOverrides
                    updatedOverrides.merge(refreshed) { _, new in new }
                    self.alternativeBikePointOverrides = updatedOverrides
                }
            )
    }

    private func toggleNearbyAlternatives(
        for dockId: String,
        autoExpandedDockIds: Set<String>
    ) {
        let isAutoExpanded = autoExpandedDockIds.contains(dockId)
        let isExpanded = isNearbyAlternativesExpanded(
            for: dockId,
            autoExpandedDockIds: autoExpandedDockIds
        )

        if isExpanded {
            expandedNearbyAlternatives.remove(dockId)
            showingAllCustomAlternatives.remove(dockId)
            if isAutoExpanded {
                dismissedAutoExpandedAlternatives.insert(dockId)
            }
        } else {
            dismissedAutoExpandedAlternatives.remove(dockId)
            expandedNearbyAlternatives.insert(dockId)
        }
    }

    private func pruneExpandedAlternatives() {
        let favoriteIds = Set(bikePoints.map(\.id))
        expandedNearbyAlternatives = Set(expandedNearbyAlternatives.filter { favoriteIds.contains($0) })
        showingAllCustomAlternatives = showingAllCustomAlternatives.filter {
            favoriteIds.contains($0) && (dockPreferences.customDockIDs(for: $0)?.count ?? 0)
                > AlternativeDockSelectionService.favoritePreviewCount
        }
        let autoExpandedDockIds = autoExpandedAlternativeDockIds
        dismissedAutoExpandedAlternatives = Set(
            dismissedAutoExpandedAlternatives.filter { dockId in
                favoriteIds.contains(dockId) && autoExpandedDockIds.contains(dockId)
            }
        )
    }

    private func isNearbyAlternativesExpanded(
        for dockId: String,
        autoExpandedDockIds: Set<String>
    ) -> Bool {
        if expandedNearbyAlternatives.contains(dockId) {
            return true
        }

        if liveActivityService.isActivityActive(for: dockId) && autoExpandedDockIds.contains(dockId) {
            return true
        }

        return autoExpandedDockIds.contains(dockId) &&
            !dismissedAutoExpandedAlternatives.contains(dockId)
    }

    private func shouldShowAlternatives(
        for favorite: BikePoint,
        primaryDisplay: LiveActivityPrimaryDisplay,
        startingPointFavoriteIds: Set<String>,
        hasLiveActivity: Bool
    ) -> Bool {
        if hasLiveActivity {
            return isBelowThreshold(for: favorite, primaryDisplay: primaryDisplay)
        }

        let needsBikes = !hasSufficientBikes(for: favorite)
        let needsSpaces = favorite.emptyDocks < alternativeDocksMinSpaces

        if alternativeDocksUseStartingPointLogic {
            let isStartingPoint = startingPointFavoriteIds.contains(favorite.id)
            return isStartingPoint ? needsBikes : needsSpaces
        }

        return needsBikes || needsSpaces
    }

    private func isBelowThreshold(
        for bikePoint: BikePoint,
        primaryDisplay: LiveActivityPrimaryDisplay
    ) -> Bool {
        switch primaryDisplay {
        case .bikes:
            return bikePoint.standardBikes < alternativeDocksMinBikes
        case .eBikes:
            return bikePoint.eBikes < alternativeDocksMinEBikes
        case .spaces:
            return bikePoint.emptyDocks < alternativeDocksMinSpaces
        }
    }

    private func alternatives(
        for favorite: BikePoint,
        favoriteIds: Set<String>,
        startingPointFavoriteIds: Set<String>,
        primaryDisplay: LiveActivityPrimaryDisplay,
        hasLiveActivity: Bool,
        forceShow: Bool = false
    ) -> [BikePoint] {
        let shouldShowAlternatives = shouldShowAlternatives(
            for: favorite,
            primaryDisplay: primaryDisplay,
            startingPointFavoriteIds: startingPointFavoriteIds,
            hasLiveActivity: hasLiveActivity
        )

        guard forceShow || shouldShowAlternatives else { return [] }

        let candidates = AlternativeDockSelectionService.orderedCandidates(
            for: favorite,
            allBikePoints: Array(Dictionary(allBikePoints.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                .merging(alternativeBikePointOverrides, uniquingKeysWith: { _, refreshed in refreshed }).values),
            excludingFavoriteIDs: favoriteIds,
            customDockIDs: dockPreferences.customDockIDs(for: favorite.id)
        )
        let filteredCandidates = candidates.filter { bikePoint in
            meetsPrimaryDisplayRequirement(for: bikePoint, primaryDisplay: primaryDisplay)
        }
        return Array(filteredCandidates.prefix(max(1, alternativeDocksMaxCount)))
    }

    private func startingPointFavoriteIds() -> Set<String> {
        guard alternativeDocksUseStartingPointLogic else { return [] }
        guard !bikePoints.isEmpty else { return [] }
        guard let userLocation = locationService.location else {
            return Set(bikePoints.map { $0.id })
        }

        let thresholdMeters = alternativeDocksDistanceThresholdMiles * AlternativeDockSettings.metersPerMile
        let favoritesWithinThreshold = bikePoints.filter { favorite in
            let favoriteLocation = CLLocation(latitude: favorite.lat, longitude: favorite.lon)
            return userLocation.distance(from: favoriteLocation) <= thresholdMeters
        }

        if !favoritesWithinThreshold.isEmpty {
            return Set(favoritesWithinThreshold.map { $0.id })
        }

        if let nearestFavorite = bikePoints.min(by: { first, second in
            let firstLocation = CLLocation(latitude: first.lat, longitude: first.lon)
            let secondLocation = CLLocation(latitude: second.lat, longitude: second.lon)
            return userLocation.distance(from: firstLocation) < userLocation.distance(from: secondLocation)
        }) {
            return [nearestFavorite.id]
        }

        return []
    }

    private func hasSufficientBikes(for bikePoint: BikePoint) -> Bool {
        switch bikeDataFilter {
        case .bikesOnly:
            return bikePoint.standardBikes >= alternativeDocksMinBikes
        case .eBikesOnly:
            return bikePoint.eBikes >= alternativeDocksMinEBikes
        case .both:
            return bikePoint.standardBikes >= alternativeDocksMinBikes &&
                bikePoint.eBikes >= alternativeDocksMinEBikes
        }
    }

    private func meetsPrimaryDisplayRequirement(
        for bikePoint: BikePoint,
        primaryDisplay: LiveActivityPrimaryDisplay
    ) -> Bool {
        if alternativeDocksUseMinimumThresholds {
            switch primaryDisplay {
            case .bikes:
                return bikePoint.standardBikes >= alternativeDocksMinBikes
            case .eBikes:
                return bikePoint.eBikes >= alternativeDocksMinEBikes
            case .spaces:
                return bikePoint.emptyDocks >= alternativeDocksMinSpaces
            }
        }

        switch primaryDisplay {
        case .bikes:
            return bikePoint.standardBikes > 0
        case .eBikes:
            return bikePoint.eBikes > 0
        case .spaces:
            return bikePoint.emptyDocks > 0
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct FavoriteJourneyCompactRow: View {
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    let startBikePoint: BikePoint?
    let bikeDataFilter: BikeDataFilter
    let distance: CLLocationDistance?
    let distanceString: String
    let onStart: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService

    var body: some View {
        HStack(spacing: 8) {
            SimplifiedDonutChart(
                standardBikes: startBikePoint?.standardBikes ?? 0,
                eBikes: startBikePoint?.eBikes ?? 0,
                emptySpaces: startBikePoint?.emptyDocks ?? 0,
                size: 34,
                displayMode: .bikes,
                bikeDataFilter: bikeDataFilter
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(availabilityAccessibilityLabel)

            Text("\(startDock.favoriteJourneyDisplayName(using: favoritesService)) → \(endDock.favoriteJourneyDisplayName(using: favoritesService))")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            DistanceIndicator(distance: distance, distanceString: distanceString)
                .fixedSize(horizontal: true, vertical: false)

            Button(action: onStart) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                "Start journey from \(startDock.favoriteJourneyDisplayName(using: favoritesService)) to \(endDock.favoriteJourneyDisplayName(using: favoritesService))"
            )
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 16))
    }

    private var availabilityAccessibilityLabel: String {
        guard let startBikePoint else {
            return "Bike availability updating for \(startDock.favoriteJourneyDisplayName(using: favoritesService))"
        }

        let counts = bikeDataFilter.filteredCounts(
            standardBikes: startBikePoint.standardBikes,
            eBikes: startBikePoint.eBikes,
            emptySpaces: startBikePoint.emptyDocks
        )
        return "\(counts.totalBikes) bikes available at \(startDock.favoriteJourneyDisplayName(using: favoritesService))"
    }
}

private extension ScheduledJourneyDock {
    var favoriteCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func favoriteJourneyDisplayName(using favoritesService: FavoritesService) -> String {
        favoritesService.alias(for: id) ?? name
    }
}

struct FavoriteRowView: View {
    let bikePoint: BikePoint
    let distance: String
    let onTap: (() -> Void)?
    var liveActivityAlternatives: [BikePoint] = []
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var liveActivityService: LiveActivityService

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue
    
    @State private var previousStandardBikes: Int?
    @State private var previousEBikes: Int?
    @State private var previousEmptyDocks: Int?
    @State private var isFlashing = false

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks
        )
    }
    
    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: bikePoint.coordinate)
    }
    
    private var hasDataChanged: Bool {
        guard let prevStandard = previousStandardBikes,
              let prevEBikes = previousEBikes,
              let prevEmpty = previousEmptyDocks else {
            return false
        }
        
        return prevStandard != filteredCounts.standardBikes ||
               prevEBikes != filteredCounts.eBikes ||
               prevEmpty != filteredCounts.emptySpaces
    }
    
    var body: some View {
        Button(action: {
            AnalyticsService.shared.trackDockTap(
                screen: .favourites,
                bikePoint: bikePoint,
                source: "favorites_list"
            )
            onTap?()
        }) {
            HStack(spacing: 16) {
                DonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 50
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favourite dock")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    if let alias = favoritesService.alias(for: bikePoint.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alias)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            
                            Text(bikePoint.commonName)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text(bikePoint.commonName)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    
                    HStack(alignment: .top) {
                        DonutChartLegend(
                            standardBikes: bikePoint.standardBikes,
                            eBikes: bikePoint.eBikes,
                            emptySpaces: bikePoint.emptyDocks,
                            showLabels: true,
                            spacesOnSecondLine: true,
                            useStatusColors: true
                        )
                        
                        Spacer()
                        
                        DistanceIndicator(
                            distance: numericDistance,
                            distanceString: distance
                        )
                    }
                }
                
                Button {
                    let alias = favoritesService.alias(for: bikePoint.id)
                    let isActive = liveActivityService.isActivityActive(for: bikePoint.id)
                    let action: AnalyticsAction = isActive ? .liveActivityEnd : .liveActivityStart
                    AnalyticsService.shared.track(
                        action: action,
                        screen: .favourites,
                        dock: AnalyticsDockInfo.from(bikePoint),
                        metadata: ["source": "favorites_row"]
                    )
                    liveActivityService.startLiveActivity(
                        for: bikePoint,
                        alias: alias,
                        alternatives: liveActivityAlternatives
                    )
                } label: {
                    let isActive = liveActivityService.isActivityActive(for: bikePoint.id)
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundColor(isActive ? .white : .accentColor.opacity(0.7))
                        .symbolEffect(.pulse, isActive: isActive)
                        .frame(width: 28, height: 28)
                        .background(isActive ? Color.blue : Color.clear)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(isActive ? Color.blue : Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())

                if !bikePoint.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, 4)
        .opacity(bikePoint.isAvailable ? 1.0 : 0.6)
        .background(
            Rectangle()
                .fill(Color.blue.opacity(isFlashing ? 0.2 : 0.0))
                .animation(.easeInOut(duration: 0.3), value: isFlashing)
        )
        .onAppear {
            // Initialize previous values on first appearance
            updatePreviousCounts()
        }
        .onChange(of: bikeDataFilterRawValue) { _, _ in
            updatePreviousCounts()
        }
        .onChange(of: bikePoint.standardBikes) { _, _ in
            checkForChangesAndFlash()
        }
        .onChange(of: bikePoint.eBikes) { _, _ in
            checkForChangesAndFlash()
        }
        .onChange(of: bikePoint.emptyDocks) { _, _ in
            checkForChangesAndFlash()
        }
    }
    
    private func checkForChangesAndFlash() {
        // Only flash if we have previous values and data actually changed
        if hasDataChanged {
            // Trigger flash effect
            withAnimation(.easeInOut(duration: 0.15)) {
                isFlashing = true
            }
            
            // Flash off after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isFlashing = false
                }
            }
        }
        
        // Update previous values for next comparison
        updatePreviousCounts()
    }

    private func updatePreviousCounts() {
        previousStandardBikes = filteredCounts.standardBikes
        previousEBikes = filteredCounts.eBikes
        previousEmptyDocks = filteredCounts.emptySpaces
    }
}

struct AlternativeDockRowView: View {
    let bikePoint: BikePoint
    let distance: String
    let onTap: (() -> Void)?
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var liveActivityService: LiveActivityService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: bikePoint.coordinate)
    }

    private var hasAvailabilityData: Bool {
        bikePoint.additionalProperties.contains {
            $0.key == "NbStandardBikes" || $0.key == "NbEBikes" || $0.key == "NbEmptyDocks"
        }
    }

    var body: some View {
        Button(action: {
            AnalyticsService.shared.trackDockTap(
                screen: .favourites,
                bikePoint: bikePoint,
                source: "alternative_dock"
            )
            onTap?()
        }) {
            HStack(spacing: 12) {
                if hasAvailabilityData {
                    DonutChart(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks,
                        size: 44,
                        strokeWidth: 12
                    )
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Availability unavailable")
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(favoritesService.displayName(for: bikePoint))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    
                    if favoritesService.alias(for: bikePoint.id) != nil {
                        Text(bikePoint.commonName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(alignment: .top) {
                        if hasAvailabilityData {
                            DonutChartLegend(
                                standardBikes: bikePoint.standardBikes,
                                eBikes: bikePoint.eBikes,
                                emptySpaces: bikePoint.emptyDocks,
                                showLabels: true,
                                spacesOnSecondLine: true,
                                useStatusColors: true
                            )
                            .scaleEffect(0.9, anchor: .leading)
                        } else {
                            Text("Availability unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        DistanceIndicator(
                            distance: numericDistance,
                            distanceString: distance
                        )
                        .scaleEffect(0.9, anchor: .trailing)
                    }
                }
                
                Button {
                    let isActive = liveActivityService.isActivityActive(for: bikePoint.id)
                    let action: AnalyticsAction = isActive ? .liveActivityEnd : .liveActivityStart
                    AnalyticsService.shared.track(
                        action: action,
                        screen: .favourites,
                        dock: AnalyticsDockInfo.from(bikePoint),
                        metadata: ["source": "alternative_row"]
                    )
                    liveActivityService.startLiveActivity(for: bikePoint, alias: favoritesService.alias(for: bikePoint.id))
                } label: {
                    let isActive = liveActivityService.isActivityActive(for: bikePoint.id)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 9))
                        .foregroundColor(isActive ? .white : .accentColor.opacity(0.7))
                        .symbolEffect(.pulse, isActive: isActive)
                        .frame(width: 24, height: 24)
                        .background(isActive ? Color.blue : Color.clear)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(isActive ? Color.blue : Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!hasAvailabilityData && !liveActivityService.isActivityActive(for: bikePoint.id))

                if hasAvailabilityData && !bikePoint.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption2)
                        .accessibilityLabel("Dock unavailable")
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        )
        .opacity(!hasAvailabilityData || bikePoint.isAvailable ? 0.9 : 0.6)
    }
}

struct SortMenu: View {
    let sortMode: SortMode
    let onSortModeChanged: (SortMode) -> Void
    
    var body: some View {
        Menu {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Button {
                    onSortModeChanged(mode)
                } label: {
                    HStack {
                        Text(mode.displayName)
                        if mode == sortMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

struct FavoriteAliasEditor: View {
    let bikePoint: BikePoint
    let initialAlias: String
    let onSave: (String?) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void
    
    @State private var alias: String
    
    init(
        bikePoint: BikePoint,
        initialAlias: String,
        onSave: @escaping (String?) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.bikePoint = bikePoint
        self.initialAlias = initialAlias
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _alias = State(initialValue: initialAlias)
    }
    
    private var hasAlias: Bool {
        !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !initialAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Alias", text: $alias)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Custom alias")
                } footer: {
                    Text("This name is used wherever this dock appears.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Original name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(bikePoint.commonName)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
                
                if hasAlias {
                    Button(role: .destructive) {
                        alias = ""
                        onRemove()
                    } label: {
                        Label("Remove Alias", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle("Edit Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(alias)
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(LocationService.shared)
        .environmentObject(FavoritesService.shared)
        .environmentObject(BannerService.shared)
}
