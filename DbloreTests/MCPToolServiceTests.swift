// MCPToolServiceTests.swift
// MCP tools: allowlist first, then the AI access gate, read-only run_query refused before sending,
// row and cell caps, History audit as `.mcp`, and the deterministic result encoding. A paired
// command-line tool (caller cli): the headless access rule, read tools only, History as `.cli`.

import Foundation
import Testing

@testable import Dblore

/// A flag another task sets (the fake catalog's answer changes once it is set).
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

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

/// Approves every write.
private struct ApprovingApprover: MCPWriteApproving {
  func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool { true }
  func denyWaiting(connections: Set<UUID>) async {}
  func denyAllWaiting() async {}
}

/// Records the writes that reached it.
private final class RecordingWriteSource: MCPWriteSource, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []

  var statements: [String] { lock.withLock { sent } }

  func runWrite(_ request: MCPWriteRequest) async throws -> MCPWriteResult {
    lock.withLock { sent.append(request.sql) }
    return MCPWriteResult(affectedRows: 1)
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
  /// Session approvals of this test only
  private let gate = AIAccessGate()

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
    _ entries: [ConnectionHistoryEntry], allowed: Set<UUID>, ai: AIConfiguration? = .empty
  ) -> MCPToolService {
    let historySwitch = historySwitch
    return MCPToolService(
      connections: { entries }, allowlist: { allowed }, aiSettings: { ai }, source: source,
      recorder: history, historyEnabled: { historySwitch.enabled }, gate: gate)
  }

  /// list_tables, describe_table and run_query on `id`.
  private func connectionTools(
    _ service: MCPToolService, _ id: UUID
  ) async -> [MCPToolResult] {
    var results: [MCPToolResult] = []
    for (tool, extra) in [
      ("list_tables", [:]), ("describe_table", ["table": JSONValue.string("users")]),
      ("run_query", ["sql": .string("SELECT 1")]),
    ] {
      results.append(
        await service.call(
          tool, arguments: extra.merging(["connection_id": .string(id.uuidString)]) { $1 }))
    }
    return results
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
        connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty }, source: source,
        recorder: history, historyEnabled: { true }, defaultMaxRows: { setting }, gate: gate)
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
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: history,
      historyEnabled: { historySwitch.enabled }, gate: gate)
    let read = await runQuery(service, id, "SELECT 1")
    let tables = await service.call(
      "list_tables", arguments: ["connection_id": .string(id.uuidString)])
    let generic = "Could not connect to this connection."
    #expect(read.isError && read.text == generic)
    #expect(tables.isError && tables.text == generic)
    #expect(await history.entries.map(\.errorMessage) == [generic])
    await pool.closeAll()
  }

  @Test("A Vault connection's refusal reaches the agent whole, even for a database named app")
  func vaultRefusalNotScrubbed() async {
    var entry = Self.entry(password: "")
    entry.config.username = "app"
    entry.config.vault = VaultSource(
      address: "https://vault.internal:8200", mount: "database", role: "app", authMethod: .token,
      caPEM: nil)
    let row = entry
    let id = row.id
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let pool = MCPConnectionPool(
      entry: { $0 == id ? row : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let historySwitch = historySwitch
    let service = MCPToolService(
      connections: { [row] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: history,
      historyEnabled: { historySwitch.enabled }, gate: gate)
    let read = await runQuery(service, id, "SELECT 1")
    #expect(read.isError)
    #expect(read.text == "Vault connections need the app window.")
    #expect(factory.sessions.isEmpty)
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

  @Test("AI access Never is refused like a non-allowlisted id and hidden; Ask is listed")
  func aiAccessNever() async {
    var never = Self.entry(name: "Never")
    never.config.aiAccess = .never
    var ask = Self.entry(.mysql, name: "Ask")
    ask.config.aiAccess = .askOncePerSession
    let outside = Self.entry(name: "Outside")
    let service = service([never, ask, outside], allowed: [never.id, ask.id])

    let refused = await connectionTools(service, never.id)
    let notAllowlisted = await connectionTools(service, outside.id)
    #expect(refused.map(\.isError) == [true, true, true])
    #expect(Set((refused + notAllowlisted).map(\.text)).count == 1)
    #expect(source.calls == 0)
    #expect(await history.entries.isEmpty)

    let listed = await service.call("list_connections", arguments: [:])
    #expect(!listed.text.contains(never.id.uuidString) && !listed.text.contains("Never"))
    #expect(listed.text.contains(ask.id.uuidString))
  }

  @Test("a non-allowlisted Never row of the same identity refuses and hides the allowlisted row")
  func aiAccessStrictestSavedRow() async {
    var always = Self.entry(name: "Always")
    always.config.aiAccess = .always
    var twin = Self.entry(name: "Twin")
    twin.config.aiAccess = .never
    var other = Self.entry(name: "Other")
    other.config.host = "db2.internal"
    other.config.aiAccess = .never

    let strict = service([always, twin], allowed: [always.id])
    let refused = await connectionTools(strict, always.id)
    let notAllowlisted = await connectionTools(strict, twin.id)
    #expect(refused.map(\.isError) == [true, true, true])
    #expect(Set((refused + notAllowlisted).map(\.text)).count == 1)
    #expect(source.calls == 0)
    let listed = await strict.call("list_connections", arguments: [:])
    #expect(
      !listed.text.contains(always.id.uuidString) && !listed.text.contains(twin.id.uuidString))

    let unrelated = service([always, other], allowed: [always.id])
    let allowed = await connectionTools(unrelated, always.id)
    #expect(allowed.map(\.isError) == [false, false, false], "\(allowed.map(\.text))")
    let listedOther = await unrelated.call("list_connections", arguments: [:])
    #expect(listedOther.text.contains(always.id.uuidString))
    #expect(!listedOther.text.contains(other.id.uuidString))
  }

  @Test(
    "AI access Ask is refused until approved in the app; unreadable settings ask",
    arguments: [
      (AIAccessPolicy.askOncePerSession, AIConfiguration?.some(.empty)), (.useDefault, nil),
    ])
  func aiAccessAsk(policy: AIAccessPolicy, ai: AIConfiguration?) async {
    var entry = Self.entry()
    entry.config.aiAccess = policy
    let service = service([entry], allowed: [entry.id], ai: ai)

    let refused = await connectionTools(service, entry.id)
    let message = "Allow AI access to this connection in Dblore first."
    #expect(refused.map(\.isError) == [true, true, true])
    #expect(refused.map(\.text) == [message, message, message])
    #expect(source.calls == 0)
    #expect(await history.entries.isEmpty)

    gate.approveForSession(AIAccessGate.sessionKey(for: entry.config))
    let allowed = await connectionTools(service, entry.id)
    #expect(allowed.map(\.isError) == [false, false, false], "\(allowed.map(\.text))")
    #expect(source.calls == 3)
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

  @Test("run_query of one quoted PostgreSQL relation returns the catalog's column types")
  func quotedRelationEnrichedTypes() async throws {
    let origin = ColumnOrigin(tableID: .postgresql(oid: 42), columnOrdinal: 1)
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [ColumnInfo(name: "amount", type: "numeric", origin: origin)],
      rows: [[.string("1.50")]])
    let entry = Self.entry()
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    // The catalog read answered in place of the server
    try await pool.withManager(for: id) { manager in
      await manager.setColumnTypeReadHook { columns in
        columns.map {
          ColumnInfo(name: $0.name, type: "NUMERIC(10,2)", origin: $0.origin)
        }
      }
    }
    let historySwitch = historySwitch
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: history,
      historyEnabled: { historySwitch.enabled }, gate: gate)
    let read = await runQuery(service, id, "SELECT amount FROM \"public\".\"payments\"")
    await pool.closeAll()

    #expect(!read.isError, "\(read.text)")
    #expect(read.text.contains(#""type":"NUMERIC(10,2)""#), "\(read.text)")
  }

  @Test("run_query writes a naive column's wall clock and a zoned column as ISO 8601 UTC")
  func sqlReadSourceDateShapes() async throws {
    // 2026-10-15 12:00:00.123 UTC
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123))
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [
        ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
        ColumnInfo(name: "zoned", type: "timestamptz"),
      ],
      rows: [[date, date]])
    let entry = Self.entry()
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let read = try await MCPSQLReadSource(pool: pool).runRead(
      MCPReadRequest(connectionID: id, sql: "SELECT naive, zoned FROM t", maxRows: 10))
    await pool.closeAll()

    #expect(read.columns.map(\.wallClock) == [true, false])
    let text = MCPResultEncoder.encodeRows(read)
    #expect(text.contains(#""rows":[["2026-10-15 12:00:00.123","2026-10-15T12:00:00.123Z"]]"#))
  }

  @Test("execute_write is refused when the commit style falls back to Review, protected mode off")
  func reviewFallbackRefusesWrite() async {
    let writes = RecordingWriteSource()
    var fallback = Self.entry()
    fallback.config.protectedMode = false
    var confirm = Self.entry()
    confirm.config.protectedMode = false
    confirm.config.commitStyle = .confirm
    let entries = [fallback, confirm]
    let ids = entries.map(\.id)
    let service = MCPToolService(
      connections: { entries }, allowlist: { Set(ids) }, aiSettings: { .empty }, source: source,
      recorder: history, historyEnabled: { true }, gate: gate,
      writes: MCPWriteAccess(
        enabled: { true }, scopes: { Dictionary(uniqueKeysWithValues: ids.map { ($0, .data) }) },
        defaultCommitStyle: { .review }, approver: ApprovingApprover(), source: writes))
    for (id, refused) in [(fallback.id, true), (confirm.id, false)] {
      let result = await service.call(
        "execute_write",
        arguments: [
          "connection_id": .string(id.uuidString), "sql": .string("DELETE FROM t WHERE id = 1"),
        ])
      #expect(result.isError == refused)
      if refused {
        #expect(result.text == MCPToolError.writeCommitStyleDefault.localizedDescription)
      }
    }
    #expect(writes.statements == ["DELETE FROM t WHERE id = 1"])
  }

  // MARK: - Command-line tool (caller cli)

  /// A service whose only connection may be changed (data scope, Confirm), approvals granted.
  private func writableService(
    _ entry: ConnectionHistoryEntry, writes: RecordingWriteSource
  ) -> MCPToolService {
    let id = entry.id
    return MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty }, source: source,
      recorder: history, historyEnabled: { true }, gate: gate,
      writes: MCPWriteAccess(
        enabled: { true }, scopes: { [id: .data] }, defaultCommitStyle: { .confirm },
        approver: ApprovingApprover(), source: writes))
  }

  private static func writableEntry() -> ConnectionHistoryEntry {
    var entry = entry()
    entry.config.protectedMode = false
    entry.config.commitStyle = .confirm
    return entry
  }

  @Test("As cli, an allowlisted Ask-once connection runs without a prompt; AI Never is refused")
  func cliFollowsHeadlessRule() async {
    var ask = Self.entry(name: "Ask")
    ask.config.aiAccess = .askOncePerSession
    var never = Self.entry(.mysql, name: "Never")
    never.config.host = "other.internal"
    never.config.aiAccess = .never
    let service = service([ask, never], allowed: [ask.id, never.id])

    // The MCP path is unchanged: Ask once still needs the app's approval
    let asMCP = await connectionTools(service, ask.id)
    #expect(
      asMCP.map(\.text)
        == Array(repeating: MCPToolError.aiAccessNotApproved.localizedDescription, count: 3))
    #expect(source.calls == 0)

    let allowed = await MCPToolService.$caller.withValue(.cli) {
      await connectionTools(service, ask.id)
    }
    #expect(allowed.map(\.isError) == [false, false, false], "\(allowed.map(\.text))")
    #expect(source.calls == 3)
    let byName = await MCPToolService.$caller.withValue(.cli) {
      await service.call(
        "run_query", arguments: ["connection_id": .string("Ask"), "sql": .string("SELECT 1")])
    }
    #expect(!byName.isError, "\(byName.text)")
    #expect(source.calls == 4)

    let refused = await MCPToolService.$caller.withValue(.cli) {
      await connectionTools(service, never.id)
    }
    #expect(refused.map(\.isError) == [true, true, true])
    #expect(source.calls == 4)
    let listed = await MCPToolService.$caller.withValue(.cli) {
      await service.call("list_connections", arguments: [:])
    }
    #expect(listed.text.contains(ask.id.uuidString))
    #expect(!listed.text.contains(never.id.uuidString))
  }

  @Test("As cli, execute_write is refused before anything is asked or sent, and not listed")
  func cliCannotWrite() async {
    let writes = RecordingWriteSource()
    let entry = Self.writableEntry()
    let service = writableService(entry, writes: writes)
    let arguments: [String: JSONValue] = [
      "connection_id": .string(entry.id.uuidString), "sql": .string("DELETE FROM t WHERE id = 1"),
    ]

    let refused = await MCPToolService.$caller.withValue(.cli) {
      await service.call("execute_write", arguments: arguments)
    }
    #expect(refused.isError)
    #expect(refused.text == MCPToolError.cliReadOnly.localizedDescription)
    #expect(writes.statements.isEmpty)
    #expect(await history.entries.isEmpty)
    let cliTools = await MCPToolService.$caller.withValue(.cli) { await service.listedTools() }
    #expect(cliTools.map(\.name) == MCPToolService.tools.map(\.name))

    // An MCP client still writes
    #expect(await service.listedTools().map(\.name).contains("execute_write"))
    let written = await service.call("execute_write", arguments: arguments)
    #expect(!written.isError, "\(written.text)")
    #expect(writes.statements == ["DELETE FROM t WHERE id = 1"])
  }

  @Test("A cli run_query is recorded in History as cli, an MCP one as mcp")
  func cliHistorySource() async {
    let entry = Self.entry()
    let service = service([entry], allowed: [entry.id])
    _ = await MCPToolService.$caller.withValue(.cli) {
      await runQuery(service, entry.id, "SELECT 1")
    }
    _ = await runQuery(service, entry.id, "SELECT 2")
    #expect(await history.entries.map(\.source) == [.cli, .mcp])
  }

  @Test("Through JSON-RPC the request's caller reaches tools/list and tools/call; none is 401")
  func callerThroughJSONRPC() async throws {
    let writes = RecordingWriteSource()
    let entry = Self.writableEntry()
    let handler = MCPJSONRPC.handler(tools: writableService(entry, writes: writes))
    let post = { (body: String, caller: MCPCallerKind?) in
      MCPHTTPRequest(
        method: "POST", path: "/mcp",
        headers: [
          "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
          "Host": "127.0.0.1:41730",
        ], body: Data(body.utf8), caller: caller, port: 41730)
    }
    let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
    func names(_ response: MCPHTTPResponse) throws -> [String] {
      let object = try #require(
        JSONSerialization.jsonObject(with: response.body) as? [String: Any])
      let tools = try #require((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
      return tools.compactMap { $0["name"] as? String }
    }
    #expect(try names(await handler(post(list, .cli))) == MCPToolService.tools.map(\.name))
    #expect(try names(await handler(post(list, .mcp))).contains("execute_write"))

    let call =
      #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute_write","#
      + #""arguments":{"connection_id":"\#(entry.id.uuidString)","sql":"DELETE FROM t"}}}"#
    let refused = await handler(post(call, .cli))
    #expect(String(decoding: refused.body, as: UTF8.self).contains("command-line tool only reads"))
    #expect(writes.statements.isEmpty)
    #expect(await handler(post(list, nil)).status == 401)
  }
}

