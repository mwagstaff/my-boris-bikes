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
