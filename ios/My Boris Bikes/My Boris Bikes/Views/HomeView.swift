import SwiftUI
import CoreLocation
import UIKit
import Combine

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var bannerService: BannerService
    let onBikePointSelected: ((BikePoint) -> Void)?
    let onShowServiceStatus: (() -> Void)?

    init(onBikePointSelected: ((BikePoint) -> Void)? = nil, onShowServiceStatus: (() -> Void)? = nil) {
        self.onBikePointSelected = onBikePointSelected
        self.onShowServiceStatus = onShowServiceStatus
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    if favoritesService.favorites.isEmpty {
                        EmptyFavoritesView()
                    } else {
                        FavoritesListView(
                            bikePoints: viewModel.favoriteBikePoints,
                            allBikePoints: viewModel.allBikePoints,
                            lastUpdateTime: viewModel.lastUpdateTime,
                            onBikePointSelected: onBikePointSelected
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
                        SortMenu(
                            sortMode: favoritesService.sortMode,
                            onSortModeChanged: { mode in
                                favoritesService.updateSortMode(mode)
                                AnalyticsService.shared.track(
                                    action: .sortModeUpdate,
                                    screen: .favourites,
                                    metadata: [
                                        "preference": AppConstants.UserDefaults.sortModeKey,
                                        "value": mode.rawValue
                                    ]
                                )
                            }
                        )
                    }
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
    let lastUpdateTime: Date?
    let onBikePointSelected: ((BikePoint) -> Void)?
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var locationService: LocationService
    @State private var editingBikePoint: BikePoint?
    @State private var alternativeBikePointOverrides: [String: BikePoint] = [:]
    @State private var expandedNearbyAlternatives: Set<String> = []
    @State private var dismissedAutoExpandedAlternatives: Set<String> = []
    @State private var alternativeDockRefreshRequest: AnyCancellable?
    @ObservedObject private var liveActivityService = LiveActivityService.shared
    private let alternativeRefreshTimer = Timer.publish(
        every: AppConstants.App.refreshInterval,
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
        let savedDisplay = LiveActivityDockSettings.getPrimaryDisplay(for: dockId)
        let preferredDisplay = savedDisplay ?? globalPrimaryDisplay
        let availableDisplays = LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)
        return availableDisplays.contains(preferredDisplay) ? preferredDisplay : globalPrimaryDisplay
    }

    private var alternativeDockMap: [String: [BikePoint]] {
        guard alternativeDocksEnabled else { return [:] }
        guard !allBikePoints.isEmpty else { return [:] }

        let favoriteIds = Set(bikePoints.map { $0.id })
        let startingPointIds = startingPointFavoriteIds()
        return Dictionary(uniqueKeysWithValues: bikePoints.map { favorite in
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
        VStack(spacing: 0) {
            List {
                ForEach(bikePoints, id: \.id) { bikePoint in
                    let alternatives = displayedAlternativeDockMap[bikePoint.id] ?? []
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
                        }

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
                            if alternativeDocksEnabled && allBikePoints.isEmpty {
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
                                    let isLastAlternative = index == alternatives.count - 1
                                    let hasLiveActivity = liveActivityService.isActivityActive(for: alternative.id)
                                    AlternativeDockRowView(
                                        bikePoint: alternative,
                                        distance: locationService.distanceString(to: alternative.coordinate),
                                        onTap: {
                                            onBikePointSelected?(alternative)
                                        }
                                    )
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
                            } else {
                                Text("No nearby alternatives currently available")
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
            
            // Last update time label at the bottom
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
                // .background(Color(.systemGroupedBackground))
                .padding(.bottom, 8) // Add padding to keep it above the tab bar
            }
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
        .onChange(of: alternativeDocksEnabled) { _, _ in
            refreshVisibleAlternativeDockData()
            if !alternativeDocksEnabled {
                expandedNearbyAlternatives.removeAll()
                dismissedAutoExpandedAlternatives.removeAll()
            }
        }
        .onReceive(alternativeRefreshTimer) { _ in
            refreshVisibleAlternativeDockData()
        }
        .onDisappear {
            alternativeDockRefreshRequest?.cancel()
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

        let ids = Set(alternativeDockMap.values.flatMap { $0.map(\.id) })
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
        forceShow: Bool = false
    ) -> [BikePoint] {
        let shouldShowAlternatives = shouldShowAlternatives(
            for: favorite,
            primaryDisplay: primaryDisplay,
            startingPointFavoriteIds: startingPointFavoriteIds,
            hasLiveActivity: hasLiveActivity
        )

        guard forceShow || shouldShowAlternatives else { return [] }

        let candidates = allBikePoints
            .map { alternativeBikePointOverrides[$0.id] ?? $0 }
            .filter { bikePoint in
                bikePoint.id != favorite.id &&
                    !favoriteIds.contains(bikePoint.id) &&
                    bikePoint.isAvailable
            }

        let filteredCandidates = candidates.filter { bikePoint in
            meetsPrimaryDisplayRequirement(for: bikePoint, primaryDisplay: primaryDisplay)
        }

        let favoriteLocation = CLLocation(latitude: favorite.lat, longitude: favorite.lon)
        let sorted = filteredCandidates.sorted { first, second in
            let firstDistance = favoriteLocation.distance(from: CLLocation(latitude: first.lat, longitude: first.lon))
            let secondDistance = favoriteLocation.distance(from: CLLocation(latitude: second.lat, longitude: second.lon))
            return firstDistance < secondDistance
        }

        return Array(sorted.prefix(max(1, alternativeDocksMaxCount)))
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
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var liveActivityService: LiveActivityService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: bikePoint.coordinate)
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
                DonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 44,
                    strokeWidth: 12
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(bikePoint.commonName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    
                    HStack(alignment: .top) {
                        DonutChartLegend(
                            standardBikes: bikePoint.standardBikes,
                            eBikes: bikePoint.eBikes,
                            emptySpaces: bikePoint.emptyDocks,
                            showLabels: true,
                            spacesOnSecondLine: true,
                            useStatusColors: true
                        )
                        .scaleEffect(0.9, anchor: .leading)
                        
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
                    liveActivityService.startLiveActivity(for: bikePoint, alias: nil)
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

                if !bikePoint.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption2)
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
        .opacity(bikePoint.isAvailable ? 0.9 : 0.6)
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
                Section(header: Text("Custom alias")) {
                    TextField("Alias", text: $alias)
                        .textInputAutocapitalization(.words)
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
