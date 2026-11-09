// DatabaseConnectionManager+ServerVersion.swift
// The PostgreSQL server version of the open session: `PostgresSession` reads
// `server_version_num` once at open, so asking sends nothing and can never land inside a user
// or app transaction. It lives exactly one connection epoch (a reconnect opens a new session).

import Foundation

extension DatabaseConnectionManager {
  /// `server_version_num` (120000 for 12.0) of the open PostgreSQL session; nil on other
  /// engines, with no session, or when the read at open failed.
  func serverVersionNum() -> Int? {
    (session as? PostgresSession)?.serverVersionNum
  }

  /// The open session's text byte lengths are UTF-8, so a data viewer page may cut text values
  /// (`DataViewerState.TextPrefixRules`): PostgreSQL `server_encoding` `UTF8` and SQLite
  /// `PRAGMA encoding` `UTF-8`, both read once at open; always on MySQL, whose lengths convert
  /// to utf8mb4. False on other engines, with no session, or when the read at open failed.
  func textLengthsAreUTF8() -> Bool {
    switch session {
    case let postgres as PostgresSession: postgres.serverEncoding == "UTF8"
    case let sqlite as SQLiteSession: sqlite.textEncoding == "UTF-8"
    case is MySQLSession: true
    default: false
    }
  }
}
