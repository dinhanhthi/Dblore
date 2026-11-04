// PostgresSearchPathIntegrationTests.swift
// Security: the app's PostgreSQL catalog and metadata reads never call a function, operator or
// relation another role planted on the user's search_path. Each case gets its own database and
// login role; functions, operators, aggregates and a pg_class view that record each call in a
// `hits` table are planted, then the app's real session and manager APIs run a schema load, a
// structure load, a column-type enrichment, the enum and Copy Objects reads, the staged-key
// lookup, the Copy Objects identity restart, the restore drop-target probe and a Cancel (side
// connection, which re-runs the session-open read). Nothing may be recorded.
// Case A: the role's search_path puts the planted schema before pg_catalog. Case B: the
// default search_path, the objects planted in public (which PUBLIC can create in on
// PostgreSQL 14 and older). Against the docker test database as its superuser (CI).

import Foundation
import Testing

@testable import Dblore

@Suite(
  "PostgreSQL catalog reads ignore planted search_path objects (Requires PostgreSQL)",
  .requiresPostgres, .serialized)
@MainActor
struct PostgresSearchPathIntegrationTests {
  enum Plant: String, CustomStringConvertible, CaseIterable, Sendable {
    /// `search_path = <planted>, pg_catalog, public` plus a planted pg_class
    case schemaBeforeCatalog
    /// The default search_path, the objects planted in public
    case defaultPathPublic

    var description: String { rawValue }
  }

  private static let app = "qa_sp_app"
  private static let open = ProtectionPolicy(protectionLevel: .none)

