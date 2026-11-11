// ShortcutsRunner.swift
// What the Shortcuts actions run, without a window. Every call first asks `HeadlessAccessRule`
// (Shortcuts on, the connection on its list, not locked); the connections come from the runner's
// own `MCPConnectionPool`, fed by the rule's entry lookup, so they work with the MCP server off,
// are refused when unattended use would need the user (`refuseUnattended`: password command,
// missing secret, unpinned SSH host key) and close after a minute unused, or as soon as Shortcuts
// is turned off or the connection leaves its list. The pool connects without the connection's
// pre-connect and post-disconnect scripts. Open Connection connects in a window, which runs
// them: `openableEntry` refuses any connection with a script, then the same unattended cases.
// - Run Query: one statement `ReadOnlyQueryGuard` accepts, on the pool's read-only manager under
//   a Read-only policy; at most `maxRows` rows and `maxCSVBytes` of CSV (RFC 4180), with a
//   header row and a last line that names any cut and carries the untrusted-data notice.
// - Add Row: one INSERT built from the table's structure, values bound (never in the SQL text)
//   and names quoted, through the execution gate with the saved connection's policy. Shortcuts
//   has no approval dialog, so it runs only when the resolved commit style is Immediate and
//   Protected mode is off; Confirm, Review and Password, Read-only connections and engines
//   without row edits are refused before anything is connected or sent.
// Both record History as `.shortcuts` while History is on. Writes made here do not mark open
// table tabs stale.

import Foundation
import os

