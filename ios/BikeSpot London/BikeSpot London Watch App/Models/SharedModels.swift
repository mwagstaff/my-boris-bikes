import Foundation
import CoreLocation

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

struct WatchFavoriteJourneyDock: Codable, Hashable {
    let id: String
    let commonName: String
    var alias: String?
    let lat: Double
    let lon: Double

    var displayName: String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedAlias.isEmpty ? commonName : trimmedAlias
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct WatchFavoriteJourney: Codable, Hashable, Identifiable {
    let id: String
    var startDock: WatchFavoriteJourneyDock
    var endDock: WatchFavoriteJourneyDock

    func docksOrderedByDistance(from userLocation: CLLocation?) -> (
        start: WatchFavoriteJourneyDock,
        destination: WatchFavoriteJourneyDock
    ) {
        guard let userLocation else { return (startDock, endDock) }
        let startDistance = userLocation.distance(
            from: CLLocation(latitude: startDock.lat, longitude: startDock.lon)
        )
        let endDistance = userLocation.distance(
            from: CLLocation(latitude: endDock.lat, longitude: endDock.lon)
        )
        return endDistance < startDistance ? (endDock, startDock) : (startDock, endDock)
    }

    func closestDockDistance(from userLocation: CLLocation?) -> CLLocationDistance? {
        guard let userLocation else { return nil }
        let docks = docksOrderedByDistance(from: userLocation)
        return userLocation.distance(
            from: CLLocation(latitude: docks.start.lat, longitude: docks.start.lon)
        )
    }
}
