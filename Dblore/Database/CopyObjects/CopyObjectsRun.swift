// CopyObjectsRun.swift
// Copy Objects: the run of a checked plan (`CopyObjectsPlanner`, `CopyObjectsDDLCheck`) from a
// source connection into a writable target (`makeCopyTargetManager`). The caller connects both
// and closes them after the run: the source is a read-only side manager for PostgreSQL, MySQL /
// MariaDB and SQLite, the tab's own manager for DuckDB.
//
// Rows are read table by table in chunks of at most 500 rows and 4 MiB: after the last primary
// key read (keyset) when the table has a usable one, else by position (LIMIT / OFFSET, with a
// warning). Every row read is sent once: rows past the 4 MiB budget wait for the next chunk, and
// the table's next read is limited to the rows that fit (at least 1), doubling back towards 500
// while the rows are small. Each value is read as text in the source engine's own form, or as bytes (hex on the
// wire), normalized per the column's value form, and bound through ImportSQLBuilder's chunked
// INSERT. Source values never become SQL text, except SQLite target BLOBs: `X'..'` literals made
// from the bytes.
//
// PostgreSQL and SQLite targets: one streamed batch in one transaction. Prelude: SQLite's
// PRAGMA defer_foreign_keys = ON (always first, whatever the edited DDL kept), then the CREATE
// TABLEs; the INSERT chunks; postlude: the indexes and foreign keys, then the identity restart.
// Cancel or any failure rolls it all back. MySQL / MariaDB targets: DDL commits implicitly, so
// each CREATE TABLE runs alone (recorded as created once it succeeded), the rows in one streamed
// transaction, then the indexes and foreign keys one by one. On failure or cancel the row
// transaction is rolled back, then every table this run created is dropped in reverse order,
// and only those, with FOREIGN_KEY_CHECKS = 0 for the session; a table whose DROP fails is named
// in the error. A CREATE TABLE the server committed but whose reply the cancel cut off is not
// recorded, so it is neither dropped nor named.
//
// Cancel sets the run's flag (the next chunk is refused) and cancels the statement the target
// runs (its batch cancellation generation). Progress is chunks done of the planned total. One
// History row on the target (data import), whatever the outcome.

import Foundation
import os

nonisolated enum CopyObjectsRunError: Error, Equatable, LocalizedError {
  /// A value the column's target form cannot take
  case invalidValue(table: String, column: String)
  /// A primary key value the next keyset read cannot start after
  case unreadableKey(table: String)
  /// The copy failed with `reason`. MySQL / MariaDB: `leftoverTables` were created by the run
  /// and could not be dropped.
  case failed(reason: String, leftoverTables: [String])
  case cancelled(leftoverTables: [String])

  var errorDescription: String? {
    switch self {
    case .invalidValue(let table, let column):
      "\"\(table)\".\"\(column)\" holds a value the target column cannot take."
    case .unreadableKey(let table):
      "The primary key of \"\(table)\" returned a value the copy cannot read past."
    case .failed(let reason, let leftovers):
      "The copy failed: \(reason)" + Self.leftoverSentence(leftovers)
    case .cancelled(let leftovers):
      "The copy was cancelled." + Self.leftoverSentence(leftovers)
    }
  }

  private static func leftoverSentence(_ tables: [String]) -> String {
    guard !tables.isEmpty else { return "" }
    return " These tables it created could not be dropped: "
      + tables.map { "\"\($0)\"" }.joined(separator: ", ") + "."
  }
}

/// What a finished copy did
nonisolated struct CopyObjectsRunResult: Sendable, Equatable {
  var tables: Int
  var rows: Int
  /// The plan's warnings, then the run's (tables read by position)
  var warnings: [String]
}

