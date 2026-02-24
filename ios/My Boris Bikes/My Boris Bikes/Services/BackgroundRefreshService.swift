import BackgroundTasks
import Combine
import Foundation
import WatchConnectivity
import WidgetKit

final class BackgroundRefreshService {
    static let shared = BackgroundRefreshService()
    static let taskIdentifier = "dev.skynolimit.myborisbikes.widget-refresh"

    /// Dedicated URLSession with tight timeouts for background refresh.
    /// Background tasks are killed quickly by iOS — keep requests fast.
    private static let backgroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private var cancellables = Set<AnyCancellable>()
    private let allBikePointsPrewarmTimestampKey = "allBikePointsPrewarmTimestamp"
#if DEBUG
    private var debugCancellable: AnyCancellable?
#endif

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(refreshTask)
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("BackgroundRefresh: Scheduled app refresh for ~15 min from now")
        } catch {
            print("BackgroundRefresh: Failed to schedule refresh: \(error)")
        }
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        // Always schedule the next refresh first, so the chain never breaks
        scheduleAppRefresh()

        Task {
            let success = await refreshWidgetDataAsync()
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            // iOS is killing us — mark complete so we don't get penalised
            task.setTaskCompleted(success: false)
            print("BackgroundRefresh: Task expired before completion")
        }
    }

    /// Called by AppDelegate when a silent background push arrives from the server.
    /// Fetches fresh dock data, updates the iOS widget, pushes watch-compatible data
    /// to the shared app group, and signals the watch via WatchConnectivity.
    func performComplicationRefresh() async -> Bool {
        return await refreshWidgetDataAsync()
    }

    func prewarmAllBikePointsIfStale(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        let lastPrefetch = AppConstants.UserDefaults.sharedDefaults.double(forKey: allBikePointsPrewarmTimestampKey)

        if !force,
           lastPrefetch > 0,
           now - lastPrefetch < AppConstants.App.allBikePointsPrewarmInterval {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let success = await self.fetchAndCacheAllBikePoints()
            if success {
                AppConstants.UserDefaults.sharedDefaults.set(
                    Date().timeIntervalSince1970,
                    forKey: self.allBikePointsPrewarmTimestampKey
                )
            }
        }
    }

#if DEBUG
    func runImmediateRefresh(completion: ((Bool, String) -> Void)? = nil) {
        debugCancellable = refreshWidgetData { success, message in
            self.debugCancellable = nil
            completion?(success, message)
        }
    }
