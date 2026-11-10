// TableHealthModel.swift
// File > Table Health...: one read-only run over the sidebar's tables. It starts as the sheet
// opens (the sheet shows a placeholder at once) and runs off the main actor on a private
// connection opened like the tab's (`makeSnapshotSideManager`), never on the tab's session, closed
// on every path: success, failure and Cancel. Refused before anything is opened while a
// transaction is open (the other connection can't see its uncommitted work) and above
// `maxTables`. The structures are read four at a time with progress, like the data dictionary
// export: a table whose read fails is left out and named in a note; every read failing fails the
// run. Then the engine's statistics (PostgreSQL, MySQL / MariaDB; none on SQLite) on the same
// connection, combined with the structure findings (`TableHealthReport.combined`). Cancel stops
// after the reads in flight and hides the sheet.

import Foundation
import Observation

nonisolated enum TableHealthError: Error, Equatable, LocalizedError {
  case transactionOpen
  case tooManyTables(Int)

  var errorDescription: String? {
    switch self {
    case .transactionOpen:
      "A transaction is open on this connection. Commit or roll it back first: Table Health "
        + "reads on a second connection, which can't see uncommitted changes."
    case .tooManyTables(let count):
      "This database has \(count.formatted()) tables. Table Health checks at most "
        + "\(TableHealthModel.maxTables.formatted()) tables."
    }
  }
}

extension TableHealthFinding.Kind {
  /// Short user-facing name
  nonisolated var title: String {
    switch self {
    case .noPrimaryKey: "No primary key"
    case .foreignKeyWithoutIndex: "Foreign key without index"
    case .unusedIndex: "Unused index"
    case .deadTuples: "Dead rows"
    case .redundantIndex: "Redundant index"
    }
  }
}

@MainActor
@Observable
final class TableHealthModel: Identifiable {
  nonisolated static let maxTables = 2_000
  /// Structure reads in flight at once
  nonisolated static let concurrency = 4

  nonisolated struct TableName: Sendable, Hashable {
    let schema: String
    let name: String
  }

  enum Phase: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  /// The sheet's filter
  enum Category: CaseIterable, Hashable {
    case all, keys, indexes, bloat

    var title: String {
      switch self {
      case .all: "All"
      case .keys: "Keys"
      case .indexes: "Indexes"
      case .bloat: "Bloat"
      }
    }

    func includes(_ kind: TableHealthFinding.Kind) -> Bool {
      switch (self, kind) {
      case (.all, _), (.keys, .noPrimaryKey), (.keys, .foreignKeyWithoutIndex),
        (.indexes, .unusedIndex), (.indexes, .redundantIndex), (.bloat, .deadTuples):
        true
      default: false
      }
    }
  }

  let tables: [TableName]
  let engine: DatabaseType
  let databaseName: String
  private(set) var phase: Phase = .loading
  /// Structures read so far
  private(set) var completed = 0
  private(set) var report = TableHealthReport()
  private(set) var isCancelling = false
  var category: Category = .all

