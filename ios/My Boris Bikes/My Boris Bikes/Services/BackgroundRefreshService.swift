import BackgroundTasks
import Combine
import Foundation
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
            print("BackgroundRefresh: Async refresh completed successfully")
            return true
        } catch {
            print("BackgroundRefresh: Async refresh failed: \(error)")
            return false
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
