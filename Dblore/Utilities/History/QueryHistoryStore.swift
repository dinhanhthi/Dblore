// QueryHistoryStore.swift
// App-wide query history in SQLite, with an FTS5 index over SQL and labels.

import Foundation
import SQLite3

/// Persists executed statements. The actor owns the `SQLiteHandle`; callers never see it.
/// Tests pass a temporary file URL. `shared` opens Application Support/Dblore/History.sqlite.
actor QueryHistoryStore {
  nonisolated enum Scope: Sendable, Equatable {
    case all
    case connection(String)
    case workspace(UUID)
  }

  private static let pruneInterval = 500
  private static let maxSQLCharacters = 100_000
  private static let truncationMarker = "\n-- truncated"
  private static let dedupeWindow: TimeInterval = 2
  private static let columns = """
    history.id, history.sql, history.executed_at, history.duration_ms, history.row_count, \
    history.status, history.error_message, history.connection_key, history.connection_label, \
    history.workspace_id, history.workspace_name, history.source
    """

  /// History file under the app container. Creating this opens the database; tests must not.
  nonisolated static let shared: QueryHistoryStore = {
    let directory = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
    let url = directory.appendingPathComponent("History.sqlite")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return try QueryHistoryStore(url: url)
    } catch {
      preconditionFailure("Unable to open query history at \(url.path): \(error)")
    }
  }()

  private let database: SQLiteHandle
  private let fileURL: URL
  private var successfulInserts = 0

  init(url: URL) throws {
    let database = try SQLiteHandle(url: url)
    try Self.migrate(database)
    self.database = database
    self.fileURL = url
  }

  /// Inserts the entry, or updates the newest row when it is the same SQL on the same
  /// connection and ran within 2 seconds. SQL longer than 100_000 characters is cut and
  /// marked with `\n-- truncated`. The input `id` is ignored.
  /// - Returns: true when a new row was inserted. A dedupe update returns false.
  @discardableResult
  func record(_ entry: QueryHistoryEntry) throws -> Bool {
    try insertRecord(entry)
  }

  /// Counts a new row. Every 500 inserts, prunes with the current history settings.
  /// A prune failure is logged and does not surface to the caller.
  fileprivate func registerSuccessfulInsert() async {
    successfulInserts += 1
    guard successfulInserts >= Self.pruneInterval else { return }
    successfulInserts = 0
    let days: Int
    let maxEntries: Int
    (days, maxEntries) = await MainActor.run {
      (AppSettings.shared.historyRetentionDays, AppSettings.shared.historyMaxEntries)
    }
    do {
      try prune(olderThan: Self.retentionCutoff(retentionDays: days), maxEntries: maxEntries)
    } catch {
      await AppLogger.shared.error(
        "Query history prune failed: \(error.localizedDescription)", category: "History")
    }
  }

  private func insertRecord(_ entry: QueryHistoryEntry) throws -> Bool {
    let sql = Self.truncate(entry.sql)
    if let newest = try newestRow(),
      newest.sql == sql,
      newest.connectionKey == entry.connectionKey,
      abs(newest.executedAt.timeIntervalSince1970 - entry.executedAt.timeIntervalSince1970)
        <= Self.dedupeWindow
    {
      try updateOutcome(id: newest.id, entry: entry)
      return false
    }
    try insert(entry, sql: sql, preservingID: false)
    return true
  }

  /// `nil` when retention is forever (`0`). Otherwise `now` minus that many 24-hour days.
  nonisolated static func retentionCutoff(retentionDays: Int, now: Date = Date()) -> Date? {
    guard retentionDays > 0 else { return nil }
    return now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
  }

  /// Empty or whitespace `text` returns the newest rows and does not query FTS.
  /// Other text is escaped into quoted prefix tokens (`"token"*`) and ranked with `bm25()`.
  func search(text: String, scope: Scope, limit: Int, offset: Int) throws -> [QueryHistoryEntry] {
    try fetch(match: Self.matchExpression(for: text), scope: scope, limit: limit, offset: offset)
  }

  func delete(ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
    let statement = try database.prepare("DELETE FROM history WHERE id IN (\(placeholders))")
    for (offset, id) in ids.enumerated() {
      try statement.bind(Int32(offset + 1), .int(Int(id)))
    }
    try run(statement)
  }

  func clear() throws {
    try database.execute("DELETE FROM history")
  }

  /// Deletes rows older than `olderThan`, then deletes the oldest extras past `maxEntries`.
  func prune(olderThan: Date?, maxEntries: Int?) throws {
    if let olderThan {
      let statement = try database.prepare("DELETE FROM history WHERE executed_at < ?")
      try statement.bind(1, .double(olderThan.timeIntervalSince1970))
      try run(statement)
    }
    guard let maxEntries else { return }
    let extra = try count() - maxEntries
    guard extra > 0 else { return }
    let statement = try database.prepare(
      """
      DELETE FROM history WHERE id IN (
        SELECT id FROM history ORDER BY executed_at ASC, id ASC LIMIT ?
      )
      """
    )
    try statement.bind(1, .int(extra))
    try run(statement)
  }

  func count() throws -> Int {
    let statement = try database.prepare("SELECT COUNT(*) FROM history")
    guard try statement.step() else { return 0 }
    return Int(statement.columnInt(0))
  }

  /// Rows matching `text` and `scope`. The filter is the same one `search` uses.
  func count(text: String, scope: Scope) throws -> Int {
    let listing = Self.listing(match: Self.matchExpression(for: text), scope: scope)
    var sql = "SELECT COUNT(*) FROM history\(listing.join)"
    if !listing.conditions.isEmpty {
      sql += " WHERE " + listing.conditions.joined(separator: " AND ")
    }
    let statement = try database.prepare(sql)
    for (index, value) in listing.values.enumerated() {
      try statement.bind(Int32(index + 1), value)
    }
    guard try statement.step() else { return 0 }
    return Int(statement.columnInt(0))
  }

  /// Byte size of the sqlite file. In-memory databases report 0.
  func fileSize() throws -> Int64 {
    if Self.isMemory(fileURL) { return 0 }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  func exportJSON(to url: URL) throws {
    let entries = try allEntries()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(entries).write(to: url, options: .atomic)
  }

  /// `replace` deletes existing rows before inserting the file. Entries have no secrets.
  func importJSON(from url: URL, replace: Bool) throws {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let entries = try decoder.decode([QueryHistoryEntry].self, from: data)
    try database.transaction {
      if replace {
        try database.execute("DELETE FROM history")
      }
      for entry in entries {
        try insert(entry, sql: entry.sql, preservingID: true)
      }
    }
  }

  private static func migrate(_ database: SQLiteHandle) throws {
    guard database.userVersion < 1 else { return }
    try database.transaction {
      try database.execute(createTable)
      try database.execute(createFTS)
      try database.execute(insertTrigger)
      try database.execute(deleteTrigger)
      try database.execute(updateTrigger)
      try database.execute("CREATE INDEX history_executed_at ON history(executed_at)")
      try database.execute("CREATE INDEX history_connection_key ON history(connection_key)")
      try database.execute("PRAGMA user_version = 1")
    }
  }

  private static func truncate(_ sql: String) -> String {
    guard sql.count > maxSQLCharacters else { return sql }
    let end = sql.index(sql.startIndex, offsetBy: maxSQLCharacters)
    return String(sql[..<end]) + truncationMarker
  }

  /// Quoted prefix tokens. User characters stay inside quotes, so `"`, `*`, and `NEAR` are data.
  private static func matchExpression(for text: String) -> String? {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    if tokens.isEmpty { return nil }
    return tokens.map { token in
      let escaped = String(token).replacingOccurrences(of: "\"", with: "\"\"")
      return "\"\(escaped)\"*"
    }.joined(separator: " ")
  }

  private static func isMemory(_ url: URL) -> Bool {
    url.path == ":memory:" || url.absoluteString == ":memory:"
  }

  private func newestRow() throws -> QueryHistoryEntry? {
    try fetch(match: nil, scope: .all, limit: 1, offset: 0).first
  }

  private func updateOutcome(id: Int64, entry: QueryHistoryEntry) throws {
    let statement = try database.prepare(
      """
      UPDATE history
      SET executed_at = ?, duration_ms = ?, row_count = ?, status = ?, error_message = ?
      WHERE id = ?
      """
    )
    try statement.bind(1, .double(entry.executedAt.timeIntervalSince1970))
    try statement.bind(2, .int(entry.durationMs))
    try bind(statement, 3, integer: entry.rowCount)
    try statement.bind(4, .string(entry.status.rawValue))
    try bind(statement, 5, text: entry.errorMessage)
    try statement.bind(6, .int(Int(id)))
    try run(statement)
  }

  private func insert(_ entry: QueryHistoryEntry, sql: String, preservingID: Bool) throws {
    let statement: SQLiteHandle.Statement
    let firstValue: Int32
    if preservingID {
      statement = try database.prepare(
        """
        INSERT INTO history (
          id, sql, executed_at, duration_ms, row_count, status, error_message,
          connection_key, connection_label, workspace_id, workspace_name, source
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
      )
      try statement.bind(1, .int(Int(entry.id)))
      firstValue = 2
    } else {
      statement = try database.prepare(
        """
        INSERT INTO history (
          sql, executed_at, duration_ms, row_count, status, error_message,
          connection_key, connection_label, workspace_id, workspace_name, source
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
      )
      firstValue = 1
    }
    try statement.bind(firstValue, .string(sql))
    try statement.bind(firstValue + 1, .double(entry.executedAt.timeIntervalSince1970))
    try statement.bind(firstValue + 2, .int(entry.durationMs))
    try bind(statement, firstValue + 3, integer: entry.rowCount)
    try statement.bind(firstValue + 4, .string(entry.status.rawValue))
    try bind(statement, firstValue + 5, text: entry.errorMessage)
    try statement.bind(firstValue + 6, .string(entry.connectionKey))
    try statement.bind(firstValue + 7, .string(entry.connectionLabel))
    try bind(statement, firstValue + 8, text: entry.workspaceID?.uuidString)
    try bind(statement, firstValue + 9, text: entry.workspaceName)
    try statement.bind(firstValue + 10, .string(entry.source.rawValue))
    try run(statement)
  }

  /// JOIN, WHERE, and bound values shared by `search` and `count(text:scope:)`.
  private struct Listing {
    var join = ""
    var conditions: [String] = []
    var values: [CellValue] = []
  }

  private static func listing(match: String?, scope: Scope) -> Listing {
    var listing = Listing()
    if let match {
      listing.join = " JOIN history_fts ON history.id = history_fts.rowid"
      listing.conditions.append("history_fts MATCH ?")
      listing.values.append(.string(match))
    }
    switch scope {
    case .all:
      break
    case .connection(let key):
      listing.conditions.append("history.connection_key = ?")
      listing.values.append(.string(key))
    case .workspace(let id):
      listing.conditions.append("history.workspace_id = ?")
      listing.values.append(.string(id.uuidString))
    }
    return listing
  }

  private func fetch(
    match: String?, scope: Scope, limit: Int?, offset: Int
  ) throws
    -> [QueryHistoryEntry]
  {
    let listing = Self.listing(match: match, scope: scope)
    var sql = "SELECT \(Self.columns) FROM history\(listing.join)"
    var values = listing.values
    if !listing.conditions.isEmpty {
      sql += " WHERE " + listing.conditions.joined(separator: " AND ")
    }
    if match == nil {
      sql += " ORDER BY history.executed_at DESC, history.id DESC"
    } else {
      sql += " ORDER BY bm25(history_fts), history.executed_at DESC, history.id DESC"
    }
    if let limit {
      sql += " LIMIT ? OFFSET ?"
      values.append(.int(limit))
      values.append(.int(offset))
    }
    let statement = try database.prepare(sql)
    for (index, value) in values.enumerated() {
      try statement.bind(Int32(index + 1), value)
    }
    return try readEntries(statement)
  }

  private func allEntries() throws -> [QueryHistoryEntry] {
    try fetch(match: nil, scope: .all, limit: nil, offset: 0)
  }

  private func run(_ statement: SQLiteHandle.Statement) throws {
    while try statement.step() {}
  }

  private func readEntries(_ statement: SQLiteHandle.Statement) throws -> [QueryHistoryEntry] {
    var entries: [QueryHistoryEntry] = []
    while try statement.step() {
      entries.append(try readEntry(statement))
    }
    return entries
  }

  private func readEntry(_ row: SQLiteHandle.Statement) throws -> QueryHistoryEntry {
    let id = row.columnInt(0)
    guard let sql = row.columnText(1),
      let statusText = row.columnText(5),
      let status = QueryHistoryEntry.Status(rawValue: statusText),
      let connectionKey = row.columnText(7),
      let connectionLabel = row.columnText(8),
      let sourceText = row.columnText(11),
      let source = QueryHistoryEntry.Source(rawValue: sourceText)
    else {
      throw SQLiteError(code: SQLITE_CORRUPT, message: "history row \(id) is incomplete")
    }
    let workspaceID = row.columnText(9).flatMap(UUID.init(uuidString:))
    return QueryHistoryEntry(
      id: id,
      sql: sql,
      executedAt: Date(timeIntervalSince1970: row.columnDouble(2)),
      durationMs: Int(row.columnInt(3)),
      rowCount: row.columnNull(4) ? nil : Int(row.columnInt(4)),
      status: status,
      errorMessage: row.columnText(6),
      connectionKey: connectionKey,
      connectionLabel: connectionLabel,
      workspaceID: workspaceID,
      workspaceName: row.columnText(10),
      source: source
    )
  }

  private func bind(_ statement: SQLiteHandle.Statement, _ index: Int32, text: String?) throws {
    if let text {
      try statement.bind(index, .string(text))
    } else {
      try statement.bind(index, .null)
    }
  }

  private func bind(_ statement: SQLiteHandle.Statement, _ index: Int32, integer: Int?) throws {
    if let integer {
      try statement.bind(index, .int(integer))
    } else {
      try statement.bind(index, .null)
    }
  }

  private static let createTable = """
    CREATE TABLE history (
      id INTEGER PRIMARY KEY,
      sql TEXT NOT NULL,
      executed_at REAL NOT NULL,
      duration_ms INTEGER NOT NULL,
      row_count INTEGER,
      status TEXT NOT NULL,
      error_message TEXT,
      connection_key TEXT NOT NULL,
      connection_label TEXT NOT NULL,
      workspace_id TEXT,
      workspace_name TEXT,
      source TEXT NOT NULL
    )
    """

  private static let createFTS = """
    CREATE VIRTUAL TABLE history_fts USING fts5(
      sql,
      error_message,
      connection_label,
      workspace_name,
      content='history',
      content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    )
    """

  private static let insertTrigger = """
    CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
      INSERT INTO history_fts(rowid, sql, error_message, connection_label, workspace_name)
      VALUES (new.id, new.sql, new.error_message, new.connection_label, new.workspace_name);
    END
    """

  private static let deleteTrigger = """
    CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
      INSERT INTO history_fts(
        history_fts, rowid, sql, error_message, connection_label, workspace_name
      )
      VALUES (
        'delete', old.id, old.sql, old.error_message, old.connection_label, old.workspace_name
      );
    END
    """

  private static let updateTrigger = """
    CREATE TRIGGER history_au AFTER UPDATE ON history BEGIN
      INSERT INTO history_fts(
        history_fts, rowid, sql, error_message, connection_label, workspace_name
      )
      VALUES (
        'delete', old.id, old.sql, old.error_message, old.connection_label, old.workspace_name
      );
      INSERT INTO history_fts(rowid, sql, error_message, connection_label, workspace_name)
      VALUES (new.id, new.sql, new.error_message, new.connection_label, new.workspace_name);
    END
    """
}

extension QueryHistoryStore: QueryHistoryRecording {
  /// Logs and swallows persistence errors. Callers that need the error use `record(_:) throws`.
  /// From outside the actor this witness is preferred, so a history failure cannot fail a query.
  nonisolated func record(_ entry: QueryHistoryEntry) async {
    do {
      if try await insertRecord(entry) {
        await registerSuccessfulInsert()
      }
    } catch {
      await AppLogger.shared.error(
        "Failed to record query history: \(error.localizedDescription)", category: "History")
    }
  }
}