// MARK: - Column masking

/// Mask rules applied where user SQL results leave the manager: an MCP `run_query`, a grid read
/// and a SQLite read. Rule `users.email`; a result's origin is resolved per engine and fails
/// closed (the rule matches on its column alone) when it is a view, a partition or unknown.
extension MCPToolServiceTests {
  private static let rawEmail = "alice@example.com"
  private static let maskedEmail = "a\u{2022}\u{2022}\u{2022}@example.com"

  /// pg_class by OID: schema, table, relkind and whether the relation has a parent
  private nonisolated static let relations: [Int: (String, String, String, Bool)] = [
    100: ("public", "users", "r", false), 200: ("public", "users_v", "v", false),
    300: ("public", "users_2026_10", "r", true), 400: ("public", "orders", "r", false),
  ]

  /// The origin lookup (the read naming pg_inherits) answered with the bound OIDs' rows
  private nonisolated static let catalog = pgCatalog { relations }

  /// `catalog` over the relations `relations` returns when the lookup runs
  private nonisolated static func pgCatalog(
    _ relations: @escaping @Sendable () -> [Int: (String, String, String, Bool)]
  ) -> FakeQueryAnswer.Script {
    { sql, binds in
      guard sql.contains("pg_inherits"), case .text(let list)? = binds.first else { return nil }
      let oids = list.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        .split(separator: ",").compactMap { Int($0) }
      let current = relations()
      return FakeQueryAnswer(
        columns: ["oid", "nspname", "relname", "relkind", "has_parent"].map {
          ColumnInfo(name: $0, type: "text")
        },
        rows: oids.compactMap { oid in
          current[oid].map {
            [.int(oid), .string($0.0), .string($0.1), .string($0.2), .bool($0.3)]
          }
        })
    }
  }