nonisolated struct ShortcutsRunner: Sendable {
  static let maxRows = 1_000
  static let maxCSVBytes = 1_024 * 1_024
  /// Longest error text handed to Shortcuts
  private static let maxErrorCharacters = 1_000

  /// Why an action was refused. Never carries a secret.
  nonisolated enum Refusal: Error, Equatable, LocalizedError {
    case readOnlyConnection
    case commitStyle(CommitStyle)
    case rowEditsUnsupported(engine: String)
    case duckDBNotSupported
    /// A plugin engine without a read-only path (`MCPConnectionError.engineNotSupported`)
    case engineNotSupported(engine: String)
    case valuesNotObject
    case nestedValue(column: String)
    case unknownColumns([String])
    case generatedColumn(String)
    case invalidValue(column: String, message: String)
    case decimalTooLong(column: String)
    case tableNotFound
    case ambiguousTable
    case opensWithScripts

    var errorDescription: String? {
      switch self {
      case .readOnlyConnection:
        "This connection is Read-only in Dblore. Nothing was sent to the database."
      case .commitStyle(let style):
        "Add Row runs only on connections whose commit style is Immediate, with Protected mode "
          + "off: this one uses \(style.rawValue.capitalized), which needs you in Dblore. "
          + "Nothing was sent to the database."
      case .rowEditsUnsupported(let engine):
        "Add Row is not available for \(engine) connections."
      case .duckDBNotSupported:
        "Shortcuts does not support DuckDB connections."
      case .engineNotSupported(let engine):
        "Shortcuts does not support \(engine) connections. Nothing was sent to the database."
      case .valuesNotObject:
        "Values must be a JSON object of column names and values, such as {\"name\": \"Ada\"}."
      case .nestedValue(let column):
        "The value of \"\(column)\" is a JSON array or object: pass it as a string."
      case .unknownColumns(let columns):
        "The table has no column named "
          + columns.map { "\"\($0)\"" }.joined(separator: ", ") + "."
      case .generatedColumn(let column):
        "\"\(column)\" is a generated column and cannot be written."
      case .invalidValue(let column, let message):
        "Column \"\(column)\": \(message)"
      case .decimalTooLong(let column):
        "The number for \"\(column)\" is too long once its exponent is written out: write the "
          + "value as plain digits in a JSON string, such as \"0.00000025\"."
      case .tableNotFound:
        "No table with that name was found."
      case .ambiguousTable:
        "Several schemas have a table with that name: use schema.table."
      case .opensWithScripts:
        "Shortcuts does not open connections that run your scripts or a password command: "
          + "open this one from Dblore."
      }
    }
  }

  let rule: HeadlessAccessRule
  let pool: MCPConnectionPool
  private let saved: @Sendable () async -> [ConnectionHistoryEntry]
  private let caller: @Sendable () async -> HeadlessAccessRule.Caller
  private let defaultCommitStyle: @Sendable () async -> CommitStyle
  private let recorder: any QueryHistoryRecording
  private let historyEnabled: @Sendable () async -> Bool

  /// `saved`: every saved connection, without passwords. `caller`: the Shortcuts settings as
  /// they are now. `password`: a connection's saved password, read off the main actor only
  /// after the rule allowed it; throws when the Keychain could not read it (the row is refused).
  /// `sessionFactory` nil: the app's sessions.
  init(
    rule: HeadlessAccessRule = HeadlessAccessRule(),
    saved: @escaping @Sendable () async -> [ConnectionHistoryEntry],
    caller: @escaping @Sendable () async -> HeadlessAccessRule.Caller,
    defaultCommitStyle: @escaping @Sendable () async -> CommitStyle,
    recorder: any QueryHistoryRecording,
    historyEnabled: @escaping @Sendable () async -> Bool,
    password: @escaping @Sendable (ConnectionConfig) throws -> String?,
    sessionFactory: (any DatabaseSessionFactory)? = nil,
    idleTimeout: Duration = .seconds(60)
  ) {
    self.rule = rule
    self.saved = saved
    self.caller = caller
    self.defaultCommitStyle = defaultCommitStyle
    self.recorder = recorder
    self.historyEnabled = historyEnabled
    pool = MCPConnectionPool(
      entry: rule.entryLookup(saved: saved, caller: caller, password: password),
      sessionFactory: sessionFactory, lockSource: rule.lockSource, idleTimeout: idleTimeout)
  }

  /// The connections Shortcuts may use now, by name
  func connections() async -> [ConnectionHistoryEntry] {
    rule.entries(saved: await saved(), caller: await caller())
  }

  /// The saved connection `id` while Shortcuts may use it, without its password
  func entry(id: UUID) async throws -> ConnectionHistoryEntry {
    try rule.entry(id: id, saved: await saved(), caller: await caller())
  }

  /// `entry(id:)` for Open Connection, which connects in a window as the Welcome window does
  /// (`connectRunningScripts`): refused when it has a pre-connect, post-disconnect or password
  /// command script, so no other app can run the user's scripts through it, and, as the actions
  /// run here are, when unattended use would need the user (`refuseUnattended`)
  func openableEntry(id: UUID) async throws -> ConnectionHistoryEntry {
    let entry = try await entry(id: id)
    let config = entry.config
    if config.preConnectScript != nil || config.postDisconnectScript != nil
      || (config.passwordCommandScript != nil && config.databaseType.capabilities.usesPassword)
    {
      throw Refusal.opensWithScripts
    }
    try await pool.refuseUnattended(config)
    return entry
  }

  // MARK: - Run Query

  /// The rows of one read-only statement as CSV (`csv`).
  @concurrent func runQuery(connectionID: UUID, sql: String) async throws -> String {
    let entry = try await entry(id: connectionID)
    let dialect = entry.config.databaseType.dialect
    let started = ContinuousClock.now
    do {
      _ = try ReadOnlyQueryGuard.check(sql, dialect: dialect)
      let result = try await MCPSQLReadSource(pool: pool).runRead(
        MCPReadRequest(connectionID: entry.id, sql: sql, maxRows: Self.maxRows))
      let output = Self.csv(result)
      await record(sql, entry: entry, started: started, rowCount: output.rows, error: nil)
      return output.text
    } catch {
      await record(sql, entry: entry, started: started, rowCount: nil, error: error)
      throw Self.shortcutsError(error, config: entry.config)
    }
  }

  /// A header row, then rows while the text stays within `maxCSVBytes`, each cell cut to
  /// `MCPResultEncoder.maxCellCharacters` (binary as base64 of at most as many characters),
  /// then a last line naming the row count, any cut, and `MCPResultEncoder.dataNotice`. NULL is
  /// the bare text NULL, as Copy Rows writes it.
  static func csv(_ result: MCPReadResult) -> (text: String, rows: Int) {
    var text = line(result.columns.map { DataExporter.escapeCSV($0.name, quote: .ifNeeded) })
    var bytes = text.utf8.count
    var rows = 0
    var cutCells = 0
    var cutByBytes = false
    for row in result.rows {
      var cut = 0
      let fields = row.enumerated().map { index, value -> String in
        let wallClock = index < result.columns.count && result.columns[index].wallClock
        let (field, wasCut) = cell(value, wallClock: wallClock)
        if wasCut { cut += 1 }
        return DataExporter.escapeCSV(field, quote: .ifNeeded)
      }
      let next = line(fields)
      guard bytes + next.utf8.count <= maxCSVBytes else {
        cutByBytes = true
        break
      }
      text += next
      bytes += next.utf8.count
      rows += 1
      cutCells += cut
    }
    var summary = rows == 1 ? "1 row." : "\(rows.formatted()) rows."
    if cutByBytes {
      summary += " Cut at 1 MB: more rows were not returned."
    } else if result.rowsTruncated {
      summary += " Cut at \(rows.formatted()) rows: more rows were not returned."
    }
    if cutCells > 0 {
      summary +=
        " \(cutCells.formatted()) \(cutCells == 1 ? "value was" : "values were") cut at "
        + "\(MCPResultEncoder.maxCellCharacters.formatted()) characters."
    }
    return (text + summary + " " + MCPResultEncoder.dataNotice, rows)
  }

  private static func line(_ fields: [String]) -> String {
    fields.joined(separator: ",") + "\r\n"
  }

  /// The cell's text (a date in its column's output form), cut by position (the pool already
  /// cut it a little past the limit)
  private static func cell(_ value: CellValue, wallClock: Bool) -> (text: String, cut: Bool) {
    let max = MCPResultEncoder.maxCellCharacters
    if case .data(let data) = value {
      let shown = max / 4 * 3
      guard data.count > shown else { return (data.base64EncodedString(), false) }
      return (Data(data.prefix(shown)).base64EncodedString(), true)
    }
    let text = value.outputString(wallClock: wallClock)
    guard let end = text.index(text.startIndex, offsetBy: max, limitedBy: text.endIndex),
      end < text.endIndex
    else { return (text, false) }
    return (String(text[..<end]), true)
  }

  // MARK: - Add Row

  /// Inserts one row into `table` (`schema.table`, or a table name only one schema has) with
  /// `values`, a JSON object of column names and values. Returns the rows inserted.
  @concurrent func addRow(connectionID: UUID, table: String, values: String) async throws -> Int {
    let entry = try await entry(id: connectionID)
    let config = entry.config
    let policy = try Self.checkAddRow(config, defaultCommitStyle: await defaultCommitStyle())
    let parsed = try Self.parseValues(values)
    let started = ContinuousClock.now
    // The INSERT as History shows it, made inside the pool's closure
    let preview = OSAllocatedUnfairLock(initialState: "")
    do {
      let inserted = try await pool.withWritableManager(for: entry.id) { manager in
        // Review turned on since the check (or a transaction left open) would hold the row in
        // a transaction nobody commits
        guard await !manager.effectivePolicy(for: policy).protectedMode else {
          throw Refusal.commitStyle(.review)
        }
        let dialect = config.databaseType.dialect
        let found = try Self.table(table, in: try await manager.fetchTables())
        let structure = try await manager.fetchTableStructure(
          schema: found.schema, table: found.name)
        let keyTypes = Dictionary(
          structure.columns.compactMap { column in column.postgresType.map { (column.name, $0) } },
          uniquingKeysWith: { first, _ in first })
        let target = EditTarget(
          qualifiedName: try dialect.qualified(schema: structure.schema, name: structure.name),
          tableID: structure.tableID, primaryKeyColumns: [],
          connectionEpoch: await manager.connectionEpoch, keyTypes: keyTypes)
        var set = RowChangeSet(target: target)
        let engine = config.databaseType
        set.stageInsert(
          values: try Self.cellValues(parsed, structure: structure, engine: engine))
        let columns = structure.columns.map {
          let type = $0.columnType ?? $0.dataType
          return ColumnInfo(
            name: $0.name, type: type, wallClock: Self.isWallClock(type: type, engine: engine))
        }
        let text = try RowChangeSQLBuilder.previewText(
          for: set, target: target, columns: columns, dialect: dialect)
        preview.withLock { $0 = text }
        let statements = try RowChangeSQLBuilder.statements(
          for: set, target: target, columns: columns, dialect: dialect)
        let counts = try await manager.executeGatedBatch(
          statements, policy: policy, connectionEpoch: target.connectionEpoch)
        return counts.reduce(0, +)
      }
      await record(
        preview.withLock { $0 }, entry: entry, started: started, rowCount: inserted, error: nil)
      return inserted
    } catch {
      await record(
        preview.withLock { $0 }, entry: entry, started: started, rowCount: nil, error: error)
      throw Self.shortcutsError(error, config: config)
    }
  }

  /// The policy Add Row runs under, or the refusal, from the saved connection alone: an engine
  /// with row edits, not Read-only, commit style Immediate and Protected mode off (the same
  /// commit-style reading as MCP's execute_write, without its approval).
  static func checkAddRow(
    _ config: ConnectionConfig, defaultCommitStyle: CommitStyle
  ) throws -> ProtectionPolicy {
    let type = config.databaseType
    guard type.capabilities.supportsRowStaging else {
      throw Refusal.rowEditsUnsupported(engine: type.rawValue)
    }
    let policy = ProtectionPolicy(config: config)
    guard policy.protectionLevel != .readOnly else { throw Refusal.readOnlyConnection }
    let style = config.resolvedCommitStyle(fallback: defaultCommitStyle)
    guard style == .immediate, !policy.protectedMode else { throw Refusal.commitStyle(style) }
    return policy
  }

  /// One column's value as `parseValues` reads it
  struct ParsedValue: Equatable, Sendable {
    /// The value's text, nil for JSON null: a number's `NSNumber` text, `true` / `false`
    var text: String?
    /// A JSON number's own token text (`19.90`, `2.5e-7`), nil for any other value
    var numberToken: String?
  }

  /// Column name to value, its text nil for JSON null. Numbers keep their `NSNumber` text and
  /// their token as written; true and false read as such; arrays and objects are refused.
  static func parseValues(_ json: String) throws -> [String: ParsedValue] {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else { throw Refusal.valuesNotObject }
    // A key the scan reads otherwise than JSONSerialization keeps its NSNumber text
    let tokens = NumberTokenScanner.tokens(json) ?? [:]
    var values: [String: ParsedValue] = [:]
    for (column, value) in object {
      switch value {
      case is NSNull:
        values[column] = ParsedValue(text: nil)
      case let text as String:
        values[column] = ParsedValue(text: text)
      case let number as NSNumber:
        values[column] =
          CFGetTypeID(number) == CFBooleanGetTypeID()
          ? ParsedValue(text: number.boolValue ? "true" : "false")
          : ParsedValue(text: number.stringValue, numberToken: tokens[column])
      default:
        throw Refusal.nestedValue(column: column)
      }
    }
    return values
  }

  /// `cellValues(_:structure:engine:)` for texts alone (no number token)
  static func cellValues(
    _ values: [String: String?], structure: TableStructure, engine: DatabaseType
  ) throws -> [String: CellValue] {
    try cellValues(
      values.mapValues { ParsedValue(text: $0) }, structure: structure, engine: engine)
  }

  /// `values` typed for their columns as pasted rows are (`PastedRows.cellValue`, a JSON string
  /// is quoted text), a naive timestamp of `engine` as its wall clock and a zoned one in the
  /// display zone, whatever its precision or spelling (`dateColumnType`). Unknown names (exact
  /// match) and generated columns are refused. A JSON number going into a NUMERIC / DECIMAL
  /// column (`CellValue.placeholder(forColumnType:)` is `.decimal`) binds its own token text,
  /// an exponent written out as plain digits, never through Double; an exponent too long to
  /// write out refuses the row, and a token that is no plain number keeps its NSNumber text.
  static func cellValues(
    _ values: [String: ParsedValue], structure: TableStructure, engine: DatabaseType
  ) throws -> [String: CellValue] {
    let columns = Dictionary(
      structure.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let unknown = values.keys.filter { columns[$0] == nil }.sorted()
    guard unknown.isEmpty else { throw Refusal.unknownColumns(unknown) }
    var typed: [String: CellValue] = [:]
    for (name, value) in values {
      guard let column = columns[name] else { continue }
      guard column.generated == nil else { throw Refusal.generatedColumn(name) }
      guard var text = value.text else {
        typed[name] = .null
        continue
      }
      let type = column.columnType ?? column.dataType
      if let token = value.numberToken,
        case .decimal = CellValue.placeholder(forColumnType: type)
      {
        switch DecimalText.plain(fromNumberToken: token) {
        case .plain(let plain): text = plain
        case .tooLong: throw Refusal.decimalTooLong(column: name)
        case .notANumber: break
        }
      }
      do {
        typed[name] = try PastedRows.cellValue(
          .init(text: text, quoted: true), columnType: dateColumnType(type),
          wallClock: isWallClock(type: type, engine: engine), dialect: engine.dialect)
      } catch {
        throw Refusal.invalidValue(column: name, message: error.message)
      }
    }
    return typed
  }

  /// `ColumnInfo.wallClock` of a catalog column type, the result columns' rule read from the
  /// type name without its `(n)` precision: PostgreSQL `timestamp [without time zone]`, MySQL
  /// DATETIME, DuckDB TIMESTAMP, TIMESTAMP_S, _MS and _NS.
  static func isWallClock(type: String, engine: DatabaseType) -> Bool {
    let name = normalizedTypeName(type)
    switch engine {
    case .postgresql: return name == "TIMESTAMP" || name == "TIMESTAMP WITHOUT TIME ZONE"
    case .mysql: return name == "DATETIME"
    case .duckdb:
      return ["TIMESTAMP", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS"].contains(name)
    default: return false
    }
  }

  /// A timestamp type as the date check (`CellValue.placeholder(forColumnType:)`) spells it:
  /// `TIMESTAMP` or `TIMESTAMPTZ` for any precision, `WITH` / `WITHOUT TIME ZONE` spelling or
  /// case (MySQL `timestamp(6)`, PostgreSQL `timestamp(3) with time zone`). Any other type
  /// unchanged.
  static func dateColumnType(_ type: String) -> String {
    switch normalizedTypeName(type) {
    case "TIMESTAMP", "TIMESTAMP WITHOUT TIME ZONE": "TIMESTAMP"
    case "TIMESTAMPTZ", "TIMESTAMP WITH TIME ZONE": "TIMESTAMPTZ"
    default: type
    }
  }

  /// `type` upper-cased, without its `(n)` precision, single-spaced
  private static func normalizedTypeName(_ type: String) -> String {
    type.uppercased().replacing(/\(\s*\d+\s*\)/, with: "")
      .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  }

  /// `reference` as `schema.table` first, else the one table of that name (from the catalog,
  /// never SQL built from the name).
  static func table(_ reference: String, in tables: [DatabaseTable]) throws -> DatabaseTable {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let qualified = tables.filter { "\($0.schema).\($0.name)" == reference }
    if qualified.count == 1 { return qualified[0] }
    let named = tables.filter { $0.name == reference }
    guard named.count < 2, qualified.count < 2 else { throw Refusal.ambiguousTable }
    guard let table = named.first else { throw Refusal.tableNotFound }
    return table
  }

  // MARK: - History and errors

  /// One History row while History is on and `sql` has a statement. A statement that carries a
  /// password is recorded with its string literals redacted and no error text.
  private func record(
    _ sql: String, entry: ConnectionHistoryEntry, started: ContinuousClock.Instant,
    rowCount: Int?, error: Error?
  ) async {
    let config = entry.config
    let dialect = config.databaseType.dialect
    let statements = SQLStatementClassifier.classify(sql, dialect: dialect)
    guard !statements.isEmpty, await historyEnabled() else { return }
    let redacted = SQLStatementClassifier.containsPasswordLiteral(sql, dialect: dialect)
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    var status = QueryHistoryEntry.Status.success
    if let error {
      if case DatabaseError.queryCancelled = error { status = .cancelled } else { status = .error }
    }
    await recorder.record(
      QueryHistoryEntry(
        id: 0, sql: redacted ? MCPToolService.redactingStrings(sql, dialect: dialect) : sql,
        executedAt: Date(),
        durationMs: Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded()),
        rowCount: rowCount, status: status,
        errorMessage: redacted ? nil : error.map { Self.message(for: $0, config: config) },
        connectionKey: QueryHistoryIdentity.connectionKey(for: config),
        connectionLabel: name.isEmpty ? "\(config.host)/\(config.database)" : name,
        workspaceID: nil, workspaceName: nil, source: .shortcuts,
        kind: MCPToolService.historyKind(statements)))
    LocalDataNotifications.post(.queryHistory)
  }

  /// Text for Shortcuts and History: refusals as they read, server text scrubbed of the
  /// connection's identifiers (`MCPToolService.scrub`) and cut to `maxErrorCharacters`.
  static func message(for error: Error, config: ConnectionConfig) -> String {
    shortcutsError(error, config: config).localizedDescription
  }

  /// `error` as Shortcuts gets it: a refusal as is; the pool's unknown connection as the rule's
  /// refusal; anything else (server text) as a scrubbed `ShortcutsError`
  static func shortcutsError(_ error: Error, config: ConnectionConfig) -> Error {
    switch error {
    case MCPConnectionError.unknownConnection:
      return HeadlessAccessRule.Refusal.notFound
    case MCPConnectionError.duckDBNotSupported:
      return Refusal.duckDBNotSupported
    case MCPConnectionError.engineNotSupported(let type):
      return Refusal.engineNotSupported(engine: type.rawValue)
    case is Refusal, is HeadlessAccessRule.Refusal, is MCPConnectionError,
      is ReadOnlyQueryGuard.Refusal, is ShortcutsError:
      return error
    default:
      let text = MCPToolService.scrub(error.localizedDescription, config: config)
      return ShortcutsError(message: String(text.prefix(maxErrorCharacters)))
    }
  }
}

/// A failed action's text, as Shortcuts shows it
nonisolated struct ShortcutsError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

// MARK: - App wiring

extension ShortcutsRunner {
  /// The runner the actions use, on the app's settings, saved connections, Keychain and History
  @MainActor static let shared = live(settings: .shared)

  /// The rule's caller from `settings`
  @MainActor static func caller(_ settings: AppSettings) -> HeadlessAccessRule.Caller {
    .shortcuts(
      enabled: settings.shortcutsEnabled, allowlist: settings.shortcutsAllowedConnectionIDs)
  }

  @MainActor private static func live(settings: AppSettings) -> ShortcutsRunner {
    let runner = ShortcutsRunner(
      saved: { await MainActor.run { SessionManager.loadHistory(passwords: NoPasswordStore()) } },
      caller: { await MainActor.run { caller(settings) } },
      defaultCommitStyle: { await MainActor.run { settings.commitStyle } },
      recorder: NotebookViewModel.defaultHistoryRecorder(),
      historyEnabled: { await MainActor.run { settings.historyEnabled } },
      password: { config in
        try SessionManager.isRunningAsTestHost
          ? nil
          : KeychainConnectionPasswordStore.readPassword(
            forKey: ConnectionKeychainKey.password(for: config))
      })
    closeRevoked(pool: runner.pool, settings: settings, allowed: usable(settings))
    return runner
  }

  @MainActor private static func usable(_ settings: AppSettings) -> Set<UUID> {
    settings.shortcutsEnabled ? settings.shortcutsAllowedConnectionIDs : []
  }

  /// Closes the managers of connections Shortcuts may no longer use (turned off, or off its
  /// list) as the settings change; the pool's lookup refuses them from then on anyway.
  @MainActor private static func closeRevoked(
    pool: MCPConnectionPool, settings: AppSettings, allowed: Set<UUID>
  ) {
    withObservationTracking {
      _ = usable(settings)
    } onChange: {
      Task { @MainActor in
        let now = usable(settings)
        closeRevoked(pool: pool, settings: settings, allowed: now)
        for id in allowed.subtracting(now) { await pool.close(id: id) }
      }
    }
  }
}

/// Each key's number token text in the flat JSON object Add Row reads, as written: keys decoded
/// with JSON's escapes, string values skipped whole (their digits are never numbers). A repeated
/// key has no token, so its column keeps the value JSONSerialization chose (the first one on
/// macOS 27, which no rule pins). Nil for text that is not such an object, a nested value
/// included.
nonisolated enum NumberTokenScanner {
  static func tokens(_ json: String) -> [String: String]? {
    var cursor = Cursor(bytes: Array(json.utf8))
    return cursor.object()
  }

  private struct Cursor {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func object() -> [String: String]? {
      var tokens: [String: String] = [:]
      var keys: Set<String> = []
      var repeated: Set<String> = []
      skipSpace()
      guard take(UInt8(ascii: "{")) else { return nil }
      skipSpace()
      if take(UInt8(ascii: "}")) { return atEnd() ? tokens : nil }
      while true {
        skipSpace()
        guard let key = string() else { return nil }
        if !keys.insert(key).inserted { repeated.insert(key) }
        skipSpace()
        guard take(UInt8(ascii: ":")) else { return nil }
        skipSpace()
        guard let byte = peek() else { return nil }
        if byte == UInt8(ascii: "\"") {
          guard string() != nil else { return nil }
          tokens[key] = nil
        } else if byte == UInt8(ascii: "-") || Self.isDigit(byte) {
          tokens[key] = run { Self.isDigit($0) || Self.numberMarks.contains($0) }
        } else {
          let word = run { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
          guard ["true", "false", "null"].contains(word) else { return nil }
          tokens[key] = nil
        }
        skipSpace()
        if take(UInt8(ascii: ",")) { continue }
        guard take(UInt8(ascii: "}")), atEnd() else { return nil }
        return tokens.filter { !repeated.contains($0.key) }
      }
    }

    /// A JSON string at the cursor, decoded (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\uXXXX`)
    private mutating func string() -> String? {
      guard take(UInt8(ascii: "\"")) else { return nil }
      var units: [UInt16] = []
      var raw: [UInt8] = []
      func flush() {
        units += String(decoding: raw, as: UTF8.self).utf16
        raw.removeAll()
      }
      while let byte = peek() {
        index += 1
        switch byte {
        case UInt8(ascii: "\""):
          flush()
          return String(decoding: units, as: UTF16.self)
        case UInt8(ascii: "\\"):
          flush()
          guard let escape = peek() else { return nil }
          index += 1
          switch escape {
          case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
            units.append(UInt16(escape))
          case UInt8(ascii: "b"): units.append(0x08)
          case UInt8(ascii: "f"): units.append(0x0C)
          case UInt8(ascii: "n"): units.append(0x0A)
          case UInt8(ascii: "r"): units.append(0x0D)
          case UInt8(ascii: "t"): units.append(0x09)
          case UInt8(ascii: "u"):
            guard index + 4 <= bytes.count,
              let unit = UInt16(
                String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { return nil }
            units.append(unit)
            index += 4
          default: return nil
          }
        default:
          raw.append(byte)
        }
      }
      return nil
    }

    private mutating func run(_ belongs: (UInt8) -> Bool) -> String {
      let start = index
      while let byte = peek(), belongs(byte) { index += 1 }
      return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func skipSpace() {
      while let byte = peek(),
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
          || byte == UInt8(ascii: "\r")
      {
        index += 1
      }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
      guard peek() == byte else { return false }
      index += 1
      return true
    }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func atEnd() -> Bool {
      skipSpace()
      return index == bytes.count
    }

    /// Bytes of a JSON number besides its digits
    private static let numberMarks: Set<UInt8> = Set("-+.eE".utf8)

    private static func isDigit(_ byte: UInt8) -> Bool {
      byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
  }
}
