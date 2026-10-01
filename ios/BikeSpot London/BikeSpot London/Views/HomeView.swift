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
                .bikeSpotBackground()
                .navigationTitle("Favourites")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if let banner = bannerService.currentBanner {
                            ServiceStatusButton(severity: banner.severity) {
                                onShowServiceStatus?()
                            }
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { isShowingAddJourney = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New journey")
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
            
            Text("No favourites yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Use the map to find and save your favourite docks.")
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
    @State private var allAlternativesDock: BikePoint?
    @State private var showsOtherNearbyDocks = false
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
                    showAll: true
                ))
            }
            let display = effectivePrimaryDisplay(for: favorite.id)
            let hasLiveActivity = liveActivityService.isActivityActive(for: favorite.id)
            return (favorite.id, alternatives(
                for: favorite,
                favoriteIds: favoriteIds,
                startingPointFavoriteIds: startingPointIds,
                primaryDisplay: display,
                hasLiveActivity: hasLiveActivity,
                forceShow: true,
                maximumCount: 20
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

    private var visibleAlternativeDockIDs: [String] {
        let visibleIDs = alternativeDockMap.flatMap { dockID, alternatives in
            alternatives.prefix(allAlternativesDock?.id == dockID ? alternatives.count : 3).map(\.id)
        }
        let customIDs = bikePoints.flatMap { dockPreferences.customDockIDs(for: $0.id) ?? [] }
        let otherIDs = allAlternativesDock.map { showsOtherNearbyDocks ? otherNearbyDocks(for: $0).map(\.id) : [] } ?? []
        return Array(Set(visibleIDs + customIDs + otherIDs)).sorted()
    }

    private func otherNearbyDocks(for dock: BikePoint) -> [BikePoint] {
        AlternativeDockSelectionService.otherNearbyDocks(
            for: dock,
            allBikePoints: Array(availableBikePointsByID
                .merging(alternativeBikePointOverrides, uniquingKeysWith: { _, refreshed in refreshed }).values),
            excludingDockIDs: Set(dockPreferences.customDockIDs(for: dock.id) ?? [])
        )
    }

    private var alternativeDockIDsSignature: String {
        visibleAlternativeDockIDs.joined(separator: ",")
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
        alternativeDocksEnabled ? Set(bikePoints.map(\.id)) : []
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
                let previewAlternatives = Array(alternatives.prefix(AlternativeDockSelectionService.favoritePreviewCount))
                let hasMoreAlternatives = alternatives.count > previewAlternatives.count
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
                        .tint(.gray)

                        Button { editingAlternatives = bikePoint } label: {
                            Label("Alternatives", systemImage: "list.bullet")
                        }
                        .tint(.accentColor)
                    }

                    if hasFavoriteLiveActivity {
                        Button { allAlternativesDock = bikePoint } label: {
                            HStack {
                                Text("Alternative docks").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 4)
                                Text("See all").font(.caption)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }

                    if hasFavoriteLiveActivity {
                        LiveActivityControlRow(bikePoint: bikePoint, compact: true)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    } else {
                        NearbyDockFilterRow(
                            bikePoint: bikePoint,
                            isExpanded: isNearbyAlternativesExpanded,
                            onSeeAll: { allAlternativesDock = bikePoint },
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
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        } else if !alternatives.isEmpty {
                            ForEach(Array(previewAlternatives.enumerated()), id: \.element.id) { index, alternative in
                                let isLastAlternative = index == previewAlternatives.count - 1 && !hasMoreAlternatives
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
                                    .tint(.gray)
                                }
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                    dimensions.width - 16
                                }
                                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: isLastAlternative ? 6 : 2, trailing: 16))
                                .listRowSeparator(isLastAlternative && !hasLiveActivity ? .visible : .hidden)

                                if hasLiveActivity {
                                    LiveActivityControlRow(bikePoint: alternative, compact: true)
                                        .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                            dimensions.width - 16
                                        }
                                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: isLastAlternative ? 16 : 8, trailing: 16))
                                        .listRowSeparator(isLastAlternative ? .visible : .hidden)
                                }
                            }
                        } else {
                            Text(dockPreferences.customDockIDs(for: bikePoint.id) == nil
                                 ? "No nearby alternatives currently available"
                                 : "No custom alternatives selected.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16))
                        }
                    }
                }
            }
            .onDelete(perform: removeFavorites)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .sheet(item: $allAlternativesDock, onDismiss: { showsOtherNearbyDocks = false }) { dock in
            NavigationStack {
                List {
                    if dockPreferences.customDockIDs(for: dock.id) != nil {
                        Toggle("Other nearby docks", isOn: $showsOtherNearbyDocks)
                    }
                    Section {
                        let displayedDocks = showsOtherNearbyDocks ? otherNearbyDocks(for: dock)
                            : displayedAlternativeDockMap[dock.id] ?? []
                        if displayedDocks.isEmpty {
                            Text(showsOtherNearbyDocks ? "No other nearby docks available." : "No alternatives selected.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(displayedDocks) { alternative in
                            let distanceFromDock = CLLocation(latitude: dock.lat, longitude: dock.lon)
                                .distance(from: CLLocation(latitude: alternative.lat, longitude: alternative.lon))
                            AlternativeDockRowView(
                                bikePoint: alternative,
                                distance: showsOtherNearbyDocks
                                    ? (distanceFromDock < 1000 ? String(format: "%.0f m from this dock", distanceFromDock)
                                       : String(format: "%.1f miles from this dock", distanceFromDock / 1609.344))
                                    : locationService.distanceString(to: alternative.coordinate),
                                onTap: {
                                    allAlternativesDock = nil
                                    onBikePointSelected?(alternative)
                                }
                            )
                        }
                    } header: {
                        Text(showsOtherNearbyDocks ? "Other nearby docks · closest first" : favoritesService.displayName(for: dock))
                    }
                    AlternativeDocksEditButton(dock: ScheduledJourneyDock(bikePoint: dock))
                }
                .bikeSpotBackground(showsPhoto: false)
                .onChange(of: dockPreferences.customDockIDs(for: dock.id)) { _, ids in
                    if ids == nil { showsOtherNearbyDocks = false }
                }
                .navigationTitle("Alternative docks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { allAlternativesDock = nil }
                    }
                }
            }
        }
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
                            Text("Updated \(DockUpdateTime.string(from: lastUpdate))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
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
                allAlternativesDock = nil
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
                            Text(isShowingAllFavoriteJourneys ? collapsedFavoriteJourneysLabel : "See all")
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

        let ids = Set(visibleAlternativeDockIDs)
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
        forceShow: Bool = false,
        maximumCount: Int? = nil
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
        return Array(filteredCandidates.prefix(max(1, maximumCount ?? alternativeDocksMaxCount)))
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
        HStack(alignment: .top, spacing: 12) {
            SimplifiedDonutChart(
                standardBikes: startBikePoint?.standardBikes ?? 0,
                eBikes: startBikePoint?.eBikes ?? 0,
                emptySpaces: startBikePoint?.emptyDocks ?? 0,
                size: 44, displayMode: .bikes, bikeDataFilter: bikeDataFilter,
                hasAvailability: startBikePoint?.hasAvailabilityData == true
            )
            .accessibilityLabel(availabilityAccessibilityLabel)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(startDock.favoriteJourneyDisplayName(using: favoritesService)) → \(endDock.favoriteJourneyDisplayName(using: favoritesService))")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                DistanceIndicator(distance: distance, distanceString: distanceString)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Start journey from \(startDock.favoriteJourneyDisplayName(using: favoritesService)) to \(endDock.favoriteJourneyDisplayName(using: favoritesService))")
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
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
    @EnvironmentObject var liveActivityService: LiveActivityService

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        layout {
            Button {
                AnalyticsService.shared.trackDockTap(screen: .favourites, bikePoint: bikePoint, source: "favorites_list")
                onTap?()
            } label: {
                DockSummaryView(bikePoint: bikePoint, name: favoritesService.displayName(for: bikePoint),
                                distance: distance, isFavourite: true)
            }
            .buttonStyle(.plain)
            DockMonitoringButton(bikePoint: bikePoint, alternatives: liveActivityAlternatives, source: "favorites_row")
        }
        .padding(.vertical, 4)
    }
}

