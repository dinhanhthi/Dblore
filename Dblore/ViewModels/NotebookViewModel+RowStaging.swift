//
//  NotebookViewModel+RowStaging.swift
//  Dblore
//
//  Data-viewer row staging. Notebook grids still send a single-cell UPDATE immediately;
//  only a data viewer with a primary-key edit target stages inserts, edits, and deletes.
//  Commit sends bound statements through executeGatedBatch. The preview text is display
//  and history only, and Safe Mode confirms that text before the batch is sent.
//

import Foundation

/// Bound statements the user already confirmed in Safe Mode, plus the preview stored in history.
struct PendingStagedBatch: Sendable {
  var statements: [BoundStatement]
  var preview: String
  var connectionEpoch: UInt64
  var historySource: QueryHistoryRecordSource = .dataViewerEdit
  var rowRanges: [ClosedRange<Int>?] = []
  /// Import only: the import sheet is still open to show the failure detail. False once the
  /// sheet closed for the Safe Mode confirmation.
  var reportsToImportSheet = true
}

extension NotebookViewModel {
  /// Shown when the data viewer has no resolved edit target, or that target has no primary key.
  static let tableHasNoPrimaryKey = "Table has no primary key"
  /// Shown when the connection's protection level blocks data changes.
  static let connectionIsReadOnly = "This connection is read-only"

  /// Why grid edits are refused for this engine (`supportsRowStaging`), or nil.
  var rowEditingUnsupportedReason: String? {
    unavailableFeatureMessage("Editing rows", \.supportsRowStaging)
  }

  /// Why a table import is refused for this engine (`supportsDataImport`), or nil.
  var importUnsupportedReason: String? {
    unavailableFeatureMessage("Importing data", \.supportsDataImport)
  }

  /// Why staging actions do nothing, or nil when this data viewer can stage.
  /// The engine, then read-only, are checked first so + Row, grid staging, and Commit share
  /// one gate.
  var rowStagingUnavailableReason: String? {
    if let reason = rowEditingUnsupportedReason { return reason }
    if protectionPolicy.protectionLevel == .readOnly { return Self.connectionIsReadOnly }
    return stagedEditTarget == nil ? Self.tableHasNoPrimaryKey : nil
  }

  /// False when there is no primary key or the connection is read-only.
  var stagingEnabled: Bool { rowStagingUnavailableReason == nil }

  var hasPendingStagedChanges: Bool {
    dataViewer?.changeSet?.isEmpty == false
  }

  /// Stages a new row. `values` and later cell edits may include primary-key columns.
  /// An empty map is `INSERT ... DEFAULT VALUES`. An existing row's primary key stays read-only.
  @discardableResult
  func stageInsert(values: [String: CellValue] = [:]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    return changeSet("Add Row") { $0.stageInsert(values: values) }
  }

