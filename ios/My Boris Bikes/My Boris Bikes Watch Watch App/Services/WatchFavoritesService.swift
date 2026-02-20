import Foundation
import Combine
import WatchConnectivity
import WidgetKit

// MARK: - Notification Names
extension Notification.Name {
    static let favoritesDidChange = Notification.Name("favoritesDidChange")
}

class WatchFavoritesService: NSObject, ObservableObject {
    static let shared = WatchFavoritesService()
    
    @Published var favorites: [WatchFavoriteBikePoint] = []
    @Published var sortMode: WatchSortMode = .distance
    @Published var isConnectedToPhone: Bool = false
    
    private let userDefaults: UserDefaults
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let favoritesKey = "favorites"
    private let sortModeKey = "sortMode"
    
    // Automatic sync properties
    private var syncTimer: Timer?
    private var connectivityTimer: Timer?
    private let syncInterval: TimeInterval = 30.0 // Sync every 30 seconds
    private let connectivityCheckInterval: TimeInterval = 10.0 // Check connectivity every 10 seconds
    private var lastSyncAttempt: Date = Date.distantPast
    private var consecutiveFailureCount = 0
    private let maxConsecutiveFailures = 10
    
    private override init() {
        self.userDefaults = UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
        
        super.init()
        
        // Only warn if we're using standard UserDefaults
        if UserDefaults(suiteName: appGroup) == nil {
        }
        
        loadFavorites()
        loadSortMode()
    }
    
