//
//  WidgetDistanceIndicator.swift
//  My Boris Bikes Widget
//
//  Distance indicator component matching main app design
//

import SwiftUI

struct WidgetDistanceIndicator: View {
    let bikePoint: WidgetBikePointData
    let compact: Bool

    init(bikePoint: WidgetBikePointData, compact: Bool = false) {
        self.bikePoint = bikePoint
        self.compact = compact
    }

    private var category: WidgetDistanceCategory {
        bikePoint.distanceCategory
    }

    private var color: Color {
        let rgb = category.colorRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        if let distanceString = bikePoint.distanceString {
            HStack(spacing: compact ? 4 : 6) {
                // Visual distance indicator - horizontal bars
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        Rectangle()
                            .fill(index < category.barCount ? color : Color.gray.opacity(0.3))
                            .frame(
                                width: compact ? 3 : 4,
                                height: index < category.barCount ? (compact ? 10 : 12) - CGFloat(index) * 2 : (compact ? 6 : 8)
                            )
                            .clipShape(Capsule())
                    }
                }

                // Distance text
                Text(distanceString)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundColor(color)
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        WidgetDistanceIndicator(
            bikePoint: WidgetBikePointData(
                id: "1",
                displayName: "Test",
                actualName: "Test Dock",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 150,
                lastUpdated: Date()
            )
        )

        WidgetDistanceIndicator(
            bikePoint: WidgetBikePointData(
                id: "2",
                displayName: "Test",
                actualName: "Test Dock",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 750,
                lastUpdated: Date()
            )
        )

        WidgetDistanceIndicator(
            bikePoint: WidgetBikePointData(
                id: "3",
                displayName: "Test",
                actualName: "Test Dock",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 1500,
                lastUpdated: Date()
            ),
            compact: true
        )
    }
    .padding()
}
