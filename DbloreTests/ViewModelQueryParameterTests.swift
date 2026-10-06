// ViewModelQueryParameterTests.swift
// Notebook runs bind stored :name values. A missing name is an error and sends nothing.

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Query Parameter Tests")
@MainActor
struct ViewModelQueryParameterTests {
  private let namedSQL = "SELECT id FROM t WHERE id = :id"
  private let rewrittenSQL = "SELECT id FROM t WHERE id = $1"
  private let boundValue = "bound-value"

  @Test("A cell run rewrites :id and binds the stored value")
  func cellRunBindsNamedParameter() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: boundValue)])
    let cellId = viewModel.notebook.cells[0].id

    let result = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))

    #expect(result?.error == nil)
    #expect(session.statements == [rewrittenSQL])
    #expect(session.statementBinds == [[.text(boundValue)]])
  }

  @Test("A multi-statement cell binds each statement")
  func multiStatementCellBindsEachStatement() async throws {
    let first = "SELECT id FROM t WHERE id = :id"
    let second = "SELECT name FROM t WHERE name = :name"
    let sql = "\(first); \(second)"
    let (viewModel, session) = try await connectedViewModel(
      sql: sql,
      parameters: [
        QueryParameter(name: "id", value: boundValue),
        QueryParameter(name: "name", value: "name-value"),
      ])
    let cellId = viewModel.notebook.cells[0].id

    let result = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: sql))

    #expect(result?.error == nil)
    #expect(
      session.statements == [
        "SELECT id FROM t WHERE id = $1",
        "SELECT name FROM t WHERE name = $1",
      ])
    #expect(session.statementBinds == [[.text(boundValue)], [.text("name-value")]])
  }

  @Test("A missing parameter sends nothing and opens the cell's parameter form")
  func missingParameterSendsNothing() async throws {
    let (viewModel, session) = try await connectedViewModel(sql: namedSQL)
    let cellId = viewModel.notebook.cells[0].id

    let result = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))

    let error = try #require(result?.error)
    #expect(error.contains("id"))
    #expect(error.contains("Nothing was executed"))
    #expect(session.statements.isEmpty)
    #expect(viewModel.openParameterFormCellIds.contains(cellId))
    #expect(!viewModel.isRightSidebarVisible)
    #expect(!viewModel.queryConfirmationState.showDialog)

    viewModel.notebook.cells[0].content = "DELETE FROM t WHERE id = :id"
    viewModel.confirmAndRunCell(id: cellId)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.notebook.cells[0].result?.error?.contains("Nothing was executed") == true)
  }

  @Test("Read-only allows SELECT :delete and blocks a parameterized DELETE")
  func readOnlyClassifiesRewrittenNames() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        connectionConfig: ConnectionConfig(
          protectionLevel: .readOnly, safeMode: .alertRead, protectedMode: false)))

    #expect(viewModel.protectionBlockMessage(for: "SELECT :delete") == nil)
    #expect(viewModel.protectionBlockMessage(for: "DELETE FROM t WHERE id = :id") != nil)
  }

  @Test("alertRead confirms DELETE :id with the original preview and skips SELECT :id")
  func safeModePreviewKeepsNamedParameter() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        connectionConfig: ConnectionConfig(
          protectionLevel: .none, safeMode: .alertRead, protectedMode: false)))
    viewModel.editorParameters = [QueryParameter(name: "id", value: boundValue)]

    #expect(!viewModel.presentConfirmationIfNeeded(for: "SELECT :id", cellId: nil))
    #expect(!viewModel.queryConfirmationState.showDialog)

    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE id = :id", cellId: nil))
    let preview = viewModel.queryConfirmationState.statements.first?.preview ?? ""
    #expect(preview.contains(":id"))
    #expect(!preview.contains("$1"))
    #expect(!preview.contains("?1"))
    #expect(viewModel.queryConfirmationState.statements.first?.kindLabel == "Data modification")
    #expect(viewModel.queryConfirmationState.affectsAllRows == false)
  }

  @Test("An editor run passes the same binds")
  func editorRunBindsNamedParameter() async throws {
    let (viewModel, session) = try await connectedViewModel(sql: namedSQL)
    viewModel.editorParameters = [QueryParameter(name: "id", value: boundValue)]
    viewModel.viewMode = .editor
    viewModel.editorContent = namedSQL
    let previousSimpleMode = AppSettings.shared.editorSimpleMode
    AppSettings.shared.editorSimpleMode = false
    defer { AppSettings.shared.editorSimpleMode = previousSimpleMode }

    await viewModel.runEditorQuery()

    #expect(session.statements == [rewrittenSQL])
    #expect(session.statementBinds == [[.text(boundValue)]])
  }

  @Test("A missing editor parameter still opens the Parameters sidebar")
  func editorMissingParameterOpensSidebar() async throws {
    let (viewModel, session) = try await connectedViewModel(sql: "SELECT 1")
    viewModel.viewMode = .editor
    viewModel.editorContent = namedSQL
    let previousSimpleMode = AppSettings.shared.editorSimpleMode
    AppSettings.shared.editorSimpleMode = false
    defer { AppSettings.shared.editorSimpleMode = previousSimpleMode }

    await viewModel.runEditorQuery()

    let error = try #require(viewModel.editorResult?.error)
    #expect(error.contains("id"))
    #expect(error.contains("Nothing was executed"))
    #expect(session.statements.isEmpty)
    #expect(viewModel.rightSidebarContent == .parameters)
    #expect(viewModel.isRightSidebarVisible)
    #expect(viewModel.openParameterFormCellIds.isEmpty)
  }

  @Test("Run All passes the same binds")
  func runAllBindsNamedParameter() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: boundValue)])

    await viewModel.runAllCells(bypass: true)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements == [rewrittenSQL])
    #expect(session.statementBinds == [[.text(boundValue)]])
  }

  @Test("Run All stops before any cell when a parameter is missing")
  func runAllStopsWhenParameterMissing() async throws {
    let (viewModel, session) = try await connectedViewModel(sql: "SELECT 1")
    viewModel.notebook.cells.append(
      NotebookCell(cellType: .sql, content: namedSQL))
    let parameterCellId = viewModel.notebook.cells[1].id

    await viewModel.runAllCells(bypass: true)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements.isEmpty)
    #expect(viewModel.notebook.cells[0].result == nil)
    let error = try #require(viewModel.notebook.cells[1].result?.error)
    #expect(error.contains("id"))
    #expect(error.contains("Nothing was executed"))
    #expect(viewModel.openParameterFormCellIds.contains(parameterCellId))
    #expect(!viewModel.isRightSidebarVisible)
  }

  @Test("Explain binds :id and sends nothing when the value is missing")
  func explainBindsNamedParameter() async throws {
    let (viewModel, session) = try await connectedViewModel(sql: namedSQL)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.selectedCellId = cellId

    await viewModel.explain(statement: namedSQL, analyze: false, buffers: false, cellId: cellId)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements.isEmpty)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.notebook.cells[0].result?.error?.contains("Nothing was executed") == true)
    #expect(viewModel.openParameterFormCellIds.contains(cellId))
    #expect(!viewModel.isRightSidebarVisible)

    viewModel.notebook.cells[0].parameters = [QueryParameter(name: "id", value: boundValue)]
    await viewModel.explain(statement: namedSQL, analyze: false, buffers: false, cellId: cellId)
    await viewModel.executionQueue.waitForIdle()

    #expect(
      session.statements == ["EXPLAIN (FORMAT JSON) SELECT id FROM t WHERE id = $1"])
    #expect(session.statementBinds == [[.text(boundValue)]])
  }

  @Test("A confirmed run binds the value from the dialog, not a later edit")
  func confirmedRunKeepsSnapshottedBind() async throws {
    let sql = "DELETE FROM t WHERE id = :id"
    let (viewModel, session) = try await connectedViewModel(
      sql: sql, parameters: [QueryParameter(name: "id", value: "first")])
    let cellId = viewModel.notebook.cells[0].id

    viewModel.confirmAndRunCell(id: cellId)
    viewModel.notebook.cells[0].parameters = [QueryParameter(name: "id", value: "second")]
    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statementBinds == [[.text("first")]])
  }

  @Test("A query change drops the confirmed binds")
  func mismatchedQueryDropsConfirmedBinds() async throws {
    let live = "live-value"
    let secret = "secret-value"
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: live)])
    let cellId = viewModel.notebook.cells[0].id
    ConfirmedParameterSnapshot.stashCell(
      viewModel, cellId: cellId, query: namedSQL, values: ["id": .text(secret)])

    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: "SELECT 1"))
    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))

    #expect(session.statementBinds.contains([.text(live)]))
    #expect(!session.statementBinds.contains([.text(secret)]))
  }

  @Test("A run that stops before send drops the confirmed binds")
  func abandonedRunDropsConfirmedBinds() async throws {
    let live = "live-value"
    let secret = "secret-value"
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: live)])
    let cellId = viewModel.notebook.cells[0].id
    let manager = viewModel.connectionManager
    viewModel.connectionManager = nil
    ConfirmedParameterSnapshot.stashCell(
      viewModel, cellId: cellId, query: namedSQL, values: ["id": .text(secret)])

    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))
    viewModel.connectionManager = manager
    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))

    #expect(session.statementBinds == [[.text(live)]])
  }

  @Test("Cancelling a cell drops its confirmed binds")
  func cancelCellDropsConfirmedBinds() async throws {
    let live = "live-value"
    let secret = "secret-value"
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: live)])
    let cellId = viewModel.notebook.cells[0].id
    ConfirmedParameterSnapshot.stashCell(
      viewModel, cellId: cellId, query: namedSQL, values: ["id": .text(secret)])

    viewModel.cancelCell(id: cellId)
    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))

    #expect(session.statementBinds == [[.text(live)]])
  }

  @Test("Cancelling the dialog does not send the explain snapshot")
  func cancelDropsExplainSnapshot() async throws {
    let live = "live-value"
    let secret = "secret-value"
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: live)])
    let cellId = viewModel.notebook.cells[0].id
    ConfirmedParameterSnapshot.armExplain(
      viewModel, sql: namedSQL, values: ["id": .text(secret)])
    viewModel.pendingExplainSQL = namedSQL

    viewModel.cancelPendingQuery()
    await viewModel.runExplained(namedSQL, cellId: cellId)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statementBinds == [[.text(live)]])
  }

  @Test("Confirmation names the snapshotted value; history keeps :id")
  func confirmationNamesValueAndHistoryKeepsName() async throws {
    let sql = "DELETE FROM t WHERE id = :id"
    let (viewModel, _) = try await connectedViewModel(
      sql: sql, parameters: [QueryParameter(name: "id", value: "first")])
    let recorder = ParameterHistoryRecorder()
    viewModel.historyRecorder = recorder
    let suiteName = "ViewModelQueryParameterTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    viewModel.historySettings = settings
    let cellId = viewModel.notebook.cells[0].id

    viewModel.confirmAndRunCell(id: cellId)
    let statement = try #require(viewModel.queryConfirmationState.statements.first)
    let summary = NotebookViewModel.confirmationSummary(
      viewModel.queryConfirmationState.statements)
    #expect(summary.contains("first"))
    #expect(statement.preview.contains(":id"))
    #expect(!statement.preview.contains("$1"))

    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()
    let recorded = await waitForHistory(recorder)
    let history = try #require(recorded.first)
    #expect(history.contains(":id"))
    #expect(!history.contains("first"))
  }

  @Test("LIKE % sets the pattern flag and does not say no WHERE")
  func likePercentSetsPatternFlagNotMissingWhere() {
    let sql = "DELETE FROM t WHERE name LIKE :pat"
    let viewModel = parameterViewModel(value: "%")
    #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
    let state = viewModel.queryConfirmationState
    let statement = state.statements.first
    let summary = NotebookViewModel.confirmationSummary(state.statements)
    let reasons = statement?.reasons.joined(separator: "\n") ?? ""
    #expect(state.likePatternAffectsAllRows)
    #expect(statement?.likePatternAffectsAllRows == true)
    #expect(!state.affectsAllRows)
    #expect(statement?.affectsAllRows == false)
    #expect(summary.contains("LIKE pattern is % — affects all rows"))
    #expect(reasons.contains("LIKE pattern is % — affects all rows"))
    #expect(!summary.lowercased().contains("no where"))
    #expect(!reasons.lowercased().contains("no where"))
  }

  @Test("Cast and calls of a percent bind set the pattern flag")
  func likeCastAndCallSetFlag() {
    for sql in [
      "DELETE FROM t WHERE name LIKE :pat::text",
      "DELETE FROM t WHERE name LIKE (:pat)::text",
      "DELETE FROM t WHERE name LIKE lower(:pat)",
      "DELETE FROM t WHERE name LIKE CAST(:pat AS text)",
      "DELETE FROM t WHERE name LIKE CAST(:pat AS character varying)",
    ] {
      let viewModel = parameterViewModel(value: "%")
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
  }

  @Test("replace that yields % sets the flag and the preview keeps the wildcard")
  func likeReplaceYieldingPercentSetsFlag() {
    let long = String(repeating: "n", count: 120)
    let sql = "DELETE FROM t WHERE name LIKE replace(:pat, '\(long)', '%')"
    let viewModel = parameterViewModel(value: long)
    #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
    let state = viewModel.queryConfirmationState
    let preview = state.statements.first?.preview ?? ""
    #expect(state.likePatternAffectsAllRows)
    #expect(preview.contains("%"))
    #expect(preview.contains("…"))
    #expect(preview.hasPrefix("DELETE FROM t WHERE name LIKE replace"))
  }

  @Test("A long confirmation preview keeps the opening predicate")
  func previewKeepsOpeningPredicate() {
    let sql =
      "DELETE FROM t WHERE name LIKE '"
      + String(repeating: "n", count: 30)
      + "' OR true AND id = 1 /* "
      + String(repeating: "x", count: 40)
      + " % */"
    let viewModel = parameterViewModel(value: "1")
    #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
    let preview = viewModel.queryConfirmationState.statements.first?.preview ?? ""
    #expect(preview.contains("OR true"))
    #expect(preview.hasPrefix(String(sql.prefix(79))))
    #expect(!preview.contains("%"))
  }

  @Test("A literal percent and a percent concat set the flag")
  func likeLiteralPercentSetsFlag() {
    let literal = parameterViewModel(value: "1")
    #expect(
      literal.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE '%' AND id = :pat", cellId: nil))
    #expect(literal.queryConfirmationState.likePatternAffectsAllRows)

    let concatenated = parameterViewModel(value: "%")
    #expect(
      concatenated.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE :pat || '%'", cellId: nil))
    #expect(concatenated.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("replace that does not yield percent does not set the flag")
  func likeReplaceOtherDoesNotFlag() {
    let viewModel = parameterViewModel(value: "abc")
    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE replace(:pat, 'b', 'x')", cellId: nil))
    #expect(!viewModel.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("A partial cast or a call that contains a literal does not set the flag")
  func likeCastOfPartialOrLiteralDoesNotFlag() {
    let partial = parameterViewModel(value: "a%")
    #expect(
      partial.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE :pat::text", cellId: nil))
    #expect(!partial.queryConfirmationState.likePatternAffectsAllRows)

    let literal = parameterViewModel(value: "%")
    #expect(
      literal.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE lower(:pat || 'x')", cellId: nil))
    #expect(!literal.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("An even NOT count keeps the pattern flag and an odd count cancels it")
  func likeNegationParity() {
    for sql in [
      "DELETE FROM t WHERE NOT (name NOT LIKE :pat)",
      "DELETE FROM t WHERE NOT NOT name LIKE :pat",
      "DELETE FROM t WHERE NOT (name !~~ :pat)",
    ] {
      let viewModel = parameterViewModel(value: "%")
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
    for sql in [
      "DELETE FROM t WHERE NOT (name LIKE :pat)",
      "DELETE FROM t WHERE NOT name LIKE :pat",
      "DELETE FROM t WHERE name NOT LIKE :pat::text",
    ] {
      let viewModel = parameterViewModel(value: "%")
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(!viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
  }

  @Test("NOT LIKE and NOT ILIKE do not set the pattern flag")
  func negatedLikeDoesNotFlag() {
    for sql in [
      "DELETE FROM t WHERE name NOT LIKE :pat",
      "DELETE FROM t WHERE name NOT ILIKE :pat",
    ] {
      let viewModel = parameterViewModel(value: "%")
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(!viewModel.queryConfirmationState.likePatternAffectsAllRows)
      let statement = viewModel.queryConfirmationState.statements.first
      #expect(statement?.likePatternAffectsAllRows == false)
    }
  }

  @Test("LIKE (:pat) with % sets the pattern flag")
  func likeParenthesizedBindSetsFlag() {
    let sql = "DELETE FROM t WHERE name LIKE (:pat)"
    let viewModel = parameterViewModel(value: "%")
    #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
    #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("%% and a trimmed percent run set the flag; a% and empty do not")
  func likePercentRunSetsFlagPartialDoesNot() {
    let sql = "DELETE FROM t WHERE name LIKE :pat"
    for value in ["%%", " % "] {
      let viewModel = parameterViewModel(value: value)
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
    for value in ["a%", ""] {
      let viewModel = parameterViewModel(value: value)
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(!viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
  }

  @Test("LIKE :a || :b flags only when every bind trims to percent")
  func likeConcatenationRequiresEveryBind() {
    let sql = "DELETE FROM t WHERE name LIKE :a || :b"
    let both = parameterViewModel(parameters: [
      QueryParameter(name: "a", value: "%"),
      QueryParameter(name: "b", value: "%%"),
    ])
    #expect(both.presentConfirmationIfNeeded(for: sql, cellId: nil))
    #expect(both.queryConfirmationState.likePatternAffectsAllRows)

    let mixed = parameterViewModel(parameters: [
      QueryParameter(name: "a", value: "%"),
      QueryParameter(name: "b", value: "a%"),
    ])
    #expect(mixed.presentConfirmationIfNeeded(for: sql, cellId: nil))
    #expect(!mixed.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("~~ and ~~* set the pattern flag; !~~ does not")
  func posixLikeOperatorSetsFlag() {
    for sql in [
      "DELETE FROM t WHERE name ~~ :pat",
      "DELETE FROM t WHERE name ~~* :pat",
    ] {
      let viewModel = parameterViewModel(value: "%")
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
      #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
    }
    let negated = parameterViewModel(value: "%")
    let negatedSQL = "DELETE FROM t WHERE name !~~ :pat"
    #expect(negated.presentConfirmationIfNeeded(for: negatedSQL, cellId: nil))
    #expect(!negated.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("EXPLAIN ANALYZE of a LIKE delete sets the flag; plain EXPLAIN does not")
  func explainAnalyzeLikeSetsFlagPlainExplainDoesNot() {
    let analyzed = parameterViewModel(value: "%")
    #expect(
      analyzed.presentConfirmationIfNeeded(
        for: "EXPLAIN ANALYZE DELETE FROM t WHERE name LIKE :pat", cellId: nil))
    #expect(analyzed.queryConfirmationState.likePatternAffectsAllRows)

    let plain = parameterViewModel(value: "%", safeMode: .alertAll)
    #expect(
      !plain.presentConfirmationIfNeeded(
        for: "EXPLAIN DELETE FROM t WHERE name LIKE :pat", cellId: nil))
    #expect(!plain.queryConfirmationState.showDialog)
    #expect(plain.queryConfirmationState.statements.isEmpty)
  }

  @Test("A newline in a bind stays on the parameter line")
  func confirmationNoteKeepsValueOnOneLine() {
    let viewModel = parameterViewModel(parameters: [
      QueryParameter(name: "pat", value: "%\n! No WHERE — affects all rows")
    ])
    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE :pat", cellId: nil))
    let summary = NotebookViewModel.confirmationSummary(
      viewModel.queryConfirmationState.statements)
    let reasonLines = summary.split(separator: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("!")
    }
    #expect(summary.contains("\"pat\" = \"% ! No WHERE — affects all rows\""))
    #expect(reasonLines.allSatisfy { $0.contains("LIKE pattern is %") })
    #expect(!reasonLines.contains { $0.contains("No WHERE") })
  }

  @Test("immediate does not confirm a brake SET or a later LIKE delete")
  func immediateSkipsBrakeAndLikeDelete() {
    let viewModel = parameterViewModel(value: "%", safeMode: .silent)
    let sql = "SET statement_timeout = 0; DELETE FROM t WHERE name LIKE :pat"
    #expect(!viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil))
    let state = viewModel.queryConfirmationState
    #expect(!state.showDialog)
    #expect(!state.likePatternAffectsAllRows)
    #expect(state.statements.isEmpty)
  }

  @Test("A line break in a parameter name stays on the parameter line")
  func confirmationNoteKeepsNameOnOneLine() {
    let name = "pat\u{2028}rest"
    let viewModel = parameterViewModel(parameters: [
      QueryParameter(name: name, value: "%")
    ])
    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE :\(name)", cellId: nil))
    let summary = NotebookViewModel.confirmationSummary(
      viewModel.queryConfirmationState.statements)
    #expect(summary.contains("\"pat rest\" = \"%\""))
    #expect(!summary.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{0085}" })
  }

  @Test("A bind note quotes a comma and drops a bidi override")
  func confirmationNoteQuotesValueAndDropsFormatCharacters() {
    let viewModel = parameterViewModel(parameters: [
      QueryParameter(name: "id\u{202E}", value: "1, role = admin\u{202E}")
    ])
    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE id = :id\u{202E}", cellId: nil))
    let note = viewModel.queryConfirmationState.statements.first?.parameterNote ?? ""
    #expect(note == "\"id\" = \"1, role = admin\"")
    #expect(!note.unicodeScalars.contains { $0.value == 0x202E })
  }

  @Test("A percent literal, escape string, or dollar quote sets the flag with no bind")
  func likeConstantPercentSetsFlag() {
    let patterns = [
      "DELETE FROM t WHERE name LIKE '%'",
      "DELETE FROM t WHERE name LIKE E'\\045'",
      "DELETE FROM t WHERE name LIKE E'\\x25'",
      "DELETE FROM t WHERE name LIKE $$%$$",
      "DELETE FROM t WHERE name LIKE $tag$%$tag$",
      "DELETE FROM t WHERE name LIKE chr(37)",
      "DELETE FROM t WHERE name LIKE char(37)",
    ]
    for sql in patterns {
      let viewModel = alertReadViewModel()
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil), "\(sql)")
      #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows, "\(sql)")
    }
  }

  @Test("A narrow literal, a non-percent code point, and a plain backslash do not set the flag")
  func likeConstantOtherDoesNotFlag() {
    let patterns = [
      "DELETE FROM t WHERE name LIKE 'a%'",
      "DELETE FROM t WHERE name LIKE chr(65)",
      "DELETE FROM t WHERE name LIKE E'\\\\%'",
      "DELETE FROM t WHERE name LIKE $$a%$$",
    ]
    for sql in patterns {
      let viewModel = alertReadViewModel()
      #expect(viewModel.presentConfirmationIfNeeded(for: sql, cellId: nil), "\(sql)")
      #expect(!viewModel.queryConfirmationState.likePatternAffectsAllRows, "\(sql)")
    }
  }

  @Test("chr of a bound code point 37 sets the flag")
  func likeChrBindSetsFlag() {
    let viewModel = parameterViewModel(parameters: [QueryParameter(name: "n", value: "37")])
    #expect(
      viewModel.presentConfirmationIfNeeded(
        for: "DELETE FROM t WHERE name LIKE chr(:n)", cellId: nil))
    #expect(viewModel.queryConfirmationState.likePatternAffectsAllRows)
  }

  @Test("A script parameter edit does not mark the file dirty")
  func scriptParameterEditDoesNotNotify() {
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(documentType: .script))
    var notifications = 0
    viewModel.onDocumentChanged = { notifications += 1 }

    viewModel.updateParameter("%", for: "pat")
    viewModel.updateParameter("%", for: "pat")

    #expect(viewModel.editorParameters == [QueryParameter(name: "pat", value: "%")])
    #expect(notifications == 0)
  }

  @Test("A cell parameter edit marks the file dirty only when the cell saves values")
  func cellParameterEditNotifies() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        cells: [NotebookCell(cellType: .sql, content: "SELECT :pat")]))
    let cellId = viewModel.notebook.cells[0].id
    var notifications = 0
    viewModel.onDocumentChanged = { notifications += 1 }

    viewModel.updateParameter("a", for: "pat", cellId: cellId)

    #expect(viewModel.notebook.cells[0].parameters == [QueryParameter(name: "pat", value: "a")])
    #expect(notifications == 0)

    viewModel.setSavesParameterValues(true, cellId: cellId)
    #expect(notifications == 1)

    viewModel.updateParameter("b", for: "pat", cellId: cellId)

    #expect(viewModel.notebook.cells[0].parameters == [QueryParameter(name: "pat", value: "b")])
    #expect(notifications == 2)
  }

  @Test("Removing an unused editor parameter drops it; a used one stays")
  func removeUnusedParameter() {
    let viewModel = NotebookViewModel(notebook: DbloreNotebook())
    viewModel.viewMode = .editor
    viewModel.editorContent = "SELECT :used"
    viewModel.editorParameters = [
      QueryParameter(name: "used", value: "1"),
      QueryParameter(name: "old", value: "secret"),
    ]
    let previousSimpleMode = AppSettings.shared.editorSimpleMode
    AppSettings.shared.editorSimpleMode = false
    defer { AppSettings.shared.editorSimpleMode = previousSimpleMode }
    var notifications = 0
    viewModel.onDocumentChanged = { notifications += 1 }

    viewModel.removeUnusedParameter(named: "used")
    #expect(viewModel.editorParameters.map(\.name) == ["used", "old"])
    #expect(notifications == 0)

    viewModel.removeUnusedParameter(named: "old")
    #expect(viewModel.editorParameters == [QueryParameter(name: "used", value: "1")])
    #expect(notifications == 0)
  }

  @Test("Removing an unused script parameter does not mark the file dirty")
  func removeUnusedScriptParameterDoesNotNotify() {
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(documentType: .script))
    viewModel.viewMode = .editor
    viewModel.editorParameters = [QueryParameter(name: "old", value: "secret")]
    var notifications = 0
    viewModel.onDocumentChanged = { notifications += 1 }

    viewModel.removeUnusedParameter(named: "old")

    #expect(viewModel.editorParameters.isEmpty)
    #expect(notifications == 0)
  }

  @Test("Run All unlock copies the LIKE pattern flag and does not say no WHERE")
  func runAllUnlockCopiesLikePatternFlag() async {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        cells: [
          NotebookCell(
            cellType: .sql, content: "DELETE FROM t WHERE name LIKE :pat",
            parameters: [QueryParameter(name: "pat", value: "%")])
        ],
        connectionConfig: ConnectionConfig(
          protectionLevel: .none, safeMode: .safeAll, protectedMode: false)))

    await viewModel.runAllCells()

    let state = viewModel.queryConfirmationState
    let statement = state.statements.first
    let reasons = statement?.reasons.joined(separator: "\n") ?? ""
    #expect(state.runAllAwaitingUnlock)
    #expect(state.likePatternAffectsAllRows)
    #expect(statement?.likePatternAffectsAllRows == true)
    #expect(!state.affectsAllRows)
    #expect(reasons.contains("LIKE pattern is % — affects all rows"))
    #expect(!reasons.lowercased().contains("no where"))
    #expect(viewModel.executionQueue.tasks.isEmpty)
  }

  @Test("DELETE without WHERE keeps the no-WHERE warning")
  func deleteWithoutWhereKeepsNoWhereWarning() {
    let viewModel = parameterViewModel(value: "%")
    #expect(viewModel.presentConfirmationIfNeeded(for: "DELETE FROM t", cellId: nil))
    let state = viewModel.queryConfirmationState
    let summary = NotebookViewModel.confirmationSummary(state.statements)
    #expect(state.affectsAllRows)
    #expect(!state.likePatternAffectsAllRows)
    #expect(summary.contains("No WHERE — affects all rows"))
    #expect(!summary.contains("LIKE pattern is % — affects all rows"))
    #expect(state.statements.first?.reasons.contains("No WHERE — affects all rows") == true)
  }

  @Test("History records :id and not the bound value")
  func historyKeepsNamedSQL() async throws {
    let (viewModel, _) = try await connectedViewModel(
      sql: namedSQL, parameters: [QueryParameter(name: "id", value: boundValue)])
    let recorder = ParameterHistoryRecorder()
    viewModel.historyRecorder = recorder
    let suiteName = "ViewModelQueryParameterTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    viewModel.historySettings = settings
    let cellId = viewModel.notebook.cells[0].id

    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: namedSQL))
    let recorded = await waitForHistory(recorder)

    let sql = try #require(recorded.first)
    #expect(sql.contains(":id"))
    #expect(!sql.contains(boundValue))
  }

  private func alertReadViewModel() -> NotebookViewModel {
    parameterViewModel(parameters: [])
  }

  private func parameterViewModel(
    value: String, safeMode: SafeMode = .alertRead
  ) -> NotebookViewModel {
    parameterViewModel(
      parameters: [QueryParameter(name: "pat", value: value)], safeMode: safeMode)
  }

  private func parameterViewModel(
    parameters: [QueryParameter], safeMode: SafeMode = .alertRead
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        connectionConfig: ConnectionConfig(
          protectionLevel: .none, safeMode: safeMode, protectedMode: false)))
    viewModel.editorParameters = parameters
    return viewModel
  }

  private func connectedViewModel(
    sql: String, parameters: [QueryParameter] = []
  ) async throws -> (NotebookViewModel, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .alertRead,
      protectedMode: false)
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        cells: [NotebookCell(cellType: .sql, content: sql, parameters: parameters)],
        connectionConfig: config))
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    let session = try #require(factory.sessions.first)
    return (viewModel, session)
  }

  private func waitForHistory(_ recorder: ParameterHistoryRecorder) async -> [String] {
    for _ in 0..<50 {
      let sql = await recorder.sql
      if !sql.isEmpty { return sql }
      await Task.yield()
    }
    return await recorder.sql
  }
}

private actor ParameterHistoryRecorder: QueryHistoryRecording {
  private(set) var sql: [String] = []

  func record(_ entry: QueryHistoryEntry) async {
    sql.append(entry.sql)
  }
}
