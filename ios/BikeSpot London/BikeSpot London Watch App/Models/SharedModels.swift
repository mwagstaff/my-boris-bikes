import Foundation

// MARK: - Widget Data Models

/// Shared widget bike point structure used by both watch app and widget extension
struct WidgetBikePoint: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let standardBikes: Int
    let eBikes: Int
    let emptySpaces: Int
    let distance: Double? // Distance in meters
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return commonName
    }
    
    var totalBikes: Int {
        standardBikes + eBikes
    }
    
    var hasData: Bool {
        standardBikes + eBikes + emptySpaces > 0
    }
}

/// Helper struct for decoding favorites from UserDefaults
struct FavoriteBikePoint: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let sortOrder: Int
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return commonName
    }
}
