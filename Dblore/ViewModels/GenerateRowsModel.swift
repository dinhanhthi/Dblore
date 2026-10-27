// GenerateRowsModel.swift
// The Generate Rows sheet's state for one table: row count, seed, a generator per column, the
// NULL ratio and a preview of the first rows, planned and made off the main actor. A run is one
// batch for the tab (`beginGeneratedRowsBatch`): one Safe Mode decision over its summary, then
// the rows made 1,000 at a time while the streamed batch sends them in one transaction, with
// progress by chunk. A run Safe Mode holds stays this model's until the tab ends it
// (`streamedCompletion`), so the sheet keeps its progress and Cancel. In Protected mode the rows
// join the app transaction and stay pending until Commit.

import Foundation
import Observation

/// One column a run sends, as the sheet lists it
struct GenerateRowsColumn: Identifiable, Sendable, Equatable {
  var name: String
  /// Type as the engine displays it
  var type: String
  /// Its generator unless the user picks another; nil is NULL (no generator fits its type)
  var defaultKind: ColumnValueGenerator.Kind?
  /// Its values come from the referenced table's keys: no generator applies
  var isForeignKey: Bool
  /// The generators the user can pick
  var choices: [ColumnValueGenerator.Kind]

  var id: String { name }
}

nonisolated enum GenerateRowsError: Error, LocalizedError, Sendable, Equatable {
  /// Sampled binary keys bind as hex text, which MySQL and SQLite store as text
  case binaryForeignKey(column: String)

  var errorDescription: String? {
    switch self {
    case .binaryForeignKey(let column):
      "Values can't be generated for the binary foreign key \(column) on this database."
    }
  }
}

@Observable
@MainActor
final class GenerateRowsModel {
  static let rowCountRange = 1...1_000_000
  static let previewRowCount = 10
  static let pendingUntilCommitNotice =
    "Protected mode is on: the generated rows stay pending until you Commit."

  let schema: String
  let table: String
  var rowCount = 1_000
  var seed = UInt64.random(in: 1...999_999)
  /// Share of NULLs in nullable columns that need not be unique, 0...1
  var nullRatio = 0.1
  /// The user's generator by column name, over `GenerateRowsColumn.defaultKind`
  var kinds: [String: ColumnValueGenerator.Kind] = [:]
  private(set) var columns: [GenerateRowsColumn] = []
  /// The columns of `previewRows`
  private(set) var previewColumns: [String] = []
  /// The first rows a run makes with these settings, as bind text; nil is NULL
  private(set) var previewRows: [[String?]] = []
  /// Reading the table or making the preview
  private(set) var isLoading = false
  /// A run is planned or with the tab, until it ends (Safe Mode's decision included)
  private(set) var isGenerating = false
  /// The tab is sending the run: Cancel goes to the tab's `cancelRunningStatement`
  private(set) var isExecutingBatch = false
  /// The tab's Safe Mode dialog holds the run: Cancel goes to the tab's `cancelPendingQuery`
  private(set) var awaitsConfirmation = false
  /// Chunks of `GenerateRowsRun.rowsPerChunk` rows sent, of `chunkTotal`
  private(set) var chunksDone = 0
  private(set) var chunkTotal = 0
  /// The tab is in Protected mode: the sheet shows `pendingUntilCommitNotice`
  private(set) var pendsUntilCommit = false
  var errorMessage: String?

  @ObservationIgnored private var structure: TableStructure?
  @ObservationIgnored private var enumLabels: [String: [String]] = [:]
  @ObservationIgnored private var operationID = UUID()

  var progress: Double { chunkTotal == 0 ? 0 : Double(chunksDone) / Double(chunkTotal) }

  init(schema: String, table: String) {
    self.schema = schema
    self.table = table
  }

