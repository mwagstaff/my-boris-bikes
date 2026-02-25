import SwiftUI
import MapKit

enum MapAvailabilityDisplayMode: String, CaseIterable, Identifiable {
    case bikesOnly
    case docksAndSpaces
    
    var id: String { rawValue }
    
    var label: String {
        switch self { 
        case .bikesOnly:
            return "Bikes"
        case .docksAndSpaces:
            return "Docks + Spaces"
        }
    }
    
    var menuDescription: String {
        switch self {
        case .bikesOnly:
            return "Show bike availability only"
        case .docksAndSpaces:
            return "Show free spaces as well as bikes"
        }
    }
    
    var iconName: String {
        switch self {
        case .bikesOnly:
            return "bicycle"
        case .docksAndSpaces:
            return "square.grid.2x2"
        }
    }
}

struct MapView: View {
    @StateObject private var viewModel = MapViewModel()
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var favoritesService: FavoritesService
    @EnvironmentObject var bannerService: BannerService
    @State private var selectedBikePointForDetail: BikePoint?
    @State private var pendingDockDetailId: String?
    @Binding var selectedBikePointForMap: BikePoint?
    @Binding var selectedDockId: String?
    @AppStorage(AppConstants.UserDefaults.mapDisplayModeKey) private var mapAvailabilityDisplayModeRawValue = MapAvailabilityDisplayMode.docksAndSpaces.rawValue
    let onShowServiceStatus: (() -> Void)?

