import SwiftUI

struct SimplifiedDonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue
    
    private let strokeWidth: CGFloat = 7
    private let borderWidth: CGFloat = 2
    private let minimumVisibleSegment: Double = 0.08
    private var circleSize: CGFloat {
        // Reduce the circle size to account for stroke width
        max(size - strokeWidth, size * 0.8)
    }
    
    private var outerCircleSize: CGFloat {
        circleSize + strokeWidth
    }
    
    private var total: Int {
        filteredStandardBikes + filteredEBikes + filteredEmptySpaces
    }
    
    private var hasData: Bool {
        total > 0
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
    
    private var adjustedSegments: (standard: Double, eBike: Double, empty: Double) {
        var empty = rawEmptySpacePercentage
        var standard = rawStandardPercentage
        var eBike = rawEBikePercentage
        
        standard = adjustedSegment(for: standard, empty: &empty)
        eBike = adjustedSegment(for: eBike, empty: &empty)
        
        let clampedEmpty = max(0, empty)
        return (standard, eBike, clampedEmpty)
    }
    
    private var standardPercentage: Double { adjustedSegments.standard }
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
            (standardPercentage, AppConstants.Colors.standardBike, lineCap(for: standardPercentage, preferred: .round)),
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
            if !hasData {
                // Simple gray circle for unavailable/no data
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: circleSize, height: circleSize)
            } else {
                Circle()
                    .fill(Color.white)
                    .frame(width: circleSize, height: circleSize)
                
                // Thin outer border to separate from map colors
                Circle()
                    .stroke(Color.white, lineWidth: borderWidth)
                    .frame(width: outerCircleSize, height: outerCircleSize)
                
                ForEach(Array(ringSegments.enumerated()), id: \.offset) { _, segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: segment.cap))
                        .rotationEffect(.degrees(-90))
                        .frame(width: circleSize, height: circleSize)
                }
                
                // Center indicator showing total bikes
                Text("\(filteredCounts.totalBikes)")
                    .font(.system(size: circleSize * 0.32, weight: .bold))
                    .foregroundColor(.black)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 20) {
        SimplifiedDonutChart(standardBikes: 5, eBikes: 3, emptySpaces: 12, size: 24)
        SimplifiedDonutChart(standardBikes: 0, eBikes: 0, emptySpaces: 0, size: 24)
        SimplifiedDonutChart(standardBikes: 2, eBikes: 0, emptySpaces: 8, size: 24)
    }
    .padding()
}
