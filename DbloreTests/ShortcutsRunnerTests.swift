// ShortcutsRunnerTests.swift
// Shortcuts has no approval dialog: Add Row under a commit style that needs the user, and a Run
// Query that is not one read, are refused before anything is connected or sent; the pool's
// lookup reads a password only for a row the rule allows; Open Connection refuses rows that
// would run the user's scripts.

import Foundation
import Security
import Testing

@testable import Dblore

/// History rows, readable by the test
private actor HistoryBook: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// How many passwords were read
private final class PasswordReads: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0

  var count: Int { lock.withLock { reads } }

  func read(_ config: ConnectionConfig) -> String? {
    lock.withLock { reads += 1 }
    return "secret"
  }
}

@MainActor
@Suite("Shortcuts runner")
struct ShortcutsRunnerTests {
  private let factory = FakeDatabaseSessionFactory(
    capabilities: .contract(), columns: [ColumnInfo(name: "n", type: "integer")],
    rows: [[.int(1)]])
  private let history = HistoryBook()

  private static func entry(
    name: String = "Orders", style: CommitStyle = .immediate
  ) -> ConnectionHistoryEntry {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, name: name, safeMode: .silent,
      protectedMode: false)
    config.applyCommitStyle(style)
    return ConnectionHistoryEntry(config: config)
  }

  private func runner(
    _ rows: [ConnectionHistoryEntry], factory: FakeDatabaseSessionFactory? = nil,
    password: @escaping @Sendable (ConnectionConfig) throws -> String? = { _ in nil }
  ) -> ShortcutsRunner {
    let allowed = Set(rows.map(\.id))
    return ShortcutsRunner(
      rule: HeadlessAccessRule(gate: AIAccessGate(), lockSource: LockRegistry()),
      saved: { rows }, caller: { .shortcuts(enabled: true, allowlist: allowed) },
      defaultCommitStyle: { .immediate }, recorder: history, historyEnabled: { true },
      password: password, sessionFactory: factory ?? self.factory)
  }

  @Test(
    "Add Row is refused before any send when the commit style needs the user",
    arguments: [CommitStyle.confirm, .review, .password])
  func addRowRefusedUnderCommitStyle(_ style: CommitStyle) async {
    let entry = Self.entry(style: style)
    let runner = runner([entry])
    await #expect(throws: ShortcutsRunner.Refusal.commitStyle(style)) {
      try await runner.addRow(connectionID: entry.id, table: "orders", values: #"{"n": 1}"#)
    }
    #expect(factory.sessions.isEmpty)
    #expect(await history.entries.isEmpty)
    await runner.pool.closeAll()
  }

  @Test("Run Query refuses a write before any send and records the refusal as Shortcuts")
  func runQueryRefusesWrite() async throws {
    let entry = Self.entry()
    let runner = runner([entry])
    await #expect(throws: ReadOnlyQueryGuard.Refusal.notRead) {
      try await runner.runQuery(connectionID: entry.id, sql: "DELETE FROM orders")
    }
    #expect(factory.sessions.isEmpty)
    let refused = await history.entries
    #expect(refused.map(\.source) == [.shortcuts])
    #expect(refused.map(\.status) == [.error])

    // A read on the same runner does reach the database
    let csv = try await runner.runQuery(connectionID: entry.id, sql: "SELECT n FROM orders")
    #expect(factory.sessions.count == 1)
    #expect(csv.hasPrefix("n\r\n1\r\n1 row."))
    #expect(csv.hasSuffix(MCPResultEncoder.dataNotice))
    await runner.pool.closeAll()
  }

  @Test("Run Query writes a naive column's wall clock and a zoned column as ISO 8601 UTC")
  func runQueryDateShapes() async throws {
    // 2026-10-15 12:00:00.123 UTC
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123))
    let dates = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      columns: [
        ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
        ColumnInfo(name: "zoned", type: "timestamptz"),
      ],
      rows: [[date, date]])
    let entry = Self.entry()
    let runner = runner([entry], factory: dates)
    let csv = try await runner.runQuery(
      connectionID: entry.id, sql: "SELECT naive, zoned FROM orders")
    #expect(
      csv.hasPrefix("naive,zoned\r\n2026-10-15 12:00:00.123,2026-10-15T12:00:00.123Z\r\n1 row."))
    await runner.pool.closeAll()
  }

  @Test("The pool's lookup reads a password only for a row Shortcuts may use")
  func lookupReadsPasswordAfterRule() async throws {
    let allowed = Self.entry(name: "Allowed")
    let other = Self.entry(name: "Other")
    let reads = PasswordReads()
    let rule = HeadlessAccessRule(gate: AIAccessGate(), lockSource: LockRegistry())
    let allowlist: Set<UUID> = [allowed.id]
    let lookup = { (enabled: Bool) in
      rule.entryLookup(
        saved: { [allowed, other] },
        caller: { .shortcuts(enabled: enabled, allowlist: allowlist) },
        password: reads.read)
    }
    #expect(try await lookup(true)(other.id) == nil)
    #expect(try await lookup(false)(allowed.id) == nil)
    #expect(reads.count == 0)
    let found = try await lookup(true)(allowed.id)
    #expect(found?.id == allowed.id)
    #expect(found?.config.password == "secret")
    #expect(reads.count == 1)
  }

  @Test("A row whose saved password the Keychain cannot read is refused with that reason")
  func unreadablePasswordRefused() async {
    let entry = Self.entry()
    let runner = runner([entry]) { _ in
      throw ConnectionPasswordError.unreadable(errSecInteractionNotAllowed)
    }
    await #expect(throws: MCPConnectionError.passwordStoreUnreadable) {
      try await runner.runQuery(connectionID: entry.id, sql: "SELECT n FROM orders")
    }
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }

  @Test("Open Connection refuses a row with a password command, as the actions run here do")
  func openRefusesPasswordCommand() async throws {
    var scripted = Self.entry()
    scripted.config.passwordCommandScript = "pw.sh"
    let plain = Self.entry(name: "Plain")
    let runner = runner([scripted, plain])
    await #expect(throws: ShortcutsRunner.Refusal.opensWithScripts) {
      try await runner.openableEntry(id: scripted.id)
    }
    #expect(try await runner.openableEntry(id: plain.id).id == plain.id)
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }

  /// Regression: Add Row into a PostgreSQL `public` table names its schema in the INSERT it
  /// sends and records, never the bare table the user's search_path would resolve
  @Test("Add Row into public.t sends and records INSERT INTO \"public\".\"t\"")
  func addRowQualifiesPublicSchema() async throws {
    let catalog = FakeDatabaseSessionFactory(
      capabilities: .contract(),
      queryAnswer: { sql, _ in
        if sql.contains("pg_stat_get_live_tuples") {
          return FakeQueryAnswer(
            columns: [],
            rows: [[.string("public"), .string("t"), .null, .bool(false), .null, .null]])
        }
        if sql.contains("c.oid::pg_catalog.int8") {
          return FakeQueryAnswer(columns: [], rows: [[.int(1), .null]])
        }
        if sql.contains("attgenerated") {
          return FakeQueryAnswer(
            columns: [],
            rows: [
              [
                .int(1), .string("n"), .string("integer"), .bool(false), .null, .string(""),
                .string(""), .null,
              ]
            ])
        }
        return nil
      })
    let entry = Self.entry()
    let runner = runner([entry], factory: catalog)
    #expect(try await runner.addRow(connectionID: entry.id, table: "t", values: #"{"n": 1}"#) == 1)
    let insert = #"INSERT INTO "public"."t" ("n") VALUES "#
    #expect(
      catalog.statements.filter { $0.hasPrefix("INSERT") }.map { $0.hasPrefix(insert) } == [true])
    #expect(await history.entries.map { $0.sql.hasPrefix(insert) } == [true])
    await runner.pool.closeAll()
  }

  /// Regression A5: Add Row reads naive timestamp text as the wall clock it shows, never as
  /// local time shifted to UTC, and zoned text as the display zone's time; text for a type with
  /// no date value (or SQLite's) stays as typed
  @Test(
    "Add Row stores naive timestamp text as its wall clock",
    arguments: [
      (DatabaseType.postgresql, "timestamp", nil, true, 1_792_065_600),
      (.postgresql, "timestamp(6) without time zone", nil, true, 1_792_065_600),
      (.postgresql, "timestamp(3) with time zone", nil, false, 1_792_040_400),
      (.postgresql, "timestamp with time zone", nil, false, 1_792_040_400),
      (.postgresql, "timestamptz", nil, false, 1_792_040_400),
      (.mysql, "datetime", "datetime(6)", true, nil),
      (.mysql, "timestamp", "timestamp", false, 1_792_040_400),
      (.mysql, "timestamp", "timestamp(6)", false, 1_792_040_400),
      (.duckdb, "TIMESTAMP_NS", nil, true, nil), (.sqlite, "TIMESTAMP", nil, false, nil),
    ] as [(DatabaseType, String, String?, Bool, Double?)])
  func addRowNaiveTimestamp(
    engine: DatabaseType, dataType: String, columnType: String?, wallClock: Bool,
    stagedDate: Double?
  ) throws {
    let type = columnType ?? dataType
    #expect(ShortcutsRunner.isWallClock(type: type, engine: engine) == wallClock)
    let structure = TableStructure(
      tableID: .postgresql(oid: 1), schema: "s", name: "t",
      columns: [
        TableStructure.Column(
          ordinal: 1, name: "at", dataType: dataType, isNullable: true, columnType: columnType)
      ], indexes: [], constraints: [])
    let text = "2026-10-15 12:00:00"
    let typed = try CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      try ShortcutsRunner.cellValues(["at": text], structure: structure, engine: engine)["at"]
    }
    // The instant of the wall clock or display zone time, or the text as typed for the server
    #expect(
      typed == (stagedDate.map { .date(Date(timeIntervalSince1970: $0)) } ?? .string(text)))
    if wallClock { #expect(typed?.displayString(wallClock: true) == text) }
  }

  /// A NUMERIC, an INTEGER, a DOUBLE PRECISION, a NUMERIC named `a"b` and a TEXT column
  private static let numberTable = TableStructure(
    tableID: .postgresql(oid: 1), schema: "s", name: "t",
    columns: [
      TableStructure.Column(
        ordinal: 1, name: "amount", dataType: "numeric", isNullable: true,
        columnType: "numeric(40,2)"),
      TableStructure.Column(ordinal: 2, name: "id", dataType: "integer", isNullable: true),
      TableStructure.Column(
        ordinal: 3, name: "ratio", dataType: "double precision", isNullable: true),
      TableStructure.Column(ordinal: 4, name: "a\"b", dataType: "numeric", isNullable: true),
      TableStructure.Column(ordinal: 5, name: "note", dataType: "text", isNullable: true),
    ], indexes: [], constraints: [])

  /// Add Row's values for `json`, typed for `numberTable`
  private static func addRowValues(_ json: String) throws -> [String: CellValue] {
    try ShortcutsRunner.cellValues(
      ShortcutsRunner.parseValues(json), structure: numberTable, engine: .postgresql)
  }

  /// Regression: a JSON number went through Double, so a NUMERIC lost digits and its scale
  @Test("Add Row binds a JSON number into NUMERIC by its own token text, made plain")
  func addRowNumericTokenText() throws {
    let forty = "1234567890123456789012345678901234567890"
    let cases: [(String, String)] = [
      ("12345678901234567890.12", "12345678901234567890.12"), ("19.90", "19.90"),
      (forty, forty), ("1e20", "100000000000000000000"), ("2.5e-7", "0.00000025"),
      ("1E+2", "100"), ("-1.5e-3", "-0.0015"), ("1.5e1", "15"),
    ]
    for (token, plain) in cases {
      #expect(try Self.addRowValues(#"{"amount": \#(token)}"#)["amount"] == .decimal(plain))
    }
    // Other columns keep v0.9.0's number text
    let other = try Self.addRowValues(#"{"id": 1.0, "ratio": 1e300}"#)
    #expect(other["id"] == .int(1))
    #expect(other["ratio"] == .double(1e300))
    #expect(try Self.addRowValues(#"{"id": 1e3}"#)["id"] == .int(1000))
    // Escaped keys map to their columns; text inside a string is never read as a number
    let keyed = try Self.addRowValues(
      #"{"note": "\"amount\": 1.5, ", "a\"b": 7.50, "amount": 0.10}"#)
    #expect(keyed["note"] == .string(#""amount": 1.5, "#))
    #expect(keyed["a\"b"] == .decimal("7.50"))
    #expect(keyed["amount"] == .decimal("0.10"))
    // A repeated key binds the value JSONSerialization chose, never the other one
    let parsed = try #require(
      try ShortcutsRunner.parseValues(#"{"amount": 1.10, "amount": 2.20}"#)["amount"])
    #expect(parsed.numberToken == nil)
    #expect(parsed.text == "1.1" || parsed.text == "2.2")
  }

  @Test("Add Row refuses a NUMERIC exponent too long to write out, without overflow")
  func addRowRefusesLongExponent() throws {
    let refusal = ShortcutsRunner.Refusal.decimalTooLong(column: "amount")
    #expect(refusal.errorDescription?.contains("plain digits in a JSON string") == true)
    #expect(throws: refusal) { try Self.addRowValues(#"{"amount": -1e1001}"#) }
    for token in ["1e-1001", "0e9223372036854775807"] {
      let json = #"{"amount": \#(token)}"#
      if let parsed = try? ShortcutsRunner.parseValues(json) {
        #expect(throws: refusal, "\(token)") {
          try ShortcutsRunner.cellValues(parsed, structure: Self.numberTable, engine: .postgresql)
        }
      } else {
        #expect(throws: ShortcutsRunner.Refusal.valuesNotObject, "\(token)") {
          try ShortcutsRunner.parseValues(json)
        }
      }
    }
  }

  @Test("Open Connection refuses a row with a pre-connect or post-disconnect script")
  func openRefusesConnectionScripts() async throws {
    var preConnect = Self.entry(name: "Pre")
    preConnect.config.preConnectScript = "pre.sh"
    var postDisconnect = Self.entry(name: "Post")
    postDisconnect.config.postDisconnectScript = "post.sh"
    let runner = runner([preConnect, postDisconnect])
    for row in [preConnect, postDisconnect] {
      await #expect(throws: ShortcutsRunner.Refusal.opensWithScripts) {
        try await runner.openableEntry(id: row.id)
      }
    }
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }
}
