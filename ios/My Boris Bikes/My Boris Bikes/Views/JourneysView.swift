import Combine
import MapKit
import SwiftUI

struct JourneysView: View {
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    @EnvironmentObject private var locationService: LocationService
    @State private var journeyEditorPresentation: JourneyEditorPresentation?
    @State private var adHocDraftPresentation: AdHocJourneyDraftPresentation?
    @State private var journeyToDelete: ScheduledJourney?

    private var scheduledJourneysByStartDistance: [ScheduledJourney] {
        journeysByStartDistance(scheduledJourneyService.journeys) { $0.startDock }
    }

    private var adHocJourneysByStartDistance: [AdHocJourney] {
        journeysByStartDistance(adHocJourneyService.recentJourneys) { $0.startDock }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { journeyEditorPresentation = .add } label: {
                        Label("Add scheduled journey", systemImage: "calendar.badge.plus")
                    }
                    .disabled(scheduledJourneyService.journeys.count >= 5)

                    Button { adHocDraftPresentation = .new } label: {
                        Label("Start ad-hoc journey", systemImage: "figure.outdoor.cycle")
                    }
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
                            ScheduledJourneyRow(
                                journey: journey,
                                distanceString: locationService.distanceString(to: journey.startDock.coordinate),
                                showsCreateReturn: !hasReturnJourney(for: journey),
                                canCreateReturn: scheduledJourneyService.journeys.count < 5,
                                onStop: { Task { await scheduledJourneyService.stop(journey) } },
                                onActivate: { Task { await scheduledJourneyService.activate(journey) } },
                                onEdit: { journeyEditorPresentation = .edit(journey) },
                                onDelete: { journeyToDelete = journey },
                                onCreateReturn: {
                                    guard scheduledJourneyService.journeys.count < 5 else { return }
                                    var draft = ScheduledJourneyDraft.returnJourney(from: journey)
                                    draft.timezone = TimeZone.current.identifier
                                    journeyEditorPresentation = .addReturn(draft)
                                }
                            )
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
                            description: Text("Start a one-off journey and the latest 10 will appear here.")
                        )
                    } else {
                        ForEach(adHocJourneysByStartDistance) { journey in
                            AdHocJourneyRow(
                                journey: journey,
                                distanceString: locationService.distanceString(to: journey.startDock.coordinate),
                                onStart: { Task { await adHocJourneyService.start(journey) } },
                                onStartReturn: { Task { await adHocJourneyService.startReturn(journey) } },
                                onStop: { Task { await adHocJourneyService.stop(journey) } }
                            )
                        }
                    }
                } header: {
                    Text("Ad-hoc journeys")
                }
            }
            .navigationTitle("Journeys")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { journeyEditorPresentation = .add } label: {
                            Label("Scheduled journey", systemImage: "calendar.badge.plus")
                        }
                        .disabled(scheduledJourneyService.journeys.count >= 5)

                        Button { adHocDraftPresentation = .new } label: {
                            Label("Ad-hoc journey", systemImage: "figure.outdoor.cycle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add journey")
                }
            }
            .task {
                locationService.startLocationUpdates()
                await scheduledJourneyService.refresh()
            }
            .refreshable {
                await scheduledJourneyService.refresh()
            }
            .sheet(item: $journeyEditorPresentation) { presentation in
                AddJourneyView(presentation: presentation)
            }
            .sheet(item: $adHocDraftPresentation) { _ in
                AdHocJourneyStartFlowView()
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

enum AdHocJourneyDraftPresentation: Identifiable {
    case new
    var id: String { "new" }
}

private struct AdHocJourneyStartFlowView: View {
    @State private var startDock: ScheduledJourneyDock?
    @State private var endDock: ScheduledJourneyDock?

    var body: some View {
        if let startDock, let endDock {
            AdHocJourneySetupView(initialStartDock: startDock, initialEndDock: endDock)
        } else if let startDock {
            DockPickerView(title: "End Dock", availabilityMode: .end, dismissOnSelect: false) { dock in
                endDock = dock
            }
        } else {
            DockPickerView(title: "Start Dock", availabilityMode: .start, dismissOnSelect: false) { dock in
                startDock = dock
            }
        }
    }
}

private struct AdHocJourneyRow: View {
    let journey: AdHocJourney
    let distanceString: String
    let onStart: () -> Void
    let onStartReturn: () -> Void
    let onStop: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: journey.startDock.coordinate)
    }

    var body: some View {
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
                    }
                }

                Spacer(minLength: 8)

                DistanceIndicator(
                    distance: numericDistance,
                    distanceString: distanceString
                )
            }

            if journey.isActive {
                Button("Stop", role: .destructive, action: onStop)
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
        .padding(.vertical, 6)
    }

    private var adHocStartActions: some View {
        Group {
            Button("Start again", action: onStart)
                .buttonStyle(.borderedProminent)

            Button("Start return journey", action: onStartReturn)
                .buttonStyle(.bordered)
        }
    }
}

