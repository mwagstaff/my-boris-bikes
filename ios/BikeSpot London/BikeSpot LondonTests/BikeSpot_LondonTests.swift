//
//  BikeSpot_LondonTests.swift
//  BikeSpot LondonTests
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import Testing
import CoreLocation
@testable import BikeSpot_London

struct BikeSpot_LondonTests {

    @Test func testBikePointModel() async throws {
        let properties = [
            AdditionalProperty(key: "Installed", value: "true"),
            AdditionalProperty(key: "Locked", value: "false"),
            AdditionalProperty(key: "NbDocks", value: "20"),
            AdditionalProperty(key: "NbEmptyDocks", value: "5"),
            AdditionalProperty(key: "NbStandardBikes", value: "10"),
            AdditionalProperty(key: "NbEBikes", value: "5")
        ]
        
        let bikePoint = BikePoint(
            id: "BikePoints_1",
            commonName: "Test Station, Test Street",
            url: "/Place/BikePoints_1",
            lat: 51.5074,
            lon: -0.1278,
            additionalProperties: properties
        )
        
        #expect(bikePoint.isInstalled == true)
        #expect(bikePoint.isLocked == false)
        #expect(bikePoint.totalDocks == 20)
        #expect(bikePoint.emptyDocks == 5)
        #expect(bikePoint.standardBikes == 10)
        #expect(bikePoint.eBikes == 5)
        #expect(bikePoint.totalBikes == 15)
        #expect(bikePoint.isAvailable == true)
    }
    
    @Test func testBikePointUnavailable() async throws {
        let properties = [
            AdditionalProperty(key: "Installed", value: "false"),
            AdditionalProperty(key: "Locked", value: "true")
        ]
        
        let bikePoint = BikePoint(
            id: "BikePoints_2",
            commonName: "Unavailable Station",
            url: "/Place/BikePoints_2",
            lat: 51.5074,
            lon: -0.1278,
            additionalProperties: properties
        )
        
        #expect(bikePoint.isInstalled == false)
        #expect(bikePoint.isLocked == true)
        #expect(bikePoint.isAvailable == false)
    }
    
    @Test func testFavoriteBikePoint() async throws {
        let properties = [
            AdditionalProperty(key: "Installed", value: "true"),
            AdditionalProperty(key: "Locked", value: "false")
        ]
        
        let bikePoint = BikePoint(
            id: "BikePoints_1",
            commonName: "Test Station",
            url: "/Place/BikePoints_1",
            lat: 51.5074,
            lon: -0.1278,
            additionalProperties: properties
        )
        
        let favorite = FavoriteBikePoint(bikePoint: bikePoint, sortOrder: 0)
        
        #expect(favorite.id == bikePoint.id)
        #expect(favorite.name == bikePoint.commonName)
        #expect(favorite.sortOrder == 0)
    }
    
    @Test func testSortModes() async throws {
        let modes = SortMode.allCases

        #expect(modes.count == 2)
        #expect(modes.contains(.distance))
        #expect(modes.contains(.alphabetical))

        #expect(SortMode.distance.displayName == "Distance")
        #expect(SortMode.alphabetical.displayName == "Alphabetical")
    }
    
    @Test func testAppConstants() async throws {
        #expect(AppConstants.API.baseURL == "https://api.tfl.gov.uk")
        #expect(AppConstants.API.bikePointEndpoint == "/BikePoint")
        #expect(AppConstants.API.placeEndpoint == "/Place")
        #expect(AppConstants.App.refreshInterval == 30)
        #expect(AppConstants.App.appGroup == "group.dev.skynolimit.myborisbikes")
        #expect(AppConstants.App.developerURL == "https://skynolimit.dev")
    }
    
