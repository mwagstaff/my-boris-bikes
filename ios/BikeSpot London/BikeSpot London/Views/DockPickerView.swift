import Combine
import MapKit
import SwiftUI

struct DockPickerView: View {
    enum AvailabilityMode {
        case start
        case end
    }

    enum Mode: String, CaseIterable, Identifiable {
        case favourites = "Favourites"
        case recents = "Recents"
        case map = "Map"
        case search = "Search"

        var id: String { rawValue }
    }

    let title: String
    var availabilityMode: AvailabilityMode
    var dismissOnSelect = true
    var referenceDock: ScheduledJourneyDock?
    var excludedDockIDs: Set<String> = []
    let onSelect: (ScheduledJourneyDock) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var scheduledJourneyService: ScheduledJourneyService
    @EnvironmentObject private var adHocJourneyService: AdHocJourneyService
    @State private var mode: Mode = .favourites
    @State private var searchText = ""
    @State private var allBikePoints: [BikePoint] = []
    @State private var cancellable: AnyCancellable?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var hasCenteredOnInitialLocation = false
    @State private var currentMapCenter = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Dock source", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if let loadError {
                    HStack(alignment: .top) {
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry", action: loadBikePoints)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                switch mode {
                case .favourites:
                    List {
                        Section {
                            ForEach(favouriteBikePoints) { bikePoint in
                                DockPickerRow(
                                    bikePoint: bikePoint,
                                    availabilityMode: availabilityMode,
                                    showsDistance: true,
                                    referenceDock: referenceDock
                                ) {
                                    onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                    dismissIfNeeded()
                                }
                            }
                        } header: {
                            Text("Favourite docks")
                        }

                        Section {
                            if referenceDock == nil && locationService.location == nil {
                                Label("Current location unavailable", systemImage: "location.slash")
                                    .foregroundStyle(.secondary)
                            } else if allBikePoints.isEmpty {
                                Label(isLoading ? "Loading nearby docks..." : "No docks loaded", systemImage: "location")
                                    .foregroundStyle(.secondary)
                            } else if nearbyBikePoints.isEmpty {
                                Label("No nearby docks found", systemImage: "bicycle")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(nearbyBikePoints) { bikePoint in
                                    DockPickerRow(
                                        bikePoint: bikePoint,
                                        availabilityMode: availabilityMode,
                                        showsDistance: true,
                                    referenceDock: referenceDock
                                    ) {
                                        onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                        dismissIfNeeded()
                                    }
                                }
                            }
                        } header: {
                            Text(referenceDock.map { "Near \(favoritesService.alias(for: $0.id) ?? $0.name)" } ?? "Nearby docks")
                        }
                    }
                case .recents:
                    if recentBikePoints.isEmpty {
                        ContentUnavailableView(
                            "No recent docks",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Docks from journeys you start will appear here.")
                        )
                    } else {
                        List(recentBikePoints) { recent in
                            DockPickerRow(
                                bikePoint: recent.bikePoint,
                                availabilityMode: availabilityMode,
                                detailText: "Last used \(recent.lastUsedAt.formatted(date: .abbreviated, time: .shortened))",
                                showsDistance: true,
                                    referenceDock: referenceDock
                            ) {
                                onSelect(ScheduledJourneyDock(bikePoint: recent.bikePoint))
                                dismissIfNeeded()
                            }
                        }
                    }
                case .map:
                    ZStack {
                        Map(position: $mapPosition) {
                            if let referenceDock {
                                Annotation("This dock", coordinate: CLLocationCoordinate2D(latitude: referenceDock.latitude, longitude: referenceDock.longitude)) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("This dock: \(favoritesService.alias(for: referenceDock.id) ?? referenceDock.name)")
                                }
                            }
                            ForEach(mapBikePoints) { bikePoint in
                                Annotation("", coordinate: bikePoint.coordinate) {
                                    Button {
                                        guard !excludedDockIDs.contains(bikePoint.id) else { return }
                                        onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                        dismissIfNeeded()
                                    } label: {
                                        DockPickerMapMarker(
                                            bikePoint: bikePoint,
                                            isAlreadyAdded: excludedDockIDs.contains(bikePoint.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(excludedDockIDs.contains(bikePoint.id))
                                    .accessibilityLabel(excludedDockIDs.contains(bikePoint.id)
                                        ? "\(favoritesService.displayName(for: bikePoint)), already added"
                                        : "Select \(favoritesService.displayName(for: bikePoint))")
                                }
                            }

                            if let userLocation = locationService.location {
                                Annotation("", coordinate: userLocation.coordinate) {
                                    UserLocationIndicator(heading: locationService.heading)
                                }
                            }
                        }
                        .onMapCameraChange(frequency: .onEnd) { context in
                            currentMapCenter = context.region.center
                        }

                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                DockPickerMapControls(
                                    hasLocation: locationService.location != nil,
                                    hasBikePoints: !allBikePoints.isEmpty,
                                    onCenterNearestDock: centerOnNearestBikePoint,
                                    onCenterUserLocation: centerOnUserLocation
                                )
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)
                        }
                    }
                case .search:
                    List(filteredBikePoints) { bikePoint in
                        DockPickerRow(
                            bikePoint: bikePoint,
                            availabilityMode: availabilityMode,
                            showsDistance: true,
                                    referenceDock: referenceDock
                        ) {
                            onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                            dismissIfNeeded()
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search dock name")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                loadBikePoints()
                startLocationServices()
                if let referenceDock {
                    centerMap(on: CLLocationCoordinate2D(latitude: referenceDock.latitude, longitude: referenceDock.longitude))
                    hasCenteredOnInitialLocation = true
                } else if let location = locationService.location {
                    centerMap(on: location.coordinate)
                    hasCenteredOnInitialLocation = true
                }
            }
            .onDisappear {
                cancellable?.cancel()
                isLoading = false
                locationService.stopHeadingUpdates()
            }
            .onReceive(locationService.$location.compactMap { $0 }) { location in
                guard !hasCenteredOnInitialLocation else { return }
                centerMap(on: location.coordinate)
                hasCenteredOnInitialLocation = true
            }
        }
    }

