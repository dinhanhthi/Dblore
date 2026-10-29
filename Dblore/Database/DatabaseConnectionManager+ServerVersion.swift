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
}
