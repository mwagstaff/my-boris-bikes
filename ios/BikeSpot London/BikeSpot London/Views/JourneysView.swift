import Combine
import MapKit
import SwiftUI

private enum CurrentActiveJourney {
    case scheduled(ScheduledJourney)
    case adHoc(AdHocJourney)

    var activityDate: Date {
        switch self {
        case .scheduled(let journey):
            return journey.activeRun?.startedAt ?? journey.updatedAt ?? .distantPast
        case .adHoc(let journey):
            return journey.lastStartedAt ?? journey.createdAt
        }
    }
}

struct JourneysView: View {
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    @StateObject private var favoriteJourneyService = FavoriteJourneyService.shared
    @StateObject private var dockAvailabilityStore = JourneyDockAvailabilityStore()
    @ObservedObject private var dockPreferences = DockPreferencesService.shared
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var locationService: LocationService
    @State private var journeyEditorPresentation: JourneyEditorPresentation?
    @State private var journeyToDelete: ScheduledJourney?
    @State private var favoriteJourneyToDelete: FavoriteJourney?
    private let onDockSelected: (String) -> Void
    private let dockAvailabilityRefreshTimer = Timer.publish(
        every: AppConstants.App.refreshInterval,
        tolerance: AppConstants.App.refreshInterval * 0.1,
        on: .main,
        in: .common
    ).autoconnect()

    init(onDockSelected: @escaping (String) -> Void = { _ in }) {
        self.onDockSelected = onDockSelected
    }

    private var scheduledJourneysByStartDistance: [ScheduledJourney] {
        journeysByStartDistance(scheduledJourneyService.journeys.filter { !$0.isActive }) { $0.startDock }
    }

