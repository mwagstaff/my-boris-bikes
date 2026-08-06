import Foundation

struct FavoriteBikePoint: Codable, Identifiable {
    let id: String
    let name: String
    var alias: String?
    var sortOrder: Int
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return name
    }
    
    init(bikePoint: BikePoint, sortOrder: Int = 0, alias: String? = nil) {
        self.id = bikePoint.id
        self.name = bikePoint.commonName
        self.alias = alias
        self.sortOrder = sortOrder
    }
}

enum SortMode: String, CaseIterable {
    case distance = "distance"
    case alphabetical = "alphabetical"

    var displayName: String {
        switch self {
        case .distance: return "Distance"
        case .alphabetical: return "Alphabetical"
        }
    }
}