  private static func emailRule(_ style: ColumnMaskRule.Style = .email) throws -> [ColumnMaskRule] {
    [try ColumnMaskRule(pattern: "users.email", style: style)]
  }

  /// A PostgreSQL fake answering user SQL with one `email` column read from relation `oid`
  private static func emailFactory(
    oid: UInt32, value: String = rawEmail, failingLookup: Bool = false,
    catalog: @escaping FakeQueryAnswer.Script = catalog
  ) -> FakeDatabaseSessionFactory {
    FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [
        ColumnInfo(
          name: "email", type: "text",
          origin: ColumnOrigin(tableID: .postgresql(oid: oid), columnOrdinal: 2))
      ],
      rows: [[.string(value)]], failingQuery: failingLookup ? "pg_inherits" : nil,
      queryAnswer: catalog)
  }

  private static func pgConfig(maskRules: [ColumnMaskRule] = []) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.maskRules = maskRules
    return config
  }

  @Test(
    "run_query masks users.email from a table, view, partition or failed lookup; not orders",
    arguments: [
      ("SELECT * FROM users", 100, false, true),
      ("SELECT email FROM users", 100, false, true),
      ("SELECT email FROM users", 100, true, true),
      ("SELECT * FROM users_v", 200, false, true),
      ("SELECT * FROM users_2026_10", 300, false, true),
      ("SELECT email FROM orders", 400, false, false),
    ] as [(String, UInt32, Bool, Bool)])
  func runQueryMasks(sql: String, oid: UInt32, failingLookup: Bool, masked: Bool) async throws {
    let factory = Self.emailFactory(oid: oid, failingLookup: failingLookup)
    var ruled = Self.entry()
    ruled.config.maskRules = try Self.emailRule()
    let entry = ruled
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let historySwitch = historySwitch
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: history,
      historyEnabled: { historySwitch.enabled }, gate: gate)
    let read = await runQuery(service, id, sql)
    await pool.closeAll()

    #expect(!read.isError, "\(read.text)")
    #expect(read.text.contains(Self.rawEmail) == !masked, "\(read.text)")
    #expect(read.text.contains(Self.maskedEmail) == masked, "\(read.text)")
    #expect(factory.statements.contains { $0.contains("pg_inherits") })
  }

  @Test("A deferred grid read resolves the origin before its rows return, once per result")
  func deferredGridReadResolvesOrigin() async throws {
    for (oid, masked) in [(UInt32(400), false), (100, true)] {
      let factory = Self.emailFactory(oid: oid)
      let manager = DatabaseConnectionManager(sessionFactory: factory)
      try await manager.connect(config: Self.pgConfig(maskRules: try Self.emailRule()))
      for _ in 0..<2 {
        let result = try await manager.execute(
          userSQL: "SELECT email FROM t", policy: ProtectionPolicy(protectionLevel: .none),
          deferEnrichment: true)
        #expect(result.typesDeferred)
        #expect(result.columns.map(\.masked) == [masked])
        #expect(result.rows == [[.string(masked ? Self.maskedEmail : Self.rawEmail)]])
      }
      #expect(factory.statements.filter { $0.contains("pg_inherits") }.count == 2)
      await manager.disconnect()
    }
  }

  @Test("A table renamed by another client is matched by its new name on the next result")
  func renamedTableMatchesNewName() async throws {
    let renamed = Flag()
    let factory = Self.emailFactory(
      oid: 100,
      catalog: Self.pgCatalog {
        renamed.isSet ? [100: ("public", "people", "r", false)] : Self.relations
      })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: Self.pgConfig(maskRules: [try ColumnMaskRule(pattern: "people.email", style: .email)])
    )
    func read() async throws -> [[CellValue]] {
      try await manager.execute(
        userSQL: "SELECT email FROM users", policy: ProtectionPolicy(protectionLevel: .none)
      ).rows
    }
    #expect(try await read() == [[.string(Self.rawEmail)]])

    // ALTER TABLE users RENAME TO people, sent by another client: same OID, new name
    renamed.set()
    #expect(try await read() == [[.string(Self.maskedEmail)]])
    await manager.disconnect()
  }

  /// A PostgreSQL fake: `SELECT email FROM <table>` reads two rows of one `email` column from
  /// `oids[table]`; the origin lookup answers `relations`
  private static func emailTablesFactory(
    oids: [String: UInt32], relations: [Int: (String, String, String, Bool)]
  ) -> FakeDatabaseSessionFactory {
    let catalog = pgCatalog { relations }
    let raw = rawEmail
    return FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: [], rows: [],
      queryAnswer: { sql, binds in
        if let answer = catalog(sql, binds) { return answer }
        let prefix = "SELECT email FROM "
        guard sql.hasPrefix(prefix), let oid = oids[String(sql.dropFirst(prefix.count))] else {
          return nil
        }
        return FakeQueryAnswer(
          columns: [
            ColumnInfo(
              name: "email", type: "text",
              origin: ColumnOrigin(tableID: .postgresql(oid: oid), columnOrdinal: 2))
          ],
          rows: [[.string(raw)], [.string(raw)]])
      })
  }

  /// Whether `SELECT email FROM <table>` comes back masked (column flag and every row)
  private static func readsMasked(
    _ table: String, on manager: DatabaseConnectionManager, policy: ProtectionPolicy,
    maxRows: Int = DatabaseConnectionManager.defaultMaxFetchRows
  ) async throws -> (masked: Bool, result: QueryResult) {
    let result = try await manager.execute(
      userSQL: "SELECT email FROM \(table)", policy: policy, maxRows: maxRows)
    let masked =
      result.columns.map(\.masked) == [true] && !result.rows.isEmpty
      && result.rows.allSatisfy { $0 == [.string(maskedEmail)] }
    return (masked, result)
  }

  @Test(
    "While the app transaction is pending, tables read before keep their origin; others fail closed"
  )
  func pendingTransactionUsesReadOrigins() async throws {
    let factory = Self.emailTablesFactory(
      oids: ["users": 100, "customers": 500, "vendors": 600],
      relations: Self.relations.merging([
        500: ("public", "customers", "r", false), 600: ("public", "vendors", "r", false),
      ]) { $1 })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    var config = Self.pgConfig(maskRules: try Self.emailRule())
    config.protectedMode = true
    try await manager.connect(config: config)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    func masked(_ table: String) async throws -> Bool {
      try await Self.readsMasked(table, on: manager, policy: protected).masked
    }
    func lookups() -> Int { factory.statements.filter { $0.contains("pg_inherits") }.count }

    #expect(try await !masked("customers"))
    #expect(try await masked("users"))
    #expect(lookups() == 2)

    _ = try await manager.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    #expect(await manager.transactionSnapshot().pending.count == 1)
    // No catalog read inside the transaction: the origins read before stand in
    #expect(try await !masked("customers"))
    #expect(try await masked("users"))
    // A read cut by the row cap keeps its session (the transaction): the memo still answers
    let capped = try await Self.readsMasked("customers", on: manager, policy: protected, maxRows: 1)
    #expect(capped.result.truncated && !capped.result.sessionReset)
    #expect(!capped.masked)
    // Never read before: no origin, so the rule matches on its column alone
    #expect(try await masked("vendors"))
    #expect(lookups() == 2)

    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(try await !masked("vendors"))
    #expect(lookups() == 3)
    await manager.disconnect()
  }

  @Test("A table renamed to a ruled name inside the app transaction is masked (memo cleared)")
  func renameInsideTransactionFailsClosed() async throws {
    // Same OID before and after the rename
    let factory = Self.emailTablesFactory(
      oids: ["staging": 700, "users": 700],
      relations: Self.relations.merging([700: ("public", "staging", "r", false)]) { $1 })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    var config = Self.pgConfig(maskRules: try Self.emailRule())
    config.protectedMode = true
    try await manager.connect(config: config)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    func lookups() -> Int { factory.statements.filter { $0.contains("pg_inherits") }.count }

    // Memoized: OID 700 is public.staging
    #expect(try await !Self.readsMasked("staging", on: manager, policy: protected).masked)
    #expect(lookups() == 1)

    _ = try await manager.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    _ = try await manager.execute(
      userSQL: "ALTER TABLE staging RENAME TO users", policy: protected)
    #expect(await manager.transactionSnapshot().pending.count == 2)
    // The DDL cleared the memo: OID 700 has no origin, so `users.email` matches on `email`
    #expect(try await Self.readsMasked("users", on: manager, policy: protected).masked)
    #expect(lookups() == 1)
    await manager.disconnect()
  }

  /// information_schema.TABLES of the MySQL fake: schema, table, TABLE_TYPE
  private nonisolated static let mysqlTables: [(String, String, String)] = [
    ("shop", "users", "BASE TABLE"), ("shop", "users_v", "VIEW"),
    ("shop", "orders", "BASE TABLE"), ("archive", "users", "BASE TABLE"),
  ]

  /// The base table lookup (the read of information_schema.TABLES) answered with the rows of
  /// its bound (schema, table) pairs
  private nonisolated static let mysqlCatalog: FakeQueryAnswer.Script = { sql, binds in
    guard sql.contains("information_schema.TABLES") else { return nil }
    let names = binds.compactMap { bind -> String? in
      if case .text(let text) = bind { return text }
      return nil
    }
    let pairs = stride(from: 0, to: names.count - 1, by: 2).map { (names[$0], names[$0 + 1]) }
    return FakeQueryAnswer(
      columns: ["TABLE_SCHEMA", "TABLE_NAME", "TABLE_TYPE"].map {
        ColumnInfo(name: $0, type: "VARCHAR")
      },
      rows: mysqlTables.filter { table in pairs.contains { $0 == (table.0, table.1) } }.map {
        [.string($0.0), .string($0.1), .string($0.2)]
      })
  }

  @Test(
    "MySQL run_query masks a view, a failed lookup and the exact schema's table; not orders",
    arguments: [
      ("users.email", "shop", "users_v", false, true),
      ("users.email", "shop", "users", true, true),
      ("users.email", "shop", "orders", false, false),
      ("shop.users.email", "shop", "users", false, true),
      ("shop.users.email", "archive", "users", false, false),
    ] as [(String, String, String, Bool, Bool)])
  func mysqlRunQueryMasks(
    rule: String, schema: String, table: String, failingLookup: Bool, masked: Bool
  ) async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [
        ColumnInfo(
          name: "email", type: "VARCHAR",
          sourceName: ColumnSourceName(schema: schema, table: table, column: "email"))
      ],
      rows: [[.string(Self.rawEmail)]],
      failingQuery: failingLookup ? "information_schema.TABLES" : nil,
      queryAnswer: Self.mysqlCatalog)
    var ruled = Self.entry(.mysql)
    ruled.config.maskRules = [try ColumnMaskRule(pattern: rule, style: .email)]
    let entry = ruled
    let id = entry.id
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let historySwitch = historySwitch
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: history,
      historyEnabled: { historySwitch.enabled }, gate: gate)
    let read = await runQuery(service, id, "SELECT * FROM \(table)")
    await pool.closeAll()

    #expect(!read.isError, "\(read.text)")
    #expect(read.text.contains(Self.rawEmail) == !masked, "\(read.text)")
    #expect(read.text.contains(Self.maskedEmail) == masked, "\(read.text)")
    #expect(factory.statements.contains { $0.contains("information_schema.TABLES") })
  }

  @Test("A cut MCP cell of a partial style shows the full mask, never the end of its prefix")
  func cutCellMasksFully() async throws {
    let long = String(repeating: "x", count: 3_000) + "1234"
    let factory = Self.emailFactory(oid: 100, value: long)
    let manager = DatabaseConnectionManager(
      sessionFactory: factory, readLimits: MCPConnectionPool.readLimits)
    try await manager.connect(config: Self.pgConfig(maskRules: try Self.emailRule(.lastFour)))
    let result = try await manager.execute(
      userSQL: "SELECT email FROM users", policy: ProtectionPolicy(protectionLevel: .readOnly))
    await manager.disconnect()
    #expect(result.rows == [[.string(ColumnMaskRule.maskText)]])
  }

  @Test("SQLite origins name the table: users.email is masked, orders.email is not")
  func sqliteOrigins() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-mask-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    config.maskRules = try Self.emailRule()
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    for sql in [
      "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)",
      "CREATE TABLE orders (id INTEGER PRIMARY KEY, email TEXT)",
      "INSERT INTO users VALUES (1, '\(Self.rawEmail)')",
      "INSERT INTO orders VALUES (1, 'bob@example.com')",
    ] {
      _ = try await manager.executeInternal(sql)
    }
    let result = try await manager.execute(
      userSQL: "SELECT users.email, orders.email FROM users, orders",
      policy: ProtectionPolicy(protectionLevel: .none))
    await manager.disconnect()
    #expect(result.columns.map(\.masked) == [true, false])
    #expect(result.rows == [[.string(Self.maskedEmail), .string("bob@example.com")]])
  }

  @Test("A manager connected without rules masks once another config saves the rule to the row")
  func savedRuleReachesLiveManager() async throws {
    let name = "MCPToolServiceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let live = Self.pgConfig()
    #expect(SessionManager.saveConnection(live, defaults: defaults, passwords: NoPasswordStore()))
    let manager = DatabaseConnectionManager(sessionFactory: Self.emailFactory(oid: 100))
    await manager.setSavedMaskRules { config in
      UserDefaults(suiteName: name).map { SavedMaskRules.rules(for: config, defaults: $0) } ?? []
    }
    try await manager.connect(config: live)
    func read() async throws -> [[CellValue]] {
      try await manager.execute(
        userSQL: "SELECT email FROM users", policy: ProtectionPolicy(protectionLevel: .none)
      ).rows
    }
    #expect(try await read() == [[.string(Self.rawEmail)]])

    // Saved from another window: the other config carries the rule, this one does not
    let other = Self.pgConfig(maskRules: try Self.emailRule())
    #expect(SessionManager.saveConnection(other, defaults: defaults, passwords: NoPasswordStore()))
    #expect(try await read() == [[.string(Self.maskedEmail)]])
    await manager.disconnect()
  }
}
