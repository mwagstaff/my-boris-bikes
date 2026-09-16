import Foundation

@main
struct SiriAvailabilityChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        checks += 1
    }
    static func fails(_ label: String, containing: String = "", _ block: () throws -> Void) {
        do { try block(); preconditionFailure(label) }
        catch { check(containing.isEmpty || error.localizedDescription.contains(containing), label) }
    }
    static func point(_ values: [(String, String)] = [], id: String = "BikePoints_1") throws -> APIJourneyDock {
        let properties = values.map { ["key": $0.0, "value": $0.1, "modified": "2000-01-01T00:00:00Z"] }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "commonName": "Synthetic Square", "additionalProperties": properties])
        return try JSONDecoder().decode(APIJourneyDock.self, from: data)
    }
    static func main() async throws {
        let now = Date()
        let a = JourneyDock(id: "BikePoints_1", name: "Synthetic Start", coordinate: .init(latitude: 51.5, longitude: -0.1))
        let b = JourneyDock(id: "BikePoints_2", name: "Synthetic Destination", coordinate: .init(latitude: 51.6, longitude: -0.1))
        var snapshot = JourneySnapshot.empty
        snapshot.generatedAt = now
        snapshot.siriDestination = a
        snapshot.active = JourneyRun(id: "test", phase: .riding, startDock: a, destinationDock: b, startedAt: now, expiresAt: now.addingTimeInterval(3600))
        func resolve(_ metric: SiriAvailabilityMetric, explicit: JourneyDock? = nil, location: JourneyLocation? = nil) throws -> SiriResolvedDock {
            try SiriDockResolver.resolve(metric: metric, snapshot: snapshot, location: location, explicit: explicit, now: now)
        }
        check(try resolve(.bikes).dock.id == a.id, "Bikes always uses start, including riding")
        check(try resolve(.spaces).dock.id == b.id, "Spaces uses destination")
        check(try resolve(.spaces, explicit: a).source == .explicit, "Explicit overrides active")
        snapshot.active?.startDock = b
        check(try resolve(.bikes).dock.id == b.id, "Same start and destination allowed")
        snapshot.active?.destinationDock.id = ""
        fails("Invalid active role never borrows default") { _ = try resolve(.spaces) }
        snapshot.active = nil
        check(try resolve(.spaces).source == .savedDestination, "Default after completion")
        snapshot.siriDestination = nil
        fails("Cleared destination", containing: "haven't selected") { _ = try resolve(.spaces) }
        do {
            _ = try resolve(.spaces)
            preconditionFailure("Missing destination must fail without a count")
        } catch {
            guard let siriError = error as? any CustomLocalizedStringResourceConvertible else {
                preconditionFailure("Siri must receive a localizable error, not an unknown NSError")
            }
            let spokenError = String(localized: siriError.localizedStringResource)
            check(spokenError.contains("haven't selected a destination dock"), "Siri error explains missing destination")
            check(spokenError.contains("Siri & Shortcuts"), "Siri error provides setup guidance")
        }
        snapshot.siriHasAmbiguousJourney = true
        fails("Ambiguous journeys", containing: "one current journey") { _ = try resolve(.bikes) }
        check(try resolve(.bikes, explicit: a).dock.id == a.id, "Explicit bypasses ambiguity")
        snapshot.siriHasAmbiguousJourney = false
        snapshot.siriHasUnresolvedJourney = true
        fails("Incomplete live activity must not borrow defaults") { _ = try resolve(.spaces) }
        snapshot.siriHasUnresolvedJourney = false
        fails("No favourites never picks nearby") { _ = try resolve(.bikes) }
        snapshot.favorites = [b, a]
        let location = JourneyLocation(coordinate: a.coordinate!, accuracy: 5, date: now)
        check(try resolve(.bikes, location: location).dock.id == a.id, "Nearest favourite, not first")
        fails("Stale location never guesses") { _ = try resolve(.bikes, location: .init(coordinate: a.coordinate!, accuracy: 5, date: now.addingTimeInterval(-121))) }
        snapshot.favorites[0].coordinate = nil
        fails("Incomplete favourite coordinates cannot pick arbitrary subset") { _ = try resolve(.bikes, location: location) }
        snapshot.favorites = [a]
        snapshot.active = JourneyRun(id: "ended", phase: .pickup, startDock: b, destinationDock: b, startedAt: now.addingTimeInterval(-7200), expiresAt: now.addingTimeInterval(-1))
        check(try resolve(.bikes, location: location).source == .favorite, "Expired ride not revived")
        let values = [("NbDocks", "30"), ("NbBikes", "8"), ("NbEmptyDocks", "6"), ("NbStandardBikes", "6"), ("NbEBikes", "2")]
        let p = try point(values.reversed())
        check(p.count("NbEmptyDocks") == 6, "Spaces is 6, never capacity minus bikes")
        check(p.count("NbBikes") == 8, "Total bikes uses NbBikes")
        check(p.trustworthyElectricBikes == 2, "Trustworthy breakdown")
        for value in ["-1", "bad", "1.5", "", "99999999999999999999999999"] {
            check(try point([("NbBikes", value)]).count("NbBikes") == nil, "Invalid metric remains unknown")
        }
        check(try point().count("NbBikes") == nil, "Missing not zero")
        check(try point([("NbBikes", "0")]).count("NbBikes") == 0, "Zero preserved")
        check(try point([("NbBikes", "2"), ("NbBikes", "3")]).count("NbBikes") == nil, "Conflicting duplicates")
        check(try point([("NbBikes", "2"), ("NbBikes", "2")]).count("NbBikes") == 2, "Matching duplicates")
        check(try point([("NbBikes", "8"), ("NbStandardBikes", "8"), ("NbEBikes", "2")]).trustworthyElectricBikes == nil, "Inconsistent breakdown omitted")
        check(try point([("Locked", "true")]).isAvailable == false, "Locked")
        check(try point([("Installed", "false")]).isAvailable == false, "Uninstalled")
        check(try point().isAvailable, "Unknown flags permit attributed report")
        let selected = try resolve(.bikes, explicit: a)
        func answer(_ p: APIJourneyDock, _ metric: SiriAvailabilityMetric, age: TimeInterval = 0) throws -> SiriAvailabilityAnswer {
            try SiriAvailabilityFormatter.answer(report: .init(point: p, receivedAt: now, retrievedAt: now.addingTimeInterval(-age)), selection: selected, metric: metric, now: now)
        }
        check(try answer(p, .spaces).count == 6, "First vertical slice")
        check(try answer(p, .bikes).dialog.contains("including 2 electric bikes"), "Mixed bikes")
        check(try answer(p, .bikes).dialog.contains("TfL reports"), "Old modified is not retrieval age")
        check(try answer(point([("NbBikes", "0")]), .bikes).dialog.contains("no bikes"), "Zero speech")
        check(try answer(point([("NbEmptyDocks", "1")]), .spaces).dialog.contains("one space"), "Singular")
        check(try answer(point([("NbBikes", "1"), ("NbStandardBikes", "0"), ("NbEBikes", "1")]), .bikes).dialog.contains("all electric"), "All electric")
        fails("Stale", containing: "stale") { _ = try answer(p, .spaces, age: 31) }
        fails("Wrong identity", containing: "different dock") { _ = try answer(point(values, id: b.id), .spaces) }
        fails("Missing requested metric", containing: "count") { _ = try answer(point(), .spaces) }
        fails("Confirmed unavailable", containing: "unavailable") { _ = try answer(point(values + [("Locked", "true")]), .spaces) }
        let suite = "SiriChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        snapshot.active = nil
        snapshot.siriDestination = b
        JourneyStore.write(snapshot, key: JourneyStore.snapshotKey, defaults: defaults)
        check(JourneyStore.read(JourneySnapshot.self, key: JourneyStore.snapshotKey, defaults: defaults)?.siriDestination == b, "Cold saved identity")
        var cleared = snapshot
        cleared.siriDestination = nil
        cleared.generatedAt = now.addingTimeInterval(1)
        check(JourneyStore.receive(try JSONEncoder().encode(cleared), defaults: defaults), "New clear accepted")
        check(!JourneyStore.receive(try JSONEncoder().encode(snapshot), defaults: defaults), "Late state rejected")
        check(JourneyStore.read(JourneySnapshot.self, key: JourneyStore.snapshotKey, defaults: defaults)?.siriDestination == nil, "Clear survives relaunch")
        let oldData = try JSONEncoder().encode(JourneySnapshot.empty)
        check(try JSONDecoder().decode(JourneySnapshot.self, from: oldData).siriDestination == nil, "No favourite role migration")
        var current = selected
        var fetches = 0
        let service = SiriAvailabilityService(now: { now }, resolve: { current }, fetch: { id, _ in
            fetches += 1
            if fetches == 1 { current = SiriResolvedDock(dock: b, source: .destination, revision: now, lastSynced: false) }
            return SiriAvailabilityReport(point: try point(values, id: id), receivedAt: now, retrievedAt: now)
        })
        let changed = try await service.lookup(metric: .spaces)
        check(fetches == 2 && changed.role == "your destination", "Selection changes refetch once")
        let offline = SiriAvailabilityService(now: { now }, resolve: { selected }, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.lookup(metric: .spaces); preconditionFailure("Offline success") }
        catch { check(error.localizedDescription.contains("couldn't check"), "Offline has no numeric output") }
        let cancelled = SiriAvailabilityService(now: { now }, resolve: { selected }, fetch: { _, _ in throw CancellationError() })
        do { _ = try await cancelled.lookup(metric: .spaces); preconditionFailure("Cancellation success") }
        catch { check(error is CancellationError, "Cancellation preserved") }
        // Exercise the actual shared HTTP adapter without contacting TfL.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = try JSONSerialization.data(withJSONObject: ["id": a.id, "commonName": "Synthetic Square", "additionalProperties": values.map { ["key": $0.0, "value": $0.1] }])
        StubURLProtocol.body = fixture
        let fresh = try await JourneyDataSource.siriReport(id: a.id, timeout: 1, session: session)
        check(fresh.isFresh(at: Date()), "New direct retrieval")
        StubURLProtocol.headers = ["Age": "90"]
        let old = try await JourneyDataSource.siriReport(id: a.id, timeout: 1, session: session)
        check(!old.isFresh(at: Date()), "Downloading old upstream cache doesn't reset age")
        for age in ["unknown", "-1", "nan"] {
            StubURLProtocol.headers = ["Age": age]
            do { _ = try await JourneyDataSource.siriReport(id: a.id, timeout: 1, session: session); preconditionFailure("Invalid age") }
            catch { check(error is SiriAvailabilityError, "Invalid HTTP age fails") }
        }
        StubURLProtocol.headers = [:]
        for status in [401, 403, 404, 429, 500, 503] {
            StubURLProtocol.status = status
            do { _ = try await JourneyDataSource.siriReport(id: a.id, timeout: 1, session: session); preconditionFailure("HTTP failure returned value") }
            catch { check(true, "HTTP failure has no value") }
        }
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("malformed".utf8)
        do { _ = try await JourneyDataSource.siriReport(id: a.id, timeout: 1, session: session); preconditionFailure("Malformed body") }
        catch { check(error is DecodingError, "Malformed body has no count") }
        StubURLProtocol.hangs = true
        let began = Date()
        do { _ = try await JourneyDataSource.siriReport(id: a.id, timeout: 0.05, session: session); preconditionFailure("Hanging response") }
        catch { check(Date().timeIntervalSince(began) < 1, "Overall deadline cancels hanging response") }
        var raceFetches = 0
        let racing = SiriAvailabilityService(now: { now }, resolve: { current }, fetch: { id, _ in
            raceFetches += 1
            current = SiriResolvedDock(dock: current.dock.id == a.id ? b : a, source: .destination, revision: now, lastSynced: false)
            return SiriAvailabilityReport(point: try point(values, id: id), receivedAt: now, retrievedAt: now)
        })
        do { _ = try await racing.lookup(metric: .spaces); preconditionFailure("Repeated selection changes") }
        catch { check(raceFetches == 2 && error.localizedDescription.contains("selection changed"), "Exactly one selection retry") }
        let watchSelection = try SiriDockResolver.resolve(metric: .bikes, snapshot: snapshot, location: location, now: now, lastSynced: true)
        check(watchSelection.role.contains("last synced"), "Watch uncertainty is spoken")
        let oldJSON = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        let legacyJSON = oldJSON.filter { !$0.key.hasPrefix("siri") }
        let legacy = try JSONDecoder().decode(JourneySnapshot.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacy.siriDestination == nil && legacy.siriSchemaVersion == nil, "Legacy snapshots decode without migrating roles")
        check(!JourneyStore.receive(try JSONEncoder().encode(cleared), defaults: defaults), "Equal revisions cannot resurrect different state")
        print("Passed \(checks) Siri availability checks (synthetic fixtures).")
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    static var hangs = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.hangs { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