    private func loadFavorites(preserveExisting: Bool = false) {
        let previousCount = favorites.count
        
        if let data = userDefaults.data(forKey: favoritesKey) {
            do {
                let iosFavorites = try JSONDecoder().decode([FavoriteBikePointiOS].self, from: data)
                favorites = iosFavorites.map { WatchFavoriteBikePoint(from: $0) }
            } catch {
                if !preserveExisting {
                    favorites = []
                }
            }
        } else {
            if !preserveExisting {
                favorites = []
            }
        }
        
        // Check if favorites list has changed and invalidate configurable widget recommendations if needed
        let newCount = favorites.count
        if previousCount != newCount {
            if #available(iOS 16.0, watchOS 9.0, *) {
                NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            }
        }
    }
    
    private func loadSortMode() {
        if let sortModeString = userDefaults.string(forKey: "sortMode"),
           let mode = WatchSortMode(rawValue: sortModeString) {
            sortMode = mode
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
    
    func updateSortMode(_ mode: WatchSortMode) {
        sortMode = mode
        userDefaults.set(mode.rawValue, forKey: "watchSortMode")
    }
    
    func refreshFromiOS(preserveExisting: Bool = false) {
        loadFavorites(preserveExisting: preserveExisting)
    }
    
    func setupWatchConnectivity() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            
            // Start automatic sync timers
            startAutomaticSync()
        }
    }
    
    private func startAutomaticSync() {
        // Stop existing timers if any
        stopAutomaticSync()
        
        // Start connectivity monitoring timer
        connectivityTimer = Timer.scheduledTimer(withTimeInterval: connectivityCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnectivityStatus()
        }
        
        // Start sync timer  
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            self?.attemptAutomaticSync()
        }
        
        // Initial connectivity check and sync attempt
        checkConnectivityStatus()
        attemptAutomaticSync()
    }
    
    private func stopAutomaticSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        connectivityTimer?.invalidate()
        connectivityTimer = nil
    }
    
    private func checkConnectivityStatus() {
        let session = WCSession.default
        // On watchOS, we only need to check if the session is reachable and activated
        let newConnectionStatus = session.activationState == .activated && session.isReachable
        
        if newConnectionStatus != isConnectedToPhone {
            DispatchQueue.main.async {
                self.isConnectedToPhone = newConnectionStatus
            }
            
            // If just connected, attempt immediate sync
            if newConnectionStatus && !isConnectedToPhone {
                attemptAutomaticSync()
            }
        }
    }
    
    func attemptAutomaticSync() {
        let session = WCSession.default
        
        // Check if we should attempt sync
        guard session.isReachable else {
            return
        }
        
        guard consecutiveFailureCount < maxConsecutiveFailures else {
            return
        }
        
        // Don't sync too frequently
        let timeSinceLastAttempt = Date().timeIntervalSince(lastSyncAttempt)
        guard timeSinceLastAttempt >= syncInterval else {
            return
        }
        
        lastSyncAttempt = Date()
        requestFavoritesFromPhone()
    }
    
    private func requestFavoritesFromPhone() {
        let session = WCSession.default
        let message = ["request": "favorites", "timestamp": Date().timeIntervalSince1970] as [String: Any]
        
        session.sendMessage(message, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                self?.handleSyncResponse(reply, success: true)
            }
        }) { [weak self] error in
            DispatchQueue.main.async {
                self?.handleSyncResponse([:], success: false)
            }
        }
    }
    
    private func handleSyncResponse(_ response: [String: Any], success: Bool) {
        if success {
            consecutiveFailureCount = 0
            
            // Check if the response contains favorites data
            if let favoritesData = response["favorites"] as? Data {
                processFavoritesData(favoritesData)
            }
        } else {
            consecutiveFailureCount += 1
            
            // If we hit max failures, implement exponential backoff
            if consecutiveFailureCount >= maxConsecutiveFailures {
                let backoffTime = min(300.0, Double(consecutiveFailureCount - maxConsecutiveFailures + 1) * 30.0) // Max 5 minutes
                
                DispatchQueue.main.asyncAfter(deadline: .now() + backoffTime) {
                    self.consecutiveFailureCount = 0
                }
            }
        }
    }
    
    private func processFavoritesData(_ data: Data) {
        do {
            let watchCompatibleFavorites = try JSONDecoder().decode([WatchCompatibleFavorite].self, from: data)
            
            DispatchQueue.main.async {
                self.favorites = watchCompatibleFavorites.map { WatchFavoriteBikePoint(from: $0) }
                self.saveFavoritesToUserDefaults()
            }
        } catch {
        }
    }
    
    private func saveFavoritesToUserDefaults() {
        
        do {
            // Convert to the format expected by the widget extension (using JSONEncoder to match widget's JSONDecoder)
            let favoritesToSave = favorites.map { favorite in
                FavoriteBikePoint(
                    id: favorite.id,
                    commonName: favorite.commonName,
                    alias: favorite.alias,
                    sortOrder: favorite.sortOrder
                )
            }
            
            let data = try JSONEncoder().encode(favoritesToSave)
            userDefaults.set(data, forKey: favoritesKey)
            
            // Check if we're actually using the app group
            if userDefaults == UserDefaults.standard {
            }
            
            // Verify the save worked
            if userDefaults.data(forKey: favoritesKey) == nil {
            }
            
            // Force synchronization
            userDefaults.synchronize()
            
            // Create file-based trigger for widget configuration refresh
            createWidgetConfigurationTrigger()
            
            // Force aggressive widget extension activation via multiple timeline reloads
            forceWidgetExtensionActivation()
            
            // Notify widgets that favorites have changed
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            
            // Additional delayed notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            }
            
        } catch {
        }
    }
    
    private func createWidgetConfigurationTrigger() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return
        }
        
        let triggerFile = containerURL.appendingPathComponent("widget_config_trigger.txt")
        let triggerContent = "Favorites updated at \(Date().timeIntervalSince1970)"
        
        do {
            try triggerContent.write(to: triggerFile, atomically: true, encoding: .utf8)
        } catch {
        }
    }
    
    private func forceWidgetExtensionActivation() {
        // Force ALL widget timelines to reload multiple times to wake up the extension process
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                WidgetCenter.shared.reloadAllTimelines()
                
                // Also specifically target configurable widgets
                if #available(iOS 16.0, watchOS 9.0, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesConfigurableDockCircularComplication")
                    WidgetCenter.shared.reloadTimelines(ofKind: "MyBorisBikesConfigurableDockRectangularComplication")
                }
            }
        }
        
        // Try to invalidate App Intents entity query cache directly
        if #available(iOS 16.0, watchOS 9.0, *) {
            invalidateAppIntentsCache()
        }
        
        // Final massive reload after a longer delay to ensure extension is awake
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            WidgetCenter.shared.reloadAllTimelines()
            
            // Post notification one more time after forcing extension activation
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            
            // Try App Intents invalidation again after timeline reload
            if #available(iOS 16.0, watchOS 9.0, *) {
                self.invalidateAppIntentsCache()
            }
        }
    }
    
    @available(iOS 16.0, watchOS 9.0, *)
    private func invalidateAppIntentsCache() {
        // Try to force invalidation by updating a cache-busting value in UserDefaults
        let cacheInvalidationKey = "app_intents_cache_invalidation_timestamp"
        let currentTime = Date().timeIntervalSince1970
        userDefaults.set(currentTime, forKey: cacheInvalidationKey)
        userDefaults.synchronize()
        
        // Multiple delayed attempts to ensure the cache is invalidated
        for delay in [0.5, 1.0, 1.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let newTime = Date().timeIntervalSince1970
                self.userDefaults.set(newTime, forKey: cacheInvalidationKey)
                self.userDefaults.synchronize()
            }
        }
    }
    
    deinit {
        stopAutomaticSync()
    }
}

