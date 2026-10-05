import Foundation

struct JourneyHistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case favourite, scheduled, adHoc
        var title: String {
            switch self {
            case .favourite: return "Favourites"
            case .scheduled: return "Scheduled"
            case .adHoc: return "Ad hoc"
            }
        }
    }

    let id: String
    let journeyID: String
    let startDock: ScheduledJourneyDock
    let endDock: ScheduledJourneyDock
    let startedAt: Date
    var endedAt: Date?
    let kind: Kind

    func hasSchedule(in journeys: [ScheduledJourney]) -> Bool {
        journeys.contains { journey in
            journey.startDock.id == startDock.id && journey.endDock.id == endDock.id
        }
    }

    var dateLabel: String {
        Self.dateLabel(start: startedAt, end: endedAt)
    }

    static func dateLabel(start: Date, end: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, MMM"
        let day = Calendar.current.component(.day, from: start)
        let suffix = (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
        let date = "\(formatter.string(from: start)) \(day)\(suffix)"
        formatter.dateFormat = Calendar.current.isDate(start, equalTo: Date(), toGranularity: .year) ? "HH:mm" : "yyyy HH:mm"
        let beginning = "\(date) \(formatter.string(from: start))"
        guard let end else { return beginning }
        formatter.dateFormat = Calendar.current.isDate(start, inSameDayAs: end) ? "HH:mm" : "EEE, MMM d HH:mm"
        return "\(beginning) – \(formatter.string(from: end))"
    }
}

struct JourneyHistoryMonth: Identifiable {
    let id: Date
    let entries: [JourneyHistoryEntry]
    let count: Int

    var heading: String {
        "\(id.formatted(.dateTime.month(.wide).year())) · \(count) \(count == 1 ? "journey" : "journeys")"
    }

    /// Counts use all matching records, even when only some rows are visible yet.
    static func sections(entries: [JourneyHistoryEntry], filter: JourneyHistoryEntry.Kind?,
                         limit: Int, calendar: Calendar = .current) -> [JourneyHistoryMonth] {
        let matching = entries.filter { filter == nil || $0.kind == filter }
            .sorted { $0.startedAt > $1.startedAt }
        func month(_ entry: JourneyHistoryEntry) -> Date {
            calendar.dateInterval(of: .month, for: entry.startedAt)!.start
        }
        let counts = Dictionary(grouping: matching, by: month).mapValues(\.count)
        let visible = Dictionary(grouping: matching.prefix(max(0, limit)), by: month)
        return visible.keys.sorted(by: >).map {
            JourneyHistoryMonth(id: $0, entries: visible[$0] ?? [], count: counts[$0] ?? 0)
        }
    }
}
