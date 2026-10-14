// DatabaseTypes+MySQL.swift
// MySQL / MariaDB table identity and catalog value mapping.

import Foundation

extension TableRef {
  /// MySQL table identity: `mysql:` then the backtick-quoted database and table. Built only here.
  /// Each name is wrapped in backticks with its backticks doubled, so two different (database,
  /// table) pairs never give the same string, even with dots in either name. The string is
  /// compared, never split, and never spliced into SQL (no NUL check needed).
  nonisolated static func mysql(database: String, table: String) -> TableRef {
    func quoted(_ name: String) -> String {
      "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }
    return TableRef("mysql:" + quoted(database) + "." + quoted(table))
  }
}

/// Exact names and column ORDINAL_POSITIONs of one MySQL table, cached per connection
/// (`DatabaseConnectionManager.mysqlTableColumns`, a `MySQLTableColumnsCache`) under
/// `TableRef.mysql(database:table:)`.
nonisolated struct MySQLTableColumns: Sendable, Equatable {
  let database: String
  let table: String
  let ordinals: [String: Int]
}

/// `MySQLTableColumns` by table identity. Every `removeAll()` bumps `generation`, so a catalog
/// read that started before a clear cannot store its (possibly pre-DDL) ordinals afterwards.
nonisolated struct MySQLTableColumnsCache: Sendable {
  private var entries: [TableRef: MySQLTableColumns] = [:]
  private(set) var generation: UInt64 = 0

  subscript(tableID: TableRef) -> MySQLTableColumns? { entries[tableID] }

  mutating func removeAll() {
    entries.removeAll()
    generation &+= 1
  }

  /// Stores `columns` unless the cache was cleared since `generation` (read before the
  /// catalog query). Returns whether it was stored.
  @discardableResult
  mutating func store(
    _ columns: MySQLTableColumns, for tableID: TableRef, readAt generation: UInt64
  ) -> Bool {
    guard generation == self.generation else { return false }
    entries[tableID] = columns
    return true
  }
}

extension ForeignKeyAction {
  /// `information_schema.REFERENTIAL_CONSTRAINTS` UPDATE_RULE / DELETE_RULE text.
  /// MariaDB reports the default as RESTRICT, MySQL as NO ACTION; both are kept as read.
  nonisolated init(mysqlRule: String) {
    switch mysqlRule.uppercased() {
    case "CASCADE": self = .cascade
    case "SET NULL": self = .setNull
    case "SET DEFAULT": self = .setDefault
    case "RESTRICT": self = .restrict
    default: self = .noAction
    }
  }
}
