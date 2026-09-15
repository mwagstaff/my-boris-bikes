#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct JourneyDemoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyDemoAttributes.self) { context in
            JourneyDemoActivityContent(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("Test Journey · \(context.state.activeDockAlias ?? "Station")")
                }
            } compactLeading: {
                Image(systemName: "bicycle")
            } compactTrailing: {
                Text("TEST")
            } minimal: {
                Image(systemName: "bicycle")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

@available(iOS 18.0, *)
private struct JourneyDemoActivityContent: View {
    let context: ActivityViewContext<JourneyDemoAttributes>
    @Environment(\.activityFamily) private var activityFamily
    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes = AlternativeDockSettings.defaultMinBikes
    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes = AlternativeDockSettings.defaultMinEBikes
    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces = AlternativeDockSettings.defaultMinSpaces

    private func threshold(for metric: JourneyMetric) -> Int {
        switch metric {
        case .bikes: return minBikes
        case .eBikes: return minEBikes
        case .allBikes: return minBikes + minEBikes
        case .spaces: return minSpaces
        }
    }

    private var watchURL: URL? {
        var components = URLComponents(string: "myborisbikes://journey")!
        components.queryItems = [
            URLQueryItem(name: "minBikes", value: String(minBikes)),
            URLQueryItem(name: "minEBikes", value: String(minEBikes)),
            URLQueryItem(name: "minSpaces", value: String(minSpaces))
        ]
        if let item = context.state.journeyActivityContext?.queryItem { components.queryItems?.append(item) }
        return components.url
    }

    var body: some View {
        let state = context.state
        let metric = JourneyMetric(rawValue: state.primaryDisplay ?? "eBikes") ?? .eBikes
        let availability = JourneyAvailability(standardBikes: state.standardBikes, eBikes: state.eBikes, spaces: state.emptySpaces,
                                               updatedAt: Date(timeIntervalSince1970: Double(state.availabilityUpdatedAtEpochSeconds ?? 0)))
        Group {
            if activityFamily == .small {
                JourneySmartStackCard(dockName: state.activeDockAlias ?? state.activeDockName ?? "Journey",
                    availability: availability, metric: metric, threshold: threshold(for: metric),
                    phase: state.activeJourneyPhase == "end" ? .riding : .pickup,
                    progress: state.journeyProgress,
                    isStale: context.isStale, isSimulation: true)
            } else {
                JourneyActivityCard(dockName: state.activeDockAlias ?? state.activeDockName ?? "Journey",
                                    availability: availability, metric: metric, threshold: threshold(for: metric),
                                    progress: state.journeyProgress, isSimulation: true, isStale: context.isStale,
                                    compact: activityFamily == .small)
            }
        }
        .padding(activityFamily == .small ? 8 : 16)
        .activityBackgroundTint(.black)
        .foregroundStyle(.white)
        .widgetURL(watchURL)
    }
}
#endif
