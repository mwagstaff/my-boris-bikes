import SwiftUI
import MapKit

struct MapView: View {
    @State private var viewModel = MapViewModel()
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var bannerService: BannerService
    @State private var selectedBikePointForDetail: BikePoint?
    @State private var selectedMapDockId: String?
    @State private var pendingDockDetailId: String?
    @Binding var selectedBikePointForMap: BikePoint?
    @Binding var selectedDockId: String?
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue = BikeDataFilter.both.rawValue
    let onShowServiceStatus: (() -> Void)?
    let onJourneyStarted: () -> Void
    @State private var didStartJourney = false

    init(
        selectedBikePoint: Binding<BikePoint?> = .constant(nil),
        selectedDockId: Binding<String?> = .constant(nil),
        onShowServiceStatus: (() -> Void)? = nil,
        onJourneyStarted: @escaping () -> Void = {}
    ) {
        self._selectedBikePointForMap = selectedBikePoint
        self._selectedDockId = selectedDockId
        self.onShowServiceStatus = onShowServiceStatus
        self.onJourneyStarted = onJourneyStarted
    }
    
    var body: some View {
        @Bindable var viewModel = viewModel
        let favoriteDockIds = Set(favoritesService.favorites.map(\.id))
        let bikeDataFilter = BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both

        NavigationStack {
            ZStack {
                Map(position: $viewModel.position, selection: $selectedMapDockId) {
                    ForEach(viewModel.visibleBikePoints, id: \.id) { bikePoint in
                        let isFavorite = favoriteDockIds.contains(bikePoint.id)

                        Annotation(bikePoint.commonName, coordinate: bikePoint.coordinate) {
                            BikePointMapPin(
                                bikePoint: bikePoint,
                                isFavorite: isFavorite,
                                isDetailed: viewModel.showsDetailedPins,
                                bikeDataFilter: bikeDataFilter
                            )
                        }
                        .annotationTitles(viewModel.showsDetailedPins ? .automatic : .hidden)
                        .tag(bikePoint.id)
                    }

                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .flat)) // Optimize map rendering
                .mapControlVisibility(.hidden) // Hide unnecessary controls
                .onMapCameraChange(frequency: .continuous) { context in
                    viewModel.handleContinuousMapCameraChange(context.region)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    viewModel.handleMapCameraChange(context.region)
                }
                .onAppear {
                    // If we have a selected bike point when appearing, center on it before setting up location services
                    if let bikePoint = selectedBikePointForMap {
                        viewModel.centerOnBikePoint(id: bikePoint.id)
                        selectedBikePointForMap = nil // Reset after centering
                        selectedDockId = nil
                    } else if let dockId = selectedDockId {
                        handleDockDeepLinkSelection(dockId)
                        selectedDockId = nil
                    }
                    viewModel.setup(locationService: locationService)
                }
                .onDisappear {
                    viewModel.endMapInteraction()
                    selectedBikePointForDetail = nil
                    selectedMapDockId = nil
                    pendingDockDetailId = nil
                }
                .onChange(of: selectedBikePointForMap) { _, newBikePoint in
                    if let bikePoint = newBikePoint {
                        selectedDockId = nil
                        viewModel.centerOnBikePoint(id: bikePoint.id)
                        selectedBikePointForMap = nil // Reset after centering
                    }
                }
                .onChange(of: selectedDockId) { _, newDockId in
                    if selectedBikePointForMap == nil, let dockId = newDockId {
                        handleDockDeepLinkSelection(dockId)
                        selectedDockId = nil
                    }
                }
                .onChange(of: selectedMapDockId) { _, newDockId in
                    guard let newDockId else { return }
                    selectBikePoint(id: newDockId, source: "map_marker")
                    selectedMapDockId = nil
                }
                .onChange(of: viewModel.visibleBikePoints) { _, _ in
                    guard let pendingDockDetailId else { return }
                    if let bikePoint = viewModel.bikePoint(for: pendingDockDetailId) {
                        selectedBikePointForDetail = bikePoint
                        self.pendingDockDetailId = nil
                    }
                }
                VStack {
                    HStack {
                        Spacer()

                        if let banner = bannerService.currentBanner {
                            ServiceStatusButton(severity: banner.severity) {
                                onShowServiceStatus?()
                            }
                            .padding(8)
                            .bikeSpotFloatingControl()
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 16)
                
                VStack {
                    Spacer()

                    // Zoom message centered and at bottom
                    if viewModel.shouldShowZoomMessage {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass.circle")
                                    .foregroundColor(.orange)
                                Text("Please zoom in to see more docks")
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground).opacity(0.95))
                            .cornerRadius(8)
                            .shadow(radius: 3)
                            Spacer()
                        }
                        .padding(.bottom, 12)
                    }

                    // Bottom bar: warning + update time on the left, action buttons on the right
                    HStack(alignment: .bottom, spacing: 8) {
                        // Left column: TfL warning and last update time
                        VStack(alignment: .leading, spacing: 4) {
                            if let warning = viewModel.tflDataStaleWarning ?? viewModel.staleDataWarningMessage {
                                TflDataWarningBanner(message: warning)
                            }
                            if let lastUpdate = viewModel.lastUpdateTime {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Updated \(formatTime(lastUpdate))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.systemBackground).opacity(0.7))
                                .cornerRadius(8)
                                .shadow(radius: 1)
                            }
                        }

                        Spacer()

                        // Right column: action buttons
                        VStack(spacing: 0) {
                            // Refresh button with animation when loading
                            Button(action: {
                                viewModel.refreshData()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 44, height: 44)
                                    .bikeSpotFloatingControl()
                                    .symbolEffect(.rotate, isActive: viewModel.isLoading)
                            }
                            .accessibilityLabel("Refresh dock availability")
                            .disabled(viewModel.isLoading)
                            .opacity(viewModel.isLoading ? 0.7 : 1.0)
                            .padding(.bottom, 10)

                            // Center on nearest bike point button
                            Button(action: viewModel.centerOnNearestBikePoint) {
                                Image(systemName: "bicycle")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .padding(12)
                                    .bikeSpotFloatingControl()
                            }
                            .accessibilityLabel("Show nearest dock")
                            .disabled(locationService.location == nil)
                            .opacity(locationService.location == nil ? 0.5 : 1.0)
                            .padding(.bottom, 10)

                            // Center on user location button
                            Button(action: {
                                viewModel.centerOnUserLocation()
                            }) {
                                Image(systemName: "location.fill")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .padding(12)
                                    .bikeSpotFloatingControl()
                            }
                            .accessibilityLabel("Show my location")
                            .disabled(locationService.location == nil)
                            .opacity(locationService.location == nil ? 0.5 : 1.0)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 50) // Above tab bar
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
            .sheet(item: $selectedBikePointForDetail, onDismiss: {
                if didStartJourney {
                    didStartJourney = false
                    onJourneyStarted()
                }
            }) { bikePoint in
                BikePointDetailView(
                    bikePoint: viewModel.bikePoint(for: bikePoint.id) ?? bikePoint,
                    allBikePoints: viewModel.dockDirectory,
                    updatedAt: viewModel.lastUpdateTime,
                    isFavorite: favoritesService.isFavorite(bikePoint.id),
                    onToggleFavorite: { favoritesService.toggleFavorite($0) },
                    onDockSelected: { dock in
                        viewModel.centerOnBikePoint(id: dock.id)
                        selectedBikePointForDetail = dock
                    },
                    onJourneyStarted: {
                        didStartJourney = true
                        selectedBikePointForDetail = nil
                    }
                )
                .id(bikePoint.id)
                .presentationDetents([.fraction(0.8), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private func handleDockDeepLinkSelection(_ dockId: String) {
        viewModel.centerOnBikePoint(id: dockId)

        if let bikePoint = viewModel.bikePoint(for: dockId) {
            selectedBikePointForDetail = bikePoint
            pendingDockDetailId = nil
        } else {
            pendingDockDetailId = dockId
        }
    }

    private func selectBikePoint(id: String, source: String) {
        guard let bikePoint = viewModel.bikePoint(for: id) else { return }
        AnalyticsService.shared.trackDockTap(
            screen: .map,
            bikePoint: bikePoint,
            source: source
        )
        selectedBikePointForDetail = bikePoint
    }


}

struct BikePointMapPin: View {
    let bikePoint: MapBikePointSummary
    let isFavorite: Bool
    let isDetailed: Bool
    let bikeDataFilter: BikeDataFilter

    private var donutSize: CGFloat { isDetailed ? 40 : 32 }

    var body: some View {
        ZStack {
            if isFavorite {
                Circle()
                    .stroke(AppConstants.Colors.favoriteHighlight, lineWidth: 3)
                    .frame(width: donutSize + 8, height: donutSize + 8)
                    .accessibilityHidden(true)
            }
            SimplifiedDonutChart(standardBikes: bikePoint.standardBikes,
                eBikes: bikePoint.eBikes, emptySpaces: bikePoint.emptyDocks,
                size: donutSize, bikeDataFilter: bikeDataFilter)
            if !bikePoint.isAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(.orange)
                    .offset(x: -10, y: -10)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bikePoint.commonName) dock")
        .accessibilityValue("\(bikeDataFilter.filteredCounts(standardBikes: bikePoint.standardBikes, eBikes: bikePoint.eBikes, emptySpaces: bikePoint.emptyDocks).totalBikes) selected bikes, \(bikePoint.emptyDocks) spaces")
        .accessibilityHint("Show dock details")
    }
}

struct BikePointDetailView: View {
    let bikePoint: BikePoint
    let allBikePoints: [BikePoint]
    let updatedAt: Date?
    let isFavorite: Bool
    let onToggleFavorite: (BikePoint) -> Void
    let onDockSelected: (BikePoint) -> Void
    var onJourneyStarted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var liveActivityService: LiveActivityService
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @ObservedObject private var preferences = DockPreferencesService.shared
    @State private var journeyEditorPresentation: JourneyEditorPresentation?
    @State private var didStartJourney = false
    @State private var showsAllDocks = false
    @State private var showsOtherNearbyDocks = false
    @State private var showsAlternativesEditor = false

    private var hasCustomAlternatives: Bool { preferences.customDockIDs(for: bikePoint.id) != nil }
    private var nearbyDocks: [BikePoint] {
        if let saved = preferences.customDocks(for: bikePoint.id) {
            return AlternativeDockSelectionService.savedAlternativesForFavorites(
                for: bikePoint.id, savedDocks: saved, allBikePoints: allBikePoints, showAll: true)
        }
        return AlternativeDockSelectionService.otherNearbyDocks(
            for: bikePoint, allBikePoints: allBikePoints, excludingDockIDs: [])
    }
    private var dialogDocks: [BikePoint] {
        guard showsOtherNearbyDocks && hasCustomAlternatives else { return nearbyDocks }
        return AlternativeDockSelectionService.otherNearbyDocks(for: bikePoint, allBikePoints: allBikePoints,
            excludingDockIDs: Set(preferences.customDockIDs(for: bikePoint.id) ?? []))
    }
    private var isWatching: Bool { liveActivityService.isActivityActive(for: bikePoint.id) }
    private var journeyIsTracking: Bool { liveActivityService.currentNotificationSession?.scheduledJourneyPhase != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                actionGrid
                if isWatching && !journeyIsTracking {
                    LiveActivityControlRow(bikePoint: bikePoint, compact: true)
                }
                Divider()
                nearbySection
                Button { showsAlternativesEditor = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Edit alternatives").font(.subheadline.weight(.semibold))
                            Text("Manage your dock options").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 4)
                }
                .dockSheetButton()
                if let updatedAt {
                    Text("Updated \(DockUpdateTime.string(from: updatedAt))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(16)
            .padding(.top, 8)
        }
        .presentationBackground(reduceTransparency ? AnyShapeStyle(BikeSpotStyle.canvas) : AnyShapeStyle(.regularMaterial))
        .sheet(item: $journeyEditorPresentation, onDismiss: {
            if didStartJourney {
                didStartJourney = false
                onJourneyStarted()
            }
        }) { presentation in
            AddJourneyView(presentation: presentation) { didStartJourney = true }
        }
        .sheet(isPresented: $showsAlternativesEditor) {
            AlternativeDocksEditor(dock: ScheduledJourneyDock(bikePoint: bikePoint))
        }
        .sheet(isPresented: $showsAllDocks, onDismiss: { showsOtherNearbyDocks = false }) {
            NavigationStack {
                List {
                    if hasCustomAlternatives {
                        Toggle("Other nearby docks", isOn: $showsOtherNearbyDocks)
                    }
                    Section(showsOtherNearbyDocks ? "Other nearby docks · closest first" : hasCustomAlternatives ? "Custom alternatives" : "Closest first") {
                        if dialogDocks.isEmpty {
                            Text("No nearby docks available.").foregroundStyle(.secondary)
                        }
                        ForEach(dialogDocks) { dock in
                            nearbyRow(dock)
                        }
                    }
                    AlternativeDocksEditButton(dock: ScheduledJourneyDock(bikePoint: bikePoint))
                }
                .bikeSpotBackground(showsPhoto: false)
                .navigationTitle("Nearby docks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAllDocks = false } }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                DonutChart(standardBikes: bikePoint.standardBikes, eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks, size: 76, hasAvailability: bikePoint.hasAvailabilityData)
                VStack(alignment: .leading, spacing: 4) {
                    Text(favoritesService.displayName(for: bikePoint))
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    if favoritesService.alias(for: bikePoint.id) != nil {
                        Text(bikePoint.commonName).font(.caption).foregroundStyle(.secondary)
                    }
                    Label(locationService.distanceString(to: bikePoint.coordinate), systemImage: "location")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                }
                .dockSheetButton()
                .accessibilityLabel("Close dock details")
            }
            if bikePoint.hasAvailabilityData {
                DonutChartLegend(standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes, emptySpaces: bikePoint.emptyDocks)
            } else {
                Text("Availability unavailable").font(.caption).foregroundStyle(.secondary)
            }
            if !bikePoint.isAvailable {
                Label(bikePoint.isLocked ? "Locked for maintenance" : "Dock unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
            Button {
                journeyEditorPresentation = .fromDock(ScheduledJourneyDock(bikePoint: bikePoint), isStart: true)
            } label: {
                DockSheetActionLabel(title: "Start here", subtitle: "Choose a destination", symbol: "bicycle")
            }
            .dockSheetButton(prominent: true)
            Button {
                journeyEditorPresentation = .fromDock(ScheduledJourneyDock(bikePoint: bikePoint), isStart: false)
            } label: {
                DockSheetActionLabel(title: "End here", subtitle: "Choose a start dock", symbol: "flag.checkered")
            }
            .dockSheetButton()
            Button {
                AnalyticsService.shared.track(action: isWatching ? .liveActivityEnd : .liveActivityStart,
                    screen: .map, dock: AnalyticsDockInfo.from(bikePoint), metadata: ["source": "detail_sheet"])
                liveActivityService.startLiveActivity(for: bikePoint, alias: favoritesService.alias(for: bikePoint.id))
            } label: {
                DockSheetActionLabel(title: journeyIsTracking ? "Journey tracking" : isWatching ? "Stop watching" : "Watch this dock",
                    subtitle: journeyIsTracking ? "Managed in Journeys" : isWatching ? "End live updates" : "Get live updates",
                    symbol: "waveform.path.ecg")
            }
            .dockSheetButton()
            .disabled(journeyIsTracking)
            Button {
                AnalyticsService.shared.track(action: isFavorite ? .favoriteRemove : .favoriteAdd,
                    screen: .map, dock: AnalyticsDockInfo.from(bikePoint), metadata: ["source": "detail_sheet"])
                onToggleFavorite(bikePoint)
            } label: {
                DockSheetActionLabel(title: isFavorite ? "Saved to favourites" : "Add to favourites",
                    subtitle: isFavorite ? "Tap to remove" : "Save for later", symbol: isFavorite ? "star.fill" : "star")
            }
            .dockSheetButton()
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hasCustomAlternatives ? "Alternative docks" : "Nearby docks")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { showsAllDocks = true } label: {
                    HStack(spacing: 6) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold)).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
            }
            if nearbyDocks.isEmpty {
                Text(hasCustomAlternatives ? "No custom alternatives selected. See all to browse nearby docks." : "No nearby docks available.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(Array(nearbyDocks.prefix(3))) { dock in
                Divider()
                nearbyRow(dock).padding(.vertical, 6)
            }
        }
    }

    private func nearbyRow(_ dock: BikePoint) -> some View {
        Button {
            showsAllDocks = false
            AnalyticsService.shared.trackDockTap(screen: .map, bikePoint: dock, source: "detail_nearby")
            onDockSelected(dock)
        } label: {
            DockSheetNearbyRow(dock: dock, origin: bikePoint,
                name: favoritesService.displayName(for: dock))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Show this dock’s details")
    }
}

private struct DockSheetActionLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle).font(.caption)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 68)
        .padding(.vertical, 4)
    }
}

private struct DockSheetNearbyRow: View {
    let dock: BikePoint
    let origin: BikePoint
    let name: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeFilterRawValue = BikeDataFilter.both.rawValue
    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes = AlternativeDockSettings.defaultMinBikes
    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes = AlternativeDockSettings.defaultMinEBikes
    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces = AlternativeDockSettings.defaultMinSpaces

    private var filter: BikeDataFilter { BikeDataFilter(rawValue: bikeFilterRawValue) ?? .both }
    private var bikeCount: Int {
        filter.filteredCounts(standardBikes: dock.standardBikes, eBikes: dock.eBikes, emptySpaces: dock.emptyDocks).totalBikes
    }
    private var threshold: Int {
        switch filter {
        case .both: minBikes + minEBikes
        case .bikesOnly: minBikes
        case .eBikesOnly: minEBikes
        }
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            DonutChart(standardBikes: dock.standardBikes, eBikes: dock.eBikes,
                emptySpaces: dock.emptyDocks, size: 40, strokeWidth: 5, hasAvailability: dock.hasAvailabilityData)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                let distance = CLLocation(latitude: origin.lat, longitude: origin.lon)
                    .distance(from: CLLocation(latitude: dock.lat, longitude: dock.lon))
                Text(distance < 1000 ? String(format: "%.0f m", distance)
                     : String(format: "%.1f miles", distance / 1609.344))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Distance from selected dock")
                    .accessibilityValue(distance < 1000 ? String(format: "%.0f metres", distance)
                        : String(format: "%.1f miles", distance / 1609.344))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if dock.hasAvailabilityData {
                VStack(alignment: .leading, spacing: 4) {
                    AvailabilityPill(count: bikeCount,
                        label: filter == .eBikesOnly ? (bikeCount == 1 ? "e-bike" : "e-bikes") : (bikeCount == 1 ? "bike" : "bikes"),
                        symbol: filter == .eBikesOnly ? "bolt.fill" : "bicycle", threshold: threshold)
                    AvailabilityPill(count: dock.emptyDocks, label: dock.emptyDocks == 1 ? "space" : "spaces",
                        symbol: "parkingsign.circle", threshold: minSpaces)
                }
            } else {
                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
    }
}

private struct DockSheetButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle(radius: 22))
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 22))
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 22))
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 22))
        }
    }
}

private extension View {
    func dockSheetButton(prominent: Bool = false) -> some View {
        modifier(DockSheetButtonModifier(prominent: prominent))
    }
}

#Preview {
    MapView()
        .environmentObject(LocationService.shared)
        .environmentObject(FavoritesService.shared)
        .environmentObject(BannerService.shared)
}

#Preview("Dock sheet actions") {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        Button {} label: {
            DockSheetActionLabel(title: "Start here", subtitle: "Choose a destination", symbol: "bicycle")
        }.dockSheetButton(prominent: true)
        Button {} label: {
            DockSheetActionLabel(title: "End here", subtitle: "Choose a start dock", symbol: "flag.checkered")
        }.dockSheetButton()
        Button {} label: {
            DockSheetActionLabel(title: "Watch this dock", subtitle: "Get live updates", symbol: "waveform.path.ecg")
        }.dockSheetButton()
        Button {} label: {
            DockSheetActionLabel(title: "Add to favourites", subtitle: "Save for later", symbol: "star")
        }.dockSheetButton()
    }
    .padding().background(.regularMaterial)
    .preferredColorScheme(.dark)
}