    init(
        selectedBikePoint: Binding<BikePoint?> = .constant(nil),
        selectedDockId: Binding<String?> = .constant(nil),
        onShowServiceStatus: (() -> Void)? = nil
    ) {
        self._selectedBikePointForMap = selectedBikePoint
        self._selectedDockId = selectedDockId
        self.onShowServiceStatus = onShowServiceStatus
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $viewModel.position) {
                    ForEach(viewModel.visibleBikePoints, id: \.id) { bikePoint in
                        Annotation(bikePoint.commonName, coordinate: bikePoint.coordinate) {
                            BikePointMapPin(
                                bikePoint: bikePoint,
                                isFavorite: favoritesService.isFavorite(bikePoint.id),
                                displayMode: mapAvailabilityDisplayMode
                            ) {
                                AnalyticsService.shared.trackDockTap(
                                    screen: .map,
                                    bikePoint: bikePoint,
                                    source: "map_pin"
                                )
                                selectedBikePointForDetail = bikePoint
                            }
                        }
                    }
                    
                    // User location indicator
                    if let userLocation = locationService.location {
                        Annotation("", coordinate: userLocation.coordinate) {
                            UserLocationIndicator()
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat)) // Optimize map rendering
                .mapControlVisibility(.hidden) // Hide unnecessary controls
                .onMapCameraChange { context in
                    // Update bike points when user scrolls to new location or zooms
                    viewModel.updateMapRegion(context.region)
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
                .onChange(of: viewModel.visibleBikePoints) { _, _ in
                    guard let pendingDockDetailId else { return }
                    if let bikePoint = viewModel.bikePoint(for: pendingDockDetailId) {
                        selectedBikePointForDetail = bikePoint
                        self.pendingDockDetailId = nil
                    }
                }
                .onChange(of: mapAvailabilityDisplayModeRawValue) { _, newValue in
                    AnalyticsService.shared.track(
                        action: .mapDisplayModeUpdate,
                        screen: .map,
                        metadata: [
                            "preference": AppConstants.UserDefaults.mapDisplayModeKey,
                            "value": newValue
                        ]
                    )
                }
                
                VStack {
                    HStack {
                        pinDisplayModeMenu

                        Spacer()

                        if let banner = bannerService.currentBanner {
                            ServiceStatusButton(severity: banner.severity) {
                                onShowServiceStatus?()
                            }
                            .padding(8)
                            .background(Color(.systemBackground).opacity(0.9), in: Circle())
                            .shadow(radius: 2, y: 1)
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
                        .padding(.bottom, 20)
                    }
                    
                    HStack {
                        Spacer()
                        
                        VStack {
                            Spacer()
                            
                            // Refresh button with animation when loading
                            Button(action: {
                                viewModel.refreshData()
                            }) {
                                // Fixed-size container to prevent layout drift on rotation
                                Image(systemName: "arrow.clockwise")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(Color(.systemBackground))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                    // Use system rotation effect for stability across OS versions
                                    .symbolEffect(.rotate, isActive: viewModel.isLoading)
                            }
                            .disabled(viewModel.isLoading)
                            .opacity(viewModel.isLoading ? 0.7 : 1.0)
                            .padding(.bottom, 10)
                            
                            // Center on nearest bike point button
                            Button(action: viewModel.centerOnNearestBikePoint) {
                                // Display a bike icon
                                Image(systemName: "bicycle")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .padding(12)
                                    .background(Color(.systemBackground))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                            }
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
                                    .background(Color(.systemBackground))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                            }
                            .disabled(locationService.location == nil)
                            .opacity(locationService.location == nil ? 0.5 : 1.0)
                            .padding(.bottom, 0) // Above tab bar and message area
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 50) // Above tab bar
                }
                
                // Last update time label
                VStack {
                    Spacer()
                    if let staleDataWarningMessage = viewModel.staleDataWarningMessage {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(staleDataWarningMessage)
                                    .font(.caption2)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemBackground).opacity(0.9))
                            .cornerRadius(8)
                            .shadow(radius: 2)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                    }
                    HStack {
                        Spacer()
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
                    .padding(.horizontal)
                    .padding(.bottom, 20) // Above tab bar and other UI elements
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
            .sheet(item: $selectedBikePointForDetail) { bikePoint in
                BikePointDetailView(
                    bikePoint: bikePoint,
                    isFavorite: favoritesService.isFavorite(bikePoint.id)
                ) { bikePoint in
                    favoritesService.toggleFavorite(bikePoint)
                }
                .presentationDetents([.height(340), .medium])
                .presentationDragIndicator(.visible)
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private var mapAvailabilityDisplayMode: MapAvailabilityDisplayMode {
        get { MapAvailabilityDisplayMode(rawValue: mapAvailabilityDisplayModeRawValue) ?? .bikesOnly }
        set { mapAvailabilityDisplayModeRawValue = newValue.rawValue }
    }
    
    private var mapAvailabilityDisplayModeBinding: Binding<MapAvailabilityDisplayMode> {
        Binding(
            get: { mapAvailabilityDisplayMode },
            set: { mapAvailabilityDisplayModeRawValue = $0.rawValue }
        )
    }
    
    private var pinDisplayModeMenu: some View {
        Menu {
            Picker("Map pins show", selection: mapAvailabilityDisplayModeBinding) {
                ForEach(MapAvailabilityDisplayMode.allCases) { mode in
                    Label(mode.menuDescription, systemImage: mode.iconName)
                        .tag(mode)
                }
            }
        } label: { 
            HStack(spacing: 6) {
                Image(systemName: mapAvailabilityDisplayMode.iconName)
                Text(mapAvailabilityDisplayMode.label)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemBackground).opacity(0.9), in: Capsule())
            .shadow(radius: 2, y: 1)
        }
        .accessibilityLabel("Map pin data mode")
        .accessibilityValue(mapAvailabilityDisplayMode.menuDescription)
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
}

struct BikePointMapPin: View {
    let bikePoint: BikePoint
    let isFavorite: Bool
    let displayMode: MapAvailabilityDisplayMode
    let onTap: () -> Void
    
    private let donutSize: CGFloat = 40
    private var favoriteRingSize: CGFloat {
        donutSize + 8
    }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if isFavorite {
                        Circle()
                            .stroke(AppConstants.Colors.favoriteHighlight, lineWidth: 3)
                            .frame(width: favoriteRingSize, height: favoriteRingSize)
                            .shadow(color: AppConstants.Colors.favoriteHighlight.opacity(0.4), radius: 4)
                            .accessibilityHidden(true)
                    }
                    
                    // Simplified donut chart for better performance
                    SimplifiedDonutChart(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks,
                        size: donutSize // Smaller for better performance
                    )

                if !bikePoint.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.orange)
                            .background(Color.black.opacity(0.0))
                            .clipShape(Circle())
                            .offset(x: -10, y: -10)
                    }
            }
            // Apply long press to the donut only
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 40) { onTap() }
            .onTapGesture {
                onTap()
            }
            // Accessibility: expose as a button with an activate action
            .accessibilityLabel(Text("\(bikePoint.commonName) dock details"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }

            if displayMode == .docksAndSpaces {
                BikePointCapacityBadge(
                    totalDocks: bikePoint.totalDocks,
                    emptySpaces: bikePoint.emptyDocks
                )
                .allowsHitTesting(false)
            }
        }
    }
}

struct BikePointCapacityBadge: View {
    let totalDocks: Int
    let emptySpaces: Int
    
