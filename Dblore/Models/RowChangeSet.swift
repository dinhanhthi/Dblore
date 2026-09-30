// RowChangeSet.swift
// Staged inserts, deletes, and cell edits for one data-viewer edit target.

import Foundation

/// `CellValue`'s `Equatable` conformance is main-actor isolated, so staged values are
/// compared here without using that conformance.
private nonisolated func cellValuesEqual(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
  switch (lhs, rhs) {
  case (.string(let left), .string(let right)): left == right
  case (.int(let left), .int(let right)): left == right
  case (.double(let left), .double(let right)): left == right
  case (.bool(let left), .bool(let right)): left == right
  case (.null, .null): true
  case (.json(let left), .json(let right)): left == right
  case (.date(let left), .date(let right)): left == right
  case (.data(let left), .data(let right)): left == right
  default: false
  }
}

private nonisolated func columnMapsEqual(
  _ lhs: [String: CellValue], _ rhs: [String: CellValue]
) -> Bool {
  guard lhs.count == rhs.count else { return false }
  for (column, value) in lhs {
    guard let other = rhs[column], cellValuesEqual(value, other) else { return false }
  }
  return true
}

private nonisolated func editMapsEqual(
  _ lhs: [RowChangeSet.RowKey: [String: CellValue]],
  _ rhs: [RowChangeSet.RowKey: [String: CellValue]]
) -> Bool {
  guard lhs.count == rhs.count else { return false }
  for (row, columns) in lhs {
    guard let other = rhs[row], columnMapsEqual(columns, other) else { return false }
  }
  return true
}

/// Why a staged edit was refused. `message` is safe to show in the UI.
nonisolated enum RowChangeError: Error, Equatable, Sendable {
  /// The row is already staged for deletion.
  case deletedRow
  /// `column` is one of the target's primary-key columns.
  case primaryKeyColumn(String)

  var message: String {
    switch self {
    case .deletedRow:
      "This row is staged for deletion. Revert the delete before editing it."
    case .primaryKeyColumn(let column):
      "Primary key column \"\(column)\" can't be edited here. Use SQL to change it."
    }
  }
}