    @Test func testNetworkErrors() async throws {
        let invalidURLError = NetworkError.invalidURL
        let noDataError = NetworkError.noData
        let offlineError = NetworkError.offline
        
        #expect(invalidURLError.errorDescription == "Invalid URL")
        #expect(noDataError.errorDescription == "No data received")
        #expect(offlineError.errorDescription == "No internet connection available")
    }

    @Test func testDockArrivalHeuristicsExpandThresholdForRealisticGpsNoise() async throws {
        let arrivalThreshold = CLLocationDistance(25)

        let preciseThreshold = DockArrivalHeuristics.effectiveArrivalThreshold(
            for: arrivalThreshold,
            horizontalAccuracy: 10
        )
        let noisyThreshold = DockArrivalHeuristics.effectiveArrivalThreshold(
            for: arrivalThreshold,
            horizontalAccuracy: 45
        )

        #expect(preciseThreshold == 25)
        #expect(noisyThreshold == 41)
        #expect(
            DockArrivalHeuristics.compensatedDistance(
                from: 52,
                horizontalAccuracy: 28
            ) == 24
        )
    }

    @Test func testDockArrivalHeuristicsCapActivationAndAccuracyAllowance() async throws {
        let acceptableAccuracy = DockArrivalHeuristics.acceptableHorizontalAccuracy(
            for: CLLocationDistance(25)
        )
        let effectiveActivationDistance = DockArrivalHeuristics.effectiveActivationDistance(
            for: LiveActivityArrivalSettings.preciseActivationDistanceMeters,
            horizontalAccuracy: 120
        )

        #expect(acceptableAccuracy == 65)
        #expect(effectiveActivationDistance == 570)
        #expect(LiveActivityArrivalSettings.preferredMaximumRegionRadiusMeters == 500)
    }

    @Test func testStartDockArrivalPolicyUsesConservativeAccuracyAllowance() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .start,
            configuredArrivalThreshold: CLLocationDistance(50),
            horizontalAccuracy: 45
        )

        #expect(policy.kind == .startDock)
        #expect(policy.arrivalThreshold == 50)
        #expect(policy.acceptableHorizontalAccuracy == 90)
        #expect(policy.usesCompensatedDistanceForConfirmation == false)
        #expect(policy.effectiveArrivalThreshold == 61.25)
        #expect(policy.confirmationDwellTime == 3)
        #expect(
            policy.isInsideArrivalThreshold(
                rawDistance: 60,
                compensatedDistance: 0
            ) == true
        )
        #expect(
            policy.isInsideArrivalThreshold(
                rawDistance: 75,
                compensatedDistance: 30
            ) == false
        )
    }

    @Test func testStartDockArrivalConfirmsAfterTwoFixesAndShortDwell() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .start,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 40
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let firstDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: startedAt,
            rawDistance: 58,
            compensatedDistance: 18,
            horizontalAccuracy: 40,
            speed: 1,
            policy: policy
        )
        guard case .candidate(let evidence) = firstDecision else {
            Issue.record("Expected the first start-dock fix to begin confirmation")
            return
        }

        let secondDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: evidence,
            timestamp: startedAt.addingTimeInterval(3),
            rawDistance: 57,
            compensatedDistance: 17,
            horizontalAccuracy: 40,
            speed: 1,
            policy: policy
        )

        #expect(secondDecision == .confirmed)
    }

    @Test func testAccurateStartDockFixStillRequiresConfirmation() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .start,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 12
        )
        let decision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: Date(),
            rawDistance: 35,
            compensatedDistance: 23,
            horizontalAccuracy: 12,
            speed: 1,
            policy: policy
        )

        guard case .candidate = decision else {
            Issue.record("Expected a single start-dock fix to remain a candidate")
            return
        }
    }

    @Test func testStrongRegularDockFixConfirmsImmediately() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: nil,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 16.1
        )
        let decision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: Date(),
            rawDistance: 31.5,
            compensatedDistance: 15.4,
            horizontalAccuracy: 16.1,
            speed: 0.23,
            policy: policy
        )

        #expect(decision == .confirmed)
    }

    @Test func testRegularDockFixOutsideStrongAccuracyStillRequiresConfirmation() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: nil,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 30
        )
        let decision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: Date(),
            rawDistance: 31.5,
            compensatedDistance: 1.5,
            horizontalAccuracy: 30,
            speed: 0.23,
            policy: policy
        )

        guard case .candidate = decision else {
            Issue.record("Expected a regular-dock fix outside strong accuracy to remain a candidate")
            return
        }
    }

    @Test func testEndDockArrivalPolicyRequiresRawDistance() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .end,
            configuredArrivalThreshold: CLLocationDistance(50),
            horizontalAccuracy: 45
        )

        #expect(policy.kind == .endDock)
        #expect(policy.acceptableHorizontalAccuracy == 90)
        #expect(policy.usesCompensatedDistanceForConfirmation == false)
        #expect(policy.arrivalThreshold == 50)
        #expect(policy.effectiveArrivalThreshold == 72.5)
        #expect(policy.confirmationDwellTime == 1)
        #expect(
            policy.isInsideArrivalThreshold(
                rawDistance: 35,
                compensatedDistance: 0
            ) == true
        )
        #expect(
            policy.isInsideArrivalThreshold(
                rawDistance: 75,
                compensatedDistance: 30
            ) == false
        )
    }

    @Test func testEndDockArrivalPreservesClosestApproachWhileWalkingAway() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .end,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 45
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let firstDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: startedAt,
            rawDistance: 70,
            compensatedDistance: 25,
            horizontalAccuracy: 45,
            speed: 4,
            policy: policy
        )
        guard case .candidate(let evidence) = firstDecision else {
            Issue.record("Expected the first plausible dock fix to start confirmation")
            return
        }
        let improvedAccuracyPolicy = DockArrivalHeuristics.arrivalPolicy(
            for: .end,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 20
        )

        let departureDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: evidence,
            timestamp: startedAt.addingTimeInterval(1),
            rawDistance: 78,
            compensatedDistance: 58,
            horizontalAccuracy: 20,
            speed: 1.4,
            policy: improvedAccuracyPolicy
        )

        #expect(departureDecision == .confirmed)
    }

    @Test func testEndDockArrivalDoesNotConfirmFastPassBy() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .end,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 45
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let firstDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: startedAt,
            rawDistance: 70,
            compensatedDistance: 25,
            horizontalAccuracy: 45,
            speed: 6,
            policy: policy
        )
        guard case .candidate(let evidence) = firstDecision else {
            Issue.record("Expected the first plausible dock fix to start confirmation")
            return
        }

        let passingDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: evidence,
            timestamp: startedAt.addingTimeInterval(1),
            rawDistance: 78,
            compensatedDistance: 33,
            horizontalAccuracy: 45,
            speed: 6,
            policy: policy
        )
        guard case .candidate(let retainedEvidence) = passingDecision else {
            Issue.record("Expected hysteresis to retain, but not confirm, a fast pass-by")
            return
        }

        let resetDecision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: retainedEvidence,
            timestamp: startedAt.addingTimeInterval(2),
            rawDistance: 90,
            compensatedDistance: 45,
            horizontalAccuracy: 45,
            speed: 6,
            policy: policy
        )
        #expect(resetDecision == .none)
    }

    @Test func testStrongDockFixConfirmsImmediately() async throws {
        let policy = DockArrivalHeuristics.arrivalPolicy(
            for: .end,
            configuredArrivalThreshold: 50,
            horizontalAccuracy: 12
        )
        let decision = DockArrivalHeuristics.evaluateArrivalEvidence(
            existingEvidence: nil,
            timestamp: Date(),
            rawDistance: 35,
            compensatedDistance: 23,
            horizontalAccuracy: 12,
            speed: -1,
            policy: policy
        )

        #expect(decision == .confirmed)
    }

}
