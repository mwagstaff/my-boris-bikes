import Combine
import MapKit
import SwiftUI

struct ProfileView: View {
    @StateObject private var scheduledJourneyService = ScheduledJourneyService.shared
    @State private var isShowingAddJourney = false
    @State private var journeyToDelete: ScheduledJourney?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        NavigationLink {
                            PreferencesView()
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        NavigationLink {
                            AboutView()
                        } label: {
                            Label("About", systemImage: "info.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    if scheduledJourneyService.journeys.isEmpty {
                        ContentUnavailableView(
                            "No scheduled journeys",
                            systemImage: "calendar.badge.clock",
                            description: Text("Add a journey from Favourites to start dock updates automatically.")
                        )
                    } else {
                        ForEach(scheduledJourneyService.journeys) { journey in
                            ScheduledJourneyRow(
                                journey: journey,
                                onStop: {
                                    Task { await scheduledJourneyService.stop(journey) }
                                },
                                onActivate: {
                                    Task { await scheduledJourneyService.activate(journey) }
                                },
                                onDelete: {
                                    journeyToDelete = journey
                                },
                                onCreateReturn: {
                                    Task { await createReturnJourney(from: journey) }
                                }
                            )
                        }
                    }
                } header: {
                    Text("Scheduled Journeys")
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAddJourney = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(scheduledJourneyService.journeys.count >= 5)
                    .accessibilityLabel("Add scheduled journey")
                }
            }
            .task {
                await scheduledJourneyService.refresh()
            }
            .refreshable {
                await scheduledJourneyService.refresh()
            }
            .sheet(isPresented: $isShowingAddJourney) {
                AddJourneyView()
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
                Text("This removes the journey from your profile.")
            }
        }
    }

    private func createReturnJourney(from journey: ScheduledJourney) async {
        guard scheduledJourneyService.journeys.count < 5 else { return }
        var draft = ScheduledJourneyDraft.returnJourney(from: journey)
        draft.timezone = TimeZone.current.identifier
        _ = try? await scheduledJourneyService.createJourney(from: draft)
    }
}

private struct ScheduledJourneyRow: View {
    let journey: ScheduledJourney
    let onStop: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void
    let onCreateReturn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: journey.isActive ? "figure.outdoor.cycle" : "calendar")
                    .foregroundStyle(journey.isActive ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(journey.startDock.name) → \(journey.endDock.name)")
                        .font(.headline)
                    Text("\(weekdaySummary(journey.weekdays)) • \(journey.startTime)-\(journey.endTime)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let activeRun = journey.activeRun {
                        Text(activeRun.phase == .start ? "Watching start dock" : "Watching destination dock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }

            HStack(spacing: 8) {
                if journey.isActive {
                    Button("Stop", role: .destructive, action: onStop)
                        .buttonStyle(.bordered)
                } else {
                    Button("Activate", action: onActivate)
                        .buttonStyle(.borderedProminent)
                }

                Button("Return", action: onCreateReturn)
                    .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete scheduled journey")
            }
        }
        .padding(.vertical, 6)
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
    @State private var draft = ScheduledJourneyDraft()
    @State private var selectedDockField: DockField?
    @State private var isSaving = false
    @State private var errorMessage: String?

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
            .navigationTitle("Add Journey")
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
                DockPickerView(title: field == .start ? "Start Dock" : "End Dock") { dock in
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
        scheduledJourneyService.journeys.count < 5
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
            _ = try await scheduledJourneyService.createJourney(from: draft)
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

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(dock?.name ?? "Choose")
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
    enum Mode: String, CaseIterable, Identifiable {
        case favourites = "Favourites"
        case search = "Search"
        case map = "Map"

        var id: String { rawValue }
    }

    let title: String
    let onSelect: (ScheduledJourneyDock) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var favoritesService: FavoritesService
    @State private var mode: Mode = .favourites
    @State private var searchText = ""
    @State private var allBikePoints: [BikePoint] = []
    @State private var cancellable: AnyCancellable?
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
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
                    List(favouriteBikePoints) { bikePoint in
                        DockPickerRow(bikePoint: bikePoint) {
                            onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                            dismiss()
                        }
                    }
                case .search:
                    List(filteredBikePoints) { bikePoint in
                        DockPickerRow(bikePoint: bikePoint) {
                            onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                            dismiss()
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search dock name")
                case .map:
                    Map(position: $mapPosition) {
                        ForEach(mapBikePoints) { bikePoint in
                            Annotation(bikePoint.commonName, coordinate: bikePoint.coordinate) {
                                Button {
                                    onSelect(ScheduledJourneyDock(bikePoint: bikePoint))
                                    dismiss()
                                } label: {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
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
            }
        }
    }

    private var favouriteBikePoints: [BikePoint] {
        let byId = Dictionary(uniqueKeysWithValues: allBikePoints.map { ($0.id, $0) })
        return favoritesService.favorites.compactMap { favorite in
            byId[favorite.id]
        }
    }

    private var filteredBikePoints: [BikePoint] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return allBikePoints.prefix(80).map { $0 }
        }
        return allBikePoints
            .filter { $0.commonName.localizedCaseInsensitiveContains(searchText) }
            .prefix(80)
            .map { $0 }
    }

    private var mapBikePoints: [BikePoint] {
        allBikePoints.prefix(250).map { $0 }
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

private struct DockPickerRow: View {
    let bikePoint: BikePoint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bikePoint.commonName)
                    .foregroundStyle(.primary)
                Text("\(bikePoint.standardBikes) bikes • \(bikePoint.eBikes) e-bikes • \(bikePoint.emptyDocks) spaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

