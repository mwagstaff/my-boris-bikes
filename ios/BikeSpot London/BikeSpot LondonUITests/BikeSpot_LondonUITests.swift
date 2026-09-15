//
//  BikeSpot_LondonUITests.swift
//  BikeSpot LondonUITests
//
//  Created by Mike Wagstaff on 08/08/2025.
//

import Foundation
import XCTest

final class BikeSpot_LondonUITests: XCTestCase {

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
    func testJourneySimulationControls() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Journey test permissions") { alert in
            for title in ["Allow While Using App", "Allow Once", "Allow", "OK", "Continue"] {
                if alert.buttons[title].exists {
                    alert.buttons[title].tap()
                    return true
                }
            }
            return false
        }
        app.launch()
        tapTab(named: "Profile", in: app, timeout: 20)

        let preferences = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preferences")).firstMatch
        XCTAssertTrue(preferences.waitForExistence(timeout: 10))
        preferences.tap()

        let alternatives = app.switches["Show nearby alternatives"]
        reveal(alternatives, in: app)
        let alternativesWereEnabled = alternatives.value as? String == "1"
        if !alternativesWereEnabled {
            alternatives.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let alternativesEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: alternatives)
        XCTAssertEqual(XCTWaiter.wait(for: [alternativesEnabled], timeout: 5), .completed)
        let originalSpaces = setMinimumPreference("Minimum free spaces", to: 5, in: app)
        let originalBikes = setMinimumPreference("Minimum bikes", to: 5, in: app)

        let journeyTest = app.buttons["Test a Journey"]
        reveal(journeyTest, in: app)
        journeyTest.tap()
        XCTAssertTrue(app.navigationBars["Test a Journey"].waitForExistence(timeout: 10))

        let start = app.buttons["Start test journey"]
        if start.exists {
            start.tap()
        } else {
            app.buttons["Restart test"].tap()
        }
        XCTAssertTrue(app.buttons["Stop test and restore real data"].waitForExistence(timeout: 10))

        selectJourneyOption("Bikes", for: "Bike preference", in: app)
        XCTAssertTrue(app.steppers["Bikes: 6"].exists)
        attachJourneyScreenshot("Collecting — 6 bikes", app: app)

        for count in stride(from: 6, through: 4, by: -1) {
            let stepper = app.steppers["Bikes: \(count)"]
            reveal(stepper, in: app)
            stepper.buttons["Decrement"].tap()
            XCTAssertTrue(app.steppers["Bikes: \(count - 1)"].waitForExistence(timeout: 5))
        }
        attachJourneyScreenshot("Collecting — 3 bikes", app: app)

        selectJourneyOption("E-bikes", for: "Bike preference", in: app)
        XCTAssertTrue(app.steppers["E-bikes: 4"].exists)
        attachJourneyScreenshot("Collecting — 4 e-bikes", app: app)

        selectJourneyOption("Cycling", for: "Stage", in: app, scrollDown: true)
        XCTAssertTrue(app.sliders["Simulated position"].exists)
        for count in stride(from: 8, through: 4, by: -1) {
            let stepper = app.steppers["Spaces: \(count)"]
            reveal(stepper, in: app)
            stepper.buttons["Decrement"].tap()
            XCTAssertTrue(app.steppers["Spaces: \(count - 1)"].waitForExistence(timeout: 5))
        }
        attachJourneyScreenshot("Cycling — 3 spaces", app: app)
        for count in 3..<8 {
            let stepper = app.steppers["Spaces: \(count)"]
            reveal(stepper, in: app)
            stepper.buttons["Increment"].tap()
            XCTAssertTrue(app.steppers["Spaces: \(count + 1)"].waitForExistence(timeout: 5))
        }
        attachJourneyScreenshot("Cycling — 8 spaces", app: app)
        if ProcessInfo.processInfo.environment["JOURNEY_PAIRED_UI_CHECK"] != "1" {
            let stop = app.buttons["Stop test and restore real data"]
            reveal(stop, in: app, scrollDown: true)
            stop.tap()
            XCTAssertTrue(app.buttons["Start test journey"].waitForExistence(timeout: 10))
            app.navigationBars["Test a Journey"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Preferences"].waitForExistence(timeout: 10))
            setMinimumPreference("Minimum bikes", to: originalBikes, in: app, scrollDown: true)
            setMinimumPreference("Minimum free spaces", to: originalSpaces, in: app, scrollDown: true)
            if !alternativesWereEnabled {
                reveal(alternatives, in: app, scrollDown: true)
                alternatives.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                let alternativesDisabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: alternatives)
                XCTAssertEqual(XCTWaiter.wait(for: [alternativesDisabled], timeout: 5), .completed)
            }
        }
    }

    @MainActor
    @discardableResult
    private func setMinimumPreference(_ label: String, to target: Int, in app: XCUIApplication, scrollDown: Bool = false) -> Int {
        let stepper = app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", label + ":")).firstMatch
        reveal(stepper, in: app, scrollDown: scrollDown)
        XCTAssertTrue(stepper.isEnabled)
        guard let count = Int(stepper.label.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""),
              (0...20).contains(count), (0...20).contains(target) else {
            XCTFail("Unexpected minimum preference: \(stepper.label)")
            return target
        }
        let direction = target > count ? 1 : -1
        for offset in 0..<abs(target - count) {
            stepper.buttons[direction == 1 ? "Increment" : "Decrement"].tap()
            XCTAssertTrue(app.steppers["\(label): \(count + direction * (offset + 1))"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.steppers["\(label): \(target)"].exists)
        return count
    }

    @MainActor
    private func selectJourneyOption(_ option: String, for label: String, in app: XCUIApplication, scrollDown: Bool = false) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        reveal(picker, in: app, scrollDown: scrollDown)
        picker.tap()
        let choice = app.buttons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollDown: Bool = false) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if scrollDown { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reach \(element)")
    }

    @MainActor
    private func attachJourneyScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if ProcessInfo.processInfo.environment["JOURNEY_PAIRED_UI_CHECK"] == "1" {
            // Opt-in time for checking the paired Watch; normal UI tests do not pause.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))
        }
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
