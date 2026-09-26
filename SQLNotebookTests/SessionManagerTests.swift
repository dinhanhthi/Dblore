//
//  SessionManagerTests.swift
//  SQLNotebookTests
//

import Testing

@testable import SQLNotebook

@Suite("SessionManager launch restore")
struct SessionManagerTests {
  @Test("Does not restore session when running under XCTest")
  func skipsRestoreUnderXCTest() {
    let environment = ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]
    #expect(SessionManager.shouldRestoreSession(environment: environment) == false)
  }

  @Test("Restores session on normal launch")
  func restoresOnNormalLaunch() {
    #expect(SessionManager.shouldRestoreSession(environment: [:]) == true)
  }
}