    private var favoriteJourneysByClosestDockDistance: [FavoriteJourney] {
        guard let userLocation = locationService.location else {
            return favoriteJourneyService.journeys
        }

        return favoriteJourneyService.journeys.sorted { first, second in
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

    private var adHocJourneysByStartDistance: [AdHocJourney] {
        journeysByStartDistance(adHocJourneyService.recentJourneys.filter { !$0.isActive }) { $0.startDock }
    }

    private var currentActiveJourney: CurrentActiveJourney? {
        let scheduled = scheduledJourneyService.journeys
            .filter(\.isActive)
            .map(CurrentActiveJourney.scheduled)
        let adHoc = adHocJourneyService.recentJourneys
            .filter(\.isActive)
            .map(CurrentActiveJourney.adHoc)

        return (scheduled + adHoc).max { $0.activityDate < $1.activityDate }
    }

    private var activeDockIDs: [String] {
        let primaryIDs: [String]
        switch currentActiveJourney {
        case .scheduled(let journey):
            primaryIDs = [journey.startDock.id, journey.endDock.id]
        case .adHoc(let journey):
            primaryIDs = [journey.startDock.id, journey.endDock.id]
        case nil:
            primaryIDs = []
        }
        let customIDs = primaryIDs.flatMap { dockPreferences.customDockIDs(for: $0) ?? [] }
        return Array(Set(primaryIDs + customIDs)).sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let currentActiveJourney {
                    activeJourneyScreen(currentActiveJourney)
                } else {
                    normalJourneysList
                }
            }
            .navigationTitle("Journeys")
            .task {
                locationService.startLocationUpdates()
                await scheduledJourneyService.refresh()
            }
            .task(id: activeDockIDs) {
                refreshActiveDockAvailability(cacheBusting: true)
            }
            .onReceive(dockAvailabilityRefreshTimer) { _ in
                // Skip network refreshes while backgrounded; the scenePhase
                // handler below refreshes on return to active.
                guard scenePhase == .active else { return }
                refreshActiveDockAvailability(cacheBusting: true)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await scheduledJourneyService.refresh()
                    refreshActiveDockAvailability(cacheBusting: true)
                }
            }
            .refreshable {
                await scheduledJourneyService.refresh()
                refreshActiveDockAvailability(cacheBusting: true)
            }
            .sheet(item: $journeyEditorPresentation) { presentation in
                AddJourneyView(presentation: presentation)
            }
            .alert("Delete scheduled journey?", isPresented: Binding(
                get: { journeyToDelete != nil },
                set: { if !$0 { journeyToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let journeyToDelete {
                        Task { await scheduledJourneyService.delete(journeyToDelete) }
                    }
                    journeyToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    journeyToDelete = nil
                }
            } message: {
                Text("This removes the journey from your scheduled journeys.")
            }
            .alert("Delete favourite journey?", isPresented: Binding(
                get: { favoriteJourneyToDelete != nil },
                set: { if !$0 { favoriteJourneyToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let favoriteJourneyToDelete {
                        favoriteJourneyService.remove(favoriteJourneyToDelete)
                    }
                    favoriteJourneyToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    favoriteJourneyToDelete = nil
                }
            } message: {
                Text("This removes the route from your favourite journeys.")
            }
        }
    }

    private var normalJourneysList: some View {
        List {
            Section {
                Button { journeyEditorPresentation = .add } label: {
                    Label("New journey", systemImage: "plus.circle.fill")
                }
            }

            Section {
                if favoriteJourneysByClosestDockDistance.isEmpty {
                    ContentUnavailableView(
                        "No favourite journeys",
                        systemImage: "star",
                        description: Text("Save routes here for quick access.")
                    )
                } else {
                    ForEach(favoriteJourneysByClosestDockDistance) { journey in
                        favoriteJourneyRow(journey)
                    }
                }
            } header: {
                Text("Favourite journeys")
            }

            Section {
                if scheduledJourneysByStartDistance.isEmpty {
                    ContentUnavailableView(
                        "No scheduled journeys",
                        systemImage: "calendar.badge.clock",
                        description: Text("Add your regular routes here.")
                    )
                } else {
                    ForEach(scheduledJourneysByStartDistance) { journey in
                        scheduledJourneyRow(journey)
                    }
                }
            } header: {
                Text("Scheduled Journeys")
            }

            Section {
                if adHocJourneysByStartDistance.isEmpty {
                    ContentUnavailableView(
                        "No ad-hoc journeys",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Save or start a one-off journey and the latest 10 will appear here.")
                    )
                } else {
                    ForEach(adHocJourneysByStartDistance) { journey in
                        adHocJourneyRow(journey)
                    }
                }
            } header: {
                Text("Ad-hoc journeys")
            }
        }
    }

    private func activeJourneyScreen(_ currentActiveJourney: CurrentActiveJourney) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch currentActiveJourney {
                case .scheduled(let journey):
                    scheduledJourneyRow(journey)
                case .adHoc(let journey):
                    adHocJourneyRow(journey)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func refreshActiveDockAvailability(cacheBusting: Bool) {
        dockAvailabilityStore.refresh(dockIDs: activeDockIDs, cacheBusting: cacheBusting)
    }

    private func scheduledJourneyRow(_ journey: ScheduledJourney) -> some View {
        ScheduledJourneyRow(
            journey: journey,
            distanceString: locationService.distanceString(to: journey.startDock.coordinate),
            startBikePoint: dockAvailabilityStore.bikePointsByID[journey.startDock.id],
            endBikePoint: dockAvailabilityStore.bikePointsByID[journey.endDock.id],
            allBikePoints: dockAvailabilityStore.allBikePoints,
            isRefreshingAvailability: dockAvailabilityStore.isRefreshing,
            showsCreateReturn: !hasReturnJourney(for: journey),
            canCreateReturn: scheduledJourneyService.journeys.count < 5,
            isFavorite: favoriteJourneyService.isFavorite(
                startDock: journey.startDock,
                endDock: journey.endDock
            ),
            onStop: { Task { await scheduledJourneyService.stop(journey) } },
            onActivate: { Task { await scheduledJourneyService.activate(journey) } },
            onEdit: { journeyEditorPresentation = .edit(journey) },
            onDelete: { journeyToDelete = journey },
            onToggleFavorite: {
                favoriteJourneyService.toggle(startDock: journey.startDock, endDock: journey.endDock)
            },
            onDockSelected: onDockSelected,
            onCreateReturn: {
                guard scheduledJourneyService.journeys.count < 5 else { return }
                var draft = ScheduledJourneyDraft.returnJourney(from: journey)
                draft.timezone = TimeZone.current.identifier
                journeyEditorPresentation = .addReturn(draft)
            }
        )
    }

    private func favoriteJourneyRow(_ journey: FavoriteJourney) -> some View {
        let docks = journey.docksOrderedByDistance(from: locationService.location)

        return FavoriteJourneyRow(
            startDock: docks.first,
            endDock: docks.second,
            distanceString: locationService.distanceString(to: docks.first.coordinate),
            onStart: {
                Task {
                    await adHocJourneyService.createAndStart(
                        startDock: docks.first,
                        endDock: docks.second
                    )
                }
            },
            onStartReturn: {
                Task {
                    await adHocJourneyService.createAndStart(
                        startDock: docks.second,
                        endDock: docks.first
                    )
                }
            },
            onDelete: { favoriteJourneyToDelete = journey }
        )
    }

    private func adHocJourneyRow(_ journey: AdHocJourney) -> some View {
        AdHocJourneyRow(
            journey: journey,
            distanceString: locationService.distanceString(to: journey.startDock.coordinate),
            startBikePoint: dockAvailabilityStore.bikePointsByID[journey.startDock.id],
            endBikePoint: dockAvailabilityStore.bikePointsByID[journey.endDock.id],
            allBikePoints: dockAvailabilityStore.allBikePoints,
            isRefreshingAvailability: dockAvailabilityStore.isRefreshing,
            isFavorite: favoriteJourneyService.isFavorite(
                startDock: journey.startDock,
                endDock: journey.endDock
            ),
            onStart: { Task { await adHocJourneyService.start(journey) } },
            onStartReturn: { Task { await adHocJourneyService.startReturn(journey) } },
            onStop: { Task { await adHocJourneyService.stop(journey) } },
            onToggleFavorite: {
                favoriteJourneyService.toggle(startDock: journey.startDock, endDock: journey.endDock)
            },
            onDockSelected: onDockSelected
        )
    }

    private func journeysByStartDistance<T>(
        _ journeys: [T],
        startDock: (T) -> ScheduledJourneyDock
    ) -> [T] {
        guard let userLocation = locationService.location else { return journeys }

        return journeys.sorted { first, second in
            let firstDock = startDock(first)
            let secondDock = startDock(second)
            let firstDistance = userLocation.distance(from: firstDock.location)
            let secondDistance = userLocation.distance(from: secondDock.location)

            if firstDistance == secondDistance {
                return firstDock.name.localizedCaseInsensitiveCompare(secondDock.name) == .orderedAscending
            }

            return firstDistance < secondDistance
        }
    }

    private func hasReturnJourney(for journey: ScheduledJourney) -> Bool {
        scheduledJourneyService.journeys.contains { candidate in
            candidate.id != journey.id &&
                candidate.startDock.id == journey.endDock.id &&
                candidate.endDock.id == journey.startDock.id
        }
    }
}

private extension ScheduledJourneyDock {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

private struct AdHocJourneyRow: View {
    let journey: AdHocJourney
    let distanceString: String
    let startBikePoint: BikePoint?
    let endBikePoint: BikePoint?
    let allBikePoints: [BikePoint]
    let isRefreshingAvailability: Bool
    let isFavorite: Bool
    let onStart: () -> Void
    let onStartReturn: () -> Void
    let onStop: () -> Void
    let onToggleFavorite: () -> Void
    let onDockSelected: (String) -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: journey.startDock.coordinate)
    }

    private var journeyProgress: Double? {
        JourneyProgressEstimator.progress(
            from: journey.startDock,
            to: journey.endDock,
            currentLocation: locationService.location
        )
    }

    var body: some View {
        ActiveJourneyCard(isActive: journey.isActive) {
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: journey.isActive ? "figure.outdoor.cycle" : "clock.arrow.circlepath")
                    .foregroundStyle(journey.isActive ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(journey.startDock.displayName(using: favoritesService)) → \(journey.endDock.displayName(using: favoritesService))")
                        .font(.headline)
                        .lineLimit(2)
                    if journey.isActive {
                        Text(journey.activePhase == .start ? "Watching start dock" : "Watching destination dock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else if let lastStartedAt = journey.lastStartedAt {
                        Text("Last started \(lastStartedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Saved \(journey.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? AppConstants.Colors.favoriteHighlight : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isFavorite ? "Remove from favourite journeys" : "Add to favourite journeys")

                DistanceIndicator(
                    distance: numericDistance,
                    distanceString: distanceString
                )
            }

            if journey.isActive {
                ActiveJourneyDockIndicators(
                    startDock: journey.activePhase == .start ? journey.startDock : nil,
                    endDock: journey.endDock,
                    startBikePoint: startBikePoint,
                    endBikePoint: endBikePoint,
                    allBikePoints: allBikePoints,
                    isRefreshing: isRefreshingAvailability,
                    onDockSelected: onDockSelected
                )

                LiveJourneyProgressView(
                    progress: journeyProgress,
                    startName: journey.startDock.displayName(using: favoritesService),
                    endName: journey.endDock.displayName(using: favoritesService)
                )

                Button("End journey", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        adHocStartActions
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        adHocStartActions
                    }
                }
            }
        }
        }
        .journeyListStyle(isActive: journey.isActive)
    }

    private var adHocStartActions: some View {
        Group {
            Button(journey.lastStartedAt == nil ? "Start now" : "Start again", action: onStart)
                .buttonStyle(.borderedProminent)

            Button("Start return journey", action: onStartReturn)
                .buttonStyle(.bordered)
        }
    }
}

private struct FavoriteJourneyRow: View {
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    let distanceString: String
    let onStart: () -> Void
    let onStartReturn: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: startDock.coordinate)
    }

    var body: some View {
        ActiveJourneyCard(isActive: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "figure.outdoor.cycle")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    Text("\(startDock.displayName(using: favoritesService)) → \(endDock.displayName(using: favoritesService))")
                        .font(.headline)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    DistanceIndicator(
                        distance: numericDistance,
                        distanceString: distanceString
                    )

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete favourite journey")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        startActions
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        startActions
                    }
                }
            }
        }
        .journeyListStyle(isActive: false)
    }

    private var startActions: some View {
        Group {
            Button("Start now", action: onStart)
                .buttonStyle(.borderedProminent)

            Button("Start return journey", action: onStartReturn)
                .buttonStyle(.bordered)
        }
    }
}

