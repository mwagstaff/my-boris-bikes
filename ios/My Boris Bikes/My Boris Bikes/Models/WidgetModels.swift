//
//  WidgetModels.swift
//  My Boris Bikes
//
//  Created for widget data sharing between app and widget extension
//

import Foundation
import CoreLocation

/// Represents bike point data optimized for widget display
struct WidgetBikePointData: Codable, Identifiable {
    let id: String
    let displayName: String
    let actualName: String // The real dock name (commonName)
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let distance: Double? // Distance in meters (optional)
    let lastUpdated: Date
    let isAlternative: Bool
    let parentFavoriteId: String?

    init(
        id: String,
        displayName: String,
        actualName: String,
        standardBikes: Int,
        eBikes: Int,
        emptySpaces: Int,
        distance: Double?,
        lastUpdated: Date,
        isAlternative: Bool = false,
        parentFavoriteId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.actualName = actualName
        self.standardBikes = standardBikes
        self.eBikes = eBikes
        self.emptySpaces = emptySpaces
        self.distance = distance
        self.lastUpdated = lastUpdated
        self.isAlternative = isAlternative
        self.parentFavoriteId = parentFavoriteId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case actualName
        case standardBikes
        case eBikes
        case emptySpaces
        case distance
        case lastUpdated
        case isAlternative
        case parentFavoriteId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        actualName = try container.decode(String.self, forKey: .actualName)
        standardBikes = try container.decode(Int.self, forKey: .standardBikes)
        eBikes = try container.decode(Int.self, forKey: .eBikes)
        emptySpaces = try container.decode(Int.self, forKey: .emptySpaces)
        distance = try container.decodeIfPresent(Double.self, forKey: .distance)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        isAlternative = try container.decodeIfPresent(Bool.self, forKey: .isAlternative) ?? false
        parentFavoriteId = try container.decodeIfPresent(String.self, forKey: .parentFavoriteId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(actualName, forKey: .actualName)
        try container.encode(standardBikes, forKey: .standardBikes)
        try container.encode(eBikes, forKey: .eBikes)
        try container.encode(emptySpaces, forKey: .emptySpaces)
        try container.encodeIfPresent(distance, forKey: .distance)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(isAlternative, forKey: .isAlternative)
        try container.encodeIfPresent(parentFavoriteId, forKey: .parentFavoriteId)
    }

    /// Whether this dock has an alias (displayName differs from actualName)
    var hasAlias: Bool {
        displayName != actualName
    }

    var totalBikes: Int {
        standardBikes + eBikes
    }

    var hasData: Bool {
        totalBikes + emptySpaces > 0
    }

    /// Returns initials from the display name for small widgets
    var initials: String {
        let words = displayName.split(separator: " ")
        if words.count >= 2 {
            let firstInitial = words[0].prefix(1)
            let secondInitial = words[1].prefix(1)
            return "\(firstInitial)\(secondInitial)".uppercased()
        } else if let firstWord = words.first {
            return String(firstWord.prefix(2)).uppercased()
        }
        return "??"
    }

    /// Formatted distance string for display (matches main app format)
    var distanceString: String? {
        guard let distance = distance else { return nil }

        if distance < 1000 {
            return String(format: "%.0fm", distance)
        } else {
            // Convert to miles and format to one decimal place
            let distanceInMiles = distance * 0.000621371 // Convert meters to miles
            // Display "mile" if distance is exactly 1 mile, "miles" otherwise
            if distanceInMiles == 1.0 {
                return String(format: "%.1f mile", distanceInMiles)
            } else {
                return String(format: "%.1f miles", distanceInMiles)
            }
        }
    }

    /// Distance category for visual indicator
    var distanceCategory: WidgetDistanceCategory {
        guard let distance = distance else { return .unknown }

        switch distance {
        case 0..<500:
            return .veryClose
        case 500..<1000:
            return .close
        case 1000..<1500:
            return .moderate
        case 1500..<3000:
            return .far
        default:
            return .veryFar
        }
    }
}

enum WidgetDistanceCategory: Codable {
    case veryClose
    case close
    case moderate
    case far
    case veryFar
    case unknown

    var barCount: Int {
        switch self {
        case .veryClose: return 5
        case .close: return 4
        case .moderate: return 3
        case .far: return 2
        case .veryFar: return 1
        case .unknown: return 0
        }
    }

    var colorRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .veryClose: return (0.0, 1.0, 0.0) // green
        case .close: return (0.4, 0.8, 0.8) // mint
        case .moderate: return (1.0, 0.6, 0.0) // orange
        case .far: return (0.7, 0.3, 0.9) // purple
        case .veryFar: return (1.0, 0.0, 0.0) // red
        case .unknown: return (0.5, 0.5, 0.5) // gray
        }
    }
}

/// Container for all widget data
struct WidgetData: Codable {
    let bikePoints: [WidgetBikePointData]
    let sortMode: String // "distance", "alphabetical", or "manual"
    let lastRefresh: Date

    var isEmpty: Bool {
        bikePoints.isEmpty
    }
}

/// Simple version of FavoriteBikePoint for widget use
struct WidgetFavorite: Codable, Identifiable {
    let id: String
    let name: String
    let alias: String?
    let sortOrder: Int

    var displayName: String {
        if let alias = alias, !alias.isEmpty {
            return alias
        }
        return name
    }
}