    private func dismissIfNeeded() {
        guard dismissOnSelect else { return }
        dismiss()
    }

    private var selectableBikePoints: [BikePoint] {
        allBikePoints.filter { !excludedDockIDs.contains($0.id) && $0.id != referenceDock?.id }
    }

    private var favouriteBikePoints: [BikePoint] {
        let byId = Dictionary(uniqueKeysWithValues: selectableBikePoints.map { ($0.id, $0) })
        return favoritesService.favorites.compactMap { favorite in
            byId[favorite.id]
        }
    }

    private var nearbyBikePoints: [BikePoint] {
        let favouriteIds = Set(favoritesService.favorites.map(\.id))
        return sortedByDistance(selectableBikePoints.filter { !favouriteIds.contains($0.id) })
            .prefix(5)
            .map { $0 }
    }

    private var recentBikePoints: [RecentDockUsage] {
        let byId = Dictionary(uniqueKeysWithValues: selectableBikePoints.map { ($0.id, $0) })
        var usagesByDockId: [String: RecentDockUsage] = [:]

        func record(_ dock: ScheduledJourneyDock, lastUsedAt: Date) {
            guard let bikePoint = byId[dock.id] else { return }
            if let existing = usagesByDockId[dock.id],
               existing.lastUsedAt >= lastUsedAt {
                return
            }

            usagesByDockId[dock.id] = RecentDockUsage(
                bikePoint: bikePoint,
                lastUsedAt: lastUsedAt
            )
        }

        for journey in adHocJourneyService.recentJourneys {
            let lastUsedAt = journey.lastStartedAt ?? journey.createdAt
            record(journey.startDock, lastUsedAt: lastUsedAt)
            record(journey.endDock, lastUsedAt: lastUsedAt)
        }

        for journey in scheduledJourneyService.journeys {
            guard let activeRun = journey.activeRun,
                  let startedAt = activeRun.startedAt else {
                continue
            }

            record(journey.startDock, lastUsedAt: startedAt)
            record(journey.endDock, lastUsedAt: startedAt)
        }

        return usagesByDockId.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private var filteredBikePoints: [BikePoint] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingBikePoints: [BikePoint]

        if trimmedSearchText.isEmpty {
            matchingBikePoints = selectableBikePoints
        } else {
            matchingBikePoints = selectableBikePoints.filter {
                $0.commonName.localizedCaseInsensitiveContains(trimmedSearchText) ||
                    ($0.alias(using: favoritesService)?.localizedCaseInsensitiveContains(trimmedSearchText) == true)
            }
        }

        return sortedByDistance(matchingBikePoints)
            .prefix(80)
            .map { $0 }
    }

