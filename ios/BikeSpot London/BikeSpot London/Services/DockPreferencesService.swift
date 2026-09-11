import Combine
import Foundation

extension Notification.Name {
    static let dockPreferencesDidChange = Notification.Name("dockPreferencesDidChange")
}

/// Dock identity owns both its alias and its ordered alternatives, independently of favourites.
final class DockPreferencesService: ObservableObject {
    static let shared = DockPreferencesService()
    static let storageKey = "dockPreferences.v1"
    private static let syncedRevisionKey = "dockPreferences.syncedRevision"

    struct Settings: Codable, Equatable {
        var enabled: Bool
        var minSpaces: Int
        var minBikes: Int
        var minEBikes: Int
        var maxCount: Int
        var useMinimumThresholds: Bool

        init(defaults: UserDefaults) {
            enabled = defaults.object(forKey: AlternativeDockSettings.enabledKey) as? Bool ?? AlternativeDockSettings.defaultEnabled
            minSpaces = defaults.object(forKey: AlternativeDockSettings.minSpacesKey) as? Int ?? AlternativeDockSettings.defaultMinSpaces
            minBikes = defaults.object(forKey: AlternativeDockSettings.minBikesKey) as? Int ?? AlternativeDockSettings.defaultMinBikes
            minEBikes = defaults.object(forKey: AlternativeDockSettings.minEBikesKey) as? Int ?? AlternativeDockSettings.defaultMinEBikes
            maxCount = defaults.object(forKey: AlternativeDockSettings.maxCountKey) as? Int ?? AlternativeDockSettings.defaultMaxAlternatives
            useMinimumThresholds = defaults.object(forKey: AlternativeDockSettings.useMinimumThresholdsKey) as? Bool ?? AlternativeDockSettings.defaultUseMinimumThresholds
        }
    }

    struct Snapshot: Codable, Equatable {
        var revision: Int64 = 0
        var alternatives: [String: [String]] = [:]
        var aliases: [String: String] = [:]
        var docks: [String: ScheduledJourneyDock] = [:]
        var settings: Settings
    }

    @Published private(set) var snapshot: Snapshot
    private let userDefaults: UserDefaults
    private var settingsObserver: AnyCancellable?

    init(userDefaults: UserDefaults = AppConstants.UserDefaults.sharedDefaults) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = Snapshot(settings: Settings(defaults: userDefaults))
            // Migrate once. Removing an alias later must not revive its legacy value.
            if let data = userDefaults.data(forKey: AppConstants.UserDefaults.favoritesKey),
               let favorites = try? JSONDecoder().decode([FavoriteBikePoint].self, from: data) {
                for favorite in favorites {
                    if let alias = Self.normalizedAlias(favorite.alias) {
                        snapshot.aliases[favorite.id] = alias
                    }
                }
            }
            persist()
        }
        refreshSettingsIfNeeded()
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSettingsIfNeeded() }
    }

    var revision: Int64 { snapshot.revision }
    var hasPendingSync: Bool {
        revision > ((userDefaults.object(forKey: Self.syncedRevisionKey) as? NSNumber)?.int64Value ?? -1)
    }

    var encodedPayload: Data? { try? JSONSerialization.data(withJSONObject: serverPayload, options: .sortedKeys) }
    var serverPayload: [String: Any] {
        guard let data = try? JSONEncoder().encode(snapshot),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        payload.removeValue(forKey: "docks")
        return payload
    }

    func customDockIDs(for dockID: String) -> [String]? { snapshot.alternatives[dockID] }
    func alias(for dockID: String) -> String? { snapshot.aliases[dockID] }

    func customDocks(for dockID: String) -> [ScheduledJourneyDock]? {
        customDockIDs(for: dockID)?.map { id in
            snapshot.docks[id] ?? ScheduledJourneyDock(id: id, name: id, latitude: 0, longitude: 0)
        }
    }

    func saveAlternatives(for dock: ScheduledJourneyDock, docks: [ScheduledJourneyDock]?, aliases: [String: String] = [:]) {
        var updated = snapshot
        if let docks {
            var seen: Set<String> = [dock.id]
            let uniqueDocks = docks.filter { seen.insert($0.id).inserted }
            updated.alternatives[dock.id] = uniqueDocks.map(\.id)
            updated.docks[dock.id] = dock
            for alternative in uniqueDocks { updated.docks[alternative.id] = alternative }
        } else {
            updated.alternatives.removeValue(forKey: dock.id)
        }
        for (id, alias) in aliases { updated.aliases[id] = Self.normalizedAlias(alias) }
        commit(updated)
    }

    func updateAlias(for dockID: String, alias: String?) {
        var updated = snapshot
        updated.aliases[dockID] = Self.normalizedAlias(alias)
        commit(updated)
    }

    func markSynced(revision: Int64) {
        guard revision == self.revision else { return }
        userDefaults.set(NSNumber(value: revision), forKey: Self.syncedRevisionKey)
    }

    func refreshSettingsIfNeeded() {
        let settings = Settings(defaults: userDefaults)
        guard settings != snapshot.settings else { return }
        var updated = snapshot
        updated.settings = settings
        commit(updated)
    }

    private static func normalizedAlias(_ alias: String?) -> String? {
        guard let value = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func commit(_ updated: Snapshot) {
        guard updated != snapshot else { return }
        var updated = updated
        updated.revision = max(snapshot.revision + 1, Int64(Date().timeIntervalSince1970 * 1_000))
        snapshot = updated
        persist()
        NotificationCenter.default.post(name: .dockPreferencesDidChange, object: self)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
