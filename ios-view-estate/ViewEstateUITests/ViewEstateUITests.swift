//
//  ViewEstateUITests.swift
//  ViewEstateUITests
//

import XCTest

/// Launch smoke test: the brand welcome owns the first screen and offers both entry points.
final class ViewEstateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeIsTheFirstScreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VE_REGION_OVERRIDE"] = "PT"
        app.launch()

        XCTAssertTrue(app.buttons["welcome.signIn"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["welcome.createAccount"].exists)
        XCTAssertTrue(app.staticTexts["Capture. Valorize. Publique."].exists)
    }
}