  /// + Row. A single integer primary key with no database default is set to the next number.
  /// A key the database fills (identity, serial, or any other default) is left unset.
  func addStagedRow() async -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    return stageInsert(values: await automaticIntegerKeyValues())
  }

  /// Stages a copy of each row. Primary-key columns are left unset so the copy does not reuse
  /// the source key, then filled with the next integer when this table's key is not automatic.
  @discardableResult
  func stageDuplicate(rows: [Int]) async -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget else { return Self.tableHasNoPrimaryKey }
    var copies = rows.compactMap { duplicatedValues(row: $0, target: target) }
    if copies.isEmpty { return rows.isEmpty ? nil : Self.rowNotOnPage }
    if let column = integerPrimaryKeyColumn(),
      var next = await nextIntegerPrimaryKeyValue(column: column)
    {
      for index in copies.indices where copies[index][column] == nil {
        copies[index][column] = .int(next)
        guard let advanced = StagedIntegerKey.increment(next) else { break }
        next = advanced
      }
    }
    return changeSet("Add Row") { set in
      for values in copies { set.stageInsert(values: values) }
    }
  }

  /// Stages a delete for each existing row, or drops a staged insert.
  @discardableResult
  func stageDelete(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget else { return Self.tableHasNoPrimaryKey }
    let keys = rows.compactMap { rowKey(at: $0, target: target) }
    if keys.isEmpty { return rows.isEmpty ? nil : Self.rowNotOnPage }
    return changeSet("Delete Rows") { set in
      for key in keys { set.stageDelete(row: key) }
    }
  }

  /// Stages one cell. `row` is a loaded-page index, or a staged insert appended after those rows.
  @discardableResult
  func stageEdit(row: Int, column: String, value: CellValue) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget, let key = rowKey(at: row, target: target) else {
      return Self.rowNotOnPage
    }
    if target.generatedColumns.contains(column) { return Self.generatedColumnMessage(column) }
    let original =
      dataViewer?.changeSet?.originals[key]?[column] ?? loadedCell(row: row, column: column)
      ?? .null
    do {
      return try changeSet("Edit Cell") { set in
        if let tempID = key.tempID {
          set.updateInsert(tempID: tempID, column: column, value: value)
        } else {
          try set.stageEdit(row: key, column: column, value: value, original: original)
        }
      }
    } catch let error as RowChangeError {
      return error.message
    } catch {
      return error.localizedDescription
    }
  }

  /// Drops staged edits, deletes, and inserts for `rows`.
  @discardableResult
  func revertStaged(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget, dataViewer?.changeSet != nil else { return nil }
    let keys = rows.compactMap { rowKey(at: $0, target: target) }
    return changeSet("Revert") { $0.revert(rows: keys) }
  }

  /// Asks Commit / Discard / Cancel when this data viewer has staged rows.
  /// Cancel leaves the set. Discard drops it. Commit continues only when the set was cleared.
  /// A prompt that is already open refuses the new request.
  func confirmLeaveStagedChanges() async -> Bool {
    guard hasPendingStagedChanges else { return true }
    guard stagedLeaveContinuation == nil else { return false }
    let choice = await withCheckedContinuation {
      (continuation: CheckedContinuation<StagedLeaveChoice, Never>) in
      stagedLeaveContinuation = continuation
      stagedLeavePromptVisible = true
    }
    switch choice {
    case .cancel:
      return false
    case .discard:
      discardStaged()
      return true
    case .commit:
      await commitStaged()
      return !hasPendingStagedChanges
    }
  }

  /// Resumes the leave prompt. A second call does nothing (the dialog also dismisses).
  func resolveStagedLeavePrompt(_ choice: StagedLeaveChoice) {
    guard let continuation = stagedLeaveContinuation else { return }
    stagedLeaveContinuation = nil
    stagedLeavePromptVisible = false
    continuation.resume(returning: choice)
  }

  /// Cancel when the dialog closed without a button having resumed the prompt.
  func cancelStagedLeavePromptIfNeeded() {
    resolveStagedLeavePrompt(.cancel)
  }

  /// Drops every staged change. A Safe Mode dialog for this batch is cancelled with it.
  func discardStaged() {
    dataViewer?.changeSet = nil
    undoManager.removeAllActions()
    let hadInlineEdit = pendingInlineEdit != nil
    pendingInlineEdit = nil
    guard pendingStagedBatch != nil || hadInlineEdit else { return }
    pendingStagedBatch = nil
    queryConfirmationState.clear()
  }

  /// Display SQL for the staged batch. Not sent to the server.
  func previewStagedSQL() -> String {
    stagedBatch()?.preview ?? ""
  }

  /// Confirms the preview in Safe Mode when needed, then sends the bound batch.
  /// Success reloads the page and clears the set. Failure keeps the set and shows the error.
  func commitStaged() async {
    guard let target = stagedEditTarget else { return }
    if let set = dataViewer?.changeSet, let reason = set.invalidated(by: target) {
      dataViewer?.changeSet = nil
      undoManager.removeAllActions()
      showToast(reason, type: .warning)
      return
    }
    await fillMissingIntegerKeys()
    guard let batch = stagedBatch() else { return }
    if presentConfirmationIfNeeded(for: batch.preview, cellId: nil) {
      pendingExplainSQL = nil
      pendingStagedBatch = batch
      return
    }
    pendingStagedBatch = nil
    await runConfirmedStagedBatch(batch)
  }

  /// Sends a batch the user already confirmed, or one that Safe Mode did not need to confirm.
  @discardableResult
  func runConfirmedStagedBatch(_ batch: PendingStagedBatch) async -> String? {
    guard !refuseWhileTransactionPendingElsewhere() else {
      return "A transaction is pending in another tab"
    }
    guard let connectionManager else {
      showToast("No database connection available", type: .error)
      return "No database connection available"
    }
    let started = Date()
    var failure: String?
    do {
      let counts = try await connectionManager.executeGatedBatch(
        batch.statements, policy: protectionPolicy, connectionEpoch: batch.connectionEpoch,
        caller: id)
      if batch.historySource == .dataViewerEdit { dataViewer?.changeSet = nil }
      // The page reloads with the same key, so a redo would target rows this batch changed
      if dataViewer != nil { undoManager.removeAllActions() }
      await recordExecution(
        [
          QueryHistoryOutcome(
            sql: batch.preview, duration: Date().timeIntervalSince(started),
            rowCount: counts.reduce(0, +), status: .success, errorMessage: nil)
        ], source: batch.historySource)
      if dataViewer != nil { await loadDataViewerPage() }
    } catch {
      let message = Self.batchFailureMessage(error, ranges: batch.rowRanges)
      recordFailure(
        error, sql: batch.preview, duration: Date().timeIntervalSince(started),
        source: batch.historySource, errorMessage: message,
        importSummary: Self.batchFailureMessage(
          error, ranges: batch.rowRanges, detail: "Import failed"))
      showToast(Self.batchToastMessage(error, batch: batch, fullMessage: message), type: .error)
      failure = message
    }
    await onStatementsExecuted?()
    return failure
  }

  /// Gate pre-check and Safe Mode confirmation for an import in this tab's transaction.
  func beginImportBatch(_ batch: PendingStagedBatch) async -> String? {
    if let reason = importUnsupportedReason { return reason }
    guard !hasPendingStagedChanges else {
      return "Commit or discard staged changes before importing"
    }
    if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluateBatch(
      batch.statements, policy: protectionPolicy, dialect: sqlDialect)
    {
      return reason
    }
    if presentConfirmationIfNeeded(for: batch.preview, cellId: nil) {
      pendingExplainSQL = nil
      // The sheet closes now, so a later failure is reported by the toast and History
      var confirmed = batch
      confirmed.reportsToImportSheet = false
      pendingStagedBatch = confirmed
      return nil
    }
    return await runConfirmedStagedBatch(batch)
  }

  private static func batchFailureMessage(
    _ error: Error, ranges: [ClosedRange<Int>?], detail: String? = nil
  ) -> String {
    let detail = detail ?? error.localizedDescription
    guard case DatabaseError.batchStatementFailed(let index, _, _, _) = error,
      ranges.indices.contains(index), let range = ranges[index]
    else { return detail }
    return "Rows \(range.lowerBound)–\(range.upperBound): \(detail)"
  }

  /// Import errors can quote file values. The toast stays generic; the sheet shows the detail,
  /// or History the row range once the sheet closed for Safe Mode.
  private static func batchToastMessage(
    _ error: Error, batch: PendingStagedBatch, fullMessage: String
  ) -> String {
    guard batch.historySource == .dataImport else { return fullMessage }
    if case DatabaseError.batchCancelled = error { return "Import cancelled" }
    let pointer =
      batch.reportsToImportSheet ? "See the import sheet for details." : "See History for details."
    return batchFailureMessage(error, ranges: batch.rowRanges, detail: "Import failed. \(pointer)")
  }

  // MARK: - Private

  static let rowNotOnPage = "That row is not on this page."

  /// What to do with an integer primary key on a new row.
  private enum IntegerKeyPlan {
    /// The database fills the column, or the lookup failed and guessing could write a bad key.
    case skip
    /// No database default. `serverMax` is nil when the table is empty or the server was not asked.
    case assign(serverMax: Int?)
  }

  /// Values for one new row: the next integer key, or empty when the database fills that column.
  private func automaticIntegerKeyValues() async -> [String: CellValue] {
    guard let column = integerPrimaryKeyColumn(),
      let value = await nextIntegerPrimaryKeyValue(column: column)
    else { return [:] }
    return [column: .int(value)]
  }

  /// Fills integer keys that + Row could not, just before the batch is sent.
  private func fillMissingIntegerKeys() async {
    guard let column = integerPrimaryKeyColumn(), missingIntegerKey(column) else { return }
    guard let start = await nextIntegerPrimaryKeyValue(column: column) else { return }
    _ = changeSet { $0.assignMissingIntegerKey(column, startingAt: start) }
  }

  private func nextIntegerPrimaryKeyValue(column: String) async -> Int? {
    let plan = await lookupIntegerPrimaryKey(column)
    guard case .assign(let serverMax) = plan else { return nil }
    var known: [Int] = stagedIntegerKeys(column)
    if let serverMax {
      known.append(serverMax)
    } else if !loadedPageIsWholeTable() {
      return nil
    }
    if let loaded = loadedIntegerKeyMax(column) { known.append(loaded) }
    return StagedIntegerKey.nextValue(known: known)
  }

  private func integerPrimaryKeyColumn() -> String? {
    guard let target = stagedEditTarget, let columns = editorResult?.columns else { return nil }
    return StagedIntegerKey.integerColumn(
      primaryKey: target.primaryKeyColumns, columns: columns)
  }

  private func missingIntegerKey(_ column: String) -> Bool {
    guard let inserts = dataViewer?.changeSet?.inserts else { return false }
    return inserts.contains { insert in
      guard let value = insert.values[column] else { return true }
      if case .null = value { return true }
      return false
    }
  }

  private func stagedIntegerKeys(_ column: String) -> [Int] {
    guard let inserts = dataViewer?.changeSet?.inserts else { return [] }
    return inserts.compactMap { insert in
      insert.values[column].flatMap(StagedIntegerKey.integer(from:))
    }
  }

  /// Without a server MAX, the loaded page max is the table max only for an unfiltered first page
  /// that holds every row.
  private func loadedPageIsWholeTable() -> Bool {
    guard let state = dataViewer, let rows = editorResult?.rows, state.page == 1,
      state.filter.whereClause(dialect: state.databaseType.dialect) == nil
    else { return false }
    return rows.count < state.pageSize || state.totalRows == rows.count
  }

  private func loadedIntegerKeyMax(_ column: String) -> Int? {
    guard let result = editorResult,
      let index = result.columns.firstIndex(where: { $0.name == column })
    else { return nil }
    var maxValue: Int?
    for row in result.rows {
      guard row.indices.contains(index), let number = StagedIntegerKey.integer(from: row[index])
      else { continue }
      maxValue = max(maxValue ?? number, number)
    }
    return maxValue
  }

  private func integerKeyCacheKey(_ column: String) -> String {
    let schema = dataViewer?.schema ?? ""
    let table = dataViewer?.name ?? ""
    return "\(schema)\u{0}\(table)\u{0}\(column)"
  }

  /// Looks up the column default and `MAX` when no transaction is open.
  /// Not connected: assign from the loaded page. A failed lookup does not guess.
  private func lookupIntegerPrimaryKey(_ column: String) async -> IntegerKeyPlan {
    let key = integerKeyCacheKey(column)
    guard let manager = connectionManager else { return .assign(serverMax: nil) }
    if await manager.isMetadataPaused {
      if let cached = integerPrimaryKeyHasDefault[key] {
        return cached ? .skip : .assign(serverMax: nil)
      }
      return .skip
    }
    guard let state = dataViewer,
      let sql = StagedIntegerKey.lookupSQL(
        schema: state.schema, table: state.name, column: column,
        dialect: state.databaseType.dialect)
    else { return .skip }
    do {
      let result = try await manager.executeInternal(sql, maxRows: 1)
      guard let remote = StagedIntegerKey.parseLookup(result.rows.first) else { return .skip }
      integerPrimaryKeyHasDefault[key] = remote.hasDefault
      return remote.hasDefault ? .skip : .assign(serverMax: remote.serverMax)
    } catch let error as DatabaseError {
      if case .notConnected = error { return .assign(serverMax: nil) }
      return .skip
    } catch {
      return .skip
    }
  }

  /// Live data-viewer target with a primary key, when every column origin names that table.
  /// Notebook results are not a staging target.
  private var stagedEditTarget: EditTarget? {
    guard dataViewer != nil, let result = editorResult, let target = result.editTarget,
      !target.primaryKeyColumns.isEmpty, Self.columnTableID(result.columns) == target.tableID
    else { return nil }
    return target
  }

  private var stagingDialect: SQLDialect {
    dataViewer?.databaseType.dialect ?? notebook.connectionConfig?.databaseType.dialect
      ?? .postgresql
  }

  private func stagedBatch() -> PendingStagedBatch? {
    guard let target = stagedEditTarget, let set = dataViewer?.changeSet, !set.isEmpty,
      set.invalidated(by: target) == nil
    else { return nil }
    let columns = editorResult?.columns ?? []
    let statements = RowChangeSQLBuilder.statements(
      for: set, target: target, columns: columns, dialect: stagingDialect)
    guard !statements.isEmpty else { return nil }
    return PendingStagedBatch(
      statements: statements,
      preview: RowChangeSQLBuilder.previewText(
        for: set, target: target, columns: columns, dialect: stagingDialect),
      connectionEpoch: target.connectionEpoch)
  }

  /// Applies `body` to the current set, creating one for `stagedEditTarget` when needed.
  /// An empty set is stored as nil. A thrown error leaves the previous set unchanged.
  /// `actionName` registers a snapshot on `undoManager` (nil skips that: the key fill before commit).
  private func changeSet(
    _ actionName: String? = nil, _ body: (inout RowChangeSet) throws -> Void
  ) rethrows -> String? {
    guard let target = stagedEditTarget else { return Self.tableHasNoPrimaryKey }
    if let existing = dataViewer?.changeSet, let reason = existing.invalidated(by: target) {
      dataViewer?.changeSet = nil
      undoManager.removeAllActions()
      showToast(reason, type: .warning)
      return reason
    }
    var set = dataViewer?.changeSet ?? RowChangeSet(target: target)
    let previous = dataViewer?.changeSet
    try body(&set)
    let stored: RowChangeSet? = set.isEmpty ? nil : set
    if stored != previous, let actionName {
      registerStagedUndo(restoring: previous, actionName: actionName)
    }
    dataViewer?.changeSet = stored
    return nil
  }

  /// Records an undo that puts `snapshot` back. Called again from that undo, it becomes the redo.
  private func registerStagedUndo(restoring snapshot: RowChangeSet?, actionName: String) {
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        target.restoreStagedChangeSet(snapshot, actionName: actionName)
      }
    }
    undoManager.setActionName(actionName)
  }

  /// Swaps the staged set for `snapshot` and registers the inverse under the same action name.
  /// A Safe Mode dialog still holding the previous batch is closed first: Execute Query would
  /// otherwise send that captured SQL, then clear this undo.
  private func restoreStagedChangeSet(_ snapshot: RowChangeSet?, actionName: String) {
    if pendingStagedBatch != nil || pendingInlineEdit != nil {
      pendingStagedBatch = nil
      pendingInlineEdit = nil
      queryConfirmationState.clear()
    }
    let current = dataViewer?.changeSet
    registerStagedUndo(restoring: current, actionName: actionName)
    dataViewer?.changeSet = snapshot
  }

  private func rowKey(at row: Int, target: EditTarget) -> RowChangeSet.RowKey? {
    guard let result = editorResult, row >= 0 else { return nil }
    if row < result.rows.count {
      var values: [CellValue] = []
      values.reserveCapacity(target.primaryKeyColumns.count)
      for column in target.primaryKeyColumns {
        guard let value = loadedCell(row: row, column: column) else { return nil }
        values.append(value)
      }
      return RowChangeSet.RowKey(values: values)
    }
    let insertIndex = row - result.rows.count
    guard let inserts = dataViewer?.changeSet?.inserts, inserts.indices.contains(insertIndex)
    else { return nil }
    return RowChangeSet.RowKey(tempID: inserts[insertIndex].tempID)
  }

  private func loadedCell(row: Int, column: String) -> CellValue? {
    guard let result = editorResult,
      let index = result.columns.firstIndex(where: { $0.name == column }),
      result.rows.indices.contains(row), result.rows[row].indices.contains(index)
    else { return nil }
    return result.rows[row][index]
  }

  /// Non-primary-key, non-generated values, with staged edits applied. Nil when `row` is not on
  /// the page.
  private func duplicatedValues(row: Int, target: EditTarget) -> [String: CellValue]? {
    guard let key = rowKey(at: row, target: target) else { return nil }
    if let tempID = key.tempID,
      let insert = dataViewer?.changeSet?.inserts.first(where: { $0.tempID == tempID })
    {
      return insert.values.filter {
        !target.primaryKeyColumns.contains($0.key) && !target.generatedColumns.contains($0.key)
      }
    }
    guard let result = editorResult, result.rows.indices.contains(row) else { return nil }
    var values: [String: CellValue] = [:]
    for (index, column) in result.columns.enumerated() {
      guard !target.primaryKeyColumns.contains(column.name),
        !target.generatedColumns.contains(column.name)
      else { continue }
      let loaded = result.rows[row].indices.contains(index) ? result.rows[row][index] : .null
      values[column.name] = dataViewer?.changeSet?.edits[key]?[column.name] ?? loaded
    }
    return values
  }
}
