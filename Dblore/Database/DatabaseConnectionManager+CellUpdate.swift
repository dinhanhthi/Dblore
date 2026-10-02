//
//  DatabaseConnectionManager+CellUpdate.swift
//  Dblore
//
//  Inline grid edit: primary-key-only UPDATE with bind parameters. Sent through
//  `executeGatedUpdate(_:policy:connectionEpoch:)` in +Gate.
//

import Foundation
import NIOCore
import PostgresNIO

/// Untyped text binds (OID 0). `.null` is SQL NULL. The only conversion from `SQLBindValue`.
nonisolated func untypedTextBindings(_ binds: [SQLBindValue]) -> PostgresBindings {
  var bindings = PostgresBindings(capacity: binds.count)
  for bind in binds {
    switch bind {
    case .text(let value):
      bindings.append(UntypedText(value))
    case .null:
      bindings.appendNull()
    }
  }
  return bindings
}

extension DatabaseConnectionManager {
  /// Resolve `tableName` (`table` or `schema.table`, bound and resolved with `to_regclass` like
  /// the query did via search_path) to its OID, server-qualified name, columns and primary key.
  /// nil if not editable: not a plain (`r`) or partitioned (`p`) table, a plain table with
  /// inheritance children (`relhassubclass`: a SELECT of the parent also returns child rows and
  /// the primary key is not unique across them), or the connection changed during the lookup.
  /// Throws `DatabaseError.metadataPausedDuringTransaction` while the app transaction is
  /// pending (results produced inside it use `cachedEditTable`). A resolved table is cached.
  func fetchEditTable(tableName: String) async throws -> EditTable? {
    try await fetchEditTable(named: tableName)
  }

  /// Same lookup as `fetchEditTable(tableName:)`. A SQLite `tableID` supplies the real schema
  /// and table: unquoted names in the SQL text are folded to uppercase by the tokenizer, and
  /// SQLite's catalog match is case-sensitive.
  func fetchEditTable(tableName: String, tableID: TableRef) async throws -> EditTable? {
    let named: String
    if let parts = tableID.sqliteComponents {
      named = "\(parts.schema).\(parts.table)"
    } else {
      named = tableName
    }
    return try await fetchEditTable(named: named)
  }

  private func fetchEditTable(named tableName: String) async throws -> EditTable? {
    let epoch = connectionEpoch
    guard
      var table = try await withCatalogSession({ session in
        try await self.introspector.editTable(named: tableName, in: session)
      }),
      epoch == connectionEpoch
    else { return nil }
    table.connectionEpoch = epoch
    editTableCache[table.resolvedTableRef] = table
    return table
  }

  /// The edit table stored under `tableID` before the pending app transaction, for results read
  /// inside it (no catalog query can be sent there). nil unless the app transaction is pending
  /// (`.appTx`), the table was resolved on the current connection, and no statement that may
  /// change the schema ran since (`ProtectedTransactionRules.invalidatesEditTables` clears the
  /// cache). Column origins still come from the result's RowDescription and are checked
  /// against it (`CellUpdateStatement.editablePrimaryKey`).
  func cachedEditTable(id tableID: TableRef) -> EditTable? {
    guard case .appTx = txState, let table = editTableCache[tableID],
      table.connectionEpoch == connectionEpoch
    else { return nil }
    return table
  }
}

/// A text-format parameter with an unspecified type (OID 0): PostgreSQL resolves the type from
/// the statement (`SET col = $1`, `pk = $2`), so no type name is ever spliced into the SQL.
private nonisolated struct UntypedText: PostgresDynamicTypeEncodable {
  let text: String
  init(_ text: String) { self.text = text }

  var psqlType: PostgresDataType { .null }  // OID 0 = unspecified
  var psqlFormat: PostgresFormat { .text }

  func encode<JSONEncoder: PostgresJSONEncoder>(
    into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
  ) {
    byteBuffer.writeString(text)
  }
}
