// MySQLTableImportTests.swift
// CSV / TSV / JSON import through TableImportModel into MySQL 8.4 (3307) and MariaDB 11.4 (3308):
// a new table (BIGINT, DOUBLE, BOOLEAN, DATE, DATETIME(6) from ISO 8601 with `Z` or an offset,
// LONGTEXT), an existing table, a ~1 MB text value (packet size), a bad row that rolls the
// existing-table import back, Protected mode (rows pending; CREATE TABLE refused because it
// commits implicitly), timestamps converted only for DATE / DATETIME / TIMESTAMP destinations,
// INSERT chunks kept under the session's max_allowed_packet, and the keyed modes (Update,
// Insert or Update) on an integer, a utf8mb4_unicode_ci, a latin1 and a BIGINT key. Opt-in
// (`.requiresMySQL`). Tables use `imp_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLTableImportTests {
  typealias Server = MySQLSessionTests.Server

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  private static func model(
    _ text: String, extension fileExtension: String
  ) async throws -> TableImportModel {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).\(fileExtension)")
    try Data(text.utf8).write(to: url)
    let model = TableImportModel()
    await model.loadFile(url)
    return model
  }

  /// Runs `body` with a connected manager, a view model on it, and a fresh table name; the
  /// table is dropped and the manager disconnected on every path.
  private func withConnection(
    _ server: Server, protectedMode: Bool = false,
    _ body: (DatabaseConnectionManager, NotebookViewModel, String) async throws -> Void
  ) async throws {
    let table = "imp_\(UUID().uuidString.prefix(8).lowercased())"
    var config = MySQLSessionTests.config(port: server.port)
    config.safeMode = .silent
    config.protectedMode = protectedMode
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    do {
      try await body(manager, viewModel, table)
    } catch {
      await cleanup(table, manager: manager)
      throw error
    }
    await cleanup(table, manager: manager)
  }

  private func cleanup(_ table: String, manager: DatabaseConnectionManager) async {
    if await !manager.transactionSnapshot().isIdle {
      try? await manager.rollbackAppTransaction()
    }
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
    await manager.disconnect()
  }

  private static func instant(_ text: String) -> CellValue {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return .date(formatter.date(from: text)!)
  }

  @Test(
    "CSV creates a typed table: booleans, dates, timestamps with Z or an offset",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func newTableCSV(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      let csv = """
        id,price,active,born,seen,name
        1,1.5,true,2024-01-02,2024-01-02T03:04:05Z,Ada
        2,2.25,false,2024-02-29,2024-01-02T05:04:05.5+02:00,Bob
        """
      let model = try await Self.model(csv + "\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: table)
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      let types = try await manager.executeInternal(
        """
        SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(table)' ORDER BY ORDINAL_POSITION
        """)
      #expect(
        types.rows.map {
          $0.map { cell -> String in
            if case .string(let text) = cell { return text.lowercased() }
            return "\(cell)"
          }
        } == [
          ["id", "bigint"], ["price", "double"], ["active", "tinyint"], ["born", "date"],
          ["seen", "datetime"], ["name", "longtext"],
        ])
      let result = try await manager.executeInternal(
        "SELECT id, price, active, born, seen, name FROM \(table) ORDER BY id")
      #expect(
        result.rows == [
          [
            .int(1), .double(1.5), .int(1), .string("2024-01-02"),
            Self.instant("2024-01-02T03:04:05.000Z"), .string("Ada"),
          ],
          [
            .int(2), .double(2.25), .int(0), .string("2024-02-29"),
            Self.instant("2024-01-02T03:04:05.500Z"), .string("Bob"),
          ],
        ])
    }
  }

  @Test(
    "JSON and TSV append to an existing table", .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [Server.mysql, .mariadb])
  func existingTable(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (id BIGINT PRIMARY KEY, name VARCHAR(20), ok BOOLEAN)")
      let json = try await Self.model(
        "{\"id\":1,\"name\":\"Ada\",\"ok\":true}\n{\"id\":2,\"name\":\"Bob\",\"ok\":false}\n",
        extension: "json")
      defer { try? FileManager.default.removeItem(at: json.fileURL!) }
      json.destination = .existing(schema: nil, table: table)
      #expect(await json.submit(to: viewModel), "\(json.errorMessage ?? "")")
      let tsv = try await Self.model("id\tname\tok\n3\tCy\ttrue\n", extension: "tsv")
      defer { try? FileManager.default.removeItem(at: tsv.fileURL!) }
      tsv.destination = .existing(schema: nil, table: table)
      #expect(await tsv.submit(to: viewModel), "\(tsv.errorMessage ?? "")")
      let result = try await manager.executeInternal(
        "SELECT id, name, ok FROM \(table) ORDER BY id")
      #expect(
        result.rows == [
          [.int(1), .string("Ada"), .int(1)], [.int(2), .string("Bob"), .int(0)],
          [.int(3), .string("Cy"), .int(1)],
        ])
    }
  }

  @Test(
    "Booleans and timestamps into existing text columns keep the file text", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func existingTextColumns(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (id BIGINT PRIMARY KEY, ok VARCHAR(10), seen TEXT, at DATETIME)")
      let model = try await Self.model(
        "id,ok,seen,at\n1,true,2024-01-02T03:04:05Z,2024-01-02T03:04:05Z\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      #expect(model.mappings.map(\.kind) == [.integer, .boolean, .timestamp, .timestamp])
      model.destination = .existing(schema: nil, table: table)
      model.tables = try await Self.tables(manager)
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      let result = try await manager.executeInternal("SELECT ok, seen, at FROM \(table)")
      #expect(
        result.rows == [
          [
            .string("true"), .string("2024-01-02T03:04:05Z"),
            Self.instant("2024-01-02T03:04:05.000Z"),
          ]
        ])
    }
  }

  /// Tables with columns, joined like `WorkspaceManager.loadDatabaseSchema`
  private static func tables(_ manager: DatabaseConnectionManager) async throws -> [DatabaseTable] {
    var tables = try await manager.fetchTables()
    let columns = try await manager.fetchAllColumns()
    for index in tables.indices {
      tables[index].columns = columns[tables[index].qualifiedName] ?? []
    }
    return tables
  }

  @Test(
    "A failed new-table import keeps the table: CREATE TABLE commits implicitly", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func failedNewTableKeepsTable(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      let model = try await Self.model("id\n1\nx\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.mappings[0].kind = .integer
      model.destination = .new(schema: nil, table: table)
      #expect(!(await model.submit(to: viewModel)))
      let result = try await manager.executeInternal("SELECT COUNT(*) FROM \(table)")
      #expect(result.rows == [[.int(0)]])
    }
  }

  @Test(
    "A 1 MB text value imports whole", .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [Server.mysql, .mariadb])
  func largeText(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      let big = String(repeating: "abcdefghij", count: 100_000)
      let model = try await Self.model("id,body\n1,\(big)\n2,small\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: table)
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      let result = try await manager.executeInternal(
        "SELECT id, CHAR_LENGTH(body), MD5(body) = MD5(REPEAT('abcdefghij', 100000)) "
          + "FROM \(table) ORDER BY id")
      #expect(result.rows == [[.int(1), .int(1_000_000), .int(1)], [.int(2), .int(5), .int(0)]])
    }
  }

  @Test(
    "A bad row rolls back the whole existing-table import", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func badRowRollsBack(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id BIGINT PRIMARY KEY)")
      let input = "id\n" + (1...1_500).map(String.init).joined(separator: "\n") + "\n1\n"
      let model = try await Self.model(input, extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(!(await model.submit(to: viewModel)))
      #expect(model.errorMessage?.contains("Rows 1001–1501") == true)
      let result = try await manager.executeInternal("SELECT COUNT(*) FROM \(table)")
      #expect(result.rows == [[.int(0)]])
    }
  }

  @Test(
    "Protected mode leaves imported rows pending and refuses CREATE TABLE", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func protectedImport(server: Server) async throws {
    try await withConnection(server, protectedMode: true) { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id BIGINT)")
      let model = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      #expect(!(await manager.transactionSnapshot().isIdle))
      try await manager.rollbackAppTransaction()
      #expect(try await manager.executeInternal("SELECT id FROM \(table)").rows.isEmpty)

      let create = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: create.fileURL!) }
      create.destination = .new(schema: nil, table: table + "_new")
      #expect(!(await create.submit(to: viewModel)))
      #expect(create.errorMessage?.contains("commits implicitly") == true)
      let exists = try await manager.executeInternal(
        """
        SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(table)_new'
        """)
      #expect(exists.rows == [[.int(0)]])
    }
  }

  // MARK: - Timestamp conversion follows the destination type

  @Test("Timestamps convert only for DATE / DATETIME / TIMESTAMP destination columns")
  func timestampConversionByDestinationType() async throws {
    let stamp = "2024-01-02T03:04:05Z"
    let types = [
      "DATETIME(6)", "TIMESTAMP", "DATE", "JSON", "ENUM('2024-01-02T03:04:05Z')", "SET('x')",
      "BINARY(20)", "VARBINARY(40)", "BLOB", "VARCHAR(40)",
    ]
    let names = types.indices.map { "c\($0)" }
    let csv = names.joined(separator: ",") + "\n" + names.map { _ in stamp }.joined(separator: ",")
    let model = try await Self.model(csv + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: model.fileURL!) }
    #expect(model.mappings.allSatisfy { $0.kind == .timestamp })
    model.destination = .existing(schema: nil, table: "t")
    model.tables = [
      DatabaseTable(
        schema: "db", name: "t",
        columns: zip(names, types).map { DatabaseColumn(name: $0, type: $1) })
    ]
    let batch = try await model.prepareBatch(dialect: .mysql, connectionEpoch: 0)
    let converted = "2024-01-02 03:04:05.000000"
    #expect(
      batch.statements.first?.values
        == [converted, converted, converted] + Array(repeating: stamp, count: 7))

    // A new table (DATETIME(6)) and a column the schema does not list still convert.
    model.tables = []
    let unknown = try await model.prepareBatch(dialect: .mysql, connectionEpoch: 0)
    #expect(unknown.statements.first?.values == Array(repeating: converted, count: types.count))
  }

  @Test(
    "Timestamps into JSON / ENUM / SET / VARBINARY keep the file text on the server",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func timestampIntoNonDateColumns(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      let stamp = "2024-01-02T03:04:05Z"
      _ = try await manager.executeInternal(
        """
        CREATE TABLE \(table) (id BIGINT PRIMARY KEY, j JSON, e ENUM('\(stamp)', 'x'),
          s SET('\(stamp)', 'x'), b VARBINARY(40), d DATETIME(6))
        """)
      let model = try await Self.model(
        "id,j,e,s,b,d\n1,\"\"\"\(stamp)\"\"\",\(stamp),\(stamp),\(stamp),\(stamp)\n",
        extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      model.tables = try await Self.tables(manager)
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      let result = try await manager.executeInternal(
        "SELECT CAST(j AS CHAR), e, s, CAST(b AS CHAR), d FROM \(table)")
      #expect(
        result.rows == [
          [
            .string("\"\(stamp)\""), .string(stamp), .string(stamp), .string(stamp),
            Self.instant("2024-01-02T03:04:05.000Z"),
          ]
        ])
    }
  }

  // MARK: - Packet size

  @Test(
    "The session reads @@max_allowed_packet at open", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func sessionReadsMaxAllowedPacket(server: Server) async throws {
    try await withConnection(server) { manager, _, _ in
      let packet = try await manager.executeInternal("SELECT @@max_allowed_packet")
      guard case .int(let expected) = packet.rows.first?.first else {
        Issue.record("no @@max_allowed_packet: \(packet.rows)")
        return
      }
      #expect(await manager.mysqlServerInfo?.maxAllowedPacket == expected)
    }
  }

  @Test(
    "An import larger than the session packet limit is split under it", .requiresMySQL,
    .timeLimit(.minutes(2)), arguments: [Server.mysql, .mariadb])
  func importSplitsUnderPacketLimit(server: Server) async throws {
    // A lower global limit is read by the next session only; it is restored right after that
    // session opens (the value a session read stays its own). 4 MiB stays above every other
    // MySQL suite's statements (the largest is the 1 MB text import).
    let packet = 4 * 1_024 * 1_024
    let root = DatabaseConnectionManager()
    var rootConfig = MySQLSessionTests.config(port: server.port)
    rootConfig.username = "root"
    rootConfig.password = "dblore123"
    try await root.connect(config: rootConfig)
    defer { Task { await root.disconnect() } }
    let original = try await root.executeInternal("SELECT @@GLOBAL.max_allowed_packet").rows
    guard case .int(let restore) = original.first?.first else {
      Issue.record("no global max_allowed_packet: \(original)")
      return
    }
    _ = try await root.executeInternal("SET GLOBAL max_allowed_packet = \(packet)")
    let opened: Result<Void, Error>
    do {
      try await withConnection(server) { manager, viewModel, table in
        _ = try? await root.executeInternal("SET GLOBAL max_allowed_packet = \(restore)")
        #expect(await manager.mysqlServerInfo?.maxAllowedPacket == packet)
        // 1,000 rows of 6 KB: one 6 MB INSERT without the cap, half again the packet limit.
        let body = String(repeating: "x", count: 6_000)
        let csv = "id,body\n" + (1...1_000).map { "\($0),\(body)" }.joined(separator: "\n")
        let model = try await Self.model(csv + "\n", extension: "csv")
        defer { try? FileManager.default.removeItem(at: model.fileURL!) }
        model.destination = .new(schema: nil, table: table)
        #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
        let result = try await manager.executeInternal(
          "SELECT COUNT(*), SUM(CHAR_LENGTH(body)) FROM \(table)")
        #expect(result.rows == [[.int(1_000), .string("6000000")]])
      }
      opened = .success(())
    } catch {
      opened = .failure(error)
    }
    _ = try? await root.executeInternal("SET GLOBAL max_allowed_packet = \(restore)")
    try opened.get()
  }

  // MARK: - Keyed modes

  /// A keyed import of `csv` into the existing `table` in `mode`, its tables and keys loaded
  /// (the primary key is chosen)
  private static func keyedModel(
    _ csv: String, table: String, mode: ImportMode, manager: DatabaseConnectionManager
  ) async throws -> TableImportModel {
    let model = try await Self.model(csv, extension: "csv")
    model.destination = .existing(schema: nil, table: table)
    model.tables = try await Self.tables(manager)
    await model.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    model.selectMode(mode)
    return model
  }

  @Test(
    "Update and Insert or Update match an integer key", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func keyedModes(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (id INT PRIMARY KEY, name VARCHAR(20))")
      _ = try await manager.executeInternal("INSERT INTO \(table) VALUES (1, 'a'), (2, 'b')")
      let rows = {
        try await manager.executeInternal("SELECT id, name FROM \(table) ORDER BY id").rows
      }

      // Update: the counts come before anything is written; 1 is updated, 3 is skipped
      let update = try await Self.keyedModel(
        "id,name\n1,A\n3,C\n", table: table, mode: .update, manager: manager)
      defer { try? FileManager.default.removeItem(at: update.fileURL!) }
      #expect(update.matchKey?.isPrimaryKey == true)
      #expect(await update.prepareImport(for: viewModel), "\(update.errorMessage ?? "")")
      let summary = try #require(update.matchSummary)
      #expect([summary.newRows, summary.existingRows, summary.refusedCount] == [1, 1, 0] as [Int])
      #expect([summary.inserts, summary.updates, summary.skips] == [0, 1, 1] as [Int])
      #expect(try await rows() == [[.int(1), .string("a")], [.int(2), .string("b")]])
      #expect(await update.confirmImport(to: viewModel), "\(update.errorMessage ?? "")")
      #expect(try await rows() == [[.int(1), .string("A")], [.int(2), .string("b")]])

      // Insert or Update: 2 is updated, 4 inserted
      let upsert = try await Self.keyedModel(
        "id,name\n2,B\n4,D\n", table: table, mode: .insertOrUpdate, manager: manager)
      defer { try? FileManager.default.removeItem(at: upsert.fileURL!) }
      #expect(await upsert.submit(to: viewModel), "\(upsert.errorMessage ?? "")")
      #expect(upsert.matchSummary?.inserts == 1)
      #expect(upsert.matchSummary?.updates == 1)
      #expect(
        try await rows() == [
          [.int(1), .string("A")], [.int(2), .string("B")], [.int(4), .string("D")],
        ])
    }
  }

  @Test(
    "Updating a row to the values it holds succeeds through the row check", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func unchangedRowUpdate(server: Server) async throws {
    // MySQL reports 0 affected rows for an UPDATE that changes nothing
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (id INT PRIMARY KEY, name VARCHAR(20))")
      _ = try await manager.executeInternal("INSERT INTO \(table) VALUES (1, 'a')")
      let model = try await Self.keyedModel(
        "id,name\n1,a\n", table: table, mode: .update, manager: manager)
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      #expect(model.errorMessage == nil)
      #expect(model.matchSummary?.updates == 1)
      let result = try await manager.executeInternal("SELECT id, name FROM \(table)")
      #expect(result.rows == [[.int(1), .string("a")]])
    }
  }

  @Test(
    "A utf8mb4_unicode_ci key matches under its collation", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func unicodeCollationKey(server: Server) async throws {
    // The match read's derived table has the connection collation: a key compared without the
    // column's COLLATE fails with error 1267, and 'A' matches 'a' only under the column's
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        """
        CREATE TABLE \(table) (
          code VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci PRIMARY KEY,
          name VARCHAR(20))
        """)
      _ = try await manager.executeInternal("INSERT INTO \(table) VALUES ('a', 'x')")
      let model = try await Self.keyedModel(
        "code,name\nA,y\nb,z\n", table: table, mode: .insertOrUpdate, manager: manager)
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      #expect(model.matchSummary?.existingRows == 1)
      #expect(model.matchSummary?.newRows == 1)
      let result = try await manager.executeInternal(
        "SELECT code, name FROM \(table) ORDER BY code")
      #expect(result.rows == [[.string("a"), .string("y")], [.string("b"), .string("z")]])
    }
  }

  @Test(
    "A latin1 key matches through CONVERT; a value latin1 can't hold is refused for its row",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func latin1Key(server: Server) async throws {
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        """
        CREATE TABLE \(table) (
          code VARCHAR(20) CHARACTER SET latin1 PRIMARY KEY, name VARCHAR(20))
        """)
      _ = try await manager.executeInternal("INSERT INTO \(table) VALUES ('café', 'x')")
      let model = try await Self.keyedModel(
        "code,name\ncafé,y\nnew,z\n日本,w\n", table: table, mode: .insertOrUpdate,
        manager: manager)
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      let summary = try #require(model.matchSummary)
      #expect([summary.newRows, summary.existingRows, summary.refusedCount] == [1, 1, 1] as [Int])
      #expect(
        summary.refused == [
          .init(row: 3, reason: "The code value can't be stored in character set latin1.")
        ])
      let result = try await manager.executeInternal(
        "SELECT code, name FROM \(table) ORDER BY code")
      #expect(result.rows == [[.string("café"), .string("y")], [.string("new"), .string("z")]])
    }
  }

  @Test(
    "A BIGINT key above 2^53 is compared exactly, not as a double", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func bigintKeyPrecision(server: Server) async throws {
    // As doubles, 9007199254740993 and 9007199254740992 are equal
    try await withConnection(server) { manager, viewModel, table in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (id BIGINT PRIMARY KEY, name VARCHAR(20))")
      _ = try await manager.executeInternal(
        "INSERT INTO \(table) VALUES (9007199254740992, 'a')")
      let model = try await Self.keyedModel(
        "id,name\n9007199254740993,b\n", table: table, mode: .insertOrUpdate, manager: manager)
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      #expect(model.matchSummary?.newRows == 1)
      #expect(model.matchSummary?.existingRows == 0)
      let result = try await manager.executeInternal(
        "SELECT id, name FROM \(table) ORDER BY id")
      #expect(
        result.rows == [
          [.int(9_007_199_254_740_992), .string("a")], [.int(9_007_199_254_740_993), .string("b")],
        ])
    }
  }
}