struct AlternativeDockRowView: View {
    let bikePoint: BikePoint
    let distance: String
    let onTap: (() -> Void)?
    @EnvironmentObject var favoritesService: FavoritesService

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        layout {
            Button {
                AnalyticsService.shared.trackDockTap(screen: .favourites, bikePoint: bikePoint, source: "alternative_dock")
                onTap?()
            } label: {
                DockSummaryView(bikePoint: bikePoint, name: favoritesService.displayName(for: bikePoint), distance: distance)
            }
            .buttonStyle(.plain)
            DockMonitoringButton(bikePoint: bikePoint, source: "alternative_row")
        }
        .padding(.vertical, 4)
    }
}

private struct DockMonitoringButton: View {
    let bikePoint: BikePoint
    var alternatives: [BikePoint] = []
    let source: String
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var liveActivityService: LiveActivityService

    private var isActive: Bool { liveActivityService.isActivityActive(for: bikePoint.id) }

    var body: some View {
        Button {
            AnalyticsService.shared.track(
                action: isActive ? .liveActivityEnd : .liveActivityStart,
                screen: .favourites, dock: AnalyticsDockInfo.from(bikePoint),
                metadata: ["source": source]
            )
            liveActivityService.startLiveActivity(for: bikePoint,
                alias: favoritesService.alias(for: bikePoint.id), alternatives: alternatives)
        } label: {
            Image(systemName: isActive ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(isActive ? Color.accentColor.opacity(0.1) : .clear, in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!bikePoint.hasAvailabilityData && !isActive)
        .accessibilityLabel("\(isActive ? "Stop" : "Start") monitoring \(favoritesService.displayName(for: bikePoint))")
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
            .bikeSpotBackground(showsPhoto: false)
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