#endif

    /// Async version of refresh used by the background task handler.
    /// Uses async/await with the tight-timeout session for faster execution.
    private func refreshWidgetDataAsync() async -> Bool {
        let favoritesService = FavoritesService.shared
        let favorites = favoritesService.favorites
        guard !favorites.isEmpty else { return true }

        let favoriteIds = favorites.map { $0.id }

        do {
            // Fetch each favorite's data concurrently with tight timeouts
            let bikePoints = try await withThrowingTaskGroup(of: BikePoint?.self, returning: [BikePoint].self) { group in
                for id in favoriteIds {
                    group.addTask {
                        try await self.fetchBikePoint(id: id)
                    }
                }
                var results: [BikePoint] = []
                for try await bp in group {
                    if let bp = bp { results.append(bp) }
                }
                return results
            }

            guard !bikePoints.isEmpty else {
                print("BackgroundRefresh: No bike points returned")
                return false
            }

            let sortMode = favoritesService.sortMode
            await MainActor.run {
                WidgetService.shared.updateWidgetData(
                    bikePoints: bikePoints,
                    allBikePoints: [],
                    favorites: favorites,
                    sortMode: sortMode,
                    userLocation: nil
                )
            }
            // Push fresh data to watch complications via WatchConnectivity
            pushDataToWatchComplication(bikePoints: bikePoints, favorites: favorites)
            print("BackgroundRefresh: Async refresh completed successfully")
            return true
        } catch {
            print("BackgroundRefresh: Async refresh failed: \(error)")
            return false
        }
    }

    // MARK: - Watch Complication Push

    /// Codable mirror of the watch extension's WidgetBikePoint — must match field names exactly.
    private struct WatchWidgetBikePoint: Codable {
        let id: String
        let commonName: String
        let alias: String?
        let standardBikes: Int
        let eBikes: Int
        let emptySpaces: Int
        let distance: Double?
    }

    /// Writes fresh bike data into the shared app group in the format expected by the watch
    /// widget extension, then signals the watch via transferCurrentComplicationUserInfo so it
    /// wakes and reloads its timelines immediately.
    private func pushDataToWatchComplication(bikePoints: [BikePoint], favorites: [FavoriteBikePoint]) {
        let appGroup = "group.dev.skynolimit.myborisbikes"
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }

        // Build an alias lookup from the user's saved favourites
        let aliasMap: [String: String] = favorites.reduce(into: [:]) { result, fav in
            if let alias = fav.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                result[fav.id] = alias
            }
        }

        // Convert to watch-compatible format, preserving favourites sort order
        let sortedIds = favorites.sorted { $0.sortOrder < $1.sortOrder }.map { $0.id }
        let bikePointById: [String: BikePoint] = Dictionary(uniqueKeysWithValues: bikePoints.map { ($0.id, $0) })

        let watchPoints: [WatchWidgetBikePoint] = sortedIds.compactMap { id in
            guard let bp = bikePointById[id] else { return nil }
            return WatchWidgetBikePoint(
                id: bp.id,
                commonName: bp.commonName,
                alias: aliasMap[bp.id],
                standardBikes: bp.standardBikes,
                eBikes: bp.eBikes,
                emptySpaces: bp.emptyDocks,
                distance: nil
            )
        }

        guard !watchPoints.isEmpty else { return }

        do {
            let timestamp = Date().timeIntervalSince1970
            let encoder = JSONEncoder()

            // Write all docks — used by configurable dock complications
            let allData = try encoder.encode(watchPoints)
            userDefaults.set(allData, forKey: "bikepoints")
            userDefaults.set(allData, forKey: "bikepoints_last_known_good")
            userDefaults.set(timestamp, forKey: "bikepoints_last_known_good_timestamp")

            // Write the first favourite as the "closest station" (no location available in background)
            if let first = watchPoints.first {
                let firstData = try encoder.encode(first)
                userDefaults.set(firstData, forKey: "widget_closest_station")
                userDefaults.set(firstData, forKey: "widget_last_known_good_data")
                userDefaults.set(timestamp, forKey: "widget_last_known_good_timestamp")

                // Also write the file that the widget extension checks first
                if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
                    try firstData.write(to: containerURL.appendingPathComponent("widget_data.json"))
                }
            }

            // Shared data timestamp — read by the complication to show "Updated X ago"
            userDefaults.set(timestamp, forKey: "widget_data_timestamp")

            // Per-dock timestamps — used by configurable widget refresh strategy
            for bp in bikePoints {
                userDefaults.set(timestamp, forKey: "dock_\(bp.id)_timestamp")
            }

            userDefaults.synchronize()

            // Signal the watch to reload its complication timelines immediately.
            // transferCurrentComplicationUserInfo has a system-enforced daily budget (~50/day),
            // which is well within our ~15-minute iOS background-refresh cadence.
            if WCSession.isSupported() {
                let session = WCSession.default
                if session.activationState == .activated && session.isWatchAppInstalled {
                    let payload: [String: Any] = [
                        "complication_refresh": true,
                        "timestamp": timestamp
                    ]
                    session.transferCurrentComplicationUserInfo(payload)
                    print("BackgroundRefresh: Sent complication refresh signal to watch")
                }
            }

        } catch {
            print("BackgroundRefresh: Failed to push watch complication data: \(error)")
        }
    }

    private func fetchBikePoint(id: String) async throws -> BikePoint? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let urlString = "https://api.tfl.gov.uk/Place/\(id)?cb=\(timestamp)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, _) = try await Self.backgroundSession.data(for: request)
        return try? JSONDecoder().decode(BikePoint.self, from: data)
    }

    private func fetchAndCacheAllBikePoints() async -> Bool {
        let timestamp = Int(Date().timeIntervalSince1970)
        let urlString = "https://api.tfl.gov.uk/BikePoint?cb=\(timestamp)"

        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = AppConstants.App.mapFetchTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, _) = try await Self.backgroundSession.data(for: request)
            let bikePoints = try JSONDecoder().decode([FailableBikePoint].self, from: data).compactMap(\.value)
            let installedBikePoints = bikePoints.filter { $0.isInstalled }
            guard !installedBikePoints.isEmpty else { return false }

            AllBikePointsCache.shared.save(installedBikePoints, savedAt: Date())
            return true
        } catch {
            print("BackgroundRefresh: All bike points prewarm failed: \(error)")
            return false
        }
    }

    /// Combine-based refresh for debug/immediate usage.
    private func refreshWidgetData(completion: @escaping (Bool, String) -> Void) -> AnyCancellable? {
        let favoritesService = FavoritesService.shared
        let favorites = favoritesService.favorites
        guard !favorites.isEmpty else {
            completion(true, "No favourites configured")
            return nil
        }

        let favoriteIds = favorites.map { $0.id }
        let favoritesPublisher = TfLAPIService.shared.fetchMultipleBikePoints(
            ids: favoriteIds,
            cacheBusting: true
        )

        let allPublisher: AnyPublisher<[BikePoint], NetworkError>
        if shouldFetchAllBikePoints() {
            allPublisher = TfLAPIService.shared.fetchAllBikePoints(cacheBusting: true)
                .catch { error in
                    print("BackgroundRefresh: All bike points refresh failed: \(error)")
                    return Just<[BikePoint]>([])
                        .setFailureType(to: NetworkError.self)
                }
                .eraseToAnyPublisher()
        } else {
            allPublisher = Just([])
                .setFailureType(to: NetworkError.self)
                .eraseToAnyPublisher()
        }

        var didComplete = false
        return favoritesPublisher
            .combineLatest(allPublisher)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    guard !didComplete else { return }
                    if case .failure(let error) = completionResult {
                        let message = error.errorDescription ?? "Refresh failed"
                        print("BackgroundRefresh: Refresh failed: \(message)")
                        didComplete = true
                        completion(false, message)
                    }
                },
                receiveValue: { favoriteBikePoints, allBikePoints in
                    guard !didComplete else { return }
                    didComplete = true

                    let installedBikePoints = allBikePoints.filter { $0.isInstalled }
                    let sortMode = favoritesService.sortMode
                    Task { @MainActor in
                        WidgetService.shared.updateWidgetData(
                            bikePoints: favoriteBikePoints,
                            allBikePoints: installedBikePoints,
                            favorites: favorites,
                            sortMode: sortMode,
                            userLocation: nil
                        )
                        completion(true, "Widget data updated")
                    }
                }
            )
    }

    private func shouldFetchAllBikePoints() -> Bool {
        let defaults = AlternativeDockSettings.userDefaultsStore
        let isEnabled = defaults.bool(forKey: AlternativeDockSettings.enabledKey)
        let widgetEnabled = defaults.object(forKey: AlternativeDockSettings.widgetEnabledKey) as? Bool
            ?? AlternativeDockSettings.defaultWidgetEnabled
        return isEnabled || widgetEnabled
    }
}

private struct FailableBikePoint: Decodable {
    let value: BikePoint?

    init(from decoder: Decoder) throws {
        value = try? BikePoint(from: decoder)
    }
}
