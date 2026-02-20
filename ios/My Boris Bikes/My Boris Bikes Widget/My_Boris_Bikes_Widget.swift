//
//  My_Boris_Bikes_Widget.swift
//  My Boris Bikes Widget
//
//  Main widget entry point
//

import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    private let appGroup = "group.dev.skynolimit.myborisbikes"
    private let widgetDataKey = "ios_widget_data"
    private let favoritesKey = "favorites"

    /// URLSession with tight timeouts for widget background fetches.
    /// Widget timeline generation has limited time; long requests get killed.
    private static let widgetSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            bikePoints: [
                WidgetBikePointData(
                    id: "1",
                    displayName: "Hyde Park Corner",
                    actualName: "Hyde Park Corner, Hyde Park",
                    standardBikes: 5,
                    eBikes: 3,
                    emptySpaces: 12,
                    distance: 250,
                    lastUpdated: Date()
                )
            ],
            sortMode: "distance",
            lastRefresh: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry: SimpleEntry

        if context.isPreview {
            // Provide sample data for widget gallery
            entry = SimpleEntry(
                date: Date(),
                bikePoints: [
                    WidgetBikePointData(
                        id: "1",
                        displayName: "Hyde Park Corner",
                        actualName: "Hyde Park Corner, Hyde Park",
                        standardBikes: 5,
                        eBikes: 3,
                        emptySpaces: 12,
                        distance: 250,
                        lastUpdated: Date()
                    ),
                    WidgetBikePointData(
                        id: "2",
                        displayName: "Serpentine Car Park",
                        actualName: "Serpentine Car Park, Hyde Park",
                        standardBikes: 8,
                        eBikes: 2,
                        emptySpaces: 10,
                        distance: 450,
                        lastUpdated: Date()
                    )
                ],
                sortMode: "distance",
                lastRefresh: Date()
            )
        } else {
            entry = loadWidgetData()
        }

        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        // Load cached data first so we always have something to show
        let cachedEntry = loadWidgetData()

        // Read the user's favorite IDs from the shared app group
        let favoriteIds = loadFavoriteIds()

        guard !favoriteIds.isEmpty else {
            // No favorites configured — return cached/empty data with multiple future entries
            let timeline = buildTimeline(from: cachedEntry)
            completion(timeline)
            return
        }

        // Attempt a live fetch from the TfL API with a tight timeout.
        // If the fetch succeeds, we update the cache and build entries from fresh data.
        // If it fails, we fall back to the cached snapshot.
        fetchBikePoints(ids: favoriteIds) { freshBikePoints in
            let entry: SimpleEntry
            if let freshBikePoints = freshBikePoints, !freshBikePoints.isEmpty {
                // Build updated widget data from fresh API results
                let updatedEntry = self.buildEntry(from: freshBikePoints, cachedEntry: cachedEntry)
                // Persist the fresh data so the cache stays warm for next time
                self.saveFreshData(entry: updatedEntry)
                entry = updatedEntry
            } else {
                // Fetch failed or returned nothing — use cached data
                entry = cachedEntry
            }

            let timeline = self.buildTimeline(from: entry)
            completion(timeline)
        }
    }

    // MARK: - Timeline building

    /// Builds a timeline with multiple future entries so the widget stays
    /// populated even if iOS delays the next timeline request.
    /// Uses .atEnd so iOS requests a new timeline once all entries are consumed.
    private func buildTimeline(from entry: SimpleEntry) -> Timeline<SimpleEntry> {
        let now = Date()
        var entries: [SimpleEntry] = []

        // Generate entries at 15-minute intervals for up to 2 hours.
        // Each entry carries the same data but with an updated `date` so
        // the refresh-status text stays accurate.
        let intervalMinutes = 15
        let entryCount = 8 // 8 × 15 min = 2 hours of coverage
        for i in 0..<entryCount {
            let entryDate = Calendar.current.date(byAdding: .minute, value: i * intervalMinutes, to: now)!
            entries.append(SimpleEntry(
                date: entryDate,
                bikePoints: entry.bikePoints,
                sortMode: entry.sortMode,
                lastRefresh: entry.lastRefresh
            ))
        }

        // .atEnd tells iOS to call getTimeline again after the last entry's date,
        // which keeps the refresh cycle going indefinitely.
        return Timeline(entries: entries, policy: .atEnd)
    }

    // MARK: - Live API fetch

    /// Fetches individual bike point data from the TfL Place API.
    /// Uses async/await internally, bridged to a callback for WidgetKit compatibility.
    private func fetchBikePoints(ids: [String], completion: @escaping ([BikePoint]?) -> Void) {
        Task {
            do {
                let bikePoints = try await withThrowingTaskGroup(of: BikePoint?.self, returning: [BikePoint].self) { group in
                    for id in ids {
                        group.addTask {
                            try await self.fetchSingleBikePoint(id: id)
                        }
                    }
                    var results: [BikePoint] = []
                    for try await bikePoint in group {
                        if let bikePoint = bikePoint {
                            results.append(bikePoint)
                        }
                    }
                    return results
                }
                completion(bikePoints)
            } catch {
                print("Widget: Live fetch failed: \(error)")
                completion(nil)
            }
        }
    }

    private func fetchSingleBikePoint(id: String) async throws -> BikePoint? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let urlString = "https://api.tfl.gov.uk/Place/\(id)?cb=\(timestamp)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, _) = try await Self.widgetSession.data(for: request)
        return try? JSONDecoder().decode(BikePoint.self, from: data)
    }

    // MARK: - Build entry from fresh data

    /// Merges fresh API data with cached metadata (display names, distances, etc.)
    private func buildEntry(from freshBikePoints: [BikePoint], cachedEntry: SimpleEntry) -> SimpleEntry {
        let cachedById = Dictionary(uniqueKeysWithValues: cachedEntry.bikePoints.map { ($0.id, $0) })
        let favorites = loadFavorites()
        let favoritesById = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, $0) })
        let freshById = Dictionary(uniqueKeysWithValues: freshBikePoints.map { ($0.id, $0) })

        var updatedBikePoints: [WidgetBikePointData] = []

        if cachedEntry.bikePoints.isEmpty {
            for bikePoint in freshBikePoints {
                let displayName: String
                if let favorite = favoritesById[bikePoint.id] {
                    displayName = favorite.displayName
                } else {
                    displayName = bikePoint.commonName
                }

                updatedBikePoints.append(WidgetBikePointData(
                    id: bikePoint.id,
                    displayName: displayName,
                    actualName: bikePoint.commonName,
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    distance: nil,
                    lastUpdated: Date()
                ))
            }
        } else {
            for cached in cachedEntry.bikePoints {
                if cached.isAlternative {
                    updatedBikePoints.append(cached)
                    continue
                }

                guard let fresh = freshById[cached.id] else {
                    updatedBikePoints.append(cached)
                    continue
                }

                let displayName: String
                if let favorite = favoritesById[fresh.id] {
                    displayName = favorite.displayName
                } else {
                    displayName = cached.displayName
                }

                updatedBikePoints.append(WidgetBikePointData(
                    id: fresh.id,
                    displayName: displayName,
                    actualName: fresh.commonName,
                    standardBikes: fresh.standardBikes,
                    eBikes: fresh.eBikes,
                    emptySpaces: fresh.emptyDocks,
                    distance: cached.distance,
                    lastUpdated: Date(),
                    isAlternative: false,
                    parentFavoriteId: nil
                ))
            }

            for bikePoint in freshBikePoints where cachedById[bikePoint.id] == nil {
                let displayName: String
                if let favorite = favoritesById[bikePoint.id] {
                    displayName = favorite.displayName
                } else {
                    displayName = bikePoint.commonName
                }

                updatedBikePoints.append(WidgetBikePointData(
                    id: bikePoint.id,
                    displayName: displayName,
                    actualName: bikePoint.commonName,
                    standardBikes: bikePoint.standardBikes,
                    eBikes: bikePoint.eBikes,
                    emptySpaces: bikePoint.emptyDocks,
                    distance: nil,
                    lastUpdated: Date()
                ))
            }
        }

        return SimpleEntry(
            date: Date(),
            bikePoints: updatedBikePoints,
            sortMode: cachedEntry.sortMode,
            lastRefresh: Date()
        )
    }

    // MARK: - Persistence

    /// Saves freshly fetched data back to the app group so subsequent
    /// cache reads (including getSnapshot) see the updated values.
    private func saveFreshData(entry: SimpleEntry) {
        guard let userDefaults = UserDefaults(suiteName: appGroup) else { return }

        let widgetData = WidgetData(
            bikePoints: entry.bikePoints,
            sortMode: entry.sortMode,
            lastRefresh: entry.lastRefresh ?? Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(widgetData)
            userDefaults.set(encoded, forKey: widgetDataKey)
            userDefaults.synchronize()
            print("Widget: Saved fresh data to app group cache")
        } catch {
            print("Widget: Failed to save fresh data: \(error)")
        }
    }

    // MARK: - Load cached / favorites

    private func loadWidgetData() -> SimpleEntry {
        print("Widget: Loading widget data from app group")

        guard let userDefaults = UserDefaults(suiteName: appGroup) else {
            print("Widget: Failed to access app group UserDefaults")
            return SimpleEntry(date: Date(), bikePoints: [], sortMode: "distance", lastRefresh: nil)
        }

        guard let data = userDefaults.data(forKey: widgetDataKey) else {
            print("Widget: No data found for key \(widgetDataKey)")
            return SimpleEntry(date: Date(), bikePoints: [], sortMode: "distance", lastRefresh: nil)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let widgetData = try decoder.decode(WidgetData.self, from: data)

            print("Widget: Successfully loaded \(widgetData.bikePoints.count) bike points")

            return SimpleEntry(
                date: Date(),
                bikePoints: widgetData.bikePoints,
                sortMode: widgetData.sortMode,
                lastRefresh: widgetData.lastRefresh
            )
        } catch {
            print("Widget: Failed to decode widget data: \(error)")
            return SimpleEntry(date: Date(), bikePoints: [], sortMode: "distance", lastRefresh: nil)
        }
    }

    /// Loads the user's favorite IDs from the shared app group.
    private func loadFavoriteIds() -> [String] {
        loadFavorites().map { $0.id }
    }

    /// Loads the full favorites list from the shared app group.
    private func loadFavorites() -> [WidgetFavorite] {
        guard let userDefaults = UserDefaults(suiteName: appGroup),
              let data = userDefaults.data(forKey: favoritesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([WidgetFavorite].self, from: data)) ?? []
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let bikePoints: [WidgetBikePointData]
    let sortMode: String
    let lastRefresh: Date?
}

