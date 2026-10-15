// MongoDocumentChangeSet.swift
// Staged MongoDB document inserts, `$set`/`$unset` updates and deletes for one collection result,
// keyed by the exact BSON `_id`, rendered as mongosh commands and drawn through a `RowChangeSet`.

import Foundation

/// Why a staged document change was refused. `message` is safe to show in the UI.
nonisolated enum MongoDocumentChangeError: Error, Equatable, Sendable, LocalizedError {
  /// The result has no MongoDB edit target keyed by `_id`.
  case notMongoTarget
  /// The `_id` column is missing or `mixed`: stored documents can't be matched.
  case idColumnUnavailable
  /// The `_id` cell can't be turned back into its exact BSON value (`type` is the column type).
  case unsupportedID(type: String)
  /// A change to `_id` or a field under it.
  case idField
  /// An empty path component, or a key containing `.` or starting with `$` (joined with `.`).
  case invalidPath(String)
  /// The document is already staged for deletion.
  case deletedDocument
  /// `path` lies under `pending`, which already has a staged change.
  case conflictingPath(path: String, pending: String)
  /// An insert that is not a document.
  case notDocument

  var message: String {
    switch self {
    case .notMongoTarget:
      "Only the result of one find on a collection can be edited."
    case .idColumnUnavailable:
      "Documents in this result can't be edited or deleted: the _id column is missing or holds "
        + "mixed types."
    case .unsupportedID(let type):
      "This document's _id (\(type)) can't be matched exactly. Use a mongosh command to change it."
    case .idField:
      "_id can't be changed. Insert a copy with a new _id and delete the original instead."
    case .invalidPath(let path):
      "Field \"\(path)\" can't be edited here: a key that is empty, contains a dot or starts "
        + "with $ can't be written as an update path. Use a mongosh command to change it."
    case .deletedDocument:
      "This document is staged for deletion. Revert the delete before editing it."
    case .conflictingPath(let path, let pending):
      "\"\(path)\" can't be changed while \"\(pending)\" has a staged change. Edit \"\(pending)\" "
        + "instead, or revert its change first."
    case .notDocument:
      "Only a document can be inserted."
    }
  }

  var errorDescription: String? { message }
}