enum JourneyEditorPresentation: Identifiable {
    case add
    case edit(ScheduledJourney)
    case addReturn(ScheduledJourneyDraft)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let journey):
            return "edit-\(journey.id)"
        case .addReturn(let draft):
            return "return-\(draft.startDock?.id ?? "start")-\(draft.endDock?.id ?? "end")-\(draft.startTime)-\(draft.endTime)"
        }
    }

    var initialDraft: ScheduledJourneyDraft {
        switch self {
        case .add:
            return ScheduledJourneyDraft()
        case .edit(let journey):
            return ScheduledJourneyDraft(journey: journey)
        case .addReturn(let draft):
            return draft
        }
    }

    var editedJourney: ScheduledJourney? {
        if case .edit(let journey) = self {
            return journey
        }
        return nil
    }

    var navigationTitle: String {
        switch self {
        case .add:
            return "New Journey"
        case .addReturn:
            return "Add Journey"
        case .edit:
            return "Edit Journey"
        }
    }

    var isEditing: Bool {
        editedJourney != nil
    }

    var isNewJourney: Bool {
        if case .add = self {
            return true
        }
        return false
    }
}

private struct ScheduledJourneyRow: View {
    let journey: ScheduledJourney
    let distanceString: String
    let startBikePoint: BikePoint?
    let endBikePoint: BikePoint?
    let allBikePoints: [BikePoint]
    let isRefreshingAvailability: Bool
    let showsCreateReturn: Bool
    let canCreateReturn: Bool
    let isFavorite: Bool
    let onStop: () -> Void
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void
    let onDockSelected: (String) -> Void
    let onCreateReturn: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: journey.startDock.coordinate)
    }

    private var journeyProgress: Double? {
        JourneyProgressEstimator.progress(
            from: journey.startDock,
            to: journey.endDock,
            currentLocation: locationService.location
        )
    }

    var body: some View {
        ActiveJourneyCard(isActive: journey.isActive) {
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: journey.isActive ? "figure.outdoor.cycle" : "calendar")
                    .foregroundStyle(journey.isActive ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(journey.startDock.displayName(using: favoritesService)) → \(journey.endDock.displayName(using: favoritesService))")
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(weekdaySummary(journey.weekdays)) • \(journey.startTime)-\(journey.endTime)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let activeRun = journey.activeRun {
                        Text(activeRun.phase == .start ? "Watching start dock" : "Watching destination dock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? AppConstants.Colors.favoriteHighlight : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isFavorite ? "Remove from favourite journeys" : "Add to favourite journeys")

                DistanceIndicator(
                    distance: numericDistance,
                    distanceString: distanceString
                )
            }

            if journey.isActive {
                ActiveJourneyDockIndicators(
                    startDock: journey.isStartPhase ? journey.startDock : nil,
                    endDock: journey.endDock,
                    startBikePoint: startBikePoint,
                    endBikePoint: endBikePoint,
                    allBikePoints: allBikePoints,
                    isRefreshing: isRefreshingAvailability,
                    onDockSelected: onDockSelected
                )

                LiveJourneyProgressView(
                    progress: journeyProgress,
                    startName: journey.startDock.displayName(using: favoritesService),
                    endName: journey.endDock.displayName(using: favoritesService)
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primaryActions
                    secondaryActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    primaryActions
                    secondaryActions
                }
            }
        }
        }
        .journeyListStyle(isActive: journey.isActive)
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            if journey.isActive {
                Button("End journey", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
            } else {
                Button("Start now", action: onActivate)
                    .buttonStyle(.borderedProminent)
            }

            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 8) {
            if showsCreateReturn {
                Button("+ Add return journey", action: onCreateReturn)
                    .buttonStyle(.bordered)
                    .disabled(!canCreateReturn)
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete scheduled journey")
        }
    }

    private func weekdaySummary(_ weekdays: [Int]) -> String {
        if weekdays == [1, 2, 3, 4, 5] { return "Weekdays" }
        if weekdays == [6, 7] { return "Weekends" }
        let labels = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return weekdays.sorted().map { labels[$0] }.joined(separator: ", ")
    }
}

