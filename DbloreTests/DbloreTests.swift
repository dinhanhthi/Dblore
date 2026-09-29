//
//  DbloreTests.swift
//  DbloreTests
//
//  Created by Anh-Thi Dinh on 12/29/25.
//

import PostgresNIO
import Testing

@testable import Dblore

@Suite("PostgresNIO Integration")
@MainActor
struct DbloreTests {

  @Test("PostgresNIO dependency is available")
  func postgresNIOImport() async throws {
    // Verify PostgresNIO dependency is available
    // This test checks that we can reference PostgresNIO types
    let _: PostgresConnection.Configuration? = nil
    #expect(true, "PostgresNIO imported successfully")
  }
}
