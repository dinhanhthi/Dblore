//
//  ResultComparison.swift
//  Dblore
//
//  Row and column diff of a pinned result against a later run
//

import Foundation

/// Difference between a baseline (pinned) result and a current result.
/// Row identities are indices into `baseline.rows` / `current.rows` (after the row cap).
nonisolated struct ResultDiff: Sendable, Equatable {
  enum Mode: Sendable, Equatable {
    /// Rows keyed by these primary key columns
    case primaryKey([String])
    /// Rows compared as a multiset over the shared columns
    case multiset
  }

  /// A row present on both sides (same primary key) with different values
  struct ChangedRow: Sendable, Equatable {
    let baselineIndex: Int
    let currentIndex: Int
    let changedColumns: Set<String>
  }

  let mode: Mode
  /// Column names only in the current result, in current order
  let addedColumns: [String]
  /// Column names only in the baseline result, in baseline order
  let removedColumns: [String]
  /// Column names on both sides, in baseline order
  let sharedColumns: [String]
  /// Indices into `current.rows`
  let addedRows: [Int]
  /// Indices into `baseline.rows`
  let removedRows: [Int]
  /// Always empty in multiset mode
  let changedRows: [ChangedRow]
  let unchangedCount: Int
  /// Either side had more rows than the cap and only the first rows were compared
  let truncated: Bool

  var hasChanges: Bool {
    !addedColumns.isEmpty || !removedColumns.isEmpty || !addedRows.isEmpty
      || !removedRows.isEmpty || !changedRows.isEmpty
  }
}

/// One row a compare pane lists: an index into that side's rows and how it differs
nonisolated struct ResultCompareRow: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    /// The whole row is only on this side (added or removed)
    case sideOnly
    /// Same row on both sides with these columns changed
    case changed(Set<String>)
    /// Same on both sides over the shared columns
    case unchanged
  }

  let index: Int
  let kind: Kind
}

nonisolated extension ResultDiff {
  enum Side: Sendable {
    case baseline
    case current
  }

  /// Rows a compare pane lists for `side`, in row order: removed (or added) and changed rows.
  /// When the column set changed, every row of the side is listed (unchanged ones too), so the
  /// added or removed columns are visible. `rowCount` is that side's row count.
  func paneRows(side: Side, rowCount: Int) -> [ResultCompareRow] {
    let whole = side == .baseline ? removedRows : addedRows
    let changed = changedRows.map {
      ResultCompareRow(
        index: side == .baseline ? $0.baselineIndex : $0.currentIndex,
        kind: .changed($0.changedColumns))
    }
    var rows = whole.map { ResultCompareRow(index: $0, kind: .sideOnly) } + changed
    if !addedColumns.isEmpty || !removedColumns.isEmpty {
      let listed = Set(rows.map(\.index))
      rows += (0..<max(rowCount, 0)).filter { !listed.contains($0) }.map {
        ResultCompareRow(index: $0, kind: .unchanged)
      }
    }
    return rows.sorted { $0.index < $1.index }
  }
}

