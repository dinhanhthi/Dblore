// ResultExportRunnerTests.swift
// The all-rows result export without a server: the read runs again on a separate snapshot
// connection (fake sessions for the tab and for the export), with the tab session's state, and
// every row is written; what may not run that way is refused before anything connects; Cancel
// keeps the destination and deletes the temporary file.

import Foundation
import Testing

@testable import Dblore

@Suite("ResultExportRunnerTests")
@MainActor
struct ResultExportRunnerTests {
  private typealias Manager = DatabaseConnectionManager

  // MARK: - All rows on a snapshot

  @Test func postgresReadIsWrittenWholeInsideAReadOnlySnapshotWithTheTabSearchPath()
    async throws
  {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The tab's result showed 10 rows; the table has 25
    let tab = try await Self.postgresTab(
      searchPath: "sales, public", timeZone: "Europe/Paris", dateStyle: "SQL, DMY")
    let export = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: Self.columns, rows: Self.rows(25))
    let runner = Self.runner(tab: tab, config: Self.postgresConfig, export: export, directory)
    let destination = directory.appendingPathComponent("out.csv")
    let reports = Recorder<Int>()

    let written = try await runner.write(
      Self.request(), to: destination, hasStagedChanges: false,
      mask: { row in [row[0], .string("masked")] }, progress: { reports.append($0) })

