// MCPToolServiceTests.swift
// MCP tools: allowlist first, read-only run_query refused before sending, row and cell caps,
// History audit as `.mcp`, and the deterministic result encoding.

import Foundation
import Testing

@testable import Dblore

/// History rows the service recorded.
private actor RecordedHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// A scripted read source that records what reached it.
private final class FakeReadSource: MCPReadSource, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [MCPReadRequest] = []
  private var touched = 0
  var result = MCPReadResult(
    columns: [MCPResultColumn(name: "n", type: "int4")], rows: [[.int(1)]], rowsTruncated: false)
  var failure: (any Error)?

  var requests: [MCPReadRequest] { lock.withLock { recorded } }
  var calls: Int { lock.withLock { touched } }

  func listTables(connectionID: UUID, schema: String?) async throws -> [MCPTableName] {
    lock.withLock { touched += 1 }
    return [MCPTableName(schema: "public", name: "users")]
  }

  func describeTable(
    connectionID: UUID, schema: String?, table: String
  ) async throws -> [MCPColumnDescription] {
    lock.withLock { touched += 1 }
    return [MCPColumnDescription(name: "id", type: "int4", nullable: false, primaryKey: true)]
  }

  func runRead(_ request: MCPReadRequest) async throws -> MCPReadResult {
    lock.withLock {
      touched += 1
      recorded.append(request)
    }
    if let failure { throw failure }
    return result
  }
}

/// Toggled by a test.
private final class HistorySwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var on = true
  var enabled: Bool {
    get { lock.withLock { on } }
    set { lock.withLock { on = newValue } }
  }
}

@MainActor
@Suite("MCP tool service")
struct MCPToolServiceTests {
  private let source = FakeReadSource()
  private let history = RecordedHistory()
  private let historySwitch = HistorySwitch()

