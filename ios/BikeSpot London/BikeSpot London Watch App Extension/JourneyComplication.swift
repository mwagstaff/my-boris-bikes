import SwiftUI
import WidgetKit

struct JourneyEntry: TimelineEntry {
    let date: Date
    let state: JourneyDisplayState
}

struct JourneyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JourneyEntry {
        let dock = JourneyDock(id: "preview", name: "Warwick Row", alias: "🚉 Station")
        let selection = JourneySelection(dock: dock, metric: .spaces, source: .active)
        return JourneyEntry(date: Date(), state: JourneyDisplayState(snapshot: .empty, selection: selection,
            availability: JourneyAvailability(standardBikes: 9, eBikes: 3, spaces: 8, updatedAt: Date())))
    }

    func getSnapshot(in context: Context, completion: @escaping (JourneyEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : JourneyEntry(date: Date(), state: JourneyDataSource.cached()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JourneyEntry>) -> Void) {
        Task {
            let state = await JourneyDataSource.refresh()
            let now = Date()
            var entries = [JourneyEntry(date: now, state: state)]
            // A later render changes only the freshness indicator, never invents new counts.
            if let staleDate = state.availability?.updatedAt.addingTimeInterval(121), staleDate > now {
                entries.append(JourneyEntry(date: staleDate, state: state))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
        }
    }
}

struct JourneyComplicationView: View {
    let entry: JourneyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let selection = entry.state.selection {
                if family == .accessoryCircular {
                    JourneyDonut(availability: entry.state.availability, metric: selection.metric,
                                 identifier: selection.dock.identifier, size: 38)
                        .overlay(alignment: .bottomTrailing) {
                            if entry.state.availability?.isStale(at: entry.date) == true {
                                Image(systemName: "clock.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            }
                        }
                } else {
                    HStack(spacing: 8) {
                        JourneyDonut(availability: entry.state.availability, metric: selection.metric, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selection.dock.displayName)
                                .font(.system(.caption, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                            JourneyAvailabilityLabel(availability: entry.state.availability, metric: selection.metric,
                                                     threshold: entry.state.snapshot.threshold(for: selection.metric))
                            if entry.state.isSimulation {
                                Text("TEST").font(.system(size: 9)).foregroundStyle(.orange)
                            } else if entry.state.availability?.isStale(at: entry.date) == true {
                                Text("Last known").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "bicycle")
                    Text("Open Journey").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "myborisbikes://journey?view=alternatives"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let selection = entry.state.selection else { return "Journey, open to load nearby docks" }
        guard let availability = entry.state.availability else { return "\(selection.dock.displayName), availability unavailable" }
        let count = selection.metric.count(in: availability)
        let status = count == 0 ? "none available" : count < entry.state.snapshot.threshold(for: selection.metric) ? "low availability" : "available"
        return "\(selection.dock.displayName), \(count) \(selection.metric.label(count: count)), \(status)"
            + (availability.isStale(at: entry.date) ? ", last known data" : "")
    }
}

struct JourneyComplication: Widget {
    let kind = JourneyStore.widgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JourneyTimelineProvider()) { JourneyComplicationView(entry: $0) }
            .configurationDisplayName("Journey")
            .description("Bikes before you ride, destination spaces while you ride. Tap for alternatives.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .accessoryCircular) {
    JourneyComplication()
} timeline: {
    JourneyEntry(date: Date(), state: JourneyDisplayState(snapshot: .empty,
        selection: JourneySelection(dock: JourneyDock(id: "preview", name: "Warwick Row"), metric: .eBikes, source: .favorite),
        availability: JourneyAvailability(standardBikes: 8, eBikes: 4, spaces: 10, updatedAt: Date())))
}

#Preview(as: .accessoryRectangular) {
    JourneyComplication()
} timeline: {
    JourneyEntry(date: Date(), state: JourneyDisplayState(snapshot: .empty,
        selection: JourneySelection(dock: JourneyDock(id: "preview", name: "Station", alias: "🚉 Station"), metric: .spaces, source: .active),
        availability: JourneyAvailability(standardBikes: 8, eBikes: 4, spaces: 0, updatedAt: Date())))
}
