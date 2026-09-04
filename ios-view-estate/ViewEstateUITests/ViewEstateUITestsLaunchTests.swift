//
//  ViewEstateUITestsLaunchTests.swift
//  ViewEstateUITests
//
//  Created by Rork on September 3, 2026.
//

import XCTest

final class ViewEstateUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VE_REGION_OVERRIDE"] = "PT"
        app.launch()

        _ = app.buttons["welcome.signIn"].waitForExistence(timeout: 20)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
