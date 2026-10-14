// MySQLNIOSpikeTests.swift
// Phase 2.3 spike: what mysql-nio 1.9.1 actually does against the docker fixtures
// (MySQL 8.4 on 3307, MariaDB 11.4 on 3308). Each test asserts the observed behavior and
// prints the numbers behind it ("SPIKE ..." lines). Opt-in: TEST_RUNNER_MYSQL_TESTS=1, plus
// TEST_RUNNER_MYSQL_TLS_TESTS=1 for the TLS cases.

import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@Suite(.requiresMySQL, .serialized)
struct MySQLNIOSpikeTests {
  // MARK: - Q1 caching_sha2_password

  /// A fresh caching_sha2 user starts with an empty server cache (CREATE USER, no FLUSH
  /// PRIVILEGES: that would empty the cache of every user other suites log in with). Over plain
  /// TCP the fork refuses full authentication unless allowPublicKeyRetrieval is on; with it the
  /// RSA key path runs, then the next connect gets fast auth (20-byte scramble).
  @Test("Q1 caching_sha2 over plain TCP: full auth through the RSA key request, then fast auth")
  func cachingSha2PlainTCP() async throws {
    let user = "spike_plain"
    let password = "spike-plain-7c1d"
    try await Spike.withFreshUser(user, password: password) {
      let refused = Spike.LogCapture()
      let error = await Spike.connectError(
        port: TestMySQLDatabase.port, username: user, password: password, tls: nil,
        allowPublicKeyRetrieval: false, logger: refused.logger)
      #expect(error != nil)
      #expect(refused.contains("public key retrieval not allowed"))
      #expect(!refused.contains("sending request_public_key"))
      Spike.record("SPIKE Q1 plain: cold cache, no key retrieval: \(Spike.describe(error))")

      let full = Spike.LogCapture()
      let fullTime = try await Spike.timed {
        try await Spike.withConnection(
          port: TestMySQLDatabase.port, username: user, password: password, logger: full.logger
        ) { conn async throws in
          #expect(
            try await Spike.scalar(conn, "SELECT CURRENT_USER()")?.hasPrefix("\(user)@") == true)
          #expect(try await Spike.sslCipher(conn) == "")
        }
      }
      #expect(full.contains("sending request_public_key"))
      #expect(full.contains("sent RSA key, sending the encrypted password"))

      let second = Spike.LogCapture()
      let secondTime = try await Spike.timed {
        try await Spike.withConnection(
          port: TestMySQLDatabase.port, username: user, password: password,
          allowPublicKeyRetrieval: false, logger: second.logger
        ) { _ in }
      }
      #expect(second.contains("fast_auth_success"))
      #expect(!second.contains("sending request_public_key"))
      Spike.record(
        "SPIKE Q1 plain: cold cache full auth (RSA) \(fullTime) ms, second connect \(secondTime) ms, fast auth"
      )
    }
  }

  @Test(
    "Q1 caching_sha2 over TLS with CA verification: full auth sends the password over TLS",
    .requiresMySQLTLS)
  func cachingSha2TLS() async throws {
    let user = "spike_tls"
    let password = "spike-tls-3e9a"
    try await Spike.withFreshUser(user, password: password) {
      let full = Spike.LogCapture()
      let fullTime = try await Spike.timed {
        try await Spike.withConnection(
          port: TestMySQLDatabase.port, username: user, password: password, tls: try Spike.tls(),
          logger: full.logger
        ) { conn async throws in
          let cipher = try await Spike.sslCipher(conn)
          let version = try await Spike.status(conn, "Ssl_version")
          #expect(cipher?.isEmpty == false)
          Spike.record("SPIKE Q1 tls: cipher \(cipher ?? "-") version \(version ?? "-")")
        }
      }
      #expect(full.contains("perform_full_authentication on TLS, sending password in cleartext"))

      // The fork's 20-byte scramble: the cached login now gets fast auth over TLS too.
      let second = Spike.LogCapture()
      try await Spike.withConnection(
        port: TestMySQLDatabase.port, username: user, password: password, tls: try Spike.tls(),
        logger: second.logger
      ) { _ in }
      #expect(second.contains("fast_auth_success"))
      #expect(!second.contains("sending password in cleartext"))
      Spike.record(
        "SPIKE Q1 tls: cold cache full auth \(fullTime) ms, second connect fast auth")
    }

    // Negative control: the library default (system roots) rejects the fixture CA.
    let error = await Spike.connectError(
      port: TestMySQLDatabase.port, tls: .makeClientConfiguration())
    #expect(error is NIOSSLError)
    Spike.record("SPIKE Q1 tls default config error: \(String(describing: error))")
  }

  /// The RSA path XORs the password with the same 21-byte seed, so bytes from index 20 on are
  /// scrambled differently from the server's 20-byte nonce.
  @Test("Q1 caching_sha2 with a 32-character password: plain TCP (RSA) vs TLS")
  func cachingSha2LongPassword() async throws {
    let password = "abcdefghijklmnopqrstuvwxyz012345"
    try await Spike.withConnection(port: TestMySQLDatabase.port, username: "root") {
      root async throws in
      try await root.simpleQuery("DROP USER IF EXISTS 'spike_long'@'%'").get()
      try await root.simpleQuery(
        "CREATE USER 'spike_long'@'%' IDENTIFIED WITH caching_sha2_password BY '\(password)'"
      ).get()
      try await root.simpleQuery("GRANT USAGE ON *.* TO 'spike_long'@'%'").get()
      try await root.simpleQuery("GRANT SELECT ON dblore_test.* TO 'spike_long'@'%'").get()

      var anyTLS = TLSConfiguration.makeClientConfiguration()
      anyTLS.certificateVerification = .none
      let plain = await Spike.connectError(
        port: TestMySQLDatabase.port, username: "spike_long", password: password, tls: nil)
      let tls = await Spike.connectError(
        port: TestMySQLDatabase.port, username: "spike_long", password: password, tls: anyTLS)
      try await root.simpleQuery("DROP USER 'spike_long'@'%'").get()
      Spike.record(
        "SPIKE Q1 32-char password: plain TCP (RSA) \(Spike.describe(plain)); TLS \(Spike.describe(tls))"
      )
      #expect(tls == nil)
      // The dblore fork of mysql-nio uses the 20-byte scramble (was ERROR 1045 on 1.9.1).
      #expect(plain == nil)
    }
  }

  // MARK: - Q2 mysql_native_password

  @Test("Q2 mysql_native_password on MariaDB 11.4")
  func nativePasswordMariaDB() async throws {
    let capture = Spike.LogCapture()
    try await Spike.withConnection(port: TestMySQLDatabase.mariaDBPort, logger: capture.logger) {
      conn async throws in
      #expect(try await Spike.scalar(conn, "SELECT VERSION()")?.contains("MariaDB") == true)
      #expect(try await Spike.scalar(conn, "SELECT 1") == "1")
    }
    #expect(capture.contains("mysql_native_password sent OK"))
    Spike.record("SPIKE Q2 auth trace: \(capture.lines.filter { $0.contains("native") })")
  }

  // MARK: - Q3 TLS custom CA and mTLS

  @Test("Q3 mTLS with in-memory PEM as the REQUIRE X509 user", .requiresMySQLTLS)
  func mutualTLS() async throws {
    try await Spike.withConnection(
      port: TestMySQLDatabase.port, username: TestMySQLDatabase.x509Username,
      password: TestMySQLDatabase.x509Password, tls: try Spike.tls(clientCertificate: true)
    ) { conn async throws in
      let user = try await Spike.scalar(conn, "SELECT CURRENT_USER()")
      #expect(user?.hasPrefix("dblore_x509@") == true)
      #expect(try await Spike.sslCipher(conn)?.isEmpty == false)
    }

    let plain = await Spike.connectError(
      port: TestMySQLDatabase.port, username: TestMySQLDatabase.x509Username,
      password: TestMySQLDatabase.x509Password, tls: nil)
    let noCertificate = await Spike.connectError(
      port: TestMySQLDatabase.port, username: TestMySQLDatabase.x509Username,
      password: TestMySQLDatabase.x509Password, tls: try Spike.tls())
    #expect(Spike.serverCode(plain) == 1045)
    #expect(Spike.serverCode(noCertificate) == 1045)
    Spike.record(
      "SPIKE Q3 x509 plain: \(Spike.describe(plain)); TLS without client cert: \(Spike.describe(noCertificate))"
    )
  }

  // MARK: - Q4 KILL QUERY

  @Test(
    "Q4 KILL QUERY interrupts SLEEP and keeps the session and its transaction",
    arguments: [
      Spike.Server.mysql, .mariadb,
    ])
  func killQuery(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { control async throws in
      try await Spike.withConnection(port: server.port) { conn async throws in
        let id = try #require(try await Spike.scalar(conn, "SELECT CONNECTION_ID()"))
        try await conn.simpleQuery("DROP TABLE IF EXISTS spike_kill").get()
        try await conn.simpleQuery("CREATE TABLE spike_kill (id INT PRIMARY KEY)").get()

        for prepared in [true, false] {
          let outcome = try await Spike.killedSleep(
            conn, control: control, id: id, prepared: prepared)
          Spike.record(
            "SPIKE Q4 \(server) prepared=\(prepared): \(outcome.result) after kill \(outcome.ms) ms"
          )
          #expect(outcome.ms < 2000)
          #expect(try await Spike.scalar(conn, "SELECT 1") == "1")
        }

        try await conn.simpleQuery("START TRANSACTION").get()
        try await conn.simpleQuery("INSERT INTO spike_kill VALUES (1)").get()
        let outcome = try await Spike.killedSleep(conn, control: control, id: id, prepared: false)
        #expect(outcome.ms < 2000)
        #expect(try await Spike.scalar(conn, "SELECT COUNT(*) FROM spike_kill") == "1")
        #expect(try await Spike.scalar(control, "SELECT COUNT(*) FROM spike_kill") == "0")
        try await conn.simpleQuery("ROLLBACK").get()
        #expect(try await Spike.scalar(conn, "SELECT COUNT(*) FROM spike_kill") == "0")
        Spike.record("SPIKE Q4 \(server) in transaction: \(outcome.result), row survived the kill")
        try await conn.simpleQuery("DROP TABLE spike_kill").get()
      }
    }
  }

  // MARK: - Q5 capped read

  // MARK: - Q6 affected rows

  @Test("Q6 affected rows for a same-value UPDATE", arguments: [Spike.Server.mysql, .mariadb])
  func affectedRows(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { conn async throws in
      try await conn.simpleQuery("DROP TABLE IF EXISTS spike_rows").get()
      try await conn.simpleQuery("CREATE TABLE spike_rows (id INT PRIMARY KEY, v INT)").get()
      try await conn.simpleQuery("INSERT INTO spike_rows VALUES (1, 1)").get()

      func preparedUpdate(_ value: Int) async throws -> UInt64? {
        let affected = Spike.Box<UInt64?>(nil)
        try await conn.query(
          "UPDATE spike_rows SET v = ? WHERE id = 1", [MySQLData(int: value)],
          onMetadata: { affected.value = $0.affectedRows }
        ).get()
        return affected.value
      }
      let same = try await preparedUpdate(1)
      let rowCountSame = try await Spike.scalar(conn, "SELECT ROW_COUNT()")
      let changed = try await preparedUpdate(2)
      #expect(same == 0)
      #expect(changed == 1)

      // A hand-written COM_QUERY command sees the OK packet's info string.
      let probe = Spike.ProbeQuery("UPDATE spike_rows SET v = 2 WHERE id = 1")
      try await conn.send(probe, logger: conn.logger).get()
      #expect(probe.ok?.affectedRows == 0)
      #expect(probe.ok?.info.hasPrefix("Rows matched: 1  Changed: 0") == true)
      Spike.record(
        "SPIKE Q6 \(server): same-value \(same.map(String.init) ?? "nil"), ROW_COUNT() \(rowCountSame ?? "nil"), changed \(changed.map(String.init) ?? "nil"), probe info '\(probe.ok?.info ?? "-")'"
      )
      try await conn.simpleQuery("DROP TABLE spike_rows").get()
    }
  }

  // MARK: - Q7 column definitions

  @Test(
    "Q7 column definitions expose schema, orgTable and orgName",
    arguments: [
      Spike.Server.mysql, .mariadb,
    ])
  func columnDefinitions(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { conn async throws in
      try await conn.simpleQuery("DROP TABLE IF EXISTS spike_cols").get()
      try await conn.simpleQuery("CREATE TABLE spike_cols (id INT PRIMARY KEY, v VARCHAR(10))")
        .get()
      try await conn.simpleQuery("INSERT INTO spike_cols VALUES (1, 'a')").get()
      let sql = "SELECT t.id AS alias, t.v, t.id + 1 AS expr FROM spike_cols t"

      for format in ["binary", "text"] {
        let rows =
          format == "binary"
          ? try await conn.query(sql).get() : try await conn.simpleQuery(sql).get()
        let columns = try #require(rows.first?.columnDefinitions)
        #expect(columns[0].schema == "dblore_test")
        #expect(columns[0].table == "t")
        #expect(columns[0].orgTable == "spike_cols")
        #expect(columns[0].name == "alias")
        #expect(columns[0].orgName == "id")
        #expect(columns[0].flags.contains(.PRIMARY_KEY))
        #expect(columns[2].orgTable == "")
        Spike.record(
          "SPIKE Q7 \(server) \(format): "
            + columns.map {
              "\($0.schema).\($0.orgTable).\($0.orgName) as \($0.table).\($0.name) [\($0.columnType) charset \($0.characterSet.rawValue) flags \($0.flags.rawValue)]"
            }.joined(separator: ", ")
        )
      }

      // Zero rows: the public API hands out columns only with rows.
      let empty = try await conn.query("SELECT id, v FROM spike_cols WHERE 1 = 0").get()
      #expect(empty.isEmpty)
      let probe = Spike.ProbeQuery("SELECT id, v FROM spike_cols WHERE 1 = 0")
      try await conn.send(probe, logger: conn.logger).get()
      #expect(probe.columns.map(\.name) == ["id", "v"])
      #expect(probe.rowCount == 0)

      // Collation id > 255 does not fit the decoder's one-byte charset + zero byte check.
      let collation =
        server == .mysql ? "utf8mb4_ja_0900_as_cs" : "utf8mb4_uca1400_ai_ci"
      let wide = await Spike.attempt {
        try await conn.simpleQuery("SELECT CAST('a' AS CHAR) COLLATE \(collation) AS c").get()
      }
      let charsetName = try await Spike.scalar(conn, "SELECT @@collation_connection")
      Spike.record(
        "SPIKE Q7 \(server) zero-row columns via public API: none, via custom command: \(probe.columns.map(\.name)); collation \(collation): \(wide.outcome); collation_connection \(charsetName ?? "-")"
      )
      try await conn.simpleQuery("DROP TABLE spike_cols").get()
    }
  }

  // MARK: - Q8 type decoding

  @Test("Q8 type decoding, text vs binary protocol", arguments: [Spike.Server.mysql, .mariadb])
  func typeDecoding(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { conn async throws in
      try await conn.simpleQuery("SET SESSION sql_mode = ''").get()
      try await conn.simpleQuery("DROP TABLE IF EXISTS spike_types").get()
      try await conn.simpleQuery(
        """
        CREATE TABLE spike_types (
          d DECIMAL(20,6), dt DATETIME(6), tm TIME, tn TIME, zd DATE, zdt DATETIME,
          b BIT(10), j JSON, bl BLOB, e ENUM('a','b'), s SET('x','y'), y YEAR, g GEOMETRY)
        """
      ).get()
      try await conn.simpleQuery(
        """
        INSERT INTO spike_types VALUES (
          12345.678900, '2024-01-02 03:04:05.123456', '25:30:15', '-01:02:03', '0000-00-00',
          '0000-00-00 00:00:00', b'1010101010', '{"a": 1}', x'00FF10', 'b', 'x,y', 2024,
          ST_GeomFromText('POINT(1 2)'))
        """
      ).get()
      let sql = "SELECT * FROM spike_types"
      let binary = try #require(try await conn.query(sql).get().first)
      let text = try #require(try await conn.simpleQuery(sql).get().first)

      var report: [String: [String: String]] = [:]
      for (format, row) in [("binary", binary), ("text", text)] {
        for (index, column) in row.columnDefinitions.enumerated() {
          let data = Spike.cell(row, index)
          report[column.name, default: [:]][format] = Spike.summary(data)
        }
      }
      for name in ["d", "dt", "tm", "tn", "zd", "zdt", "b", "j", "bl", "e", "s", "y", "g"] {
        Spike.record(
          "SPIKE Q8 \(server) \(name): binary \(report[name]?["binary"] ?? "-") | text \(report[name]?["text"] ?? "-")"
        )
      }

      // Pinned findings (see the printed matrix for the rest).
      let tmBinary = try #require(Spike.cell(binary, 2).time)
      #expect(tmBinary.hour == 1)  // TIME '25:30:15' binary: the days field is dropped
      #expect(Spike.cell(text, 2).string == "25:30:15")
      #expect(Spike.cell(text, 3).string == "-01:02:03")
      #expect(Spike.cell(binary, 4).buffer?.readableBytes == 0)  // zero DATE in binary
      #expect(Spike.cell(text, 4).string == "0000-00-00")
      #expect(Spike.cell(binary, 0).string == nil)  // DECIMAL binary .string is nil
      #expect(Spike.cell(binary, 0).decimal == Decimal(string: "12345.678900"))
      try await conn.simpleQuery("DROP TABLE spike_types").get()
    }
  }

  // MARK: - Q9 CALL

  @Test(
    "Q9 CALL of a procedure that returns a result set",
    arguments: [
      Spike.Server.mysql, .mariadb,
    ])
  func callProcedure(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { conn async throws in
      try await conn.simpleQuery("DROP PROCEDURE IF EXISTS spike_proc").get()
      try await conn.simpleQuery("DROP PROCEDURE IF EXISTS spike_noop").get()
      try await conn.simpleQuery("CREATE PROCEDURE spike_proc() BEGIN SELECT 1 AS one; END").get()
      try await conn.simpleQuery("CREATE PROCEDURE spike_noop() BEGIN DO 1; END").get()

      let text = await Spike.attempt { try await conn.simpleQuery("CALL spike_proc()").get() }
      let prepared = await Spike.attempt { try await conn.query("CALL spike_proc()").get() }
      let noop = await Spike.attempt { try await conn.simpleQuery("CALL spike_noop()").get() }
      let alive = try await Spike.scalar(conn, "SELECT 1")
      Spike.record(
        "SPIKE Q9 \(server): text \(text.outcome), prepared \(prepared.outcome), no-result CALL \(noop.outcome), session after \(alive ?? "dead")"
      )
      #expect(Spike.serverCode(text.error) == 1312)
      #expect(alive == "1")
      try await conn.simpleQuery("DROP PROCEDURE spike_proc").get()
      try await conn.simpleQuery("DROP PROCEDURE spike_noop").get()
    }
  }

  // MARK: - Q10 multi statements and LOCAL INFILE

  @Test(
    "Q10 CLIENT_MULTI_STATEMENTS and CLIENT_LOCAL_FILES are off",
    arguments: [
      Spike.Server.mysql, .mariadb,
    ])
  func multiStatementsAndLocalInfile(server: Spike.Server) async throws {
    #expect(!MySQLProtocol.CapabilityFlags.clientDefault.contains(.CLIENT_MULTI_STATEMENTS))
    #expect(!MySQLProtocol.CapabilityFlags.clientDefault.contains(.CLIENT_LOCAL_FILES))
    #expect(!MySQLProtocol.CapabilityFlags.clientDefault.contains(.CLIENT_FOUND_ROWS))
    #expect(!MySQLProtocol.CapabilityFlags.clientDefault.contains(.CLIENT_MULTI_RESULTS))

    try await Spike.withConnection(port: server.port, username: "root") { root async throws in
      try await root.simpleQuery("SET GLOBAL local_infile = 1").get()
      do {
        try await Spike.withConnection(port: server.port) { conn async throws in
          let text = await Spike.attempt { try await conn.simpleQuery("SELECT 1; SELECT 2").get() }
          let prepared = await Spike.attempt { try await conn.query("SELECT 1; SELECT 2").get() }
          #expect(Spike.serverCode(text.error) == 1064)
          #expect(Spike.serverCode(prepared.error) == 1064)

          try await conn.simpleQuery("DROP TABLE IF EXISTS spike_load").get()
          try await conn.simpleQuery("CREATE TABLE spike_load (line TEXT)").get()
          let load = await Spike.attempt {
            try await conn.simpleQuery("LOAD DATA LOCAL INFILE '/etc/hosts' INTO TABLE spike_load")
              .get()
          }
          #expect(load.error != nil)
          let loaded = try await Spike.scalar(conn, "SELECT COUNT(*) FROM spike_load")
          #expect(loaded == "0")
          #expect(try await Spike.scalar(conn, "SELECT 1") == "1")
          Spike.record(
            "SPIKE Q10 \(server): multi text \(text.outcome), multi prepared \(prepared.outcome), LOAD DATA LOCAL (server local_infile=1) \(load.outcome)"
          )
          try await conn.simpleQuery("DROP TABLE spike_load").get()
        }
      } catch {
        try? await root.simpleQuery("SET GLOBAL local_infile = 0").get()
        throw error
      }
      try await root.simpleQuery("SET GLOBAL local_infile = 0").get()
    }
  }

  // MARK: - Q11 event loop group lifecycle

  // MARK: - Q12 MariaDB detection and statement timeout

  @Test(
    "Q12 VERSION() detection and statement timeouts",
    arguments: [
      Spike.Server.mysql, .mariadb,
    ])
  func versionAndStatementTimeout(server: Spike.Server) async throws {
    try await Spike.withConnection(port: server.port) { conn async throws in
      let version = try #require(try await Spike.scalar(conn, "SELECT VERSION()"))
      #expect(version.contains("MariaDB") == (server == .mariadb))

      let mysqlVariable = await Spike.attempt {
        try await conn.simpleQuery("SET SESSION max_execution_time = 1000").get()
      }
      let mariaVariable = await Spike.attempt {
        try await conn.simpleQuery("SET SESSION max_statement_time = 1").get()
      }
      let sleep = Spike.Box("")
      let sleepMs = try await Spike.timed {
        do {
          sleep.value = try await Spike.scalar(conn, "SELECT SLEEP(5)") ?? "nil"
        } catch {
          sleep.value = Spike.describe(error)
        }
      }
      let heavy = Spike.Box("")
      try await conn.simpleQuery(
        server == .mysql
          ? "SET SESSION cte_max_recursion_depth = 100000000"
          : "SET SESSION max_recursive_iterations = 100000000"
      ).get()
      let heavyMs = try await Spike.timed {
        do {
          heavy.value =
            try await Spike.scalar(
              conn,
              "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50000000) SELECT COUNT(*) FROM seq"
            ) ?? "nil"
        } catch {
          heavy.value = Spike.describe(error)
        }
      }
      #expect(try await Spike.scalar(conn, "SELECT 1") == "1")
      Spike.record(
        "SPIKE Q12 \(server): VERSION() '\(version)'; max_execution_time \(mysqlVariable.outcome); max_statement_time \(mariaVariable.outcome); SLEEP(5) -> \(sleep.value) in \(sleepMs) ms; 50M-row CTE -> \(heavy.value) in \(heavyMs) ms"
      )
      if server == .mysql {
        #expect(mysqlVariable.error == nil)
        #expect(Spike.serverCode(mariaVariable.error) == 1193)
      } else {
        #expect(mariaVariable.error == nil)
        #expect(Spike.serverCode(mysqlVariable.error) == 1193)
      }
      #expect(sleepMs < 3000)
      #expect(heavyMs < 3000)
    }
  }
}

