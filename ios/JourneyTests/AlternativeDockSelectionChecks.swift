import Foundation

struct AlternativeDockSettings {
    static let suiteName = "AlternativeDisplayChecks-" + UUID().uuidString
    static let userDefaultsStore = UserDefaults(suiteName: suiteName)!
    static let enabledKey = "enabled"
    static let minBikesKey = "minBikes"
    static let minEBikesKey = "minEBikes"
    static let minSpacesKey = "minSpaces"
    static let maxCountKey = "maxCount"
    static let useMinimumThresholdsKey = "thresholds"
    static let defaultEnabled = true
    static let defaultMinBikes = 2
    static let defaultMinEBikes = 1
    static let defaultMinSpaces = 2
    static let defaultMaxAlternatives = 3
    static let defaultUseMinimumThresholds = false
}
final class DockPreferencesService {
    static let shared = DockPreferencesService()
    var custom: [String: [String]] = [:]
    func customDockIDs(for id: String) -> [String]? { custom[id] }
}
func point(_ id: String, latitude: Double, bikes: Int) -> BikePoint {
    let values = ["Installed":"true", "Locked":"false", "NbStandardBikes":String(bikes), "NbEBikes":"0", "NbEmptyDocks":"10", "NbDocks":String(bikes + 10)]
    let json: [String: Any] = ["id":id, "commonName":id, "lat":latitude, "lon":-0.1,
        "additionalProperties":values.map { ["key":$0.key, "value":$0.value] }]
    return try! JSONDecoder().decode(BikePoint.self, from: JSONSerialization.data(withJSONObject: json))
}
@main struct Checks {
    static func main() {
        defer { AlternativeDockSettings.userDefaultsStore.removePersistentDomain(forName: AlternativeDockSettings.suiteName) }
        let primary = point("primary", latitude: 51.5, bikes: 0)
        let near = point("near", latitude: 51.5001, bikes: 5)
        let middle = point("middle", latitude: 51.5002, bikes: 5)
        let far = point("far", latitude: 51.51, bikes: 5)
        let zero = point("zero", latitude: 51.50005, bikes: 0)
        let extra = point("extra", latitude: 51.52, bikes: 5)
        let missing = ScheduledJourneyDock(id: "missing", name: "Missing", latitude: 51.53, longitude: -0.1)
        let saved = [far, near, zero].map { ScheduledJourneyDock(bikePoint: $0) } + [missing, ScheduledJourneyDock(bikePoint: near)]
        let all = [far, primary, middle, zero, near, extra]
        let preview = AlternativeDockSelectionService.savedAlternativesForFavorites(for: primary.id, savedDocks: saved, allBikePoints: all, showAll: false)
        precondition(preview.map(\.id) == ["far", "near", "zero"], "Custom preview preserves chosen order and zero availability")
        let expanded = AlternativeDockSelectionService.savedAlternativesForFavorites(for: primary.id, savedDocks: saved, allBikePoints: all, showAll: true)
        precondition(expanded.map(\.id) == ["far", "near", "zero", "missing"], "See all includes missing docks without duplicates")
        precondition(expanded.last!.additionalProperties.isEmpty, "Unknown availability must remain unknown")
        precondition(AlternativeDockSelectionService.savedAlternativesForFavorites(for: primary.id, savedDocks: [], allBikePoints: all, showAll: true).isEmpty)
        let automatic = AlternativeDockSelectionService.alternatives(for: primary, allBikePoints: all, favorites: [], userLocation: nil, purpose: .bikes, forceShow: true, maximumCount: 20)
        precondition(automatic.prefix(3).map(\.id) == ["near", "middle", "far"], "Automatic preview is the nearest eligible three")
        precondition(automatic.count == 4, "See all contains alternatives beyond the preview")
        let other = AlternativeDockSelectionService.otherNearbyDocks(
            for: primary, allBikePoints: all + [middle, near], excludingDockIDs: Set(saved.map(\.id)))
        precondition(other.map(\.id) == ["middle", "extra"], "Other docks exclude custom choices and primary, deduplicate and sort closest first")
        let browseZero = AlternativeDockSelectionService.otherNearbyDocks(
            for: primary, allBikePoints: all, excludingDockIDs: [])
        precondition(browseZero.first?.id == "zero", "Browsing includes zero availability so users can inspect nearby docks")
        let many = (1...30).reversed().map { point("dock-\($0)", latitude: 51.5 + Double($0) / 10000, bikes: 5) }
        let limited = AlternativeDockSelectionService.otherNearbyDocks(
            for: primary, allBikePoints: many + many, excludingDockIDs: ["dock-1"])
        precondition(limited.count == 20 && Set(limited.map(\.id)).count == 20)
        precondition(limited.first?.id == "dock-2" && limited.last?.id == "dock-21", "The limit is applied after sorting and deduplication")
        let unavailable = BikePoint(id: "unavailable", commonName: "Unavailable", lat: 51.5, lon: -0.1)
        precondition(AlternativeDockSelectionService.otherNearbyDocks(for: primary, allBikePoints: [unavailable], excludingDockIDs: []).isEmpty)
        let tieB = point("tie-b", latitude: 51.5001, bikes: 2)
        let tieA = point("tie-a", latitude: 51.5001, bikes: 2)
        precondition(AlternativeDockSelectionService.otherNearbyDocks(for: primary, allBikePoints: [tieB, tieA], excludingDockIDs: []).map(\.id) == ["tie-a", "tie-b"])
        precondition(AlternativeDockSelectionService.savedAlternativesForFavorites(for: primary.id, savedDocks: saved, allBikePoints: all, showAll: true).map(\.id) == expanded.map(\.id), "Browsing never changes custom order")
        print("Passed alternative checks: custom order, empty/missing data, nearest-first browsing, exclusions, duplicates, stable ties and 20-dock limit")
    }
}
