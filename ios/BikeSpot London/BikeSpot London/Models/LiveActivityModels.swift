//
//  LiveActivityModels.swift
//  BikeSpot London
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
    let scheduledJourneyId: String?
    let scheduledJourneyPhase: String?
    let adHocJourneyId: String?
    let latitude: Double?
    let longitude: Double?
    let destinationDockId: String?
    let destinationDockName: String?
    let destinationLatitude: Double?
    let destinationLongitude: Double?

    init(
        dockId: String,
        dockName: String,
        alias: String?,
        scheduledJourneyId: String? = nil,
        scheduledJourneyPhase: String? = nil,
        adHocJourneyId: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        destinationDockId: String? = nil,
        destinationDockName: String? = nil,
        destinationLatitude: Double? = nil,
        destinationLongitude: Double? = nil
    ) {
        self.dockId = dockId
        self.dockName = dockName
        self.alias = alias?.liveActivityDisplayText
        self.scheduledJourneyId = scheduledJourneyId
        self.scheduledJourneyPhase = scheduledJourneyPhase
        self.adHocJourneyId = adHocJourneyId
        self.latitude = latitude
        self.longitude = longitude
        self.destinationDockId = destinationDockId
        self.destinationDockName = destinationDockName
        self.destinationLatitude = destinationLatitude
        self.destinationLongitude = destinationLongitude
    }

    struct ContentState: Codable, Hashable {
        /// Dynamic properties updated via push notification
        let standardBikes: Int
        let eBikes: Int
        let emptySpaces: Int
        /// Nearby favourite docks shown inline on the watch Smart Stack card
        var alternatives: [AlternativeDock]
        /// Mutable dock identity for journey Live Activities. Regular dock activities leave these nil.
        let activeDockId: String?
        let activeDockName: String?
        let activeDockAlias: String?
        let activeJourneyPhase: String?
        let primaryDisplay: String?
        /// Unix timestamp for the availability snapshot shown in this content state.
        /// Older server payloads omit it, so it remains optional for compatibility.
        let availabilityUpdatedAtEpochSeconds: Int?

        init(
            standardBikes: Int,
            eBikes: Int,
            emptySpaces: Int,
            alternatives: [AlternativeDock] = [],
            activeDockId: String? = nil,
            activeDockName: String? = nil,
            activeDockAlias: String? = nil,
            activeJourneyPhase: String? = nil,
            primaryDisplay: String? = nil,
            availabilityUpdatedAtEpochSeconds: Int? = nil
        ) {
            self.standardBikes = standardBikes
            self.eBikes = eBikes
            self.emptySpaces = emptySpaces
            self.alternatives = alternatives
            self.activeDockId = activeDockId
            self.activeDockName = activeDockName
            self.activeDockAlias = activeDockAlias?.liveActivityDisplayText
            self.activeJourneyPhase = activeJourneyPhase
            self.primaryDisplay = primaryDisplay
            self.availabilityUpdatedAtEpochSeconds = availabilityUpdatedAtEpochSeconds
        }

        // Custom decoding so push payloads that omit `alternatives` still decode successfully
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            standardBikes = try container.decode(Int.self, forKey: .standardBikes)
            eBikes = try container.decode(Int.self, forKey: .eBikes)
            emptySpaces = try container.decode(Int.self, forKey: .emptySpaces)
            alternatives = try container.decodeIfPresent([AlternativeDock].self, forKey: .alternatives) ?? []
            activeDockId = try container.decodeIfPresent(String.self, forKey: .activeDockId)
            activeDockName = try container.decodeIfPresent(String.self, forKey: .activeDockName)
            activeDockAlias = try container.decodeIfPresent(String.self, forKey: .activeDockAlias)?.liveActivityDisplayText
            activeJourneyPhase = try container.decodeIfPresent(String.self, forKey: .activeJourneyPhase)
            primaryDisplay = try container.decodeIfPresent(String.self, forKey: .primaryDisplay)
            availabilityUpdatedAtEpochSeconds = try container.decodeIfPresent(
                Int.self,
                forKey: .availabilityUpdatedAtEpochSeconds
            )
        }

        var resolvedDockId: String? {
            activeDockId?.nilIfBlank
        }

        var resolvedDockName: String? {
            activeDockName?.nilIfBlank
        }

        var resolvedAlias: String? {
            activeDockAlias?.nilIfBlank
        }
    }

    /// Compact representation of a nearby alternative dock for the watch Smart Stack
    struct AlternativeDock: Codable, Hashable {
        /// Older activity payloads omit identity and alias; keep decoding them by name.
        let id: String?
        let name: String
        let alias: String?
        let standardBikes: Int
        let eBikes: Int
        let emptySpaces: Int

        init(
            name: String,
            standardBikes: Int,
            eBikes: Int,
            emptySpaces: Int,
            id: String? = nil,
            alias: String? = nil
        ) {
            self.id = id
            self.name = name.liveActivityDisplayText
            self.alias = alias?.liveActivityDisplayText
            self.standardBikes = standardBikes
            self.eBikes = eBikes
            self.emptySpaces = emptySpaces
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                standardBikes: try container.decode(Int.self, forKey: .standardBikes),
                eBikes: try container.decode(Int.self, forKey: .eBikes),
                emptySpaces: try container.decode(Int.self, forKey: .emptySpaces),
                id: try container.decodeIfPresent(String.self, forKey: .id),
                alias: try container.decodeIfPresent(String.self, forKey: .alias)
            )
        }

        var displayName: String { alias?.nilIfBlank ?? name }
        var stableIdentifier: String { id?.nilIfBlank ?? name }

        var serverPayload: [String: Any] {
            var payload: [String: Any] = [
                "name": name,
                "standardBikes": standardBikes,
                "eBikes": eBikes,
                "emptySpaces": emptySpaces,
            ]
            payload["id"] = id
            payload["alias"] = alias
            return payload
        }
    }
}


private extension String {
    /// The complete name stays in dock preferences. Live Activity content has a 4KB budget.
    var liveActivityDisplayText: String {
        var result = ""
        var byteCount = 0
        for scalar in unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= 120 else { break }
            result.unicodeScalars.append(scalar)
            byteCount += scalarBytes
        }
        return result
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
