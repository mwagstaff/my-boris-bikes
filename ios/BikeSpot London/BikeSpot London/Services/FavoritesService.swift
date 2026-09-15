import Foundation
import Combine
#if os(iOS)
import WatchConnectivity
import WidgetKit
#endif

class FavoritesService: NSObject, ObservableObject {
    static let shared = FavoritesService()
    
    @Published var favorites: [FavoriteBikePoint] = []
    @Published var sortMode: SortMode = .distance
    @Published var recentlyAddedBikePoint: BikePoint?
    
    private let userDefaults: UserDefaults
    private var dockPreferencesObserver: AnyCancellable?
    
    private override init() {
        let suiteName = AppConstants.App.appGroup
        
        if !suiteName.isEmpty {
            if let groupDefaults = UserDefaults(suiteName: suiteName) {
                self.userDefaults = groupDefaults
            } else {
                self.userDefaults = UserDefaults.standard
            }
        } else {
            self.userDefaults = UserDefaults.standard
        }
        
        super.init()
        
        loadFavorites()
        loadSortMode()
        // Keep legacy favourite payloads compatible while names are now shared by dock ID.
        applyDockPreferences()
        dockPreferencesObserver = NotificationCenter.default.publisher(for: .dockPreferencesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDockPreferences() }
    }
    
    private func loadFavorites() {
        
        if let data = userDefaults.data(forKey: AppConstants.UserDefaults.favoritesKey) {
            do {
                favorites = try JSONDecoder().decode([FavoriteBikePoint].self, from: data)
                favorites.forEach { favorite in
                }
            } catch {
                favorites = []
            }
        } else {
            favorites = []
        }
    }
    
