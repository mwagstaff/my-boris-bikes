import Foundation
import SwiftUI

struct AppConstants {
    struct Colors {
        static let standardBike = Color(red: 236/255, green: 0/255, blue: 0/255)
        static let eBike = Color(red: 12/255, green: 17/255, blue: 177/255)
        static let emptySpace = Color(red: 117/255, green: 117/255, blue: 117/255)
        static let favoriteHighlight = Color(red: 255/255, green: 215/255, blue: 0/255) // golden yellow for favorites
        // static let emptySpace = Color(red: 227/255, green: 120/255, blue: 52/255)
    }
    
    struct API {
        static let baseURL = "https://api.tfl.gov.uk"
        static let bikePointEndpoint = "/BikePoint"
        static let placeEndpoint = "/Place"
    }
    
    struct App {
        static let refreshInterval: TimeInterval = 30
        static let staleDataWarningThreshold: TimeInterval = 120
        static let mapFetchTimeout: TimeInterval = 12
        static let mapTransientRetryInterval: TimeInterval = 8
        static let allBikePointsPrewarmInterval: TimeInterval = 60
        static let appGroup = "group.dev.skynolimit.myborisbikes"
        static let developerURL = "https://skynolimit.dev"
    }

    struct Server {
        static let analyticsEndpoint = "/app/metrics"
        static let complicationRegisterEndpoint = "/complication/register"
        static let complicationUnregisterEndpoint = "/complication/unregister"

        static var baseURL: String {
            #if DEBUG
            let useDevEnvironment = AppConstants.UserDefaults.sharedDefaults.bool(
                forKey: AppConstants.UserDefaults.liveActivityUseDevAPIKey
            )
            if useDevEnvironment {
                return "http://localhost:3010"
            }
            #endif
            return "https://api.skynolimit.dev/my-boris-bikes"
        }
    }
    
    struct UserDefaults {
        static let favoritesKey = "favorites"
        static let sortModeKey = "sortMode"
        static let locationPermissionKey = "locationPermission"
        static let mapDisplayModeKey = "mapAvailabilityDisplayMode"
        static let bikeDataFilterKey = "bikeDataFilter"
        static let widgetRefreshRequestKey = "widgetRefreshRequest"
        static let alternativeDocksEnabledKey = "alternativeDocksEnabled"
        static let alternativeDocksMinSpacesKey = "alternativeDocksMinSpaces"
        static let alternativeDocksMinBikesKey = "alternativeDocksMinBikes"
        static let alternativeDocksMinEBikesKey = "alternativeDocksMinEBikes"
        static let alternativeDocksDistanceThresholdMilesKey = "alternativeDocksDistanceThresholdMiles"
        static let alternativeDocksMaxCountKey = "alternativeDocksMaxCount"
        static let alternativeDocksWidgetEnabledKey = "alternativeDocksWidgetEnabled"
        static let alternativeDocksUseStartingPointLogicKey = "alternativeDocksUseStartingPointLogic"
        static let alternativeDocksUseMinimumThresholdsKey = "alternativeDocksUseMinimumThresholds"
        static let liveActivityPrimaryDisplayKey = "liveActivityPrimaryDisplay"
        static let liveActivityUseDevAPIKey = "liveActivityUseDevAPI"
        static let liveActivityAutoRemoveDurationKey = "liveActivityAutoRemoveDuration"

        static var sharedDefaults: Foundation.UserDefaults {
            Foundation.UserDefaults(suiteName: AppConstants.App.appGroup) ?? .standard
        }
    }

    struct LiveActivity {
        /// Default auto-removal duration (2 hours)
        static let defaultAutoRemoveDurationSeconds: TimeInterval = 2 * 60 * 60

        /// Hard cap for notification updates if an activity isn't explicitly ended
        static let maxNotificationWindowSeconds: TimeInterval = 2 * 60 * 60

        /// Debug auto-removal duration (1 minute)
        static let debugAutoRemoveDurationSeconds: TimeInterval = 60
    }
}

// MARK: - Live Activity API Environment

enum LiveActivityAPIEnvironment: String, CaseIterable, Identifiable {
    case production = "Production"
    case development = "Development (localhost)"

    var id: String { rawValue }

    var isProduction: Bool {
        self == .production
    }

    var description: String {
        switch self {
        case .production:
            return "https://api.skynolimit.dev/my-boris-bikes"
        case .development:
            return "http://localhost:3010"
        }
    }
}
