import XCTest

final class DockFreshnessUITests: XCTestCase {
    @MainActor
    func testSharedRefreshStatusAndOpenDockSheetUpdate() throws {
        try verifyRefresh()
    }

    @MainActor
    func testRefreshWithLargeText() throws {
        try verifyRefresh(appearanceArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
    }

    @MainActor
    private func verifyRefresh(appearanceArguments: [String] = []) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_DOCK_FRESHNESS"] + appearanceArguments
        addUIInterruptionMonitor(withDescription: "Freshness test permissions") { alert in
            for title in ["Allow While Using App", "Allow Once", "Allow", "OK", "Open"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
        app.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Getting latest data…"].waitForExistence(timeout: 5))
        attach("Favourites refreshing", app: app)
        app.tabBars.buttons["Journeys"].tap()
        XCTAssertTrue(app.staticTexts["Getting latest data…"].exists)
        attach("Journeys refreshing", app: app)
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["Getting latest data…"].exists)
        let dock = app.descendants(matching: .any)["dock-pin-freshness-test"]
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        dock.tap()
        XCTAssertTrue(app.staticTexts["Freshness test dock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8 bikes"].exists)
        attach("Dock sheet refreshing", app: app)
        let freshCount = app.staticTexts["1 bike"]
        XCTAssertTrue(freshCount.waitForExistence(timeout: 30), "The open sheet must observe refreshed counts")
        XCTAssertFalse(app.staticTexts["8 bikes"].exists)
        attach("Dock sheet refreshed", app: app)
    }

    @MainActor private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
