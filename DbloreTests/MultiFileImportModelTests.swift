import Foundation
import Testing

@testable import Dblore

@Suite("Multi-file import model")
@MainActor
struct MultiFileImportModelTests {
  @Test("A file goes to the current schema's table of its name, any case; two such tables ask")
  func nameMatching() async throws {
    let folder = try temporaryFolder([
      "people.csv": "id\n1\n", "orders.csv": "id\n1\n", "items.csv": "id\n1\n",
      "new.csv": "id\n1\n", "users.csv": "id\n1\n",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main",
      tables: [
        DatabaseTable(schema: "main", name: "people"),
        DatabaseTable(schema: "main", name: "Orders"),
        DatabaseTable(schema: "main", name: "Users"), DatabaseTable(schema: "main", name: "users"),
        DatabaseTable(schema: "other", name: "items"),
      ])
    await model.load([folder])
    let byName = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.displayName, $0) })
    #expect(byName["people.csv"]?.destination == .existing(schema: "main", table: "people"))
    #expect(byName["orders.csv"]?.destination == .existing(schema: "main", table: "Orders"))
    // A table of another schema does not match
    #expect(byName["items.csv"]?.destination == .new(schema: "main", table: "items"))
    #expect(byName["new.csv"]?.destination == .new(schema: "main", table: "new"))

    let users = try #require(byName["users.csv"])
    let reason = try #require(users.destinationChoiceReason)
    #expect(reason.contains("Users") && reason.contains("users"))
    for entry in model.entries where entry !== users { entry.isIncluded = false }
    await #expect(throws: MultiFileImportError.tableNotChosen(file: "users.csv")) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
    users.setDestination(.existing(schema: "main", table: "users"))
    let prepared = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    #expect(prepared.files == ["users.csv"])
    #expect(prepared.batch.statements.first?.sql.contains(#""users""#) == true)
  }

  @Test("A folder lists its importable files by name, without hidden files or subfolders")
  func folderListing() async throws {
    let folder = try temporaryFolder([
      "d.tsv": "id\n1\n", "B.JSON": #"[{"id":1}]"#, "a.csv": "id\n1\n", "notes.txt": "id\n1\n",
      ".hidden.csv": "id\n1\n", "sub/c.csv": "id\n1\n", "dir.csv/e.csv": "id\n1\n",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    // A symlink is skipped even when it names an importable file
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("x.csv"),
      withDestinationURL: folder.appendingPathComponent("a.csv"))
    let model = MultiFileImportModel(schema: "main", tables: [])
    await model.load([folder])
    #expect(model.entries.map(\.displayName) == ["a.csv", "B.JSON", "d.tsv"])
    #expect(model.entries.allSatisfy { $0.model.mappings.map(\.sourceName) == ["id"] })
  }

  @Test("Included files make one batch in order; an excluded file adds nothing")
  func oneBatchForAllFiles() async throws {
    let folder = try temporaryFolder([
      "a.csv": "id,name\n1,ann\n2,al\n", "b.csv": "id,name\n3,bee\n", "c.csv": "id,name\n4,cy\n",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main", tables: [DatabaseTable(schema: "main", name: "A")])
    await model.load([folder])
    model.entries[1].isIncluded = false
    let prepared = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 5)
    let batch = prepared.batch

    #expect(prepared.files == ["a.csv", "c.csv"])
    #expect(batch.statementFiles == ["a.csv", "c.csv", "c.csv"])
    #expect(prepared.summary.files.map(\.file) == ["a.csv", "c.csv"])
    #expect(batch.statements.count == 3)
    #expect(batch.statements[0].sql.hasPrefix(#"INSERT INTO "A""#))
    #expect(batch.statements[0].values == ["1", "ann", "2", "al"])
    #expect(batch.statements[1].sql.hasPrefix(#"CREATE TABLE "c""#))
    #expect(batch.statements[2].values == ["4", "cy"])
    #expect(batch.rowRanges == [1...2, nil, 1...1])
    #expect(batch.connectionEpoch == 5)
    #expect(batch.historySource == .dataImport)
    #expect(batch.preview.contains("a.csv") && batch.preview.contains("c.csv"))
    #expect(!batch.preview.contains("b.csv"))
    #expect(!batch.statements.contains { $0.values.contains("bee") })
  }

  @Test("Safe Mode reads one statement per real statement: a later file's CREATE TABLE stays apart")
  func previewSplitsPerFile() async throws {
    let folder = try temporaryFolder(["a.csv": "id\n1\n2\n", "c.csv": "id\n4\n"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main", tables: [DatabaseTable(schema: "main", name: "A")])
    await model.load([folder])
    let preview = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1).batch.preview
    let statements = SQLStatementClassifier.classify(preview, dialect: .sqlite)

    try #require(statements.count == 3)
    // The CREATE TABLE of c.csv is its own DDL statement, not part of a.csv's INSERT
    #expect(statements.map(\.kind) == [.dml, .ddl, .dml])
    #expect(statements[0].text.contains(#"INSERT INTO "A""#))
    #expect(statements[1].text.contains("-- File: c.csv"))
    #expect(statements[2].text.contains(#"INSERT INTO "c""#))
  }

  @Test("A file name shows without format characters and stays on its comment line")
  func fileNameInPreview() async throws {
    let folder = try temporaryFolder(["a\u{202E}b.csv": "id\n1\n", "x\ny.csv": "id\n2\n"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(schema: "main", tables: [])
    await model.load([folder])
    #expect(model.entries.map(\.displayName) == ["ab.csv", "x\ny.csv"])
    let preview = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1).batch.preview
    #expect(preview.contains("-- File: x\\ny.csv\n"))
    #expect(preview.contains("-- File: ab.csv\n"))
    #expect(SQLStatementClassifier.classify(preview, dialect: .sqlite).count == 4)
  }

  @Test("A relocked connection is refused before the summary and before Safe Mode")
  func relockedConnectionRefused() async throws {
    let registry = LockRegistry()
    let (manager, viewModel, database) = try await sqliteTab(
      safeMode: .alertAll, lockSource: registry)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    let folder = try temporaryFolder(["a.csv": "id\n1\n"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(schema: "main", tables: [])
    await model.load([folder])
    let config = try #require(await manager.config)
    let locked = DatabaseError.connectionLocked.localizedDescription

    registry.setLockedConnections([LockIdentity(config)])
    #expect(await model.prepareImport(for: viewModel) == false)
    #expect(model.errorMessage == locked)
    #expect(model.summary == nil && !model.isReviewing)

    registry.setLockedConnections([])
    #expect(await model.prepareImport(for: viewModel))
    registry.setLockedConnections([LockIdentity(config)])
    #expect(await model.confirmImport(to: viewModel) == false)
    #expect(model.errorMessage == locked)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch == nil)
    // The prepared run stays for a Continue once unlocked
    #expect(model.isReviewing)
    #expect(try await tableNames(manager) == [])
  }

  @Test("An error in the third file names that file and no file values")
  func errorNamesFile() async throws {
    let late = "id\n" + (0..<100).map(String.init).joined(separator: "\n") + "\n100,secret\n"
    let folder = try temporaryFolder(["a.csv": "id\n1\n", "b.csv": "id\n2\n", "c.csv": late])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(schema: "main", tables: [])
    await model.load([folder])
    #expect(model.entries.count == 3)
    let error = await #expect(throws: MultiFileImportError.self) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
    let message = try #require(error?.localizedDescription)
    #expect(message.hasPrefix("c.csv: "))
    #expect(!message.contains("a.csv") && !message.contains("b.csv"))
    #expect(!message.contains("secret"))
  }

  @Test("A statement failing at run time names its file and rows, and rolls back every file")
  func runTimeFailureNamesFile() async throws {
    let (manager, viewModel, database) = try await sqliteTab(safeMode: .silent)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(
      "CREATE TABLE c (id INTEGER PRIMARY KEY); INSERT INTO c VALUES (1)")
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let folder = try temporaryFolder([
      "a.csv": "id\n1\n", "b.csv": "id\n2\n", "c.csv": "id\n5\n1\n",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main", tables: [DatabaseTable(schema: "main", name: "c")])
    await model.load([folder])

    #expect(await model.prepareImport(for: viewModel))
    #expect(await model.confirmImport(to: viewModel) == false)
    let message = try #require(model.errorMessage)
    #expect(message.hasPrefix("c.csv rows 1–2: "))
    #expect(message.contains("UNIQUE"))
    // The toast names the file and rows, never the server detail
    #expect(toasts == ["c.csv rows 1–2: Import failed. See the import sheet for details."])
    // SQLite DDL is transactional: the tables of a.csv and b.csv went with the failure
    #expect(try await tableNames(manager) == ["c"])
    #expect(try await manager.executeInternal("SELECT id FROM c").rows == [[.int(1)]])
  }

  @Test("One summary and one Safe Mode decision for every file; excluded files add nothing")
  func oneSafeModeDecision() async throws {
    let (manager, viewModel, database) = try await sqliteTab(safeMode: .alertAll)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(
      """
      CREATE TABLE b (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO b VALUES (1, 'a');
      CREATE TABLE c (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO c VALUES (1, 'x')
      """)
    let folder = try temporaryFolder([
      "a.csv": "id,name\n1,ann\n", "b.csv": "id,name\n1,A\n2,B\n", "c.csv": "id,name\n1,y\n",
      "d.csv": "id,name\n9,dee\n",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main",
      tables: [DatabaseTable(schema: "main", name: "b"), DatabaseTable(schema: "main", name: "c")])
    await model.load([folder])
    await model.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    model.entries[1].model.selectMode(.insertOrUpdate)
    model.entries[2].model.selectMode(.insertSkippingExisting)
    model.entries[3].isIncluded = false
    let original = try await tableNames(manager)

    // The combined summary comes first: nothing written, Safe Mode not asked yet
    #expect(await model.prepareImport(for: viewModel))
    #expect(model.isReviewing)
    #expect(!viewModel.queryConfirmationState.showDialog)
    let summary = try #require(model.summary)
    #expect(summary.files.map(\.file) == ["a.csv", "b.csv", "c.csv"])
    #expect(summary.files[0].counts == .init(inserts: 1, updates: 0, skips: 0, refused: 0))
    #expect(summary.files[1].match?.newRows == 1)
    #expect(summary.files[1].match?.existingRows == 1)
    #expect(summary.files[1].notice == nil)
    // A keyed file with nothing to write is a notice; the other files still run
    #expect(summary.files[2].notice == "No rows to write: 1 skipped, 0 refused.")
    #expect(summary.totals == .init(inserts: 2, updates: 1, skips: 1, refused: 0))
    #expect(model.notice == nil)
    #expect(try await tableNames(manager) == original)

    #expect(await model.confirmImport(to: viewModel))
    #expect(viewModel.queryConfirmationState.showDialog)
    let pending = try #require(viewModel.pendingStagedBatch)
    #expect(pending.statementFiles == ["a.csv", "a.csv", "b.csv", "b.csv"])
    #expect(pending.preview.hasPrefix("-- 3 files: 2 to insert, 1 to update, 1 skipped"))
    #expect(!pending.preview.contains("d.csv"))
    #expect(!pending.preview.contains("ann") && !pending.preview.contains("dee"))
    await viewModel.executePendingQuery()
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(try await tableNames(manager) == ["a", "b", "c"])
    let rows = { (table: String) in
      try await manager.executeInternal("SELECT id, name FROM \(table) ORDER BY id").rows
    }
    #expect(try await rows("a") == [[.int(1), .string("ann")]])
    #expect(try await rows("b") == [[.int(1), .string("A")], [.int(2), .string("B")]])
    #expect(try await rows("c") == [[.int(1), .string("x")]])
  }

  @Test("Cancel while a file prepares stops the run: later files are not read, nothing is sent")
  func cancelBetweenFiles() async throws {
    let folder = try temporaryFolder(["a.csv": "id,name\n1,A\n", "b.csv": "id,name\n2,B\n"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main",
      tables: [DatabaseTable(schema: "main", name: "a"), DatabaseTable(schema: "main", name: "b")])
    await model.load([folder])
    await model.loadMatchKeys { schema, table in keyedStructure(schema: schema, table: table) }
    for entry in model.entries { entry.model.selectMode(.insertOrUpdate) }
    let reads = ReadCounter()
    let prepared = await model.prepareImport(
      dialect: .sqlite, connectionEpoch: 1,
      readMatches: { _ in
        await reads.increment()
        await MainActor.run { model.cancel() }
        return []
      })

    #expect(prepared == false)
    #expect(model.errorMessage == "Import cancelled")
    #expect(await reads.count == 1)
    #expect(model.summary == nil && !model.isReviewing && model.progress == nil)
    let viewModel = NotebookViewModel(notebook: DbloreNotebook.newDocument())
    #expect(await model.confirmImport(to: viewModel) == false)
    #expect(viewModel.pendingStagedBatch == nil)
  }

  @Test("Only a MySQL or MariaDB run that creates a table warns that it saves the work so far")
  func implicitCommitWarning() async throws {
    let folder = try temporaryFolder(["a.csv": "id\n1\n", "b.csv": "id\n2\n"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = MultiFileImportModel(
      schema: "main", tables: [DatabaseTable(schema: "main", name: "a")])
    await model.load([folder])

    #expect(await model.prepareImport(dialect: .mysql, connectionEpoch: 1, readMatches: nil))
    #expect(model.implicitCommitWarning?.contains("MySQL") == true)
    #expect(await model.prepareImport(dialect: .sqlite, connectionEpoch: 1, readMatches: nil))
    #expect(model.implicitCommitWarning == nil)
    model.entries[1].isIncluded = false
    #expect(await model.prepareImport(dialect: .mysql, connectionEpoch: 1, readMatches: nil))
    #expect(model.implicitCommitWarning == nil)
  }

  /// A connected SQLite tab on a new database file
  private func sqliteTab(
    safeMode: SafeMode, lockSource: LockRegistry = .shared
  ) async throws -> (DatabaseConnectionManager, NotebookViewModel, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-multi-run-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: safeMode, protectedMode: false)
    let manager = DatabaseConnectionManager(lockSource: lockSource)
    try await manager.connect(config: config)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    return (manager, viewModel, url)
  }

  private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private func tableNames(_ manager: DatabaseConnectionManager) async throws -> [String] {
    try await manager.executeInternal(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ).rows.compactMap { row in
      if case .string(let name) = row.first { name } else { nil }
    }
  }

  /// A temporary folder with `files` (relative paths, subfolders created as needed)
  private func temporaryFolder(_ files: [String: String]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-multi-import-\(UUID().uuidString)", isDirectory: true)
    for (path, contents) in files {
      let url = folder.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
    }
    return folder
  }
}

/// A table `id INTEGER PRIMARY KEY, name TEXT`
private func keyedStructure(schema: String, table: String) -> TableStructure {
  TableStructure(
    tableID: .sqlite(schema: schema, table: table), schema: schema, name: table,
    columns: [
      .init(ordinal: 1, name: "id", dataType: "INTEGER", isNullable: false),
      .init(ordinal: 2, name: "name", dataType: "TEXT", isNullable: true),
    ],
    indexes: [], constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
}

private actor ReadCounter {
  private(set) var count = 0

  func increment() { count += 1 }
}
