//
//  My_Boris_BikesUITests.swift
//  My Boris BikesUITests
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import Foundation
import XCTest

final class My_Boris_BikesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)

        app.launchArguments += [
            "-UITEST_MODE",
            "1"
        ]

        addUIInterruptionMonitor(withDescription: "System Alerts") { alert -> Bool in
            let preferredButtons = [
                "Allow While Using App",
                "Allow Once",
                "OK",
                "Continue"
            ]

            for button in preferredButtons where alert.buttons[button].exists {
                alert.buttons[button].tap()
                return true
            }

            if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
                return true
            }

            return false
        }

        app.launch()
        app.tap() // Trigger interruption handler if a system alert is shown.

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))

        waitForUIToSettle()
        snapshot("01-Favourites", timeWaitingForIdle: 0)

        tapTab(named: "Map", in: app)
        waitForUIToSettle()
        snapshot("02-Map", timeWaitingForIdle: 0)

        tapTab(named: "Preferences", in: app)
        waitForUIToSettle()
        snapshot("03-Preferences", timeWaitingForIdle: 0)

        tapTab(named: "About", in: app)
        waitForUIToSettle()
        snapshot("04-About", timeWaitingForIdle: 0)
    }

    @MainActor
    private func tapTab(named tabName: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let tabButton = app.tabBars.buttons[tabName]
        XCTAssertTrue(tabButton.waitForExistence(timeout: timeout), "Tab '\(tabName)' did not appear")
        tabButton.tap()
    }

    private func waitForUIToSettle(seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
