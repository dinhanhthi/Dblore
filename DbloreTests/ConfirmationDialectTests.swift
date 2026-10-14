// ConfirmationDialectTests.swift
// Safe Mode confirmation and notebook execution lex with the connection dialect: MySQL
// backslash strings in LIKE operands, MySQL `#` comments in the preview, and SQLite
// statement splitting in editor and cell runs.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Confirmation and execution dialect")
struct ConfirmationDialectTests {

  // MARK: - Safe Mode LIKE check

  @Test("MySQL decodes backslash escapes in a LIKE operand, keeping \\% and \\_")
  func mysqlLikeBackslashRule() {
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE '%\n'"#, .mysql))
    #expect(!matchesAll(#"DELETE FROM t WHERE a LIKE '\%'"#, .mysql))
    #expect(!matchesAll(#"DELETE FROM t WHERE a LIKE '\x25'"#, .mysql))
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE "%""#, .mysql))
  }

  @Test("MySQL LIKE fails closed on ||, OR, introducers and hex literals")
  func mysqlLikeFailsClosed() {
    #expect(matchesAll("DELETE FROM t WHERE name LIKE '%' || 'x'", .mysql))
    #expect(matchesAll("DELETE FROM t WHERE name LIKE 'a' OR 1", .mysql))
    #expect(matchesAll("DELETE FROM t WHERE name LIKE N'%'", .mysql))
    #expect(matchesAll("DELETE FROM t WHERE name LIKE _utf8mb4'%'", .mysql))
    #expect(matchesAll("DELETE FROM t WHERE name LIKE 0x25", .mysql))
    #expect(matchesAll("DELETE FROM t WHERE name LIKE X'25'", .mysql))
    #expect(!matchesAll("DELETE FROM t WHERE name LIKE 'abc%'", .mysql))
    #expect(!matchesAll("DELETE FROM t WHERE name LIKE '%' || 'x'", .postgresql))
  }

  @Test("MySQL LIKE fails closed on bit literals, introducers, BINARY, OR and comments")
  func mysqlLikeFailsClosedOnEveryOperandForm() {
    for operand in [
      "0b100101", "B'00100101'", "_utf8mb4 0x25", "_binary X'25'", "_utf8mb4 B'00100101'",
      "'a' XOR 1", "'a' | | 1", "'a' /*! OR 1 */", "'a' /*!50000 OR 1 */", "BINARY '%'",
      "BINARY :p", "/*!'%'*/", "/*!50000 '%' */",
    ] {
      #expect(matchesAll("DELETE FROM t WHERE name LIKE \(operand)", .mysql, ["p": "%"]))
    }
  }

  @Test("MySQL REGEXP and RLIKE warn on match-all and unreadable patterns")
  func mysqlRegexpMatchAll() {
    for condition in [
      "name RLIKE '.*'", "name REGEXP ''", "name REGEXP '^'", "name REGEXP '^.*$'",
      "name REGEXP :p", "name REGEXP other", "name REGEXP 'abc' /*!50000 OR 1 */",
      "REGEXP_LIKE(name, '.*')",
    ] {
      #expect(matchesAll("DELETE FROM t WHERE \(condition)", .mysql, ["p": "$"]))
    }
    // Any pattern that matches the empty string matches every non-NULL row; `(` fails closed.
    for pattern in ["a*", "x?", "a|", "|", "(.*)", ".*?", ".{0,}", "^(.*)$", "()", "("] {
      #expect(matchesAll("DELETE FROM t WHERE name REGEXP '\(pattern)'", .mysql))
      #expect(!matchesAll("DELETE FROM t WHERE name NOT REGEXP '\(pattern)'", .mysql))
    }
    for condition in [
      "name NOT REGEXP '.*'", "name NOT RLIKE ''", "name REGEXP 'abc'", "name REGEXP '.'",
      "NOT REGEXP_LIKE(name, '.*')", "name REGEXP '^a'", "name REGEXP 'a+'",
    ] {
      #expect(!matchesAll("DELETE FROM t WHERE \(condition)", .mysql))
    }
    #expect(!matchesAll("DELETE FROM t WHERE name REGEXP '.*'", .postgresql))
  }

