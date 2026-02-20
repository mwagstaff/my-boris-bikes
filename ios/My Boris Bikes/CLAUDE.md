# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a native iOS app called "My Boris Bikes" built with SwiftUI and Swift 5.0, targeting iOS 18.5+. The project is created with Xcode and follows standard iOS development patterns.

Its aim is to provide users with a quick and easy way to find out how many bikes and spaces are available at their favourite docks (also known as "bike points"), as well as a map showing bike and space availability for every dock.

The app will make use of API endpoints described in the `Data source` section below.

The app is designed to offer the following features:

### Home screen

 - Home screen: Displays a list of user-selected docks ("bike points"), showing in an easy-to-read donut chart format how many bikes are available at each dock, broken down as follows:
   - Normal bikes (red, rgb(236 0 0))
   - e-bikes (blue, rgb(12 17 177))
   - Spaces (gray, rgb(117 117 117))

This screen should be designed to load as quickly as possible, use as little bandwidth as possible, and be extremely responsive to user interactions.

By default, the app should use the user's current location, and the home screen list of favourite docks should be sorted by distance from the user's current location, with the closest docks at the top.

There should be options for the user to sort alphabetically or manually, with the user able to drag and drop the docks to change their order.

Data should update every 30 seconds in the background, and the user should be able to see the latest data without having to refresh the screen.

The user should be able to pull down to refresh the data, and the app should be able to handle being offline. If the app goes offline, it should display a message to the user, and the user should be able to refresh the data when the app is back online.

### Map screen

- Map screen: Displays a map centered by default on the user's current location, with a list of bike points as pins. The pins should be a donut chart, showing the breakdown of bikes available at each dock, broken down as follows:
  - Normal bikes (red, rgb(236 0 0))
  - e-bikes (blue, rgb(12 17 177))
  - Spaces (gray, rgb(117 117 117))

Each pin should be clickable, and when clicked, should pop up a dialog that (a) allows the user to toggle that location as a favourite, which will be indicated by a star icon; and (b) It should also display the name of the dock, the number of bikes available at that location, broken down as follows:
  - Normal bikes
  - e-bikes
  - Spaces

- About screen: Displays a picture of a Santander Cycle hire bike in London, information about the app, including its name, version, and developer, Sky No Limit (https://skynolimit.dev)

## Data source

The app will make use of the following API endpoints. Note that no API authentication or API key is required at this point, but may be needed in the future.

### BikePoint

- Method: GET
- URL: https://api.tfl.gov.uk/BikePoint
- Response: JSON
- Purpose: Retrieves an array of docks ("bike points")
- Where to use: Map screen, where all docks are displayed as pins

Each bike point is a JSON object with the following important properties:

 - id: The unique identifier of the bike point
 - commonName: The common name of the bike point, which should be used for display purposes on the favourites and maps screens
 - url: the "place" API endpoint for the individual bike point
 - lat: the latitude of the bike point
 - lon: the longitude of the bike point
 - additionalProperties: Additional properties specific to the bike point, such as the number of available bikes, which is an array of objects with the following important properties:
   - key: the category of the additional property, for which the values we care about in the app are:
     - Installed: A boolean indicating whether the bike point is installed and working. We should only display those for which this is true, and highlight to the user those that are not by graying them out.
     - Locked: A boolean indicating whether the bike point is locked, e.g. for maintenance. We should only display those for which this is false, and highlight to the user those that are locked by graying them out.
     - NbDocks: The total number of docks at the bike point.
     - NbEmptyDocks: The number of empty docks, i.e. spaces available, at the bike point.
     - NbStandardBikes: The number of standard bikes available to hire at the bike point.
     - NbEBikes: The number of e-bikes available to hire at the bike point.

### Place

- Method: GET
- URL: https://api.tfl.gov.uk/Place/<bike_point_id>
- Response: JSON
- Purpose: Retrieves information about a specific bike point
- Where to use: Favourites screen, to get information on the user's favourite docks

The bike point information returned is the same as the `BikePoint` endpoint, but only for the specified bike point.

## watchOS app

The iOS app is accompanied by a companion watchOS app that shares data with the iOS app - and a group.dev.skynolimit.myborisbikes app group capability has been added in Xcode accordingly.

The data shared between the iOS and watchOS apps is as follows:

- User's favourite docks (names and IDs)

The watchOS app will make use of the same API endpoints as the iOS app for the user's favourite docks.

The app will display by default the same information as the Favourites screen on the iOS app, i.e. a list of favourite docks, with the number of bikes and spaces available at each dock.

The list should be sorted by distance from the user's current location by default, with the closest docks at the top.

The watchOS app should also make use of donut charts and visual distance indicators.

There should be an option for the user to sort the list alphabetically and an easy way to toggle between alphabetic and distance sorting, but there is no need for a manual sort option.

Data should update every 30 seconds in the background, and the user should be able to see the latest data without having to refresh the screen.


## Development Commands

### Building and Running
- `xcodebuild -scheme "My Boris Bikes" -configuration Debug build` - Build the app for development
- `xcodebuild -scheme "My Boris Bikes" -configuration Release build` - Build for release
- Use Xcode IDE to run on simulator or device

### Testing
- `xcodebuild test -scheme "My Boris Bikes"` - Run all tests
- `xcodebuild test -scheme "My Boris Bikes" -destination 'platform=iOS Simulator,name=iPhone 15'` - Run tests on specific simulator
- Tests use Swift Testing framework (not XCTest) with `@Test` annotations and `#expect(...)` assertions

### Project Information
- `xcodebuild -list` - Show available schemes, targets, and build configurations

## Architecture

### Project Structure
- `My Boris Bikes/` - Main app source code
  - `My_Boris_BikesApp.swift` - App entry point with `@main` attribute
  - `ContentView.swift` - Root SwiftUI view
  - `Assets.xcassets/` - App icons and assets
- `My Boris BikesTests/` - Unit tests using Swift Testing framework
- `My Boris BikesUITests/` - UI tests for the application

### Key Components
- SwiftUI-based declarative UI architecture
- Single-target iOS application with separate test bundles
- Standard iOS app lifecycle managed by SwiftUI App protocol

### Testing Framework
The project uses Swift Testing framework (not XCTest). Test structure:
- Tests are written as `struct` with `@Test` methods
- Use `#expect(...)` for assertions instead of `XCTAssert*`
- Import the main module with `@testable import My_Boris_Bikes`