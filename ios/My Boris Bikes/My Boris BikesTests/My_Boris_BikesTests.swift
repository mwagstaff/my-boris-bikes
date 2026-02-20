//
//  My_Boris_BikesTests.swift
//  My Boris BikesTests
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import Testing
import CoreLocation
@testable import My_Boris_Bikes

struct My_Boris_BikesTests {

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

}