private struct ActiveJourneyDockIndicators: View {
    let startDock: ScheduledJourneyDock?
    let endDock: ScheduledJourneyDock
    let startBikePoint: BikePoint?
    let endBikePoint: BikePoint?
    let allBikePoints: [BikePoint]
    let isRefreshing: Bool
    let onDockSelected: (String) -> Void

    @EnvironmentObject private var favoritesService: FavoritesService
    @ObservedObject private var dockPreferences = DockPreferencesService.shared

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes = AlternativeDockSettings.defaultMinEBikes

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces = AlternativeDockSettings.defaultMinSpaces

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var bikeAvailabilityThreshold: Int {
        switch bikeDataFilter {
        case .both:
            return minBikes + minEBikes
        case .bikesOnly:
            return minBikes
        case .eBikesOnly:
            return minEBikes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let startDock {
                dockIndicator(
                    dock: startDock,
                    bikePoint: startBikePoint,
                    mode: .bikes
                )
            }

            dockIndicator(
                dock: endDock,
                bikePoint: endBikePoint,
                mode: .spaces
            )
        }
    }

    private func dockIndicator(
        dock: ScheduledJourneyDock,
        bikePoint: BikePoint?,
        mode: SimplifiedDonutChart.DisplayMode
    ) -> some View {
        let counts = bikePoint.map {
            bikeDataFilter.filteredCounts(
                standardBikes: $0.standardBikes,
                eBikes: $0.eBikes,
                emptySpaces: $0.emptyDocks
            )
        }
        let count = mode == .bikes ? counts?.totalBikes : counts?.emptySpaces
        let availabilityLabel = mode == .bikes ? "bikes" : "spaces"
        let threshold = mode == .bikes ? bikeAvailabilityThreshold : minSpaces
        let availabilityColor = count.map {
            statusColor(count: $0, threshold: threshold)
        } ?? Color.secondary
        let alternatives = alternatives(for: bikePoint, mode: mode)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                onDockSelected(dock.id)
            } label: {
                HStack(spacing: 10) {
                    SimplifiedDonutChart(
                        standardBikes: bikePoint?.standardBikes ?? 0,
                        eBikes: bikePoint?.eBikes ?? 0,
                        emptySpaces: bikePoint?.emptyDocks ?? 0,
                        size: 44,
                        displayMode: mode,
                        bikeDataFilter: bikeDataFilter
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode == .bikes ? "Start dock" : "End dock")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)

                        Text(dock.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 5) {
                            Text(count.map { "\($0) \(availabilityLabel)" } ?? "Updating availability")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(availabilityColor)
                                .lineLimit(1)

                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityLabel("Loading latest availability")
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "map")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(dock.name) on the map")
            .accessibilityValue(
                count.map { "\($0) \(availabilityLabel) available" } ?? "Availability updating"
            )

            AlternativeDocksEditButton(
                dock: dock,
                availabilityMode: mode == .bikes ? .start : .end
            )
            .font(.footnote)
            .padding(.horizontal, 10)
            .accessibilityLabel("Edit alternative docks for \(dock.displayName(using: favoritesService))")

            if !alternatives.isEmpty {
                JourneyAlternativeDockGrid(
                    alternatives: alternatives,
                    mode: mode,
                    bikeDataFilter: bikeDataFilter,
                    onDockSelected: onDockSelected
                )
            }
        }
    }

    private func alternatives(
        for bikePoint: BikePoint?,
        mode: SimplifiedDonutChart.DisplayMode
    ) -> [BikePoint] {
        guard let bikePoint else { return [] }

        return AlternativeDockSelectionService.alternatives(
            for: bikePoint,
            allBikePoints: allBikePoints,
            favorites: favoritesService.favorites,
            userLocation: nil,
            purpose: alternativePurpose(for: mode),
            maximumCount: maximumAlternativeCount(for: bikePoint),
            filterCustomDocksByAvailability: false
        )
    }

    private func maximumAlternativeCount(for bikePoint: BikePoint) -> Int {
        let configuredCount = dockPreferences.customDockIDs(for: bikePoint.id)?.count
            ?? dockPreferences.snapshot.settings.maxCount
        return max(ActiveJourneyAlternativeDisplay.previewCount, configuredCount)
    }

    private func alternativePurpose(
        for mode: SimplifiedDonutChart.DisplayMode
    ) -> AlternativeDockPurpose {
        guard mode == .bikes else { return .spaces }

        switch bikeDataFilter {
        case .both:
            return .allBikes
        case .bikesOnly:
            return .bikes
        case .eBikesOnly:
            return .eBikes
        }
    }

    private func statusColor(count: Int, threshold: Int) -> Color {
        if count == 0 { return .red }
        if count >= threshold { return .green }
        return .orange
    }
}