extension WatchFavoritesService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
        }
        
        // Update connectivity status when activation completes
        DispatchQueue.main.async {
            self.checkConnectivityStatus()
        }
        
        // If successfully activated and connected, attempt initial sync
        if activationState == .activated && session.isReachable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.attemptAutomaticSync()
            }
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.checkConnectivityStatus()
        }
        
        // If just became reachable, attempt sync
        if session.isReachable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.attemptAutomaticSync()
            }
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        
        if let favoritesData = message["favorites"] as? Data {
            do {
                // First try decoding as the new watch-compatible format
                let watchCompatibleFavorites = try JSONDecoder().decode([WatchCompatibleFavorite].self, from: favoritesData)
                
                DispatchQueue.main.async {
                    self.favorites = watchCompatibleFavorites.map { WatchFavoriteBikePoint(from: $0) }
                    self.saveFavoritesToUserDefaults()
                }
                
                replyHandler(["status": "success"])
            } catch {
                
                // Fallback: try decoding as old format
                do {
                    let iosFavorites = try JSONDecoder().decode([FavoriteBikePointiOS].self, from: favoritesData)
                    
                    DispatchQueue.main.async {
                        self.favorites = iosFavorites.map { WatchFavoriteBikePoint(from: $0) }
                        self.saveFavoritesToUserDefaults()
                    }
                    
                    replyHandler(["status": "success"])
                } catch {
                    replyHandler(["status": "error", "message": error.localizedDescription])
                }
            }
        } else {
            replyHandler(["status": "no_data"])
        }
    }
}

// Helper struct to match iOS app's sent data format
struct WatchCompatibleFavorite: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let sortOrder: Int
}

enum WatchSortMode: String, CaseIterable {
    case distance = "distance"
    case alphabetical = "alphabetical"
    
    var displayName: String {
        switch self {
        case .distance: return "Distance"
        case .alphabetical: return "A-Z"
        }
    }
}

struct WatchFavoriteBikePoint: Identifiable, Codable {
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
    
    init(from iosFavorite: FavoriteBikePointiOS) {
        self.id = iosFavorite.id
        self.commonName = iosFavorite.commonName
        self.alias = iosFavorite.alias
        self.sortOrder = iosFavorite.sortOrder
    }
    
    init(from watchCompatible: WatchCompatibleFavorite) {
        self.id = watchCompatible.id
        self.commonName = watchCompatible.commonName
        self.alias = watchCompatible.alias
        self.sortOrder = watchCompatible.sortOrder
    }
    
    init(id: String, commonName: String, alias: String?, sortOrder: Int) {
        self.id = id
        self.commonName = commonName
        self.alias = alias
        self.sortOrder = sortOrder
    }
}

// Temporary struct to decode iOS favorites
struct FavoriteBikePointiOS: Codable {
    let id: String
    let commonName: String
    let alias: String?
    let sortOrder: Int
}
