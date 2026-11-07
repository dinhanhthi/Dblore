// PostgresSearchPathIntegrationTests.swift
// Security: the app's PostgreSQL catalog and metadata reads never call a function, operator or
// relation another role planted on the user's search_path. Each case gets its own database and
// login role; functions, operators, aggregates and a pg_class view that record each call in a
// `hits` table are planted, then the app's real session and manager APIs run a schema load, a
// structure load, a column-type enrichment, the enum and Copy Objects reads, the staged-key
// lookup, the Copy Objects identity restart, the restore drop-target probe and a Cancel (side
// connection, which re-runs the session-open read). Nothing may be recorded. A restore case runs
// a Dblore dump (a CHECK, a DEFAULT, an index expression, a view) in the victim's open
// transaction: nothing is recorded, nothing restored depends on a planted object, and the
// victim's search_path is the same after the restore. A user-data case per path (a cell edit
// with Rewind and its undo, data viewer pages and filters, a cascade preview count, a keyed
// import, Copy Objects source reads) runs the app's statements on `public` tables with more
// operators and functions planted, and a same-named decoy of the table first on the path:
// nothing is recorded and every result comes from the real table. A type case loads columns of
// the real contrib citext, a domain over it, its array and a look-alike `evil.citext` first on the
// path: the schema and structure reads classify each one (skipped without contrib citext).
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

  /// The restore case's source: its dump prints now(), lower(text), >(integer, integer) and
  /// =(integer, integer) unqualified in a DEFAULT, an index, a CHECK and a view
  private static let restored = "qa_sp_restored"
  private static let restoreSource = [
    "CREATE SCHEMA \(restored)",
    """
    CREATE TABLE \(restored).items (id integer PRIMARY KEY, name text NOT NULL,
      qty integer NOT NULL CONSTRAINT items_qty_check CHECK (qty > 0),
      added timestamptz DEFAULT now())
    """,
    "INSERT INTO \(restored).items (id, name, qty) VALUES (1, 'A', 1)",
    "CREATE INDEX items_lower_name ON \(restored).items (lower(name))",
    "CREATE VIEW \(restored).singles AS SELECT id, lower(name) AS lname FROM \(restored).items"
      + " WHERE qty = 1",
  ]

  /// The calls of `restoreSource` that `traps` does not plant, recorded as `traps` records them
  private static func restoreTraps(in schema: String) -> [String] {
    func recorder(
      _ name: String, _ arguments: String, returns: String, _ label: String, _ body: String
    ) -> String {
      """
      CREATE FUNCTION \(schema).\(name)(\(arguments)) RETURNS \(returns) LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $$ BEGIN INSERT INTO \(schema).hits (what) VALUES ('\(label)'); \(body) END $$
      """
    }
    return [
      recorder("now", "", returns: "timestamptz", "now()", "RETURN pg_catalog.now();"),
      recorder("lower", "text", returns: "text", "lower(text)", "RETURN pg_catalog.lower($1);"),
      recorder(
        "trap_gt_int4", "integer, integer", returns: "boolean", ">(integer, integer)",
        "RETURN $1 > $2;"),
      "CREATE OPERATOR \(schema).> (LEFTARG = integer, RIGHTARG = integer, "
        + "FUNCTION = \(schema).trap_gt_int4)",
    ]
  }

  @Test(
    "A restore in the user's transaction binds no planted object and keeps their search_path",
    .timeLimit(.minutes(3)))
  func restoreIgnoresPlantedObjects() async throws {
    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
      .lowercased()
    let source = "qa_sp_src_\(suffix)"
    let database = "qa_sp_db_\(suffix)"
    let role = "qa_sp_role_\(suffix)"
    let password = "sp_\(suffix)"
    let schema = "qa_sp_evil"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sp-restore-\(suffix)", isDirectory: true)

    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.config(database: TestDatabase.database))
    let seeder = DatabaseConnectionManager()
    let planter = DatabaseConnectionManager()
    let victim = DatabaseConnectionManager()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(source)")
      _ = try await admin.executeInternal("CREATE DATABASE \(database)")
      _ = try await admin.executeInternal("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'")

      // The dump, written by the app from its own database
      try await seeder.connect(config: Self.config(database: source))
      for sql in Self.restoreSource {
        _ = try await seeder.executeInternal(sql)
      }
      await seeder.disconnect()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("dump.sql")
      _ = try await SQLDumpWriter(
        config: Self.config(database: source), material: nil, sshCredential: nil,
        sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
      ).write(to: file)
      let dump = try String(contentsOf: file, encoding: .utf8)

      try await planter.connect(config: Self.config(database: database))
      let setup = [
        "GRANT CREATE ON DATABASE \(database) TO \(role)",
        "CREATE SCHEMA \(schema)",
        "GRANT USAGE ON SCHEMA \(schema) TO \(role)",
        "ALTER ROLE \(role) SET search_path = \(schema), pg_catalog, public",
      ]
      for sql in setup + Self.traps(in: schema, role: role) + Self.restoreTraps(in: schema) {
        _ = try await planter.executeInternal(sql)
      }
      try await victim.connect(
        config: Self.config(database: database, username: role, password: password))

      // Control: on the victim's path the dump's unqualified calls reach the traps
      _ = try await victim.executeInternal(
        "SELECT now(), lower('A'::pg_catalog.text), 2 > 1, 1 = 1")
      let control = try await hits(schema, planter)
      let missed = ["now()", "lower(text)", ">(integer, integer)", "=(integer, integer)"]
        .filter { !control.contains($0) }
      #expect(missed.isEmpty, "control missed \(missed): \(control)")
      _ = try await planter.executeInternal("DELETE FROM \(schema).hits")

      // In the victim's own transaction: RELEASE keeps a SET LOCAL, so the put-back must run
      _ = try await victim.execute(userSQL: "BEGIN", policy: Self.open)
      let before = try await searchPath(victim)
      #expect(before == "\(schema), pg_catalog, public")
      let summary = try await victim.executeGatedRestore(
        script: dump, policy: Self.open, connectionEpoch: await victim.connectionEpoch)
      #expect(summary.insideUserTransaction)
      #expect(try await searchPath(victim) == before, "search_path after the restore")
      _ = try await victim.execute(userSQL: "COMMIT", policy: Self.open)
      #expect(try await hits(schema, planter) == [], "restore")

      // The restored DEFAULT, CHECK, index and view run (as the planter, whose own path holds
      // no trap); anything bound to a planted object would record a hit here
      let restored = Self.restored
      _ = try await planter.executeInternal(
        "INSERT INTO \(restored).items (id, name, qty) VALUES (2, 'B', 1)")
      let singles = try await planter.executeInternal("SELECT count(*) FROM \(restored).singles")
      #expect(singles.rows.first?.first == .int(2), "the restored view")
      #expect(try await hits(schema, planter) == [], "restored objects in use")
      let bound = try await planter.executeInternal(
        """
        SELECT count(*) FROM pg_depend d
        WHERE d.classid IN ('pg_class'::regclass, 'pg_attrdef'::regclass,
            'pg_constraint'::regclass, 'pg_rewrite'::regclass)
          AND ((d.refclassid = 'pg_proc'::regclass AND d.refobjid IN
              (SELECT oid FROM pg_proc WHERE pronamespace = '\(schema)'::regnamespace))
            OR (d.refclassid = 'pg_operator'::regclass AND d.refobjid IN
              (SELECT oid FROM pg_operator WHERE oprnamespace = '\(schema)'::regnamespace)))
        """)
      #expect(bound.rows.first?.first == .int(0), "objects that depend on a planted one")
    } catch {
      Issue.record(error)
    }
    await seeder.disconnect()
    await victim.disconnect()
    await planter.disconnect()
    for name in [source, database] {
      _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(name) WITH (FORCE)")
    }
    _ = try? await admin.executeInternal("DROP ROLE IF EXISTS \(role)")
    await admin.disconnect()
    try? FileManager.default.removeItem(at: directory)
  }

  /// An app path on user data, each run in its own database by `userDataIgnoresPlantedObjects`
  enum UserDataPath: String, CustomStringConvertible, CaseIterable, Sendable {
    case cellEditWithRewind
    case dataViewer
    case cascadePreview
    case keyedImport
    case copyObjectsSource

    var description: String { rawValue }
  }

  /// The user's tables in `public`: `t` (a bytea column for the lazy page), a cascading child
  /// and grandchild; read and written by `role`
  private static func userDataSetup(role: String) -> [String] {
    [
      "CREATE TABLE public.t (id integer PRIMARY KEY, name text NOT NULL, note text, body bytea)",
      #"""
      INSERT INTO public.t VALUES (1, 'a%b', 'x', '\x0102'), (2, 'B', 'y', NULL),
        (3, 'c', 'z', '\x03')
      """#,
      """
      CREATE TABLE public.child (id integer PRIMARY KEY,
        t_id integer NOT NULL REFERENCES public.t (id) ON DELETE CASCADE)
      """,
      "INSERT INTO public.child VALUES (10, 1), (11, 1), (12, 2)",
      """
      CREATE TABLE public.grandchild (id integer PRIMARY KEY,
        child_id integer NOT NULL REFERENCES public.child (id) ON DELETE CASCADE)
      """,
      "INSERT INTO public.grandchild VALUES (100, 10), (101, 12)",
      "GRANT USAGE ON SCHEMA public TO \(role)",
      "GRANT SELECT, INSERT, UPDATE ON public.t TO \(role)",
      "GRANT SELECT ON public.child, public.grandchild TO \(role)",
    ]
  }

  /// What the user-data statements call that `traps` does not plant, recorded as `traps`
  /// records them, and a decoy `t` (other ids) that records each row it is scanned for. Planted
  /// after `traps`: the decoy calls its `dblore_hit`.
  private static func userDataTraps(in schema: String, role: String) -> [String] {
    func recorder(
      _ name: String, _ arguments: String, returns: String, _ label: String, _ body: String
    ) -> String {
      """
      CREATE FUNCTION \(schema).\(name)(\(arguments)) RETURNS \(returns) LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $$ BEGIN INSERT INTO \(schema).hits (what) VALUES ('\(label)'); \(body) END $$
      """
    }
    // symbol, function name, operand type, result type
    let operators = [
      (">", "gt_int4", "integer", "boolean"), ("<", "lt_int4", "integer", "boolean"),
      ("<>", "ne_int4", "integer", "boolean"), (">", "gt_text", "text", "boolean"),
      ("<", "lt_text", "text", "boolean"), ("~~", "like_text", "text", "boolean"),
      ("~~*", "ilike_text", "text", "boolean"), ("||", "cat_text", "text", "text"),
    ]
    var statements: [String] = []
    for (symbol, name, type, result) in operators {
      statements += [
        recorder(
          "trap_\(name)", "\(type), \(type)", returns: result, "\(symbol)(\(type), \(type))",
          "RETURN $1 \(symbol) $2;"),
        "CREATE OPERATOR \(schema).\(symbol) (LEFTARG = \(type), RIGHTARG = \(type), "
          + "FUNCTION = \(schema).trap_\(name))",
      ]
    }
    return statements + [
      recorder(
        "octet_length", "text", returns: "integer", "octet_length(text)",
        "RETURN pg_catalog.octet_length($1);"),
      recorder(
        "octet_length", "bytea", returns: "integer", "octet_length(bytea)",
        "RETURN pg_catalog.octet_length($1);"),
      recorder(
        "like_escape", "text, text", returns: "text", "like_escape(text, text)",
        "RETURN pg_catalog.like_escape($1, $2);"),
      """
      CREATE VIEW \(schema).t AS SELECT id + 100 AS id, name, note, body FROM public.t
      WHERE \(schema).dblore_hit('t')
      """,
      "GRANT SELECT ON \(schema).t TO \(role)",
    ]
  }

  /// Unqualified calls of every trap the user-data paths could reach, typed to one signature
  private static let userDataBaits = [
    """
    SELECT 1 = 1, 2 > 1, 1 < 2, 1 <> 2, 'a'::pg_catalog.text = 'a'::pg_catalog.text,
      'a'::pg_catalog.text <> 'b'::pg_catalog.text, 'b'::pg_catalog.text > 'a'::pg_catalog.text,
      'a'::pg_catalog.text < 'b'::pg_catalog.text, 'a'::pg_catalog.text ~~ 'a'::pg_catalog.text,
      'a'::pg_catalog.text ~~* 'A'::pg_catalog.text, 'a'::pg_catalog.text || 'b'::pg_catalog.text,
      octet_length('a'::pg_catalog.text), octet_length('\\x01'::pg_catalog.bytea),
      like_escape('a'::pg_catalog.text, '!'::pg_catalog.text)
    """,
    "SELECT count(*) FROM t",
  ]

  /// What `userDataBaits` must record
  private static let userDataBaitHits = [
    "=(integer, integer)", ">(integer, integer)", "<(integer, integer)", "<>(integer, integer)",
    "=(text, text)", "<>(text, text)", ">(text, text)", "<(text, text)", "~~(text, text)",
    "~~*(text, text)", "||(text, text)", "octet_length(text)", "octet_length(bytea)",
    "like_escape(text, text)", "count(*)", "t",
  ]

  @Test(
    "The app's statements on user data call no planted operator, function or relation",
    .timeLimit(.minutes(3)), arguments: UserDataPath.allCases)
  func userDataIgnoresPlantedObjects(_ path: UserDataPath) async throws {
    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
      .lowercased()
    let database = "qa_sp_db_\(suffix)"
    let role = "qa_sp_role_\(suffix)"
    let password = "sp_\(suffix)"
    let schema = "qa_sp_evil"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sp-data-\(suffix)", isDirectory: true)
    let victimConfig = Self.config(database: database, username: role, password: password)

    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.config(database: TestDatabase.database))
    let planter = DatabaseConnectionManager()
    let victim = DatabaseConnectionManager()
    let side = victim.makeReadOnlySideManager()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(database)")
      _ = try await admin.executeInternal("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'")

      try await planter.connect(config: Self.config(database: database))
      let plant = [
        "CREATE SCHEMA \(schema)",
        "GRANT USAGE ON SCHEMA \(schema) TO \(role)",
        "ALTER ROLE \(role) SET search_path = \(schema), pg_catalog, public",
      ]
      for sql in Self.userDataSetup(role: role) + plant + Self.traps(in: schema, role: role)
        + Self.userDataTraps(in: schema, role: role)
      {
        _ = try await planter.executeInternal(sql)
      }
      try await victim.connect(config: victimConfig)

      // Control: on the victim's path unqualified SQL reaches every trap and the decoy
      for sql in Self.userDataBaits {
        _ = try await victim.executeInternal(sql)
      }
      let control = try await hits(schema, planter)
      let missed = Self.userDataBaitHits.filter { !control.contains($0) }
      #expect(missed.isEmpty, "control missed \(missed): \(control)")
      _ = try await planter.executeInternal("DELETE FROM \(schema).hits")

      switch path {
      case .cellEditWithRewind:
        try await editWithRewind(victim, planter, schema: schema, directory: directory)
      case .dataViewer:
        try await browseDataViewer(victim, planter, schema: schema)
      case .cascadePreview:
        try await previewCascade(victim, side: side, planter, schema: schema)
      case .keyedImport:
        try await importKeyed(victim, config: victimConfig, planter, schema: schema)
      case .copyObjectsSource:
        try await readCopySource(victim, side: side, planter, schema: schema)
      }
    } catch {
      Issue.record(error)
    }
    await side.disconnect()
    await victim.disconnect()
    await planter.disconnect()
    _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database) WITH (FORCE)")
    _ = try? await admin.executeInternal("DROP ROLE IF EXISTS \(role)")
    await admin.disconnect()
    try? FileManager.default.removeItem(at: directory)
  }

  /// A cell edit made on a data viewer page with Data Rewind recording (its capture reads the
  /// row before and after), then the Rewind undo of it, both through the gate
  private func editWithRewind(
    _ victim: DatabaseConnectionManager, _ planter: DatabaseConnectionManager, schema: String,
    directory: URL
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try RewindStore(url: directory.appendingPathComponent("rewind.sqlite"))
    let recorder = RewindRecorder(store: store)
    await victim.setRewindRecorder(recorder)

    let oid = try await planter.executeInternal("SELECT 'public.t'::regclass::oid::int8").rows
    guard case .int(let number)? = oid.first?.first, let tableOID = UInt32(exactly: number) else {
      throw DatabaseError.notEditable("no oid for public.t")
    }
    let table = try #require(
      try await victim.fetchEditTable(
        tableName: #""public"."t""#, tableID: .postgresql(oid: tableOID)))
    let target = EditTarget(
      qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
      primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
      updateOnly: table.updateOnly, schema: table.schema, name: table.name,
      generatedColumns: table.generatedColumns)
    #expect(target.primaryKeyColumns == ["id"])

    let page = try await victim.execute(
      userSQL: DataViewerState(schema: "public", name: "t", orderColumns: ["id"]).pageSQL,
      policy: Self.open)
    let first = try #require(page.rows.first)
    let rowData = Dictionary(
      zip(page.columns.map(\.name), first).map { ($0, $1) }, uniquingKeysWith: { first, _ in first }
    )
    let assignments: [(column: String, value: String?)] = [(column: "note", value: "edited")]
    let statement = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, assignments: assignments,
      primaryKeyColumns: target.primaryKeyColumns, rowData: rowData,
      updateOnly: target.updateOnly, dialect: .postgresql)
    let step = try #require(
      RewindPlan.inlineStep(
        assignments: assignments, primaryKeyColumns: target.primaryKeyColumns, rowData: rowData))
    let plan = try #require(
      RewindPlan.make(
        target: target, resultColumns: page.columns, editKind: .inline, steps: [step],
        engine: .postgresql, enabled: true))
    let updated = try await victim.executeGatedUpdate(
      statement, policy: Self.open, connectionEpoch: target.connectionEpoch,
      commitImmediately: true, rewind: plan)
    #expect(updated == 1)
    #expect(try await note(of: 1, planter) == .string("edited"))
    #expect(try await hits(schema, planter) == [], "cell edit with Rewind capture")

    // The capture read the row twice: an entry that is not "not captured"
    await recorder.flushed()
    let entries = try store.entries(connectionKey: nil)
    #expect(entries.map(\.notCaptured) == [false], "the Rewind entry")
    let structure = try await victim.fetchTableStructure(schema: "public", table: "t")
    let inverse = try RewindPlanner.plan(
      try entries.map { (entry: $0, rows: try store.rows(entryID: $0.id)) },
      tables: [RewindTableName(schema: "public", table: "t"): RewindTable(structure)],
      engine: .postgresql)
    let counts = try await victim.executeGatedBatch(
      inverse.statements, policy: Self.open, connectionEpoch: await victim.connectionEpoch,
      rewinding: inverse.entryIDs)
    #expect(counts == [1])
    #expect(try await note(of: 1, planter) == .string("x"))
    #expect(try await hits(schema, planter) == [], "Rewind undo")
    await recorder.flushed()
    #expect(try store.entries(connectionKey: nil).map(\.state) == [.rewound])
  }

  /// Data viewer pages (lazy: the bytea column read as a prefix and its length) and counts,
  /// with the column types of the schema cache, unfiltered and through each kind of filter
  private func browseDataViewer(
    _ victim: DatabaseConnectionManager, _ planter: DatabaseConnectionManager, schema: String
  ) async throws {
    let table = try #require(
      try await victim.fetchTables().first { $0.schema == "public" && $0.name == "t" })
    let cached = try await victim.fetchAllColumns()[table.qualifiedName] ?? []
    #expect(cached.map(\.name) == ["id", "name", "note", "body"])
    var state = DataViewerState(schema: "public", name: "t", orderColumns: ["id"])
    state.columnTypes = Dictionary(
      cached.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
    state.lazyColumns = DataViewerState.lazyColumns(
      cached.map { ($0.name, $0.type, $0.isPrimaryKey) }, databaseType: .postgresql,
      orderColumns: state.orderColumns)
    #expect(state.lazyColumns?.contains { $0.name == "body" && $0.isPrefixed } == true)

    let filters: [(condition: FilterCondition?, ids: [Int])] = [
      (nil, [1, 2, 3]),
      (FilterCondition(column: "id", op: .equals, value: "1"), [1]),
      (FilterCondition(column: "id", op: .greaterThan, value: "1"), [2, 3]),
      (FilterCondition(column: "id", op: .in, value: "1, 3"), [1, 3]),
      (FilterCondition(column: "name", op: .notEquals, value: "c"), [1, 2]),
      (FilterCondition(column: "name", op: .like, value: "a!%%", likeEscape: "!"), [1]),
      (FilterCondition(column: "name", op: .ilike, value: "b"), [2]),
    ]
    for (condition, ids) in filters {
      state.filter = TableFilter(conditions: condition.map { [$0] } ?? [])
      let label = condition.map { "\($0.column) \($0.op.rawValue)" } ?? "no filter"
      let page = try await victim.execute(userSQL: state.pageSQL, policy: Self.open)
      #expect(page.rows.map(\.first) == ids.map { .int($0) }, "\(label): page")
      if condition == nil {
        // The length column of the prefixed bytea, last in the select list
        #expect(page.rows.map(\.last) == [.int(2), .null, .int(1)], "body lengths")
      }
      let count = try await victim.execute(userSQL: state.countSQL, policy: Self.open, maxRows: 1)
      #expect(DataViewerState.total(from: count) == ids.count, "\(label): count")
      #expect(try await hits(schema, planter) == [], "data viewer, \(label)")
    }
  }

  /// The staged delete of row 1's cascade preview: the foreign keys and counts read on the
  /// check's own read-only connection, as the confirmation computes them
  private func previewCascade(
    _ victim: DatabaseConnectionManager, side: DatabaseConnectionManager,
    _ planter: DatabaseConnectionManager, schema: String
  ) async throws {
    try await NotebookViewModel.connectSide(side, like: victim)
    let impact = CascadeImpactPlanner.impact(
      deletingFrom: "public", table: "t", keyColumns: ["id"], keys: [[.int(1)]],
      foreignKeys: try await side.fetchForeignKeys(), dialect: .postgresql)
    guard case .plan(let plan) = impact else {
      Issue.record("expected a plan, got \(impact)")
      return
    }
    #expect(!plan.steps.isEmpty)
    let summary = try await NotebookViewModel.countCascadeImpact(
      impact, connectionManager: victim, counter: side, dialect: .postgresql, caller: nil,
      expectedEpoch: nil)
    #expect(summary.note == nil, "\(summary.lines)")
    #expect(summary.blockers.isEmpty)
    #expect(
      summary.affected.map { "\($0.table) \($0.effect) \($0.count)" }.sorted() == [
        "child deleted 2", "grandchild deleted 1",
      ])
    #expect(try await hits(schema, planter) == [], "cascade preview")
  }

  /// A keyed CSV import (Insert or Update on the primary key) submitted through the tab: the
  /// match read, then the INSERT and the keyed UPDATE in the tab's batch
  private func importKeyed(
    _ victim: DatabaseConnectionManager, config: ConnectionConfig,
    _ planter: DatabaseConnectionManager, schema: String
  ) async throws {
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = victim
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sp-import-\(UUID().uuidString).csv")
    try Data("id,name\n1,A\n4,D\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let model = TableImportModel()
    await model.loadFile(file)
    model.destination = .existing(schema: "public", table: "t")
    await model.loadMatchKeys { try await victim.fetchTableStructure(schema: $0, table: $1) }
    model.matchKey = model.matchKeys.first
    #expect(model.matchKey?.columns == ["id"])
    model.mode = .insertOrUpdate

    #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
    #expect(model.matchSummary?.newRows == 1)
    #expect(model.matchSummary?.existingRows == 1)
    let rows = try await planter.executeInternal("SELECT id, name FROM public.t ORDER BY id").rows
    #expect(
      rows == [
        [.int(1), .string("A")], [.int(2), .string("B")], [.int(3), .string("c")],
        [.int(4), .string("D")],
      ])
    #expect(try await hits(schema, planter) == [], "keyed import")
  }

  /// Copy Objects' reads of `public.t` on a read-only source connection, for a PostgreSQL and
  /// a SQLite target: the count, the first page and the keyset page after it. The decoy `t`
  /// first on the path holds other ids, so a read of it would show.
  private func readCopySource(
    _ victim: DatabaseConnectionManager, side: DatabaseConnectionManager,
    _ planter: DatabaseConnectionManager, schema: String
  ) async throws {
    try await victim.connectSideManager(side)
    let structure = try await side.fetchTableStructure(schema: "public", table: "t")
    let targets: [StructureDDLBuilder.Engine] = [
      .postgresql, .sqlite(libraryVersion: SQLiteLibraryVersion.current),
    ]
    for target in targets {
      let plan = try CopyObjectsPlanner.plan(
        [.init(structure: structure)], source: .postgresql, target: target,
        targetSchema: target == .postgresql ? "qa_sp_copy" : "main", existingNames: [])
      let read = try CopyObjectsTableRead(plan.tables[0], source: .postgresql, target: target)
      #expect(read.relation == #""public"."t""#)
      #expect(!read.readsByPosition)

      let count = try await side.readCopyObjectsRows(read.countSQL, binds: [])
      #expect(count.first?.first == .int(3), "\(target): count")
      let first = read.select(after: nil, offset: 0, limit: 1)
      let firstRows = try await side.readCopyObjectsRows(first.sql, binds: first.binds)
      let row = try #require(firstRows.first)
      let key = try #require(try read.key(row))
      #expect(key == ["1"], "\(target): first page")
      let values = try read.values(row, timestamps: ImportTypeInference.TimestampParser()).values
      #expect(values.count == 4 && values[1] == .text("a%b"), "\(target): \(values)")
      let next = read.select(after: key, offset: 1, limit: 1)
      let nextRows = try await side.readCopyObjectsRows(next.sql, binds: next.binds)
      #expect(try nextRows.map { try read.key($0) } == [["2"]], "\(target): keyset page")
      #expect(try await hits(schema, planter) == [], "Copy Objects source reads, \(target)")
    }
  }

  /// The typed table's columns: built-ins, the real citext, a domain over it, its array and a
  /// look-alike `evil.citext` (first on the reader's path, so a bare `citext` would name it).
  /// Every type is schema-qualified.
  private static let typeSetup = [
    "CREATE EXTENSION citext SCHEMA public",
    "CREATE SCHEMA evil",
    "CREATE DOMAIN evil.citext AS pg_catalog.text",
    "CREATE DOMAIN public.cit_dom AS public.citext",
    """
    CREATE TABLE public.typed (id pg_catalog.int4 PRIMARY KEY, plain pg_catalog.text,
      ci public.citext, dom public.cit_dom, arr public.citext[], fake evil.citext)
    """,
  ]

  @Test(
    "The schema and structure reads classify citext, a domain over it, its array and a look-alike",
    .timeLimit(.minutes(3)))
  func columnTypesClassifyExtensionTypes() async throws {
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.config(database: TestDatabase.database))
    // contrib citext is optional on a server: without it there is nothing to classify
    let available = try await admin.executeInternal(
      "SELECT count(*) FROM pg_catalog.pg_available_extensions WHERE name = 'citext'")
    guard available.rows.first?.first == .int(1) else {
      await admin.disconnect()
      try Test.cancel("contrib citext is not available on this server")
    }

    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
      .lowercased()
    let database = "qa_sp_db_\(suffix)"
    let role = "qa_sp_role_\(suffix)"
    let password = "sp_\(suffix)"
    let planter = DatabaseConnectionManager()
    let reader = DatabaseConnectionManager()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(database)")
      _ = try await admin.executeInternal("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'")

      try await planter.connect(config: Self.config(database: database))
      let grants = [
        "GRANT USAGE ON SCHEMA public, evil TO \(role)",
        "GRANT SELECT ON public.typed TO \(role)",
        "ALTER ROLE \(role) SET search_path = evil, public, pg_catalog",
      ]
      for sql in Self.typeSetup + grants {
        _ = try await planter.executeInternal(sql)
      }

      // Each column's atttypid, read as the planter
      let attributes = try await planter.executeInternal(
        """
        SELECT a.attname::pg_catalog.text, a.atttypid::pg_catalog.int8
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.typed'::pg_catalog.regclass AND a.attnum > 0
          AND NOT a.attisdropped
        """
      ).rows
      var oids: [String: UInt32] = [:]
      for row in attributes {
        if case .string(let name)? = row.first, case .int(let oid)? = row.last {
          oids[name] = UInt32(exactly: oid)
        }
      }
      let oid = { (name: String) throws -> UInt32 in try #require(oids[name], "\(name)") }
      let expected: [String: PostgresColumnType?] = [
        "id": nil,
        "plain": nil,
        "ci": PostgresColumnType(
          oid: try oid("ci"), operand: .bare, castName: "public.citext", compareCast: nil,
          operatorSchema: "public"),
        "dom": PostgresColumnType(
          oid: try oid("dom"), operand: .bare, castName: "public.cit_dom",
          compareCast: "public.citext", operatorSchema: "public"),
        "arr": PostgresColumnType(
          oid: try oid("arr"), operand: .qualified, castName: "public.citext[]",
          compareCast: nil, operatorSchema: nil),
        "fake": PostgresColumnType(
          oid: try oid("fake"), operand: .qualified, castName: "evil.citext", compareCast: nil,
          operatorSchema: nil),
      ]

      // The reads run on the trap path
      try await reader.connect(
        config: Self.config(database: database, username: role, password: password))
      #expect(try await searchPath(reader) == "evil, public, pg_catalog")

      let table = try #require(
        try await reader.fetchTables().first { $0.schema == "public" && $0.name == "typed" })
      let columns = try await reader.fetchAllColumns()[table.qualifiedName] ?? []
      #expect(columns.map(\.name) == ["id", "plain", "ci", "dom", "arr", "fake"])
      for column in columns {
        #expect(column.postgresType == expected[column.name] ?? nil, "schema load: \(column.name)")
      }

      let structure = try await reader.fetchTableStructure(schema: "public", table: "typed")
      #expect(structure.columns.map(\.name) == ["id", "plain", "ci", "dom", "arr", "fake"])
      for column in structure.columns {
        #expect(column.postgresType == expected[column.name] ?? nil, "structure: \(column.name)")
      }
    } catch {
      Issue.record(error)
    }
    await reader.disconnect()
    await planter.disconnect()
    _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database) WITH (FORCE)")
    _ = try? await admin.executeInternal("DROP ROLE IF EXISTS \(role)")
    await admin.disconnect()
  }

  /// `public.t`'s note of row `id`, read as the planter
  private func note(of id: Int, _ planter: DatabaseConnectionManager) async throws -> CellValue? {
    try await planter.executeInternal("SELECT note FROM public.t WHERE id = \(id)").rows.first?
      .first
  }

  /// `SHOW search_path` on the user's session
  private func searchPath(_ manager: DatabaseConnectionManager) async throws -> String? {
    let result = try await manager.execute(userSQL: "SHOW search_path", policy: Self.open)
    guard case .string(let path)? = result.rows.first?.first else { return nil }
    return path
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