private struct JourneyAlternativeDockGrid: View {
    @ObservedObject private var dockPreferences = DockPreferencesService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAllAlternatives = false
    let alternatives: [BikePoint]
    let mode: SimplifiedDonutChart.DisplayMode
    let bikeDataFilter: BikeDataFilter
    let onDockSelected: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var displayedAlternatives: ArraySlice<BikePoint> {
        alternatives.prefix(
            isShowingAllAlternatives
                ? alternatives.count
                : ActiveJourneyAlternativeDisplay.previewCount
        )
    }

    private var hasMoreAlternatives: Bool {
        alternatives.count > ActiveJourneyAlternativeDisplay.previewCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode == .bikes ? "Nearby bikes" : "Nearby spaces")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(displayedAlternatives) { alternative in
                    Button {
                        onDockSelected(alternative.id)
                    } label: {
                        HStack(spacing: 7) {
                            SimplifiedDonutChart(
                                standardBikes: alternative.standardBikes,
                                eBikes: alternative.eBikes,
                                emptySpaces: alternative.emptyDocks,
                                size: 30,
                                displayMode: mode,
                                bikeDataFilter: bikeDataFilter
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(dockPreferences.alias(for: alternative.id) ?? shortName(alternative.commonName))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(availabilityText(for: alternative))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View alternative dock \(dockPreferences.alias(for: alternative.id) ?? alternative.commonName) on the map")
                }
            }

            if hasMoreAlternatives {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        isShowingAllAlternatives.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(isShowingAllAlternatives ? "View fewer alternate docks" : "View more alternate docks")
                        Image(systemName: isShowingAllAlternatives ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityValue(isShowingAllAlternatives ? "Expanded" : "Collapsed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func availabilityText(for bikePoint: BikePoint) -> String {
        if mode == .spaces {
            return "\(bikePoint.emptyDocks) spaces"
        }

        let counts = bikeDataFilter.filteredCounts(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks
        )
        return "\(counts.totalBikes) bikes"
    }

    private func shortName(_ name: String) -> String {
        name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
    }
}

private enum ActiveJourneyAlternativeDisplay {
    static let previewCount = 9
}

private enum JourneyProgressEstimator {
    static func progress(
        from startDock: ScheduledJourneyDock,
        to endDock: ScheduledJourneyDock,
        currentLocation: CLLocation?
    ) -> Double? {
        guard let currentLocation else { return nil }

        let totalDistance = startDock.location.distance(from: endDock.location)
        guard totalDistance > 1 else { return nil }

        let distanceFromStart = currentLocation.distance(from: startDock.location)
        let distanceFromEnd = currentLocation.distance(from: endDock.location)
        let projectedProgress = (
            totalDistance * totalDistance +
            distanceFromStart * distanceFromStart -
            distanceFromEnd * distanceFromEnd
        ) / (2 * totalDistance * totalDistance)

        return min(max(projectedProgress, 0), 1)
    }
}

private struct ActiveJourneyCard<Content: View>: View {
    let isActive: Bool
    private let content: Content

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        if isActive {
            if #available(iOS 26.0, *) {
                content
                    .padding(16)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.18)),
                        in: .rect(cornerRadius: 26)
                    )
                    .overlay { activeBorder }
                    .shadow(color: Color.accentColor.opacity(0.2), radius: 16, y: 6)
                    .padding(.vertical, 6)
            } else {
                content
                    .padding(16)
                    .background {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.2),
                                        Color.accentColor.opacity(0.05),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            }
                    }
                    .overlay { activeBorder }
                    .shadow(color: Color.accentColor.opacity(0.2), radius: 16, y: 6)
                    .padding(.vertical, 6)
            }
        } else {
            content
                .padding(.vertical, 6)
        }
    }

    private var activeBorder: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.7), Color.accentColor.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

