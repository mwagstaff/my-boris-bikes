import Combine
import MapKit
import SwiftUI

struct JourneysView: View {
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    @StateObject private var favoriteJourneyService = FavoriteJourneyService.shared
    @StateObject private var dockAvailabilityStore = JourneyDockAvailabilityStore()
    @ObservedObject private var dockPreferences = DockPreferencesService.shared
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var favoritesService: FavoritesService
    @StateObject private var historyService = JourneyHistoryService.shared
    @State private var historyFilter: JourneyHistoryEntry.Kind?
    @State private var historyLimit = 30
    @State private var selectedSection: JourneySection = .saved
    @State private var journeyEditorPresentation: JourneyEditorPresentation?
    @State private var journeyToDelete: ScheduledJourney?
    @State private var isSwitchingDock = false
    @State private var lastAvailabilityRefreshAttempt: Date?
    @State private var dockSwitchError: String?
    @State private var favoriteJourneyToDelete: FavoriteJourney?
    private let onDockSelected: (String) -> Void
    private let dockAvailabilityRefreshTimer = Timer.publish(
        every: AppConstants.App.nearbyDockRefreshInterval,
        tolerance: 1,
        on: .main,
        in: .common
    ).autoconnect()

    init(onDockSelected: @escaping (String) -> Void = { _ in }) {
        self.onDockSelected = onDockSelected
    }

    private enum JourneySection: String, CaseIterable, Identifiable {
        case current = "Current"
        case saved = "Favourites"
        case history = "History"
        var id: String { rawValue }
    }

    private var activeJourneyID: String? {
        switch currentActiveJourney {
        case .scheduled(let journey): return "scheduled-\(journey.id)"
        case .adHoc(let journey): return "ad-hoc-\(journey.id)"
        case nil: return nil
        }
    }