    private func saveFavorites() {
        favorites.forEach { fav in
        }
        
        do {
            let data = try JSONEncoder().encode(favorites)
            userDefaults.set(data, forKey: AppConstants.UserDefaults.favoritesKey)
            
            // Debug logging
            
            // Check if we're actually using the app group
            if userDefaults == UserDefaults.standard {
            } else {
            }
            
            // Verify the save worked
            if let verifyData = userDefaults.data(forKey: AppConstants.UserDefaults.favoritesKey) {
                
                // Try to decode it back to verify structure
                do {
                    let verifyFavorites = try JSONDecoder().decode([FavoriteBikePoint].self, from: verifyData)
                } catch {
                }
            } else {
            }
            
            // Force synchronization
            let syncResult = userDefaults.synchronize()
            
            // Send notification to watch app if available
            #if os(iOS)
            sendFavoritesToWatch()

            // Create file-based trigger for watch widget configuration refresh
            createWidgetConfigurationTrigger()

            // Reload iOS widgets
            WidgetCenter.shared.reloadAllTimelines()

            // Also trigger watch widget refresh via notification
            NotificationCenter.default.post(name: Notification.Name("favoritesDidChange"), object: nil)

            // Additional delay to ensure watch processes the data
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NotificationCenter.default.post(name: Notification.Name("favoritesDidChange"), object: nil)
            }
            #endif
            
        } catch {
        }
        
    }
    
    #if os(iOS)
    private func createWidgetConfigurationTrigger() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.App.appGroup) else {
            return
        }
        
        let triggerFile = containerURL.appendingPathComponent("widget_config_trigger.txt")
        let triggerContent = "iOS favorites updated at \(Date().timeIntervalSince1970)"
        
        do {
            try triggerContent.write(to: triggerFile, atomically: true, encoding: .utf8)
        } catch {
        }
    }
    #endif
    
    private func loadSortMode() {
        if let sortModeString = userDefaults.string(forKey: AppConstants.UserDefaults.sortModeKey),
           let mode = SortMode(rawValue: sortModeString) {
            sortMode = mode
        }
    }
    
    private func saveSortMode() {
        userDefaults.set(sortMode.rawValue, forKey: AppConstants.UserDefaults.sortModeKey)
    }
    
    func addFavorite(_ bikePoint: BikePoint) {
        guard !isFavorite(bikePoint.id) else { return }
        
        let favorite = FavoriteBikePoint(bikePoint: bikePoint, sortOrder: favorites.count, alias: DockPreferencesService.shared.alias(for: bikePoint.id))
        favorites.append(favorite)
        saveFavorites()
        
        // Store the bike point data for immediate use in HomeViewModel
        recentlyAddedBikePoint = bikePoint
        
        // Clear after a short delay to prevent memory bloat
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.recentlyAddedBikePoint = nil
        }
    }
    
    func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
        reorderFavorites()
        saveFavorites()
    }
    
    func isFavorite(_ id: String) -> Bool {
        favorites.contains { $0.id == id }
    }
    
    func toggleFavorite(_ bikePoint: BikePoint) {
        if isFavorite(bikePoint.id) {
            removeFavorite(bikePoint.id)
        } else {
            addFavorite(bikePoint)
        }
    }
    
    func alias(for id: String) -> String? {
        DockPreferencesService.shared.alias(for: id)
    }

    func displayName(for bikePoint: BikePoint) -> String {
        alias(for: bikePoint.id) ?? bikePoint.commonName
    }

    func updateAlias(for id: String, alias: String?) {
        DockPreferencesService.shared.updateAlias(for: id, alias: alias)
    }

    private func applyDockPreferences() {
        favorites = favorites.map { favorite in
            var updated = favorite
            updated.alias = DockPreferencesService.shared.alias(for: favorite.id)
            return updated
        }
        saveFavorites()
    }

    func updateSortMode(_ mode: SortMode) {
        sortMode = mode
        saveSortMode()
    }
    
    func reorderFavorites() {
        for (index, _) in favorites.enumerated() {
            favorites[index].sortOrder = index
        }
        saveFavorites()
    }
    
    #if os(iOS)
    private func sendFavoritesToWatch() {
        
        guard WCSession.default.activationState == .activated else { return }
        
        do {
            // Convert FavoriteBikePoint to format expected by watch
            let watchCompatibleFavorites = favorites.map { favorite in
                WatchCompatibleFavorite(
                    id: favorite.id,
                    commonName: favorite.name,
                    alias: favorite.alias,
                    sortOrder: favorite.sortOrder
                )
            }
            
            let data = try JSONEncoder().encode(watchCompatibleFavorites)
            var message: [String: Any] = ["favorites": data]
            message["favoriteJourneys"] = encodedFavoriteJourneysForWatch()
            message["dockPreferences"] = DockPreferencesService.shared.encodedPayload
            message.merge(JourneyStore.syncPayload) { _, latest in latest }
            // Application context delivers the latest complete preferences when Watch reconnects.
            try WCSession.default.updateApplicationContext(message)
            guard WCSession.default.isReachable else { return }
            WCSession.default.sendMessage(message, replyHandler: { reply in
            }) { error in
            }
        } catch {
        }
    }
    
    // Public method to force sync with watch
    func forceSyncWithWatch() {
        sendFavoritesToWatch()
    }

    private func encodedFavoriteJourneysForWatch() -> Data? {
        let storedJourneys = userDefaults.data(forKey: AppConstants.UserDefaults.favoriteJourneysKey)
            .flatMap { try? JSONDecoder().decode([FavoriteJourney].self, from: $0) } ?? []
        let preferences = DockPreferencesService.shared
        let journeys = storedJourneys.map { journey in
            WatchFavoriteJourney(
                id: journey.id,
                startDock: WatchFavoriteJourneyDock(
                    id: journey.startDock.id,
                    commonName: journey.startDock.name,
                    alias: preferences.alias(for: journey.startDock.id),
                    lat: journey.startDock.latitude,
                    lon: journey.startDock.longitude
                ),
                endDock: WatchFavoriteJourneyDock(
                    id: journey.endDock.id,
                    commonName: journey.endDock.name,
                    alias: preferences.alias(for: journey.endDock.id),
                    lat: journey.endDock.latitude,
                    lon: journey.endDock.longitude
                )
            )
        }
        return try? JSONEncoder().encode(journeys)
    }
    
    func setupWatchConnectivity() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    #endif
}

