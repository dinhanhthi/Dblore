//
//  NotebookViewModel+Explain.swift
//  Dblore
//
//  Explain and Explain Analyze use the same protection check, Safe Mode confirmation,
//  execution, and history recording as a normal run. EXPLAIN ANALYZE runs the inner
//  statement, so it is never sent through executeInternal. MongoDB explains one find or
//  aggregate as its mongosh `.explain("executionStats")` text and has no Explain Analyze.
//

import Foundation

extension NotebookViewModel {
  /// Explain the statement the Run action would run: the editor selection (or the current
  /// line / file), or the selected notebook cell.
  func explainSelectedStatement(analyze: Bool) async {
    if analyze, refuseMongoExplainAnalyze() { return }
    if analyze, !canExplainAnalyze {
      if let reason = explainAnalyzeUnavailableReason { showToast(reason, type: .error) }
      return
    }
    if viewMode == .editor {
      guard dataViewer == nil, !isReadOnlySource, let text = getEditorQueryText(), !text.isEmpty
      else { return }
      await explain(statement: text, analyze: analyze, buffers: analyze)
      return
    }
    guard let id = selectedCellId,
      let cell = notebook.cells.first(where: { $0.id == id }),
      cell.cellType == .sql
    else { return }
    await explain(statement: cell.content, analyze: analyze, buffers: analyze, cellId: id)
  }

  /// Build an explain script and run it through `protectionBlockMessage`, Safe Mode, then
  /// `execute` / `executeDetailed`. `buffers` is on for Explain Analyze. Data-changing ANALYZE
  /// rolls back unless `rollbackAfterAnalyze` is false or a protected transaction is open.
  func explain(
    statement: String,
    analyze: Bool,
    buffers: Bool,
    rollbackAfterAnalyze: Bool = true,
    cellId: UUID? = nil
  ) async {
    if viewMode == .markdown { return }
    ConfirmedParameterSnapshot.disarmExplain(self)
    if isMongoConnection {
      await explainMongo(statement: statement, analyze: analyze, cellId: cellId)
      return
    }
    // Asked of the open session: the version the request is checked against is the live one.
    let mysqlServer = await connectionManager?.mysqlServerInfo
    let request: ExplainRequest
    do {
      request = try ExplainRequest(
        statement: statement, analyze: analyze, buffers: buffers,
        rollbackAfterAnalyze: rollbackAfterAnalyze, dialect: explainDialect,
        mysqlServer: mysqlServer)
    } catch let error as ExplainRequestError {
      showToast(error.message, type: .error)
      return
    } catch {
      showToast(error.localizedDescription, type: .error)
      return
    }

    let sql = request.sqlToRun(protectedTransactionOpen: await protectedTransactionOpen())
    if let message = protectionBlockMessage(for: sql) {
      showToast(message, type: .error)
      return
    }
    let targetCell = viewMode == .editor ? nil : (cellId ?? selectedCellId)
    if refuseMissingParameters(sql, cellId: targetCell) != nil { return }
    if presentConfirmationIfNeeded(for: sql, cellId: targetCell) {
      ConfirmedParameterSnapshot.armExplain(
        self, sql: sql, values: queryConfirmationState.parameterValues)
      pendingExplainSQL = sql
      pendingStagedBatch = nil
      return
    }
    await runExplained(sql, cellId: targetCell)
  }

  private var isMongoConnection: Bool {
    notebook.connectionConfig?.databaseType.capabilities.queryLanguage == .mongosh
  }

  /// MongoDB has no Explain Analyze: refused with a toast before anything is sent. True when
  /// refused.
  private func refuseMongoExplainAnalyze() -> Bool {
    guard isMongoConnection else { return false }
    showToast("Explain Analyze is not available for MongoDB connections", type: .error)
    return true
  }

