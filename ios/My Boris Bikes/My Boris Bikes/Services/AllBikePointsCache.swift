import Foundation

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
        guard let fileURL = fileURL else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode([BikePoint].self, from: data)
        } catch {
            print("AllBikePointsCache: Failed to decode cache: \(error)")
            return []
        }
    }

    func save(_ bikePoints: [BikePoint]) {
        guard let fileURL = fileURL else { return }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(bikePoints)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("AllBikePointsCache: Failed to save cache: \(error)")
        }
    }
}
