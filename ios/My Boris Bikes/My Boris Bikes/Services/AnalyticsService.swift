import Foundation

enum AnalyticsScreen: String {
    case app = "App"
    case favourites = "Favourites"
    case map = "Map"
    case preferences = "Preferences"
    case about = "About"
    case unknown = "Unknown"
}

enum AnalyticsAction: String {
    case appLaunch = "app_launch"
    case screenView = "screen_view"
    case dockTap = "dock_tap"
    case favoriteAdd = "favorite_add"
    case favoriteRemove = "favorite_remove"
    case liveActivityStart = "live_activity_start"
    case liveActivityEnd = "live_activity_end"
    case preferenceUpdate = "preference_update"
    case sortModeUpdate = "sort_mode_update"
    case favoriteAliasUpdate = "favorite_alias_update"
    case favoriteAliasRemove = "favorite_alias_remove"
    case mapDisplayModeUpdate = "map_display_mode_update"
}

struct AnalyticsDockInfo {
    let id: String
    let name: String?
    let standardBikes: Int?
    let eBikes: Int?
    let emptySpaces: Int?
    let totalDocks: Int?
    let isAvailable: Bool?

    init(
        id: String,
        name: String? = nil,
        standardBikes: Int? = nil,
        eBikes: Int? = nil,
        emptySpaces: Int? = nil,
        totalDocks: Int? = nil,
        isAvailable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.standardBikes = standardBikes
        self.eBikes = eBikes
        self.emptySpaces = emptySpaces
        self.totalDocks = totalDocks
        self.isAvailable = isAvailable
    }

    static func from(_ bikePoint: BikePoint) -> AnalyticsDockInfo {
        AnalyticsDockInfo(
            id: bikePoint.id,
            name: bikePoint.commonName,
            standardBikes: bikePoint.standardBikes,
            eBikes: bikePoint.eBikes,
            emptySpaces: bikePoint.emptyDocks,
            totalDocks: bikePoint.totalDocks,
            isAvailable: bikePoint.isAvailable
        )
    }

    func payload() -> [String: Any] {
        var payload: [String: Any] = ["id": id]
        if let name = name { payload["name"] = name }
        if let standardBikes = standardBikes { payload["standardBikes"] = standardBikes }
        if let eBikes = eBikes { payload["eBikes"] = eBikes }
        if let emptySpaces = emptySpaces { payload["emptySpaces"] = emptySpaces }
        if let totalDocks = totalDocks { payload["totalDocks"] = totalDocks }
        if let isAvailable = isAvailable { payload["isAvailable"] = isAvailable }
        return payload
    }
}

final class AnalyticsService {
    static let shared = AnalyticsService()

    private let endpointPath = AppConstants.Server.analyticsEndpoint
    private let isoFormatter: ISO8601DateFormatter
    private var didSendAppLaunch = false

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    private var buildType: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    func trackAppLaunch(screen: AnalyticsScreen) {
        guard !didSendAppLaunch else { return }
        didSendAppLaunch = true
        track(action: .appLaunch, screen: screen)
    }

    func track(
        action: AnalyticsAction,
        screen: AnalyticsScreen,
        dock: AnalyticsDockInfo? = nil,
        metadata: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "action": action.rawValue,
            "screen": screen.rawValue,
            "timestamp": isoFormatter.string(from: Date()),
            "buildType": buildType,
        ]

        if let deviceToken = DeviceTokenHelper.deviceToken {
            payload["deviceToken"] = deviceToken
        }

        if let dock = dock {
            payload["dock"] = dock.payload()
        }

        if !metadata.isEmpty {
            payload["metadata"] = metadata
        }

        send(payload: payload)
    }

    func trackDockTap(screen: AnalyticsScreen, bikePoint: BikePoint, source: String) {
        track(
            action: .dockTap,
            screen: screen,
            dock: AnalyticsDockInfo.from(bikePoint),
            metadata: ["source": source]
        )
    }

    private func send(payload: [String: Any]) {
        guard let url = URL(string: "\(AppConstants.Server.baseURL)\(endpointPath)") else { return }
        guard JSONSerialization.isValidJSONObject(payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        if let deviceToken = DeviceTokenHelper.deviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }
}