// MARK: - Helpers

nonisolated enum Spike {
  enum Server: String, Sendable, CustomStringConvertible {
    case mysql, mariadb
    var port: Int { self == .mysql ? TestMySQLDatabase.port : TestMySQLDatabase.mariaDBPort }
    var description: String { rawValue }
  }

  final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
    @discardableResult
    func mutate<T>(_ body: (inout Value) throws -> T) rethrows -> T {
      try lock.withLock { try body(&stored) }
    }
  }

  /// Captures mysql-nio's trace messages to tell which auth path ran.
  final class LogCapture: Sendable {
    private let box = Box<[String]>([])
    var logger: Logger {
      let box = self.box
      var logger = Logger(label: "spike.mysql") { _ in Handler(box: box) }
      logger.logLevel = .trace
      return logger
    }
    var lines: [String] { box.value }
    func contains(_ text: String) -> Bool { lines.contains { $0.contains(text) } }

    struct Handler: LogHandler {
      let box: Box<[String]>
      var metadata: Logger.Metadata = [:]
      var logLevel: Logger.Level = .trace
      subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
      }
      func log(event: LogEvent) { box.mutate { $0.append(event.message.description) } }
    }
  }

  /// COM_QUERY that keeps the column definitions without rows and the raw OK packet.
  final class ProbeQuery: MySQLCommand, @unchecked Sendable {
    let sql: String
    var columnCount: Int?
    var columns: [MySQLProtocol.ColumnDefinition41] = []
    var rowCount = 0
    var ok: MySQLProtocol.OK_Packet?

    init(_ sql: String) { self.sql = sql }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
      MySQLCommandState(response: [
        try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)
      ])
    }

    func handle(
      packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags
    ) throws
      -> MySQLCommandState
    {
      if packet.isError {
        let error = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
        return MySQLCommandState(done: true, error: MySQLError.server(error))
      }
      guard let count = columnCount else {
        if packet.isOK {
          ok = try Self.decodeOK(&packet, capabilities)
          return MySQLCommandState(done: true)
        }
        let response = try packet.decode(
          MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
        columnCount = Int(response.columnCount)
        return MySQLCommandState()
      }
      if columns.count < count {
        columns.append(
          try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
        return MySQLCommandState()
      }
      if packet.isEOF {
        ok = try Self.decodeOK(&packet, capabilities)
        return MySQLCommandState(done: true)
      }
      rowCount += 1
      return MySQLCommandState()
    }

    private static func decodeOK(
      _ packet: inout MySQLPacket, _ capabilities: MySQLProtocol.CapabilityFlags
    ) throws -> MySQLProtocol.OK_Packet {
      try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
    }
  }

  static func tls(clientCertificate: Bool = false) throws -> TLSConfiguration {
    var config = TLSConfiguration.makeClientConfiguration()
    let ca = try String(contentsOf: TestMySQLDatabase.caCertificate, encoding: .utf8)
    config.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(ca.utf8), format: .pem)])
    if clientCertificate {
      let certificate = try String(contentsOf: TestMySQLDatabase.clientCertificate, encoding: .utf8)
      let key = try String(contentsOf: TestMySQLDatabase.clientKey, encoding: .utf8)
      config.certificateChain = [
        .certificate(try NIOSSLCertificate(bytes: Array(certificate.utf8), format: .pem))
      ]
      config.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem))
    }
    return config
  }

  static func connect(
    port: Int,
    username: String = TestMySQLDatabase.username,
    password: String = TestMySQLDatabase.password,
    tls: TLSConfiguration? = nil,
    allowPublicKeyRetrieval: Bool = true,
    logger: Logger = Logger(label: "spike.mysql"),
    on eventLoop: (any EventLoop)? = nil
  ) async throws -> MySQLConnection {
    try await MySQLConnection.connect(
      to: try SocketAddress(ipAddress: TestMySQLDatabase.host, port: port),
      username: username,
      database: TestMySQLDatabase.database,
      password: password,
      tlsConfiguration: tls,
      serverHostname: tls == nil ? nil : "localhost",
      // Driver spike against the local fixture: keep the RSA full-auth path reachable.
      allowPublicKeyRetrieval: allowPublicKeyRetrieval,
      logger: logger,
      on: eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
    ).get()
  }

  /// Closes on every path: MySQLConnection asserts it was closed before deinit.
  static func withConnection<T>(
    port: Int,
    username: String = TestMySQLDatabase.username,
    password: String = TestMySQLDatabase.password,
    tls: TLSConfiguration? = nil,
    allowPublicKeyRetrieval: Bool = true,
    logger: Logger = Logger(label: "spike.mysql"),
    on eventLoop: (any EventLoop)? = nil,
    _ body: (MySQLConnection) async throws -> T
  ) async throws -> T {
    let conn = try await connect(
      port: port, username: username, password: password, tls: tls,
      allowPublicKeyRetrieval: allowPublicKeyRetrieval, logger: logger, on: eventLoop)
    do {
      let result = try await body(conn)
      try await conn.close().get()
      return result
    } catch {
      try? await conn.close().get()
      throw error
    }
  }

  static func connectError(
    port: Int,
    username: String = TestMySQLDatabase.username,
    password: String = TestMySQLDatabase.password,
    tls: TLSConfiguration?,
    allowPublicKeyRetrieval: Bool = true,
    logger: Logger = Logger(label: "spike.mysql")
  ) async -> (any Error)? {
    do {
      try await withConnection(
        port: port, username: username, password: password, tls: tls,
        allowPublicKeyRetrieval: allowPublicKeyRetrieval, logger: logger
      ) { _ in }
      return nil
    } catch {
      return error
    }
  }

  /// Runs `body` with a new caching_sha2 user on the MySQL server, so its auth cache starts
  /// empty without touching the cache of the users other suites log in with.
  static func withFreshUser(
    _ user: String, password: String, _ body: () async throws -> Void
  ) async throws {
    try await withConnection(port: TestMySQLDatabase.port, username: "root") {
      root async throws in
      try await root.simpleQuery("DROP USER IF EXISTS '\(user)'@'%'").get()
      try await root.simpleQuery(
        "CREATE USER '\(user)'@'%' IDENTIFIED WITH caching_sha2_password BY '\(password)'"
      ).get()
      try await root.simpleQuery(
        "GRANT SELECT ON \(TestMySQLDatabase.database).* TO '\(user)'@'%'"
      ).get()
    }
    let result = await attempt(body)
    try await withConnection(port: TestMySQLDatabase.port, username: "root") {
      root async throws in
      try await root.simpleQuery("DROP USER IF EXISTS '\(user)'@'%'").get()
    }
    try result.get()
  }

  /// First column of the first row, read as text (text protocol).
  static func scalar(_ conn: MySQLConnection, _ sql: String) async throws -> String? {
    let rows = try await conn.simpleQuery(sql).get()
    guard var buffer = rows.first?.values.first ?? nil else { return nil }
    return buffer.readString(length: buffer.readableBytes)
  }

  static func status(_ conn: MySQLConnection, _ name: String) async throws -> String? {
    let rows = try await conn.simpleQuery("SHOW SESSION STATUS LIKE '\(name)'").get()
    guard let row = rows.first, row.values.count > 1, var buffer = row.values[1] else {
      return nil
    }
    return buffer.readString(length: buffer.readableBytes)
  }

  static func sslCipher(_ conn: MySQLConnection) async throws -> String? {
    try await status(conn, "Ssl_cipher")
  }

  static func cell(_ row: MySQLRow, _ index: Int) -> MySQLData {
    let column = row.columnDefinitions[index]
    return MySQLData(
      type: column.columnType, format: row.format, buffer: row.values[index],
      isUnsigned: column.flags.contains(.COLUMN_UNSIGNED))
  }

  /// Never uses MySQLData.description: it force-unwraps and traps on odd values.
  static func summary(_ data: MySQLData) -> String {
    let bytes = data.buffer.map { Array($0.readableBytesView) } ?? []
    let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
    let time = data.time.map {
      "\($0.year.map(String.init) ?? "_")-\($0.month.map(String.init) ?? "_")-\($0.day.map(String.init) ?? "_") \($0.hour.map(String.init) ?? "_"):\($0.minute.map(String.init) ?? "_"):\($0.second.map(String.init) ?? "_").\($0.microsecond.map(String.init) ?? "_")"
    }
    return
      "type \(data.type) len \(bytes.count) hex \(hex) string \(data.string.map { "'\($0)'" } ?? "nil") int \(data.int.map(String.init) ?? "nil") decimal \(data.decimal.map { "\($0)" } ?? "nil") time \(time ?? "nil")"
  }

  static func serverCode(_ error: (any Error)?) -> UInt16? {
    switch error as? MySQLError {
    case .server(let packet): packet.errorCode.rawValue
    case .invalidSyntax: 1064
    case .duplicateEntry: 1062
    default: nil
    }
  }

  static func describe(_ error: (any Error)?) -> String {
    guard let error else { return "no error" }
    if case .server(let packet) = error as? MySQLError {
      return "server \(packet.errorCode.rawValue) \(packet.errorMessage)"
    }
    return String(describing: error)
  }

  struct KillOutcome {
    let result: String
    let ms: Int
  }

  /// Runs SLEEP(10) on `conn`, waits until the server shows it, then KILL QUERY from `control`.
  static func killedSleep(
    _ conn: MySQLConnection, control: MySQLConnection, id: String, prepared: Bool
  ) async throws -> KillOutcome {
    let sleep = Task { () -> String in
      do {
        let rows =
          prepared
          ? try await conn.query("SELECT SLEEP(10)").get()
          : try await conn.simpleQuery("SELECT SLEEP(10)").get()
        guard let row = rows.first else { return "no rows" }
        return "SLEEP returned \(cell(row, 0).int.map(String.init) ?? "nil")"
      } catch {
        return describe(error)
      }
    }
    var running = false
    for _ in 0..<40 where !running {
      running =
        try await scalar(
          control,
          "SELECT COUNT(*) FROM information_schema.processlist WHERE id = \(id) AND info LIKE 'SELECT SLEEP%'"
        ) == "1"
      if !running { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(running)
    let start = ContinuousClock.now
    try await control.simpleQuery("KILL QUERY \(id)").get()
    let result = await sleep.value
    return KillOutcome(result: result, ms: milliseconds(ContinuousClock.now - start))
  }

  /// Prints and appends to $TMPDIR/dblore-mysql-spike.txt (xcodebuild drops test host stdout).
  static func record(_ line: String) {
    print(line)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-mysql-spike.txt")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  static func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
  }

  static func timed(_ body: () async throws -> Void) async throws -> Int {
    let start = ContinuousClock.now
    try await body()
    return milliseconds(ContinuousClock.now - start)
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }
}

extension Result where Failure == any Error {
  fileprivate var error: (any Error)? {
    if case .failure(let error) = self { return error }
    return nil
  }

  fileprivate var outcome: String {
    switch self {
    case .success(let value):
      if let rows = value as? [MySQLRow] { return "ok (\(rows.count) rows)" }
      return "ok"
    case .failure(let error): return Spike.describe(error)
    }
  }
}
