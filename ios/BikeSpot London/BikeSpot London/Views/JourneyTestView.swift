#if DEBUG
import ActivityKit
import Combine
import SwiftUI

@MainActor
final class JourneyTestService: ObservableObject {
    static let shared = JourneyTestService()
    @Published private(set) var enabled = false
    @Published private(set) var status = ""
    private var expiryTask: Task<Void, Never>?

    private init() {
        let expiresAt = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key)?.expiresAt ?? .distantPast
        enabled = expiresAt > Date() || !Activity<JourneyDemoAttributes>.activities.isEmpty
        if enabled {
            expiryTask = Task {
                let remaining = max(0, expiresAt.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                await stop()
            }
        }
    }

    func apply(_ settings: JourneyTestSettings) async {
        enabled = true
        let simulation = settings.simulation
        JourneyStore.write(simulation, key: JourneySimulation.key)
        FavoritesService.shared.forceSyncWithWatch()
        expiryTask?.cancel()
        expiryTask = Task {
            do { try await Task.sleep(for: .seconds(1800)) } catch { return }
            await stop()
        }
        await updateActivity(simulation, finished: settings.phase == "finished")
    }

    func performWatchAction(_ action: String) async -> Bool {
        guard var simulation = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key),
              simulation.expiresAt > Date(),
              let run = simulation.snapshot.active else { return false }

        switch action {
        case "advance":
            guard run.phase == .pickup else { return false }
            let now = Date()
            simulation.updatedAt = now
            simulation.snapshot.generatedAt = now
            simulation.snapshot.active?.phase = .riding
            simulation.snapshot.active?.rideStartedAt = now
            JourneyStore.write(simulation, key: JourneySimulation.key)
            FavoritesService.shared.forceSyncWithWatch()
            await updateActivity(simulation)
            return true
        case "end":
            await stop()
            return true
        default:
            return false
        }
    }

    private func updateActivity(_ simulation: JourneySimulation, finished: Bool = false) async {
        if finished {
            for activity in Activity<JourneyDemoAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            status = "Journey finished. Test Live Activity ended; complications show the next departure."
            return
        }
        guard let selection = simulation.snapshot.selection(location: simulation.location, nearby: simulation.nearby),
              let availability = simulation.availability[selection.dock.id] else { return }
        let state = DockActivityAttributes.ContentState(
            standardBikes: availability.standardBikes, eBikes: availability.eBikes, emptySpaces: availability.spaces,
            activeDockId: selection.dock.id, activeDockName: selection.dock.name, activeDockAlias: selection.dock.alias,
            activeJourneyPhase: selection.run?.phase.rawValue,
            primaryDisplay: selection.metric.rawValue,
            availabilityUpdatedAtEpochSeconds: Int(availability.updatedAt.timeIntervalSince1970),
            journeyProgress: selection.run?.progress,
            journeyActivityContext: JourneyActivityContext(selection: selection, availability: availability,
                updatedAt: simulation.updatedAt, expiresAt: simulation.expiresAt, isSimulation: true),
            rideStartedAtEpochSeconds: selection.run?.rideStartedAt?.timeIntervalSince1970
        )
        let content = ActivityContent(state: state, staleDate: availability.updatedAt.addingTimeInterval(120))
        if let activity = Activity<JourneyDemoAttributes>.activities.first {
            await activity.update(content)
            guard enabled,
                  JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key)?.updatedAt == simulation.updatedAt else { return }
            status = "Test state sent to Watch. Live Activity updated."
        } else {
            do {
                _ = try Activity.request(attributes: JourneyDemoAttributes(), content: content, pushType: nil)
                status = "Test state sent to Watch. Test Live Activity started."
            } catch {
                status = "Complication test enabled. Couldn’t start Live Activity: \(error.localizedDescription)"
            }
        }
    }

    func stop() async {
        enabled = false
        expiryTask?.cancel()
        expiryTask = nil
        var ended = JourneySimulation.make()
        ended.expiresAt = .distantPast
        // Send a dated tombstone so a queued older test payload cannot restart the simulation.
        JourneyStore.write(ended, key: JourneySimulation.key)
        FavoritesService.shared.forceSyncWithWatch()
        for activity in Activity<JourneyDemoAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        status = "Test stopped. Real journey and dock data restored."
    }
}

struct JourneyTestView: View {
    @StateObject private var service = JourneyTestService.shared
    @State private var settings = JourneyTestSettings()
    @State private var editTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Text("Test the Journey complications and Watch activity without travelling. Add Journey to your watch face, then start this test. Changes below are sent to your paired Watch.")
                Text("Test data expires after 30 minutes. Your real journeys are unchanged.")
                    .foregroundStyle(.secondary)
                Button(service.enabled ? "Restart test" : "Start test journey") {
                    Task { await service.apply(settings) }
                }
                if service.enabled {
                    Button("Stop test and restore real data", role: .destructive) {
                        editTask?.cancel()
                        Task { await service.stop() }
                    }
                }
                if !service.status.isEmpty { Text(service.status).font(.footnote).foregroundStyle(.secondary) }
            }
            JourneyTestControls(settings: $settings)
            Section("What to check") {
                Text("Collecting a bike shows Home and your preferred bike count. Cycling switches to Station and spaces. Labels use your saved availability thresholds: zero is red, below your minimum is orange, and at or above it is green. Move the position slider to update distance and percentage. Finish to return to the next scheduled journey, or test the two nearest-dock fallbacks.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Test a Journey")
        .onChange(of: settings) { _, updated in
            editTask?.cancel()
            guard service.enabled else { return }
            editTask = Task {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard service.enabled, !Task.isCancelled else { return }
                await service.apply(updated)
            }
        }
        .onDisappear { editTask?.cancel() }
    }
}
#endif