  /// Reads the table's structure and PostgreSQL enum labels through the tab's manager, then
  /// makes the preview
  func load(for viewModel: NotebookViewModel) async {
    cancel()
    let operationID = self.operationID
    guard let manager = viewModel.connectionManager else {
      errorMessage = "No database connection available"
      return
    }
    pendsUntilCommit = viewModel.protectionPolicy.protectedMode
    isLoading = true
    let structure: TableStructure
    let labels: [String: [String]]
    do {
      structure = try await manager.fetchTableStructure(schema: schema, table: table)
      labels = try await manager.readGenerateRowsEnumLabels(structure)
    } catch {
      if self.operationID == operationID {
        errorMessage = Self.message(error)
        isLoading = false
      }
      return
    }
    guard self.operationID == operationID else { return }
    self.structure = structure
    enumLabels = labels
    columns = Self.columns(structure, enumLabels: labels)
    await refreshPreview(for: viewModel)
  }

  /// Plans with the current settings and makes the first rows a run would, off the main actor.
  /// The same seed and settings give the same rows.
  func refreshPreview(for viewModel: NotebookViewModel) async {
    guard let structure, let manager = viewModel.connectionManager else { return }
    operationID = UUID()
    let operationID = self.operationID
    isLoading = true
    defer { if self.operationID == operationID { isLoading = false } }
    let request = request(structure, dialect: viewModel.sqlDialect)
    let count = min(Self.previewRowCount, max(rowCount, 1))
    do {
      let (columns, rows) = try await Task.detached(priority: .userInitiated) {
        var plan = try await request.plan { try await manager.readGenerateRows($0) }
        var random = SeededGenerator(seed: request.seed)
        var rows: [[String?]] = []
        for _ in 0..<count { rows.append(try plan.nextRow(using: &random)) }
        return (plan.columns, rows)
      }.value
      guard self.operationID == operationID else { return }
      previewColumns = columns
      previewRows = rows
      errorMessage = nil
    } catch {
      guard self.operationID == operationID else { return }
      previewColumns = []
      previewRows = []
      errorMessage = Self.message(error)
    }
  }

  /// Refused first, before any read: the engine, a Read-only connection, a relock, the row
  /// count. Then the plan with fresh reads, and the run as one batch for the tab: its one Safe
  /// Mode decision over the summary, then the rows in the tab's transaction. True once the tab
  /// took the run (sent, or waiting on Safe Mode: `isGenerating` then stays set until the run
  /// ends); false with `errorMessage` set.
  func generate(in viewModel: NotebookViewModel) async -> Bool {
    if let reason = viewModel.generateRowsUnavailableReason {
      errorMessage = reason
      return false
    }
    guard let manager = viewModel.connectionManager else {
      errorMessage = "No database connection available"
      return false
    }
    if let refusal = await Self.lockRefusal(manager) {
      errorMessage = refusal
      return false
    }
    guard Self.rowCountRange.contains(rowCount) else {
      errorMessage = "Generate between 1 and 1,000,000 rows"
      return false
    }
    guard let structure else {
      errorMessage = "The table's columns are not loaded"
      return false
    }
    // A preview still being made is dropped
    cancel()
    let operationID = self.operationID
    isGenerating = true
    awaitsConfirmation = false
    defer { if !awaitsConfirmation { isGenerating = false } }
    pendsUntilCommit = viewModel.protectionPolicy.protectedMode
    let epoch = await manager.connectionEpoch
    let dialect = viewModel.sqlDialect
    let maxChunkBytes =
      dialect == .mysql
      ? ImportSQLBuilder.mysqlChunkByteCap(
        maxAllowedPacket: await manager.mysqlServerInfo?.maxAllowedPacket) : nil
    let request = request(structure, dialect: dialect)
    let batch: PendingStagedBatch
    do {
      let plan = try await Task.detached(priority: .userInitiated) {
        try await request.plan { try await manager.readGenerateRows($0) }
      }.value
      guard self.operationID == operationID else {
        errorMessage = "Generate Rows cancelled"
        return false
      }
      batch = try runBatch(plan, request: request, epoch: epoch, maxChunkBytes: maxChunkBytes)
    } catch {
      if self.operationID == operationID { errorMessage = Self.message(error) }
      return false
    }
    isExecutingBatch = true
    defer { isExecutingBatch = false }
    if let reason = await viewModel.beginGeneratedRowsBatch(batch) {
      errorMessage = reason
      return false
    }
    errorMessage = nil
    awaitsConfirmation = viewModel.pendingStagedBatch?.streamed != nil
    return true
  }

