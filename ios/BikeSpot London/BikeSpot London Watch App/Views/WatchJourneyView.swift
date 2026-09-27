import Combine
import SwiftUI
import WidgetKit

@MainActor
func updateCachedJourney(after action: String) {
    var snapshot = JourneyStore.snapshot
    guard var active = snapshot.active else { return }

    switch action {
    case "advance":
        active.phase = .riding
        active.rideStartedAt = Date()
        snapshot.active = active
    case "end":
        snapshot.active = nil
    default:
        return
    }

    snapshot.generatedAt = Date()
    JourneyStore.write(snapshot, key: JourneyStore.snapshotKey)
    NotificationCenter.default.post(name: Notification.Name("journeySnapshotChanged"), object: nil)
}

@MainActor
final class WatchJourneyViewModel: ObservableObject {
    @Published private(set) var state: JourneyDisplayState
    @Published private(set) var isRefreshing = false
    let activityContext: JourneyActivityContext?

    init(activityContext: JourneyActivityContext? = nil) {
        self.activityContext = activityContext
        state = activityContext.map { JourneyDataSource.activityState($0) } ?? JourneyDataSource.cached()
    }

    func reloadCached() { state = activityContext.map { JourneyDataSource.activityState($0) } ?? JourneyDataSource.cached() }
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        _ = await WatchFavoritesService.shared.requestJourneyRefreshFromPhone()
        let updated = await JourneyDataSource.refresh(activityContext: activityContext)
        guard !Task.isCancelled else { return }
        state = updated
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyStore.widgetKind)
    }
}

struct WatchJourneyView: View {
    @StateObject private var model: WatchJourneyViewModel
    @ObservedObject private var locationService = WatchLocationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var isVisible = false
    @State private var isPerformingJourneyAction = false
    @State private var journeyActionMessage: String?

    init(activityContext: JourneyActivityContext? = nil) {
        _model = StateObject(wrappedValue: WatchJourneyViewModel(activityContext: activityContext))
    }

    private var embedsDockDetail: Bool {
        model.state.selection != nil && !model.state.isSimulation
    }

