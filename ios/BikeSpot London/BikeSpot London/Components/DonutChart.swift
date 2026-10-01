import SwiftUI

struct DonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    var size: CGFloat = 72
    var strokeWidth: CGFloat = 9
    var hasAvailability = true

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue = BikeDataFilter.both.rawValue

    var body: some View {
        DockAvailabilityRing(
            standardBikes: standardBikes, eBikes: eBikes, emptySpaces: emptySpaces,
            size: size, strokeWidth: strokeWidth,
            bikeDataFilter: BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both,
            hasAvailability: hasAvailability
        )
    }
}

/// A consistent ring for dock cards and compact map annotations.
/// The neutral bike-ring segment represents empty spaces, not hidden bike types.
struct DockAvailabilityRing: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat
    let strokeWidth: CGFloat
    let bikeDataFilter: BikeDataFilter
    var showsSpaces = false
    var hasAvailability = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var counts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(standardBikes: max(0, standardBikes),
                                      eBikes: max(0, eBikes), emptySpaces: max(0, emptySpaces))
    }
    private var capacity: Int {
        showsSpaces
            ? max(0, standardBikes) + max(0, eBikes) + counts.emptySpaces
            : counts.totalBikes + counts.emptySpaces
    }
    private var count: Int { showsSpaces ? counts.emptySpaces : counts.totalBikes }
    private var hasData: Bool { hasAvailability }
    private var unit: String { showsSpaces ? "spaces" : bikeDataFilter == .eBikesOnly ? "e-bikes" : "bikes" }
    private var standardFraction: Double { Double(counts.standardBikes) / Double(max(1, capacity)) }
    private var bikeFraction: Double { Double(counts.totalBikes) / Double(max(1, capacity)) }

    var body: some View {
        ZStack {
            Circle().fill(BikeSpotStyle.surface)
            Circle().stroke(Color(.systemGray4).opacity(0.65), lineWidth: strokeWidth)
            if hasData {
                if counts.emptySpaces == 0 {
                    // A full dock is a complete red ring in every display/filter mode.
                    Circle().stroke(Color("AvailabilityEmpty"), lineWidth: strokeWidth)
                } else if showsSpaces {
                    Circle().trim(from: 0, to: Double(counts.emptySpaces) / Double(max(1, capacity)))
                        .stroke(Color("AvailabilityGood"), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle().trim(from: 0, to: standardFraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                    Circle().trim(from: standardFraction, to: bikeFraction)
                        .stroke(Color.indigo, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 1) {
                Text(hasData ? String(count) : "—")
                    .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if size >= 64 {
                    Text(unit)
                        .font(.system(size: size * 0.14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(strokeWidth / 2)
        .frame(width: size, height: size)
        .animation(reduceMotion || size < 64 ? nil : .easeInOut(duration: 0.25), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasData ? "\(count) \(unit) available" : "Availability unavailable")
    }
}

struct DonutChartLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue = BikeDataFilter.both.rawValue
    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces = AlternativeDockSettings.defaultMinSpaces
    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes = AlternativeDockSettings.defaultMinBikes
    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes = AlternativeDockSettings.defaultMinEBikes

    private var filter: BikeDataFilter { BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both }

    var body: some View {
        AvailabilityPillLayout {
            if filter.showsStandardBikes {
                AvailabilityPill(count: standardBikes, label: standardBikes == 1 ? "bike" : "bikes",
                                 symbol: "bicycle", threshold: minBikes)
            }
            if filter.showsEBikes {
                AvailabilityPill(count: eBikes, label: eBikes == 1 ? "e-bike" : "e-bikes",
                                 symbol: "bolt.fill", threshold: minEBikes)
            }
            AvailabilityPill(count: emptySpaces, label: emptySpaces == 1 ? "space" : "spaces",
                             symbol: "parkingsign.circle", threshold: minSpaces)
        }
    }
}

#Preview("Dock rings") {
    VStack(spacing: 24) {
        DonutChart(standardBikes: 3, eBikes: 2, emptySpaces: 19)
        DonutChartLegend(standardBikes: 3, eBikes: 2, emptySpaces: 19)
        DonutChart(standardBikes: 0, eBikes: 0, emptySpaces: 19)
        DonutChart(standardBikes: 0, eBikes: 0, emptySpaces: 0, hasAvailability: false)
    }
    .padding().bikeSpotBackground()
}

#Preview("Full docks · All bike filters") {
    VStack(spacing: 20) {
        ForEach(BikeDataFilter.allCases) { filter in
            HStack {
                Text(filter.title).frame(width: 70, alignment: .leading)
                DockAvailabilityRing(standardBikes: 15, eBikes: 2, emptySpaces: 0,
                    size: 60, strokeWidth: 7, bikeDataFilter: filter)
                DockAvailabilityRing(standardBikes: 15, eBikes: 2, emptySpaces: 0,
                    size: 60, strokeWidth: 7, bikeDataFilter: filter, showsSpaces: true)
                DockAvailabilityRing(standardBikes: 0, eBikes: 0, emptySpaces: 0,
                    size: 60, strokeWidth: 7, bikeDataFilter: filter, hasAvailability: false)
            }
        }
    }
    .padding().bikeSpotBackground()
}
