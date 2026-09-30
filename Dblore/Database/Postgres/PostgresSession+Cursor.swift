// PostgresSession+Cursor.swift
// Server-side cursor: DECLARE, FETCH, CLOSE. The actor chooses cursor vs reset vs drain
// and passes the FETCH count (it adds one when it needs to see truncation).

import Foundation
import PostgresNIO

extension PostgresSession {
  static func cursorName() -> String {
    "dblore_cap_" + UUID().uuidString.prefix(8).lowercased()
  }

  static func declareSQL(name: String, query: String) -> String {
    "DECLARE \(name) NO SCROLL CURSOR FOR \(query)"
  }

  static func fetchSQL(name: String, maxRows: Int) -> String {
    "FETCH FORWARD \(maxRows) FROM \(name)"
  }

  static func closeSQL(name: String) -> String {
    "CLOSE \(name)"
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    let name = Self.cursorName()
    let declare = Self.declareSQL(name: name, query: sql)
    do {
      _ = try await commandMetadata(declare, binds: binds)
    } catch is ConnectionClosedError {
      throw ConnectionClosedError()
    } catch {
      throw PostgresSentError(sql: declare, underlying: error)
    }
    return SessionCursor(name: name)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    let collected = try await readQuery(
      Self.fetchSQL(name: cursor.name, maxRows: maxRows), binds: [], maxRows: maxRows,
      readToEnd: false)
    return Self.rowSource(collected)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    _ = try await commandMetadata(Self.closeSQL(name: cursor.name))
  }
}