  /// Hides the sheet
  @ObservationIgnored var onClose: () -> Void = {}
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    tables: [TableName], engine: DatabaseType, databaseName: String,
    connectionManager: DatabaseConnectionManager
  ) {
    self.tables = tables
    self.engine = engine
    self.databaseName = databaseName
    self.connectionManager = connectionManager
  }

  var isLoading: Bool { phase == .loading }

  var visibleFindings: [TableHealthFinding] {
    report.findings.filter { category.includes($0.kind) }
  }

  /// Runs the check once. Returns at once: the phase is `loading` until it ends.
  func start() {
    guard task == nil else { return }
    phase = .loading
    let tables = tables
    let engine = engine
    let manager = connectionManager
    task = Task { [weak self] in
      do {
        let report = try await Self.run(tables, engine: engine, manager: manager) { done in
          await MainActor.run { self?.completed = done }
        }
        try Task.checkCancellation()
        self?.report = report
        self?.phase = .loaded
      } catch {
        // A cancelled read may fail as a wrapped query error: Cancel never shows a message
        guard !Task.isCancelled else {
          self?.onClose()
          return
        }
        self?.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// While running: stops after the reads in flight, then hides the sheet. Otherwise hides it.
  func cancel() {
    guard isLoading, let task else {
      onClose()
      return
    }
    isCancelling = true
    task.cancel()
  }

  /// The whole report (every category) as Markdown
  func markdown(generatedAt: Date = Date()) -> String {
    var lines = [
      "# Table Health: \(databaseName)", "",
      "Generated \(generatedAt.formatted(date: .abbreviated, time: .shortened))", "",
    ]
    if !report.notes.isEmpty {
      lines += report.notes.map { "> \($0)" } + [""]
    }
    if report.findings.isEmpty {
      lines.append("No findings.")
    }
    for finding in report.findings {
      let severity = finding.severity == .warning ? "Warning" : "Info"
      lines.append(
        "- **\(severity)** \(Self.displayName(finding)) (\(finding.kind.title)): \(finding.reason)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `schema.table`, or the table alone without a schema
  static func displayName(_ finding: TableHealthFinding) -> String {
    finding.schema.isEmpty ? finding.table : "\(finding.schema).\(finding.table)"
  }

  // MARK: - Run

  /// Refuses or opens the side connection, reads, combines, and closes it on every path
  @concurrent nonisolated private static func run(
    _ tables: [TableName], engine: DatabaseType, manager: DatabaseConnectionManager,
    progress: @escaping @Sendable (Int) async -> Void
  ) async throws -> TableHealthReport {
    guard tables.count <= maxTables else { throw TableHealthError.tooManyTables(tables.count) }
    guard await manager.isOutsideAnyTransaction else { throw TableHealthError.transactionOpen }
    let side = manager.makeSnapshotSideManager()
    do {
      try await manager.connectSideManager(side)
      try Task.checkCancellation()
      let (structures, skipped) = try await loadStructures(
        tables, from: side, progress: progress)
      try Task.checkCancellation()
      let statistics = try await side.tableHealthStatistics(
        engine: engine, schemas: Array(Set(tables.map(\.schema))).sorted())
      await side.disconnect()
      var report = TableHealthReport.combined(structures: structures, statistics: statistics)
      if !skipped.isEmpty {
        let names = skipped.map { $0.schema.isEmpty ? $0.name : "\($0.schema).\($0.name)" }
        report.notes.append(
          "Not checked, their structure could not be read: \(names.joined(separator: ", ")).")
      }
      return report
    } catch {
      await side.disconnect()
      throw error
    }
  }

  /// The structures read, at most `concurrency` at once, and the tables whose read failed.
  /// Cancellation aborts; so does every read failing (the first error is thrown).
  @concurrent nonisolated private static func loadStructures(
    _ tables: [TableName], from side: DatabaseConnectionManager,
    progress: @escaping @Sendable (Int) async -> Void
  ) async throws -> (structures: [TableStructure], skipped: [TableName]) {
    try await withThrowingTaskGroup(of: (Int, Result<TableStructure, any Error>).self) { group in
      var results = [Result<TableStructure, any Error>?](repeating: nil, count: tables.count)
      var next = 0
      var done = 0
      func addNext() {
        let index = next
        let table = tables[index]
        next += 1
        group.addTask {
          do {
            return (
              index,
              .success(try await side.fetchTableStructure(schema: table.schema, table: table.name))
            )
          } catch {
            // A cancelled read may fail as a wrapped query error: it aborts, never skips
            try Task.checkCancellation()
            return (index, .failure(error))
          }
        }
      }
      while next < min(concurrency, tables.count) { addNext() }
      while let (index, result) = try await group.next() {
        try Task.checkCancellation()
        results[index] = result
        done += 1
        await progress(done)
        if next < tables.count { addNext() }
      }
      var structures: [TableStructure] = []
      var skipped: [TableName] = []
      var firstError: (any Error)?
      for (index, result) in results.enumerated() {
        switch result {
        case .success(let structure): structures.append(structure)
        case .failure(let error):
          skipped.append(tables[index])
          firstError = firstError ?? error
        case nil: break
        }
      }
      if structures.isEmpty, let firstError { throw firstError }
      return (structures, skipped)
    }
  }
}

extension DatabaseConnectionManager {
  /// Table Health's engine statistics on this (side) manager's session: PostgreSQL's for the
  /// database, MySQL / MariaDB's for each of `schemas`, none on the other engines
  func tableHealthStatistics(
    engine: DatabaseType, schemas: [String]
  ) async throws -> TableHealthReport {
    switch engine {
    case .postgresql:
      return try await withSession { try await TableHealthQueries.postgresReport(in: $0) }
    case .mysql:
      var report = TableHealthReport()
      for schema in schemas {
        let one = try await withSession {
          try await TableHealthQueries.mysqlReport(schema: schema, in: $0)
        }
        report.findings += one.findings
        report.notes += one.notes.filter { !report.notes.contains($0) }
      }
      return report
    case .sqlite, .duckdb, .mongodb, .clickhouse, .sqlserver:
      return TableHealthReport()
    }
  }
}
