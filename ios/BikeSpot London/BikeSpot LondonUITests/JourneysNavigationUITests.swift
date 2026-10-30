import CoreLocation
import XCTest

final class JourneysNavigationUITests: XCTestCase {
    @MainActor
    func testJourneysSelectionFromEveryTab() throws {
        verifyJourneysNavigation()
    }

    @MainActor
    func testJourneysSelectionWithAccessibilityText() throws {
        verifyJourneysNavigation(launchArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
    }

    @MainActor
    private func verifyJourneysNavigation(launchArguments: [String] = []) {
        continueAfterFailure = false
        let originalLocation = XCUIDevice.shared.location
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 51.5074, longitude: -0.1278))
        defer { XCUIDevice.shared.location = originalLocation }
        let app = XCUIApplication()
        app.launchArguments += launchArguments
        addUIInterruptionMonitor(withDescription: "Journey navigation permissions") { alert in
            for title in ["Allow While Using App", "Allow Once", "Allow", "OK", "Continue"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))

        for source in ["Favourites", "Map", "Profile", "Favourites"] {
            tabs.buttons[source].tap()
            XCTAssertTrue(tabs.buttons[source].isSelected)
            tabs.buttons["Journeys"].tap()
            XCTAssertTrue(tabs.buttons["Journeys"].isSelected)
            XCTAssertTrue(app.navigationBars["Journeys"].exists)
            XCTAssertTrue(app.buttons["New journey"].exists)

            // Section changes must remain inside the Journeys tab.
            app.segmentedControls.buttons["History"].tap()
            XCTAssertTrue(app.segmentedControls.buttons["History"].isSelected)
            XCTAssertTrue(tabs.buttons["Journeys"].isSelected)
            tabs.buttons[source].tap()
            tabs.buttons["Journeys"].tap()
            XCTAssertTrue(tabs.buttons["Journeys"].isSelected)
            XCTAssertTrue(app.segmentedControls.buttons["History"].isSelected)
            app.segmentedControls.buttons["Favourites"].tap()
            XCTAssertTrue(tabs.buttons["Journeys"].isSelected)
        }

        tabs.buttons["Profile"].tap()
        app.open(URL(string: "myborisbikes://journeys")!)
        XCTAssertTrue(tabs.buttons["Journeys"].isSelected)
        XCTAssertTrue(app.navigationBars["Journeys"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = launchArguments.isEmpty ? "Journeys navigation" : "Journeys with accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
