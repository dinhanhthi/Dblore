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
}

extension NotebookViewModel {
  /// Shown when the data viewer has no resolved edit target, or that target has no primary key.
  static let tableHasNoPrimaryKey = "Table has no primary key"

  /// Why staging actions do nothing, or nil when this data viewer can stage.
  var rowStagingUnavailableReason: String? {
    stagedEditTarget == nil ? Self.tableHasNoPrimaryKey : nil
  }

  /// Stages a new row. `values` may include primary-key columns; later cell edits may not.
  /// An empty map is `INSERT ... DEFAULT VALUES`.
  @discardableResult
  func stageInsert(values: [String: CellValue] = [:]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    return changeSet { $0.stageInsert(values: values) }
  }

  /// Stages a copy of each row, without primary-key columns (those cannot be edited here).
  @discardableResult
  func stageDuplicate(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget else { return Self.tableHasNoPrimaryKey }
    let copies = rows.compactMap { duplicatedValues(row: $0, target: target) }
    if copies.isEmpty { return rows.isEmpty ? nil : Self.rowNotOnPage }
    return changeSet { set in
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
    return changeSet { set in
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
    let original =
      dataViewer?.changeSet?.originals[key]?[column] ?? loadedCell(row: row, column: column)
      ?? .null
    do {
      return try changeSet { set in
        if let tempID = key.tempID {
          try set.updateInsert(tempID: tempID, column: column, value: value)
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
    return changeSet { $0.revert(rows: keys) }
  }

  /// Drops every staged change. A Safe Mode dialog for this batch is cancelled with it.
  func discardStaged() {
    dataViewer?.changeSet = nil
    guard pendingStagedBatch != nil else { return }
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
      showToast(reason, type: .warning)
      return
    }
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
  func runConfirmedStagedBatch(_ batch: PendingStagedBatch) async {
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    guard let connectionManager else {
      showToast("No database connection available", type: .error)
      return
    }
    let started = Date()
    do {
      let counts = try await connectionManager.executeGatedBatch(
        batch.statements, policy: protectionPolicy, connectionEpoch: batch.connectionEpoch,
        caller: id)
      dataViewer?.changeSet = nil
      await recordExecution(
        [
          QueryHistoryOutcome(
            sql: batch.preview, duration: Date().timeIntervalSince(started),
            rowCount: counts.reduce(0, +), status: .success, errorMessage: nil)
        ], source: .dataViewerEdit)
      await loadDataViewerPage()
    } catch {
      recordFailure(
        error, sql: batch.preview, duration: Date().timeIntervalSince(started),
        source: .dataViewerEdit)
      showToast(error.localizedDescription, type: .error)
    }
    await onStatementsExecuted?()
  }

  // MARK: - Private

  private static let rowNotOnPage = "That row is not on this page."

  /// Live data-viewer target with a primary key. Notebook results are not a staging target.
  private var stagedEditTarget: EditTarget? {
    guard dataViewer != nil, let target = editorResult?.editTarget,
      !target.primaryKeyColumns.isEmpty
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
  private func changeSet(_ body: (inout RowChangeSet) throws -> Void) rethrows -> String? {
    guard let target = stagedEditTarget else { return Self.tableHasNoPrimaryKey }
    var set: RowChangeSet
    if let existing = dataViewer?.changeSet {
      if let reason = existing.invalidated(by: target) {
        dataViewer?.changeSet = nil
        showToast(reason, type: .warning)
        return reason
      }
      set = existing
    } else {
      set = RowChangeSet(target: target)
    }
    try body(&set)
    dataViewer?.changeSet = set.isEmpty ? nil : set
    return nil
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

  /// Non-primary-key values, with staged edits applied. Nil when `row` is not on the page.
  private func duplicatedValues(row: Int, target: EditTarget) -> [String: CellValue]? {
    guard let key = rowKey(at: row, target: target) else { return nil }
    if let tempID = key.tempID,
      let insert = dataViewer?.changeSet?.inserts.first(where: { $0.tempID == tempID })
    {
      return insert.values.filter { !target.primaryKeyColumns.contains($0.key) }
    }
    guard let result = editorResult, result.rows.indices.contains(row) else { return nil }
    var values: [String: CellValue] = [:]
    for (index, column) in result.columns.enumerated() {
      guard !target.primaryKeyColumns.contains(column.name) else { continue }
      let loaded = result.rows[row].indices.contains(index) ? result.rows[row][index] : .null
      values[column.name] = dataViewer?.changeSet?.edits[key]?[column.name] ?? loaded
    }
    return values
  }
}
