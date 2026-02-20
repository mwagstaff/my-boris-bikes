import Foundation
import CoreLocation

struct BikePoint: Codable, Identifiable, Equatable {
    let id: String
    let commonName: String
    let url: String
    let lat: Double
    let lon: Double
    let additionalProperties: [AdditionalProperty]

    private enum CodingKeys: String, CodingKey {
        case id
        case commonName
        case url
        case lat
        case lon
        case additionalProperties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        commonName = try container.decodeIfPresent(String.self, forKey: .commonName) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        lat = try container.decodeIfPresent(Double.self, forKey: .lat) ?? 0
        lon = try container.decodeIfPresent(Double.self, forKey: .lon) ?? 0
        additionalProperties = try container.decodeIfPresent([AdditionalProperty].self, forKey: .additionalProperties) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(commonName, forKey: .commonName)
        try container.encode(url, forKey: .url)
        try container.encode(lat, forKey: .lat)
        try container.encode(lon, forKey: .lon)
        try container.encode(additionalProperties, forKey: .additionalProperties)
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    
    var isInstalled: Bool {
        additionalProperties.first { $0.key == "Installed" }?.value == "true"
    }
    
    var isLocked: Bool {
        additionalProperties.first { $0.key == "Locked" }?.value == "true"
    }
    
    var totalDocks: Int {
        Int(additionalProperties.first { $0.key == "NbDocks" }?.value ?? "0") ?? 0
    }
    
    /// Raw number of empty docks from API
    private var rawEmptyDocks: Int {
        Int(additionalProperties.first { $0.key == "NbEmptyDocks" }?.value ?? "0") ?? 0
    }
    
    var standardBikes: Int {
        Int(additionalProperties.first { $0.key == "NbStandardBikes" }?.value ?? "0") ?? 0
    }
    
    var eBikes: Int {
        Int(additionalProperties.first { $0.key == "NbEBikes" }?.value ?? "0") ?? 0
    }
    
    var totalBikes: Int {
        standardBikes + eBikes
    }
    
    /// Number of broken docks calculated from API data
    /// Formula: nbDocks - (nbBikes + nbSpaces) != 0 indicates broken docks
    var brokenDocks: Int {
        let calculatedBrokenDocks = totalDocks - (totalBikes + rawEmptyDocks)
        let brokenCount = max(0, calculatedBrokenDocks)
        
        if brokenCount > 0 {
        }
        
        return brokenCount
    }
    
    /// Adjusted number of empty docks, accounting for broken docks
    /// This is the number of spaces actually available to users
    var emptyDocks: Int {
        // If there are broken docks, we should not show them as available spaces
        // The raw empty docks should already exclude broken ones, but we verify the calculation
        let expectedTotal = totalBikes + rawEmptyDocks + brokenDocks
        
        if expectedTotal == totalDocks {
            // Data is consistent, return raw empty docks
            return rawEmptyDocks
        } else {
            // Data inconsistency detected, calculate adjusted empty docks
            let adjustedEmpty = totalDocks - totalBikes - brokenDocks
            return max(0, adjustedEmpty)
        }
    }
    
    var isAvailable: Bool {
        isInstalled && !isLocked
    }
    
    /// Indicates whether this dock has any broken docks
    var hasBrokenDocks: Bool {
        brokenDocks > 0
    }
}

struct AdditionalProperty: Codable, Equatable {
    let key: String
    let value: String

    private enum CodingKeys: String, CodingKey {
        case key
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)

        if let stringValue = try? container.decode(String.self, forKey: .value) {
            value = stringValue
            return
        }
        if let intValue = try? container.decode(Int.self, forKey: .value) {
            value = String(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self, forKey: .value) {
            value = String(doubleValue)
            return
        }
        if let boolValue = try? container.decode(Bool.self, forKey: .value) {
            value = boolValue ? "true" : "false"
            return
        }

        value = ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
    }
}