struct AdHocJourneySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var adHocJourneyService = AdHocJourneyService.shared
    @State private var startDock: ScheduledJourneyDock?
    @State private var endDock: ScheduledJourneyDock?
    @State private var selectedDockField: AddJourneyView.DockField?
    @State private var isStarting = false

    init(initialStartDock: ScheduledJourneyDock? = nil, initialEndDock: ScheduledJourneyDock? = nil) {
        _startDock = State(initialValue: initialStartDock)
        _endDock = State(initialValue: initialEndDock)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Docks") {
                    DockSelectionButton(title: "Start", dock: startDock) { selectedDockField = .start }
                    DockSelectionButton(title: "End", dock: endDock) { selectedDockField = .end }
                }
            }
            .navigationTitle("Ad-hoc Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting..." : "Start") {
                        Task { await start() }
                    }
                    .disabled(!canStart || isStarting)
                }
            }
            .sheet(item: $selectedDockField) { field in
                DockPickerView(
                    title: field == .start ? "Start Dock" : "End Dock",
                    availabilityMode: field == .start ? .start : .end
                ) { dock in
                    switch field {
                    case .start: startDock = dock
                    case .end: endDock = dock
                    }
                    selectedDockField = nil
                }
            }
        }
    }

    private var canStart: Bool {
        startDock != nil && endDock != nil && startDock?.id != endDock?.id
    }

    private func start() async {
        guard let startDock, let endDock, canStart else { return }
        isStarting = true
        await adHocJourneyService.createAndStart(startDock: startDock, endDock: endDock)
        isStarting = false
        dismiss()
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
        case .add, .addReturn:
            return "Add Journey"
        case .edit:
            return "Edit Journey"
        }
    }

    var isEditing: Bool {
        editedJourney != nil
    }
}

