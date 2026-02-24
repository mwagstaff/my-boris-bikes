import Foundation

struct AllBikePointsSnapshot {
    let bikePoints: [BikePoint]
    let savedAt: Date?
}

final class AllBikePointsCache {
    static let shared = AllBikePointsCache()

    private let appGroup = AppConstants.App.appGroup
    private let fileName = "all_bike_points_cache.json"

    private init() {}

    private var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    func load() -> [BikePoint] {
        loadSnapshot()?.bikePoints ?? []
    }

    func loadSnapshot() -> AllBikePointsSnapshot? {
        guard let fileURL = fileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(CachedAllBikePointsPayload.self, from: data) {
            return AllBikePointsSnapshot(
                bikePoints: payload.bikePoints,
                savedAt: payload.savedAt
            )
        }

        if let bikePoints = try? decoder.decode([BikePoint].self, from: data) {
            let savedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return AllBikePointsSnapshot(
                bikePoints: bikePoints,
                savedAt: savedAt
            )
        }

        print("AllBikePointsCache: Failed to decode cache payload")
        return nil
    }

    func save(_ bikePoints: [BikePoint], savedAt: Date = Date()) {
        guard !bikePoints.isEmpty else {
            print("AllBikePointsCache: Skipping save because bike points list is empty")
            return
        }
        guard let fileURL = fileURL else { return }

        do {
            let encoder = JSONEncoder()
            let payload = CachedAllBikePointsPayload(savedAt: savedAt, bikePoints: bikePoints)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("AllBikePointsCache: Failed to save cache: \(error)")
        }
    }
}

private struct CachedAllBikePointsPayload: Codable {
    let savedAt: Date
    let bikePoints: [BikePoint]
}
