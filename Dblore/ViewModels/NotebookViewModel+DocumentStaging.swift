//
//  NotebookViewModel+DocumentStaging.swift
//  Dblore
//
//  MongoDB document staging and inline edits. The data viewer stages inserts (+ Row, Insert,
//  Duplicate, through the document editor sheet) and deletes in
//  `DataViewerState.documentChangeSet`. An inline edit (a grid cell, or a field of a Documents
//  card at any key path) is a one-`$set` change set committed at once. Both are confirmed in
//  Safe Mode as their rendered commands, then sent one by one through
//  `executeGatedSequentialBatch`: never `executeGatedBatch` or `executeGatedUpdate`, whose
//  BEGIN / COMMIT MongoDB does not have. No undo: the undo stack holds `RowChangeSet`s only.
//

import Foundation

extension NotebookViewModel {
  /// Shown when a notebook cell or editor result's value needs the editor sheet
  static let documentValueNeedsDataViewer =
    "Open the collection in the data viewer to edit this value"

  /// Shown when the editor sheet's page or connection changed while it was open
  static let documentEditorTargetChanged =
    "The collection page changed while the editor was open. Close it and edit again."

  /// BSON types edited as text in the grid; every other type opens the editor sheet.
  nonisolated static let primitiveDocumentTypes: Set<String> = [
    "int", "long", "double", "bool", "date", "string", "objectId",
  ]

  /// A MongoDB tab (connection or data viewer): staging and inline edits go to documents and
  /// never reach the SQL builders.
  var stagesDocuments: Bool {
    notebook.connectionConfig?.databaseType.capabilities.queryLanguage == .mongosh
      || isMongoDataViewer
  }

  /// The data viewer's live MongoDB edit target: one `find` on a collection, keyed by an `_id`
  /// column that is not `mixed`. Checked instead of the SQL target, whose column origins Mongo
  /// columns never have.
  var mongoDocumentTarget: EditTarget? {
    guard dataViewer != nil, stagesDocuments, let result = editorResult,
      let target = result.editTarget, target.primaryKeyColumns == ["_id"],
      let idColumn = result.columns.first(where: { $0.name == "_id" }),
      idColumn.type != MongoBSONMapping.mixedTypeName
    else { return nil }
    return target
  }

  /// Counts of the staged rows or documents, nil when nothing is staged: the data viewer shows
  /// its summary, Preview, Discard, and Commit only then.
  var stagedChangeCounts: RowChangeSet.Counts? {
    if let set = dataViewer?.changeSet, !set.isEmpty { return set.counts }
    if let set = dataViewer?.documentChangeSet, !set.isEmpty { return set.counts }
    return nil
  }

  // MARK: - Staging