    private var capacityColor: Color {
        switch emptySpaces {
        case 0:
            return .red
        case 1...3:
            return .yellow
        default:
            return .green
        }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(capacityColor)
                .frame(width: 8, height: 8)
                .foregroundColor(.secondary)
            Text("\(emptySpaces) space\(emptySpaces == 1 ? "" : "s")")
                .foregroundColor(.primary)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemBackground).opacity(0.95))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

struct BikePointDetailView: View {
    let bikePoint: BikePoint
    let isFavorite: Bool
    let onToggleFavorite: (BikePoint) -> Void
    @EnvironmentObject var liveActivityService: LiveActivityService

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @State private var currentPrimaryDisplay: LiveActivityPrimaryDisplay = .bikes

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

    private var hasAnyBikes: Bool {
        filteredCounts.hasAnyBikes
    }

    private var hasAnyAvailability: Bool {
        filteredCounts.hasAnyAvailability
    }
    
    var body: some View {
        let isActive = liveActivityService.isActivityActive(for: bikePoint.id)

        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    DonutChart(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks,
                        size: 60
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(bikePoint.commonName)
                            .font(.headline)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if !bikePoint.isAvailable {
                            Label {
                                Text(bikePoint.isLocked ? "Locked for maintenance" : "Not available")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        } else if !hasAnyBikes {
                            Text(bikeDataFilter.noBikesMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if bikePoint.totalDocks > 0 {
                            Text("\(bikePoint.emptyDocks) spaces available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                
                if hasAnyAvailability {
                    DonutChartLegend(
                        standardBikes: bikePoint.standardBikes,
                        eBikes: bikePoint.eBikes,
                        emptySpaces: bikePoint.emptyDocks
                    )
                }
                
                Button {
                    let action: AnalyticsAction = isFavorite ? .favoriteRemove : .favoriteAdd
                    AnalyticsService.shared.track(
                        action: action,
                        screen: .map,
                        dock: AnalyticsDockInfo.from(bikePoint),
                        metadata: ["source": "detail_sheet"]
                    )
                    onToggleFavorite(bikePoint)
                } label: {
                    HStack {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                        Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    }
                    .foregroundColor(isFavorite ? .red : .accentColor)
                }
                .buttonStyle(.bordered)

                Button {
                    let action: AnalyticsAction = isActive ? .liveActivityEnd : .liveActivityStart
                    AnalyticsService.shared.track(
                        action: action,
                        screen: .map,
                        dock: AnalyticsDockInfo.from(bikePoint),
                        metadata: ["source": "detail_sheet"]
                    )
                    liveActivityService.startLiveActivity(for: bikePoint, alias: nil)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                            Text(isActive ? "End Live Activity" : "Start Live Activity")
                        }
                        .font(.system(size: 16, weight: isActive ? .bold : .semibold))
                        .foregroundColor(isActive ? .white : .accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isActive ? AppConstants.Colors.standardBike : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    isActive ? AppConstants.Colors.standardBike : .accentColor.opacity(0.35),
                                    lineWidth: 1
                                )
                        )

                        if isActive {
                            Text("Tap this to end the live activity and stop receiving dock notifications")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.plain)

                if isActive {
                    VStack(alignment: .center, spacing: 8) {
                        Text("Live Activity:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)

                        HStack(spacing: 12) {
                            ForEach(LiveActivityPrimaryDisplay.availableCases(for: bikeDataFilter)) { display in
                                let isSelected = currentPrimaryDisplay == display
                                Button {
                                    AnalyticsService.shared.track(
                                        action: .preferenceUpdate,
                                        screen: .map,
                                        dock: AnalyticsDockInfo.from(bikePoint),
                                        metadata: [
                                            "preference": "live_activity_primary_display_dock",
                                            "value": display.rawValue
                                        ]
                                    )
                                    liveActivityService.setPrimaryDisplay(display, for: bikePoint.id)
                                    currentPrimaryDisplay = display
                                } label: {
                                    Text(display.title)
                                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                        .foregroundColor(isSelected ? .blue : .blue.opacity(0.7))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.clear)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(isSelected ? Color.blue.opacity(0.7) : Color.blue.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                    .onAppear {
                        currentPrimaryDisplay = liveActivityService.getPrimaryDisplay(for: bikePoint.id)
                    }
                }
            }
            .padding()
            .padding(.top, 16)
        }
        .frame(maxHeight: 420) // Increased to accommodate live activity controls
        .opacity(bikePoint.isAvailable ? 1.0 : 0.7)
    }
}

#Preview {
    MapView()
        .environmentObject(LocationService.shared)
        .environmentObject(FavoritesService.shared)
        .environmentObject(BannerService.shared)
}
