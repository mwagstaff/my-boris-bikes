import SwiftUI

struct WatchDonutChart: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue
    
    private let strokeWidth: CGFloat = 6
    
    private var total: Int {
        filteredStandardBikes + filteredEBikes + filteredEmptySpaces
    }
    
    private var standardPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(filteredStandardBikes) / Double(total)
    }
    
    private var eBikePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(filteredEBikes) / Double(total)
    }
    
    private var hasData: Bool {
        total > 0
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
    
    var body: some View {
        ZStack {
            if !hasData {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: size, height: size)
                
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.gray)
                    .font(.system(size: size * 0.3))
            } else {
                // Background circle (empty spaces)
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: strokeWidth)
                    .frame(width: size, height: size)
                
                // E-bikes section (blue)
                if filteredEBikes > 0 {
                    Circle()
                        .trim(from: 0, to: eBikePercentage + standardPercentage)
                        .stroke(Color.blue, lineWidth: strokeWidth)
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                }
                
                // Standard bikes section (red)
                if filteredStandardBikes > 0 {
                    Circle()
                        .trim(from: 0, to: standardPercentage)
                        .stroke(Color.red, lineWidth: strokeWidth)
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                }
                
                // Center text showing total bikes
                Text("\(filteredCounts.totalBikes)")
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundColor(.primary)
            }
        }
    }
}

struct WatchDonutChartLegend: View {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    @AppStorage(BikeDataFilter.userDefaultsKey, store: BikeDataFilter.userDefaultsStore)
    private var bikeDataFilterRawValue: String = BikeDataFilter.both.rawValue

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

    private var bikeItems: [(color: Color, count: Int, label: String)] {
        var items: [(Color, Int, String)] = []

        if bikeDataFilter.showsStandardBikes {
            items.append((.red, filteredCounts.standardBikes, "bikes"))
        }

        if bikeDataFilter.showsEBikes {
            items.append((.blue, filteredCounts.eBikes, "e-bikes"))
        }

        return items
    }
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(bikeItems.enumerated()), id: \.offset) { _, item in
                WatchLegendItem(color: item.color, count: item.count, label: item.label)
            }
            WatchLegendItem(
                color: .gray.opacity(0.6),
                count: filteredCounts.emptySpaces,
                label: "spaces"
            )
        }
    }
}

struct WatchLegendItem: View {
    let color: Color
    let count: Int
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            
            Text("\(count)")
                .font(.caption2)
                .fontWeight(.medium)
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