struct My_Boris_Bikes_WidgetEntryView : View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        case .systemExtraLarge:
            LargeWidgetView(entry: entry) // Use large view for extra large
        @unknown default:
            MediumWidgetView(entry: entry)
        }
    }
}

@main
struct My_Boris_Bikes_WidgetBundle: WidgetBundle {
    var body: some Widget {
        My_Boris_Bikes_Widget()
        My_Boris_Bikes_WidgetLiveActivity()
    }
}

struct My_Boris_Bikes_Widget: Widget {
    let kind: String = "My_Boris_Bikes_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            My_Boris_Bikes_WidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("My Boris Bikes")
        .description("View your favorite bike docks at a glance")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemSmall) {
    My_Boris_Bikes_Widget()
} timeline: {
    SimpleEntry(
        date: Date(),
        bikePoints: [
            WidgetBikePointData(
                id: "1",
                displayName: "Hyde Park Corner",
                actualName: "Hyde Park Corner, Hyde Park",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 250,
                lastUpdated: Date()
            )
        ],
        sortMode: "distance",
        lastRefresh: Date()
    )
}

#Preview(as: .systemMedium) {
    My_Boris_Bikes_Widget()
} timeline: {
    SimpleEntry(
        date: Date(),
        bikePoints: [
            WidgetBikePointData(
                id: "1",
                displayName: "Hyde Park Corner",
                actualName: "Hyde Park Corner, Hyde Park",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 250,
                lastUpdated: Date()
            ),
            WidgetBikePointData(
                id: "2",
                displayName: "Serpentine Car Park",
                actualName: "Serpentine Car Park, Hyde Park",
                standardBikes: 8,
                eBikes: 2,
                emptySpaces: 10,
                distance: 450,
                lastUpdated: Date()
            )
        ],
        sortMode: "distance",
        lastRefresh: Date()
    )
}

#Preview(as: .systemLarge) {
    My_Boris_Bikes_Widget()
} timeline: {
    SimpleEntry(
        date: Date(),
        bikePoints: [
            WidgetBikePointData(
                id: "1",
                displayName: "Hyde Park Corner",
                actualName: "Hyde Park Corner, Hyde Park",
                standardBikes: 5,
                eBikes: 3,
                emptySpaces: 12,
                distance: 250,
                lastUpdated: Date()
            ),
            WidgetBikePointData(
                id: "2",
                displayName: "Serpentine Car Park",
                actualName: "Serpentine Car Park, Hyde Park",
                standardBikes: 8,
                eBikes: 2,
                emptySpaces: 10,
                distance: 450,
                lastUpdated: Date()
            ),
            WidgetBikePointData(
                id: "3",
                displayName: "Wellington Arch",
                actualName: "Wellington Arch, Hyde Park Corner",
                standardBikes: 3,
                eBikes: 5,
                emptySpaces: 15,
                distance: 680,
                lastUpdated: Date()
            )
        ],
        sortMode: "distance",
        lastRefresh: Date()
    )
}