/// Inserts, updates and deletes staged against one MongoDB collection result.
///
/// Documents are named by their exact `_id` (`idValue(cell:columnType:)` turns the grid cell back
/// into BSON using the `_id` column type). Updates hold one ordered list of `$set` and `$unset`
/// changes per document:
/// - the same path staged again replaces its change (`$set` drops a pending `$unset` and vice
///   versa) and moves to the end;
/// - a path replaces pending changes of its child paths (`a` drops `a.b`), as running them one
///   after the other would;
/// - a path under a pending one (`a.b` while `a` is staged) is refused, so an update never names
///   conflicting paths (MongoDB error 40).
///
/// `commands()` runs deletes, then updates, then inserts, each group in staging order: a document
/// is never both deleted and updated (a delete drops its updates), and a deleted `_id` can be
/// inserted again in the same commit. Inserts carry a local id only (`localID`); MongoDB assigns
/// `_id` when the document has none.
nonisolated struct MongoDocumentChangeSet: Sendable, Equatable {
  /// One `$set` (`value` non-nil) or `$unset` (`value` nil) of a path given as its keys.
  nonisolated struct PathChange: Equatable, Sendable {
    let path: [String]
    let value: MongoValue?
  }

  /// The staged changes of one stored document, in staging order.
  nonisolated struct StagedUpdate: Equatable, Sendable {
    let id: MongoValue
    fileprivate(set) var changes: [PathChange]
  }

  /// A document that is not on the server yet.
  nonisolated struct StagedInsert: Equatable, Sendable {
    let localID: UUID
    let document: MongoValue
  }

  let collection: String
  let qualifiedName: String
  let generation: UUID
  let connectionEpoch: UInt64
  /// Type of the `_id` column; nil when it is missing or `mixed` (updates and deletes refused).
  let idColumnType: String?

  private(set) var inserts: [StagedInsert] = []
  private(set) var updates: [StagedUpdate] = []
  private(set) var deletes: [MongoValue] = []

  /// Accepts only a MongoDB edit target (keyed by `_id`; callers check the query language) and
  /// takes the collection from it. `columns` are the result's; inserts work whatever they hold.
  init(target: EditTarget, columns: [ColumnInfo]) throws(MongoDocumentChangeError) {
    guard target.primaryKeyColumns == ["_id"] else { throw .notMongoTarget }
    collection = target.name ?? target.qualifiedName
    qualifiedName = target.qualifiedName
    generation = target.generation
    connectionEpoch = target.connectionEpoch
    let idType = columns.first { $0.name == "_id" }?.type
    idColumnType = idType == MongoBSONMapping.mixedTypeName ? nil : idType
  }

  var isEmpty: Bool {
    inserts.isEmpty && updates.isEmpty && deletes.isEmpty
  }

  /// Inserted documents, deleted documents, and documents with updates.
  var counts: RowChangeSet.Counts {
    RowChangeSet.Counts(inserts: inserts.count, deletes: deletes.count, edits: updates.count)
  }

  /// User-facing reason when `target` is a different collection, generation, or connection.
  func invalidated(by target: EditTarget) -> String? {
    let same =
      target.qualifiedName == qualifiedName && target.generation == generation
      && target.connectionEpoch == connectionEpoch
    return same ? nil : "The collection changed; staged edits were discarded."
  }

  // MARK: - _id

  /// The exact BSON `_id` of a grid cell (`MongoBSONMapping.cellValue`) in a column of
  /// `columnType`, or nil when it can't be recovered exactly. Refused: `binData` (the cell loses
  /// the subtype), `regex` (a filter would pattern-match), `array`, `null`, `mixed`, JavaScript,
  /// documents with a `$` key (a filter would read it as an operator), and any cell of another
  /// case than the type maps to.
  static func idValue(cell: CellValue, columnType: String) -> MongoValue? {
    switch (columnType, cell) {
    case ("objectId", .string(let hex)):
      return MongoObjectId(hex: hex).map(MongoValue.objectId)
    case ("string", .string(let text)):
      return .string(text)
    case ("int", .int(let number)):
      return Int32(exactly: number).map(MongoValue.int32)
    case ("long", .int(let number)):
      return Int64(exactly: number).map(MongoValue.int64)
    case ("double", .double(let number)):
      return .double(number)
    case ("decimal", .string(let text)):
      return MongoRelaxedJSON.Lexer.isDecimal(text) ? .decimal128(text) : nil
    case ("bool", .bool(let flag)):
      return .bool(flag)
    case ("date", .date(let date)):
      return .date(MongoBSONMapping.millis(of: date))
    case ("object", .json(let text)):
      guard let value = try? MongoRelaxedJSON.parse(text), case .document(let fields) = value,
        MongoBSONMapping.typeName(value) == "object",
        !fields.contains(where: { $0.key.hasPrefix("$") })
      else { return nil }
      return value
    case ("timestamp", .string(let text)), ("minKey", .string(let text)),
      ("maxKey", .string(let text)):
      guard let value = try? MongoRelaxedJSON.parse(text),
        MongoBSONMapping.typeName(value) == columnType
      else { return nil }
      return value
    default:
      return nil
    }
  }

  // MARK: - Staging

  /// Stages a whole document and returns its local id.
  @discardableResult
  mutating func stageInsert(_ document: MongoValue) throws(MongoDocumentChangeError) -> UUID {
    guard case .document = document else { throw .notDocument }
    let localID = UUID()
    inserts.append(StagedInsert(localID: localID, document: document))
    return localID
  }

  /// Stages `$set` of `path` (keys from the top level) on the document whose `_id` cell is `id`.
  mutating func stageSet(
    id: CellValue, path: [String], value: MongoValue
  ) throws(MongoDocumentChangeError) {
    try stage(PathChange(path: path, value: value), id: id)
  }

  /// Stages `$unset` of `path` on the document whose `_id` cell is `id`.
  mutating func stageUnset(id: CellValue, path: [String]) throws(MongoDocumentChangeError) {
    try stage(PathChange(path: path, value: nil), id: id)
  }

  /// Stages the deletion of a stored document and drops its pending updates.
  mutating func stageDelete(id: CellValue) throws(MongoDocumentChangeError) {
    let value = try storedID(id)
    updates.removeAll { $0.id == value }
    if !deletes.contains(value) { deletes.append(value) }
  }

  /// Removes a staged insert.
  mutating func deleteInsert(localID: UUID) {
    inserts.removeAll { $0.localID == localID }
  }

  /// Replaces the document of a staged insert, keeping its place (and so its grid row).
  mutating func replaceInsert(
    localID: UUID, with document: MongoValue
  ) throws(MongoDocumentChangeError) {
    guard case .document = document else { throw .notDocument }
    guard let index = inserts.firstIndex(where: { $0.localID == localID }) else { return }
    inserts[index] = StagedInsert(localID: localID, document: document)
  }

  /// What one command of `commands()` sends: a delete's `_id`, an update's `_id` and changes,
  /// an insert's local id.
  nonisolated enum ChangeKey: Equatable, Sendable {
    case delete(MongoValue)
    case update(id: MongoValue, changes: [PathChange])
    case insert(UUID)
  }

  /// One key per command of `commands()`, in the same order.
  func changeKeys() -> [ChangeKey] {
    deletes.map(ChangeKey.delete)
      + updates.map { ChangeKey.update(id: $0.id, changes: $0.changes) }
      + inserts.map { ChangeKey.insert($0.localID) }
  }

  /// Drops the changes a commit already sent (`keys`, from `changeKeys()` when it started), by
  /// identity: changes staged since stay, including new paths of a sent update.
  mutating func removeApplied(_ keys: some Sequence<ChangeKey>) {
    for key in keys {
      switch key {
      case .delete(let id):
        deletes.removeAll { $0 == id }
      case .update(let id, let sent):
        guard let index = updates.firstIndex(where: { $0.id == id }) else { continue }
        updates[index].changes.removeAll { sent.contains($0) }
        if updates[index].changes.isEmpty { updates.remove(at: index) }
      case .insert(let localID):
        inserts.removeAll { $0.localID == localID }
      }
    }
  }

  /// Drops the updates and the delete of the document whose `_id` cell is `id`.
  mutating func revert(id: CellValue) {
    guard let value = idColumnType.flatMap({ Self.idValue(cell: id, columnType: $0) }) else {
      return
    }
    updates.removeAll { $0.id == value }
    deletes.removeAll { $0 == value }
  }

  /// Drops every staged insert, update and delete.
  mutating func revertAll() {
    inserts.removeAll()
    updates.removeAll()
    deletes.removeAll()
  }

  private func storedID(_ cell: CellValue) throws(MongoDocumentChangeError) -> MongoValue {
    guard let idColumnType else { throw .idColumnUnavailable }
    guard let value = Self.idValue(cell: cell, columnType: idColumnType) else {
      throw .unsupportedID(type: idColumnType)
    }
    return value
  }

  private mutating func stage(_ change: PathChange, id: CellValue) throws(MongoDocumentChangeError)
  {
    let value = try storedID(id)
    let path = change.path
    guard !path.isEmpty,
      path.allSatisfy({ !$0.isEmpty && !$0.contains(".") && !$0.hasPrefix("$") })
    else { throw .invalidPath(path.joined(separator: ".")) }
    guard path[0] != "_id" else { throw .idField }
    guard !deletes.contains(value) else { throw .deletedDocument }
    let index = updates.firstIndex { $0.id == value }
    var changes = index.map { updates[$0].changes } ?? []
    if let parent = changes.first(where: {
      $0.path.count < path.count && path.starts(with: $0.path)
    }) {
      throw .conflictingPath(
        path: path.joined(separator: "."), pending: parent.path.joined(separator: "."))
    }
    changes.removeAll { $0.path.starts(with: path) }
    changes.append(change)
    if let index {
      updates[index].changes = changes
    } else {
      updates.append(StagedUpdate(id: value, changes: changes))
    }
  }

  // MARK: - Commands

  /// Deletes, then updates, then inserts, each in staging order. An update has `$set` and
  /// `$unset` only when non-empty; `$unset` values are `""`.
  func commands() -> [MongoCommand] {
    let deleted = deletes.map { MongoCommand.deleteOne(collection: collection, filter: filter($0)) }
    let updated = updates.map { update in
      var sets: [MongoValue.Field] = []
      var unsets: [MongoValue.Field] = []
      for change in update.changes {
        let key = change.path.joined(separator: ".")
        if let value = change.value {
          sets.append(MongoValue.Field(key, value))
        } else {
          unsets.append(MongoValue.Field(key, .string("")))
        }
      }
      var operators: [MongoValue.Field] = []
      if !sets.isEmpty { operators.append(MongoValue.Field("$set", .document(sets))) }
      if !unsets.isEmpty { operators.append(MongoValue.Field("$unset", .document(unsets))) }
      return MongoCommand.updateOne(
        collection: collection, filter: filter(update.id), update: .document(operators))
    }
    let inserted = inserts.map {
      MongoCommand.insertOne(collection: collection, document: $0.document)
    }
    return deleted + updated + inserted
  }

  /// The commands exactly as sent: `render()` of each, one per line.
  func previewText() -> String {
    commands().map { $0.render() }.joined(separator: "\n")
  }

  private func filter(_ id: MongoValue) -> MongoValue {
    .document([MongoValue.Field("_id", id)])
  }

  // MARK: - Grid overlay

  /// A `RowChangeSet` for drawing only (never for SQL): rows keyed by their `_id` cell, top-level
  /// `$set` values as cells, `$unset` as `.null`, inserts with their top-level fields. Changes
  /// to nested paths are not drawn (grid columns are top-level keys). Inserts keep this set's
  /// order, so the grid's n-th staged insert row is `inserts[n]`.
  func displayRowChangeSet(target: EditTarget) -> RowChangeSet {
    var display = RowChangeSet(target: target)
    for update in updates {
      let row = RowChangeSet.RowKey(values: [MongoBSONMapping.cellValue(update.id)])
      for change in update.changes where change.path.count == 1 {
        let cell = change.value.map(MongoBSONMapping.cellValue) ?? .null
        // The overlay never reads originals; one that differs keeps the edit from clearing.
        let original: CellValue = if case .null = cell { .string("") } else { .null }
        try? display.stageEdit(row: row, column: change.path[0], value: cell, original: original)
      }
    }
    for id in deletes {
      display.stageDelete(row: RowChangeSet.RowKey(values: [MongoBSONMapping.cellValue(id)]))
    }
    for insert in inserts {
      guard case .document(let fields) = insert.document else { continue }
      var values: [String: CellValue] = [:]
      for field in fields where !values.keys.contains(field.key) {
        values[field.key] = MongoBSONMapping.cellValue(field.value)
      }
      display.stageInsert(values: values)
    }
    return display
  }
}
