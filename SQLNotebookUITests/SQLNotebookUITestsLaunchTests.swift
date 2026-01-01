//
//  SQLNotebookUITestsLaunchTests.swift
//  SQLNotebookUITests
//
//  Created by Anh-Thi Dinh on 12/29/25.
//

// MARK: - UI Launch Tests
// These tests run by default locally and are skipped in CI via SKIP_UI_TESTS=true

import XCTest

final class SQLNotebookUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        // Skip all UI tests if SKIP_UI_TESTS environment variable is set
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SKIP_UI_TESTS"] == "true",
            "UI tests skipped in CI environment"
        )
        
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