  @Test("MySQL joins adjacent string literals in LIKE and REGEXP operands")
  func mysqlAdjacentLiteralsJoin() {
    for condition in [
      "name LIKE '' '%'", #"name LIKE "" "%""#, "name LIKE _utf8mb4'' '%'", "name LIKE N'' '%'",
      "name LIKE '%' ''", "name LIKE '' /* x */ '%'", "name REGEXP 'a' '*'",
    ] {
      #expect(matchesAll("DELETE FROM t WHERE \(condition)", .mysql))
    }
    for condition in ["name LIKE 'a' '' '%'", "name REGEXP 'a' 'b'", "name LIKE 'ab' 'c%'"] {
      #expect(!matchesAll("DELETE FROM t WHERE \(condition)", .mysql))
    }
    #expect(!matchesAll("DELETE FROM t WHERE name LIKE '' '%'", .postgresql))
  }

  @Test("MySQL LIKE evaluates CONCAT, CONCAT_WS, IFNULL and COALESCE")
  func mysqlLikeStringFunctions() {
    for operand in [
      "CONCAT('', '%')", "CONCAT_WS('', '%')", "IFNULL(NULL, '%')", "COALESCE(NULL, '%')",
      "CONCAT(:p, '%')", "COALESCE(:n, '%')",
    ] {
      #expect(
        matchesAll("DELETE FROM t WHERE name LIKE \(operand)", .mysql, ["p": ""], nulls: ["n"]))
    }
    for operand in [
      "CONCAT('a', '%')", "CONCAT(NULL, '%')", "IFNULL('a', '%')", "COALESCE(col, '%')",
      "CONCAT_WS(NULL, '%')",
    ] {
      #expect(!matchesAll("DELETE FROM t WHERE name LIKE \(operand)", .mysql))
    }
    #expect(!matchesAll("DELETE FROM t WHERE name LIKE CONCAT('', '%')", .postgresql))
  }

  @Test("The confirmation preview skips a MySQL # comment")
  func mysqlPreviewSkipsHashComment() throws {
    let sql = "# note\nDELETE FROM t"
    let listed = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        SQLStatementClassifier.classify(sql, dialect: .mysql), commitStyle: .confirm,
        dialect: .mysql))
    #expect(listed.first?.preview == "DELETE FROM t")
  }

  private func matchesAll(
    _ sql: String, _ dialect: SQLDialect, _ texts: [String: String] = [:], nulls: [String] = []
  ) -> Bool {
    var parameters = texts.mapValues { SQLBindValue.text($0) }
    for name in nulls { parameters[name] = .null }
    return NotebookViewModel.scriptMatchesAllRowsByLike(
      SQLStatementClassifier.classify(sql, dialect: dialect), parameters: parameters,
      dialect: dialect)
  }

  // MARK: - Statement splitting

  /// One statement in SQLite (`[a;b]` is an identifier), two with PostgreSQL rules
  private static let bracketAlias = "SELECT 1 AS [a;b]"

  @Test("An editor run splits with the SQLite dialect", .timeLimit(.minutes(1)))
  func editorRunSplitsWithDialect() async throws {
    try await withSQLiteViewModel(cells: []) { viewModel in
      viewModel.viewMode = .editor
      await viewModel.executeEditorQuery(Self.bracketAlias)
      #expect(viewModel.editorResult?.error == nil)
      #expect(viewModel.editorResult?.columns.map(\.name) == ["a;b"])
      #expect(viewModel.editorStatementResults.isEmpty)
    }
  }

  @Test("A cell run splits with the SQLite dialect", .timeLimit(.minutes(1)))
  func cellRunSplitsWithDialect() async throws {
    try await withSQLiteViewModel(cells: [Self.bracketAlias]) { viewModel in
      await viewModel.runCell(id: viewModel.notebook.cells[0].id)
      await viewModel.executionQueue.waitForIdle()
      let cell = viewModel.notebook.cells[0]
      #expect(cell.result?.error == nil)
      #expect(cell.result?.columns.map(\.name) == ["a;b"])
      #expect(cell.statementResults.isEmpty)
    }
  }

  /// A connected SQLite view model over a temporary file
  private func withSQLiteViewModel(
    cells: [String], _ body: (NotebookViewModel) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-dialect-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    _ = try SQLiteHandle(url: url)
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = cells.map { NotebookCell(cellType: .sql, content: $0) }
    viewModel.notebook.connectionConfig = config
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.toastPresenter = { _, _ in }
    do {
      try await body(viewModel)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }
}
