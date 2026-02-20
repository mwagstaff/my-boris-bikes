//
//  LiveActivityModels.swift
//  My Boris Bikes
//
//  Shared between the main app and widget extension for Live Activity support
//

import ActivityKit
import Foundation

struct DockActivityAttributes: ActivityAttributes {
    /// Fixed properties set at activity creation
    let dockId: String
    let dockName: String
    let alias: String?

    struct ContentState: Codable, Hashable {
        /// Dynamic properties updated via push notification
        let standardBikes: Int
        let eBikes: Int
        let emptySpaces: Int
        /// Nearby favourite docks shown inline on the watch Smart Stack card
        var alternatives: [AlternativeDock]

        init(standardBikes: Int, eBikes: Int, emptySpaces: Int, alternatives: [AlternativeDock] = []) {
            self.standardBikes = standardBikes
            self.eBikes = eBikes
            self.emptySpaces = emptySpaces
            self.alternatives = alternatives
        }

        // Custom decoding so push payloads that omit `alternatives` still decode successfully
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            standardBikes = try container.decode(Int.self, forKey: .standardBikes)
            eBikes = try container.decode(Int.self, forKey: .eBikes)
            emptySpaces = try container.decode(Int.self, forKey: .emptySpaces)
            alternatives = try container.decodeIfPresent([AlternativeDock].self, forKey: .alternatives) ?? []
        }
    }

    /// Compact representation of a nearby alternative dock for the watch Smart Stack
    struct AlternativeDock: Codable, Hashable {
        let name: String
        let standardBikes: Int
        let eBikes: Int
        let emptySpaces: Int
    }
}
