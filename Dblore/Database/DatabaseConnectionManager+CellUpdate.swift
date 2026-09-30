//
//  DatabaseConnectionManager+CellUpdate.swift
//  Dblore
//
//  Inline grid edit: primary-key-only UPDATE with bind parameters. Sent through
//  `executeGatedUpdate(_:policy:connectionEpoch:)` in +Gate.
//

import Foundation
import Logging
import NIOCore
import PostgresNIO

nonisolated extension CellUpdateStatement {
  /// Bind parameters: untyped text (the server infers each parameter's type from the column,
  /// like libpq's `PQexecParams` without `paramTypes`), NULL for nil.
  var bindings: PostgresBindings { untypedTextBindings(values) }
}

nonisolated extension BoundStatement {
  /// Bind parameters: untyped text, NULL for nil. Same encoding as `CellUpdateStatement`.
  var bindings: PostgresBindings { untypedTextBindings(values) }
}

/// Untyped text binds. Nil is SQL NULL. File-private so both statement types share `UntypedText`.
private nonisolated func untypedTextBindings(_ values: [String?]) -> PostgresBindings {
  var bindings = PostgresBindings(capacity: values.count)
  for value in values {
    if let value {
      bindings.append(UntypedText(value))
    } else {
      bindings.appendNull()
    }
  }
  return bindings
}

extension ColumnInfo {
  /// Column metadata with its source table OID / attribute number from the RowDescription
  nonisolated init(name: String, type: String, origin: PostgresColumn?) {
    self.init(
      name: name, type: type, tableOID: origin.map { UInt32(bitPattern: $0.tableOID) },
      attributeNumber: origin?.columnAttributeNumber)
  }
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
    let connection = try catalogConnection()
    let epoch = connectionEpoch
    var binds = PostgresBindings(capacity: 1)
    binds.append(tableName)
    let query = PostgresQuery(
      unsafeSQL: """
        SELECT c.oid::int8, a.attnum::int4, a.attname::text,
               COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(att, ord)
                         WHERE k.att = a.attnum), 0)::int4,
               format('%I.%I', n.nspname, c.relname), c.relkind::text, c.relhassubclass
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
        WHERE c.oid = to_regclass($1)
        """, binds: binds)
    var oid: UInt32 = 0
    var qualifiedName = ""
    var names: [Int16: String] = [:]
    var keyPositions: [(position: Int32, name: String)] = []
    var relationKind = ""
    var hasSubclass = true
    let rows = try await send(on: connection) {
      try await $0.query(query, logger: Logger(label: "dblore.edit"))
    }
    for try await (tableOID, attnum, name, keyPosition, qualified, kind, subclass) in rows.decode(
      (Int64, Int32, String, Int32, String, String, Bool).self)
    {
      guard let number = Int16(exactly: attnum), let tableID = UInt32(exactly: tableOID) else {
        continue
      }
      oid = tableID
      qualifiedName = qualified
      relationKind = kind
      hasSubclass = subclass
      names[number] = name
      if keyPosition > 0 { keyPositions.append((keyPosition, name)) }
    }
    guard oid != 0, epoch == connectionEpoch,
      relationKind == "p" || (relationKind == "r" && !hasSubclass)
    else { return nil }
    let primaryKey = keyPositions.sorted { $0.position < $1.position }.map(\.name)
    let table = EditTable(
      oid: oid, attributeNames: names, primaryKeyColumns: primaryKey, qualifiedName: qualifiedName,
      connectionEpoch: epoch, updateOnly: relationKind == "r")
    editTableCache[oid] = table
    return table
  }

  /// The edit table of `oid` resolved before the pending app transaction, for results read
  /// inside it (no catalog query can be sent there). nil unless the app transaction is pending
  /// (`.appTx`), the table was resolved on the current connection, and no statement that may
  /// change the schema ran since (`ProtectedTransactionRules.invalidatesEditTables` clears the
  /// cache). Column origins still come from the result's RowDescription and are checked
  /// against it (`CellUpdateStatement.editablePrimaryKey`).
  func cachedEditTable(oid: UInt32) -> EditTable? {
    guard case .appTx = txState, let table = editTableCache[oid],
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
