import Combine
import Foundation

@MainActor
final class JourneyHistoryService: ObservableObject {
    static let shared = JourneyHistoryService()
    @Published private(set) var entries: [JourneyHistoryEntry] = []
    private let defaults: UserDefaults
    private let key = "journeyRunHistory"
    private let removedKey = "removedJourneyHistoryIDs"
    private var removedIDs: Set<String> = []

    init(defaults: UserDefaults = AppConstants.UserDefaults.sharedDefaults) {
        self.defaults = defaults
        removedIDs = Set(defaults.stringArray(forKey: removedKey) ?? [])
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([JourneyHistoryEntry].self, from: data) {
            entries = saved.filter { !removedIDs.contains($0.id) }
        }
    }

    func record(id: String, journeyID: String, start: ScheduledJourneyDock, end: ScheduledJourneyDock,
                startedAt: Date, kind: JourneyHistoryEntry.Kind, endedAt: Date? = nil) {
        guard !removedIDs.contains(id), !entries.contains(where: { $0.id == id }) else { return }
        entries.append(JourneyHistoryEntry(id: id, journeyID: journeyID, startDock: start,
            endDock: end, startedAt: startedAt, endedAt: endedAt, kind: kind))
        entries.sort { $0.startedAt > $1.startedAt }
        persist()
    }

    func finish(journeyID: String, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.journeyID == journeyID && $0.endedAt == nil }) else { return }
        entries[index].endedAt = max(date, entries[index].startedAt)
        persist()
    }

    func merge(_ records: [JourneyHistoryEntry]) {
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for record in records where !removedIDs.contains(record.id) { byID[record.id] = record }
        entries = byID.values.sorted { $0.startedAt > $1.startedAt }
        persist()
    }

    func remove(_ entry: JourneyHistoryEntry) {
        removedIDs.insert(entry.id)
        defaults.set(Array(removedIDs), forKey: removedKey)
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
