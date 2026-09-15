import SwiftUI

/// Rendered by the iPhone activity extension for the Watch's small supplemental family.
/// Availability and estimated progress reuse ActivityKit updates without networking or polling.
struct JourneySmartStackCard: View {
    let dockName: String
    let availability: JourneyAvailability?
    let metric: JourneyMetric
    let threshold: Int
    let phase: JourneyRun.Phase
    let progress: JourneyProgress?
    var isStale = false
    var isSimulation = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.colorSchemeContrast) private var contrast

    private var presentation: JourneySmartStackPresentation {
        JourneySmartStackPresentation(phase: phase, progress: progress)
    }

    private var stale: Bool { isStale || availability?.isStale() != false }
    private var brandColor: Color { isLuminanceReduced || contrast == .increased ? .white : .red }
    private var lastUpdated: Date? {
        guard let date = availability?.updatedAt, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(showsBrand: true)
            content(showsBrand: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .transaction { if isLuminanceReduced { $0.animation = nil } }
    }

    private func content(showsBrand: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsBrand {
                HStack(spacing: 3) {
                    Image(systemName: "bicycle").foregroundStyle(brandColor)
                    Text(isSimulation ? "BikeSpot · TEST" : "BikeSpot").fontWeight(.bold)
                    Spacer(minLength: 2)
                    Text(stageTitle).foregroundStyle(.secondary)
                }
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
            }
            if phase == .riding {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        stationName
                        HStack(spacing: 4) {
                            JourneyDonut(availability: availability, metric: .spaces, size: 26)
                            JourneyAvailabilityLabel(availability: availability, metric: .spaces, threshold: threshold,
                                                     font: .system(.caption2, weight: .bold))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    progressDonut
                }
            } else {
                HStack(spacing: 8) {
                    JourneyDonut(availability: availability, metric: metric, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        stationName
                        JourneyAvailabilityLabel(availability: availability, metric: metric, threshold: threshold,
                                                 font: .system(.caption, weight: .bold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            freshness
        }
    }

    private var stageTitle: String {
        switch presentation.stage {
        case .collection: return "Collect"
        case .riding: return "Riding"
        case .approaching: return "Arriving"
        }
    }

    private var stationName: some View {
        Text(dockName).font(.caption2).fontWeight(.semibold)
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel("\(phase == .pickup ? "Collection" : "Destination"): \(dockName)")
    }

    private var progressDonut: some View {
        let fresh = progress?.isFresh() == true
        let color: Color = fresh ? (isLuminanceReduced ? .white : .cyan) : .gray
        return VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.gray.opacity(0.35), lineWidth: 4)
                Circle().trim(from: 0, to: progress?.fractionComplete ?? 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(progress.map { "\(min(100, max(0, $0.percent)))%" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 30, height: 30).padding(2)
            HStack(spacing: 2) {
                if progress != nil && !fresh {
                    Image(systemName: "clock").font(.system(size: 7))
                }
                Text(progress?.remainingDistanceText ?? "—").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(fresh ? .white : .gray)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 42)
        .opacity(isLuminanceReduced ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated journey progress")
        .accessibilityValue(progress.map {
            "\($0.isFresh() ? "Approximately" : "Last known") \(min(100, max(0, $0.percent))) percent complete, \($0.remainingDistanceText) to destination"
        } ?? "Waiting for location")
    }

    private var freshness: some View {
        HStack(spacing: 3) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "arrow.clockwise")
            if let date = lastUpdated {
                Text(stale ? "Last update" : "Updated")
                Text(date, style: .time)
            } else {
                Text("Awaiting dock data")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(stale ? Color.orange : Color.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityLabel(stale ? "Dock availability may be out of date" : "Dock availability updated")
        .accessibilityValue(lastUpdated.map { Text($0, style: .time) } ?? Text("Waiting for data"))
    }
}

#Preview("Collect · small Watch") {
    JourneySmartStackCard(dockName: "🏠 Warwick Row", availability: .previewJourneyAvailability, metric: .eBikes,
                         threshold: 5, phase: .pickup, progress: nil)
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Collect · bikes only") {
    JourneySmartStackCard(dockName: "🏠 Home", availability: .previewJourneyAvailability, metric: .bikes,
                         threshold: 5, phase: .pickup, progress: nil)
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Collect · both bike types") {
    JourneySmartStackCard(dockName: "🏠 Home", availability: .previewJourneyAvailability, metric: .allBikes,
                         threshold: 10, phase: .pickup, progress: nil)
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Riding · miles") {
    JourneySmartStackCard(dockName: "🚉 Station", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding,
                         progress: JourneyProgress(percent: 25, remainingMeters: 1669, updatedAtEpochSeconds: Date().timeIntervalSince1970))
        .padding(8).frame(width: 176, height: 92).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Arriving · stale · larger text") {
    JourneySmartStackCard(dockName: "Allington Street, Victoria", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding,
                         progress: JourneyProgress(percent: 90, remainingMeters: 200, updatedAtEpochSeconds: Date().timeIntervalSince1970),
                         isStale: true)
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .xxxLarge)
}

#Preview("Always On") {
    JourneySmartStackCard(dockName: "🚉 Station", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding,
                         progress: JourneyProgress(percent: 25, remainingMeters: 1669, updatedAtEpochSeconds: Date().timeIntervalSince1970))
        .padding(8).frame(width: 176, height: 92).background(.black).environment(\.colorScheme, .dark)
        .environment(\.isLuminanceReduced, true)
}

#Preview("Riding · accessibility") {
    JourneySmartStackCard(dockName: "Allington Street, Victoria", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding,
                         progress: JourneyProgress(percent: 60, remainingMeters: 850, updatedAtEpochSeconds: Date().timeIntervalSince1970))
        .padding(8).frame(width: 176, height: 92).background(.black).environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Riding · stale location") {
    JourneySmartStackCard(dockName: "🚉 Station", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding,
                         progress: JourneyProgress(percent: 60, remainingMeters: 850,
                                                   updatedAtEpochSeconds: Date().addingTimeInterval(-300).timeIntervalSince1970))
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
}

#Preview("Riding · waiting for location") {
    JourneySmartStackCard(dockName: "🚉 Station", availability: .previewJourneyAvailability, metric: .spaces,
                         threshold: 5, phase: .riding, progress: nil)
        .padding(8).frame(width: 156, height: 92).background(.black).environment(\.colorScheme, .dark)
}

private extension JourneyAvailability {
    static var previewJourneyAvailability: Self {
        Self(standardBikes: 6, eBikes: 3, spaces: 4, updatedAt: Date())
    }
}
