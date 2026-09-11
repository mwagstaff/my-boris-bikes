import Testing
@testable import BikeSpot_London

struct LiveActivityMonitoringResolverTests {
    private let warwickId = "BikePoints_316"
    private let warwickName = "Warwick Row, Westminster"
    private let warwickLatitude = 51.4979
    private let warwickLongitude = -0.1432
    private let stonecutterId = "BikePoints_112"
    private let stonecutterName = "Stonecutter Street, Holborn"
    private let stonecutterLatitude = 51.5155
    private let stonecutterLongitude = -0.1047

    @Test func coldRestoredStartResolvesOriginAndDestination() {
        let configuration = DockActivityMonitoringResolver.resolve(
            attributes: startAttributes(),
            state: contentState()
        )

        #expect(configuration?.bikePoint.id == warwickId)
        #expect(configuration?.bikePoint.lat == warwickLatitude)
        #expect(configuration?.bikePoint.lon == warwickLongitude)
        #expect(configuration?.phase == .start)
        #expect(configuration?.scheduledJourneyId == "journey-1")
        #expect(configuration?.destinationDock?.id == stonecutterId)
        #expect(configuration?.destinationDock?.latitude == stonecutterLatitude)
        #expect(configuration?.destinationDock?.longitude == stonecutterLongitude)
    }

    @Test func transitionedEndUsesDestinationCoordinates() {
        let configuration = DockActivityMonitoringResolver.resolve(
            attributes: startAttributes(),
            state: contentState(
                activeDockId: stonecutterId,
                activeDockName: stonecutterName,
                activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue
            )
        )

        #expect(configuration?.bikePoint.id == stonecutterId)
        #expect(configuration?.bikePoint.lat == stonecutterLatitude)
        #expect(configuration?.bikePoint.lon == stonecutterLongitude)
        #expect(configuration?.bikePoint.lat != warwickLatitude)
        #expect(configuration?.phase == .end)
        #expect(configuration?.destinationDock == nil)
    }

    @Test func activityCreatedInEndPhaseUsesPrimaryCoordinates() {
        let attributes = DockActivityAttributes(
            dockId: stonecutterId,
            dockName: stonecutterName,
            alias: nil,
            scheduledJourneyId: "journey-1",
            scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue,
            latitude: stonecutterLatitude,
            longitude: stonecutterLongitude
        )

        let configuration = DockActivityMonitoringResolver.resolve(
            attributes: attributes,
            state: contentState()
        )

        #expect(configuration?.bikePoint.id == stonecutterId)
        #expect(configuration?.bikePoint.lat == stonecutterLatitude)
        #expect(configuration?.phase == .end)
    }

    @Test func transitionedEndRejectsIncompleteDestinationCoordinates() {
        let attributes = startAttributes(destinationLongitude: nil)
        let state = contentState(
            activeDockId: stonecutterId,
            activeDockName: stonecutterName,
            activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue
        )

        #expect(DockActivityMonitoringResolver.resolve(attributes: attributes, state: state) == nil)
    }

