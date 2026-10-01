import SwiftUI

struct SimplifiedDonutChart: View {
    enum DisplayMode {
        case all
        case bikes
        case spaces
    }

    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let size: CGFloat
    var displayMode: DisplayMode = .all
    let bikeDataFilter: BikeDataFilter
    var hasAvailability = true

    var body: some View {
        DockAvailabilityRing(
            standardBikes: standardBikes, eBikes: eBikes, emptySpaces: emptySpaces,
            size: size, strokeWidth: max(3, size * 0.12), bikeDataFilter: bikeDataFilter,
            showsSpaces: displayMode == .spaces, hasAvailability: hasAvailability
        )
    }
}

#Preview {
    HStack(spacing: 20) {
        SimplifiedDonutChart(standardBikes: 3, eBikes: 2, emptySpaces: 19, size: 72, bikeDataFilter: .both)
        SimplifiedDonutChart(standardBikes: 3, eBikes: 2, emptySpaces: 19, size: 72, displayMode: .spaces, bikeDataFilter: .both)
    }
    .padding().bikeSpotBackground()
}