/// Inserts, deletes, and cell edits staged against one `EditTarget`.
/// Discard the set when `invalidated(by:)` returns a reason.
nonisolated struct RowChangeSet: Sendable, Equatable {
  let qualifiedName: String
  let generation: UUID
  let connectionEpoch: UInt64
  /// Primary key columns in key order. Edits to these columns are refused.
  let primaryKeyColumns: [String]

  private(set) var inserts: [StagedInsert]
  private(set) var deletes: Set<RowKey>
  private(set) var edits: [RowKey: [String: CellValue]]
  /// Cell values from before staging, kept so an edit can be previewed and restored.
  private(set) var originals: [RowKey: [String: CellValue]]

  /// A row that is not on the server yet.
  nonisolated struct StagedInsert: Identifiable, Equatable, Sendable {
    let tempID: UUID
    var values: [String: CellValue]
    var id: UUID { tempID }

    static func == (lhs: StagedInsert, rhs: StagedInsert) -> Bool {
      lhs.tempID == rhs.tempID && columnMapsEqual(lhs.values, rhs.values)
    }
  }

  /// Primary-key values in `primaryKeyColumns` order, or a staged insert named by `tempID`.
  nonisolated struct RowKey: Hashable, Sendable {
    /// Primary-key values. Empty when `tempID` names an insert.
    let values: [CellValue]
    /// Set when this key names a staged insert instead of an existing row.
    let tempID: UUID?

    init(values: [CellValue]) {
      self.values = values
      self.tempID = nil
    }

    init(tempID: UUID) {
      self.values = []
      self.tempID = tempID
    }

    static func == (lhs: RowKey, rhs: RowKey) -> Bool {
      guard lhs.tempID == rhs.tempID, lhs.values.count == rhs.values.count else { return false }
      return zip(lhs.values, rhs.values).allSatisfy { cellValuesEqual($0, $1) }
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(tempID)
      hasher.combine(values.count)
      for value in values {
        Self.combine(value, into: &hasher)
      }
    }

    /// Case tag plus payload. `CellValue` is not `Hashable`; this keeps that type unchanged.
    private static func combine(_ value: CellValue, into hasher: inout Hasher) {
      switch value {
      case .null:
        hasher.combine(0)
      case .bool(let flag):
        hasher.combine(1)
        hasher.combine(flag)
      case .int(let number):
        hasher.combine(2)
        hasher.combine(number)
      case .double(let number):
        hasher.combine(3)
        hasher.combine(number)
      case .date(let date):
        hasher.combine(4)
        hasher.combine(date)
      case .string(let text):
        hasher.combine(5)
        hasher.combine(text)
      case .json(let text):
        hasher.combine(6)
        hasher.combine(text)
      case .data(let data):
        hasher.combine(7)
        hasher.combine(data)
      }
    }
  }

  /// How many inserts, deleted rows, and rows with cell edits are staged.
  nonisolated struct Counts: Equatable, Sendable {
    var inserts: Int
    var deletes: Int
    var edits: Int
  }

  init(target: EditTarget) {
    qualifiedName = target.qualifiedName
    generation = target.generation
    connectionEpoch = target.connectionEpoch
    primaryKeyColumns = target.primaryKeyColumns
    inserts = []
    deletes = []
    edits = [:]
    originals = [:]
  }

  static func == (lhs: RowChangeSet, rhs: RowChangeSet) -> Bool {
    lhs.qualifiedName == rhs.qualifiedName && lhs.generation == rhs.generation
      && lhs.connectionEpoch == rhs.connectionEpoch
      && lhs.primaryKeyColumns == rhs.primaryKeyColumns && lhs.inserts == rhs.inserts
      && lhs.deletes == rhs.deletes && editMapsEqual(lhs.edits, rhs.edits)
      && editMapsEqual(lhs.originals, rhs.originals)
  }

  var isEmpty: Bool {
    inserts.isEmpty && deletes.isEmpty && edits.isEmpty
  }

  var counts: Counts {
    Counts(inserts: inserts.count, deletes: deletes.count, edits: edits.count)
  }

  /// User-facing reason when `target` is a different table, generation, or connection.
  func invalidated(by target: EditTarget) -> String? {
    let same =
      target.qualifiedName == qualifiedName && target.generation == generation
      && target.connectionEpoch == connectionEpoch
    return same ? nil : "The table changed; staged edits were discarded."
  }

  /// Stages one cell. `value == original` clears that column, and the row when none remain.
  mutating func stageEdit(
    row: RowKey, column: String, value: CellValue, original: CellValue
  ) throws {
    if deletes.contains(row) {
      throw RowChangeError.deletedRow
    }
    if primaryKeyColumns.contains(column) {
      throw RowChangeError.primaryKeyColumn(column)
    }
    if cellValuesEqual(value, original) {
      clearColumn(column, on: row)
      return
    }
    var staged = edits[row] ?? [:]
    staged[column] = value
    edits[row] = staged
    var baseline = originals[row] ?? [:]
    if !baseline.keys.contains(column) {
      baseline[column] = original
    }
    originals[row] = baseline
  }

  /// Drops a staged insert, or marks an existing row deleted and discards its pending edits.
  mutating func stageDelete(row: RowKey) {
    if let tempID = row.tempID {
      deleteInsert(tempID: tempID)
      return
    }
    edits.removeValue(forKey: row)
    originals.removeValue(forKey: row)
    deletes.insert(row)
  }

  /// Removes a staged insert. Does not record a delete.
  mutating func deleteInsert(tempID: UUID) {
    inserts.removeAll { $0.tempID == tempID }
  }

  /// Appends a staged insert and returns its temporary id.
  @discardableResult
  mutating func stageInsert(values: [String: CellValue]) -> UUID {
    let tempID = UUID()
    inserts.append(StagedInsert(tempID: tempID, values: values))
    return tempID
  }

  /// Sets one column on a staged insert. A primary-key column is refused.
  mutating func updateInsert(tempID: UUID, column: String, value: CellValue) throws {
    if primaryKeyColumns.contains(column) {
      throw RowChangeError.primaryKeyColumn(column)
    }
    guard let index = inserts.firstIndex(where: { $0.tempID == tempID }) else { return }
    inserts[index].values[column] = value
  }

  /// Drops edits and the delete mark for each existing row, and drops inserts named by `tempID`.
  mutating func revert(rows: [RowKey]) {
    for row in rows {
      if let tempID = row.tempID {
        deleteInsert(tempID: tempID)
        continue
      }
      edits.removeValue(forKey: row)
      originals.removeValue(forKey: row)
      deletes.remove(row)
    }
  }

  /// Drops every staged insert, delete, and edit.
  mutating func revertAll() {
    inserts.removeAll()
    deletes.removeAll()
    edits.removeAll()
    originals.removeAll()
  }

  private mutating func clearColumn(_ column: String, on row: RowKey) {
    guard var staged = edits[row] else { return }
    staged.removeValue(forKey: column)
    var baseline = originals[row] ?? [:]
    baseline.removeValue(forKey: column)
    if staged.isEmpty {
      edits.removeValue(forKey: row)
      originals.removeValue(forKey: row)
    } else {
      edits[row] = staged
      originals[row] = baseline
    }
  }
}
