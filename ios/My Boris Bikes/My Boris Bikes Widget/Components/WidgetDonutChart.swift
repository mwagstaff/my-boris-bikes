//
//  WidgetDonutChart.swift
//  My Boris Bikes Widget
//
//  Donut chart component optimized for widget display
//

import SwiftUI

struct WidgetDonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat
    let strokeWidth: CGFloat
    var centerText: String?

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

    // Colors matching app constants
    private let standardBikeColor = Color(red: 236/255, green: 0/255, blue: 0/255)
    private let eBikeColor = Color(red: 12/255, green: 17/255, blue: 177/255)
    private let emptySpaceColor = Color(red: 117/255, green: 117/255, blue: 117/255)

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

    private var total: Int {
        filteredCounts.standardBikes + filteredCounts.eBikes + filteredCounts.emptySpaces
    }

    private var segments: [(value: Int, color: Color, percentage: Double)] {
        guard total > 0 else { return [] }

        return [
            (filteredCounts.standardBikes, standardBikeColor, Double(filteredCounts.standardBikes) / Double(total)),
            (filteredCounts.eBikes, eBikeColor, Double(filteredCounts.eBikes) / Double(total)),
            (filteredCounts.emptySpaces, emptySpaceColor, Double(filteredCounts.emptySpaces) / Double(total))
        ].filter { $0.value > 0 }
    }

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: strokeWidth)
                .frame(width: size, height: size)

            // Segments
            if total > 0 {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    CircleSegment(
                        startAngle: startAngle(for: index),
                        endAngle: endAngle(for: index),
                        color: segment.color,
                        strokeWidth: strokeWidth
                    )
                    .frame(width: size, height: size)
                }
            }

            // Center initials
            if let centerText = centerText, !centerText.isEmpty {
                let innerDiameter = size - strokeWidth * 2
                let fontSize = innerDiameter * 0.65
                Text(centerText)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: innerDiameter * 0.8, height: innerDiameter * 0.8)
            }
        }
    }

    private func startAngle(for index: Int) -> Angle {
        let previousSegments = segments.prefix(index)
        let totalPercentage = previousSegments.reduce(0.0) { $0 + $1.percentage }
        return .degrees(-90 + (totalPercentage * 360))
    }

    private func endAngle(for index: Int) -> Angle {
        let previousSegments = segments.prefix(index + 1)
        let totalPercentage = previousSegments.reduce(0.0) { $0 + $1.percentage }
        return .degrees(-90 + (totalPercentage * 360))
    }
}

struct CircleSegment: View {
    let startAngle: Angle
    let endAngle: Angle
    let color: Color
    let strokeWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: trimStart, to: trimEnd)
            .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            .rotationEffect(.degrees(0))
    }

    private var trimStart: CGFloat {
        (startAngle.degrees + 90) / 360
    }

    private var trimEnd: CGFloat {
        (endAngle.degrees + 90) / 360
    }
}

#Preview {
    VStack(spacing: 20) {
        WidgetDonutChart(
            standardBikes: 5,
            eBikes: 3,
            emptySpaces: 12,
            size: 80,
            strokeWidth: 16
        )

        WidgetDonutChart(
            standardBikes: 8,
            eBikes: 2,
            emptySpaces: 10,
            size: 50,
            strokeWidth: 10
        )

        WidgetDonutChart(
            standardBikes: 0,
            eBikes: 0,
            emptySpaces: 20,
            size: 50,
            strokeWidth: 10
        )
    }
    .padding()
}