private struct ScheduledJourneyRow: View {
    let journey: ScheduledJourney
    let distanceString: String
    let showsCreateReturn: Bool
    let canCreateReturn: Bool
    let onStop: () -> Void
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onCreateReturn: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: journey.startDock.coordinate)
    }

    var body: some View {
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

                DistanceIndicator(
                    distance: numericDistance,
                    distanceString: distanceString
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
        .padding(.vertical, 6)
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            if journey.isActive {
                Button("Stop", role: .destructive, action: onStop)
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

struct AddJourneyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    private let presentation: JourneyEditorPresentation
    @State private var draft: ScheduledJourneyDraft
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
                Section("Docks") {
                    DockSelectionButton(title: "Start", dock: draft.startDock) {
                        selectedDockField = .start
                    }
                    DockSelectionButton(title: "End", dock: draft.endDock) {
                        selectedDockField = .end
                    }
                }

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

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(presentation.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
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
        }
    }

    private var canSave: Bool {
        draft.startDock != nil &&
        draft.endDock != nil &&
        draft.startDock?.id != draft.endDock?.id &&
        !draft.weekdays.isEmpty &&
        windowMinutes.map { $0 <= 12 * 60 } == true &&
        (presentation.isEditing || scheduledJourneyService.journeys.count < 5)
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

private struct DockPickerView: View {
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

                switch mode {
                case .favourites:
                    List {
                        Section {
                            ForEach(favouriteBikePoints) { bikePoint in
                                DockPickerRow(
                                    bikePoint: bikePoint,
                                    availabilityMode: availabilityMode,
                                    showsDistance: true
                                ) {
                                    onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                    dismissIfNeeded()
                                }
                            }
                        } header: {
                            Text("Favourite docks")
                        }

                        Section {
                            if locationService.location == nil {
                                Label("Current location unavailable", systemImage: "location.slash")
                                    .foregroundStyle(.secondary)
                            } else if allBikePoints.isEmpty {
                                Label("Loading nearby docks...", systemImage: "location")
                                    .foregroundStyle(.secondary)
                            } else if nearbyBikePoints.isEmpty {
                                Label("No nearby docks found", systemImage: "bicycle")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(nearbyBikePoints) { bikePoint in
                                    DockPickerRow(
                                        bikePoint: bikePoint,
                                        availabilityMode: availabilityMode,
                                        showsDistance: true
                                    ) {
                                        onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                        dismissIfNeeded()
                                    }
                                }
                            }
                        } header: {
                            Text("Nearby docks")
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
                                showsDistance: true
                            ) {
                                onSelect(ScheduledJourneyDock(bikePoint: recent.bikePoint))
                                dismissIfNeeded()
                            }
                        }
                    }
                case .map:
                    ZStack {
                        Map(position: $mapPosition) {
                            ForEach(mapBikePoints) { bikePoint in
                                Annotation("", coordinate: bikePoint.coordinate) {
                                    Button {
                                        onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                        dismissIfNeeded()
                                    } label: {
                                        DockPickerMapMarker(bikePoint: bikePoint)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Select \(bikePoint.commonName)")
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
                            showsDistance: true
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
                if let location = locationService.location {
                    centerMap(on: location.coordinate)
                    hasCenteredOnInitialLocation = true
                }
            }
            .onDisappear {
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

    private var favouriteBikePoints: [BikePoint] {
        let byId = Dictionary(uniqueKeysWithValues: allBikePoints.map { ($0.id, $0) })
        return favoritesService.favorites.compactMap { favorite in
            byId[favorite.id]
        }
    }

    private var nearbyBikePoints: [BikePoint] {
        let favouriteIds = Set(favoritesService.favorites.map(\.id))
        return sortedByDistance(allBikePoints.filter { !favouriteIds.contains($0.id) })
            .prefix(5)
            .map { $0 }
    }

    private var recentBikePoints: [RecentDockUsage] {
        let byId = Dictionary(uniqueKeysWithValues: allBikePoints.map { ($0.id, $0) })
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
            matchingBikePoints = allBikePoints
        } else {
            matchingBikePoints = allBikePoints.filter {
                $0.commonName.localizedCaseInsensitiveContains(trimmedSearchText) ||
                    ($0.alias(using: favoritesService)?.localizedCaseInsensitiveContains(trimmedSearchText) == true)
            }
        }

        return sortedByDistance(matchingBikePoints)
            .prefix(80)
            .map { $0 }
    }

    private var mapBikePoints: [BikePoint] {
        return allBikePoints
            .sorted {
                squaredDistanceMeters(from: currentMapCenter, to: $0.coordinate)
                    < squaredDistanceMeters(from: currentMapCenter, to: $1.coordinate)
            }
            .prefix(250)
            .map { $0 }
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
        guard let userCoordinate = locationService.location?.coordinate,
              let nearestBikePoint = allBikePoints.min(by: {
                  squaredDistanceMeters(from: userCoordinate, to: $0.coordinate)
                      < squaredDistanceMeters(from: userCoordinate, to: $1.coordinate)
              }) else {
            return
        }

        centerMap(on: nearestBikePoint.coordinate)
    }

    private func sortedByDistance(_ bikePoints: [BikePoint]) -> [BikePoint] {
        guard let userCoordinate = locationService.location?.coordinate else {
            return bikePoints
        }

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
        let cached = AllBikePointsCache.shared.load()
        if !cached.isEmpty {
            allBikePoints = cached
        }

        cancellable = TfLAPIService.shared.fetchAllBikePoints(cacheBusting: false)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { bikePoints in
                    allBikePoints = bikePoints.filter(\.isInstalled)
                    AllBikePointsCache.shared.save(allBikePoints, savedAt: Date())
                }
            )
    }
}

private struct DockPickerMapMarker: View {
    let bikePoint: BikePoint

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                SimplifiedDonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 40
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
            .contentShape(Circle())

            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
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
        bikePoint.commonName
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
    let action: () -> Void
    @EnvironmentObject private var favoritesService: FavoritesService
    @EnvironmentObject private var locationService: LocationService
    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    private var numericDistance: CLLocationDistance? {
        locationService.distance(to: bikePoint.coordinate)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                SimplifiedDonutChart(
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    size: 38,
                    displayMode: availabilityMode == .start ? .bikes : .spaces
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
                        distanceString: locationService.distanceString(to: bikePoint.coordinate)
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

    private var bikeAvailabilityText: String {
        let filter = BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
        let counts = filter.filteredCounts(
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks
        )
        var parts: [String] = []

        if filter.showsStandardBikes {
            parts.append("\(counts.standardBikes) \(counts.standardBikes == 1 ? "bike" : "bikes")")
        }

        if filter.showsEBikes {
            parts.append("\(counts.eBikes) \(counts.eBikes == 1 ? "e-bike" : "e-bikes")")
        }

        return parts.joined(separator: " • ")
    }
}

private extension ScheduledJourneyDock {
    func displayName(using favoritesService: FavoritesService) -> String {
        favoritesService.alias(for: id) ?? name
    }
}

private extension BikePoint {
    func alias(using favoritesService: FavoritesService) -> String? {
        favoritesService.alias(for: id)
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
