#if DEBUG
import SwiftUI
import WidgetKit

struct WatchJourneyTestView: View {
    @State private var settings = JourneyTestSettings()
    @State private var enabled = (JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key)?.expiresAt ?? .distantPast) > Date()

    var body: some View {
        Form {
            Section {
                Text("Local Watch test. To test Smart Stack mirroring too, use Preferences → Debug → Test a Journey on iPhone.")
                    .font(.caption2)
                Button(enabled ? "Restart test" : "Start test") { enabled = true; apply() }
                if enabled {
                    Button("Stop Watch test", role: .destructive) {
                        enabled = false
                        var ended = JourneySimulation.make()
                        ended.expiresAt = .distantPast
                        JourneyStore.write(ended, key: JourneySimulation.key)
                        reload()
                    }
                }
                NavigationLink("View Journey") { WatchJourneyView() }
            }
            JourneyTestControls(settings: $settings)
        }
        .navigationTitle("Test Journey")
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: settings) { _, _ in if enabled { apply() } }
    }

    private func apply() {
        JourneyStore.write(settings.simulation, key: JourneySimulation.key)
        reload()
    }

    private func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyStore.widgetKind)
        NotificationCenter.default.post(name: Notification.Name("journeySnapshotChanged"), object: nil)
    }
}
#endif