/// The reads of one source table and the values they return, as the target takes them
nonisolated struct CopyObjectsTableRead: Sendable {
  typealias Engine = StructureDDLBuilder.Engine
  typealias Value = ImportSQLBuilder.Value

  static let rowsPerChunk = 500
  static let bytesPerChunk = 4 * 1_024 * 1_024

  /// The quoted source table
  let relation: String
  /// The target table and its columns
  let table: String
  let columns: [ImportSQLBuilder.BoundColumn]
  /// Each column's value form (`.asIs` between the same engine) and whether it is read as bytes
  private let forms: [CopyObjectsTypeMapping.ValueForm]
  private let binary: [Bool]
  private let selectList: [String]
  /// Keyset: the quoted primary key; nil reads by position
  private let keys: [String]?
  /// Per key column: the exact number type its bind is cast to (MySQL integers and decimals)
  private let keyCasts: [String?]
  private let positionOrder: String?
  private let source: Engine
  private let target: SQLDialect

  /// Rows are read by position (no usable primary key)
  var readsByPosition: Bool { keys == nil }
  /// Read by position with no ORDER BY (a MySQL table without a primary key)
  var readsUnordered: Bool { keys == nil && positionOrder == nil }

  init(_ planned: CopyObjectsPlan.Table, source: Engine, target: Engine) throws {
    self.source = source
    self.target = target.dialect
    let dialect = source.dialect
    let sameEngine = dialect == target.dialect
    let structure = planned.source
    relation = try dialect.qualified(schema: structure.schema, name: structure.name)
    table = planned.name
    columns = planned.columns.map { .init(name: $0.name, bindForm: $0.mapping.bindForm) }
    forms = planned.columns.map { sameEngine ? .asIs : $0.mapping.valueForm }
    binary = planned.columns.map { $0.mapping.bindForm != .plain }
    var list: [String] = []
    for (index, column) in planned.columns.enumerated() {
      list.append(
        Self.valueRead(
          try dialect.quoteIdentifier(column.name), binary: binary[index], form: forms[index],
          source: source))
    }

    let primaryKey = CopyObjectsTypeMapping.primaryKey(of: structure)
    let quotedKey = try primaryKey.map(dialect.quoteIdentifier)
    if Self.allowsKeyset(primaryKey, planned: planned, source: source) {
      keys = quotedKey
      // MySQL compares a string with a number as a double: the bind is cast first
      keyCasts = primaryKey.map { name in
        guard case .mysql = source,
          let column = structure.columns.first(where: { $0.name == name })
        else { return nil }
        switch CopyObjectsTypeMapping.family(of: column, source: source) {
        case .integer: return "DECIMAL(65,0)"
        case .decimal(let precision, let scale): return "DECIMAL(\(precision ?? 65),\(scale ?? 0))"
        default: return nil
        }
      }
      list += quotedKey.map { Self.keyRead($0, source: source) }
      positionOrder = nil
    } else {
      keys = nil
      keyCasts = []
      if !quotedKey.isEmpty {
        positionOrder = quotedKey.joined(separator: ", ")
      } else {
        switch source {
        case .postgresql: positionOrder = "ctid"
        case .sqlite, .duckdb: positionOrder = "rowid"
        case .mysql: positionOrder = nil
        }
      }
    }
    selectList = list
  }

  /// The count read, for the planned chunk total
  var countSQL: String { "SELECT COUNT(*) FROM \(relation)" }

  /// The next read of at most `limit` rows: after `key` (keyset) or from `offset` (by position)
  func select(
    after key: [String]?, offset: Int, limit: Int = rowsPerChunk
  ) -> (sql: String, binds: [SQLBindValue]) {
    var sql = "SELECT \(selectList.joined(separator: ", ")) FROM \(relation)"
    guard let keys else {
      if let positionOrder { sql += " ORDER BY \(positionOrder)" }
      return (sql + " LIMIT \(limit) OFFSET \(offset)", [])
    }
    var binds: [SQLBindValue] = []
    if let key {
      let dialect = source.dialect
      let markers = zip(key.indices, keyCasts).map { index, cast in
        let marker = dialect.placeholder(index + 1)
        return cast.map { "CAST(\(marker) AS \($0))" } ?? marker
      }
      sql +=
        keys.count == 1
        ? " WHERE \(keys[0]) > \(markers[0])"
        : " WHERE (\(keys.joined(separator: ", "))) > (\(markers.joined(separator: ", ")))"
      binds = key.map { .text($0) }
    }
    return (sql + " ORDER BY \(keys.joined(separator: ", ")) LIMIT \(limit)", binds)
  }

  /// One row's values in the target's form, and their size toward the 4 MiB chunk budget
  func values(
    _ row: [CellValue], timestamps: ImportTypeInference.TimestampParser
  ) throws -> (values: [Value], bytes: Int) {
    var values: [Value] = []
    var bytes = 0
    for index in columns.indices {
      let column = columns[index].name
      guard index < row.count,
        let read = Self.value(row[index], binary: binary[index], source: source)
      else { throw CopyObjectsRunError.invalidValue(table: table, column: column) }
      guard
        let value = Self.normalized(
          read, form: forms[index], target: target, timestamps: timestamps)
      else { throw CopyObjectsRunError.invalidValue(table: table, column: column) }
      switch value {
      case .null: break
      case .text(let text): bytes += text.utf8.count
      case .bytes(let data): bytes += data.count * 2
      }
      values.append(value)
    }
    return (values, bytes)
  }

  /// The primary key of `row` as the next keyset read binds it; nil when reading by position
  func key(_ row: [CellValue]) throws -> [String]? {
    guard let keys else { return nil }
    let start = columns.count
    guard row.count == start + keys.count else {
      throw CopyObjectsRunError.unreadableKey(table: table)
    }
    return try row[start...].map { cell in
      guard let text = Self.keyText(cell, source: source) else {
        throw CopyObjectsRunError.unreadableKey(table: table)
      }
      return text
    }
  }

  // MARK: - Reads

  /// Text in the engine's own form behind a `v` (PostgreSQL, MySQL and DuckDB sessions may read
  /// an empty text as NULL; text concatenated with NULL stays NULL), or bytes as hex. SQLite
  /// values are read as stored.
  private static func valueRead(
    _ name: String, binary: Bool, form: CopyObjectsTypeMapping.ValueForm, source: Engine
  ) -> String {
    switch source {
    case .postgresql:
      if binary { return "'v' || encode(\(name), 'hex')" }
      switch form {
      case .jsonText: return "'v' || to_json(\(name))::text"
      case .timestampUTC:
        return "'v' || to_char(\(name) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US')"
      default: return "'v' || \(name)::text"
      }
    case .mysql:
      return binary ? "CONCAT('v', HEX(\(name)))" : "CONCAT('v', CAST(\(name) AS CHAR))"
    case .sqlite:
      return name
    case .duckdb:
      if binary { return "'v' || hex(\(name))" }
      switch form {
      case .jsonText: return "'v' || CAST(to_json(\(name)) AS VARCHAR)"
      case .timestampUTC: return "'v' || CAST(timezone('UTC', \(name)) AS VARCHAR)"
      default: return "'v' || CAST(\(name) AS VARCHAR)"
      }
    }
  }

  /// A primary key column read again in the engine's own text form, for the next read's bind
  private static func keyRead(_ name: String, source: Engine) -> String {
    switch source {
    case .postgresql: "'v' || \(name)::text"
    case .mysql: "CONCAT('v', CAST(\(name) AS CHAR))"
    case .sqlite: name
    case .duckdb: "'v' || CAST(\(name) AS VARCHAR)"
    }
  }

  /// Keyset needs a primary key of text-comparable columns: no binary column; on SQLite no
  /// column without affinity or with BLOB affinity (a text bind would not compare with its
  /// values) and no column that may hold NULL (SQLite allows NULL in most primary keys)
  private static func allowsKeyset(
    _ primaryKey: [String], planned: CopyObjectsPlan.Table, source: Engine
  ) -> Bool {
    guard !primaryKey.isEmpty else { return false }
    return primaryKey.allSatisfy { name in
      guard let column = planned.columns.first(where: { $0.name == name }),
        column.mapping.bindForm == .plain,
        let structure = planned.source.columns.first(where: { $0.name == name })
      else { return false }
      guard case .sqlite = source else { return true }
      let declared = SQLTokenizer.asciiUppercased(
        structure.dataType.trimmingCharacters(in: .whitespaces))
      if declared.isEmpty || declared.contains("BLOB") { return false }
      return !structure.isNullable || (primaryKey.count == 1 && declared == "INTEGER")
    }
  }

  // MARK: - Values

  /// A read cell as text or bytes; nil when it is not in the form read
  private static func value(_ cell: CellValue, binary: Bool, source: Engine) -> Value? {
    if case .null = cell { return .null }
    if case .sqlite = source {
      switch cell {
      case .data(let data): return .bytes(data)
      case .int(let number): return .text(String(number))
      case .double(let number): return .text(String(number))
      case .bool(let flag): return .text(flag ? "1" : "0")
      case .string(let text), .json(let text): return .text(text)
      default: return nil
      }
    }
    guard let text = prefixedText(cell) else { return nil }
    guard binary else { return .text(text) }
    return bytes(hex: text).map(Value.bytes)
  }

  private static func keyText(_ cell: CellValue, source: Engine) -> String? {
    guard case .sqlite = source else { return prefixedText(cell) }
    switch cell {
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .string(let text): return text
    default: return nil
    }
  }

  /// The text after the `v` every non-SQLite read starts with
  private static func prefixedText(_ cell: CellValue) -> String? {
    let text: String
    switch cell {
    case .string(let value), .json(let value): text = value
    case .data(let data):
      guard let value = String(data: data, encoding: .utf8) else { return nil }
      text = value
    default: return nil
    }
    guard text.unicodeScalars.first == "v" else { return nil }
    // Scalars, not characters: a combining mark after the prefix joins it in one character
    return String(text.unicodeScalars.dropFirst())
  }

  /// Hex digits (an odd count gets a leading 0, as MySQL's HEX of a BIT value) as bytes
  private static func bytes(hex text: String) -> Data? {
    guard SQLDumpDataRenderer.isHex(text[...]) else { return nil }
    let digits = Array((text.utf8.count.isMultiple(of: 2) ? "" : "0").utf8) + Array(text.utf8)
    var data = Data(capacity: digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)
      else { return nil }
      data.append(byte)
    }
    return data
  }

  /// `value` in the target's form for `form`; nil when it cannot be
  private static func normalized(
    _ value: Value, form: CopyObjectsTypeMapping.ValueForm, target: SQLDialect,
    timestamps: ImportTypeInference.TimestampParser
  ) -> Value? {
    guard case .text(let text) = value else {
      if form == .uuid, case .bytes(let data) = value, data.count == 16 {
        let hex = Array(data.hexDigits())
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
        return .text(parts.joined(separator: "-"))
      }
      return value
    }
    switch form {
    case .asIs, .date, .time, .jsonText:
      return value
    case .boolean:
      guard let flag = boolean(text) else { return nil }
      return .text(target == .postgresql ? (flag ? "true" : "false") : (flag ? "1" : "0"))
    case .timestamp:
      // MySQL DATETIME refuses ISO 8601 `T`, `Z` and offsets
      guard target == .mysql,
        let date = timestamps.date(from: text.trimmingCharacters(in: .whitespaces)),
        let mysql = CellUpdateStatement.inputText(.date(date), dialect: .mysql)
      else { return value }
      return .text(mysql)
    case .timestampUTC:
      // Read in UTC without an offset: MySQL DATETIME takes it so, the others need the offset
      return target == .mysql ? value : .text(text + "+00:00")
    case .uuid:
      return .text(text.lowercased())
    }
  }

  private static func boolean(_ text: String) -> Bool? {
    let word = SQLTokenizer.asciiLowercased(text.trimmingCharacters(in: .whitespaces))
    if ["t", "true", "y", "yes", "on", "1"].contains(word) { return true }
    if ["f", "false", "n", "no", "off", "0"].contains(word) { return false }
    return Int(word).map { $0 != 0 }
  }
}