    private var mapBikePoints: [BikePoint] {
        let sorted = allBikePoints
            .filter { $0.id != referenceDock?.id }
            .sorted {
                squaredDistanceMeters(from: currentMapCenter, to: $0.coordinate)
                    < squaredDistanceMeters(from: currentMapCenter, to: $1.coordinate)
            }
        let nearbyIDs = Set(sorted.prefix(250).map(\.id))
        return sorted.filter { nearbyIDs.contains($0.id) || excludedDockIDs.contains($0.id) }
    }

    private func startLocationServices() {
        locationService.startLocationUpdates()
        locationService.startHeadingUpdates()
    }

    private func centerOnUserLocation() {
        guard let location = locationService.location else { return }
        centerMap(on: location.coordinate)
    }

    private func centerOnNearestBikePoint() {
        let origin = referenceDock.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? locationService.location?.coordinate
        guard let userCoordinate = origin,
              let nearestBikePoint = selectableBikePoints.min(by: {
                  squaredDistanceMeters(from: userCoordinate, to: $0.coordinate)
                      < squaredDistanceMeters(from: userCoordinate, to: $1.coordinate)
              }) else {
            return
        }

        centerMap(on: nearestBikePoint.coordinate)
    }

    private func sortedByDistance(_ bikePoints: [BikePoint]) -> [BikePoint] {
        let origin = referenceDock.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? locationService.location?.coordinate
        guard let userCoordinate = origin else { return bikePoints }

        return bikePoints.sorted {
            squaredDistanceMeters(from: userCoordinate, to: $0.coordinate)
                < squaredDistanceMeters(from: userCoordinate, to: $1.coordinate)
        }
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        currentMapCenter = coordinate

        withAnimation(.easeInOut(duration: 1.0)) {
            mapPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            )
        }
    }

    private func squaredDistanceMeters(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> Double {
        let metersPerDegreeLatitude = 111_320.0
        let averageLatitudeRadians = ((source.latitude + destination.latitude) * 0.5) * .pi / 180
        let metersPerDegreeLongitude = max(1, cos(averageLatitudeRadians) * metersPerDegreeLatitude)

        let deltaLatitudeMeters = (destination.latitude - source.latitude) * metersPerDegreeLatitude
        let deltaLongitudeMeters = (destination.longitude - source.longitude) * metersPerDegreeLongitude
        return (deltaLatitudeMeters * deltaLatitudeMeters) + (deltaLongitudeMeters * deltaLongitudeMeters)
    }

    private func loadBikePoints() {
        cancellable?.cancel()
        loadError = nil
        isLoading = true
        let cached = AllBikePointsCache.shared.load()
        if !cached.isEmpty {
            allBikePoints = cached
        }

        cancellable = TfLAPIService.shared.fetchAllBikePoints(cacheBusting: false)
            .sink(
                receiveCompletion: { completion in
                    isLoading = false
                    if case .failure = completion {
                        loadError = allBikePoints.isEmpty
                            ? "Docks couldn’t be loaded. Check your connection and try again."
                            : "Showing saved docks. Availability couldn’t be refreshed."
                    }
                },
                receiveValue: { bikePoints in
                    allBikePoints = bikePoints.filter(\.isInstalled)
                    AllBikePointsCache.shared.save(allBikePoints, savedAt: Date())
                }
            )
    }
}

