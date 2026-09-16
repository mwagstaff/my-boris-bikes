import Foundation
import CoreLocation
#if os(watchOS)
import WatchConnectivity
#endif

@MainActor
enum SiriAvailabilityRuntime {
    static func lookup(_ metric: SiriAvailabilityMetric, explicit: JourneyDock? = nil) async throws -> SiriAvailabilityAnswer {
        let deadline = Date().addingTimeInterval(8)
        var lastSynced = false
#if os(watchOS)
        if explicit == nil {
            let watch = WatchFavoritesService.shared
            // Reuse the existing delegate; do not start screen refresh timers for a voice lookup.
            let session = WCSession.default
            if session.activationState != .activated {
                session.delegate = watch
                session.activate()
            }
            lastSynced = !(await watch.requestJourneyRefreshFromPhone(timeout: .seconds(2), requireSiriContext: true))
            guard JourneyStore.snapshot.siriSchemaVersion == 1 else {
                throw SiriAvailabilityError(message: String(localized: "Open BikeSpot London on your iPhone and Watch to sync Siri dock selections."))
            }
        }
#else
        // Publish loaded authoritative services before capturing the durable snapshot.
        // App startup restores activities; no screen or view model is required.
        JourneySyncService.shared.publish()
#endif
        var snapshot = JourneyDataSource.siriSnapshot()
        var location = JourneyStore.location
        if explicit == nil, metric == .bikes, snapshot.active?.expiresAt ?? .distantPast <= Date(),
           !snapshot.favorites.isEmpty, snapshot.siriHasAmbiguousJourney != true {
            // No permission dialog from Siri. Use the existing grant and a bounded one-shot fix.
            location = await SiriLocationRequest().sample(timeout: min(2, max(0, deadline.timeIntervalSinceNow)))
            if snapshot.favorites.contains(where: { $0.coordinate?.isValid != true }), deadline.timeIntervalSinceNow > 0 {
                if let catalogue = try? await JourneyDataSource.siriDockCatalogue(timeout: deadline.timeIntervalSinceNow) {
                    snapshot.favorites = snapshot.favorites.map { favorite in
                        var dock = favorite
                        dock.coordinate = catalogue.first { $0.id == dock.id }?.coordinate
                        return dock
                    }
                }
            }
        }
        let capturedLocation = location
        let capturedSnapshot = snapshot
        let capturedLastSynced = lastSynced
        let service = SiriAvailabilityService(resolve: {
            var current = JourneyDataSource.siriSnapshot()
            // Catalogue coordinates are metadata only; never replace current favourite IDs.
            current.favorites = current.favorites.map { favorite in
                var dock = favorite
                if dock.coordinate?.isValid != true {
                    dock.coordinate = capturedSnapshot.favorites.first { $0.id == dock.id }?.coordinate
                }
                return dock
            }
            return try SiriDockResolver.resolve(metric: metric, snapshot: current, location: capturedLocation,
                                                explicit: explicit, now: Date(), lastSynced: capturedLastSynced)
        }, fetch: { id, timeout in
            try await JourneyDataSource.siriReport(id: id, timeout: timeout)
        })
        return try await service.lookup(metric: metric, deadline: deadline)
    }
}

/// Shares the app's Core Location permission and JourneyLocation model. No tracking or new grant.
@MainActor
private final class SiriLocationRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<JourneyLocation>.Continuation?

    func sample(timeout: TimeInterval) async -> JourneyLocation? {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return nil }
        if let cached = JourneyStore.location, cached.isUsable(at: Date()) { return cached }
        guard timeout > 0, !Task.isCancelled else { return nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let (stream, continuation) = AsyncStream<JourneyLocation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        let timer = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            continuation.finish()
        }
        defer {
            timer.cancel()
            manager.stopUpdatingLocation()
            manager.delegate = nil
            continuation.finish()
            self.continuation = nil
        }
        manager.requestLocation()
        for await sample in stream { return Task.isCancelled ? nil : sample }
        return nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        let sample = JourneyLocation(coordinate: .init(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude),
                                     accuracy: value.horizontalAccuracy, date: value.timestamp)
        if sample.isUsable(at: Date()) {
            continuation?.yield(sample)
            continuation?.finish()
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { continuation?.finish() }
}
