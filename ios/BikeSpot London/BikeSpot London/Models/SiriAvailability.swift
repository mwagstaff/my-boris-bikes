import Foundation

enum SiriAvailabilityMetric: Sendable { case bikes, spaces }

struct SiriAvailabilityError: LocalizedError, CustomLocalizedStringResourceConvertible, Equatable {
    let message: String
    var errorDescription: String? { message }
    // Siri consumes the error outside this process; LocalizedError alone bridges as an unknown NSError.
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct SiriResolvedDock: Equatable, Sendable {
    enum Source: Sendable { case start, destination, savedDestination, favorite, explicit }
    let dock: JourneyDock
    let source: Source
    let revision: Date
    let lastSynced: Bool

    var spokenName: String { dock.name.isEmpty ? String(localized: "the selected dock") : dock.name }
    var role: String {
        switch source {
        case .start: return lastSynced ? String(localized: "your last synced start dock") : String(localized: "your start dock")
        case .destination: return lastSynced ? String(localized: "your last synced destination") : String(localized: "your destination")
        case .savedDestination: return lastSynced ? String(localized: "your last synced saved destination") : String(localized: "your saved destination")
        case .favorite: return lastSynced ? String(localized: "the nearest of your last synced favourites") : String(localized: "your nearest favourite dock")
        case .explicit: return ""
        }
    }
}

enum SiriDockResolver {
    static func resolve(metric: SiriAvailabilityMetric, snapshot: JourneySnapshot, location: JourneyLocation?,
                        explicit: JourneyDock? = nil, now: Date, lastSynced: Bool = false) throws -> SiriResolvedDock {
        if let explicit { return try selection(explicit, source: .explicit, revision: .distantPast, lastSynced: false) }
        guard snapshot.siriHasAmbiguousJourney != true else {
            throw SiriAvailabilityError(message: String(localized: "Choose one current journey in BikeSpot London before checking availability."))
        }
        guard snapshot.siriHasUnresolvedJourney != true else {
            throw SiriAvailabilityError(message: String(localized: "Your current journey's docks are unavailable. Update the journey in BikeSpot London."))
        }
        if let active = snapshot.active, active.expiresAt > now {
            return try selection(metric == .bikes ? active.startDock : active.destinationDock,
                                 source: metric == .bikes ? .start : .destination,
                                 revision: snapshot.generatedAt, lastSynced: lastSynced)
        }
        if metric == .spaces {
            guard let dock = snapshot.siriDestination else {
                throw SiriAvailabilityError(message: String(localized: "You haven't selected a destination dock in BikeSpot London. Set one in Siri & Shortcuts or start a journey."))
            }
            return try selection(dock, source: .savedDestination, revision: snapshot.generatedAt, lastSynced: lastSynced)
        }
        guard !snapshot.favorites.isEmpty else {
            throw SiriAvailabilityError(message: String(localized: "Add a favourite dock in BikeSpot London or start a journey before checking bikes."))
        }
        guard let location, location.isUsable(at: now) else {
            throw SiriAvailabilityError(message: String(localized: "I couldn't find your nearest favourite. Allow location in BikeSpot London and try again, or start a journey."))
        }
        // Missing coordinates could hide the nearest favourite. Never choose an arbitrary subset.
        guard snapshot.favorites.allSatisfy({ $0.coordinate?.isValid == true }) else {
            throw SiriAvailabilityError(message: String(localized: "I couldn't locate your favourite docks. Open BikeSpot London to refresh them."))
        }
        let dock = snapshot.favorites.min {
            let a = location.coordinate.distance(to: $0.coordinate!)
            let b = location.coordinate.distance(to: $1.coordinate!)
            return a == b ? $0.id < $1.id : a < b
        }!
        return try selection(dock, source: .favorite, revision: snapshot.generatedAt, lastSynced: lastSynced)
    }

    static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("BikePoints_") && !id.dropFirst("BikePoints_".count).isEmpty
            && id.dropFirst("BikePoints_".count).allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func selection(_ dock: JourneyDock, source: SiriResolvedDock.Source,
                                  revision: Date, lastSynced: Bool) throws -> SiriResolvedDock {
        guard isValidID(dock.id) else {
            throw SiriAvailabilityError(message: String(localized: "The selected dock is unavailable. Update it in BikeSpot London."))
        }
        return SiriResolvedDock(dock: dock, source: source, revision: revision, lastSynced: lastSynced)
    }
}

/// A direct TfL retrieval, with HTTP cache age kept separately from property-change metadata.
struct SiriAvailabilityReport: Sendable {
    let point: APIJourneyDock
    let receivedAt: Date
    let retrievedAt: Date

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(retrievedAt)
        return age >= -5 && age <= 30
    }
}

