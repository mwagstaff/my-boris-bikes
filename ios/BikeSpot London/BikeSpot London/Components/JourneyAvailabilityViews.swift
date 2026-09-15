import SwiftUI

struct JourneyDonut: View {
    let availability: JourneyAvailability?
    let metric: JourneyMetric
    var identifier: String? = nil
    var size: CGFloat = 42
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var chartAvailability: JourneyAvailability? { availability?.filtered(for: metric) }
    private var total: Double { Double(max(1, chartAvailability?.total ?? 0)) }
    private var standard: Double { Double(chartAvailability?.standardBikes ?? 0) / total }
    private var electric: Double { Double(chartAvailability?.eBikes ?? 0) / total }
    private var lineWidth: CGFloat { max(4, size * 0.105) }

    var body: some View {
        ZStack {
            Circle().stroke(.gray.opacity(0.4), lineWidth: lineWidth)
            if let chartAvailability, chartAvailability.total > 0 {
                Circle().trim(from: 0, to: standard + electric)
                    .stroke(Color(red: 12 / 255, green: 17 / 255, blue: 177 / 255), lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
                Circle().trim(from: 0, to: standard)
                    .stroke(Color(red: 236 / 255, green: 0, blue: 0), lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                if let identifier, !identifier.isEmpty {
                    Text(identifier).font(.system(size: size * 0.23, weight: .semibold))
                }
                Text(availability.map { String(metric.count(in: $0)) } ?? "—")
                    .font(.system(size: size * (identifier == nil ? 0.44 : 0.32), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth)
            }
        }
        .frame(width: size, height: size)
        .padding(lineWidth / 2)
        .opacity(isLuminanceReduced ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(availability.map { "\(metric.count(in: $0)) \(metric.label(count: metric.count(in: $0)))" }
                            ?? "Availability unavailable")
    }
}

struct JourneyAvailabilityLabel: View {
    let availability: JourneyAvailability?
    let metric: JourneyMetric
    let threshold: Int
    var font: Font = .system(.caption2, weight: .semibold)
    var isLowAvailability: Bool? = nil

    var body: some View {
        if let availability {
            let count = metric.count(in: availability)
            let isLow = isLowAvailability ?? (count < threshold)
            let color: Color = count == 0 ? .red : isLow ? .orange : .green
            Text("\(count) \(metric.label(count: count))")
                .font(font)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("\(count) \(metric.label(count: count)), \(count == 0 ? "none available" : isLow ? "low availability" : "available")")
        } else {
            Text("Unavailable").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct JourneyProgressBar: View {
    let progress: JourneyProgress?

    var body: some View {
        ProgressView(value: progress?.fractionComplete ?? 0)
            .progressViewStyle(JourneyLinearProgressStyle(color: progress?.isFresh() == true ? .cyan : .gray))
            .labelsHidden()
            .frame(maxWidth: .infinity).frame(height: 10)
            .accessibilityLabel("Journey progress")
            .accessibilityValue(progress.map {
                "\($0.isFresh() ? "Approximately" : "Last known") \(Int($0.fractionComplete * 100)) percent complete"
            } ?? "Waiting for location")
    }
}

private struct JourneyLinearProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.gray.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }.frame(height: 6)
    }
}

struct JourneyActivityCard: View {
    let dockName: String
    let availability: JourneyAvailability?
    let metric: JourneyMetric
    let threshold: Int
    let progress: JourneyProgress?
    var isSimulation = false
    var isStale = false
    var compact = true

    var body: some View {
        HStack(spacing: compact ? 8 : 18) {
            JourneyDonut(availability: availability, metric: metric, size: compact ? 40 : 80)
            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                Text(isSimulation ? "TEST · \(dockName)" : dockName)
                    .font(compact ? .system(.caption, weight: .semibold) : .title3.weight(.semibold))
                    .lineLimit(compact ? 1 : 2).minimumScaleFactor(0.8)
                JourneyAvailabilityLabel(availability: availability, metric: metric, threshold: threshold,
                    font: compact ? .system(.caption2, weight: .semibold) : .title2.weight(.semibold))
                if metric == .spaces { JourneyProgressBar(progress: progress) }
                if isStale { Text("Last known").font(.caption2).foregroundStyle(.orange) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Watch app's riding page uses the available display, independently of the Smart Stack card.
struct JourneyRideDashboard: View {
    let dockName: String
    let availability: JourneyAvailability?
    let threshold: Int
    let progress: JourneyProgress?
    var isSimulation = false

    var body: some View {
        GeometryReader { geometry in
            let chartSize = max(56, min(geometry.size.width * 0.8, (geometry.size.height - 78) / 1.105))
            ViewThatFits(in: .vertical) {
                content(chartSize: chartSize)
                ScrollView { content(chartSize: chartSize) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(chartSize: CGFloat) -> some View {
        VStack(spacing: 6) {
            Text(isSimulation ? "TEST · \(dockName)" : dockName)
                .font(.headline).multilineTextAlignment(.center).lineLimit(2)
            JourneyDonut(availability: availability, metric: .spaces, size: chartSize)
            JourneyAvailabilityLabel(availability: availability, metric: .spaces, threshold: threshold,
                                     font: .headline)
            JourneyProgressBar(progress: progress).padding(.horizontal, 8)
            if availability?.isStale() == true {
                Text("Last known availability").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

#if DEBUG
struct JourneyTestControls: View {
    @Binding var settings: JourneyTestSettings

    var body: some View {
        Section("Journey") {
            Picker("Stage", selection: $settings.phase) {
                Text("Next scheduled journey").tag("upcoming")
                Text("Collecting a bike").tag("pickup")
                Text("Cycling").tag("riding")
                Text("Arrived · 100%").tag("arrived")
                Text("Finished · next journey").tag("finished")
                Text("No journey · favourite").tag("fallback")
                Text("No favourites · nearest").tag("noFavorites")
            }
            if settings.phase == "riding" {
                Text("Position: \(Int(settings.progress))% along direct line")
                    .font(.caption)
                Slider(value: $settings.progress, in: 0...100, step: 5)
                    .accessibilityLabel("Simulated position")
            }
        }
        Section("Availability") {
            Picker("Bike preference", selection: $settings.metric) {
                Text("Bikes").tag(JourneyMetric.bikes)
                Text("E-bikes").tag(JourneyMetric.eBikes)
                Text("Both").tag(JourneyMetric.allBikes)
            }
            Stepper("Bikes: \(settings.bikes)", value: $settings.bikes, in: 0...40)
            Stepper("E-bikes: \(settings.eBikes)", value: $settings.eBikes, in: 0...40)
            Stepper("Spaces: \(settings.spaces)", value: $settings.spaces, in: 0...40)
            Toggle("Stale availability", isOn: $settings.stale)
        }
    }
}
#endif
