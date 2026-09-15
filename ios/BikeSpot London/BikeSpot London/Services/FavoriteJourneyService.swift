import Combine
import Foundation

@MainActor
final class FavoriteJourneyService: ObservableObject {
    static let shared = FavoriteJourneyService()

    @Published private(set) var journeys: [FavoriteJourney] = []

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = AppConstants.UserDefaults.sharedDefaults) {
        self.userDefaults = userDefaults
        load()
    }

    func add(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) {
        guard !isFavorite(startDock: startDock, endDock: endDock) else { return }
        journeys.append(FavoriteJourney(startDock: startDock, endDock: endDock))
        persist()
    }

    func remove(_ journey: FavoriteJourney) {
        journeys.removeAll { $0.id == journey.id }
        persist()
    }

    func toggle(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) {
        if isFavorite(startDock: startDock, endDock: endDock) {
            journeys.removeAll { $0.matches(startDock: startDock, endDock: endDock) }
            persist()
        } else {
            add(startDock: startDock, endDock: endDock)
        }
    }

    func isFavorite(startDock: ScheduledJourneyDock, endDock: ScheduledJourneyDock) -> Bool {
        journeys.contains { $0.matches(startDock: startDock, endDock: endDock) }
    }

    private func load() {
        guard let data = userDefaults.data(forKey: AppConstants.UserDefaults.favoriteJourneysKey) else { return }
        journeys = (try? decoder.decode([FavoriteJourney].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? encoder.encode(journeys) else { return }
        userDefaults.set(data, forKey: AppConstants.UserDefaults.favoriteJourneysKey)
        FavoritesService.shared.forceSyncWithWatch()
    }
}