    @Test func resolverRejectsUnknownActiveDockAndInconsistentPhase() {
        let unknownDockState = contentState(
            activeDockId: "BikePoints_unknown",
            activeDockName: "Unknown",
            activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue
        )
        let endPhaseAtOriginState = contentState(
            activeDockId: warwickId,
            activeDockName: warwickName,
            activeJourneyPhase: ScheduledJourney.ActiveRun.Phase.end.rawValue
        )

        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(),
                state: unknownDockState
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(),
                state: endPhaseAtOriginState
            ) == nil
        )
    }

    @Test func regularActivityResolvesPrimaryDockWithoutJourneyContext() {
        let attributes = DockActivityAttributes(
            dockId: warwickId,
            dockName: warwickName,
            alias: nil,
            latitude: warwickLatitude,
            longitude: warwickLongitude
        )

        let configuration = DockActivityMonitoringResolver.resolve(
            attributes: attributes,
            state: contentState(activeDockName: "Ignored without a mutable dock ID")
        )

        #expect(configuration?.bikePoint.id == warwickId)
        #expect(configuration?.bikePoint.commonName == warwickName)
        #expect(configuration?.phase == nil)
        #expect(configuration?.destinationDock == nil)
    }

    @Test func fetchedDocksRepairIncompleteStartAttributes() {
        let attributes = startAttributes(
            dockName: "",
            latitude: nil,
            longitude: nil,
            destinationDockName: nil,
            destinationLatitude: nil,
            destinationLongitude: nil
        )
        let fallbackActiveDock = BikePoint(
            id: warwickId,
            commonName: warwickName,
            lat: warwickLatitude,
            lon: warwickLongitude
        )
        let fallbackDestinationDock = ScheduledJourneyDock(
            id: stonecutterId,
            name: stonecutterName,
            latitude: stonecutterLatitude,
            longitude: stonecutterLongitude
        )

        let configuration = DockActivityMonitoringResolver.resolve(
            attributes: attributes,
            state: contentState(),
            fallbackActiveDock: fallbackActiveDock,
            fallbackDestinationDock: fallbackDestinationDock
        )

        #expect(configuration?.bikePoint == fallbackActiveDock)
        #expect(configuration?.destinationDock == fallbackDestinationDock)
        #expect(configuration?.phase == .start)
    }

    @Test func resolverRejectsMismatchedFallbackDocks() {
        let attributes = startAttributes(
            latitude: nil,
            longitude: nil,
            destinationLatitude: nil,
            destinationLongitude: nil
        )
        let wrongActiveDock = BikePoint(
            id: "BikePoints_wrong",
            commonName: "Wrong dock",
            lat: warwickLatitude,
            lon: warwickLongitude
        )
        let correctActiveDock = BikePoint(
            id: warwickId,
            commonName: warwickName,
            lat: warwickLatitude,
            lon: warwickLongitude
        )
        let wrongDestinationDock = ScheduledJourneyDock(
            id: "BikePoints_wrong",
            name: "Wrong dock",
            latitude: stonecutterLatitude,
            longitude: stonecutterLongitude
        )

        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: attributes,
                state: contentState(),
                fallbackActiveDock: wrongActiveDock
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: attributes,
                state: contentState(),
                fallbackActiveDock: correctActiveDock,
                fallbackDestinationDock: wrongDestinationDock
            ) == nil
        )
    }

    @Test func resolverRejectsInvalidCoordinatesAndMutablePhase() {
        let invalidPhaseState = contentState(activeJourneyPhase: "not-a-phase")

        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(latitude: 0, longitude: 0),
                state: contentState()
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(latitude: .nan),
                state: contentState()
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(latitude: 91),
                state: contentState()
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(),
                state: invalidPhaseState
            ) == nil
        )
        #expect(
            DockActivityMonitoringResolver.resolve(
                attributes: startAttributes(),
                state: contentState(activeJourneyPhase: "  ")
            )?.phase == .start
        )
    }

    @Test func reconciliationActionDistinguishesStartRearmReplaceAndReuse() {
        #expect(
            DockArrivalMonitoringReconciliationAction.resolve(
                hasCurrentConfiguration: false,
                currentMatchesExpected: false,
                isConfiguredThisProcess: false
            ) == .start
        )
        #expect(
            DockArrivalMonitoringReconciliationAction.resolve(
                hasCurrentConfiguration: true,
                currentMatchesExpected: true,
                isConfiguredThisProcess: false
            ) == .rearm
        )
        #expect(
            DockArrivalMonitoringReconciliationAction.resolve(
                hasCurrentConfiguration: true,
                currentMatchesExpected: false,
                isConfiguredThisProcess: true
            ) == .replace
        )
        #expect(
            DockArrivalMonitoringReconciliationAction.resolve(
                hasCurrentConfiguration: true,
                currentMatchesExpected: true,
                isConfiguredThisProcess: true
            ) == .reuseAndProbe
        )
    }

    private func startAttributes(
        dockName: String = "Warwick Row, Westminster",
        latitude: Double? = 51.4979,
        longitude: Double? = -0.1432,
        destinationDockName: String? = "Stonecutter Street, Holborn",
        destinationLatitude: Double? = 51.5155,
        destinationLongitude: Double? = -0.1047
    ) -> DockActivityAttributes {
        DockActivityAttributes(
            dockId: warwickId,
            dockName: dockName,
            alias: nil,
            scheduledJourneyId: "journey-1",
            scheduledJourneyPhase: ScheduledJourney.ActiveRun.Phase.start.rawValue,
            latitude: latitude,
            longitude: longitude,
            destinationDockId: stonecutterId,
            destinationDockName: destinationDockName,
            destinationLatitude: destinationLatitude,
            destinationLongitude: destinationLongitude
        )
    }

    private func contentState(
        activeDockId: String? = nil,
        activeDockName: String? = nil,
        activeJourneyPhase: String? = nil
    ) -> DockActivityAttributes.ContentState {
        DockActivityAttributes.ContentState(
            standardBikes: 10,
            eBikes: 2,
            emptySpaces: 8,
            activeDockId: activeDockId,
            activeDockName: activeDockName,
            activeJourneyPhase: activeJourneyPhase
        )
    }
}
