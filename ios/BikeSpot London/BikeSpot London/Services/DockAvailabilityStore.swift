import Combine
import CoreLocation
import Foundation
import SwiftUI

/// The only in-process owner of dock counts. Screens project this snapshot rather
/// than retaining their own network responses or treating the disk cache as live data.
@MainActor
final class DockAvailabilityStore: ObservableObject {
    static let shared: DockAvailabilityStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITEST_DOCK_FRESHNESS") {
            func point(bikes: Int) -> BikePoint {
                BikePoint(id: "freshness-test", commonName: "Freshness test dock", lat: 51.5074, lon: -0.1278,
                    additionalProperties: [
                        AdditionalProperty(key: "Installed", value: "true"),
                        AdditionalProperty(key: "NbStandardBikes", value: String(bikes)),
                        AdditionalProperty(key: "NbEBikes", value: "0"),
                        AdditionalProperty(key: "NbEmptyDocks", value: String(20 - bikes)),
                        AdditionalProperty(key: "NbDocks", value: "20")
                    ])
            }
            return DockAvailabilityStore(cachedBikePoints: [point(bikes: 8)], cachedAt: .distantPast,
                fetchDirectory: {
                    Just([point(bikes: 1)]).setFailureType(to: NetworkError.self)
                        .delay(for: .seconds(20), scheduler: DispatchQueue.main).eraseToAnyPublisher()
                }, fetchDock: { _ in Just(point(bikes: 1)).setFailureType(to: NetworkError.self).eraseToAnyPublisher() })
        }
        #endif
        return DockAvailabilityStore()
    }()

    struct Snapshot {
        var bikePointsByID: [String: BikePoint] = [:]
        var checkedAtByID: [String: Date] = [:]
        var directoryCheckedAt: Date?

        var allBikePoints: [BikePoint] { bikePointsByID.values.sorted { $0.id < $1.id } }

        func oldestCheck(for ids: [String]) -> Date? {
            guard !ids.isEmpty, ids.allSatisfy({ checkedAtByID[$0] != nil }) else { return nil }
            return ids.compactMap { checkedAtByID[$0] }.min()
        }
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshFailed = false
    private var requests: [String: AnyCancellable] = [:]
    private var pendingRequests: Set<String> = []
    private var lastAttempts: [String: Date] = [:]
    private var timer: Timer?
    private var networkObservation: AnyCancellable?
    private var isActive = false
    private let fetchDirectory: () -> AnyPublisher<[BikePoint], NetworkError>
    private let fetchDock: (String) -> AnyPublisher<BikePoint, NetworkError>
    private let persist: (Snapshot) -> Void
    private let didAccept: ([BikePoint]) -> Void
    private let now: () -> Date

    // Push payloads may arrive before the directory supplies coordinates/metadata.
    private struct PushedCounts {
        let standardBikes: Int
        let eBikes: Int
        let spaces: Int
        let checkedAt: Date
    }
    private var pushedCounts: [String: PushedCounts] = [:]
    private var pushedSpaces: [String: (spaces: Int, checkedAt: Date)] = [:]

    var allBikePoints: [BikePoint] { snapshot.allBikePoints }
    var bikePointsByID: [String: BikePoint] { snapshot.bikePointsByID }
    var lastUpdateTime: Date? { snapshot.oldestCheck(for: Array(snapshot.bikePointsByID.keys)) }

    convenience init() {
        let cache = AllBikePointsCache.shared.loadSnapshot()
        self.init(
            cachedBikePoints: cache?.bikePoints ?? [],
            cachedAt: cache?.savedAt,
            checkedAtByID: cache?.checkedAtByID,
            fetchDirectory: { TfLAPIService.shared.fetchAllBikePoints(cacheBusting: true, timeoutInterval: 12) },
            fetchDock: { TfLAPIService.shared.fetchBikePoint(id: $0, cacheBusting: true) },
            persist: { snapshot in
                AllBikePointsCache.shared.save(snapshot.allBikePoints,
                    savedAt: snapshot.directoryCheckedAt ?? .distantPast,
                    checkedAtByID: snapshot.checkedAtByID)
            },
            didAccept: { points in
                for point in points {
                    DockArrivalMonitoringService.shared.updateMonitoredDockIfNeeded(using: point)
                }
                Task { await LiveActivityService.shared.updateActiveActivitiesIfNeeded(using: points) }
            }
        )
        networkObservation = TfLAPIService.shared.$isOnline.removeDuplicates().dropFirst()
            .sink { [weak self] online in
                guard let self, online, self.isActive else { return }
                self.refresh(force: true)
            }
    }

    init(cachedBikePoints: [BikePoint] = [], cachedAt: Date? = nil,
         checkedAtByID: [String: Date]? = nil,
         fetchDirectory: @escaping () -> AnyPublisher<[BikePoint], NetworkError>,
         fetchDock: @escaping (String) -> AnyPublisher<BikePoint, NetworkError>,
         persist: @escaping (Snapshot) -> Void = { _ in },
         didAccept: @escaping ([BikePoint]) -> Void = { _ in },
         now: @escaping () -> Date = Date.init) {
        let points = Dictionary(cachedBikePoints.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        snapshot = Snapshot(bikePointsByID: points,
            checkedAtByID: checkedAtByID ?? cachedAt.map { date in points.mapValues { _ in date } } ?? [:],
            directoryCheckedAt: cachedAt)
        self.fetchDirectory = fetchDirectory
        self.fetchDock = fetchDock
        self.persist = persist
        self.didAccept = didAccept
        self.now = now
    }

    func isStale(at date: Date, dockIDs: [String]? = nil) -> Bool {
        let checkedAt = dockIDs.map { snapshot.oldestCheck(for: $0) } ?? lastUpdateTime
        return checkedAt.map { date.timeIntervalSince($0) >= AppConstants.App.refreshInterval } ?? true
    }

    /// Coalesce callers across tabs. A selected-dock request never cancels a
    /// directory refresh, and a partial success never renews other docks' ages.
    func refresh(dockIDs: [String] = [], force: Bool = false,
                 maxAge: TimeInterval = AppConstants.App.refreshInterval) {
        let date = now()
        if shouldRequest("directory", checkedAt: snapshot.directoryCheckedAt,
                         maxAge: AppConstants.App.refreshInterval, force: force, at: date) {
            startRequest(key: "directory", publisher: fetchDirectory(), startedAt: date, directory: true)
        }
        for id in Set(dockIDs).sorted() {
            guard shouldRequest(id, checkedAt: snapshot.checkedAtByID[id], maxAge: maxAge, force: force, at: date) else { continue }
            startRequest(key: id, publisher: fetchDock(id).map { [$0] }.eraseToAnyPublisher(),
                         startedAt: date, directory: false)
        }
    }

    func refreshAndWait(dockIDs: [String] = [], force: Bool = false) async {
        refresh(dockIDs: dockIDs, force: force)
        // Cancellation ends this caller's wait without cancelling another screen's request.
        for await refreshing in $isRefreshing.values {
            if !refreshing || Task.isCancelled { return }
        }
    }

    private func shouldRequest(_ key: String, checkedAt: Date?, maxAge: TimeInterval,
                               force: Bool, at date: Date) -> Bool {
        guard !pendingRequests.contains(key) else { return false }
        if force { return true }
        guard checkedAt.map({ date.timeIntervalSince($0) >= maxAge }) ?? true else { return false }
        return lastAttempts[key].map { date.timeIntervalSince($0) >= 8 } ?? true
    }

    private func startRequest(key: String, publisher: AnyPublisher<[BikePoint], NetworkError>,
                              startedAt: Date, directory: Bool) {
        pendingRequests.insert(key)
        lastAttempts[key] = startedAt
        isRefreshing = true
        var receivedData = false
        let request = publisher.sink { [weak self] completion in
            guard let self else { return }
            if case .failure = completion { self.refreshFailed = true }
            if !receivedData { self.refreshFailed = true }
            self.pendingRequests.remove(key)
            self.requests.removeValue(forKey: key)
            self.isRefreshing = !self.pendingRequests.isEmpty
        } receiveValue: { [weak self] points in
            guard let self, !points.isEmpty else { return }
            receivedData = true
            self.accept(points, checkedAt: startedAt, directory: directory)
            if directory { self.refreshFailed = false }
        }
        if pendingRequests.contains(key) { requests[key] = request }
    }

    /// Request-start time orders concurrent responses; TfL's source timestamp
    /// additionally prevents an older cached response replacing newer counts.
    func accept(_ points: [BikePoint], checkedAt: Date, directory: Bool = false) {
        var next = snapshot
        var acceptedIDs: Set<String> = []
        if directory, !points.isEmpty {
            let incomingIDs = Set(points.map(\.id))
            for id in next.bikePointsByID.keys where !incomingIDs.contains(id)
                && (next.checkedAtByID[id] ?? .distantPast) < checkedAt {
                next.bikePointsByID.removeValue(forKey: id)
                next.checkedAtByID.removeValue(forKey: id)
            }
        }
        for point in points {
            if let previousCheck = next.checkedAtByID[point.id], checkedAt < previousCheck { continue }
            if let existing = next.bikePointsByID[point.id],
               let oldModified = existing.availabilityDataModifiedAt,
               let incomingModified = point.availabilityDataModifiedAt,
               incomingModified < oldModified { continue }
            // A later targeted response wins a tie with the directory.
            if directory, let previousCheck = next.checkedAtByID[point.id], checkedAt == previousCheck { continue }
            next.bikePointsByID[point.id] = point
            next.checkedAtByID[point.id] = checkedAt
            acceptedIDs.insert(point.id)
        }
        if directory, !points.isEmpty {
            next.directoryCheckedAt = max(next.directoryCheckedAt ?? .distantPast, checkedAt)
        }
        for (id, counts) in pushedCounts {
            if apply(counts, to: id, in: &next) { acceptedIDs.insert(id) }
        }
        for (id, spaces) in pushedSpaces {
            applySpaces(spaces.spaces, checkedAt: spaces.checkedAt, id: id, in: &next)
        }
        snapshot = next
        persist(next)
        let accepted = acceptedIDs.compactMap { next.bikePointsByID[$0] }
        if !accepted.isEmpty { didAccept(accepted) }
    }

    func acceptPushedCounts(id: String, standardBikes: Int, eBikes: Int, spaces: Int, checkedAt: Date) {
        if let previous = pushedCounts[id], previous.checkedAt >= checkedAt { return }
        let counts = PushedCounts(standardBikes: standardBikes, eBikes: eBikes, spaces: spaces, checkedAt: checkedAt)
        pushedCounts[id] = counts
        var next = snapshot
        guard apply(counts, to: id, in: &next) else { return }
        if let spaces = pushedSpaces[id] {
            applySpaces(spaces.spaces, checkedAt: spaces.checkedAt, id: id, in: &next)
        }
        snapshot = next
        persist(next)
        // Do not echo an ActivityKit content update back into ActivityKit.
    }

    func acceptPushedSpaces(id: String, spaces: Int, checkedAt: Date) {
        guard checkedAt > (pushedSpaces[id]?.checkedAt ?? .distantPast) else { return }
        pushedSpaces[id] = (spaces, checkedAt)
        var next = snapshot
        applySpaces(spaces, checkedAt: checkedAt, id: id, in: &next)
        snapshot = next
        persist(next)
    }

    private func applySpaces(_ spaces: Int, checkedAt: Date, id: String, in next: inout Snapshot) {
        guard let point = next.bikePointsByID[id],
              checkedAt > (next.checkedAtByID[id] ?? .distantPast) else { return }
        let properties = point.additionalProperties.filter { $0.key != "NbEmptyDocks" }
            + [AdditionalProperty(key: "NbEmptyDocks", value: String(spaces))]
        next.bikePointsByID[id] = BikePoint(id: point.id, commonName: point.commonName,
            lat: point.lat, lon: point.lon, additionalProperties: properties)
    }

    private func apply(_ counts: PushedCounts, to id: String, in next: inout Snapshot) -> Bool {
        guard let point = next.bikePointsByID[id],
              counts.checkedAt > (next.checkedAtByID[id] ?? .distantPast) else { return false }
        let values = ["NbStandardBikes": counts.standardBikes, "NbEBikes": counts.eBikes,
                      "NbBikes": counts.standardBikes + counts.eBikes, "NbEmptyDocks": counts.spaces]
        let properties = point.additionalProperties.filter { values[$0.key] == nil }
            + values.map { AdditionalProperty(key: $0.key, value: String($0.value)) }
        next.bikePointsByID[id] = BikePoint(id: point.id, commonName: point.commonName,
            lat: point.lat, lon: point.lon, additionalProperties: properties)
        next.checkedAtByID[id] = counts.checkedAt
        return true
    }

    func handleScenePhase(_ phase: ScenePhase) {
        isActive = phase == .active
        timer?.invalidate()
        timer = nil
        if isActive {
            refresh(force: true)
            refreshImportantDocks()
            timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.refreshImportantDocks()
                }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } else if phase == .background {
            cancelRequests()
        }
    }

    private func refreshImportantDocks() {
        let ids = FavoritesService.shared.favorites.map(\.id)
            + LiveActivityService.shared.activeActivities.values.flatMap { activity in
                [activity.content.state.resolvedDockId ?? activity.attributes.dockId]
                    + activity.content.state.alternatives.compactMap(\.id)
                    + [activity.content.state.destinationAvailability?.id].compactMap { $0 }
            }
        let location = LocationService.shared.location
        let nearbyIDs = ids.filter { id in
            guard let point = snapshot.bikePointsByID[id], let location,
                  location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
                  abs(location.timestamp.timeIntervalSinceNow) <= 60 else { return false }
            return location.distance(from: CLLocation(latitude: point.lat, longitude: point.lon))
                <= AppConstants.App.nearbyDockDistanceMeters
        }
        refresh(dockIDs: ids)
        refresh(dockIDs: nearbyIDs, maxAge: AppConstants.App.nearbyDockRefreshInterval)
    }

    func cancelRequests() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        pendingRequests.removeAll()
        isRefreshing = false
    }

    deinit { timer?.invalidate() }
}