  /// MongoDB Explain: one `find` (any chain) or read `aggregate` becomes its
  /// `.explain("executionStats")` text, then takes the same protection check, Safe Mode
  /// confirmation and send path as SQL. No `ExplainRequest`, so no SQL prefix is applied.
  private func explainMongo(statement: String, analyze: Bool, cellId: UUID?) async {
    if analyze, refuseMongoExplainAnalyze() { return }
    guard let script = mongoExplainScript(statement) else { return }
    if let message = protectionBlockMessage(for: script) {
      showToast(message, type: .error)
      return
    }
    let targetCell = viewMode == .editor ? nil : (cellId ?? selectedCellId)
    if refuseMissingParameters(script, cellId: targetCell) != nil { return }
    if presentConfirmationIfNeeded(for: script, cellId: targetCell) {
      ConfirmedParameterSnapshot.armExplain(
        self, sql: script, values: queryConfirmationState.parameterValues)
      pendingExplainSQL = script
      pendingStagedBatch = nil
      return
    }
    await runExplained(script, cellId: targetCell)
  }

  /// The explain text of exactly one `find` or `aggregate`, or nil after a toast. A pipeline
  /// that writes (`$out`, `$merge`) is refused: the classifier only lets an explain of a read
  /// through.
  private func mongoExplainScript(_ statement: String) -> String? {
    let needsOne = "Explain needs one find or aggregate"
    let pieces = MongoshSplitter.split(statement)
    guard pieces.count == 1 else {
      showToast(needsOne, type: .error)
      return nil
    }
    let command: MongoCommand
    do {
      command = try MongoshParser.parse(pieces[0])
    } catch {
      showToast(error.message, type: .error)
      return nil
    }
    switch command {
    case .find, .aggregate:
      let script = MongoCommand.explain(command, verbosity: "executionStats").render()
      guard MongoCommandClassifier.classifyStatement(script)?.kind == .read else {
        showToast("Explain runs reads only: this pipeline writes ($out or $merge)", type: .error)
        return nil
      }
      return script
    case .explain:
      showToast("This is already an explain", type: .error)
    default:
      showToast(needsOne, type: .error)
    }
    return nil
  }

  /// Protected mode owns the transaction even before the first statement opens it.
  /// An open user transaction is the same: do not send another BEGIN / ROLLBACK.
  private func protectedTransactionOpen() async -> Bool {
    if protectionPolicy.protectedMode { return true }
    guard let connectionManager else { return false }
    let snapshot = await connectionManager.transactionSnapshot()
    if !snapshot.isIdle { return true }
    return await connectionManager.runningStatementStatus().userTxOpen
  }

  private var explainDialect: SQLDialect {
    notebook.connectionConfig?.databaseType.dialect ?? .postgresql
  }

  /// Editor runs and cell runs both record the explain SQL through the normal history path.
  /// Called again after Safe Mode confirmation (`executePendingQuery`).
  func runExplained(_ sql: String, cellId: UUID?) async {
    let snapshotted = ConfirmedParameterSnapshot.takeExplain(self, sql: sql)
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    if viewMode != .editor, let cellId {
      await runCellStatement(id: cellId, query: sql, parameters: snapshotted)
      return
    }
    guard connectionState.isConnected else {
      showToast("Not connected to database", type: .error)
      return
    }
    let source: QueryHistoryRecordSource = viewMode == .editor ? .editor : .cell
    await executeEditorQuery(sql, source: source, parameters: snapshotted)
  }

  /// Same send path as `runCell`, with the explain script in place of the cell text.
  /// `parameters` is the dialog snapshot. Nil reads the live values at send time.
  private func runCellStatement(
    id: UUID, query: String, parameters: [String: SQLBindValue]? = nil
  ) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }),
      notebook.cells[index].cellType == .sql
    else { return }
    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult(
        "Not connected to database", sourceQuery: query, aiSessionKey: aiSessionKey)
      onDocumentChanged?()
      return
    }
    guard !executionQueue.isInQueue(cellId: id) else { return }
    if let parameters {
      ConfirmedParameterSnapshot.stashCell(self, cellId: id, query: query, values: parameters)
    } else {
      ConfirmedParameterSnapshot.dropCell(self, cellId: id)
    }
    executionQueue.enqueue(cellId: id, query: query)
  }
}
