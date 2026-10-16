// DatabaseBackupModelTests.swift
// The dump and restore sheets' model without panels: the dump connection gets the tab
// manager's config, unremembered certificate and SSH secret and host-key prompt; a save
// destination that is the open SQLite file is refused before anything starts; one History row
// per dump and restore (success, failure, cancel, none with History off); the restore file is
// read and planned off the main actor (size checked before reading), refused restores are
// explained before the confirmation, and Safe Mode asks before the restore runs.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite("DatabaseBackupModelTests", .serialized)
@MainActor
struct DatabaseBackupModelTests {
  // MARK: - Dump connection

  @Test func dumpPassesTheTabManagersConfigCredentialsAndHostKeyPrompt() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = ConnectionConfig(
      host: "fake", port: 1, database: "db", username: "u", password: "in-memory")
    config.rememberConnection = false
    config.clientCertificate = ClientCertificateInfo(subject: "CN=u", expiry: nil, hasCA: false)
    config.sshTunnel = SSHTunnelConfig(
      host: "bastion-\(UUID().uuidString).example", username: "jump")
    let certificate = ClientCertificateStoreFactory.ConnectionMaterial(
      account: ClientCertificateStoreFactory.account(for: config),
      material: ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key"))
    let secret = SSHCredentialStoreFactory.ConnectionCredential(
      account: try #require(SSHCredentialStoreFactory.account(for: config)),
      credential: .password("held-only-in-memory"))
    let prompt = RecordingPrompt()
    let manager = DatabaseConnectionManager(
      sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()),
      sshHostKeyPrompt: prompt)
    try await manager.reconnectWithActiveCertificate(
      config: config, material: certificate, sshCredential: secret)
    defer { Task { await manager.disconnect() } }
    let viewModel = Self.viewModel(manager: manager, config: config)
    let made = WriterArguments()
    var environment = Self.environment(save: directory.appendingPathComponent("out.sql"))
    environment.makeDumpWriter = { config, material, credential, prompt in
      made.record(config: config, material: material, credential: credential, prompt: prompt)
      return SQLDumpWriter(
        config: config, material: material, sshCredential: credential,
        sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()),
        temporaryDirectory: directory)
    }
    let model = DatabaseBackupModel(viewModel: viewModel, environment: environment)

    await model.exportDump(options: SQLDumpOptions())

    #expect(model.errorMessage == nil)
    #expect(made.count == 1)
    #expect(made.config?.password == "in-memory")
    #expect(made.config?.host == "fake")
    #expect(made.material == certificate)
    #expect(made.credential == secret)
    #expect(made.prompt === prompt)
    #expect(manager.sshHostKeyPolicy.prompt as? RecordingPrompt === prompt)
  }

  @Test func dumpRefusesTheOpenSQLiteFileBeforeStarting() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    for destination in [fixture.database, URL(fileURLWithPath: fixture.database.path + "-wal")] {
      var environment = Self.environment(save: destination)
      let made = WriterArguments()
      environment.makeDumpWriter = { config, material, credential, prompt in
        made.record(config: config, material: material, credential: credential, prompt: prompt)
        return SQLDumpWriter(
          config: config, material: nil, sshCredential: nil,
          sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()),
          temporaryDirectory: fixture.directory)
      }
      let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
      await model.exportDump(options: SQLDumpOptions())
      #expect(made.count == 0)
      #expect(model.errorMessage == SQLDumpError.destinationIsDatabase.localizedDescription)
      #expect(model.activity == nil)
    }
    #expect(await fixture.recorder.entries.isEmpty)
  }

  // MARK: - Dump history

  @Test func dumpRecordsOneHistoryRowOnSuccess() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let destination = fixture.directory.appendingPathComponent("dump.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: fixture.realEnvironment(save: destination))
    var reloads = 0
    fixture.viewModel.onHistoryRecorded = { reloads += 1 }

    await model.exportDump(options: SQLDumpOptions())

    #expect(model.errorMessage == nil)
    #expect(model.dumpProgress == SQLDumpProgress(tablesDone: 2, tableCount: 2, rowsWritten: 3))
    let text = try String(contentsOf: destination, encoding: .utf8)
    #expect(text.hasPrefix("-- Dblore SQL dump 1 engine=SQLite"))
    let entries = await fixture.recorder.entries
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.source == .dump && entry.kind == .read && entry.status == .success)
    #expect(entry.sql == "SQL dump of source.db: 2 tables, 3 rows")
    #expect(entry.rowCount == 3)
    #expect(entry.workspaceID == SQLiteFixture.workspaceID)
    #expect(reloads == 1)
  }

  @Test func dumpRecordsAFailureAndNothingWithHistoryOff() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    var environment = Self.environment(
      save: fixture.directory.appendingPathComponent("dump.sql"))
    environment.makeDumpWriter = { config, _, _, _ in
      SQLDumpWriter(
        config: config, material: nil, sshCredential: nil,
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: .contract(), openError: FakeQueryError()),
        temporaryDirectory: fixture.directory)
    }
    let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
    await model.exportDump(options: SQLDumpOptions())
    #expect(model.errorMessage != nil)
    let entry = try #require(await fixture.recorder.entries.first)
    #expect(entry.source == .dump && entry.status == .error)
    #expect(entry.errorMessage != nil)

    fixture.viewModel.historySettings.historyEnabled = false
    await model.exportDump(options: SQLDumpOptions())
    #expect(await fixture.recorder.entries.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelStopsTheDumpAndRecordsACancelledRow() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let factory = AnnouncingFactory(
      FakeDatabaseSessionFactory(capabilities: .contract(), slowQueries: true))
    var environment = Self.environment(
      save: fixture.directory.appendingPathComponent("dump.sql"))
    environment.makeDumpWriter = { _, _, _, _ in
      SQLDumpWriter(
        config: ConnectionConfig(
          host: "fake", port: 1, database: "db", username: "u", password: "p"),
        material: nil, sshCredential: nil, sessionFactory: factory,
        temporaryDirectory: fixture.directory)
    }
    let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
    let running = Task { await model.exportDump(options: SQLDumpOptions()) }
    var made = factory.sessions.makeAsyncIterator()
    let session = try #require(await made.next())
    await session.waitUntilQueryStarted()
    #expect(model.activity == .dumping)
    await model.cancel()
    await running.value

    #expect(model.activity == nil)
    let entry = try #require(await fixture.recorder.entries.first)
    #expect(entry.source == .dump && entry.status == .cancelled)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent(
          "dump.sql"
        ).path))
  }

  // MARK: - Table selection

  @Test func selectionKeysMatchTheSidebarTablesAndAllMeansEveryTable() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let session = SQLiteSession(config: fixture.config)
    try await session.open()
    let tables = try await SQLiteSchemaIntrospector().tables(in: session)
    await session.close()
    #expect(tables.map(\.name).sorted() == ["notes", "tags"])

    let all = Set(tables.map { SQLDumpDDL.ObjectName(schema: $0.schema, name: $0.name) })
    #expect(
      DatabaseBackupModel.dumpOptions(selected: all, from: tables, includeData: false)
        == SQLDumpOptions(tables: nil, includeData: false))
    let notes = Set(all.filter { $0.name == "notes" })
    let options = DatabaseBackupModel.dumpOptions(selected: notes, from: tables, includeData: true)
    #expect(options.tables == notes)

    let destination = fixture.directory.appendingPathComponent("notes.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: fixture.realEnvironment(save: destination))
    await model.exportDump(options: options)
    #expect(model.dumpProgress == SQLDumpProgress(tablesDone: 1, tableCount: 1, rowsWritten: 2))
    let text = try String(contentsOf: destination, encoding: .utf8)
    #expect(text.contains("CREATE TABLE notes") && !text.contains("tags"))
  }

  // MARK: - SQLite file copy

  @Test func fileCopyRefusesTheOpenDatabaseAndCopiesElsewhere() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let refused = DatabaseBackupModel(
      viewModel: fixture.viewModel,
      environment: fixture.realEnvironment(save: fixture.database))
    await refused.copyDatabaseFile()
    #expect(
      refused.errorMessage == SQLiteFileBackupError.destinationIsDatabase.localizedDescription)

    let destination = fixture.directory.appendingPathComponent("copy.sqlite")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: fixture.realEnvironment(save: destination))
    await model.copyDatabaseFile()
    #expect(model.errorMessage == nil)
    #expect(model.copyProgress.map { $0.pagesCopied == $0.pageCount } == true)
    #expect(try Self.count(destination, "notes") == 2)
  }

  // MARK: - Restore

  private static let sqliteDump = """
    -- Dblore SQL dump 1 engine=SQLite created=2026-10-15T12:00:00Z
    PRAGMA defer_foreign_keys = ON;
    CREATE TABLE restored (id INTEGER PRIMARY KEY, v TEXT);
    INSERT INTO "restored" ("id", "v") VALUES
    (1, 'a'),
    (2, 'b');

    """

  @Test func restoreReadsThePlanAndRunsWithoutAskingUnderImmediate() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    var executed = 0
    fixture.viewModel.onStatementsExecuted = { executed += 1 }
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .immediate))

    await model.chooseRestoreFile()
    let plan = try #require(model.restorePlan)
    #expect(model.restoreFileName == "dump.sql")
    #expect(plan.summary.statementCount == 3)
    #expect(plan.summary.count(.schema) == 1 && plan.summary.count(.data) == 1)
    #expect(plan.summary.count(.sessionSetting) == 1)
    #expect(model.restoreBlockedReason == nil)

    await model.restore()
    #expect(!model.isConfirmingRestore)
    #expect(model.errorMessage == nil)
    #expect(model.restoreProgress == SQLRestoreProgress(statementsDone: 3, statementCount: 3))
    #expect(try Self.count(fixture.database, "restored") == 2)
    #expect(executed == 1)
    let entry = try #require(await fixture.recorder.entries.first)
    #expect(entry.source == .restore && entry.kind == .schema && entry.status == .success)
    #expect(entry.sql == "Restore SQL dump: 3 statements")
  }

  @Test func safeModeConfirmsBeforeTheRestoreRuns() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    for style in [CommitStyle.confirm, .password] {
      let model = DatabaseBackupModel(
        viewModel: fixture.viewModel, environment: Self.environment(open: file, style: style))
      await model.chooseRestoreFile()
      await model.restore()
      #expect(model.isConfirmingRestore)
      #expect(model.confirmationRequiresPassword == (style == .password))
      #expect(try Self.tableExists(fixture.database, "restored") == false)
      model.cancelRestoreConfirmation()
      #expect(!model.isConfirmingRestore)
      // A late answer (Touch ID after the panel closed) sends nothing
      await model.confirmRestore()
      #expect(try Self.tableExists(fixture.database, "restored") == false)
    }
    #expect(await fixture.recorder.entries.isEmpty)

    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .confirm))
    await model.chooseRestoreFile()
    await model.restore()
    await model.confirmRestore()
    #expect(!model.isConfirmingRestore)
    #expect(try Self.count(fixture.database, "restored") == 2)
    #expect(await fixture.recorder.entries.map(\.status) == [.success])
  }

  @Test func safeModeListsEveryStatementButTheRowsWithItsText() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .confirm))
    await model.chooseRestoreFile()
    #expect(model.restoreConfirmation.isEmpty)
    await model.restore()
    #expect(model.isConfirmingRestore)
    #expect(model.restoreConfirmation.map(\.index) == [0, 1])
    #expect(
      model.restoreConfirmation.map(\.preview) == [
        "PRAGMA defer_foreign_keys = ON",
        "CREATE TABLE restored (id INTEGER PRIMARY KEY, v TEXT)",
      ])
    #expect(model.restoreConfirmation.map(\.kindLabel) == ["Session setting", "Schema"])
    model.cancelRestoreConfirmation()
    #expect(model.restoreConfirmation.isEmpty)
  }

  @Test func restoreConfirmationListsSchemaSequenceAndSettingsButNoInsert() throws {
    let long =
      "CREATE TABLE \"app\".\"wide\" (\n"
      + (1...12).map { "  \"column_\($0)\" integer DEFAULT \($0)" }.joined(separator: ",\n")
      + "\n);"
    let statements = [
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "CREATE TABLE \"app\".\"t\" (\n  \"id\" integer DEFAULT 1 NOT NULL\n);",
      "INSERT INTO \"app\".\"t\" (\"id\") VALUES\n('1');",
      "INSERT INTO \"app\".\"t\" (\"id\") VALUES\n('2');",
      long,
      "SELECT pg_catalog.setval('\"app\".\"s\"', 2, true);",
      "CREATE VIEW \"app\".\"v\" AS\nSELECT 1;",
    ]
    let script =
      "-- Dblore SQL dump 1 engine=PostgreSQL created=x\n-- Not included: roles\n"
      + statements.joined(separator: "\n") + "\n"
    let plan = try SQLRestorePlan(script: script, engine: .postgresql)
    let listed = DatabaseBackupModel.restoreConfirmation(plan)
    #expect(listed.map(\.index) == [0, 1, 4, 5, 6])
    #expect(listed.map(\.kindLabel) == ["Schema", "Schema", "Schema", "Sequence value", "Schema"])
    #expect(listed[0].preview == "CREATE SCHEMA IF NOT EXISTS \"app\"")
    #expect(listed[1].preview == "CREATE TABLE \"app\".\"t\" ( \"id\" integer DEFAULT 1 NOT NULL )")
    #expect(listed[3].preview == "SELECT pg_catalog.setval('\"app\".\"s\"', 2, true)")
    #expect(listed[4].preview == "CREATE VIEW \"app\".\"v\" AS SELECT 1")
    // Long statements are cut as the other Safe Mode confirmations cut them
    #expect(listed[2].preview.count == 80)
    #expect(
      listed[2].preview.hasPrefix("CREATE TABLE \"app\".\"wide\" ( \"column_1\" integer DEFAULT 1,")
    )
    #expect(listed[2].preview.hasSuffix("…"))
    #expect(!listed.contains { $0.preview.hasPrefix("INSERT") })
    // Only the cut row carries its whole text, behind "Show full statement"
    #expect(listed.map(\.isTruncated) == [false, false, true, false, false])
    #expect(listed[2].fullText == String(long.dropLast()))
    #expect(listed.filter { $0.index != 4 }.allSatisfy { $0.fullText == nil })
    #expect(listed.filter { $0.index != 4 }.allSatisfy { $0.reasons.isEmpty })
  }

  @Test func restoreConfirmationShowsWhatPaddingAndCommentsHide() throws {
    let padding = String(repeating: " ", count: 200)
    let quiet = "/* " + String(repeating: "x", count: 120) + " */"
    let trigger =
      "CREATE TRIGGER t AFTER INSERT ON notes BEGIN\n" + padding + quiet
      + "\n  DELETE FROM accounts;\nEND;"
    let defaults = String(repeating: "'x' || ", count: 20) + "'y'"
    let table =
      "CREATE TABLE wide (a INTEGER" + padding + "-- quiet\n\t\t, b TEXT DEFAULT (" + defaults
      + "));"
    let script =
      "-- Dblore SQL dump 1 engine=SQLite created=x\n"
      + ["PRAGMA defer_foreign_keys = ON;", table, trigger].joined(separator: "\n") + "\n"
    let plan = try SQLRestorePlan(script: script, engine: .sqlite)
    let listed = DatabaseBackupModel.restoreConfirmation(plan)
    #expect(listed.map(\.kindLabel) == ["Session setting", "Schema", "Trigger"])

    // Whitespace runs and comments collapse: the trigger body is in the preview, and every
    // trigger shows its whole text with what it does
    #expect(
      listed[2].preview == "CREATE TRIGGER t AFTER INSERT ON notes BEGIN DELETE FROM accounts; END")
    #expect(!listed[2].isTruncated)
    #expect(listed[2].fullText == plan.statements[2].text)
    #expect(listed[2].reasons == ["Trigger body runs on every later write to notes"])

    // A cut row carries its whole text and says how much the preview leaves out
    let collapsed = "CREATE TABLE wide (a INTEGER , b TEXT DEFAULT (" + defaults + "))"
    #expect(listed[1].preview == String(collapsed.prefix(79)) + "…")
    #expect(listed[1].isTruncated)
    #expect(listed[1].fullText == plan.statements[1].text)
    #expect(
      listed[1].reasons == ["Statement continues for \(collapsed.count - 79) more characters"])

    #expect(listed[0].fullText == nil && !listed[0].isTruncated && listed[0].reasons.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func sheetGoneStopsTheRunningDump() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let factory = AnnouncingFactory(
      FakeDatabaseSessionFactory(capabilities: .contract(), slowQueries: true))
    var environment = Self.environment(
      save: fixture.directory.appendingPathComponent("dump.sql"))
    environment.makeDumpWriter = { _, _, _, _ in
      SQLDumpWriter(
        config: ConnectionConfig(
          host: "fake", port: 1, database: "db", username: "u", password: "p"),
        material: nil, sshCredential: nil, sessionFactory: factory,
        temporaryDirectory: fixture.directory)
    }
    let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
    let running = Task { await model.exportDump(options: SQLDumpOptions()) }
    var made = factory.sessions.makeAsyncIterator()
    let session = try #require(await made.next())
    await session.waitUntilQueryStarted()
    #expect(model.activity == .dumping)

    // The panel closed its sheet (the tab went away): nothing waits for the user
    model.sheetDisappeared()
    await running.value

    #expect(model.activity == nil)
    #expect(await fixture.recorder.entries.first?.status == .cancelled)
  }

  @Test func sheetGoneEndsTheSafeModeQuestion() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .confirm))
    await model.chooseRestoreFile()
    await model.restore()
    #expect(model.isConfirmingRestore)
    model.sheetDisappeared()
    #expect(!model.isConfirmingRestore)
    #expect(model.restoreConfirmation.isEmpty)
    // A late Touch ID answer sends nothing
    await model.confirmRestore()
    #expect(try Self.tableExists(fixture.database, "restored") == false)
  }

  @Test func failedRestoreRecordsAnErrorRow() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    // `notes` exists already: the CREATE TABLE fails and the batch rolls back
    let file = try fixture.write(
      Self.sqliteDump + "CREATE TABLE notes (id INTEGER);\n", name: "dump.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .immediate))
    await model.chooseRestoreFile()
    await model.restore()
    #expect(model.errorMessage != nil)
    #expect(try Self.tableExists(fixture.database, "restored") == false)
    let entry = try #require(await fixture.recorder.entries.first)
    #expect(entry.source == .restore && entry.status == .error)
    #expect(entry.sql == "Restore SQL dump: 4 statements")
  }

  @Test func restoreRefusesAFileOverTheLimitBeforeReadingIt() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = fixture.directory.appendingPathComponent("huge.sql")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(SQLRestorePlan.maxScriptBytes + 1))
    try handle.close()
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .immediate))
    await model.chooseRestoreFile()
    #expect(model.restorePlan == nil)
    #expect(
      model.errorMessage
        == SQLRestoreError.tooLarge(bytes: SQLRestorePlan.maxScriptBytes + 1).localizedDescription)
    #expect(model.activity == nil)
  }

  @Test func restoreOfAnotherEnginesDumpIsExplained() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(
      "-- Dblore SQL dump 1 engine=PostgreSQL created=x\nCREATE TABLE t (id int);\n",
      name: "pg.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .immediate))
    await model.chooseRestoreFile()
    #expect(model.restorePlan == nil)
    #expect(
      model.errorMessage
        == SQLRestoreError.engineMismatch(dump: "PostgreSQL", connection: "SQLite")
        .localizedDescription)
  }

  @Test func blockReasonsComeBeforeTheConfirmation() throws {
    let mysql = try SQLRestorePlan(
      script: "-- Dblore SQL dump 1 engine=MySQL created=x\nCREATE TABLE t (id int);\n",
      engine: .mysql)
    let open = ProtectionPolicy(protectionLevel: .none)
    #expect(DatabaseBackupModel.restoreBlockReason(mysql, policy: open) == nil)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    #expect(
      DatabaseBackupModel.restoreBlockReason(mysql, policy: protected)?.contains("Protected mode")
        == true)
    let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
    #expect(
      DatabaseBackupModel.restoreBlockReason(mysql, policy: readOnly)?.contains("read-only")
        == true)
    let sqlite = try SQLRestorePlan(script: Self.sqliteDump, engine: .sqlite)
    let schemaOnly = ProtectionPolicy(protectionLevel: .schemaOnly)
    #expect(DatabaseBackupModel.restoreBlockReason(sqlite, policy: schemaOnly) != nil)
    // Protected mode keeps a PostgreSQL / SQLite restore pending until Commit: not refused
    #expect(DatabaseBackupModel.restoreBlockReason(sqlite, policy: protected) == nil)
  }

  @Test func protectedModeRestoreWaitsForCommit() async throws {
    let fixture = try await SQLiteFixture(protectedMode: true)
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    let model = DatabaseBackupModel(
      viewModel: fixture.viewModel, environment: Self.environment(open: file, style: .review))
    await model.chooseRestoreFile()
    await model.restore()
    #expect(model.errorMessage == nil)
    #expect(model.resultMessage?.contains("Commit") == true)
    #expect(await fixture.manager.transactionStatus().state.isIdle == false)
    try await fixture.manager.rollbackAppTransaction()
  }

  @Test func safeModeConfirmsASequenceValuesOnlyRestore() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("setval.sql")
    try
      ("-- Dblore SQL dump 1 engine=PostgreSQL created=x\n"
      + "SELECT pg_catalog.setval('\"public\".\"s\"', 5, true);\n")
      .write(to: file, atomically: true, encoding: .utf8)
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    try await manager.connect(config: config)
    let viewModel = Self.viewModel(manager: manager, config: config)
    let recorder = BackupHistoryRecorder()
    viewModel.historyRecorder = recorder
    for style in [CommitStyle.confirm, .password] {
      let model = DatabaseBackupModel(
        viewModel: viewModel, environment: Self.environment(open: file, style: style))
      await model.chooseRestoreFile()
      #expect(model.restorePlan?.kinds == [.sequenceValue])
      let sent = factory.statements.count
      await model.restore()
      #expect(model.isConfirmingRestore)
      #expect(model.confirmationRequiresPassword == (style == .password))
      #expect(factory.statements.count == sent)
      model.cancelRestoreConfirmation()
    }
    #expect(await recorder.entries.isEmpty)
    await manager.disconnect()
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelWhilePlanningStoresNoPlan() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    let gate = ReadGate()
    var environment = Self.environment(open: file, style: .immediate)
    // The plan is made, then held: planning past its last cancellation check
    environment.readRestorePlan = { url, engine in
      let result = try DatabaseBackupModel.readPlan(url: url, engine: engine)
      await gate.arrive()
      return result
    }
    let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
    let load = Task { await model.chooseRestoreFile() }
    await gate.waitUntilArrived()
    #expect(model.activity == .reading)
    await model.cancel()
    #expect(model.activity == nil)
    await gate.release()
    await load.value
    #expect(model.restorePlan == nil)
    #expect(model.activity == nil)
    #expect(model.errorMessage == nil)
    await model.restore()
    #expect(try Self.tableExists(fixture.database, "restored") == false)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelAfterTheRestoreReturnedLeavesAnotherStatementRunning() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("dump.sql")
    try
      ("-- Dblore SQL dump 1 engine=PostgreSQL created=x\n"
      + "CREATE TABLE \"public\".\"a\" (id int);\n")
      .write(to: file, atomically: true, encoding: .utf8)
    // Reads wait until interrupted; the restore's BEGIN, CREATE and COMMIT do not
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities, slowQueries: true)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    try await manager.connect(config: config)
    let session = try #require(factory.sessions.first)
    let viewModel = Self.viewModel(manager: manager, config: config)
    let model = DatabaseBackupModel(
      viewModel: viewModel, environment: Self.environment(open: file, style: .immediate))
    await model.chooseRestoreFile()
    let open = ProtectionPolicy(protectionLevel: .none)
    var other: Task<QueryResult, Error>?
    // The restore returned; another tab's statement now runs on the shared connection while
    // the sheet still shows "Restoring..."
    viewModel.onStatementsExecuted = {
      #expect(model.activity == .restoring)
      other = Task { try await manager.execute(userSQL: "SELECT pg_sleep(30)", policy: open) }
      await session.waitUntilQueryStarted()
      model.sheetDisappeared()
      await model.cancel()
      #expect(await manager.runningStatementStatus().inFlight)
    }
    await model.restore()
    #expect(model.errorMessage == nil)
    #expect(model.restoreCompleted)
    for _ in 0..<20 { await Task.yield() }
    // Nothing closed the session or cancelled the other statement
    #expect(await manager.lastCancel == nil)
    #expect(factory.sessions.count == 1)
    #expect(!session.didClose)
    #expect(await manager.runningStatementStatus().inFlight)
    await session.interrupt()
    _ = try? await other?.value
    await manager.disconnect()
  }

  @Test(.timeLimit(.minutes(1)))
  func sheetGoneWhileReadingEndsAtOnceAndDropsThePlan() async throws {
    let fixture = try await SQLiteFixture()
    defer { fixture.remove() }
    let file = try fixture.write(Self.sqliteDump, name: "dump.sql")
    let gate = ReadGate()
    var environment = Self.environment(open: file, style: .immediate)
    environment.readRestorePlan = { url, engine in
      let result = try DatabaseBackupModel.readPlan(url: url, engine: engine)
      await gate.arrive()
      return result
    }
    let model = DatabaseBackupModel(viewModel: fixture.viewModel, environment: environment)
    let load = Task { await model.chooseRestoreFile() }
    await gate.waitUntilArrived()
    #expect(model.activity == .reading)
    model.sheetDisappeared()
    #expect(model.activity == nil)
    await gate.release()
    await load.value
    #expect(model.restorePlan == nil)
    #expect(model.activity == nil)
    #expect(model.errorMessage == nil)
  }

  // MARK: - Helpers

  private static func environment(
    save: URL? = nil, open: URL? = nil, style: CommitStyle = .immediate
  ) -> DatabaseBackupModel.Environment {
    var environment = DatabaseBackupModel.Environment.live
    environment.chooseSaveURL = { _, _ in save }
    environment.chooseOpenURL = { open }
    environment.commitStyle = { _ in style }
    return environment
  }

  private static func viewModel(
    manager: DatabaseConnectionManager, config: ConnectionConfig
  ) -> NotebookViewModel {
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    return viewModel
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-backup-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func count(_ database: URL, _ table: String) throws -> Int {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let db = handle
    else { throw FakeQueryError() }
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table)\"", -1, &statement, nil)
        == SQLITE_OK, let prepared = statement
    else { throw FakeQueryError() }
    defer { sqlite3_finalize(prepared) }
    guard sqlite3_step(prepared) == SQLITE_ROW else { throw FakeQueryError() }
    return Int(sqlite3_column_int64(prepared, 0))
  }

  private static func tableExists(_ database: URL, _ table: String) throws -> Bool {
    (try? count(database, table)) != nil
  }

  /// A connected SQLite file (`notes` with 2 rows, `tags` with 1) in a tab with History on
  @MainActor fileprivate final class SQLiteFixture {
    static let workspaceID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    let directory: URL
    let database: URL
    let config: ConnectionConfig
    let manager = DatabaseConnectionManager()
    let viewModel: NotebookViewModel
    let recorder: BackupHistoryRecorder

    init(protectedMode: Bool = false) async throws {
      recorder = BackupHistoryRecorder()
      directory = try DatabaseBackupModelTests.temporaryDirectory()
      database = directory.appendingPathComponent("source.db")
      config = ConnectionConfig(
        databaseType: .sqlite, database: database.path, username: "", protectionLevel: .none,
        safeMode: .silent, protectedMode: protectedMode)
      try await manager.connect(config: config)
      for statement in [
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)",
        "CREATE TABLE tags (id INTEGER PRIMARY KEY, label TEXT)",
        "INSERT INTO notes VALUES (1, 'a'), (2, 'b')", "INSERT INTO tags VALUES (1, 'x')",
      ] {
        _ = try await manager.executeInternal(statement)
      }
      viewModel = DatabaseBackupModelTests.viewModel(manager: manager, config: config)
      viewModel.historyRecorder = recorder
      let suiteName = "DatabaseBackupModelTests.\(UUID().uuidString)"
      let suite = try #require(UserDefaults(suiteName: suiteName))
      suite.removePersistentDomain(forName: suiteName)
      let settings = AppSettings(defaults: suite)
      settings.historyEnabled = true
      viewModel.historySettings = settings
      viewModel.historyWorkspace = { (id: Self.workspaceID, name: "Backups") }
    }

    /// Dumps with the real writer (its temporary file in this fixture's folder)
    func realEnvironment(save: URL) -> DatabaseBackupModel.Environment {
      var environment = DatabaseBackupModelTests.environment(save: save)
      let directory = directory
      environment.makeDumpWriter = { config, material, credential, _ in
        SQLDumpWriter(
          config: config, material: material, sshCredential: credential,
          sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
          temporaryDirectory: directory)
      }
      return environment
    }

    func write(_ text: String, name: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    }

    func remove() {
      let manager = manager
      let directory = directory
      Task {
        await manager.disconnect()
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
}

private actor BackupHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// The host-key prompt the tab's manager was built with (compared by identity)
private final class RecordingPrompt: SSHHostKeyPrompt, @unchecked Sendable {
  func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool { false }
}

/// What `makeDumpWriter` was given
@MainActor
private final class WriterArguments {
  private(set) var count = 0
  private(set) var config: ConnectionConfig?
  private(set) var material: ClientCertificateStoreFactory.ConnectionMaterial?
  private(set) var credential: SSHCredentialStoreFactory.ConnectionCredential?
  private(set) var prompt: RecordingPrompt?

  func record(
    config: ConnectionConfig, material: ClientCertificateStoreFactory.ConnectionMaterial?,
    credential: SSHCredentialStoreFactory.ConnectionCredential?, prompt: any SSHHostKeyPrompt
  ) {
    count += 1
    self.config = config
    self.material = material
    self.credential = credential
    self.prompt = prompt as? RecordingPrompt
  }
}

/// Yields each session it makes, so a test can wait for the dump's session without polling
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

/// Holds a restore read until the test releases it
private actor ReadGate {
  private var arrived = false
  private var released = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func arrive() async {
    arrived = true
    for waiter in arrivalWaiters { waiter.resume() }
    arrivalWaiters.removeAll()
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilArrived() async {
    guard !arrived else { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}