private extension View {
    @ViewBuilder
    func journeyListStyle(isActive: Bool) -> some View {
        if isActive {
            self
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            self
        }
    }
}

private struct SubtleActivityPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let scale: CGFloat
    let minimumOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([false, true]) { view, isExpanded in
                view
                    .scaleEffect(isExpanded ? scale : 1)
                    .opacity(isExpanded ? minimumOpacity : 1)
            } animation: { _ in
                .easeInOut(duration: 1.4)
            }
        }
    }
}

private extension View {
    func subtleActivityPulse(scale: CGFloat, minimumOpacity: Double) -> some View {
        modifier(SubtleActivityPulseModifier(scale: scale, minimumOpacity: minimumOpacity))
    }
}

private struct LiveJourneyProgressView: View {
    let progress: Double?
    let startName: String
    let endName: String

    private var resolvedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)

                Spacer()

                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Label("Location unavailable", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                let trackWidth = proxy.size.width
                let markerOffset = max(7, min(trackWidth - 7, trackWidth * resolvedProgress))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(height: 5)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, trackWidth * resolvedProgress), height: 5)

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .overlay { Circle().stroke(Color.accentColor, lineWidth: 3) }
                        .shadow(color: Color.accentColor.opacity(0.8), radius: 5)
                        .subtleActivityPulse(scale: 1.1, minimumOpacity: 0.82)
                        .offset(x: markerOffset - 7)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)

            HStack(alignment: .top) {
                Text(startName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(endName)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journey progress from \(startName) to \(endName)")
        .accessibilityValue(progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Location unavailable")
    }
}

struct AddJourneyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @StateObject private var favoriteJourneyService = FavoriteJourneyService.shared
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    private let presentation: JourneyEditorPresentation
    @State private var draft: ScheduledJourneyDraft
    @State private var addToFavorites = false
    @State private var addAsScheduledJourney = false
    @State private var startJourneyImmediately = false
    @State private var selectedDockField: DockField?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(presentation: JourneyEditorPresentation = .add) {
        self.presentation = presentation
        _draft = State(initialValue: presentation.initialDraft)
    }

    enum DockField: Identifiable {
        case start
        case end

        var id: String {
            switch self {
            case .start: "start"
            case .end: "end"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DockSelectionButton(title: "Start", dock: draft.startDock) {
                        selectedDockField = .start
                    }
                    if let startDock = draft.startDock {
                        AlternativeDocksEditButton(dock: startDock, title: "Start dock alternatives", availabilityMode: .start)
                    }
                    DockSelectionButton(title: "End", dock: draft.endDock) {
                        selectedDockField = .end
                    }
                    if let endDock = draft.endDock {
                        AlternativeDocksEditButton(dock: endDock, title: "End dock alternatives", availabilityMode: .end)
                    }
                } header: {
                    Text("Docks")
                }

                if presentation.isNewJourney {
                    Section {
                        Toggle(isOn: $addToFavorites) {
                            Label("Add to favourites", systemImage: "star")
                        }
                        .disabled(!hasValidDocks || favoriteJourneyAlreadyExists)

                        Toggle(isOn: $addAsScheduledJourney) {
                            Label("Add as a scheduled journey", systemImage: "calendar.badge.clock")
                        }
                        .disabled(!hasValidDocks || scheduledJourneyService.journeys.count >= 5)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if favoriteJourneyAlreadyExists {
                                Text("This route is already in your favourite journeys, so there’s no need to add it again.")
                            } else if addToFavorites {
                                Text("No return journey needed — we’ll automatically show the closest dock first.")
                            }
                            if scheduledJourneyService.journeys.count >= 5 {
                                Text("You already have the maximum of 5 scheduled journeys.")
                            }
                        }
                    }
                }

                if showsSchedule {
                    Section("Days") {
                        WeekdayPicker(selectedWeekdays: $draft.weekdays)
                    }

                    Section("Time Window") {
                        TimePickerRow(title: "Start", time: $draft.startTime)
                        TimePickerRow(title: "End", time: $draft.endTime)
                        if let windowMessage {
                            Text(windowMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if presentation.isNewJourney && canSave {
                    Section {
                        Toggle(isOn: $startJourneyImmediately) {
                            Label("Start journey now", systemImage: "play.circle.fill")
                        }

                        Button {
                            Task { await save() }
                        } label: {
                            Text(isSaving ? "Saving..." : "Save journey")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle(presentation.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !presentation.isNewJourney {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving..." : "Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave || isSaving)
                    }
                }
            }
            .sheet(item: $selectedDockField) { field in
                DockPickerView(
                    title: field == .start ? "Start Dock" : "End Dock",
                    availabilityMode: field == .start ? .start : .end
                ) { dock in
                    switch field {
                    case .start:
                        draft.startDock = dock
                    case .end:
                        draft.endDock = dock
                    }
                    selectedDockField = nil
                }
            }
            .onChange(of: favoriteJourneyAlreadyExists) { _, alreadyExists in
                if alreadyExists {
                    addToFavorites = false
                }
            }
            .onChange(of: scheduledJourneyService.journeys.count) { _, journeyCount in
                if journeyCount >= 5 {
                    addAsScheduledJourney = false
                }
            }
        }
    }

    private var canSave: Bool {
        hasValidDocks && (!showsSchedule || hasValidSchedule)
    }

    private var hasValidDocks: Bool {
        draft.startDock != nil &&
            draft.endDock != nil &&
            draft.startDock?.id != draft.endDock?.id
    }

    private var hasValidSchedule: Bool {
        !draft.weekdays.isEmpty &&
            windowMinutes.map { $0 <= 12 * 60 } == true &&
            (presentation.isEditing || scheduledJourneyService.journeys.count < 5)
    }

    private var showsSchedule: Bool {
        !presentation.isNewJourney || addAsScheduledJourney
    }

    private var favoriteJourneyAlreadyExists: Bool {
        guard let startDock = draft.startDock,
              let endDock = draft.endDock,
              startDock.id != endDock.id else {
            return false
        }
        return favoriteJourneyService.isFavorite(startDock: startDock, endDock: endDock)
    }

    private var windowMinutes: Int? {
        minutesBetween(start: draft.startTime, end: draft.endTime)
    }

    private var windowMessage: String? {
        guard let windowMinutes else { return nil }
        if windowMinutes > 12 * 60 {
            return "Time window must be 12 hours or less."
        }
        if parseMinutes(draft.endTime) ?? 0 <= parseMinutes(draft.startTime) ?? 0 {
            return "Overnight journey window."
        }
        return nil
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        if presentation.isNewJourney {
            await saveNewJourney(startImmediately: startJourneyImmediately)
            return
        }

        do {
            if let editedJourney = presentation.editedJourney {
                _ = try await scheduledJourneyService.update(editedJourney, from: draft)
            } else {
                _ = try await scheduledJourneyService.createJourney(from: draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveNewJourney(startImmediately: Bool) async {
        guard let startDock = draft.startDock, let endDock = draft.endDock else { return }

        do {
            if addAsScheduledJourney {
                _ = try await scheduledJourneyService.createJourney(from: draft)
            }
            if addToFavorites && !favoriteJourneyAlreadyExists {
                favoriteJourneyService.add(startDock: startDock, endDock: endDock)
            }
            if startImmediately {
                await adHocJourneyService.createAndStart(startDock: startDock, endDock: endDock)
            } else {
                adHocJourneyService.save(startDock: startDock, endDock: endDock)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DockSelectionButton: View {
    let title: String
    let dock: ScheduledJourneyDock?
    let action: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(dock?.displayName(using: favoritesService) ?? "Choose")
                    .foregroundStyle(dock == nil ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var selectedWeekdays: [Int]
    private let days = [(1, "M"), (2, "T"), (3, "W"), (4, "T"), (5, "F"), (6, "S"), (7, "S")]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days, id: \.0) { day, label in
                Button {
                    if selectedWeekdays.contains(day) {
                        selectedWeekdays.removeAll { $0 == day }
                    } else {
                        selectedWeekdays.append(day)
                        selectedWeekdays.sort()
                    }
                } label: {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(selectedWeekdays.contains(day) ? Color.accentColor : Color(.secondarySystemFill))
                        .foregroundStyle(selectedWeekdays.contains(day) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TimePickerRow: View {
    let title: String
    @Binding var time: String

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: { date(from: time) },
                set: { time = string(from: $0) }
            ),
            displayedComponents: .hourAndMinute
        )
    }

    private func date(from value: String) -> Date {
        let minutes = parseMinutes(value) ?? 0
        return Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func string(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

private extension ScheduledJourneyDock {
    func displayName(using favoritesService: FavoritesService) -> String {
        favoritesService.alias(for: id) ?? name
    }
}

private func parseMinutes(_ time: String) -> Int? {
    let parts = time.split(separator: ":")
    guard parts.count == 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1]),
          (0...23).contains(hour),
          (0...59).contains(minute) else {
        return nil
    }
    return hour * 60 + minute
}

private func minutesBetween(start: String, end: String) -> Int? {
    guard let startMinutes = parseMinutes(start), let endMinutes = parseMinutes(end) else {
        return nil
    }
    let diff = (endMinutes - startMinutes + 24 * 60) % (24 * 60)
    return diff == 0 ? 24 * 60 : diff
}
