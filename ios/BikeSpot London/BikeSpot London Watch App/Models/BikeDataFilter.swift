import Foundation

struct BikeAvailabilityCounts {
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int

    var totalBikes: Int {
        standardBikes + eBikes
    }

    var hasAnyBikes: Bool {
        totalBikes > 0
    }

    var hasAnyAvailability: Bool {
        totalBikes + emptySpaces > 0
    }
}

enum BikeDataFilter: String, CaseIterable, Identifiable {
    case both
    case bikesOnly
    case eBikesOnly

    static let userDefaultsKey = "bikeDataFilter"
    private static let appGroup = "group.dev.skynolimit.myborisbikes"

    static var userDefaultsStore: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both:
            return "Both"
        case .bikesOnly:
            return "Bikes"
        case .eBikesOnly:
            return "E-bikes"
        }
    }

    var showsStandardBikes: Bool {
        self != .eBikesOnly
    }

    var showsEBikes: Bool {
        self != .bikesOnly
    }

    func filteredCounts(standardBikes: Int, eBikes: Int, emptySpaces: Int) -> BikeAvailabilityCounts {
        switch self {
        case .both:
            return BikeAvailabilityCounts(
                standardBikes: standardBikes,
                eBikes: eBikes,
                emptySpaces: emptySpaces
            )
        case .bikesOnly:
            return BikeAvailabilityCounts(
                standardBikes: standardBikes,
                eBikes: 0,
                emptySpaces: emptySpaces
            )
        case .eBikesOnly:
            return BikeAvailabilityCounts(
                standardBikes: 0,
                eBikes: eBikes,
                emptySpaces: emptySpaces
            )
        }
    }
}