// Helper struct to match watch app's expected data format
struct WatchCompatibleFavorite: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let sortOrder: Int
}

private struct WatchFavoriteJourneyDock: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let lat: Double
    let lon: Double
}

private struct WatchFavoriteJourney: Codable {
    let id: String
    let startDock: WatchFavoriteJourneyDock
    let endDock: WatchFavoriteJourneyDock
}

#if os(iOS)
extension FavoritesService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            DispatchQueue.main.async { self.sendFavoritesToWatch() }
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        
        // Handle sync request from watch
        if let request = message["request"] as? String, request == "favorites" {
            
            do {
                // Convert favorites to watch-compatible format
                let watchCompatibleFavorites = favorites.map { favorite in
                    WatchCompatibleFavorite(
                        id: favorite.id,
                        commonName: favorite.name,
                        alias: favorite.alias,
                        sortOrder: favorite.sortOrder
                    )
                }
                
                let data = try JSONEncoder().encode(watchCompatibleFavorites)
                var response = [
                    "favorites": data,
                    "status": "success",
                    "count": favorites.count,
                    "timestamp": Date().timeIntervalSince1970
                ] as [String : Any]
                
                response["favoriteJourneys"] = encodedFavoriteJourneysForWatch()
                response["dockPreferences"] = DockPreferencesService.shared.encodedPayload
                response.merge(JourneyStore.syncPayload) { _, latest in latest }
                Task { @MainActor in await ScheduledJourneyService.shared.refresh() }
                replyHandler(response)
                
            } catch {
                replyHandler([
                    "status": "error",
                    "message": error.localizedDescription,
                    "timestamp": Date().timeIntervalSince1970
                ])
            }
        } else if let request = message["request"] as? String, request == "journeyState" {
            var response = JourneyStore.syncPayload
            response["dockPreferences"] = DockPreferencesService.shared.encodedPayload
            response["status"] = "success"
            response["timestamp"] = Date().timeIntervalSince1970
            replyHandler(response)
        } else if let request = message["request"] as? String, request == "journeyTestAction" {
            let action = message["action"] as? String ?? ""
            Task { @MainActor in
#if DEBUG
                let success = await JourneyTestService.shared.performWatchAction(action)
#else
                let success = false
#endif
                var response = JourneyStore.syncPayload
                response["dockPreferences"] = DockPreferencesService.shared.encodedPayload
                response["status"] = success ? "success" : "error"
                response["success"] = success
                response["timestamp"] = Date().timeIntervalSince1970
                if success,
                   let simulation = JourneyStore.read(JourneySimulation.self, key: JourneySimulation.key),
                   simulation.expiresAt > Date(),
                   let selection = simulation.snapshot.selection(location: simulation.location, nearby: simulation.nearby) {
                    response["dockId"] = selection.dock.id
                    response["journeyMetric"] = selection.metric.rawValue
                }
                replyHandler(response)
            }
        } else if let request = message["request"] as? String, request == "journeyAction" {
            let action = message["action"] as? String ?? ""
            let dockId = message["dockId"] as? String ?? ""

            Task { @MainActor in
                let success = await LiveActivityService.shared.performWatchJourneyAction(
                    action: action,
                    dockId: dockId
                )
                let session = LiveActivityService.shared.currentNotificationSession
                var response: [String: Any] = [
                    "status": success ? "success" : "error",
                    "success": success,
                    "timestamp": Date().timeIntervalSince1970
                ]
                if let session {
                    response["dockId"] = session.dockId
                    if let phase = session.scheduledJourneyPhase {
                        response["journeyMetric"] = phase == .end ? "spaces" : "allBikes"
                    }
                }
                replyHandler(response)
            }
        } else {
            // Unknown request
            replyHandler([
                "status": "unknown_request",
                "timestamp": Date().timeIntervalSince1970
            ])
        }
    }
}
#endif