    private var availableSections: [JourneySection] {
        activeJourneyID == nil ? [.saved, .history] : JourneySection.allCases
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
            VStack(spacing: 0) {
                Picker("Journeys", selection: $selectedSection) {
                    ForEach(availableSections) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                if selectedSection == .current, let currentActiveJourney {
                    activeJourneyScreen(currentActiveJourney)
                } else {
                    normalJourneysList
                }
            }
            .bikeSpotBackground()
            .disabled(isSwitchingDock)
            .alert("Couldn’t change dock", isPresented: Binding(
                get: { dockSwitchError != nil },
                set: { if !$0 { dockSwitchError = nil } }
            )) {
                Button("OK", role: .cancel) { dockSwitchError = nil }
            } message: {
                Text(dockSwitchError ?? "Please try again.")
            }
            .navigationTitle("Journeys")
            .navigationBarTitleDisplayMode(selectedSection == .current ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { journeyEditorPresentation = .add } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New journey")
                }
            }
            .onChange(of: activeJourneyID, initial: true) { _, id in
                if id != nil {
                    selectedSection = .current
                } else if selectedSection == .current {
                    selectedSection = .saved
                }
            }
            .task {
                locationService.startLocationUpdates()
                await scheduledJourneyService.refresh()
            }
            .task(id: selectedSection) {
                if selectedSection == .history { await scheduledJourneyService.refreshHistory() }
            }
            .task(id: activeDockIDs) {
                refreshActiveDockAvailability(cacheBusting: true)
            }
            .onReceive(dockAvailabilityRefreshTimer) { _ in
                // Skip network refreshes while backgrounded; the scenePhase
                // handler below refreshes on return to active.
                guard scenePhase == .active, !dockAvailabilityStore.isRefreshing else { return }
                let interval = isNearActiveDock
                    ? AppConstants.App.nearbyDockRefreshInterval : AppConstants.App.refreshInterval
                guard lastAvailabilityRefreshAttempt.map({ Date().timeIntervalSince($0) >= interval - 1 }) ?? true else { return }
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
                if selectedSection == .history { await scheduledJourneyService.refreshHistory() }
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
            if selectedSection == .saved {
                Section("Favourite routes") {
                    if favoriteJourneysByClosestDockDistance.isEmpty {
                        Text("Save a favourite route when creating a journey.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favoriteJourneysByClosestDockDistance) { favoriteJourneyRow($0) }
                    }
                }
                Section {
                    if scheduledJourneyService.journeys.isEmpty {
                        ContentUnavailableView("No scheduled journeys", systemImage: "calendar",
                            description: Text("Add a regular route and choose the days you ride."))
                    } else {
                        ForEach(scheduledJourneyService.journeys.filter(\.isActive)) { journey in
                            HStack {
                                Button { selectedSection = .current } label: {
                                    Label("\(journey.startDock.displayName(using: favoritesService)) → \(journey.endDock.displayName(using: favoritesService)) · Active", systemImage: "bicycle")
                                }
                                Spacer()
                                Button("Edit") { journeyEditorPresentation = .edit(journey) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        ForEach(scheduledJourneysByStartDistance) { scheduledJourneyRow($0) }
                    }
                } header: {
                    Text("Scheduled journeys")
                }
            } else {
                Section {
                    Picker("Filter history", selection: $historyFilter) {
                        Text("All journeys").tag(Optional<JourneyHistoryEntry.Kind>.none)
                        ForEach(JourneyHistoryEntry.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                    .onChange(of: historyFilter) { _, _ in historyLimit = 30 }
                }
                Section {
                    if filteredHistory.isEmpty {
                        ContentUnavailableView("No journeys yet", systemImage: "clock.arrow.circlepath",
                            description: Text("Journeys you start will appear here automatically."))
                    }
                    ForEach(filteredHistory.prefix(historyLimit)) { entry in
                        historyRow(entry)
                    }
                    if historyLimit < filteredHistory.count {
                        ProgressView().frame(maxWidth: .infinity)
                            .onAppear { historyLimit += 30 }
                    } else if let error = scheduledJourneyService.historyError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await scheduledJourneyService.loadMoreHistory() } }
                        }
                    } else if scheduledJourneyService.hasMoreHistory {
                        ProgressView().frame(maxWidth: .infinity)
                            .task(id: historyService.entries.count) { await scheduledJourneyService.loadMoreHistory() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
    }

    private var filteredHistory: [JourneyHistoryEntry] {
        historyService.entries.filter { historyFilter == nil || $0.kind == historyFilter }
    }

    private func historyRow(_ entry: JourneyHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(entry.startDock.displayName(using: favoritesService)) → \(entry.endDock.displayName(using: favoritesService))")
                .font(.headline)
            Text(entry.dateLabel).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(entry.kind.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Start again", systemImage: "play.fill") {
                        Task { await adHocJourneyService.createAndStart(startDock: entry.startDock, endDock: entry.endDock, kind: entry.kind) }
                    }
                    Button("Start return journey", systemImage: "arrow.uturn.backward") {
                        Task { await adHocJourneyService.createAndStart(startDock: entry.endDock, endDock: entry.startDock, kind: entry.kind) }
                    }
                    Button("Schedule journey", systemImage: "calendar.badge.plus") {
                        journeyEditorPresentation = .schedule(entry)
                    }
                } label: {
                    Label("Journey options", systemImage: "ellipsis.circle")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func activeJourneyScreen(_ currentActiveJourney: CurrentActiveJourney) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch currentActiveJourney {
                case .scheduled(let journey):
                    scheduledJourneyRow(journey)
                case .adHoc(let journey):
                    adHocJourneyRow(journey)
                }

                if let updatedAt = dockAvailabilityStore.lastUpdateTime {
                    Text("Updated \(DockUpdateTime.string(from: updatedAt))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    private var isNearActiveDock: Bool {
        guard let location = locationService.location,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
              abs(location.timestamp.timeIntervalSinceNow) <= 60 else { return false }
        return dockAvailabilityStore.bikePointsByID.values.contains {
            location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))
                <= AppConstants.App.nearbyDockDistanceMeters
        }
    }

    private func refreshActiveDockAvailability(cacheBusting: Bool) {
        lastAvailabilityRefreshAttempt = Date()
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
            onSelectAlternative: { dock in switchActiveDock(to: dock, for: .scheduled(journey)) },
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
            onEdit: { journeyEditorPresentation = .editFavorite(journey) },
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
            onDockSelected: onDockSelected,
            onSelectAlternative: { dock in switchActiveDock(to: dock, for: .adHoc(journey)) }
        )
    }

    private func switchActiveDock(to bikePoint: BikePoint, for activeJourney: CurrentActiveJourney) {
        guard !isSwitchingDock else { return }
        isSwitchingDock = true
        Task {
            defer { isSwitchingDock = false }
            dockSwitchError = await adHocJourneyService.switchDock(to: bikePoint, for: activeJourney)
        }
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

private struct JourneyNextLegButton: View {
    let startDockId: String
    @Binding var isAdvancing: Bool
    @State private var showsFailure = false

    var body: some View {
        Button {
            guard !isAdvancing else { return }
            isAdvancing = true
            Task {
                defer { isAdvancing = false }
                let advanced = await LiveActivityService.shared.advanceJourneyFromStart(
                    dockId: startDockId, source: "journeys_screen"
                )
                showsFailure = !advanced
            }
        } label: {
            HStack(spacing: 6) {
                if isAdvancing { ProgressView().controlSize(.small) }
                Text(isAdvancing ? "Moving to next leg…" : "Next leg")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAdvancing)
        .accessibilityHint("Start watching availability at the destination dock")
        .alert("Couldn’t move to the next leg", isPresented: $showsFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The journey may have changed. Refresh Journeys and try again.")
        }
    }
}

private struct JourneyEndButton: View {
    let onStop: () -> Void

    var body: some View {
        Button(role: .destructive, action: onStop) {
            Text("End journey").frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct ActiveJourneyHeader: View {
    let isStartPhase: Bool
    let startDockID: String
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    @Binding var isAdvancing: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                phaseLabel
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 4) {
                phaseLabel
                HStack { actions }
            }
        }
    }

    private var phaseLabel: some View {
        Label(isStartPhase ? "Watching start dock" : "Riding to end dock", systemImage: "figure.outdoor.cycle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var actions: some View {
        if isStartPhase {
            JourneyNextLegButton(startDockId: startDockID, isAdvancing: $isAdvancing)
                .controlSize(.small)
                .frame(minHeight: 44)
        }
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? AppConstants.Colors.favoriteHighlight : .secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFavorite ? "Remove from favourite journeys" : "Add to favourite journeys")
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
    let onSelectAlternative: (BikePoint) -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @State private var isAdvancing = false

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
            VStack(alignment: .leading, spacing: journey.isActive ? 8 : 16) {
                if !journey.isActive {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(journey.startDock.displayName(using: favoritesService)) → \(journey.endDock.displayName(using: favoritesService))")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let lastStartedAt = journey.lastStartedAt {
                                Text(JourneyHistoryEntry.dateLabel(start: lastStartedAt, end: nil))
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

                    }

                    DistanceIndicator(distance: numericDistance, distanceString: distanceString)
                }

                if journey.isActive {
                    ActiveJourneyHeader(isStartPhase: journey.activePhase == .start, startDockID: journey.startDock.id,
                        isFavorite: isFavorite, onToggleFavorite: onToggleFavorite, isAdvancing: $isAdvancing)

                    ActiveJourneyDockIndicators(
                        startDock: journey.startDock,
                        isStartPhase: journey.activePhase == .start,
                        endDock: journey.endDock,
                        startBikePoint: startBikePoint,
                        endBikePoint: endBikePoint,
                        allBikePoints: allBikePoints,
                        isRefreshing: isRefreshingAvailability,
                        onDockSelected: onDockSelected,
                        onSelectAlternative: onSelectAlternative
                    )
                    .disabled(isAdvancing)

                    LiveJourneyProgressView(
                        progress: journeyProgress,
                        startName: journey.startDock.displayName(using: favoritesService),
                        endName: journey.endDock.displayName(using: favoritesService)
                    )

                    JourneyEndButton(onStop: onStop)
                        .disabled(isAdvancing)
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
    let onEdit: () -> Void
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
                        .fixedSize(horizontal: false, vertical: true)

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

            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)

            Button("Start return journey", action: onStartReturn)
                .buttonStyle(.bordered)
        }
    }
}

enum JourneyEditorPresentation: Identifiable {
    case add
    case edit(ScheduledJourney)
    case editFavorite(FavoriteJourney)
    case fromDock(ScheduledJourneyDock, isStart: Bool)
    case addReturn(ScheduledJourneyDraft)
    case schedule(JourneyHistoryEntry)

    var id: String {
        switch self {
        case .schedule(let entry):
            return "schedule-\(entry.id)"
        case .add:
            return "add"
        case .editFavorite(let journey):
            return "favorite-\(journey.id)"
        case .fromDock(let dock, let isStart):
            return "dock-\(dock.id)-\(isStart)"
        case .edit(let journey):
            return "edit-\(journey.id)"
        case .addReturn(let draft):
            return "return-\(draft.startDock?.id ?? "start")-\(draft.endDock?.id ?? "end")-\(draft.startTime)-\(draft.endTime)"
        }
    }

    var initialDraft: ScheduledJourneyDraft {
        switch self {
        case .schedule(let entry):
            return ScheduledJourneyDraft(startDock: entry.startDock, endDock: entry.endDock)
        case .add:
            return ScheduledJourneyDraft()
        case .editFavorite(let journey):
            return ScheduledJourneyDraft(startDock: journey.startDock, endDock: journey.endDock)
        case .fromDock(let dock, let isStart):
            return ScheduledJourneyDraft(startDock: isStart ? dock : nil, endDock: isStart ? nil : dock)
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
        case .add, .fromDock:
            return "New Journey"
        case .schedule:
            return "Schedule Journey"
        case .addReturn:
            return "Add Journey"
        case .edit, .editFavorite:
            return "Edit Journey"
        }
    }

    var editedFavorite: FavoriteJourney? {
        if case .editFavorite(let journey) = self { return journey }
        return nil
    }

    var startsImmediately: Bool {
        if case .fromDock = self { return true }
        return false
    }

    var isEditing: Bool {
        editedJourney != nil
    }

    var isNewJourney: Bool {
        switch self {
        case .add, .fromDock: return true
        default: return false
        }
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
    let onSelectAlternative: (BikePoint) -> Void
    let onCreateReturn: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @State private var isAdvancing = false

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
            VStack(alignment: .leading, spacing: journey.isActive ? 8 : 16) {
                if !journey.isActive {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(journey.startDock.displayName(using: favoritesService)) → \(journey.endDock.displayName(using: favoritesService))")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(weekdaySummary(journey.weekdays)) • \(journey.startTime)-\(journey.endTime)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                        }

                        Spacer(minLength: 8)

                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .foregroundStyle(isFavorite ? AppConstants.Colors.favoriteHighlight : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isFavorite ? "Remove from favourite journeys" : "Add to favourite journeys")

                    }

                    DistanceIndicator(distance: numericDistance, distanceString: distanceString)
                }

                if journey.isActive {
                    ActiveJourneyHeader(isStartPhase: journey.isStartPhase, startDockID: journey.startDock.id,
                        isFavorite: isFavorite, onToggleFavorite: onToggleFavorite, isAdvancing: $isAdvancing)

                    ActiveJourneyDockIndicators(
                        startDock: journey.startDock,
                        isStartPhase: journey.isStartPhase,
                        endDock: journey.endDock,
                        startBikePoint: startBikePoint,
                        endBikePoint: endBikePoint,
                        allBikePoints: allBikePoints,
                        isRefreshing: isRefreshingAvailability,
                        onDockSelected: onDockSelected,
                        onSelectAlternative: onSelectAlternative
                    )
                    .disabled(isAdvancing)

                    LiveJourneyProgressView(
                        progress: journeyProgress,
                        startName: journey.startDock.displayName(using: favoritesService),
                        endName: journey.endDock.displayName(using: favoritesService)
                    )
                }

                if journey.isActive {
                    JourneyEndButton(onStop: onStop).disabled(isAdvancing)
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
            if !journey.isActive {
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
    let startDock: ScheduledJourneyDock
    let isStartPhase: Bool
    let endDock: ScheduledJourneyDock
    let startBikePoint: BikePoint?
    let endBikePoint: BikePoint?
    let allBikePoints: [BikePoint]
    let isRefreshing: Bool
    let onDockSelected: (String) -> Void
    let onSelectAlternative: (BikePoint) -> Void
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var bikeDataFilter: BikeDataFilter { BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both }
    private var bikeAvailabilityThreshold: Int {
        switch bikeDataFilter {
        case .both: return minBikes + minEBikes
        case .bikesOnly: return minBikes
        case .eBikesOnly: return minEBikes
        }
    }

    var body: some View {
        let column = GridItem(.flexible(minimum: 0), spacing: 8, alignment: .topLeading)
        LazyVGrid(columns: Array(repeating: column, count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                  alignment: .leading, spacing: 8) {
            dockColumn(dock: startDock, bikePoint: startBikePoint, mode: .bikes)
            dockColumn(dock: endDock, bikePoint: endBikePoint, mode: .spaces)
        }
    }

    private func dockColumn(dock: ScheduledJourneyDock, bikePoint: BikePoint?, mode: SimplifiedDonutChart.DisplayMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            dockIndicator(dock: dock, bikePoint: bikePoint, mode: mode)
            if dockPreferences.snapshot.settings.enabled {
                JourneyAlternativeDockList(
                    dock: dock, alternatives: alternatives(for: dock, mode: mode), allBikePoints: allBikePoints,
                    threshold: mode == .bikes ? bikeAvailabilityThreshold : minSpaces,
                    mode: mode, bikeDataFilter: bikeDataFilter, onDockSelected: onDockSelected,
                    onSelectAlternative: onSelectAlternative,
                    allowsDockChange: mode == .bikes ? isStartPhase : !isStartPhase,
                    excludedDockID: mode == .bikes ? endDock.id : startDock.id,
                    isRefreshing: isRefreshing
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dockIndicator(dock: ScheduledJourneyDock, bikePoint: BikePoint?, mode: SimplifiedDonutChart.DisplayMode) -> some View {
        Button { onDockSelected(dock.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(mode == .bikes ? "Start dock" : "End dock")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "map").font(.caption)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.tint)
                Text(dock.displayName(using: favoritesService))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 36, alignment: .topLeading)
                let counts = bikeDataFilter.filteredCounts(standardBikes: bikePoint?.standardBikes ?? 0,
                    eBikes: bikePoint?.eBikes ?? 0, emptySpaces: bikePoint?.emptyDocks ?? 0)
                let count = mode == .spaces ? counts.emptySpaces : counts.totalBikes
                AvailabilityPillLayout(spacing: 8) {
                    SimplifiedDonutChart(standardBikes: bikePoint?.standardBikes ?? 0,
                        eBikes: bikePoint?.eBikes ?? 0, emptySpaces: bikePoint?.emptyDocks ?? 0,
                        size: 40, displayMode: mode, bikeDataFilter: bikeDataFilter,
                        hasAvailability: bikePoint?.hasAvailabilityData == true)
                    AvailabilityPill(count: bikePoint?.hasAvailabilityData == true ? count : nil,
                        label: mode == .spaces ? (count == 1 ? "space" : "spaces")
                            : bikeDataFilter == .eBikesOnly ? (count == 1 ? "e-bike" : "e-bikes")
                            : (count == 1 ? "bike" : "bikes"),
                        symbol: mode == .spaces ? "parkingsign.circle" : "bicycle",
                        threshold: mode == .spaces ? minSpaces : bikeAvailabilityThreshold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .bikeSpotCard()
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("View this dock and its full availability on the map")
    }

    private func alternatives(for dock: ScheduledJourneyDock, mode: SimplifiedDonutChart.DisplayMode) -> [BikePoint] {
        if let saved = dockPreferences.customDocks(for: dock.id) {
            return AlternativeDockSelectionService.savedAlternativesForFavorites(
                for: dock.id, savedDocks: saved, allBikePoints: allBikePoints, showAll: true)
        }
        let purpose: AlternativeDockPurpose
        switch (mode, bikeDataFilter) {
        case (.spaces, _): purpose = .spaces
        case (_, .both): purpose = .allBikes
        case (_, .bikesOnly): purpose = .bikes
        case (_, .eBikesOnly): purpose = .eBikes
        }
        return AlternativeDockSelectionService.alternatives(
            for: BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude),
            allBikePoints: allBikePoints, favorites: favoritesService.favorites,
            userLocation: nil, purpose: purpose, forceShow: true, maximumCount: 20)
    }
}

private struct JourneyAlternativeDockList: View {
    let dock: ScheduledJourneyDock
    let alternatives: [BikePoint]
    let allBikePoints: [BikePoint]
    let threshold: Int
    let mode: SimplifiedDonutChart.DisplayMode
    let bikeDataFilter: BikeDataFilter
    let onDockSelected: (String) -> Void
    let onSelectAlternative: (BikePoint) -> Void
    let allowsDockChange: Bool
    let excludedDockID: String?
    let isRefreshing: Bool
    @ObservedObject private var dockPreferences = DockPreferencesService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAll = false
    @State private var showsOtherNearbyDocks = false

    private var title: String { mode == .bikes ? "Alternative start docks" : "Alternative end docks" }

    private var dialogDocks: [BikePoint] {
        guard showsOtherNearbyDocks else { return alternatives }
        var excluded = Set(dockPreferences.customDockIDs(for: dock.id) ?? [])
        if let excludedDockID { excluded.insert(excludedDockID) }
        return AlternativeDockSelectionService.otherNearbyDocks(
            for: BikePoint(id: dock.id, commonName: dock.name, lat: dock.latitude, lon: dock.longitude),
            allBikePoints: allBikePoints, excludingDockIDs: excluded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Text("Alternatives").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    seeAllButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.subheadline.weight(.semibold))
                    seeAllButton
                }
            }
            if alternatives.isEmpty {
                Text(isRefreshing ? "Loading alternatives…" : dockPreferences.customDockIDs(for: dock.id) == nil
                     ? "No suitable nearby docks available." : "No custom alternatives selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(alternatives.prefix(3))) { alternative in
                compactAlternativeRow(alternative)
                if alternative.id != alternatives.prefix(3).last?.id { Divider() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .bikeSpotCard()
        .sheet(isPresented: $showsAll, onDismiss: { showsOtherNearbyDocks = false }) {
            NavigationStack {
                List {
                    if dockPreferences.customDockIDs(for: dock.id) != nil {
                        Toggle("Other nearby docks", isOn: $showsOtherNearbyDocks)
                    }
                    Section(showsOtherNearbyDocks ? "Other nearby docks · closest first" : "Alternatives") {
                        if dialogDocks.isEmpty {
                            Text(isRefreshing ? "Loading docks…" : "No other docks available.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(dialogDocks) { alternative in
                            alternativeRow(alternative)
                        }
                    }
                    AlternativeDocksEditButton(dock: dock, availabilityMode: mode == .bikes ? .start : .end)
                }
                .bikeSpotBackground(showsPhoto: false)
                .onChange(of: dockPreferences.customDockIDs(for: dock.id)) { _, ids in
                    if ids == nil { showsOtherNearbyDocks = false }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAll = false } }
                }
            }
        }
    }

    private var seeAllButton: some View {
        // Always available: the full list also contains the alternatives editor.
        Button { showsAll = true } label: {
            Text("See all")
                .font(.caption).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("See all \(mode == .bikes ? "start" : "end") alternatives")
    }

    private func compactAlternativeRow(_ alternative: BikePoint) -> some View {
        let fullName = dockPreferences.alias(for: alternative.id) ?? alternative.commonName
        // Keep the borough in the full list and VoiceOver label, not every compact row.
        let shortName = dockPreferences.alias(for: alternative.id)
            ?? alternative.commonName.components(separatedBy: ",").first ?? fullName
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                onDockSelected(alternative.id)
            } label: {
                HStack(spacing: 6) {
                    SimplifiedDonutChart(standardBikes: alternative.standardBikes,
                        eBikes: alternative.eBikes, emptySpaces: alternative.emptyDocks,
                        size: 32, displayMode: .all, bikeDataFilter: bikeDataFilter,
                        hasAvailability: alternative.hasAvailabilityData)
                    Text(shortName)
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(fullName)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("View this dock on the map")
            let layout = dynamicTypeSize > .large
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 0))
            layout {
                availabilityPill(for: alternative)
                if dynamicTypeSize <= .large { Spacer(minLength: 0) }
                useDockButton(for: alternative)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    private func availabilityPill(for alternative: BikePoint) -> some View {
        let counts = bikeDataFilter.filteredCounts(standardBikes: alternative.standardBikes,
            eBikes: alternative.eBikes, emptySpaces: alternative.emptyDocks)
        let count = mode == .spaces ? counts.emptySpaces : counts.totalBikes
        return AvailabilityPill(count: alternative.hasAvailabilityData ? count : nil,
            label: mode == .spaces ? (count == 1 ? "space" : "spaces")
                : bikeDataFilter == .eBikesOnly ? (count == 1 ? "e-bike" : "e-bikes")
                : (count == 1 ? "bike" : "bikes"),
            symbol: mode == .spaces ? "parkingsign.circle" : "bicycle", threshold: threshold)
    }

    @ViewBuilder
    private func useDockButton(for alternative: BikePoint) -> some View {
        if allowsDockChange && alternative.id != excludedDockID {
            Button { onSelectAlternative(alternative) } label: {
                Text("Use")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!alternative.hasAvailabilityData || !alternative.isAvailable)
            .accessibilityLabel("Use \(dockPreferences.alias(for: alternative.id) ?? alternative.commonName) as the \(mode == .bikes ? "start" : "end") dock")
        }
    }

    private func alternativeRow(_ alternative: BikePoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsAll = false
                onDockSelected(alternative.id)
            } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    SimplifiedDonutChart(standardBikes: alternative.standardBikes,
                        eBikes: alternative.eBikes, emptySpaces: alternative.emptyDocks,
                        size: 60, displayMode: .all, bikeDataFilter: bikeDataFilter,
                        hasAvailability: alternative.hasAvailabilityData)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dockPreferences.alias(for: alternative.id) ?? alternative.commonName)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        availabilityPill(for: alternative)
                        let distance = dock.location.distance(from: CLLocation(latitude: alternative.lat, longitude: alternative.lon))
                        Text(distance < 1000 ? String(format: "%.0f m from this dock", distance)
                             : String(format: "%.1f miles from this dock", distance / 1609.344))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("View this dock on the map")
            if allowsDockChange && alternative.id != excludedDockID {
                Button {
                    showsAll = false
                    onSelectAlternative(alternative)
                } label: {
                    Label("Use this dock", systemImage: mode == .bikes ? "bicycle" : "flag.checkered")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(!alternative.hasAvailabilityData || !alternative.isAvailable)
                .accessibilityLabel("Use \(dockPreferences.alias(for: alternative.id) ?? alternative.commonName) as the \(mode == .bikes ? "start" : "end") dock")
            }
        }
        .padding(.vertical, 4)
    }
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
        content.padding(.vertical, isActive ? 4 : 10)
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

private struct LiveJourneyProgressView: View {
    let progress: Double?
    let startName: String
    let endName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedProgress: Double { min(max(progress ?? 0, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Journey progress").font(.headline)
                    Spacer()
                    progressLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Journey progress").font(.headline)
                    progressLabel
                }
            }
            GeometryReader { proxy in
                let travel = max(0, proxy.size.width - 36)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray4).opacity(0.5)).frame(height: 5)
                    Capsule().fill(Color.accentColor)
                        .frame(width: progress == nil ? 0 : 18 + travel * resolvedProgress, height: 5)
                    Image(systemName: "bicycle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 36, height: 36)
                        .background(progress == nil ? Color.gray : Color.accentColor, in: Circle())
                        .offset(x: travel * resolvedProgress)
                }
                .frame(maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: resolvedProgress)
            }
            .frame(height: 40)
            HStack(alignment: .top, spacing: 20) {
                Label(startName, systemImage: "circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(endName, systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .bikeSpotCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journey progress from \(startName) to \(endName)")
        .accessibilityValue(progress.map { "Approximately \(Int($0 * 100)) percent" } ?? "Location unavailable")
    }

    private var progressLabel: some View {
        Text(progress.map { "Approx. \(Int($0 * 100))%" } ?? "Location unavailable")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

struct AddJourneyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @StateObject private var favoriteJourneyService = FavoriteJourneyService.shared
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    private let onJourneyStarted: () -> Void
    private let presentation: JourneyEditorPresentation
    @State private var draft: ScheduledJourneyDraft
    @State private var addToFavorites = false
    @State private var addAsScheduledJourney = false
    @State private var selectedDockField: DockField?
    @State private var isSaving = false
    @State private var createdScheduleID: String?
    @State private var errorMessage: String?

    init(presentation: JourneyEditorPresentation = .add, onJourneyStarted: @escaping () -> Void = {}) {
        self.onJourneyStarted = onJourneyStarted
        self.presentation = presentation
        _draft = State(initialValue: presentation.initialDraft)
        _addAsScheduledJourney = State(initialValue: presentation.editedJourney != nil || {
            switch presentation {
            case .schedule, .addReturn: return true
            default: return false
            }
        }())
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

                if presentation.isNewJourney || presentation.editedFavorite != nil || presentation.editedJourney != nil {
                    Section {
                        if presentation.isNewJourney {
                        Toggle(isOn: $addToFavorites) {
                            Label("Add to favourites", systemImage: "star")
                        }
                        .disabled(!hasValidDocks || favoriteJourneyAlreadyExists)
                        }

                        Toggle(isOn: $addAsScheduledJourney) {
                            Label("Schedule journey", systemImage: "calendar.badge.clock")
                        }
                        .disabled(!hasValidDocks || (presentation.editedJourney == nil && scheduledJourneyService.journeys.count >= 5))
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if favoriteJourneyAlreadyExists {
                                Text("This route is already in your favourite journeys, so there’s no need to add it again.")
                            } else if addToFavorites {
                                Text("No return journey needed — we’ll automatically show the closest dock first.")
                            }
                            if presentation.editedJourney != nil && !addAsScheduledJourney {
                                Text("Saving will remove the schedule and keep this route as a favourite.")
                            }
                            if presentation.editedJourney == nil && scheduledJourneyService.journeys.count >= 5 {
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

                if presentation.isNewJourney {
                    Section {
                        Button {
                            Task { await save() }
                        } label: {
                            Label(isSaving ? "Starting…" : "Start journey", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSave || isSaving)
                    } footer: {
                        Text("Your journey is added to History automatically.")
                    }
                }
            }
            .disabled(isSaving)
            .bikeSpotBackground(showsPhoto: false)
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
                if journeyCount >= 5 && presentation.editedJourney == nil {
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
        addAsScheduledJourney
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
            await saveNewJourney()
            return
        }

        do {
            if let editedJourney = presentation.editedJourney {
                if addAsScheduledJourney {
                    _ = try await scheduledJourneyService.update(editedJourney, from: draft)
                } else {
                    try await scheduledJourneyService.unschedule(editedJourney, draft: draft)
                }
            } else {
                if addAsScheduledJourney {
                    _ = try await scheduledJourneyService.createJourney(from: draft)
                }
                if let favorite = presentation.editedFavorite,
                   let start = draft.startDock, let end = draft.endDock {
                    favoriteJourneyService.update(favorite, startDock: start, endDock: end)
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveNewJourney() async {
        guard let startDock = draft.startDock, let endDock = draft.endDock else { return }

        do {
            if addAsScheduledJourney && createdScheduleID == nil {
                createdScheduleID = try await scheduledJourneyService.createJourney(from: draft).id
            }
            if addToFavorites && !favoriteJourneyAlreadyExists {
                favoriteJourneyService.add(startDock: startDock, endDock: endDock)
            }
            let started = await adHocJourneyService.createAndStart(startDock: startDock, endDock: endDock,
                kind: addAsScheduledJourney ? .scheduled : nil)
            guard started else {
                errorMessage = "Couldn’t start the journey. Check that Live Activities are enabled for BikeSpot London and try again."
                return
            }
            dismiss()
            onJourneyStarted()
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
                        .foregroundStyle(selectedWeekdays.contains(day) ? Color(.systemBackground) : .primary)
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

#Preview("Journey progress · Light") {
    VStack(spacing: 16) {
        LiveJourneyProgressView(progress: 0.32, startName: "Station", endName: "Office")
        LiveJourneyProgressView(progress: nil, startName: "Warwick Row, Westminster", endName: "Stonecutter Street, Holborn")
    }
    .padding().bikeSpotBackground()
}

#Preview("Journey progress · Dark & Large Text") {
    LiveJourneyProgressView(progress: 0.32, startName: "Warwick Row, Westminster", endName: "Stonecutter Street, Holborn")
        .padding().bikeSpotBackground()
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}
