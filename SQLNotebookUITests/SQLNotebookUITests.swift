//
//  SQLNotebookUITests.swift
//  SQLNotebookUITests
//
//  Created by Anh-Thi Dinh on 12/29/25.
//
// MARK: - UI Tests
// These tests run by default locally and are skipped in CI via SKIP_UI_TESTS=true

import XCTest

final class SQLNotebookUITests: XCTestCase {

    override func setUpWithError() throws {
        // Skip all UI tests if SKIP_UI_TESTS environment variable is set
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SKIP_UI_TESTS"] == "true",
            "UI tests skipped in CI environment"
        )
        
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
