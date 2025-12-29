//
//  SQLNotebookTests.swift
//  SQLNotebookTests
//
//  Created by Anh-Thi Dinh on 12/29/25.
//

import Testing
@testable import SQLNotebook
import PostgresNIO

@Suite("PostgresNIO Integration")
struct SQLNotebookTests {

    @Test("PostgresNIO dependency is available")
    func postgresNIOImport() async throws {
        // Verify PostgresNIO dependency is available
        // This test checks that we can reference PostgresNIO types
        let _: PostgresConnection.Configuration? = nil
        #expect(true, "PostgresNIO imported successfully")
    }
}
