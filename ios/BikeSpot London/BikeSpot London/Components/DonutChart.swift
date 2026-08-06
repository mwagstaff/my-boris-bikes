import SwiftUI

struct DonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat
    let strokeWidth: CGFloat

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue
    
    @State private var animationAmount: Double = 0
    private let borderWidth: CGFloat = 2
    private let minimumVisibleSegment: Double = 0.12
    
    init(standardBikes: Int, eBikes: Int, emptySpaces: Int, size: CGFloat = 60, strokeWidth: CGFloat = 14) {
        self.standardBikes = standardBikes
        self.eBikes = eBikes
        self.emptySpaces = emptySpaces
        self.size = size
        self.strokeWidth = strokeWidth
    }
    
    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: standardBikes,
            eBikes: eBikes,
            emptySpaces: emptySpaces
        )
    }

    private var filteredStandardBikes: Int { filteredCounts.standardBikes }
    private var filteredEBikes: Int { filteredCounts.eBikes }
    private var filteredEmptySpaces: Int { filteredCounts.emptySpaces }

    // Create a unique identifier for this configuration to help SwiftUI track changes
    private var chartId: String {
        "\(filteredStandardBikes)-\(filteredEBikes)-\(filteredEmptySpaces)-\(bikeDataFilterRawValue)"
    }
    
    private var total: Int {
        filteredStandardBikes + filteredEBikes + filteredEmptySpaces
    }
    
    private var rawStandardPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(filteredStandardBikes) / Double(total)
    }
    
    private var rawEBikePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(filteredEBikes) / Double(total)
    }
    
    private var rawEmptySpacePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(filteredEmptySpaces) / Double(total)
    }
    
    private var adjustedSegments: (standard: Double, eBike: Double, empty: Double) {
        var empty = rawEmptySpacePercentage
        var standard = rawStandardPercentage
        var eBike = rawEBikePercentage
        
        standard = adjustedSegment(for: standard, empty: &empty)
        eBike = adjustedSegment(for: eBike, empty: &empty)
        
        let clampedEmpty = max(0, empty)
        return (standard, eBike, clampedEmpty)
    }
    
    private var standardBikePercentage: Double { adjustedSegments.standard }
    private var eBikePercentage: Double { adjustedSegments.eBike }
    private var emptySpacePercentage: Double { adjustedSegments.empty }
    private var emptyLineCap: CGLineCap {
        lineCap(for: emptySpacePercentage, preferred: .round)
    }
    
    private var ringSegments: [(start: Double, end: Double, color: Color, cap: CGLineCap)] {
        var segments: [(Double, Double, Color, CGLineCap)] = []
        var currentStart: Double = 0
        
        let components: [(amount: Double, color: Color, cap: CGLineCap)] = [
            (eBikePercentage, AppConstants.Colors.eBike, lineCap(for: eBikePercentage, preferred: .round)),
            (standardBikePercentage, AppConstants.Colors.standardBike, lineCap(for: standardBikePercentage, preferred: .round)),
            (emptySpacePercentage, AppConstants.Colors.emptySpace.opacity(0.95), emptyLineCap)
        ]
        
        for component in components where component.amount > 0 {
            let end = min(1, currentStart + component.amount)
            segments.append((currentStart, end, component.color, component.cap))
            currentStart = end
        }
        
        return segments
    }
    
    private func adjustedSegment(for value: Double, empty: inout Double) -> Double {
        guard value > 0 else { return 0 }
        guard value < minimumVisibleSegment, empty > 0 else { return value }
        
        let delta = min(minimumVisibleSegment - value, empty)
        empty -= delta
        return value + delta
    }
    
    private func lineCap(for amount: Double, preferred: CGLineCap) -> CGLineCap {
        amount < minimumVisibleSegment + 0.02 ? .butt : preferred
    }
    var body: some View {
        ZStack {
            if total == 0 {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: strokeWidth)
                    .frame(width: size, height: size)
                
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.gray)
                    .font(.system(size: size * 0.3))
            } else {
                Circle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
                
                Circle()
                    .stroke(Color.white, lineWidth: borderWidth)
                    .frame(width: size + strokeWidth, height: size + strokeWidth)
                
                ForEach(Array(ringSegments.enumerated()), id: \.offset) { _, segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: segment.cap))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                        .animation(.easeInOut(duration: 0.6), value: animationAmount)
                }
                
                // Center text with total bikes
                Text("\(filteredCounts.totalBikes)")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundColor(.black)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: filteredCounts.totalBikes)
            }
        }
        .id(chartId) // Force SwiftUI to recognize this as a new view when data changes
        .onAppear {
            // Trigger animation when the chart appears
            withAnimation(.easeInOut(duration: 0.8)) {
                animationAmount = 1.0
            }
        }
        .onChange(of: chartId) { _, _ in
            // Reset and re-animate when data changes
            animationAmount = 0
            withAnimation(.easeInOut(duration: 0.6)) {
                animationAmount = 1.0
            }
        }
    }
}