  /// Drops a preview or a run's plan still being made. A run already with the tab stops through
  /// the tab's `cancelRunningStatement`, which rolls it back.
  func cancel() {
    operationID = UUID()
    isLoading = false
  }

  /// The run's batch: no statements, its rows made chunk by chunk as the gate asks, and its
  /// summary (columns, row count, seed) as the preview Safe Mode and History show
  private func runBatch(
    _ plan: GenerateRowsPlanner.Plan, request: GenerateRowsRequest, epoch: UInt64,
    maxChunkBytes: Int?
  ) throws -> PendingStagedBatch {
    let dialect = request.dialect
    let structure = request.structure
    let relation = try dialect.qualified(schema: structure.schema, name: structure.name)
    let names = try plan.columns.map(dialect.quoteIdentifier).joined(separator: ", ")
    let run = GenerateRowsRun(
      plan: plan, seed: request.seed, rowCount: request.rowCount, schema: structure.schema,
      table: structure.name, dialect: dialect, maxChunkBytes: maxChunkBytes)
    chunksDone = 0
    chunkTotal =
      (request.rowCount + GenerateRowsRun.rowsPerChunk - 1) / GenerateRowsRun.rowsPerChunk
    var batch = PendingStagedBatch(
      statements: [],
      preview:
        "INSERT INTO \(relation) (\(names)) -- \(request.rowCount) generated rows, "
        + "seed \(request.seed)",
      connectionEpoch: epoch, historySource: .generatedRows)
    batch.streamed = StreamedBatch(relation: relation, nextChunk: { try await run.next() })
    let operationID = self.operationID
    batch.streamedProgress = { [weak self] done in
      Task { @MainActor in
        guard let self, self.operationID == operationID else { return }
        self.chunksDone = max(self.chunksDone, done)
        // Sending (past Safe Mode); a late update after the run's end changes nothing
        guard self.isGenerating else { return }
        self.isExecutingBatch = true
        self.awaitsConfirmation = false
      }
    }
    batch.streamedCompletion = { [weak self] failure in
      guard let self, self.operationID == operationID else { return }
      self.isGenerating = false
      self.isExecutingBatch = false
      self.awaitsConfirmation = false
      self.errorMessage = failure
    }
    return batch
  }

  private func request(_ structure: TableStructure, dialect: SQLDialect) -> GenerateRowsRequest {
    GenerateRowsRequest(
      structure: structure, dialect: dialect, kinds: kinds, nullRatio: nullRatio,
      enumLabels: enumLabels, seed: seed, rowCount: rowCount)
  }

  /// The columns a run sends (the planner leaves identity, generated and defaulted ones to the
  /// server), with their generators
  private static func columns(
    _ structure: TableStructure, enumLabels: [String: [String]]
  ) -> [GenerateRowsColumn] {
    let foreignKeyColumns = Set(
      structure.constraints.flatMap { constraint -> [String] in
        if case .foreignKey = constraint.kind { constraint.columns } else { [] }
      })
    return GenerateRowsRequest.sentColumns(structure).map { column in
      let kind = ColumnValueGenerator.defaultKind(
        for: column, enumLabels: enumLabels[column.name] ?? [])
      return GenerateRowsColumn(
        name: column.name, type: column.columnType ?? column.dataType, defaultKind: kind,
        isForeignKey: foreignKeyColumns.contains(column.name),
        // Enum labels only where the column has labels to pick
        choices: ColumnValueGenerator.Kind.allCases.filter {
          $0 != .enumLabel || kind == .enumLabel
        })
    }
  }

