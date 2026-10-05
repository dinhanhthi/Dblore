// QueryBindThreadingTests.swift
// Binds travel with the user statement. Results can keep the original text while the
// classified text is what the session receives.

import Foundation
import Testing

@testable import Dblore

@Suite("Query Bind Threading")
struct QueryBindThreadingTests {
  private func connect(
    rows: [[CellValue]] = []
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return (manager, factory)
  }

  private func classified(_ texts: [String]) throws -> [ClassifiedStatement] {
    var statements: [ClassifiedStatement] = []
    for text in texts {
      statements.append(try #require(SQLStatementClassifier.classifyStatement(text)))
    }
    return statements
  }

  @Test("A non-empty bind list reaches command, query, and openCursor")
  func bindsReachCommandQueryAndOpenCursor() async throws {
    let (manager, factory) = try await connect()
    let select = "SELECT id FROM items WHERE id = $1"
    let insert = "INSERT INTO items (id) VALUES ($1) RETURNING id"
    let update = "UPDATE items SET name = $1"
    let delete = "DELETE FROM items"
    let statements = try classified([select, insert, "BEGIN", select, update, delete])
    let queryBinds: [SQLBindValue] = [.text("q"), .null]
    let returningBinds: [SQLBindValue] = [.text("r")]
    let cursorBinds: [SQLBindValue] = [.text("c")]
    let commandBinds: [SQLBindValue] = [.text("u")]

    _ = try await manager.runUserStatements(
      statements, protectedMode: false, maxRows: 2, caller: nil,
      binds: [queryBinds, returningBinds, [], cursorBinds, commandBinds])

    let session = try #require(factory.sessions.first)
    #expect(factory.sessions.count == 1)
    #expect(session.queries == [select, insert])
    #expect(session.openCursorCount == 1)
    #expect(
      session.statements == [
        select, insert, "BEGIN", select, "FETCH 3", "CLOSE fake_cap", update, delete,
      ])
    #expect(
      session.statementBinds == [
        queryBinds, returningBinds, [], cursorBinds, [], [], commandBinds, [],
      ])
  }

  @Test("runUserStatements keeps the original text and sends the classified text")
  func runUserStatementsKeepsOriginalText() async throws {
    let rows = [[CellValue.int(1)], [CellValue.int(2)]]
    let (manager, factory) = try await connect(rows: rows)
    let sent = [
      "UPDATE items SET name = $1",
      "SELECT id FROM items WHERE id = $1",
      "DELETE FROM items WHERE id = $1",
    ]
    let originals = [
      "UPDATE items SET name = :name",
      "SELECT id FROM items WHERE id = :id",
      "DELETE FROM items WHERE id = :id",
    ]

    let run = try await manager.runUserStatements(
      try classified(sent), protectedMode: false, maxRows: 1, caller: nil,
      originalTexts: originals)

    #expect(run.results.map(\.queryText) == [originals[0], originals[1]])
    #expect(run.results[1].result.sessionReset)
    #expect(run.results[1].result.skippedStatements == [originals[2]])
    #expect(factory.statements == [sent[0], sent[1]])
  }
}
