import AppIntents
import SwiftUI

struct GetSpacesAtDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Spaces at Destination"
    static var description = IntentDescription("Check spaces at your active journey's destination, or your saved Siri destination. The dock is resolved each time.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let answer = try await SiriAvailabilityRuntime.lookup(.spaces)
        return .result(value: answer.count, dialog: IntentDialog(stringLiteral: answer.dialog), view: SiriAvailabilityCard(answer: answer))
    }
}

struct GetBikesAtStartIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Bikes at Start"
    static var description = IntentDescription("Check all bikes at your active journey's start dock, or your nearest favourite when no journey is active. Location is needed only for the nearest favourite.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let answer = try await SiriAvailabilityRuntime.lookup(.bikes)
        return .result(value: answer.count, dialog: IntentDialog(stringLiteral: answer.dialog), view: SiriAvailabilityCard(answer: answer))
    }
}

struct GetSpacesAtDockIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Spaces at Dock"
    static var description = IntentDescription("Check spaces at a specific dock without changing your journey.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Dock") var dock: BikeDockEntity
    static var parameterSummary: some ParameterSummary { Summary("Get spaces at \(\.$dock)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let answer = try await SiriAvailabilityRuntime.lookup(.spaces, explicit: dock.dock)
        return .result(value: answer.count, dialog: IntentDialog(stringLiteral: answer.dialog), view: SiriAvailabilityCard(answer: answer))
    }
}

struct GetBikesAtDockIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Bikes at Dock"
    static var description = IntentDescription("Check all bikes at a specific dock without changing your journey.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Dock") var dock: BikeDockEntity
    static var parameterSummary: some ParameterSummary { Summary("Get bikes at \(\.$dock)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let answer = try await SiriAvailabilityRuntime.lookup(.bikes, explicit: dock.dock)
        return .result(value: answer.count, dialog: IntentDialog(stringLiteral: answer.dialog), view: SiriAvailabilityCard(answer: answer))
    }
}

struct BikeDockEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dock")
    static var defaultQuery = BikeDockQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    var dock: JourneyDock { JourneyDock(id: id, name: name) }
}

struct BikeDockQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BikeDockEntity] {
        // Retain valid saved identities when offline or removed; perform() reports lookup failure.
        // Never replace a saved Shortcut's station with a new search result.
        let snapshot = JourneyDataSource.siriSnapshot()
        let known = snapshot.favorites + [snapshot.active?.startDock, snapshot.active?.destinationDock, snapshot.siriDestination].compactMap { $0 }
        return identifiers.filter(SiriDockResolver.isValidID).map { id in
            BikeDockEntity(id: id, name: known.first { $0.id == id }?.name ?? String(localized: "Saved dock"))
        }
    }

    func entities(matching string: String) async throws -> [BikeDockEntity] {
        let docks = try await JourneyDataSource.siriDockCatalogue()
        return docks.filter { $0.name.localizedCaseInsensitiveContains(string) }
            .sorted { $0.name < $1.name }.prefix(50).map { BikeDockEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [BikeDockEntity] {
        JourneyDataSource.siriSnapshot().favorites.map { BikeDockEntity(id: $0.id, name: $0.name) }
    }
}

struct BikeSpotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetSpacesAtDestinationIntent(), phrases: [
            "How many spaces in \(.applicationName)",
            "Check destination spaces in \(.applicationName)"
        ], shortTitle: "Destination spaces", systemImageName: "parkingsign.circle")
        AppShortcut(intent: GetBikesAtStartIntent(), phrases: [
            "How many bikes in \(.applicationName)",
            "Check start dock bikes in \(.applicationName)"
        ], shortTitle: "Start dock bikes", systemImageName: "bicycle")
    }
}

struct SiriAvailabilityCard: View {
    let answer: SiriAvailabilityAnswer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.count, format: .number).font(.largeTitle.bold())
            Text(answer.metric == .spaces ? "Spaces" : "Bikes").font(.headline)
            Text(answer.name).font(.headline)
            if !answer.role.isEmpty { Text(answer.role).font(.subheadline) }
            Text("TfL report · Checked \(answer.checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(answer.dialog)
    }
}