  /// A refused read's own sentence (an open transaction), without "Query failed:"
  private static func message(_ error: Error) -> String {
    if case DatabaseError.queryFailed(let message, _) = error { return message }
    return error.localizedDescription
  }

  /// The refusal of a relocked connection, before anything is read or sent
  private static func lockRefusal(_ manager: DatabaseConnectionManager) async -> String? {
    guard let config = await manager.config else { return nil }
    return manager.lockSource.refusal(for: config)?.localizedDescription
  }
}

/// What a preview or a run plans from, taken on the main actor
private nonisolated struct GenerateRowsRequest: Sendable {
  var structure: TableStructure
  var dialect: SQLDialect
  var kinds: [String: ColumnValueGenerator.Kind]
  var nullRatio: Double
  var enumLabels: [String: [String]]
  var seed: UInt64
  var rowCount: Int

  /// The columns the planner sends: not identity, generated or defaulted
  static func sentColumns(_ structure: TableStructure) -> [TableStructure.Column] {
    structure.columns.filter {
      $0.identity == nil && $0.generated == nil && $0.defaultExpression == nil
    }
  }

  /// `GenerateRowsPlanner.plan`, after refusing a sent binary foreign key outside PostgreSQL:
  /// its sampled keys bind as hex text (`CellUpdateStatement.inputText`), never as bytes
  func plan(
    read: (GenerateRowsPlanner.Read) async throws -> [[CellValue]]
  ) async throws -> GenerateRowsPlanner.Plan {
    if dialect != .postgresql {
      let sent = Set(Self.sentColumns(structure).map(\.name))
      for constraint in structure.constraints {
        guard case .foreignKey = constraint.kind else { continue }
        for column in structure.columns
        where constraint.columns.contains(column.name) && sent.contains(column.name) {
          let type = (column.columnType ?? column.dataType).lowercased()
          if type.contains("binary") || type.contains("blob") {
            throw GenerateRowsError.binaryForeignKey(column: column.name)
          }
        }
      }
    }
    return try await GenerateRowsPlanner.plan(
      structure: structure, dialect: dialect, kinds: kinds, nullRatio: nullRatio,
      enumLabels: enumLabels, read: read)
  }
}

/// The rows of one run, made `rowsPerChunk` at a time as the streamed batch asks for its next
/// chunk, so the whole run is never in memory
private actor GenerateRowsRun {
  static let rowsPerChunk = 1_000

  private var plan: GenerateRowsPlanner.Plan
  private var random: SeededGenerator
  private var rowsLeft: Int
  private let schema: String
  private let table: String
  private let dialect: SQLDialect
  private let maxChunkBytes: Int?

  init(
    plan: GenerateRowsPlanner.Plan, seed: UInt64, rowCount: Int, schema: String, table: String,
    dialect: SQLDialect, maxChunkBytes: Int?
  ) {
    self.plan = plan
    random = SeededGenerator(seed: seed)
    rowsLeft = rowCount
    self.schema = schema
    self.table = table
    self.dialect = dialect
    self.maxChunkBytes = maxChunkBytes
  }

  /// The next chunk's INSERTs; nil once every row is made
  func next() throws -> [BoundStatement]? {
    guard rowsLeft > 0 else { return nil }
    let count = min(rowsLeft, Self.rowsPerChunk)
    var rows: [[String?]] = []
    rows.reserveCapacity(count)
    for _ in 0..<count { rows.append(try plan.nextRow(using: &random)) }
    rowsLeft -= count
    return try ImportSQLBuilder.insertStatements(
      schema: schema, table: table, columns: plan.columns, rows: rows, dialect: dialect,
      maxChunkBytes: maxChunkBytes)
  }
}