struct DonutChartLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let showLabels: Bool
    let spacesOnSecondLine: Bool
    let useStatusColors: Bool

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    @AppStorage(AlternativeDockSettings.minSpacesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minSpaces: Int = AlternativeDockSettings.defaultMinSpaces

    @AppStorage(AlternativeDockSettings.minBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minBikes: Int = AlternativeDockSettings.defaultMinBikes

    @AppStorage(AlternativeDockSettings.minEBikesKey, store: AlternativeDockSettings.userDefaultsStore)
    private var minEBikes: Int = AlternativeDockSettings.defaultMinEBikes
    
    init(
        standardBikes: Int,
        eBikes: Int,
        emptySpaces: Int,
        showLabels: Bool = true,
        spacesOnSecondLine: Bool = false,
        useStatusColors: Bool = false
    ) {
        self.standardBikes = standardBikes
        self.eBikes = eBikes
        self.emptySpaces = emptySpaces
        self.showLabels = showLabels
        self.spacesOnSecondLine = spacesOnSecondLine
        self.useStatusColors = useStatusColors
    }

    private var bikeDataFilter: BikeDataFilter {
        BikeDataFilter(rawValue: bikeDataFilterRawValue) ?? .both
    }

    private var filteredCounts: BikeAvailabilityCounts {
        bikeDataFilter.filteredCounts(
            standardBikes: standardBikes,
            eBikes: eBikes,
            emptySpaces: emptySpaces
        )
    }

    private var bikeItems: [(color: Color, count: Int, label: String?, threshold: Int)] {
        var items: [(Color, Int, String?, Int)] = []

        if bikeDataFilter.showsStandardBikes {
            let label = showLabels ? (filteredCounts.standardBikes == 1 ? "bike" : "bikes") : nil
            items.append((AppConstants.Colors.standardBike, filteredCounts.standardBikes, label, minBikes))
        }

        if bikeDataFilter.showsEBikes {
            let label = showLabels ? (filteredCounts.eBikes == 1 ? "e-bike" : "e-bikes") : nil
            items.append((AppConstants.Colors.eBike, filteredCounts.eBikes, label, minEBikes))
        }

        return items
    }

    private var spaceItem: (color: Color, count: Int, label: String?, threshold: Int) {
        let label = showLabels ? (filteredCounts.emptySpaces == 1 ? "space" : "spaces") : nil
        return (AppConstants.Colors.emptySpace, filteredCounts.emptySpaces, label, minSpaces)
    }
    
    // Create a unique identifier to help SwiftUI track changes
    private var legendId: String {
        "\(filteredCounts.standardBikes)-\(filteredCounts.eBikes)-\(filteredCounts.emptySpaces)-\(showLabels)-\(spacesOnSecondLine)-\(bikeDataFilterRawValue)"
    }
    
    var body: some View {
        Group {
            if spacesOnSecondLine {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) {
                        ForEach(Array(bikeItems.enumerated()), id: \.offset) { _, item in
                            LegendItem(
                                color: item.color,
                                count: item.count,
                                label: item.label,
                                threshold: item.threshold,
                                useStatusColors: useStatusColors
                            )
                        }
                    }
                    
                    LegendItem(
                        color: spaceItem.color,
                        count: spaceItem.count,
                        label: spaceItem.label,
                        threshold: spaceItem.threshold,
                        useStatusColors: useStatusColors
                    )
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(bikeItems.enumerated()), id: \.offset) { _, item in
                        LegendItem(
                            color: item.color,
                            count: item.count,
                            label: item.label,
                            threshold: item.threshold,
                            useStatusColors: useStatusColors
                        )
                    }

                    LegendItem(
                        color: spaceItem.color,
                        count: spaceItem.count,
                        label: spaceItem.label,
                        threshold: spaceItem.threshold,
                        useStatusColors: useStatusColors
                    )
                }
            }
        }
        .id(legendId) // Help SwiftUI track changes
    }
}

struct LegendItem: View {
    let color: Color
    let count: Int
    let label: String?
    let threshold: Int
    let useStatusColors: Bool

    private var countColor: Color {
        guard useStatusColors else { return .primary }
        if count == 0 {
            return .red
        }
        if count >= threshold {
            return .green
        }
        return .orange
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color) 
                .frame(width: 8, height: 8)
            
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(countColor)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: count)
            
            if let label = label {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(useStatusColors ? countColor : .secondary)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        DonutChart(standardBikes: 5, eBikes: 3, emptySpaces: 12)
        
        DonutChartLegend(standardBikes: 5, eBikes: 3, emptySpaces: 12)
        
        DonutChart(standardBikes: 0, eBikes: 0, emptySpaces: 0)
    }
    .padding()
}