    #expect(written == 25)
    #expect(reports.values.last == 25)
    let lines = try String(contentsOf: destination, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 26)
    #expect(lines.first == "id,email")
    #expect(lines.dropFirst().allSatisfy { $0.hasSuffix(",masked") })
    let session = try #require(export.sessions.first)
    #expect(
      session.statements == [
        "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
        "SET LOCAL statement_timeout = 0", "SET LOCAL lock_timeout = 0",
        "SET LOCAL idle_in_transaction_session_timeout = 0",
        Manager.SearchPathPin.putBackSQL, Manager.resultExportTimeZoneSQL,
        Manager.resultExportDateStyleSQL, Self.sql, "ROLLBACK",
      ])
    let pin = try #require(session.statements.firstIndex(of: Manager.SearchPathPin.putBackSQL))
    #expect(session.statementBinds[pin] == [.text("sales, public")])
    let zone = try #require(session.statements.firstIndex(of: Manager.resultExportTimeZoneSQL))
    #expect(session.statementBinds[zone] == [.text("Europe/Paris")])
    // The tab's DateStyle: date literals in the query parse as they did there
    let dates = try #require(session.statements.firstIndex(of: Manager.resultExportDateStyleSQL))
    #expect(session.statementBinds[dates] == [.text("SQL, DMY")])
    #expect(!session.statements.contains { $0.contains("search_path = ''") })
    #expect(!session.statements.contains { $0.hasPrefix("SET LOCAL") && !$0.contains("timeout") })
    #expect(export.sessions.allSatisfy { $0.didClose })
    #expect(try Self.leftovers(in: directory) == ["out.csv"])
  }

  @Test func mysqlSessionTakesTheTabDatabaseTimeZoneAndSessionSettings() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = try await Self.mysqlTab(
      database: "shop", timeZone: "Europe/Paris",
      sqlMode: "ONLY_FULL_GROUP_BY,PIPES_AS_CONCAT,STRICT_TRANS_TABLES",
      groupConcatMaxLength: .string("18446744073709551615"), divPrecisionIncrement: .int(8))
    let export = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mysql.capabilities, columns: Self.columns, rows: Self.rows(3),
      queryAnswer: { sql, _ in
        sql == "SELECT VERSION()"
          ? FakeQueryAnswer(
            columns: [ColumnInfo(name: "VERSION()", type: "text")], rows: [[.string("8.4.3")]])
          : nil
      })
    let runner = Self.runner(tab: tab, config: Self.mysqlConfig, export: export, directory)

    let written = try await runner.write(
      Self.request(format: .json), to: directory.appendingPathComponent("out.json"),
      hasStagedChanges: false, mask: { $0 })

    #expect(written == 3)
    let session = try #require(export.sessions.first)
    #expect(
      session.statements.filter { $0 != "SELECT VERSION()" } == [
        "SET SESSION max_execution_time = 0",
        "SET SESSION innodb_lock_wait_timeout = 31536000",
        "SET SESSION lock_wait_timeout = 31536000", "USE `shop`",
        "SET time_zone = 'Europe/Paris'",
        "SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,PIPES_AS_CONCAT,STRICT_TRANS_TABLES'",
        "SET SESSION group_concat_max_len = 18446744073709551615",
        "SET SESSION div_precision_increment = 8",
        "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", Self.sql, "ROLLBACK",
      ])
    #expect(export.sessions.allSatisfy { $0.didClose })
  }

  @Test func newPostgresSessionStateReadIsCatalogQualified() {
    #expect(PostgresQualificationLint.violations(Manager.resultExportPostgresStateSQL).isEmpty)
    #expect(PostgresQualificationLint.violations(Manager.resultExportTimeZoneSQL).isEmpty)
    #expect(PostgresQualificationLint.violations(Manager.resultExportDateStyleSQL).isEmpty)
    // Temporary tables still there, not a temporary schema left by one that was dropped
    #expect(
      Manager.resultExportPostgresStateSQL.hasPrefix(
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE relnamespace "
          + "OPERATOR(pg_catalog.=) pg_catalog.pg_my_temp_schema()), "))
  }

  // MARK: - Refused before connecting

  @Test func writesScriptsAndParametersAreRefusedBeforeConnecting() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = try await Self.postgresTab()
    let export = FakeDatabaseSessionFactory(capabilities: .contract())
    let runner = Self.runner(tab: tab, config: Self.postgresConfig, export: export, directory)
    let sent = tab.factory.statements.count
    let cases: [(String, any Error)] = [
      ("UPDATE users SET email = 'x'", ReadOnlyQueryGuard.Refusal.notRead),
      ("SELECT 1; SELECT 2", ReadOnlyQueryGuard.Refusal.multipleStatements),
      ("SELECT * FROM users WHERE id = :id", ResultExportError.parameters),
    ]
    for (sql, expected) in cases {
      do {
        _ = try await runner.write(
          Self.request(sql: sql), to: directory.appendingPathComponent("out.csv"),
          hasStagedChanges: false, mask: { $0 })
        Issue.record("Expected \(sql) to be refused")
      } catch {
        #expect(error.localizedDescription == expected.localizedDescription, "\(sql)")
      }
    }
    #expect(export.sessions.isEmpty)
    #expect(tab.factory.statements.count == sent)
    #expect(try Self.leftovers(in: directory).isEmpty)
    #expect(
      ResultExportError.openChanges.errorDescription
        == "Commit or discard the open changes first: a separate connection would not see them.")
  }

  @Test func openChangesAndATemporarySchemaAreRefusedBeforeConnecting() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("out.csv")
    let export = FakeDatabaseSessionFactory(capabilities: .contract())

    let staged = try await Self.postgresTab()
    await #expect(throws: ResultExportError.openChanges) {
      _ = try await Self.runner(
        tab: staged, config: Self.postgresConfig, export: export, directory
      ).write(Self.request(), to: destination, hasStagedChanges: true, mask: { $0 })
    }

    let open = try await Self.postgresTab()
    _ = try await open.manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    await #expect(throws: ResultExportError.openChanges) {
      _ = try await Self.runner(
        tab: open, config: Self.postgresConfig, export: export, directory
      ).write(Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
    }

    let temporary = try await Self.postgresTab(temporarySchema: true)
    await #expect(throws: ResultExportError.temporaryTables) {
      _ = try await Self.runner(
        tab: temporary, config: Self.postgresConfig, export: export, directory
      ).write(Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
    }

    // SET ROLE: current_user is not session_user
    let role = try await Self.postgresTab(otherRole: true)
    await #expect(throws: ResultExportError.otherRole) {
      _ = try await Self.runner(
        tab: role, config: Self.postgresConfig, export: export, directory
      ).write(Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
    }
    #expect(
      ResultExportError.otherRole.errorDescription
        == "This session uses another role (SET ROLE), which a separate connection would not "
        + "use, so all rows cannot be exported.")

    #expect(export.sessions.isEmpty)
    #expect(try Self.leftovers(in: directory).isEmpty)
  }

  @Test func mysqlUserVariablesAndUncarriedSessionStateAreRefusedBeforeConnecting() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("out.csv")
    let export = FakeDatabaseSessionFactory(capabilities: DatabaseType.mysql.capabilities)

    // `@name` outside strings is refused (the offer's reason too); `@@system` and a literal pass
    #expect(throws: ResultExportError.sessionVariables) {
      try ResultExportRunner.checkedRead("SELECT * FROM t WHERE id > @min", dialect: .mysql)
    }
    for sql in [
      "SELECT @@session.time_zone, id FROM t", "SELECT * FROM t WHERE note = '@x'",
      "SELECT `a@b` FROM t", "SELECT id # @x\nFROM t", "SELECT id -- @x\nFROM t",
    ] {
      #expect(try ResultExportRunner.checkedRead(sql, dialect: .mysql) == sql)
    }
    for sql in ["SELECT @`x`", "SELECT 'u'@'h'"] {
      #expect(throws: ResultExportError.sessionVariables, "\(sql)") {
        try ResultExportRunner.checkedRead(sql, dialect: .mysql)
      }
    }
    #expect(
      ResultExportError.sessionVariables.errorDescription
        == "This query uses session variables (@name), which a separate connection would not "
        + "have, so all rows cannot be exported.")
    let tab = try await Self.mysqlTab(database: "shop", timeZone: "SYSTEM")
    await #expect(throws: ResultExportError.sessionVariables) {
      _ = try await Self.runner(tab: tab, config: Self.mysqlConfig, export: export, directory)
        .write(
          Self.request(sql: "SELECT id, email FROM users WHERE id > @min"), to: destination,
          hasStagedChanges: false, mask: { $0 })
    }

    // A time zone or sql_mode that is not plain is never quoted into SET, a setting that is not
    // an integer never written into one; a sql_mode that changes how the app reads the query
    // (ANSI_QUOTES or NO_BACKSLASH_ESCAPES, also as part of ANSI) is refused
    let cases: [(Tab, ResultExportError)] = [
      (try await Self.mysqlTab(timeZone: "+00:00'; --"), .sessionStateUnreadable),
      (try await Self.mysqlTab(sqlMode: "STRICT_TRANS_TABLES'; --"), .sessionStateUnreadable),
      (try await Self.mysqlTab(groupConcatMaxLength: .string("lots")), .sessionStateUnreadable),
      (try await Self.mysqlTab(divPrecisionIncrement: .double(4.5)), .sessionStateUnreadable),
      (
        try await Self.mysqlTab(
          sqlMode: "REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI"),
        .sqlMode
      ),
      (try await Self.mysqlTab(sqlMode: "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES"), .sqlMode),
    ]
    for (tab, expected) in cases {
      let sent = tab.factory.statements.count
      await #expect(throws: expected) {
        _ = try await Self.runner(tab: tab, config: Self.mysqlConfig, export: export, directory)
          .write(Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
      }
      // Only the state read ran on the tab
      #expect(tab.factory.statements.count == sent + 1)
    }
    #expect(
      ResultExportError.sqlMode.errorDescription
        == "This session's sql_mode (ANSI_QUOTES or NO_BACKSLASH_ESCAPES) changes how the query "
        + "is read, so all rows cannot be exported.")

    #expect(export.sessions.isEmpty)
    #expect(try Self.leftovers(in: directory).isEmpty)
  }

  /// The export reads the file on a connection of its own, which sees no TEMP table of the
  /// tab's (and `temp` shadows `main`)
  @Test func sqliteTemporaryTableIsRefusedBeforeConnecting() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: directory.appendingPathComponent("db.sqlite").path,
      username: "", protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    _ = try await manager.executeInternal("CREATE TABLE users (id INTEGER, email TEXT)")
    _ = try await manager.executeInternal("CREATE TEMP TABLE users (id INTEGER, email TEXT)")
    let export = FakeDatabaseSessionFactory(capabilities: DatabaseType.sqlite.capabilities)
    let runner = ResultExportRunner(
      tabManager: manager, config: config, material: nil, sshCredential: nil,
      sessionFactory: export, temporaryDirectory: directory)

    await #expect(throws: ResultExportError.temporaryTables) {
      _ = try await runner.write(
        Self.request(), to: directory.appendingPathComponent("out.csv"),
        hasStagedChanges: false, mask: { $0 })
    }
    #expect(export.sessions.isEmpty)
    await manager.disconnect()
  }

  // MARK: - Refused on the snapshot

  @Test func otherColumnsAreRefusedAndTheDestinationIsKept() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("out.csv")
    try Data("old".utf8).write(to: destination)
    let tab = try await Self.postgresTab()
    let export = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      rows: Self.rows(2))
    let runner = Self.runner(tab: tab, config: Self.postgresConfig, export: export, directory)

    await #expect(throws: ResultExportError.columnsChanged) {
      _ = try await runner.write(
        Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
    }
    #expect(
      ResultExportError.columnsChanged.errorDescription
        == "The query returns other columns now. Run it again, then export.")
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(export.statements.last == "ROLLBACK")
    #expect(export.sessions.allSatisfy { $0.didClose })
    #expect(try Self.leftovers(in: directory) == ["out.csv"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelKeepsTheDestinationAndDeletesTheTemporaryFile() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("out.csv")
    try Data("old".utf8).write(to: destination)
    let tab = try await Self.postgresTab()
    let export = AnnouncingFactory(
      FakeDatabaseSessionFactory(
        capabilities: .contract(), columns: Self.columns, rows: Self.rows(5), slowQueries: true))
    let runner = ResultExportRunner(
      tabManager: tab.manager, config: Self.postgresConfig, material: nil, sshCredential: nil,
      sessionFactory: export, temporaryDirectory: directory)
    let task = Task {
      try await runner.write(
        Self.request(), to: destination, hasStagedChanges: false, mask: { $0 })
    }
    var made = export.sessions.makeAsyncIterator()
    let session = try #require(await made.next())
    await session.waitUntilQueryStarted()
    let temporary = try #require(try Self.leftovers(in: directory).first { $0 != "out.csv" })
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(temporary).path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(session.statements.last == "ROLLBACK")
    #expect(session.didClose)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try Self.leftovers(in: directory) == ["out.csv"])
  }

  // MARK: - Mask plan

  /// Rule `users.email`: the email from users (OID 100) is masked, the one from orders (400) is
  /// not unless the origin lookup fails (fail closed); `id` has no rule. The plan masks the raw
  /// rows exactly as the grid's read does and records the same masked columns.
  @Test(
    arguments: [
      (ColumnMaskRule.Style.full, false), (.null, false), (.lastFour, false), (.email, false),
      (.email, true),
    ])
  func maskPlanMasksRowsAsTheGridRead(
    style: ColumnMaskRule.Style, failingLookup: Bool
  )
    async throws
  {
    let columns = [
      ColumnInfo(name: "id", type: "int4"), Self.emailColumn(oid: 100), Self.emailColumn(oid: 400),
    ]
    let rows: [[CellValue]] = [
      [.int(1), .string("alice@example.com"), .string("bob.smith@example.com")],
      [.int(2), .string("carol@example.org"), .null],
    ]
    let tab = try await Self.postgresTab(
      maskRules: [try ColumnMaskRule(pattern: "users.email", style: style)],
      failingLookup: failingLookup, columns: columns, rows: rows)
    let grid = try await tab.manager.execute(
      userSQL: "SELECT u.id, u.email, o.email FROM users u JOIN orders o USING (id)",
      policy: ProtectionPolicy(protectionLevel: .none))

    let plan = await tab.manager.maskPlan(for: columns)

    #expect(rows.map(plan.mask) == grid.rows)
    #expect(plan.maskedColumns == grid.columns.indices.filter { grid.columns[$0].masked })
    #expect(plan.maskedColumns == (failingLookup ? [1, 2] : [1]))
    #expect(grid.rows.map { $0[1] } == rows.map { style.masked($0[1]) })
    #expect(grid.rows.map { $0[0] } == rows.map { $0[0] })
  }

  /// The file masks `users.email` from users, and from orders when the lookup fails
  @Test(arguments: [(UInt32(100), false), (400, true)])
  func maskedColumnIsMaskedInTheFile(oid: UInt32, failingLookup: Bool) async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = try await Self.postgresTab(
      maskRules: [try ColumnMaskRule(pattern: "users.email", style: .full)],
      failingLookup: failingLookup)
    let export = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: Self.columns, rows: Self.rows(3))
    let runner = Self.runner(tab: tab, config: Self.postgresConfig, export: export, directory)
    var request = Self.request()
    request.columns = [ColumnInfo(name: "id", type: "int4"), Self.emailColumn(oid: oid)]
    let plan = await tab.manager.maskPlan(for: request.columns)
    let destination = directory.appendingPathComponent("out.csv")

    _ = try await runner.write(
      request, to: destination, hasStagedChanges: false, mask: { plan.mask($0) })

    let lines = try String(contentsOf: destination, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    #expect(lines == ["id,email"] + (1...3).map { "\($0),\(ColumnMaskRule.maskText)" })
  }

  // MARK: - Helpers

  private static let sql = "SELECT id, email FROM users ORDER BY id"

  private static let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "email", type: "text"),
  ]

  private static func rows(_ count: Int) -> [[CellValue]] {
    (1...count).map { [.int($0), .string("user\($0)@example.com")] }
  }

  private static func request(
    sql: String = sql, format: ExportFormat = .csv
  ) -> ResultExportRequest {
    ResultExportRequest(
      sql: sql, columns: columns, format: .download(ExportOptions(format: format)))
  }

  private static let postgresConfig = ConnectionConfig(
    host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
    protectionLevel: .none, safeMode: .silent, protectedMode: false)

  private static let mysqlConfig = ConnectionConfig(
    databaseType: .mysql, host: "fake", port: 1, database: "db", username: "u", password: "p",
    sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)

  private struct Tab {
    let manager: DatabaseConnectionManager
    let factory: FakeDatabaseSessionFactory
  }

  /// A connected PostgreSQL tab whose session answers its state (temporary tables, search_path,
  /// time zone, DateStyle, current and session user: `otherRole` after SET ROLE) and the mask origin
  /// lookup (`relations`: OID 100 is `public.users`, 400 `public.orders`; it fails with
  /// `failingLookup`). User SQL answers `columns` and `rows`.
  private static func postgresTab(
    searchPath: String = "\"$user\", public", timeZone: String = "UTC",
    dateStyle: String = "ISO, MDY",
    temporarySchema: Bool = false, otherRole: Bool = false,
    maskRules: [ColumnMaskRule] = [], failingLookup: Bool = false, columns: [ColumnInfo] = [],
    rows: [[CellValue]] = []
  ) async throws -> Tab {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: columns, rows: rows,
      failingQuery: failingLookup ? "pg_inherits" : nil,
      queryAnswer: { sql, binds in
        if sql.contains("pg_inherits"), case .text(let list)? = binds.first {
          return FakeQueryAnswer(
            columns: ["oid", "nspname", "relname", "relkind", "has_parent"].map {
              ColumnInfo(name: $0, type: "text")
            },
            rows: list.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
              .split(separator: ",").compactMap { Int($0) }
              .compactMap { oid in
                Self.relations[oid].map {
                  [.int(oid), .string("public"), .string($0), .string("r"), .bool(false)]
                }
              })
        }
        guard sql == Manager.resultExportPostgresStateSQL else { return nil }
        return FakeQueryAnswer(
          columns: [
            "temporary", "search_path", "TimeZone", "DateStyle", "current_user", "session_user",
          ].map { ColumnInfo(name: $0, type: "text") },
          rows: [
            [
              .bool(temporarySchema), .string(searchPath), .string(timeZone), .string(dateStyle),
              .string(otherRole ? "admin" : "ana"), .string("ana"),
            ]
          ])
      })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    var config = postgresConfig
    config.maskRules = maskRules
    try await manager.connect(config: config)
    return Tab(manager: manager, factory: factory)
  }

  private nonisolated static let relations: [Int: String] = [100: "users", 400: "orders"]

  /// An `email` column read from relation `oid`
  private static func emailColumn(oid: UInt32) -> ColumnInfo {
    ColumnInfo(
      name: "email", type: "text",
      origin: ColumnOrigin(tableID: .postgresql(oid: oid), columnOrdinal: 2))
  }

  /// A connected MySQL tab whose session answers its database, time zone, sql_mode,
  /// group_concat_max_len and div_precision_increment
  private static func mysqlTab(
    database: String = "shop", timeZone: String = "SYSTEM",
    sqlMode: String = "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES",
    groupConcatMaxLength: CellValue = .int(1024), divPrecisionIncrement: CellValue = .int(4)
  ) async throws -> Tab {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mysql.capabilities,
      queryAnswer: { sql, _ in
        sql == Manager.resultExportMySQLStateSQL
          ? FakeQueryAnswer(
            columns: [
              "DATABASE()", "@@session.time_zone", "@@session.sql_mode",
              "@@session.group_concat_max_len", "@@session.div_precision_increment",
            ].map { ColumnInfo(name: $0, type: "text") },
            rows: [
              [
                .string(database), .string(timeZone), .string(sqlMode), groupConcatMaxLength,
                divPrecisionIncrement,
              ]
            ])
          : nil
      })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: mysqlConfig)
    return Tab(manager: manager, factory: factory)
  }

  private static func runner(
    tab: Tab, config: ConnectionConfig, export: any DatabaseSessionFactory, _ directory: URL
  ) -> ResultExportRunner {
    ResultExportRunner(
      tabManager: tab.manager, config: config, material: nil, sshCredential: nil,
      sessionFactory: export, temporaryDirectory: directory)
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-export-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func leftovers(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }
}

/// Yields each session it makes, so a test can wait for the export's session without polling
private final class AnnouncingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let inner: FakeDatabaseSessionFactory
  let sessions: AsyncStream<FakeDatabaseSession>
  private let continuation: AsyncStream<FakeDatabaseSession>.Continuation

  init(_ inner: FakeDatabaseSessionFactory) {
    self.inner = inner
    (sessions, continuation) = AsyncStream.makeStream()
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let session = inner.makeSession(config: config)
    if let fake = session as? FakeDatabaseSession { continuation.yield(fake) }
    return session
  }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Value] = []

  func append(_ value: Value) { lock.withLock { recorded.append(value) } }
  var values: [Value] { lock.withLock { recorded } }
}
