import Foundation
import Testing

@testable import Dblore

@Suite("Table import PostgreSQL integration", .requiresPostgres, .serialized)
@MainActor
struct TableImportIntegrationTests {
  private static func config(
    protectedMode: Bool = false, protectionLevel: ConnectionProtectionLevel = .none
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port,
      database: TestDatabase.database, username: TestDatabase.username,
      password: TestDatabase.password, sslMode: .disable,
      protectionLevel: protectionLevel, safeMode: .silent,
      protectedMode: protectedMode)
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

  private func withConnection(
    protectedMode: Bool = false, protectionLevel: ConnectionProtectionLevel = .none,
    _ body: (DatabaseConnectionManager, NotebookViewModel, String) async throws -> Void
  ) async throws {
    let table = "imp_\(UUID().uuidString.prefix(8).lowercased())"
    let config = Self.config(protectedMode: protectedMode, protectionLevel: protectionLevel)
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

  @Test("CSV creates a table and imports its rows", .timeLimit(.minutes(1)))
  func newTableCSV() async throws {
    try await withConnection { manager, viewModel, table in
      let model = try await Self.model("id,name\n1,Ada\n2,Bob\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: table)
      #expect(await model.submit(to: viewModel))
      let result = try await manager.executeInternal("SELECT id, name FROM \(table) ORDER BY id")
      #expect(result.rows == [[.int(1), .string("Ada")], [.int(2), .string("Bob")]])
    }
  }

  @Test("JSON appends to an existing table", .timeLimit(.minutes(1)))
  func existingTableJSON() async throws {
    try await withConnection { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id bigint, name text)")
      let model = try await Self.model(
        "{\"id\":1,\"name\":\"Ada\"}\n{\"id\":2,\"name\":\"Bob\"}\n", extension: "json")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(await model.submit(to: viewModel))
      let result = try await manager.executeInternal("SELECT id, name FROM \(table) ORDER BY id")
      #expect(result.rows == [[.int(1), .string("Ada")], [.int(2), .string("Bob")]])
    }
  }

  @Test("Protected mode leaves imported rows pending", .timeLimit(.minutes(1)))
  func protectedImport() async throws {
    try await withConnection(protectedMode: true) { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id bigint)")
      let model = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(await model.submit(to: viewModel))
      let snapshot = await manager.transactionSnapshot()
      #expect(!snapshot.isIdle)
      #expect(!snapshot.pending.isEmpty)
      try await manager.rollbackAppTransaction()
      let result = try await manager.executeInternal("SELECT id FROM \(table)")
      #expect(result.rows.isEmpty)
    }
  }

  @Test("Schema-only protection blocks CREATE before execution", .timeLimit(.minutes(1)))
  func schemaOnly() async throws {
    try await withConnection(protectionLevel: .schemaOnly) { manager, viewModel, table in
      let model = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: table)
      #expect(!(await model.submit(to: viewModel)))
      #expect(model.errorMessage?.contains("Schema change") == true)
      let result = try await manager.executeInternal("SELECT to_regclass('public.\(table)')")
      #expect(result.rows == [[.null]])
    }
  }

  @Test("A bad row rolls back the whole import", .timeLimit(.minutes(1)))
  func badRowRollsBack() async throws {
    try await withConnection { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id bigint PRIMARY KEY)")
      let model = try await Self.model("id\n1\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(!(await model.submit(to: viewModel)))
      #expect(model.errorMessage?.contains("Rows 1–2") == true)
      let result = try await manager.executeInternal("SELECT id FROM \(table)")
      #expect(result.rows.isEmpty)
    }
  }

  @Test(
    "Failed import inside a manual transaction leaves no committable rows", .timeLimit(.minutes(1)))
  func badRowInManualTransaction() async throws {
    try await withConnection { manager, viewModel, table in
      _ = try await manager.executeInternal("CREATE TABLE \(table) (id bigint PRIMARY KEY)")
      let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
      _ = try await manager.execute(userSQL: "BEGIN", policy: policy)
      let input = "id\n" + (1...1000).map(String.init).joined(separator: "\n") + "\n1\n"
      let model = try await Self.model(input, extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: table)
      #expect(!(await model.submit(to: viewModel)))
      _ = try await manager.execute(userSQL: "COMMIT", policy: policy)
      let result = try await manager.executeInternal("SELECT id FROM \(table)")
      #expect(result.rows.isEmpty)
    }
  }
}