  private static func config(
    database: String, username: String = TestDatabase.username,
    password: String = TestDatabase.password
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: database, username: username,
      password: password, sslMode: .disable, timeoutSeconds: 30, safeMode: .silent,
      protectedMode: false)
  }

  /// The user's tables, created before any trap is planted
  private static let appSetup = [
    "CREATE SCHEMA \(app)",
    "CREATE TYPE \(app).mood AS ENUM ('ok', 'bad')",
    """
    CREATE TABLE \(app).orders (id integer PRIMARY KEY, seq serial, amount numeric(10,2),
      mood \(app).mood, doubled integer GENERATED ALWAYS AS (id * 2) STORED)
    """,
    "COMMENT ON TABLE \(app).orders IS 'orders'",
    "INSERT INTO \(app).orders (id, amount, mood) VALUES (1, 2.50, 'ok')",
  ]

  /// Functions, operators and aggregates that record a call in `<schema>.hits` and answer as
  /// the pg_catalog ones do. Their own bodies run with a pinned path, so they never call each
  /// other. Each one has a bait in `baits`.
  private static func traps(in schema: String, role: String) -> [String] {
    func recorder(
      _ name: String, _ arguments: String, returns: String, _ label: String, _ body: String
    )
      -> String
    {
      """
      CREATE FUNCTION \(schema).\(name)(\(arguments)) RETURNS \(returns) LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $$ BEGIN INSERT INTO \(schema).hits (what) VALUES ('\(label)'); \(body) END $$
      """
    }
    /// `left symbol right`, recorded as `symbol(left, right)`; `name` names its function
    func binary(
      _ symbol: String, _ name: String, _ left: String, _ right: String,
      returns: String = "boolean"
    ) -> [String] {
      [
        recorder(
          "trap_\(name)", "\(left), \(right)", returns: returns, "\(symbol)(\(left), \(right))",
          "RETURN $1 \(symbol) $2;"),
        "CREATE OPERATOR \(schema).\(symbol) (LEFTARG = \(left), RIGHTARG = \(right), "
          + "FUNCTION = \(schema).trap_\(name))",
      ]
    }
    var statements = [
      "CREATE TABLE \(schema).hits (what text NOT NULL)",
      "GRANT INSERT, SELECT ON \(schema).hits TO \(role)",
      """
      CREATE FUNCTION \(schema).dblore_hit(what text) RETURNS boolean LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $$ BEGIN INSERT INTO \(schema).hits (what) VALUES (what); RETURN true; END $$
      """,
      recorder(
        "obj_description", "oid, text", returns: "text", "obj_description(oid, text)",
        "RETURN NULL;"),
      recorder(
        "left", "text, integer", returns: "text", "left(text, integer)",
        "RETURN pg_catalog.left($1, $2);"),
      recorder(
        "length", "text", returns: "integer", "length(text)", "RETURN pg_catalog.length($1);"),
      recorder(
        "current_schema", "", returns: "name", "current_schema()",
        "RETURN pg_catalog.current_schema();"),
      recorder(
        "current_setting", "text", returns: "text", "current_setting(text)",
        "RETURN pg_catalog.current_setting($1);"),
      recorder(
        "pg_backend_pid", "", returns: "integer", "pg_backend_pid()",
        "RETURN pg_catalog.pg_backend_pid();"),
      recorder(
        "pg_get_serial_sequence", "text, text", returns: "text",
        "pg_get_serial_sequence(text, text)",
        "RETURN pg_catalog.pg_get_serial_sequence($1, $2);"),
      // pg_catalog's takes a regclass: a text argument (the old restart's) prefers this one
      recorder(
        "setval", "text, bigint, boolean", returns: "bigint", "setval(text, bigint, boolean)",
        "RETURN pg_catalog.setval($1::pg_catalog.regclass, $2, $3);"),
      // Aggregates record once per row they fold. Every column this test MAXes is an integer,
      // so max(bigint) is not planted.
      recorder(
        "trap_max_int4", "integer, integer", returns: "integer", "max(integer)",
        "RETURN GREATEST($1, $2);"),
      "CREATE AGGREGATE \(schema).max(integer) (SFUNC = \(schema).trap_max_int4, STYPE = integer)",
      recorder("trap_count", "bigint", returns: "bigint", "count(*)", "RETURN $1 + 1;"),
      "CREATE AGGREGATE \(schema).count(*) (SFUNC = \(schema).trap_count, STYPE = bigint, "
        + "INITCOND = '0')",
    ]
    statements += binary("<", "lt_real_int", "real", "integer")
    statements += binary("=", "eq_text", "text", "text")
    statements += binary("=", "eq_oid", "oid", "oid")
    statements += binary("=", "eq_name", "name", "name")
    statements += binary("=", "eq_char", "\"char\"", "\"char\"")
    statements += binary("=", "eq_int4", "integer", "integer")
    statements += binary(">", "gt_int2_int4", "smallint", "integer")
    statements += binary("<>", "ne_name", "name", "name")
    statements += binary("<>", "ne_name_text", "name", "text")
    statements += binary("<>", "ne_text", "text", "text")
    statements += binary("+", "plus_int8_int4", "bigint", "integer", returns: "bigint")
    statements += binary("->>", "jsonb_text", "jsonb", "text", returns: "text")
    return statements
  }

  /// Deliberately unqualified SQL, one call per planted family, typed so each resolves to one
  /// signature. Run by the victim before the app's reads: the traps must be reachable.
  private static let baits = [
    "SELECT obj_description(c.oid, 'pg_class') FROM pg_catalog.pg_class c LIMIT 1",
    "SELECT pg_catalog.count(*) FROM pg_catalog.pg_class c WHERE c.reltuples < 0",
    // The planted pg_class and =(name, name), both called for the matching row
    "SELECT 1 FROM pg_class c WHERE c.relname = 'pg_class'",
    """
    SELECT 'r'::pg_catalog."char" = 'r'::pg_catalog."char", 1 = 1, 1::pg_catalog.int2 > 0,
      'a'::pg_catalog.name <> 'b'::pg_catalog.name, 'a'::pg_catalog.name <> 'b'::pg_catalog.text,
      'a'::pg_catalog.text <> 'b'::pg_catalog.text, 'a'::pg_catalog.text = 'a'::pg_catalog.text,
      0::pg_catalog.oid = 0::pg_catalog.oid, 1::pg_catalog.int8 + 1,
      '{}'::pg_catalog.jsonb ->> 'k'::pg_catalog.text, left('abc'::pg_catalog.text, 1),
      length('abc'::pg_catalog.text), current_schema(),
      current_setting('search_path'::pg_catalog.text), pg_backend_pid(),
      pg_get_serial_sequence('\(app).orders'::pg_catalog.text, 'seq'::pg_catalog.text),
      setval('\(app).orders_seq_seq'::pg_catalog.text, 1, true)
    """,
    "SELECT max(id), count(*) FROM \(app).orders",
  ]

  /// What `baits` must record. Case A: every trap (the planted schema comes first, so a
  /// same-signature trap wins). Case B: pg_catalog is searched first by default, so a trap with
  /// pg_catalog's exact signature can never win from public; only the cross-type ones (no
  /// pg_catalog twin: `<(real, integer)`, `obj_description(oid, text)` where pg_catalog takes a
  /// name, `setval(text, ...)` where it takes a regclass) are meaningful there.
  private static func baitHits(_ plant: Plant) -> [String] {
    let crossType = [
      "obj_description(oid, text)", "<(real, integer)", "setval(text, bigint, boolean)",
    ]
    guard plant == .schemaBeforeCatalog else { return crossType }
    return crossType + [
      "pg_class", "=(name, name)", "=(text, text)", "=(oid, oid)", #"=("char", "char")"#,
      "=(integer, integer)", ">(smallint, integer)", "<>(name, name)", "<>(name, text)",
      "<>(text, text)", "+(bigint, integer)", "->>(jsonb, text)", "left(text, integer)",
      "length(text)", "current_schema()", "current_setting(text)", "pg_backend_pid()",
      "pg_get_serial_sequence(text, text)", "max(integer)", "count(*)",
    ]
  }

  @Test(
    "No planted function, operator or relation runs during the app's reads and Cancel",
    .timeLimit(.minutes(3)), arguments: Plant.allCases)
  func plantedObjectsNeverRun(_ plant: Plant) async throws {
    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
      .lowercased()
    let database = "qa_sp_db_\(suffix)"
    let role = "qa_sp_role_\(suffix)"
    let password = "sp_\(suffix)"
    let schema = plant == .schemaBeforeCatalog ? "qa_sp_evil" : "public"

    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.config(database: TestDatabase.database))
    let planter = DatabaseConnectionManager()
    let victim = DatabaseConnectionManager()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(database)")
      _ = try await admin.executeInternal("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'")

      try await planter.connect(config: Self.config(database: database))
      for sql in Self.appSetup {
        _ = try await planter.executeInternal(sql)
      }
      for sql in [
        "GRANT USAGE ON SCHEMA \(Self.app) TO \(role)",
        "GRANT SELECT ON ALL TABLES IN SCHEMA \(Self.app) TO \(role)",
        // The identity restart's (and its bait's) setval
        "GRANT UPDATE ON ALL SEQUENCES IN SCHEMA \(Self.app) TO \(role)",
      ] {
        _ = try await planter.executeInternal(sql)
      }
      if plant == .schemaBeforeCatalog {
        for sql in [
          "CREATE SCHEMA \(schema)",
          "GRANT USAGE ON SCHEMA \(schema) TO \(role)",
          "ALTER ROLE \(role) SET search_path = \(schema), pg_catalog, public",
        ] {
          _ = try await planter.executeInternal(sql)
        }
      }
      for sql in Self.traps(in: schema, role: role) {
        _ = try await planter.executeInternal(sql)
      }
      if plant == .schemaBeforeCatalog {
        // An unqualified pg_class (or a 'pg_class'::regclass literal) would name this view; a
        // scan of it records a hit. The regclass rule of the lint test guards the literal.
        for sql in [
          """
          CREATE VIEW \(schema).pg_class AS SELECT c.* FROM pg_catalog.pg_class c
          WHERE \(schema).dblore_hit('pg_class')
          """,
          "GRANT SELECT ON \(schema).pg_class TO \(role)",
        ] {
          _ = try await planter.executeInternal(sql)
        }
      }

      // Opening the session runs the extension-type and session-identity reads
      try await victim.connect(
        config: Self.config(database: database, username: role, password: password))
      #expect(try await hits(schema, planter) == [], "session open")

      // Control: unqualified SQL does reach every trap that can fire in this case (else the
      // case proves nothing, e.g. without USAGE on the planted schema)
      for sql in Self.baits {
        _ = try await victim.executeInternal(sql)
      }
      let control = try await hits(schema, planter)
      let missed = Self.baitHits(plant).filter { !control.contains($0) }
      #expect(missed.isEmpty, "control missed \(missed): \(control)")
      _ = try await planter.executeInternal("DELETE FROM \(schema).hits")

      try await runAppReads(victim)
      #expect(try await hits(schema, planter) == [], "catalog reads")

      try await runRestartAndDropProbe(victim)
      #expect(try await hits(schema, planter) == [], "identity restart and drop-target probe")

      try await cancelSleep(victim, role: role, observer: admin)
      #expect(try await hits(schema, planter) == [], "cancel")
    } catch {
      Issue.record(error)
    }
    await victim.disconnect()
    await planter.disconnect()
    _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database) WITH (FORCE)")
    _ = try? await admin.executeInternal("DROP ROLE IF EXISTS \(role)")
    await admin.disconnect()
  }

  /// What the traps recorded (in no set order)
  private func hits(
    _ schema: String, _ planter: DatabaseConnectionManager
  ) async throws
    -> [String]
  {
    try await planter.executeInternal("SELECT what FROM \(schema).hits").rows.compactMap {
      if case .string(let what)? = $0.first { return what }
      return nil
    }
  }

  /// The schema browser's reads, the structure editor's, a column-type enrichment, the enum and
  /// Copy Objects reads and the staged-key lookup, each checked for a real answer
  private func runAppReads(_ manager: DatabaseConnectionManager) async throws {
    let app = Self.app
    let tables = try await manager.fetchTables()
    #expect(tables.contains { $0.schema == app && $0.name == "orders" })
    let columns = try await manager.fetchAllColumns()
    #expect(columns.contains { $0.key.hasSuffix("orders") && $0.value.count == 5 })
    _ = try await manager.fetchViews()
    _ = try await manager.fetchFunctions()
    _ = try await manager.fetchProcedures()
    _ = try await manager.fetchTriggers()
    _ = try await manager.fetchSequences()
    _ = try await manager.fetchUserTypes()
    _ = try await manager.fetchForeignKeys()
    _ = try await manager.fetchUsers()
    _ = try await manager.fetchRoles()
    #expect(try await manager.fetchRowCount(tableSchema: app, tableName: "orders") == 1)
    #expect(try await manager.fetchPrimaryKeyColumns(tableName: "\(app).orders") == ["id"])

    let structure = try await manager.fetchTableStructure(schema: app, table: "orders")
    #expect(structure.columns.map(\.name) == ["id", "seq", "amount", "mood", "doubled"])
    #expect(structure.comment == "orders")

    let query = "SELECT id, amount FROM \(app).orders"
    let result = try await manager.executeInternal(query)
    let enriched = await manager.enrichColumnTypes(columns: result.columns, query: query)
    #expect(enriched.map(\.type).last == "NUMERIC(10,2)", "\(enriched.map(\.type))")

    #expect(try await manager.readGenerateRowsEnumLabels(structure) == ["mood": ["ok", "bad"]])
    _ = try await manager.copyTargetNames()

    // No default, a serial default, a generated column (no default, as information_schema says)
    for (column, hasDefault) in [("id", false), ("seq", true), ("doubled", false)] {
      let sql = try #require(
        StagedIntegerKey.lookupSQL(
          schema: app, table: "orders", column: column, dialect: .postgresql))
      let row = try await manager.executeInternal(sql, maxRows: 1).rows.first
      let lookup = StagedIntegerKey.parseLookup(row)
      #expect(lookup?.hasDefault == hasDefault, "\(column): \(String(describing: row))")
      #expect(lookup?.serverMax == (column == "doubled" ? 2 : 1), "\(column)")
    }
  }

  /// Statements run on a session that is not a catalog read: Copy Objects' identity restart
  /// (after the copied rows) and the restore's drop-target probe, each checked for a real answer
  private func runRestartAndDropProbe(_ manager: DatabaseConnectionManager) async throws {
    let app = Self.app
    let copy = CopyObjectsPlan(
      source: .postgresql, target: .postgresql, targetSchema: app, tables: [],
      indexStatements: [], foreignKeyStatements: [],
      identityColumns: [.init(table: "orders", column: "seq")], warnings: [])
    let restart = try #require(try copy.identityRestartStatements().first)
    // max(seq) is 1, so the sequence continues at 2
    #expect(try await manager.executeInternal(restart).rows.first?.first == .int(2), "restart")

    let drops = SQLRestorePlan.PostgresDrops(
      tables: [[Array(app.utf8), Array("orders".utf8)]],
      types: [[Array(app.utf8), Array("mood".utf8)]], createdSequences: [])
    let rows = try await manager.executeInternal(
      DatabaseConnectionManager.postgresDropTargetsQuery(drops)
    ).rows
    let owns: [CellValue] = [
      .string("owns"), .string(app), .string("orders"), .string(app), .string("orders_seq_seq"),
    ]
    #expect(rows.contains(owns), "drop targets: \(rows)")
  }

  /// A running pg_sleep cancelled from the side connection: the same backend answers after it
  /// (the side cancel matched, no reconnect)
  private func cancelSleep(
    _ manager: DatabaseConnectionManager, role: String, observer: DatabaseConnectionManager
  ) async throws {
    let pid = try await manager.executeInternal("SELECT pg_catalog.pg_backend_pid()").rows.first?
      .first
    let policy = Self.open
    let running = Task {
      await bounded(.seconds(15)) {
        _ = try await manager.execute(userSQL: "SELECT pg_sleep(30)", policy: policy)
      }
    }
    let active = """
      SELECT count(*) FROM pg_stat_activity WHERE usename = '\(role)' AND state = 'active'
        AND query LIKE 'SELECT pg_sleep(30)%'
      """
    let deadline = ContinuousClock.now + .seconds(10)
    var started = false
    while !started, ContinuousClock.now < deadline {
      let count = try await observer.executeInternal(active).rows.first?.first
      started = count == .int(1)
      if !started { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(started, "pg_sleep never ran")
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    _ = await running.value
    let after = try await manager.executeInternal("SELECT pg_catalog.pg_backend_pid()").rows.first?
      .first
    #expect(after == pid, "the cancel reconnected instead of cancelling on the server")
  }
}