private struct DockPickerMapMarker: View {
    let bikePoint: BikePoint
    let isAlreadyAdded: Bool
    @EnvironmentObject private var favoritesService: FavoritesService
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue = BikeDataFilter.both.rawValue

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                SimplifiedDonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 40,
                    bikeDataFilter: bikeDataFilter
                )
                .saturation(isAlreadyAdded ? 0 : 1)
                .opacity(isAlreadyAdded ? 0.5 : 1)

                if !bikePoint.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                        .background(Color.black.opacity(0.0))
                        .clipShape(Circle())
                        .offset(x: -10, y: -10)
                }
            }
            .contentShape(Circle())

            VStack(spacing: 2) {
                Text(label)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isAlreadyAdded {
                    Label("Already added", systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundColor(isAlreadyAdded ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 128)
            .background(Color(.systemBackground).opacity(0.95))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            .allowsHitTesting(false)
        }
    }

    private var label: String {
        if let alias = favoritesService.alias(for: bikePoint.id) {
            return alias
        }
        return bikePoint.commonName
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? bikePoint.commonName
    }
}

private struct DockPickerMapControls: View {
    let hasLocation: Bool
    let hasBikePoints: Bool
    let onCenterNearestDock: () -> Void
    let onCenterUserLocation: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onCenterNearestDock) {
                Image(systemName: "bicycle")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .padding(12)
                    .background(Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .disabled(!hasLocation || !hasBikePoints)
            .opacity(hasLocation && hasBikePoints ? 1.0 : 0.5)
            .accessibilityLabel("Center on nearest dock")

            Button(action: onCenterUserLocation) {
                Image(systemName: "location.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .padding(12)
                    .background(Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .disabled(!hasLocation)
            .opacity(hasLocation ? 1.0 : 0.5)
            .accessibilityLabel("Center on current location")
        }
    }
}

private struct RecentDockUsage: Identifiable {
    let bikePoint: BikePoint
    let lastUsedAt: Date

    var id: String { bikePoint.id }
}

private struct DockPickerRow: View {
    let bikePoint: BikePoint
    let availabilityMode: DockPickerView.AvailabilityMode
    var detailText: String?
    var showsDistance = false
    var referenceDock: ScheduledJourneyDock?
    let action: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    private var numericDistance: CLLocationDistance? {
        if let referenceDock {
            return CLLocation(latitude: referenceDock.latitude, longitude: referenceDock.longitude)
                .distance(from: CLLocation(latitude: bikePoint.lat, longitude: bikePoint.lon))
        }
        return locationService.distance(to: bikePoint.coordinate)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                SimplifiedDonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 38,
                    displayMode: availabilityMode == .start ? .bikes : .spaces,
                    bikeDataFilter: bikeDataFilter
                )

                VStack(alignment: .leading, spacing: 4) {
                    if let alias = bikePoint.alias(using: favoritesService) {
                        Text(alias)
                            .foregroundStyle(.primary)
                        Text(bikePoint.commonName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(bikePoint.commonName)
                            .foregroundStyle(.primary)
                    }
                    Text(availabilityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detailText {
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showsDistance {
                    Spacer(minLength: 12)

                    DistanceIndicator(
                        distance: numericDistance,
                        distanceString: referenceDock == nil ? locationService.distanceString(to: bikePoint.coordinate) : numericDistance.map { $0 < 1000 ? String(format: "%.0fm", $0) : String(format: "%.1f miles", $0 / 1609.344) } ?? ""
                    )
                }
            }
        }
    }

    private var availabilityText: String {
        switch availabilityMode {
        case .start:
            return bikeAvailabilityText
        case .end:
            return "\(bikePoint.emptyDocks) \(bikePoint.emptyDocks == 1 ? "space" : "spaces")"
        }
    }

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var bikeAvailabilityText: String {
        let counts = bikeDataFilter.filteredCounts(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks
        )
        var parts: [String] = []

        if bikeDataFilter.showsStandardBikes {
            parts.append("\(counts.standardBikes) \(counts.standardBikes == 1 ? "bike" : "bikes")")
        }

        if bikeDataFilter.showsEBikes {
            parts.append("\(counts.eBikes) \(counts.eBikes == 1 ? "e-bike" : "e-bikes")")
        }

        return parts.joined(separator: " • ")
    }
}

private extension BikePoint {
    func alias(using favoritesService: FavoritesService) -> String? {
        favoritesService.alias(for: id)
    }
}
