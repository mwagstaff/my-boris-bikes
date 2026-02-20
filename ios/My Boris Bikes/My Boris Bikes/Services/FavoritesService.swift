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
        
        let favorite = FavoriteBikePoint(bikePoint: bikePoint, sortOrder: favorites.count)
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
        guard let rawAlias = favorites.first(where: { $0.id == id })?.alias?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAlias.isEmpty else {
            return nil
        }
        return rawAlias
    }
    
    func displayName(for bikePoint: BikePoint) -> String {
        alias(for: bikePoint.id) ?? bikePoint.commonName
    }
    
    func updateAlias(for id: String, alias: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].alias = (trimmedAlias?.isEmpty == false) ? trimmedAlias : nil
        
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
        
        guard WCSession.default.isReachable else {
            return
        }
        
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
            let message = ["favorites": data]
            
            
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

#if os(iOS)
extension FavoritesService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
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
                let response = [
                    "favorites": data,
                    "status": "success",
                    "count": favorites.count,
                    "timestamp": Date().timeIntervalSince1970
                ] as [String : Any]
                
                replyHandler(response)
                
            } catch {
                replyHandler([
                    "status": "error",
                    "message": error.localizedDescription,
                    "timestamp": Date().timeIntervalSince1970
                ])
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