  private static func entry(
    _ type: DatabaseType = .postgresql, name: String = "Prod", password: String = "pw-secret"
  ) -> ConnectionHistoryEntry {
    var entry = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: type, host: "db.internal", port: 5432, database: "app",
        username: "admin-user", name: name))
    entry.config.password = password
    return entry
  }

  private func service(
    _ entries: [ConnectionHistoryEntry], allowed: Set<UUID>
  ) -> MCPToolService {
    let historySwitch = historySwitch
    return MCPToolService(
      connections: { entries }, allowlist: { allowed }, source: source, recorder: history,
      historyEnabled: { historySwitch.enabled })
  }

  private func runQuery(
    _ service: MCPToolService, _ id: UUID, _ sql: String, maxRows: JSONValue? = nil
  ) async -> MCPToolResult {
    var arguments: [String: JSONValue] = [
      "connection_id": .string(id.uuidString), "sql": .string(sql),
    ]
    arguments["max_rows"] = maxRows
    return await service.call("run_query", arguments: arguments)
  }

  @Test("Tools list names the four tools and labels results as untrusted data")
  func toolList() {
    #expect(
      MCPToolService.tools.map(\.name) == [
        "list_connections", "list_tables", "describe_table", "run_query",
      ])
    for tool in MCPToolService.tools.dropFirst() {
      #expect(tool.description.contains("untrusted"))
    }
  }

  @Test("Unknown, malformed and not-allowlisted connections get the same refusal")
  func allowlistRefusal() async {
    let known = Self.entry()
    let service = service([known], allowed: [])
    var texts: Set<String> = []
    for id in [known.id.uuidString, UUID().uuidString, "not-a-uuid"] {
      for (tool, extra) in [
        ("list_tables", [:]), ("describe_table", ["table": JSONValue.string("users")]),
        ("run_query", ["sql": .string("SELECT 1")]),
      ] {
        let result = await service.call(
          tool, arguments: extra.merging(["connection_id": .string(id)]) { $1 })
        #expect(result.isError)
        texts.insert(result.text)
      }
    }
    #expect(texts.count == 1)
    #expect(source.calls == 0)
    #expect(await history.entries.isEmpty)
  }

  @Test(
    "Statements other than one read are refused before sending, on PostgreSQL and MySQL",
    arguments: [DatabaseType.postgresql, .mysql])
  func nonReadRefused(type: DatabaseType) async {
    let entry = Self.entry(type)
    let service = service([entry], allowed: [entry.id])
    for sql in [
      "INSERT INTO t VALUES (1)", "SELECT 1; SELECT 2", "CREATE TABLE t (a int)",
      "SET search_path = x", "CALL p()", "EXPLAIN SELECT 1", "",
    ] {
      let result = await runQuery(service, entry.id, sql)
      #expect(result.isError, "\(sql)")
    }
    #expect(source.calls == 0)
    let recorded = await history.entries
    // Empty SQL has no statement to record
    #expect(recorded.count == 6)
    #expect(recorded.allSatisfy { $0.source == .mcp && $0.status == .error })
  }

  @Test("PostgreSQL calls to side-effect functions are refused before sending")
  func postgresSideEffectFunctionsRefused() async {
    let entry = Self.entry()
    let service = service([entry], allowed: [entry.id])
    let refused = [
      "SELECT dblink_exec('host=x', 'DELETE FROM t')",
      "SELECT * FROM dblink('c', 'SELECT 1') AS t(a int)",
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity", "SELECT pg_cancel_backend(1)",
      "SELECT pg_advisory_lock(1)", "SELECT pg_advisory_xact_lock(1)",
      "SELECT pg_try_advisory_lock_shared(1)", "SELECT pg_advisory_unlock_all()",
      "SELECT lo_import('/etc/passwd')", "SELECT lo_export(1, '/tmp/x')", "SELECT lo_unlink(1)",
      "SELECT lo_create(0)", "SELECT lo_open(1, 1)", "SELECT lo_put(1, 0, 'x')",
      "SELECT lo_from_bytea(0, 'x')", "SELECT lo_truncate(1, 0)",
      "SELECT pg_read_file('/etc/passwd')", "SELECT pg_read_binary_file('x')",
      "SELECT pg_ls_dir('.')", "SELECT * FROM pg_ls_waldir()", "SELECT pg_stat_file('x')",
      "SELECT pg_sleep(10)", "SELECT pg_sleep_for('1 minute')", "SELECT pg_reload_conf()",
      "SELECT pg_rotate_logfile()", "SELECT pg_promote()", "SELECT pg_switch_wal()",
      "SELECT pg_create_logical_replication_slot('s', 'p')",
      "SELECT pg_drop_replication_slot('s')", "SELECT pg_notify('c', 'x')",
      "SELECT set_config('a.b', 'c', false)", "SELECT nextval('s')", "SELECT setval('s', 1)",
      "SELECT txid_current()", "SELECT pg_current_xact_id()",
      "SELECT pg_logical_emit_message(true, 'p', 'x')",
      // SQL text run by the function, unseen by the classifier
      "SELECT query_to_xml('select pg_terminate_backend(1)', true, false, '')",
      "SELECT query_to_xmlschema('SELECT 1', true, false, '')",
      "SELECT query_to_xml_and_xmlschema('SELECT 1', true, false, '')",
      "SELECT cursor_to_xml('c', 1, true, false, '')",
      "SELECT cursor_to_xmlschema('c', true, false, '')",
      "SELECT database_to_xml(true, false, '')", "SELECT schema_to_xml('public', true, false, '')",
      "SELECT * FROM ts_stat('SELECT v FROM t')",
      #"SELECT U&"pg\0073leep"(1)"#,
      // Case, spacing, comments, schema-qualified and quoted names
      "select PG_SLEEP(1)", "SELECT pg_sleep (1)", "SELECT pg_sleep/* x */(1)",
      "SELECT pg_catalog.pg_sleep(1)", #"SELECT "pg_sleep"(1)"#,
      #"SELECT pg_catalog."pg_advisory_lock"(1)"#,
      // ts_rewrite runs its second argument as SQL
      "SELECT ts_rewrite('a'::tsquery, $$SELECT pg_try_advisory_lock(42)::text::tsquery, 'b'::tsquery$$)",
      "SELECT * FROM pg_copy_logical_replication_slot('a', 'b')",
      "SELECT * FROM pg_logical_slot_get_changes('s', NULL, NULL)",
      "SELECT pg_stat_statements_reset()", "SELECT pg_start_backup('x')", "SELECT pg_stop_backup()",
      "SELECT pg_logfile_rotate()", "SELECT pg_log_backend_memory_contexts(1)",
      "SELECT pg_import_system_collations('pg_catalog')",
      // A CTE before the main query does not hide a call in it
      "WITH a AS (SELECT 1) SELECT 1, pg_sleep(1) AS x FROM a",
      "WITH lo_a(n) AS (SELECT 1) SELECT pg_sleep(n) AS (n) FROM lo_a",
      // A record function's column definitions shaped like a CTE head
      "SELECT * FROM (VALUES ('c', 'DELETE FROM t')) v(c, q), dblink(c, q) AS (values text)",
      // A CTE named like a listed function fails closed
      "WITH pg_sleep_stats(a) AS (SELECT 1) SELECT a FROM pg_sleep_stats",
      "WITH RECURSIVE pg_sleep(n) AS (SELECT 1) SELECT n FROM pg_sleep",
    ]
    for sql in refused {
      let result = await runQuery(service, entry.id, sql)
      #expect(result.isError, "\(sql)")
      #expect(result.text == MCPToolError.sideEffectFunction.localizedDescription, "\(sql)")
    }
    #expect(source.calls == 0)
    let recorded = await history.entries
    #expect(recorded.count == refused.count)
    #expect(recorded.allSatisfy { $0.status == .error })

    // A mention that is not a call is sent: a string, a column, an alias column list
    let sent = [
      "SELECT 'pg_sleep(1)'", "SELECT lower('x')", "SELECT count(*) FROM pg_stat_activity",
      "SELECT pg_sleep FROM t", "SELECT n FROM generate_series(1, 2) AS lo_x(n)",
    ]
    for sql in sent {
      let result = await runQuery(service, entry.id, sql)
      #expect(!result.isError, "\(sql): \(result.text)")
    }
    #expect(source.calls == sent.count)
  }

  @Test("Row cap defaults to 200 and is clamped to 1...1000")
  func rowCap() async {
    let entry = Self.entry()
    let service = service([entry], allowed: [entry.id])
    _ = await runQuery(service, entry.id, "SELECT 1")
    _ = await runQuery(service, entry.id, "SELECT 1", maxRows: .number(5000))
    _ = await runQuery(service, entry.id, "SELECT 1", maxRows: .number(0))
    _ = await runQuery(service, entry.id, "SELECT 1", maxRows: .number(50))
    #expect(source.requests.map(\.maxRows) == [200, 1000, 1, 50])
    #expect(source.requests.allSatisfy { $0.connectionID == entry.id && $0.sql == "SELECT 1" })

    let invalid = await runQuery(service, entry.id, "SELECT 1", maxRows: .string("50"))
    #expect(invalid.isError)
    #expect(source.requests.count == 4)
    #expect(await history.entries.last?.status == .error)

    // The default comes from the row cap setting, clamped to 1...1000 too.
    let id = entry.id
    for (setting, expected) in [(300, 300), (5_000, 1_000), (0, 1)] {
      let configured = MCPToolService(
        connections: { [entry] }, allowlist: { [id] }, source: source, recorder: history,
        historyEnabled: { true }, defaultMaxRows: { setting })
      _ = await runQuery(configured, entry.id, "SELECT 1")
      #expect(source.requests.last?.maxRows == expected)
    }
  }

  @Test("A successful read is recorded as MCP only while History is on")
  func historyFollowsSetting() async {
    let entry = Self.entry()
    let service = service([entry], allowed: [entry.id])
    let result = await runQuery(service, entry.id, "SELECT 1")
    #expect(!result.isError)
    historySwitch.enabled = false
    _ = await runQuery(service, entry.id, "SELECT 2")
    _ = await runQuery(service, entry.id, "DELETE FROM t")

    let recorded = await history.entries
    #expect(recorded.count == 1)
    #expect(recorded.first?.source == .mcp)
    #expect(recorded.first?.kind == .read)
    #expect(recorded.first?.status == .success)
    #expect(recorded.first?.rowCount == 1)
    #expect(recorded.first?.sql == "SELECT 1")
    #expect(recorded.first?.connectionLabel == "Prod")
    #expect(recorded.first?.connectionKey == QueryHistoryIdentity.connectionKey(for: entry.config))
  }

  @Test("A failed read is recorded with its error and returned without secrets")
  func failureRecorded() async {
    let entry = Self.entry()
    source.failure = DatabaseError.queryFailed("relation \"nope\" does not exist", 0)
    let service = service([entry], allowed: [entry.id])
    let result = await runQuery(service, entry.id, "SELECT * FROM nope")
    #expect(result.isError)
    #expect(result.text.contains("does not exist"))
    #expect(!result.text.contains("pw-secret"))
    let recorded = await history.entries
    #expect(recorded.map(\.status) == [.error])
    #expect(recorded.first?.errorMessage?.contains("does not exist") == true)
  }

  @Test("MySQL side-effect functions and SELECT ... INTO are refused before sending")
  func mysqlSideEffectsRefused() async {
    let entry = Self.entry(.mysql)
    let service = service([entry], allowed: [entry.id])
    for sql in [
      "SELECT LOAD_FILE('/etc/passwd')", "SELECT SLEEP(10)", "SELECT GET_LOCK('x', 1)",
      "SELECT 1 INTO OUTFILE '/tmp/x'", "SELECT 1 INTO DUMPFILE '/tmp/x'", "SELECT 1 INTO @v",
    ] {
      let result = await runQuery(service, entry.id, sql)
      #expect(result.isError, "\(sql)")
      #expect(result.text == MCPToolError.notRead.localizedDescription, "\(sql)")
    }
    #expect(source.calls == 0)
  }

  @Test("Statements that carry a password are recorded with their string literals redacted")
  func passwordStatementsRedacted() async {
    let entry = Self.entry(.mysql)
    let service = service([entry], allowed: [entry.id])
    _ = await runQuery(service, entry.id, "ALTER USER bob IDENTIFIED BY 'hunter2'")
    _ = await runQuery(
      service, entry.id, "SELECT secret, `card` FROM t, (SELECT PASSWORD('hunter2')) p")
    source.failure = DatabaseError.queryFailed("near 'hunter2': bad value hunter2", 0)
    _ = await runQuery(service, entry.id, "SELECT secret FROM t WHERE PASSWORD(\"hunter2\")")
    source.failure = nil
    _ = await runQuery(service, entry.id, "SELECT 'kept'")
    let recorded = await history.entries
    #expect(
      recorded.map(\.sql) == [
        "ALTER USER bob IDENTIFIED BY '…'",
        "SELECT secret, `card` FROM t, (SELECT PASSWORD('…')) p",
        "SELECT secret FROM t WHERE PASSWORD('…')", "SELECT 'kept'",
      ])
    #expect(recorded.map(\.status) == [.error, .success, .error, .success])
    #expect(recorded.map(\.rowCount) == [nil, 1, nil, 1])
    #expect(recorded.allSatisfy { $0.source == .mcp && $0.kind != nil })
    // Error text of such a row may quote the literal, so it is not kept
    #expect(recorded[2].errorMessage == nil)
    #expect(recorded[0].errorMessage == nil)
    #expect(!recorded.contains { ($0.sql + ($0.errorMessage ?? "")).contains("hunter2") })
  }

  @Test("Scrubbing replaces the longest value first and whole dotted names only")
  func scrubLongestFirst() {
    var config = Self.entry().config
    config.database = "orders"
    config.host = "orders-db.example.com"
    let text = MCPToolService.scrub(
      "could not reach orders-db.example.com for database orders. orders_archive is kept",
      config: config)
    #expect(text == "could not reach <host> for database <database>. orders_archive is kept")
  }

  @Test("Server errors are scrubbed of the connection's host, user, database and file path")
  func errorsScrubbed() async {
    let mysql = Self.entry(.mysql)
    var sqlite = Self.entry(.sqlite, name: "Local")
    sqlite.config.database = "/Users/me/data/app.sqlite"
    let service = service([mysql, sqlite], allowed: [mysql.id, sqlite.id])
    source.failure = DatabaseError.queryFailed(
      "Access denied for user 'admin-user'@'10.0.0.5' to database 'app' on db.internal:5432 "
        + String(repeating: "z", count: 2_000), 0)
    let denied = await runQuery(service, mysql.id, "SELECT 1")
    source.failure = DatabaseError.queryFailed(
      "unable to open database file /Users/me/data/app.sqlite", 0)
    let path = await runQuery(service, sqlite.id, "SELECT 1")

    #expect(denied.isError && denied.text.contains("Access denied"))
    #expect(denied.text.count <= 1_000)
    #expect(path.isError && path.text.contains("unable to open database file"))
    let recorded = await history.entries.compactMap(\.errorMessage)
    #expect(recorded == [denied.text, path.text])
    for text in [denied.text, path.text] {
      for leaked in ["admin-user", "10.0.0.5", "db.internal", "'app'", "/Users/me"] {
        #expect(!text.contains(leaked), "\(leaked) in \(text)")
      }
    }
  }

  @Test("A connection that fails to connect gets a generic error, without server text")
  func connectErrorGeneric() async {
    let entry = Self.entry()
    let id = entry.id
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      openError: DatabaseError.connectionFailed(
        "password authentication failed for user \"admin-user\" (db.internal:5432)"))
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let historySwitch = historySwitch
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, source: MCPSQLReadSource(pool: pool),
      recorder: history, historyEnabled: { historySwitch.enabled })
    let read = await runQuery(service, id, "SELECT 1")
    let tables = await service.call(
      "list_tables", arguments: ["connection_id": .string(id.uuidString)])
    let generic = "Could not connect to this connection."
    #expect(read.isError && read.text == generic)
    #expect(tables.isError && tables.text == generic)
    #expect(await history.entries.map(\.errorMessage) == [generic])
    await pool.closeAll()
  }

  @Test("list_connections shows only allowlisted connections, without host or secrets")
  func listConnections() async {
    let allowed = Self.entry(name: "Prod")
    let hidden = Self.entry(.mysql, name: "Hidden")
    let service = service([allowed, hidden], allowed: [allowed.id, UUID()])
    let result = await service.call("list_connections", arguments: [:])
    #expect(!result.isError)
    #expect(result.text.contains(allowed.id.uuidString))
    #expect(result.text.contains("Prod"))
    #expect(result.text.contains("PostgreSQL"))
    for leaked in [hidden.id.uuidString, "Hidden", "pw-secret", "db.internal", "admin-user"] {
      #expect(!result.text.contains(leaked), "\(leaked)")
    }
  }

  @Test("list_tables and describe_table go through the read source once allowlisted")
  func introspectionTools() async {
    let entry = Self.entry()
    let service = service([entry], allowed: [entry.id])
    let id = JSONValue.string(entry.id.uuidString)
    let tables = await service.call("list_tables", arguments: ["connection_id": id])
    let columns = await service.call(
      "describe_table", arguments: ["connection_id": id, "table": .string("users")])
    #expect(!tables.isError && tables.text.contains("users"))
    #expect(!columns.isError && columns.text.contains("\"primary_key\":true"))
    #expect(tables.text.contains(MCPResultEncoder.dataNotice))

    let empty = await service.call(
      "describe_table", arguments: ["connection_id": id, "table": .string("")])
    #expect(empty.isError)
    #expect(empty.text == MCPToolError.missingArgument("table").localizedDescription)
    #expect(source.calls == 2)
  }

  @Test("Encoder: deterministic JSON, NULL vs empty string, binary as base64, long cells cut")
  func encoderOutput() {
    let long = String(repeating: "x", count: 2_500)
    let result = MCPReadResult(
      columns: [MCPResultColumn(name: "a", type: "text"), MCPResultColumn(name: "b", type: "")],
      rows: [
        [.null, .string("")],
        [.int(7), .bool(true)],
        [.data(Data([0, 1, 255])), .string(long)],
      ],
      rowsTruncated: true)
    let text = MCPResultEncoder.encodeRows(result)
    #expect(text == MCPResultEncoder.encodeRows(result))
    let expectedPrefix =
      #"{"columns":[{"name":"a","type":"text"},{"name":"b","type":""}],"notice":""#
      + MCPResultEncoder.dataNotice
      + #"","row_count":3,"rows":[[null,""],[7,true],[{"base64":"AAH/","bytes":3},"#
    #expect(text.hasPrefix(expectedPrefix))
    #expect(
      text.hasSuffix(
        #"{"truncated":true,"value":""# + String(repeating: "x", count: 2_000)
          + #""}]],"rows_truncated":true,"truncated_cells":1}"#))
  }

  @Test("Cells are cut as rows are read, and the read stops at the result byte budget")
  func resultMemoryBounded() async throws {
    let big = CellValue.string(String(repeating: "x", count: 3_000))
    let blob = CellValue.data(Data(repeating: 7, count: 10_000))
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: ["a", "b", "c", "d"].map { ColumnInfo(name: $0, type: "text") },
      rows: Array(repeating: [big, big, big, blob], count: 1_000))
    let entry = Self.entry()
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let read = try await MCPSQLReadSource(pool: pool).runRead(
      MCPReadRequest(connectionID: id, sql: "SELECT a, b, c, d FROM t", maxRows: 1_000))
    await pool.closeAll()

    #expect(read.rowsTruncated)
    #expect(read.rows.count > 100 && read.rows.count < 1_000)
    var bytes = 0
    for cell in read.rows.joined() {
      switch cell {
      case .string(let text):
        #expect(text.count <= MCPResultEncoder.maxCellCharacters + 1)
        bytes += text.utf8.count
      case .data(let data):
        #expect(data.count <= MCPResultEncoder.maxCellCharacters / 4 * 3 + 1)
        bytes += data.count
      default: Issue.record("unexpected \(cell)")
      }
    }
    #expect(bytes <= 4 * 1_024 * 1_024)
    let text = MCPResultEncoder.encodeRows(read)
    #expect(text.contains(#""truncated_cells":\#(read.rows.count * 4)"#))
  }

  @Test("The SQL read source runs the query on the pool's read-only session with the cap")
  func sqlReadSource() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: [ColumnInfo(name: "n", type: "int4")],
      rows: [[.int(1)], [.int(2)], [.int(3)]])
    let entry = Self.entry()
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let read = try await MCPSQLReadSource(pool: pool).runRead(
      MCPReadRequest(connectionID: entry.id, sql: "SELECT n FROM t", maxRows: 2))
    #expect(read.columns == [MCPResultColumn(name: "n", type: "int4")])
    #expect(read.rows == [[.int(1)], [.int(2)]])
    #expect(read.rowsTruncated)
    #expect(factory.statements.contains("BEGIN TRANSACTION READ ONLY"))
    #expect(factory.statements.contains("SELECT n FROM t"))
    await pool.closeAll()
  }
}