  /// + Row and Insert: opens the editor sheet on an empty document.
  func openDocumentInsertEditor() -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = mongoDocumentTarget else {
      return MongoDocumentChangeError.notMongoTarget.message
    }
    dataViewer?.pendingDocumentEditor = DataViewerState.DocumentEditorRequest(
      kind: .insert, target: target, text: "{\n  \n}")
    return nil
  }

  /// Duplicate: opens the editor sheet on a copy of each row's document without `_id` (one
  /// document, or an array for several rows). Stored documents are rebuilt from the grid cells
  /// by column type; a missing field and an explicit null both show as NULL and are left out.
  func openDocumentDuplicateEditor(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = mongoDocumentTarget else {
      return MongoDocumentChangeError.notMongoTarget.message
    }
    let copies = rows.compactMap(duplicatedDocument)
    if copies.isEmpty { return rows.isEmpty ? nil : Self.rowNotOnPage }
    let seed = copies.count == 1 ? copies[0] : .array(copies)
    dataViewer?.pendingDocumentEditor = DataViewerState.DocumentEditorRequest(
      kind: .insert, target: target, text: MongoRelaxedJSON.render(seed, as: .mongosh))
    return nil
  }

  /// Stages a delete for each stored document, or drops a staged insert.
  func stageDocumentDelete(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    let targets = rows.compactMap(documentRow)
    if targets.isEmpty { return rows.isEmpty ? nil : Self.rowNotOnPage }
    return updateDocumentChangeSet {
      (set: inout MongoDocumentChangeSet) throws(MongoDocumentChangeError) in
      for target in targets {
        switch target {
        case .stored(let id): try set.stageDelete(id: id)
        case .staged(let insert): set.deleteInsert(localID: insert.localID)
        }
      }
    }
  }

  /// Drops the staged changes of each stored document, or the staged insert.
  func revertStagedDocuments(rows: [Int]) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard dataViewer?.documentChangeSet != nil else { return nil }
    let targets = rows.compactMap(documentRow)
    return updateDocumentChangeSet { set in
      for target in targets {
        switch target {
        case .stored(let id): set.revert(id: id)
        case .staged(let insert): set.deleteInsert(localID: insert.localID)
        }
      }
    }
  }

  /// A grid edit of a staged insert's cell (`value` as the grid converted it). A primitive column
  /// sets that top-level field (NULL removes it); any other type opens the editor sheet on the
  /// whole staged document. A stored document's cells are inline edits (`handleCellValueEdit`).
  func stageDocumentInsertEdit(row: Int, column: String, value: CellValue) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = mongoDocumentTarget else {
      return MongoDocumentChangeError.notMongoTarget.message
    }
    guard case .staged(let insert)? = documentRow(row), case .document(var fields) = insert.document
    else { return Self.rowNotOnPage }
    let columnType = editorResult?.columns.first { $0.name == column }?.type ?? "string"
    let parsed: MongoValue?
    do {
      parsed = try Self.parsedDocumentValue(
        value.isNull ? nil : value.fullString, columnType: columnType)
    } catch {
      return error.message
    }
    guard let parsed else {
      dataViewer?.pendingDocumentEditor = DataViewerState.DocumentEditorRequest(
        kind: .replaceInsert(localID: insert.localID), target: target,
        text: MongoRelaxedJSON.render(insert.document, as: .mongosh))
      return nil
    }
    if case .null = parsed {
      fields.removeAll { $0.key == column }
    } else if let index = fields.firstIndex(where: { $0.key == column }) {
      fields[index].value = parsed
    } else {
      fields.append(MongoValue.Field(column, parsed))
    }
    return updateDocumentChangeSet {
      (set: inout MongoDocumentChangeSet) throws(MongoDocumentChangeError) in
      try set.replaceInsert(localID: insert.localID, with: .document(fields))
    }
  }

  /// Stage on the editor sheet: parses `text` (mongosh notation) and stages it as inserts,
  /// replaces a staged insert, or commits one `$set`. Nil when applied (the sheet closes);
  /// otherwise the sheet stays open with the error. Refused once the data viewer's target is
  /// not the one the sheet opened on (page reloaded, other collection or connection).
  func applyDocumentEditor(_ text: String) async -> DataViewerState.DocumentEditorError? {
    guard let request = dataViewer?.pendingDocumentEditor else { return nil }
    guard mongoDocumentTarget == request.target else {
      return DataViewerState.DocumentEditorError(
        message: Self.documentEditorTargetChanged, offset: nil)
    }
    let value: MongoValue
    do {
      value = try MongoRelaxedJSON.parse(text)
    } catch {
      return DataViewerState.DocumentEditorError(message: error.message, offset: error.offset)
    }
    var message: String?
    var batch: PendingStagedBatch?
    switch request.kind {
    case .insert:
      let documents: [MongoValue] = if case .array(let items) = value { items } else { [value] }
      message = updateDocumentChangeSet {
        (set: inout MongoDocumentChangeSet) throws(MongoDocumentChangeError) in
        if documents.isEmpty { throw MongoDocumentChangeError.notDocument }
        for document in documents { try set.stageInsert(document) }
      }
    case .replaceInsert(let localID):
      message = updateDocumentChangeSet {
        (set: inout MongoDocumentChangeSet) throws(MongoDocumentChangeError) in
        try set.replaceInsert(localID: localID, with: value)
      }
    case .value(let id, let path):
      switch documentEditBatch(
        id: id, path: path, value: value, target: request.target, cellId: nil)
      {
      case .success(let ready?):
        batch = ready
      case .success(nil):
        // A dialog or password sheet attached while the editor sheet animates out can fail and
        // cancel the edit: the armed dialog shows once the sheet has dismissed
        queryConfirmationState.showDialog = false
        dataViewer?.confirmationAwaitsEditorDismissal = true
      case .failure(let error):
        message = error.message
      }
    }
    if let message { return DataViewerState.DocumentEditorError(message: message, offset: nil) }
    dataViewer?.pendingDocumentEditor = nil
    if let batch { await runConfirmedStagedBatch(batch) }
    return nil
  }

  /// The editor sheet has dismissed: shows the Safe Mode dialog its field edit armed, unless
  /// that edit was cancelled meanwhile.
  func documentEditorDismissed() {
    guard dataViewer?.confirmationAwaitsEditorDismissal == true else { return }
    dataViewer?.confirmationAwaitsEditorDismissal = false
    if pendingStagedBatch != nil { queryConfirmationState.showDialog = true }
  }

  // MARK: - Inline edits

  /// An inline edit of a MongoDB result's field (grid, sidebar or Documents card), after the
  /// live-target checks of `handleCellValueEdit`. `path` is the field's key path (nil: the
  /// top-level `columnName`). Primitive types parse by BSON type and commit one `$set`; other
  /// types open the editor sheet in the data viewer, and only there.
  func handleDocumentValueEdit(
    columnName: String, columnType: String, newValue: String?, rowData: [String: CellValue],
    target: EditTarget, cellId: UUID?, path: [String]? = nil
  ) {
    guard let id = rowData["_id"] else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    let path = path ?? [columnName]
    let value: MongoValue
    do {
      guard let parsed = try Self.parsedDocumentValue(newValue, columnType: columnType) else {
        openDocumentValueEditor(
          id: id, path: path,
          current: Self.documentValue(cell: rowData[columnName] ?? .null, columnType: columnType),
          cellId: cellId)
        return
      }
      value = parsed
    } catch {
      showToast(error.message, type: .error)
      return
    }
    switch documentEditBatch(id: id, path: path, value: value, target: target, cellId: cellId) {
    case .success(let batch?):
      Task { [weak self] in await self?.runConfirmedStagedBatch(batch) }
    case .success(nil):
      break
    case .failure(let error):
      showToast(error.message, type: .error)
    }
  }

  /// An edit of a Documents card field: `row` is the document's position (staged inserts follow
  /// the page), `keys` its key path, `editType` and `text` its exact primitive type and edit text
  /// (nil: edited in the sheet), `current` its value. A staged insert opens the sheet on the whole
  /// staged document; `_id` is never edited; any other field commits one `$set` of its dotted
  /// path through the grid's gates, without the grid's clipboard copy or Cell Info refresh.
  func handleDocumentFieldEdit(
    row: Int, keys: [String], editType: String?, text: String?, current: MongoValue,
    result: CellResult, cellId: UUID?
  ) {
    guard row >= 0 else { return }
    if row >= result.rows.count {
      if let message = openStagedInsertEditor(row: row) { showToast(message, type: .error) }
      return
    }
    guard let first = keys.first, first != "_id" else { return }
    let rowData = CellResult.rowData(columns: result.columns, row: result.rows[row])
    guard let editType, let text else {
      guard let id = rowData["_id"] else {
        showToast(Self.notEditableMessage, type: .error)
        return
      }
      openDocumentValueEditor(id: id, path: keys, current: current, cellId: cellId)
      return
    }
    guard let connectionManager else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    cellDetailEditTarget = result.editTarget
    submitInlineEdit(
      assignments: [(column: first, value: text)], rowData: rowData, target: result.editTarget,
      cellId: cellId, connectionManager: connectionManager,
      documentValue: (columnType: editType, text: text), documentPath: keys)
  }

  /// Page rows of `result` whose document is staged for deletion.
  func stagedDeletedDocumentRows(result: CellResult) -> Set<Int> {
    guard let deletes = dataViewer?.documentChangeSet?.deletes, !deletes.isEmpty,
      let index = result.columns.firstIndex(where: { $0.name == "_id" })
    else { return [] }
    let idType = result.columns[index].type
    return Set(
      result.rows.indices.filter { row in
        guard result.rows[row].indices.contains(index),
          let id = MongoDocumentChangeSet.idValue(cell: result.rows[row][index], columnType: idType)
        else { return false }
        return deletes.contains(id)
      })
  }

  /// The value of `text` typed for a field of BSON `columnType`. Nil for a type that is not
  /// edited as text (`primitiveDocumentTypes`); `text` nil is null. An objectId takes 24 hex
  /// digits and stays an ObjectId.
  nonisolated static func parsedDocumentValue(
    _ text: String?, columnType: String
  ) throws(DataViewerState.DocumentEditorError) -> MongoValue? {
    guard primitiveDocumentTypes.contains(columnType) else { return nil }
    guard let text else { return .null }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    func refuse(_ expected: String) -> DataViewerState.DocumentEditorError {
      DataViewerState.DocumentEditorError(
        message: "\"\(text)\" is not \(expected) (\(columnType))", offset: nil)
    }
    switch columnType {
    case "int":
      guard let number = Int32(trimmed) else { throw refuse("a 32-bit integer") }
      return .int32(number)
    case "long":
      guard let number = Int64(trimmed) else { throw refuse("a 64-bit integer") }
      return .int64(number)
    case "double":
      guard let number = Double(trimmed) else { throw refuse("a number") }
      return .double(number)
    case "bool":
      guard let flag = Bool(trimmed.lowercased()) else { throw refuse("true or false") }
      return .bool(flag)
    case "date":
      guard let date = Self.isoDate(trimmed) else { throw refuse("an ISO 8601 date") }
      return .date(MongoBSONMapping.millis(of: date))
    case "objectId":
      guard let id = MongoObjectId(hex: trimmed) else {
        throw refuse("an ObjectId of 24 hexadecimal digits")
      }
      return .objectId(id)
    default:
      return .string(text)
    }
  }

  /// The BSON value of a grid cell in a column of `columnType`, as exact as the cell allows:
  /// nested values parse back from their canonical Extended JSON; binary loses its subtype (0);
  /// a `mixed` column takes the cell's own type.
  nonisolated static func documentValue(cell: CellValue, columnType: String) -> MongoValue {
    switch cell {
    case .null: return .null
    case .int(let number):
      if columnType == "long" { return .int64(Int64(number)) }
      return Int32(exactly: number).map(MongoValue.int32) ?? .int64(Int64(number))
    case .double(let number): return .double(number)
    case .bool(let flag): return .bool(flag)
    case .date(let date): return .date(MongoBSONMapping.millis(of: date))
    case .data(let data): return .binary(subtype: 0, data: data)
    case .json(let text): return (try? MongoRelaxedJSON.parse(text)) ?? .string(text)
    case .string(let text):
      switch columnType {
      case "objectId":
        return MongoObjectId(hex: text).map(MongoValue.objectId) ?? .string(text)
      case "decimal":
        return MongoRelaxedJSON.Lexer.isDecimal(text) ? .decimal128(text) : .string(text)
      case "regex", "timestamp", "minKey", "maxKey":
        guard let value = try? MongoRelaxedJSON.parse(text),
          MongoBSONMapping.typeName(value) == columnType
        else { return .string(text) }
        return value
      default:
        return .string(text)
      }
    }
  }

  // MARK: - Commit

  /// Commit: confirms the rendered commands in Safe Mode when needed, then sends them.
  /// A set staged against another page is dropped with a warning.
  func commitStagedDocuments() async {
    guard let target = mongoDocumentTarget, let set = dataViewer?.documentChangeSet else { return }
    if let reason = set.invalidated(by: target) {
      dataViewer?.documentChangeSet = nil
      showToast(reason, type: .warning)
      return
    }
    guard let batch = stagedDocumentBatch() else { return }
    if presentConfirmationIfNeeded(for: batch.preview, cellId: nil) {
      pendingExplainSQL = nil
      pendingStagedBatch = batch
      return
    }
    pendingStagedBatch = nil
    await runConfirmedStagedBatch(batch)
  }

  /// The staged documents as a batch: `preview` is exactly the commands sent.
  func stagedDocumentBatch() -> PendingStagedBatch? {
    guard let target = mongoDocumentTarget, let set = dataViewer?.documentChangeSet,
      !set.isEmpty, set.invalidated(by: target) == nil
    else { return nil }
    return PendingStagedBatch(
      statements: [], preview: set.previewText(), connectionEpoch: set.connectionEpoch,
      mongoCommands: set.commands().map { $0.render() },
      mongoStagedChanges: PendingStagedBatch.MongoStagedChanges(
        generation: set.generation, keys: set.changeKeys()))
  }

  /// Sends a confirmed MongoDB batch one command at a time, each expected to affect one
  /// document. Success refreshes (`refreshAfterDocumentBatch`). A partly applied batch
  /// (`batchPartiallyApplied`, also on cancel) refreshes too, so the applied commands leave the
  /// staged set and the rest stays; nothing applied keeps the set.
  func runConfirmedDocumentBatch(
    _ batch: PendingStagedBatch, commands: [String],
    connectionManager: DatabaseConnectionManager
  ) async -> String? {
    let started = Date()
    var failure: String?
    do {
      let counts = try await connectionManager.executeGatedSequentialBatch(
        commands, policy: protectionPolicy, connectionEpoch: batch.connectionEpoch, caller: id,
        expectedRows: Array(repeating: 1, count: commands.count))
      await recordExecution(
        [
          QueryHistoryOutcome(
            sql: batch.preview, duration: Date().timeIntervalSince(started),
            rowCount: counts.reduce(0, +), status: .success, errorMessage: nil)
        ], source: batch.historySource)
      await refreshAfterDocumentBatch(batch, applied: commands.count)
    } catch {
      let message = error.localizedDescription
      recordFailure(
        error, sql: batch.preview, duration: Date().timeIntervalSince(started),
        source: batch.historySource)
      showToast(message, type: .error)
      failure = message
      if case DatabaseError.batchPartiallyApplied(let applied, _, _, _) = error, applied > 0 {
        await refreshAfterDocumentBatch(batch, applied: applied)
      }
    }
    await onStatementsExecuted?()
    return failure
  }

  // MARK: - Private

  /// A row of the data-viewer grid: a loaded document (its `_id` cell), or the n-th staged
  /// insert drawn after the loaded rows.
  private enum DocumentRow {
    case stored(id: CellValue)
    case staged(MongoDocumentChangeSet.StagedInsert)
  }

  private func documentRow(_ row: Int) -> DocumentRow? {
    guard let result = editorResult, row >= 0 else { return nil }
    if row < result.rows.count {
      guard let index = result.columns.firstIndex(where: { $0.name == "_id" }),
        result.rows[row].indices.contains(index)
      else { return nil }
      return .stored(id: result.rows[row][index])
    }
    let insertIndex = row - result.rows.count
    guard let inserts = dataViewer?.documentChangeSet?.inserts,
      inserts.indices.contains(insertIndex)
    else { return nil }
    return .staged(inserts[insertIndex])
  }

  /// The document of `row` without `_id`, nil when the row is not on the page.
  private func duplicatedDocument(row: Int) -> MongoValue? {
    switch documentRow(row) {
    case .staged(let insert)?:
      guard case .document(let fields) = insert.document else { return nil }
      return .document(fields.filter { $0.key != "_id" })
    case .stored?:
      guard let result = editorResult else { return nil }
      var fields: [MongoValue.Field] = []
      for (index, column) in result.columns.enumerated() where column.name != "_id" {
        guard result.rows[row].indices.contains(index) else { continue }
        let cell = result.rows[row][index]
        if case .null = cell { continue }
        fields.append(
          MongoValue.Field(column.name, Self.documentValue(cell: cell, columnType: column.type)))
      }
      return .document(fields)
    case nil:
      return nil
    }
  }

  /// Applies `body` to the staged set, creating one for `mongoDocumentTarget`. An empty set is
  /// stored as nil; a thrown error leaves the set unchanged and is returned as its message. A
  /// set staged against another page is dropped with a warning. Nothing is registered for undo,
  /// and older row snapshots are dropped, so Undo stays disabled.
  private func updateDocumentChangeSet(
    _ body: (inout MongoDocumentChangeSet) throws(MongoDocumentChangeError) -> Void
  ) -> String? {
    guard let target = mongoDocumentTarget, let columns = editorResult?.columns else {
      return MongoDocumentChangeError.notMongoTarget.message
    }
    if let existing = dataViewer?.documentChangeSet, let reason = existing.invalidated(by: target) {
      dataViewer?.documentChangeSet = nil
      showToast(reason, type: .warning)
      return reason
    }
    do {
      var set: MongoDocumentChangeSet
      if let existing = dataViewer?.documentChangeSet {
        set = existing
      } else {
        set = try MongoDocumentChangeSet(target: target, columns: columns)
      }
      try body(&set)
      dataViewer?.documentChangeSet = set.isEmpty ? nil : set
      undoManager.removeAllActions()
      return nil
    } catch {
      return error.message
    }
  }

  /// Opens the editor sheet on one field (`path` from the top level) of a stored document, in
  /// the data viewer only.
  private func openDocumentValueEditor(
    id: CellValue, path: [String], current: MongoValue, cellId: UUID?
  ) {
    guard cellId == nil, dataViewer != nil, let target = mongoDocumentTarget else {
      showToast(Self.documentValueNeedsDataViewer, type: .error)
      return
    }
    dataViewer?.pendingDocumentEditor = DataViewerState.DocumentEditorRequest(
      kind: .value(id: id, path: path), target: target,
      text: MongoRelaxedJSON.render(current, as: .mongosh))
  }

  /// Opens the editor sheet on the staged insert drawn at `row`; the reason when it can't.
  private func openStagedInsertEditor(row: Int) -> String? {
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = mongoDocumentTarget else {
      return MongoDocumentChangeError.notMongoTarget.message
    }
    guard case .staged(let insert)? = documentRow(row) else { return Self.rowNotOnPage }
    dataViewer?.pendingDocumentEditor = DataViewerState.DocumentEditorRequest(
      kind: .replaceInsert(localID: insert.localID), target: target,
      text: MongoRelaxedJSON.render(insert.document, as: .mongosh))
    return nil
  }

  /// One `$set` of `path` on the document `id` of `target`'s live result, as a batch. Success
  /// nil: the Safe Mode dialog holds it (`pendingStagedBatch`). Success with a batch: send it
  /// now. A document staged for deletion, `_id`, and invalid keys are refused.
  private func documentEditBatch(
    id: CellValue, path: [String], value: MongoValue, target: EditTarget, cellId: UUID?
  ) -> Result<PendingStagedBatch?, DataViewerState.DocumentEditorError> {
    func refused(
      _ message: String
    ) -> Result<PendingStagedBatch?, DataViewerState.DocumentEditorError> {
      .failure(DataViewerState.DocumentEditorError(message: message, offset: nil))
    }
    guard let columns = liveColumns(of: target, cellId: cellId) else {
      return refused(Self.notEditableMessage)
    }
    let set: MongoDocumentChangeSet
    do {
      // The staged set knows which documents are deleted; probing it changes nothing
      if cellId == nil, var staged = dataViewer?.documentChangeSet {
        try staged.stageSet(id: id, path: path, value: value)
      }
      var edit = try MongoDocumentChangeSet(target: target, columns: columns)
      try edit.stageSet(id: id, path: path, value: value)
      set = edit
    } catch {
      return refused(error.message)
    }
    let commands = set.commands().map { $0.render() }
    let preview = set.previewText()
    if let message = protectionBlockMessage(for: preview) { return refused(message) }
    let batch = PendingStagedBatch(
      statements: [], preview: preview, connectionEpoch: target.connectionEpoch,
      mongoCommands: commands,
      mongoInlineEdit: PendingStagedBatch.MongoInlineEdit(cellId: cellId, target: target))
    if presentConfirmationIfNeeded(for: preview, cellId: cellId) {
      pendingExplainSQL = nil
      pendingStagedBatch = batch
      return .success(nil)
    }
    return .success(batch)
  }

  /// Columns of the result `target` belongs to (a notebook cell's, else the editor's), nil when
  /// it is no longer shown.
  private func liveColumns(of target: EditTarget, cellId: UUID?) -> [ColumnInfo]? {
    let results: [CellResult]
    if let cellId {
      guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return nil }
      results = [cell.result].compactMap { $0 } + cell.statementResults.map(\.result)
    } else {
      results = [editorResult].compactMap { $0 } + editorStatementResults.map(\.result)
    }
    return results.first { $0.editTarget == target }?.columns
  }

  /// After `applied` commands of `batch` reached the server: a notebook cell re-runs; an SQL
  /// file's editor result runs its own query again while it is still shown (one statement of a
  /// multi-statement run, whose other results stay); a staged commit drops the applied
  /// changes from the set by identity (changes staged meanwhile stay); the data viewer reloads
  /// its page, or, while changes stay staged, re-reads its rows keeping the target they were
  /// staged against.
  private func refreshAfterDocumentBatch(_ batch: PendingStagedBatch, applied: Int) async {
    if let cellId = batch.mongoInlineEdit?.cellId {
      await runCell(id: cellId)
      return
    }
    if let target = batch.mongoInlineEdit?.target, dataViewer == nil {
      // Only while the edited result is still shown: another statement picked or a run started
      // during the commit skips the refresh, so nothing but that result's own read runs again.
      // Its query, not the editor text, which may have changed since
      guard !isEditorQueryRunning, let shown = editorResult, shown.editTarget == target,
        let query = shown.sourceQuery
      else { return }
      let statements = editorStatementResults
      let index = statements.firstIndex { $0.result.editTarget == target } ?? -1
      let totalTime = totalExecutionTime
      await executeEditorQuery(query, source: .internal)
      // A multi-statement run re-ran only the edited statement: the other results stay
      guard statements.indices.contains(index), let result = editorResult else { return }
      var refreshed = statements
      refreshed[index] = StatementResult(
        id: statements[index].id, queryText: statements[index].queryText, result: result,
        statementIndex: statements[index].statementIndex)
      editorStatementResults = refreshed
      selectedStatementIndex = index
      totalExecutionTime = totalTime
      return
    }
    guard dataViewer != nil, let connectionManager else { return }
    if let sent = batch.mongoStagedChanges, var set = dataViewer?.documentChangeSet,
      set.generation == sent.generation
    {
      set.removeApplied(sent.keys.prefix(applied))
      dataViewer?.documentChangeSet = set.isEmpty ? nil : set
    }
    guard hasPendingStagedChanges else {
      // Inserts and deletes changed the document count: count again with the page
      dataViewer?.totalRows = nil
      await loadDataViewerPage()
      return
    }
    guard let target = mongoDocumentTarget else { return }
    await refreshDataViewerRows(
      target: target, connectionManager: connectionManager, done: "Changes applied")
  }

  private nonisolated static func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}