nonisolated enum ResultComparison {
  static let defaultRowCap = 10_000

  static func compare(
    baseline: CellResult, current: CellResult, rowCap: Int = defaultRowCap
  ) -> ResultDiff {
    PerfSignpost.interval("result.compare") {
      diff(baseline: baseline, current: current, rowCap: rowCap)
    }
  }

  /// Runs `compare` off the main actor
  static func compareInBackground(
    baseline: CellResult, current: CellResult, rowCap: Int = defaultRowCap
  ) async -> ResultDiff {
    await Task.detached(priority: .userInitiated) {
      compare(baseline: baseline, current: current, rowCap: rowCap)
    }.value
  }

  private static func diff(baseline: CellResult, current: CellResult, rowCap: Int) -> ResultDiff {
    let cap = max(rowCap, 0)
    let truncated = baseline.rows.count > cap || current.rows.count > cap
    let baselineRows = Array(baseline.rows.prefix(cap))
    let currentRows = Array(current.rows.prefix(cap))

    let baselineNames = baseline.columns.map(\.name)
    let currentNames = current.columns.map(\.name)
    let baselineIndex = firstIndexByName(baselineNames)
    let currentIndex = firstIndexByName(currentNames)
    let shared = baselineNames.filter { currentIndex[$0] != nil }
    let added = currentNames.filter { baselineIndex[$0] == nil }
    let removed = baselineNames.filter { currentIndex[$0] == nil }

    let sides = Sides(
      baselineRows: baselineRows, currentRows: currentRows,
      baselineColumn: baselineIndex, currentColumn: currentIndex)

    var rows: RowDiff?
    if let key = sharedPrimaryKey(baseline, current, baselineIndex, currentIndex) {
      rows = primaryKeyDiff(sides, key: key, shared: shared)
    }
    let mode: ResultDiff.Mode = rows == nil ? .multiset : .primaryKey(baseline.primaryKeyColumns)
    let rowDiff = rows ?? multisetDiff(sides, shared: shared)

    return ResultDiff(
      mode: mode,
      addedColumns: added,
      removedColumns: removed,
      sharedColumns: shared,
      addedRows: rowDiff.added,
      removedRows: rowDiff.removed,
      changedRows: rowDiff.changed,
      unchangedCount: rowDiff.unchanged,
      truncated: truncated
    )
  }

  // MARK: - Rows

  private struct Sides {
    let baselineRows: [[CellValue]]
    let currentRows: [[CellValue]]
    let baselineColumn: [String: Int]
    let currentColumn: [String: Int]
  }

  private struct RowDiff {
    var added: [Int] = []
    var removed: [Int] = []
    var changed: [ResultDiff.ChangedRow] = []
    var unchanged = 0
  }

  /// The primary key when both sides declare the same non-empty set and both have its columns
  private static func sharedPrimaryKey(
    _ baseline: CellResult, _ current: CellResult,
    _ baselineColumn: [String: Int], _ currentColumn: [String: Int]
  ) -> [String]? {
    let key = baseline.primaryKeyColumns
    guard !key.isEmpty, Set(key) == Set(current.primaryKeyColumns),
      key.allSatisfy({ baselineColumn[$0] != nil && currentColumn[$0] != nil })
    else { return nil }
    return key
  }

  /// nil when a key repeats on either side (e.g. a join carrying one table's key)
  private static func primaryKeyDiff(_ sides: Sides, key: [String], shared: [String]) -> RowDiff? {
    guard
      let baselineByKey = rowsByKey(sides.baselineRows, key.map { sides.baselineColumn[$0]! }),
      let currentByKey = rowsByKey(sides.currentRows, key.map { sides.currentColumn[$0]! })
    else { return nil }

    let compared = shared.filter { !key.contains($0) }
    var result = RowDiff()
    for (index, row) in sides.baselineRows.enumerated() {
      let rowKey = project(row, key.map { sides.baselineColumn[$0]! })
      guard let currentIndex = currentByKey[rowKey] else {
        result.removed.append(index)
        continue
      }
      let currentRow = sides.currentRows[currentIndex]
      let changed = compared.filter {
        ValueKey(row, sides.baselineColumn[$0]!) != ValueKey(currentRow, sides.currentColumn[$0]!)
      }
      if changed.isEmpty {
        result.unchanged += 1
      } else {
        result.changed.append(
          ResultDiff.ChangedRow(
            baselineIndex: index, currentIndex: currentIndex, changedColumns: Set(changed)))
      }
    }
    for (index, row) in sides.currentRows.enumerated() {
      let rowKey = project(row, key.map { sides.currentColumn[$0]! })
      if baselineByKey[rowKey] == nil { result.added.append(index) }
    }
    return result
  }

  /// Matches equal rows (over shared columns) first-to-first; the rest are added or removed
  private static func multisetDiff(_ sides: Sides, shared: [String]) -> RowDiff {
    let baselineColumns = shared.map { sides.baselineColumn[$0]! }
    let currentColumns = shared.map { sides.currentColumn[$0]! }

    var pending: [[ValueKey]: [Int]] = [:]
    for (index, row) in sides.baselineRows.enumerated() {
      pending[project(row, baselineColumns), default: []].append(index)
    }
    // Next unmatched position in each key's index list (no array copies)
    var cursor: [[ValueKey]: Int] = [:]
    var matched = Set<Int>()
    var result = RowDiff()
    for (index, row) in sides.currentRows.enumerated() {
      let rowKey = project(row, currentColumns)
      let next = cursor[rowKey, default: 0]
      if let indices = pending[rowKey], next < indices.count {
        matched.insert(indices[next])
        cursor[rowKey] = next + 1
        result.unchanged += 1
      } else {
        result.added.append(index)
      }
    }
    result.removed = sides.baselineRows.indices.filter { !matched.contains($0) }
    return result
  }

  private static func rowsByKey(_ rows: [[CellValue]], _ columns: [Int]) -> [[ValueKey]: Int]? {
    var byKey: [[ValueKey]: Int] = [:]
    for (index, row) in rows.enumerated() {
      guard byKey.updateValue(index, forKey: project(row, columns)) == nil else { return nil }
    }
    return byKey
  }

  private static func project(_ row: [CellValue], _ columns: [Int]) -> [ValueKey] {
    columns.map { ValueKey(row, $0) }
  }

  private static func firstIndexByName(_ names: [String]) -> [String: Int] {
    var index: [String: Int] = [:]
    for (position, name) in names.enumerated() where index[name] == nil {
      index[name] = position
    }
    return index
  }

  /// Hashable stand-in for `CellValue`. NULL equals NULL; a short row reads as NULL.
  private enum ValueKey: Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case json(String)
    case date(Date)
    case data(Data)

    init(_ row: [CellValue], _ column: Int) {
      guard row.indices.contains(column) else {
        self = .null
        return
      }
      switch row[column] {
      case .string(let value): self = .string(value)
      case .int(let value): self = .int(value)
      case .double(let value): self = .double(value)
      case .bool(let value): self = .bool(value)
      case .null: self = .null
      case .json(let value): self = .json(value)
      case .date(let value): self = .date(value)
      case .data(let value): self = .data(value)
      }
    }
  }
}