    private var currentSimulation: JourneySimulation? {
        guard var simulation = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key) else { return nil }
        simulation.snapshot = model.state.snapshot
        return simulation
    }

    var body: some View {
        Group {
            if let selection = model.state.selection, model.state.isSimulation {
                simulationAlternativesView(selection: selection)
            } else if let selection = model.state.selection {
                WatchWidgetDetailView(
                    primaryDockId: selection.dock.id,
                    journeyMetricRawValue: selection.metric.rawValue,
                    showsJourneyActions: selection.source == .active,
                    autoRefresh: true,
                    compactCards: true,
                    alwaysShowsEndAction: true,
                    initialDock: selection.dock,
                    initialAvailability: model.state.availability,
                    journeyProgress: model.state.progress
                )
                .id(selection.dock.id + selection.metric.rawValue)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if model.state.isSimulation {
                            Text("TEST JOURNEY").font(.caption2).foregroundStyle(.orange)
                        }
                        if model.activityContext != nil {
                            Text("Activity ended").font(.headline)
                            Text("Start a new journey or test to see its activity.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "location.circle").font(.largeTitle)
                            Text("Location needed").font(.headline)
                            Text("Allow location on your Watch to find the nearest dock. Open the iPhone app to sync journeys and favourites.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Refresh") {
                                locationService.requestLocationPermission()
                                WatchFavoritesService.shared.attemptAutomaticSync()
                                Task { await model.refresh() }
                            }
                        }
#if DEBUG
                        NavigationLink("Test a journey") { WatchJourneyTestView() }
                            .font(.caption2)
#endif
                    }.padding(.horizontal, 8).padding(.bottom)
                }
            }
        }
        .navigationTitle("Journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !embedsDockDetail {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchRefreshButton(isLoading: model.isRefreshing) {
                        Task { await model.refresh() }
                    }
                    .accessibilityLabel("Refresh journey")
                }
            }
        }
        .onAppear {
            isVisible = true
            locationService.startLocationUpdates()
            WatchFavoritesService.shared.attemptAutomaticSync()
            model.reloadCached()
        }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("journeySnapshotChanged"))) { _ in
            model.reloadCached()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockPreferencesDidChange)) { _ in
            model.reloadCached()
        }
        .onReceive(locationService.$location.receive(on: DispatchQueue.main)) { _ in model.reloadCached() }
        .task(id: isVisible && scenePhase == .active && !embedsDockDetail) {
            guard isVisible, scenePhase == .active, !embedsDockDetail else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }

    @ViewBuilder
    private func journeyActionControls(for selection: JourneySelection) -> some View {
        if selection.source == .active {
            VStack(spacing: 6) {
                if selection.run?.phase == .pickup {
                    Text("Watching start dock").font(.caption2).foregroundStyle(.secondary)
                    Button {
                        Task { await performJourneyAction("advance", dockId: selection.dock.id) }
                    } label: {
                        journeyActionLabel("Next leg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPerformingJourneyAction)
                    .accessibilityHint("Start watching availability at the destination dock")
                }

                Button {
                    Task { await performJourneyAction("end", dockId: selection.dock.id) }
                } label: {
                    journeyActionLabel("End journey")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isPerformingJourneyAction)

                if let journeyActionMessage {
                    Text(journeyActionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if !WatchFavoritesService.shared.isConnectedToPhone {
                    Text("Requires iPhone connection.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func journeyActionLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            if isPerformingJourneyAction { ProgressView().controlSize(.mini) }
            Text(title).font(.system(.caption, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private func performJourneyAction(_ action: String, dockId: String) async {
        isPerformingJourneyAction = true
        journeyActionMessage = nil
        let isSimulation = model.state.isSimulation
        let result = await WatchFavoritesService.shared.performJourneyAction(
            action: action, dockId: dockId, isSimulation: isSimulation
        )
        isPerformingJourneyAction = false
        journeyActionMessage = result.success ? nil : "Couldn’t update journey."
        guard result.success else { return }
        if !isSimulation { updateCachedJourney(after: action) }
        model.reloadCached()
        if action == "end" { dismiss() }
    }

    @ViewBuilder
    private func simulationAlternativesView(selection: JourneySelection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEST JOURNEY")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let primaryAvailability = model.state.availability {
                    CompactJourneyDockAvailabilityCard(
                        dockName: selection.dock.displayName,
                        availability: primaryAvailability,
                        distanceString: nil,
                        metric: selection.metric,
                        threshold: model.state.snapshot.threshold(for: selection.metric),
                        isPrimary: true
                    )
                } else {
                    ProgressView("Loading dock…")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                }

                if selection.run?.phase == .riding {
                    JourneyProgressBar(progress: model.state.progress)
                }

                simulationAlternativeSection(selection: selection)
                journeyActionControls(for: selection)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func simulationAlternativeSection(selection: JourneySelection) -> some View {
        if let simulation = currentSimulation,
           simulation.expiresAt > Date(),
           simulation.updatedAt >= (model.activityContext?.updatedAt ?? .distantPast) {
            let customDockIDs = WatchFavoritesService.shared.customDockIDs(for: selection.dock.id)
            let alternatives = customDockIDs != nil && !WatchFavoritesService.shared.customAlternativesEnabled
                ? [] : simulation.alternativeDocks(
                from: selection.dock,
                metric: selection.metric,
                customDockIDs: customDockIDs,
                limit: WatchFavoritesService.shared.customAlternativeLimit(maximum: 3)
            )

            Text(WatchFavoritesService.shared.customDockIDs(for: selection.dock.id) == nil
                 ? "Nearby alternatives" : "Preferred alternatives")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.secondary)

            if alternatives.isEmpty {
                Text("No alternatives with enough \(selection.metric.label(count: 2)).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alternatives) { dock in
                    if let availability = simulation.availability[dock.id] {
                        CompactJourneyDockAvailabilityCard(
                            dockName: dock.displayName,
                            availability: availability,
                            distanceString: simulationDistance(from: selection.dock, to: dock),
                            metric: selection.metric,
                            threshold: model.state.snapshot.threshold(for: selection.metric),
                            isPrimary: false
                        )
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                if model.isRefreshing { ProgressView().controlSize(.mini) }
                Text(model.isRefreshing ? "Refreshing alternatives…" : "Connect to iPhone, then refresh for alternatives.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func simulationDistance(from primary: JourneyDock, to alternative: JourneyDock) -> String? {
        guard let start = primary.coordinate, let end = alternative.coordinate else { return nil }
        let meters = start.distance(to: end)
        return meters < 1_000
            ? String(format: "%.0fm", meters)
            : String(format: "%.1fmi", meters * 0.000621371)
    }
}

#Preview { NavigationStack { WatchJourneyView() } }
