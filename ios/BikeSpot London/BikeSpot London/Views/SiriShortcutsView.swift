import AppIntents
import SwiftUI

struct SiriShortcutsView: View {
    @State private var snapshot = JourneyStore.snapshot
    @State private var pickingDestination = false
    @State private var answer: SiriAvailabilityAnswer?
    @State private var error: String?
    @State private var checking = false
    @State private var lookupTask: Task<Void, Never>?

    private var active: JourneyRun? {
        guard let run = snapshot.active, run.expiresAt > Date() else { return nil }
        return run
    }

    var body: some View {
        Form {
            Section("Docks used by Siri") {
                if let active {
                    LabeledContent("Start dock", value: active.startDock.name)
                    LabeledContent("Destination", value: active.destinationDock.name)
                    Text("Your active journey takes priority. Change its docks in Journeys; Siri uses the new selection next time.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Start dock", value: "Nearest favourite")
                    Text("Without an active journey, bikes uses your nearest favourite. Location access and a recent location are required.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    pickingDestination = true
                } label: {
                    LabeledContent("Saved Siri destination", value: snapshot.siriDestination?.name ?? "Choose dock")
                }
                if active == nil && snapshot.siriDestination == nil {
                    Text("Choose a saved destination above to ask for spaces without starting a journey.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if snapshot.siriDestination != nil {
                    Button("Clear saved destination", role: .destructive) { saveDestination(nil) }
                }
                Text("The saved destination is used only when no journey is active. Availability can change before you arrive.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Try it") {
                Button("Try bikes") { lookup(.bikes) }.disabled(checking)
                Button("Try spaces") { lookup(.spaces) }.disabled(checking)
                if checking { ProgressView("Checking TfL…") }
                if let answer {
                    SiriAvailabilityCard(answer: answer)
                    Text(answer.dialog).font(.callout)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            Section("Say “How many spaces”") {
                Text("1. In Shortcuts, create a new shortcut and add BikeSpot London's Get Spaces at Destination action.")
                Text("2. Keep the dynamic destination action; don't replace it with Get Spaces at Dock.")
                Text("3. Name the shortcut exactly How many spaces, then say “Hey Siri, how many spaces?”")
            }
            Section("Say “How many bikes”") {
                Text("1. Create another shortcut with BikeSpot London's Get Bikes at Start action.")
                Text("2. Keep the dynamic start action. It uses the active start dock, or your nearest favourite when no journey is active.")
                Text("3. Name it exactly How many bikes, then say “Hey Siri, how many bikes?”")
            }
            Section("App shortcuts") {
                ShortcutsLink()
                Text("You can also say “How many spaces in BikeSpot London?” or “How many bikes in BikeSpot London?” without creating a personal shortcut.")
                Text("Use just one action in each personal shortcut. No Open App or Speak Text action is needed. Test that Siri speaks the full answer once.")
            }
            Section("Privacy and Apple Watch") {
                Text("These read-only actions allow Siri to speak dock names while your device is locked, subject to your Siri settings. They don't change or start a journey.")
                Text("Enable Show on Apple Watch for each personal shortcut in Shortcuts. Watch requests the latest phone selection before checking TfL. If the phone can't confirm it, the answer says last synced; that selection may differ from your phone.")
                Text("A missing count or failed check is reported as unavailable, never as zero. Test Siri, AirPods and Watch while stationary.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
        .sheet(isPresented: $pickingDestination) {
            DockPickerView(title: "Siri destination", availabilityMode: .end) { dock in
                saveDestination(JourneyDock(id: dock.id, name: dock.name,
                                            coordinate: .init(latitude: dock.latitude, longitude: dock.longitude)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in snapshot = JourneyStore.snapshot }
        .onDisappear { lookupTask?.cancel() }
    }

    private func saveDestination(_ dock: JourneyDock?) {
        JourneySyncService.shared.setSiriDestination(dock)
        snapshot = JourneyStore.snapshot
        answer = nil
        error = nil
    }

    private func lookup(_ metric: SiriAvailabilityMetric) {
        lookupTask?.cancel()
        answer = nil
        error = nil
        checking = true
        lookupTask = Task { @MainActor in
            defer { checking = false }
            do { answer = try await SiriAvailabilityRuntime.lookup(metric) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