/// One Copy Objects run. `run` once, `cancel` from anywhere.
actor CopyObjectsRun {
  /// Chunks done, of the planned total (which a 4 MiB split may raise)
  typealias Progress = @Sendable (_ chunksDone: Int, _ chunkTotal: Int) -> Void

  private let plan: CopyObjectsPlan
  private let checked: CopyObjectsDDLCheck.Checked
  private let source: DatabaseConnectionManager
  private let sourceLabel: String
  nonisolated let target: CopyObjectsTarget
  private let recorder: (any QueryHistoryRecording)?
  private let workspaceID: UUID?
  private let workspaceName: String?
  private nonisolated let cancelled = OSAllocatedUnfairLock(initialState: false)

  private var reads: [CopyObjectsTableRead] = []
  private var readIndex = 0
  /// The current table: the key of the last row read, the rows read, the next read's LIMIT, rows
  /// read but not sent yet, and whether a read came back short (no row left to read)
  private var lastKey: [String]?
  private var offset = 0
  private var limit = CopyObjectsTableRead.rowsPerChunk
  private var pendingRows: [[CellValue]] = []
  private var tableExhausted = false
  private var rowsRead = 0
  /// Rows the source returned, over every read (each row is read once), and each read's LIMIT
  private(set) var rowsFetched = 0
  private(set) var readLimits: [Int] = []
  private var maxChunkBytes: Int?
  private let timestamps = ImportTypeInference.TimestampParser()
  /// MySQL / MariaDB: the tables this run created whose DROP failed
  private var leftoverTables: [String] = []

  /// `source` and `target.manager` are connected; the caller closes them after the run.
  /// `recorder` gets the History row (nil when History is off).
  init(
    plan: CopyObjectsPlan, checked: CopyObjectsDDLCheck.Checked,
    source: DatabaseConnectionManager, sourceLabel: String, target: CopyObjectsTarget,
    recorder: (any QueryHistoryRecording)?, workspaceID: UUID? = nil, workspaceName: String? = nil
  ) {
    self.plan = plan
    self.checked = checked
    self.source = source
    self.sourceLabel = sourceLabel
    self.target = target
    self.recorder = recorder
    self.workspaceID = workspaceID
    self.workspaceName = workspaceName
  }

  /// Stops the run: no further chunk is read, and the statement the target runs is cancelled
  /// (the run then rolls back, and on MySQL / MariaDB drops what it created)
  nonisolated func cancel() {
    let first = cancelled.withLock { flag in
      defer { flag = true }
      return !flag
    }
    guard first else { return }
    let manager = target.manager
    Task {
      let status = await manager.runningStatementStatus()
      guard status.inFlight else { return }
      _ = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
    }
  }

  /// Copies the plan. Throws `CopyObjectsRunError.cancelled` or `.failed`.
  func run(progress: Progress? = nil) async throws -> CopyObjectsRunResult {
    let started = ContinuousClock.now
    do {
      let result = try await copy(progress: progress)
      await record(.success, error: nil, started: started)
      return result
    } catch {
      let failure: CopyObjectsRunError =
        if cancelled.withLock({ $0 }) || error is CancellationError {
          .cancelled(leftoverTables: leftoverTables)
        } else {
          .failed(
            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            leftoverTables: leftoverTables)
        }
      if case .cancelled = failure {
        await record(.cancelled, error: failure.errorDescription, started: started)
      } else {
        await record(.error, error: failure.errorDescription, started: started)
      }
      throw failure
    }
  }

  // MARK: - Run

  private func copy(progress: Progress?) async throws -> CopyObjectsRunResult {
    try refuseIfCancelled()
    reads = try plan.tables.map {
      try CopyObjectsTableRead($0, source: plan.source, target: plan.target)
    }
    var warnings = plan.warnings
    var chunkTotal = 0
    for read in reads {
      if read.readsUnordered {
        warnings.append(
          "\"\(read.table)\": no primary key, so rows are read by position with no order: "
            + "rows may be missed or repeated.")
      } else if read.readsByPosition {
        warnings.append(
          "\"\(read.table)\": no usable primary key, so rows are read by position: rows "
            + "changed during the copy may be missed or repeated.")
      }
      let counted = try await source.readCopyObjectsRows(read.countSQL, binds: [])
      let count = try Self.count(counted)
      chunkTotal +=
        (count + CopyObjectsTableRead.rowsPerChunk - 1) / CopyObjectsTableRead.rowsPerChunk
    }
    try refuseIfCancelled()

    let manager = target.manager
    let mysql = plan.target.dialect == .mysql
    if mysql {
      maxChunkBytes = ImportSQLBuilder.mysqlChunkByteCap(
        maxAllowedPacket: await manager.mysqlServerInfo?.maxAllowedPacket)
    }
    let epoch = await manager.connectionEpoch
    let total = chunkTotal
    var reporting: (@Sendable (Int) -> Void)?
    if let progress {
      reporting = { done in progress(done, max(done, total)) }
    }
    let batch = StreamedBatch(
      relation: try plan.target.dialect.qualified(
        schema: plan.targetSchema, name: plan.tables[0].name),
      nextChunk: { [self] in try await nextChunk() }, operation: "Copying rows",
      rowsLabel: "copied rows")
    let rows: Int
    if mysql {
      rows = try await copyToMySQL(batch, epoch: epoch, progress: reporting)
    } else {
      rows = try await manager.executeGatedBatch(
        streamed: batch, policy: target.policy, connectionEpoch: epoch,
        prelude: transactionalPrelude().map(Self.bound),
        postlude: (checked.postRows + plan.identityRestartStatements()).map(Self.bound),
        progress: reporting)
    }
    return CopyObjectsRunResult(tables: plan.tables.count, rows: rows, warnings: warnings)
  }

  /// PostgreSQL and SQLite: the checked CREATE TABLEs, after SQLite's deferred foreign-key
  /// checks (always first, whether or not the edited DDL kept the PRAGMA)
  private func transactionalPrelude() -> [String] {
    let creates = checked.prelude.filter { $0.createsTable != nil }.map(\.sql)
    guard case .sqlite = plan.target else { return creates }
    return [CopyObjectsPlan.sqliteDeferForeignKeys] + creates
  }

  /// MySQL / MariaDB: each CREATE TABLE alone, the rows in one transaction, then each index and
  /// foreign key alone. Any failure drops the tables created so far (`dropCreated`).
  private func copyToMySQL(
    _ batch: StreamedBatch, epoch: UInt64, progress: (@Sendable (Int) -> Void)?
  ) async throws -> Int {
    let manager = target.manager
    var created: [String] = []
    do {
      for statement in checked.prelude {
        try refuseIfCancelled()
        _ = try await manager.executeGatedSequentialCommands(
          [statement.sql], policy: target.policy, connectionEpoch: epoch, expectedRows: nil)
        if let table = statement.createsTable { created.append(table) }
      }
      let rows = try await manager.executeGatedBatch(
        streamed: batch, policy: target.policy, connectionEpoch: epoch, progress: progress)
      for sql in checked.postRows {
        try refuseIfCancelled()
        _ = try await manager.executeGatedSequentialCommands(
          [sql], policy: target.policy, connectionEpoch: epoch, expectedRows: nil)
      }
      return rows
    } catch {
      leftoverTables = await dropCreated(created)
      throw error
    }
  }

  /// Drops `tables` (created by this run) in reverse order with the session's foreign key
  /// checks off. Returns those whose DROP failed, in creation order.
  private func dropCreated(_ tables: [String]) async -> [String] {
    guard !tables.isEmpty else { return [] }
    let manager = target.manager
    _ = try? await manager.executeInternal("SET FOREIGN_KEY_CHECKS = 0")
    var failed: Set<String> = []
    for table in tables.reversed() {
      do {
        let relation = try SQLDialect.mysql.qualified(schema: plan.targetSchema, name: table)
        _ = try await manager.executeInternal("DROP TABLE \(relation)")
      } catch {
        failed.insert(table)
      }
    }
    _ = try? await manager.executeInternal("SET FOREIGN_KEY_CHECKS = 1")
    return tables.filter(failed.contains)
  }

  /// The next chunk's INSERTs: the current table's rows waiting from the last read, else its
  /// next read, as many as fit in 4 MiB (at least one); the rest wait for the next chunk. Moves
  /// to the next table when one is done. Nil once every table is read.
  private func nextChunk() async throws -> [BoundStatement]? {
    while readIndex < reads.count {
      try refuseIfCancelled()
      try Task.checkCancellation()
      let read = reads[readIndex]
      // A PostgreSQL table without columns has no value to read
      guard !read.columns.isEmpty else {
        nextTable()
        continue
      }
      if pendingRows.isEmpty {
        guard !tableExhausted else {
          nextTable()
          continue
        }
        let (sql, binds) = read.select(after: lastKey, offset: offset, limit: limit)
        readLimits.append(limit)
        let rows = try await source.readCopyObjectsRows(sql, binds: binds)
        try refuseIfCancelled()
        rowsFetched += rows.count
        tableExhausted = rows.count < limit
        if let last = rows.last { lastKey = try read.key(last) }
        offset += rows.count
        pendingRows = rows
        guard !rows.isEmpty else { continue }
      }
      var values: [[ImportSQLBuilder.Value]] = []
      var bytes = 0
      for row in pendingRows {
        guard bytes < CopyObjectsTableRead.bytesPerChunk else { break }
        let converted = try read.values(row, timestamps: timestamps)
        values.append(converted.values)
        bytes += converted.bytes
      }
      pendingRows.removeFirst(values.count)
      if !pendingRows.isEmpty {
        // Over the budget: the next read takes no more rows than fitted
        limit = values.count
      } else if values.count == limit, bytes <= CopyObjectsTableRead.bytesPerChunk / 2 {
        // A whole read fitted with room to spare
        limit = min(limit * 2, CopyObjectsTableRead.rowsPerChunk)
      }
      rowsRead += values.count
      return try ImportSQLBuilder.insertStatements(
        schema: plan.targetSchema, table: read.table, columns: read.columns, values: values,
        dialect: plan.target.dialect, maxChunkBytes: maxChunkBytes)
    }
    return nil
  }

  /// Moves to the next table's first read
  private func nextTable() {
    readIndex += 1
    lastKey = nil
    offset = 0
    limit = CopyObjectsTableRead.rowsPerChunk
    pendingRows = []
    tableExhausted = false
  }

  private func refuseIfCancelled() throws {
    if cancelled.withLock({ $0 }) { throw DatabaseError.batchCancelled }
  }

  private static func bound(_ sql: String) -> BoundStatement {
    BoundStatement(sql: sql, values: [], expectedRows: nil)
  }

  private static func count(_ rows: [[CellValue]]) throws -> Int {
    switch rows.first?.first {
    case .int(let count): return count
    case .string(let text): if let count = Int(text) { return count }
    case .double(let count): return Int(count)
    default: break
    }
    throw DatabaseError.queryFailed("The row count could not be read.", 0)
  }

  // MARK: - History

  /// One row: "Copy Objects: n tables, m rows from <source label>" (the rows read so far)
  private func record(
    _ status: QueryHistoryEntry.Status, error: String?, started: ContinuousClock.Instant
  ) async {
    guard let recorder else { return }
    let config = target.config
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let tables = plan.tables.count
    let sql =
      "Copy Objects: \(tables) table\(tables == 1 ? "" : "s"), "
      + "\(rowsRead) row\(rowsRead == 1 ? "" : "s") from \(sourceLabel)"
    await recorder.record(
      QueryHistoryEntry(
        id: 0, sql: sql, executedAt: Date(),
        durationMs: Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded()),
        rowCount: rowsRead, status: status, errorMessage: error,
        connectionKey: QueryHistoryIdentity.connectionKey(for: config),
        connectionLabel: name.isEmpty ? "\(config.host)/\(config.database)" : name,
        workspaceID: workspaceID, workspaceName: workspaceName, source: .dataImport,
        kind: .schema))
  }
}

extension DatabaseConnectionManager {
  /// Copy Objects: every row of one app-built read (a count, or at most
  /// `CopyObjectsTableRead.rowsPerChunk` rows), with no row, cell or byte cap, so a large value
  /// is read whole. Refused unless it is one read; a relock stops it.
  func readCopyObjectsRows(_ sql: String, binds: [SQLBindValue]) async throws -> [[CellValue]] {
    try refuseIfRelocked(config)
    _ = try ReadOnlyQueryGuard.check(sql, dialect: Self.dialect(of: config))
    return try await withSession { session in
      var rows: [[CellValue]] = []
      for try await row in try await session.query(sql, binds: binds).rows {
        rows.append(row)
      }
      return rows
    }
  }
}
