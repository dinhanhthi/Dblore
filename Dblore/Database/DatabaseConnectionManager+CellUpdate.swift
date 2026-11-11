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
  /// PostgreSQL: a view the v1 rule accepts gives its own edit table (`viewEditTable`).
  /// Throws `DatabaseError.metadataPausedDuringTransaction` while the app transaction is
  /// pending (results produced inside it use `cachedEditTable`). A resolved table is cached.
  /// `probesViews` false (a read that shown results wait for): a view whose map is not cached
  /// is not editable, and no side connection is opened for its probe.
  func fetchEditTable(tableName: String, probesViews: Bool = true) async throws -> EditTable? {
    try await fetchEditTable(named: tableName, probesViews: probesViews)
  }

  /// Same lookup as `fetchEditTable(tableName:)`. A SQLite `tableID` supplies the real schema
  /// and table: unquoted names in the SQL text are folded to uppercase by the tokenizer, and
  /// SQLite's catalog match is case-sensitive. A MySQL `tableID` supplies the exact names its
  /// origins were resolved with (`mysqlTableColumns`); only the connected database is editable,
  /// and a table that resolves to another identity is not editable.
  func fetchEditTable(
    tableName: String, tableID: TableRef, probesViews: Bool = true
  ) async throws -> EditTable? {
    let named: String
    if let parts = tableID.sqliteComponents {
      named = "\(parts.schema).\(parts.table)"
    } else if config?.databaseType == .mysql {
      guard let names = mysqlTableColumns[tableID], names.database == config?.database else {
        return nil
      }
      let table = try await fetchEditTable(named: names.table, probesViews: probesViews)
      return table?.resolvedTableRef == tableID ? table : nil
    } else {
      named = tableName
    }
    return try await fetchEditTable(named: named, probesViews: probesViews)
  }

  /// Whether `relation` (`CellUpdateStatement.singleRelation` text) names the table of
  /// `tableID`. Always true for engines whose origin identity is the table the server read.
  /// MySQL: the identity comes from the column definition, and MariaDB reports a view's
  /// columns with the BASE table's database and the VIEW's name, so a view in another
  /// database can name a same-named base table of the connected one. The table part must
  /// equal the identity's table, and the database part (or the current database, `USE` may
  /// have changed it) its database. Backticked parts compare exactly, unquoted ones without
  /// ASCII case (the tokenizer uppercases words). Fails closed.
  func relationNamesTable(_ relation: String, tableID: TableRef) async -> Bool {
    guard config?.databaseType == .mysql else { return true }
    guard let names = mysqlTableColumns[tableID] else { return false }
    let tokens = SQLTokenizer.tokens(relation, dialect: .mysql)
    func matches(_ token: SQLToken, _ name: String) -> Bool {
      switch token.kind {
      case .quotedIdentifier:
        return Array(token.text.unicodeScalars) == Array(name.unicodeScalars)
      case .word:
        let folded = SQLTokenizer.asciiUppercased(name)
        return Array(token.text.unicodeScalars) == Array(folded.unicodeScalars)
      default:
        return false
      }
    }
    switch tokens.count {
    case 1:
      guard matches(tokens[0], names.table) else { return false }
      let current = try? await withSession { session in
        var database: String?
        for try await row in try await session.query("SELECT DATABASE()", binds: []).rows {
          if case .string(let name) = row.first { database = name }
        }
        return database
      }
      guard let current else { return false }
      return Array(current.unicodeScalars) == Array(names.database.unicodeScalars)
    case 3:
      return tokens[1].isSymbol(".") && matches(tokens[0], names.database)
        && matches(tokens[2], names.table)
    default:
      return false
    }
  }

  private func fetchEditTable(
    named tableName: String, probesViews: Bool
  ) async throws -> EditTable? {
    let epoch = connectionEpoch
    await catalogReadHook?()
    let postgres = config?.databaseType == .postgresql
    let flavor = config?.flavor
    let (found, candidate) = try await withCatalogSession {
      session -> (EditTable?, ViewEditCandidate?) in
      if let table = try await self.introspector.editTable(named: tableName, in: session) {
        return (table, nil)
      }
      guard postgres else { return (nil, nil) }
      let candidate = try await PostgresSchemaIntrospector(flavor: flavor).viewEditCandidate(
        named: tableName, in: session)
      return (nil, candidate)
    }
    guard epoch == connectionEpoch else { return nil }
    guard var table = found else {
      guard let candidate else { return nil }
      return try await viewEditTable(candidate, epoch: epoch, probes: probesViews)
    }
    table.connectionEpoch = epoch
    editTableCache[table.resolvedTableRef] = table
    return table
  }

  /// The edit table of the view `candidate` (`viewEditCandidate`, read just now on the catalog
  /// session). Its column map to the base table is probed once per view OID and kept in
  /// `editTableCache` (a refusal too, as `EditTable.refusedView`) until the cache is cleared;
  /// a cached map is used while the catalog still shows the same columns, base table, key and
  /// view definition (`ViewBaseMap.matches`). Without a cached map, nil and no probe when
  /// `probes` is false (a visible page never waits on a side connection). A probe that failed for a passing reason (a failed connect, a lost
  /// connection, `probeRefusalIsLasting` false) is thrown again, without a probe, for
  /// `viewProbeRetryDelay` on the same connection and view definition. Lookups of a view whose
  /// probe is running join it (`probeViewEditTable`), so it opens one side connection.
  private func viewEditTable(
    _ candidate: ViewEditCandidate, epoch: UInt64, probes: Bool
  ) async throws -> EditTable? {
    let id = TableRef.postgresql(oid: candidate.viewOID)
    if let cached = editTableCache[id], cached.connectionEpoch == epoch,
      cached.attributeNames == candidate.columns, let map = cached.viewBase,
      map.matches(candidate)
    {
      return cached.isRefusedView
        ? nil : EditTable.view(candidate, map: map, connectionEpoch: epoch)
    }
    guard probes else { return nil }
    let key = ViewProbeKey(
      viewOID: candidate.viewOID, definitionVersion: candidate.definitionVersion,
      connectionEpoch: epoch)
    if let failure = viewProbeFailures[key],
      now().timeIntervalSince(failure.at) < Self.viewProbeRetryDelay
    {
      throw failure.error
    }
    if let running = viewProbesInFlight[key] { return try await running.value }
    let probe = Task { try await self.probeViewEditTable(candidate, key: key) }
    viewProbesInFlight[key] = probe
    defer { viewProbesInFlight[key] = nil }
    return try await probe.value
  }

  /// How long a view probe that failed for a passing reason is not tried again, in seconds
  nonisolated static let viewProbeRetryDelay: TimeInterval = 30

  /// Probes the view `candidate` and caches the outcome (`viewEditTable`). The probe reads
  /// `pg_get_viewdef` and the body's column origins on one side connection opened like this one
  /// (`makeSnapshotSideManager`), never on this session, and closed on every path. A probe the
  /// server refuses (`probeRefusalIsLasting`, e.g. no privilege on the base table) is cached as
  /// a refusal; a failed connect or a passing error is thrown and kept in `viewProbeFailures`.
  /// Runs as its own task, shared by every lookup that joins it: a caller's Cancel does not stop
  /// it (the probe's `statement_timeout` and `lock_timeout` bound it).
  private func probeViewEditTable(
    _ candidate: ViewEditCandidate, key: ViewProbeKey
  ) async throws -> EditTable? {
    let id = TableRef.postgresql(oid: candidate.viewOID)
    let epoch = key.connectionEpoch
    let side = makeSnapshotSideManager()
    let origins: [ColumnOrigin?]
    do {
      try await connectSideManager(side)
    } catch {
      await side.disconnect()
      await AppLogger.shared.debug(
        "View \(candidate.viewOID) probe connection failed: \(type(of: error))",
        category: "Database")
      recordViewProbeFailure(key, error)
      throw error
    }
    do {
      origins = try await side.viewBodyColumnOrigins(viewOID: candidate.viewOID)
      await side.disconnect()
    } catch {
      await side.disconnect()
      // The SQLSTATE or the error type only: a server message can quote catalog data
      let sqlState = Self.serverSQLState(error)
      let reason = sqlState.map { "SQLSTATE \($0)" } ?? "\(type(of: error))"
      await AppLogger.shared.debug(
        "View \(candidate.viewOID) probe failed: \(reason)", category: "Database")
      guard let sqlState, Self.probeRefusalIsLasting(sqlState: sqlState) else {
        recordViewProbeFailure(key, error)
        throw error
      }
      guard epoch == connectionEpoch else { return nil }
      editTableCache[id] = EditTable.refusedView(candidate, connectionEpoch: epoch)
      return nil
    }
    guard epoch == connectionEpoch else { return nil }
    let originsText = origins.map { origin in
      origin.map { "\($0.tableID.identity)#\($0.columnOrdinal)" } ?? "-"
    }.joined(separator: ", ")
    let table: EditTable?
    do {
      let map = try ViewBaseMap.make(candidate, origins: origins)
      table = EditTable.view(candidate, map: map, connectionEpoch: epoch)
      let keys = zip(map.primaryKeyColumns, map.basePrimaryKey).map { "\($0)=\($1)" }
      await AppLogger.shared.debug(
        "View \(candidate.viewOID) origins [\(originsText)], base \(candidate.baseOID) key "
          + "[\(keys.joined(separator: ", "))]: "
          + (table == nil ? "not editable, a key column is not updatable" : "editable"),
        category: "Database")
    } catch {
      table = nil
      await AppLogger.shared.debug(
        "View \(candidate.viewOID) origins [\(originsText)]: not editable, \(error.reason)",
        category: "Database")
    }
    editTableCache[id] = table ?? EditTable.refusedView(candidate, connectionEpoch: epoch)
    return table
  }

  /// Keeps a passing probe failure for `viewProbeRetryDelay` (never a cancellation), dropping
  /// the expired ones
  private func recordViewProbeFailure(_ key: ViewProbeKey, _ error: any Error) {
    guard !(error is CancellationError) else { return }
    let time = now()
    viewProbeFailures = viewProbeFailures.filter {
      time.timeIntervalSince($0.value.at) < Self.viewProbeRetryDelay
    }
    viewProbeFailures[key] = (time, error)
  }

  /// Whether a server error of a view body's probe refuses the view until the cache is cleared:
  /// any SQLSTATE but a passing one, i.e. not connection (08), rollback (40), resources (53),
  /// object state and lock timeout (55), cancel and statement timeout (57), system (58) or
  /// internal (XX) errors.
  nonisolated static func probeRefusalIsLasting(sqlState: String) -> Bool {
    !["08", "40", "53", "55", "57", "58", "XX"].contains(String(sqlState.prefix(2)))
  }

  /// `columnOrigins(ofViewBody:)` of the view `viewOID`'s `pg_get_viewdef`, both on this
  /// single-use side manager's session. A view gone meanwhile has no body: not editable.
  private func viewBodyColumnOrigins(viewOID: UInt32) async throws -> [ColumnOrigin?] {
    try await withSession { session in
      var body: String?
      let source = try await session.query(
        PostgresSchemaIntrospector.viewDefinitionSQL, binds: [.text(String(viewOID))])
      for try await row in source.rows {
        body = row.first.flatMap(CatalogValue.string)
      }
      guard let body else { throw DatabaseError.notEditable("the view has no definition") }
      return try await session.columnOrigins(ofViewBody: body)
    }
  }

  /// The edit table last resolved under `tableID`, with no catalog query: for results read
  /// inside the pending app transaction (no catalog query can be sent there), and for the target
  /// a result shows at once outside it, which the app checks against the catalog in the
  /// background before any edit is sent (DDL from another client is not seen by the clears).
  /// nil unless the table was resolved on the current connection and nothing this manager ran
  /// since may have changed the schema (a schema change, a restore,
  /// `ProtectedTransactionRules.invalidatesEditTables` and disconnect clear the cache). Column
  /// origins still come from the result's RowDescription and are checked against it
  /// (`CellUpdateStatement.editablePrimaryKey`). A view refused after its probe gives nil.
  func cachedEditTable(id tableID: TableRef) -> EditTable? {
    guard let table = editTableCache[tableID], table.connectionEpoch == connectionEpoch,
      !table.isRefusedView
    else { return nil }
    return table
  }
}

extension DatabaseConnectionManager {
  /// Test hook (see `catalogReadHook`): lets a test hold the edit-table catalog read. Nil in
  /// the app.
  func setCatalogReadHook(_ hook: (@Sendable () async -> Void)?) {
    catalogReadHook = hook
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