struct SiriAvailabilityAnswer: Sendable {
    let count: Int
    let metric: SiriAvailabilityMetric
    let name: String
    let role: String
    let checkedAt: Date
    let dialog: String
}

enum SiriAvailabilityFormatter {
    static func answer(report: SiriAvailabilityReport, selection: SiriResolvedDock,
                       metric: SiriAvailabilityMetric, now: Date) throws -> SiriAvailabilityAnswer {
        let point = report.point
        guard point.id == selection.dock.id else {
            throw SiriAvailabilityError(message: String(localized: "TfL returned a different dock. I couldn't check the selected dock."))
        }
        let name = point.commonName.isEmpty ? selection.spokenName : point.commonName
        guard report.isFresh(at: now) else {
            throw SiriAvailabilityError(message: String(localized: "I couldn't get current availability at \(name). The available report is stale."))
        }
        guard point.isAvailable else {
            throw SiriAvailabilityError(message: String(localized: "\(name) is currently unavailable."))
        }
        guard let count = point.count(metric == .bikes ? "NbBikes" : "NbEmptyDocks") else {
            let message = metric == .bikes
                ? String(localized: "The bike count for \(name) is unavailable.")
                : String(localized: "The space count for \(name) is unavailable.")
            throw SiriAvailabilityError(message: message)
        }
        let subject = selection.role.isEmpty ? name : String(localized: "\(name), \(selection.role)")
        let dialog: String
        // TfL property 'modified' is not an observation timestamp. Always attribute the report.
        if metric == .spaces {
            if count == 0 { dialog = String(localized: "TfL reports no spaces at \(subject).") }
            else if count == 1 { dialog = String(localized: "TfL reports one space at \(subject).") }
            else { dialog = String(localized: "TfL reports \(count) spaces at \(subject).") }
        } else {
            let electric = point.trustworthyElectricBikes
            if count == 0 { dialog = String(localized: "TfL reports no bikes at \(subject).") }
            else if electric == count {
                dialog = count == 1 ? String(localized: "TfL reports one bike at \(subject), all electric.")
                    : String(localized: "TfL reports \(count) bikes at \(subject), all electric.")
            } else if let electric, electric > 0 {
                dialog = electric == 1
                    ? String(localized: "TfL reports \(count) bikes at \(subject), including one electric bike.")
                    : String(localized: "TfL reports \(count) bikes at \(subject), including \(electric) electric bikes.")
            } else {
                dialog = count == 1 ? String(localized: "TfL reports one bike at \(subject).")
                    : String(localized: "TfL reports \(count) bikes at \(subject).")
            }
        }
        return SiriAvailabilityAnswer(count: count, metric: metric, name: name, role: selection.role,
                                      checkedAt: report.retrievedAt, dialog: dialog)
    }
}

/// Injected seams keep cold invocation, selection races, time and provider failures testable.
struct SiriAvailabilityService {
    var now: () -> Date = Date.init
    var resolve: () throws -> SiriResolvedDock
    var fetch: (String, TimeInterval) async throws -> SiriAvailabilityReport

    func lookup(metric: SiriAvailabilityMetric, deadline: Date? = nil) async throws -> SiriAvailabilityAnswer {
        let deadline = deadline ?? now().addingTimeInterval(8)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let selected = try resolve()
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { throw failure(selected) }
            let report: SiriAvailabilityReport
            do { report = try await fetch(selected.dock.id, remaining) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SiriAvailabilityError { throw error }
            catch {
                try Task.checkCancellation()
                throw failure(selected)
            }
            try Task.checkCancellation()
            guard now() <= deadline else { throw failure(selected) }
            guard try resolve() == selected else {
                if attempt == 0 { continue }
                throw SiriAvailabilityError(message: String(localized: "Your dock selection changed. Please ask again."))
            }
            return try SiriAvailabilityFormatter.answer(report: report, selection: selected, metric: metric, now: now())
        }
        throw SiriAvailabilityError(message: String(localized: "Your dock selection changed. Please ask again."))
    }

    private func failure(_ selection: SiriResolvedDock) -> SiriAvailabilityError {
        SiriAvailabilityError(message: String(localized: "I couldn't check availability at \(selection.spokenName) right now. Please try again."))
    }
}
