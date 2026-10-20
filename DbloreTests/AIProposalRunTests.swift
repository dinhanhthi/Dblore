// AIProposalRunTests.swift
// Proposal cards: the kind the app reads from a proposal (SQL and mongosh), the typed name of a
// destructive one, and Run, which goes through the active tab's user-SQL path (protection
// level, Safe Mode confirmation, the execution gate), opens a query tab when none is active,
// runs only on the connection it was proposed for, and is the only way a proposal runs.
// Fake sessions, no database needed.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("AI proposal run")
@MainActor
struct AIProposalRunTests {
  /// A workspace connected to `live`, with no tab open
  private func connectedManager(
    live: FakeDatabaseSessionFactory, databaseType: DatabaseType = .postgresql,
    commitStyle: CommitStyle = .immediate, protectionLevel: ConnectionProtectionLevel = .none
  ) async throws -> WorkspaceManager {
    var config = ConnectionConfig(
      databaseType: databaseType, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: protectionLevel, safeMode: .silent,
      protectedMode: false)
    config.applyCommitStyle(commitStyle)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: live))
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    return manager
  }

  /// A proposal made for `manager`'s connection
  private func proposal(_ sql: String, for manager: WorkspaceManager) -> AIProposal {
    let config = manager.workspace.connectionConfig
    return AIProposal(
      sql: sql, reason: "r", sessionKey: config.map(AIAccessGate.sessionKey(for:)),
      database: config?.database)
  }

  /// Polls `condition` (up to 10 s, for a loaded full-suite run)
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private static func check(_ sql: String, _ dialect: SQLDialect = .postgresql) -> AIProposalCheck {
    AIProposalCheck.make(sql: sql, dialect: dialect, database: "db")
  }

  // MARK: - Kind

  @Test("SQL proposals are read, write, schema or destructive, as the app classifies them")
  func sqlKinds() {
    #expect(Self.check("SELECT * FROM users").kind == .read)
    #expect(Self.check("UPDATE users SET a = 1 WHERE id = 2").kind == .write)
    #expect(Self.check("CREATE INDEX i ON users (a)").kind == .schema)
    #expect(Self.check("DROP TABLE users").kind == .destructive)
    #expect(Self.check("TRUNCATE users").kind == .destructive)
    #expect(Self.check("SELECT 1; DROP VIEW v").kind == .destructive)
    let all = Self.check("DELETE FROM users")
    #expect(all.kind == .write && all.affectsAllRows)
  }

  @Test("DROP and TRUNCATE name their object as written; several objects name none")
  func sqlConfirmNames() {
    #expect(Self.check("DROP TABLE users").confirmName == "users")
    #expect(
      Self.check("drop table if exists Public.\"Order Items\" cascade").confirmName
        == "Public.Order Items")
    #expect(Self.check("DROP INDEX CONCURRENTLY IF EXISTS idx_a").confirmName == "idx_a")
    #expect(Self.check("DROP MATERIALIZED VIEW mv").confirmName == "mv")
    #expect(Self.check("TRUNCATE TABLE ONLY logs RESTART IDENTITY").confirmName == "logs")
    #expect(Self.check("DROP TABLE `shop`.`orders`", .mysql).confirmName == "shop.orders")
    for sql in ["DROP TABLE a, b", "TRUNCATE a, b", "DROP OWNED BY bob"] {
      let check = Self.check(sql)
      #expect(check.kind == .destructive, "\(sql)")
      #expect(check.confirmName == nil, "\(sql)")
      #expect(check.runRefusal == AIProposalCheck.noNameRefusal, "\(sql)")
    }
  }

  @Test("DO blocks, EXECUTE and CALL are destructive with no name: Run is off")
  func opaqueStatementsCannotRun() {
    for sql in [
      "DO $$ BEGIN DELETE FROM users; END $$", "do language plpgsql $$ BEGIN NULL; END $$",
      "EXECUTE purge_users(1)", "CALL archive_orders()",
    ] {
      let check = Self.check(sql)
      #expect(check.kind == .destructive, "\(sql)")
      #expect(check.confirmName == nil, "\(sql)")
      #expect(check.runRefusal == AIProposalCheck.noNameRefusal, "\(sql)")
    }
    #expect(Self.check("CALL archive_orders()", .mysql).runRefusal == AIProposalCheck.noNameRefusal)
    // MySQL runs the SQL in an executable comment, which the name check cannot read
    for sql in ["/*!40000 DROP TABLE users */", "DROP TABLE a /*!, b */"] {
      let check = Self.check(sql, .mysql)
      #expect(check.kind == .destructive, "\(sql)")
      #expect(check.confirmName == nil, "\(sql)")
      #expect(check.runRefusal == AIProposalCheck.noNameRefusal, "\(sql)")
    }
  }

  @Test("A destructive statement with any other statement cannot run")
  func destructiveRunsAlone() {
    for (sql, dialect) in [
      ("SELECT 1; DROP VIEW v", SQLDialect.postgresql), ("DROP TABLE a; DROP TABLE b", .postgresql),
      ("TRUNCATE logs; INSERT INTO logs (a) VALUES (1)", .postgresql),
      ("db.orders.find({}); db.orders.drop()", .mongodb),
    ] {
      let check = Self.check(sql, dialect)
      #expect(check.kind == .destructive, "\(sql)")
      #expect(check.runRefusal == AIProposalCheck.destructiveWithOthersRefusal, "\(sql)")
    }
    // A write with others is not destructive: it may run
    #expect(Self.check("UPDATE a SET b = 1 WHERE c = 2; SELECT 1").runRefusal == nil)
  }

  @Test("Invisible format and text-direction characters are found, and the text cannot run")
  func hiddenCharacters() {
    for scalar in ["\u{202A}", "\u{202E}", "\u{2066}", "\u{2069}", "\u{200B}", "\u{FEFF}"] {
      #expect(
        AIProposalCheck.hasHiddenCharacters("SELECT 1 -- a\(scalar)b"), "\(scalar.debugDescription)"
      )
    }
    #expect(!AIProposalCheck.hasHiddenCharacters("SELECT 'café', '日本' -- note\n\tFROM t"))
    let check = Self.check("SELECT * FROM users WHERE role = 'user\u{202E} \u{2066}'")
    #expect(check.kind == .read)
    #expect(check.runRefusal == AIProposalCheck.hiddenCharactersRefusal)
  }

  @Test("MongoDB drop(), dropDatabase() and deleteMany({}) are destructive with their name")
  func mongoKinds() {
    let drop = Self.check("db.orders.drop()", .mongodb)
    #expect(drop.kind == .destructive && drop.confirmName == "orders")
    let database = Self.check("db.dropDatabase()", .mongodb)
    #expect(database.kind == .destructive && database.confirmName == "db")
    let deleteAll = Self.check("db.logs.deleteMany({})", .mongodb)
    #expect(deleteAll.kind == .destructive && deleteAll.confirmName == "logs")
    #expect(Self.check("db.logs.deleteMany({level: \"debug\"})", .mongodb).kind == .write)
    let updateAll = Self.check("db.logs.updateMany({}, {$set: {a: 1}})", .mongodb)
    #expect(updateAll.kind == .write && updateAll.affectsAllRows)
    #expect(Self.check("db.logs.find({})", .mongodb).kind == .read)
    #expect(Self.check("db.logs.createIndex({a: 1})", .mongodb).kind == .schema)
  }

  @Test("The shared classifier still calls deleteMany({}) DML that affects all rows")
  func classifierUnchanged() throws {
    let statement = try #require(MongoCommandClassifier.classifyStatement("db.logs.deleteMany({})"))
    #expect(statement.kind == .dml)
    #expect(statement.affectsAllRows)
    #expect(!statement.isDestructive)
  }

  // MARK: - Run

  @Test("Run goes through the active tab's user-SQL path and leaves the editor text alone")
  func runsThroughEditorPath() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let tabID = manager.newSQLFile(content: "SELECT 1")
    let tab = try #require(manager.viewModel(for: tabID))
    let sql = "UPDATE users SET a = 1 WHERE id = 2"

    #expect(
      manager.runAIProposal(proposal(sql, for: manager), confirmedName: nil) == .ran(tabID: tabID))
    await waitUntil { live.statements.contains(sql) }

    #expect(live.statements.contains(sql))
    #expect(tab.editorContent == "SELECT 1")
    #expect(manager.tabs.count == 1)
  }

  @Test("In a notebook Run adds the proposal as a cell and runs that cell")
  func runsAsNotebookCell() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let tabID = manager.newNotebook()
    let tab = try #require(manager.viewModel(for: tabID))
    let sql = "INSERT INTO users (a) VALUES (1)"

    #expect(
      manager.runAIProposal(proposal(sql, for: manager), confirmedName: nil) == .ran(tabID: tabID))
    await waitUntil { live.statements.contains(sql) }

    #expect(tab.notebook.cells.contains { $0.content == sql })
    #expect(live.statements.contains(sql))
  }

  @Test("Safe Mode asks first, as for typed SQL; only its confirmation sends the write")
  func safeModeConfirmationApplies() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live, commitStyle: .confirm)
    let tabID = manager.newSQLFile()
    let tab = try #require(manager.viewModel(for: tabID))
    let sql = "DELETE FROM users WHERE id = 2"

    #expect(
      manager.runAIProposal(proposal(sql, for: manager), confirmedName: nil) == .ran(tabID: tabID))
    await waitUntil { tab.queryConfirmationState.showDialog }

    #expect(tab.queryConfirmationState.showDialog)
    #expect(tab.queryConfirmationState.pendingQuery == sql)
    #expect(!live.statements.contains(sql))

    await tab.executePendingQuery()
    #expect(live.statements.contains(sql))
  }

  @Test("A read-only connection refuses a write before anything is sent or opened")
  func readOnlyRefusesWrites() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live, protectionLevel: .readOnly)
    let before = live.statements.count
    let write = proposal("DELETE FROM users WHERE id = 2", for: manager)

    // No tab: refused without opening one
    guard case .refused = manager.runAIProposal(write, confirmedName: nil) else {
      Issue.record("expected a refusal")
      return
    }
    #expect(manager.tabs.isEmpty)

    // In the active tab: the tab's own protection check refuses it
    let tabID = manager.newSQLFile()
    guard case .refused = manager.runAIProposal(write, confirmedName: nil) else {
      Issue.record("expected a refusal")
      return
    }
    let tab = try #require(manager.viewModel(for: tabID))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(live.statements.count == before)
    #expect(!tab.queryConfirmationState.showDialog)
  }

  @Test("DROP and TRUNCATE need the object name typed first")
  func typedNameForDropAndTruncate() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let tabID = manager.newSQLFile()
    let tab = try #require(manager.viewModel(for: tabID))

    for (sql, name) in [("DROP TABLE public.users", "public.users"), ("TRUNCATE logs", "logs")] {
      let proposal = proposal(sql, for: manager)
      for typed in [nil, "", "users", name.uppercased()] {
        #expect(
          manager.runAIProposal(proposal, confirmedName: typed)
            == .refused("Type \(name) to run this statement."))
      }
      try? await Task.sleep(for: .milliseconds(30))
      // Check for this statement only: the previous one's schema reload sent catalog queries
      #expect(!live.statements.contains(sql))
      #expect(manager.runAIProposal(proposal, confirmedName: " \(name) ") == .ran(tabID: tabID))
      // The fake records the statement before the editor run ends; the next Run would find the
      // query still running
      await waitUntil { live.statements.contains(sql) && !tab.isEditorQueryRunning }
      #expect(live.statements.contains(sql))
      #expect(!tab.isEditorQueryRunning)
      // The statement changed the schema, so the run started a schema reload: let its catalog
      // queries finish before the next statement is checked
      await manager.awaitSchemaLoad()
    }
  }

  @Test("MongoDB drop() and deleteMany({}) need the collection name typed first")
  func typedNameForMongo() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = try await connectedManager(live: live, databaseType: .mongodb)
    let before = live.statements.count

    for (command, name) in [
      ("db.orders.drop()", "orders"), ("db.logs.deleteMany({})", "logs"),
      ("db.dropDatabase()", "db"),
    ] {
      let proposal = proposal(command, for: manager)
      #expect(
        manager.runAIProposal(proposal, confirmedName: nil)
          == .refused("Type \(name) to run this statement."))
      #expect(
        manager.runAIProposal(proposal, confirmedName: "other")
          == .refused("Type \(name) to run this statement."))
    }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(manager.tabs.isEmpty)
    #expect(live.statements.count == before)
    #expect(live.typedCommands.isEmpty)
  }

  @Test("With no query tab open, Run opens one holding the proposal and runs it there")
  func opensTabWhenNone() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let sql = "UPDATE users SET a = 1 WHERE id = 2"
    #expect(manager.tabs.isEmpty)

    guard
      case .openedTab(let tabID) = manager.runAIProposal(
        proposal(sql, for: manager), confirmedName: nil)
    else {
      Issue.record("expected a new tab")
      return
    }
    await waitUntil { live.statements.contains(sql) }

    #expect(manager.activeTabId == tabID)
    #expect(manager.viewModel(for: tabID)?.editorContent == sql)
    #expect(live.statements.contains(sql))
  }

  @Test("A proposal runs only on the connection it was proposed for")
  func otherConnectionRefused() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let refused = WorkspaceManager.AIProposalRunOutcome.refused(
      WorkspaceManager.proposalOtherConnectionRefusal)

    let other = AIProposal(sql: "SELECT 1", reason: "r", sessionKey: "postgresql|other|1|db")
    #expect(manager.runAIProposal(other, confirmedName: nil) == refused)
    // A saved proposal without a connection (older chat, or edited JSON)
    #expect(
      manager.runAIProposal(AIProposal(sql: "SELECT 1", reason: "r"), confirmedName: nil) == refused
    )
    #expect(manager.tabs.isEmpty)
  }

  @Test("A tab still on another connection does not run the proposal")
  func tabOnOtherConnectionRefused() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let tabID = manager.newSQLFile()
    let tab = try #require(manager.viewModel(for: tabID))
    var other = try #require(manager.workspace.connectionConfig)
    other.host = "other"
    tab.applyWorkspaceConnectionConfig(other)
    let before = live.statements.count

    #expect(
      manager.runAIProposal(
        proposal("UPDATE users SET a = 1 WHERE id = 2", for: manager), confirmedName: nil)
        == .refused(WorkspaceManager.proposalOtherConnectionRefusal))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(live.statements.count == before)
  }

  @Test("After a MongoDB database switch a proposal of the old database does not run")
  func mongoOtherDatabaseRefused() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = try await connectedManager(live: live, databaseType: .mongodb)
    let config = try #require(manager.workspace.connectionConfig)
    let onDB = proposal("db.orders.find({})", for: manager)
    let refused = WorkspaceManager.AIProposalRunOutcome.refused(
      WorkspaceManager.proposalOtherDatabaseRefusal)

    // The switch keeps the session key, so only the database tells them apart
    manager.workspace.connectionConfig = WorkspaceManager.switchedMongoConfig(
      config, to: "analytics")
    #expect(manager.liveSessionKey == onDB.sessionKey)
    #expect(manager.runAIProposal(onDB, confirmedName: nil) == refused)
    let drop = proposal("db.orders.drop()", for: manager)
    #expect(drop.database == "analytics")
    #expect(
      manager.runAIProposal(
        AIProposal(sql: drop.sql, reason: "r", sessionKey: drop.sessionKey, database: "db"),
        confirmedName: "orders") == refused)
    // No database stamped (older chat, or edited JSON)
    #expect(
      manager.runAIProposal(
        AIProposal(sql: "db.orders.find({})", reason: "r", sessionKey: onDB.sessionKey),
        confirmedName: nil) == refused)
    #expect(manager.tabs.isEmpty)
    #expect(live.typedCommands.isEmpty)
  }

  @Test("A blank MongoDB database matches the session's default database")
  func mongoBlankDatabaseIsDefault() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = try await connectedManager(live: live, databaseType: .mongodb)
    let config = try #require(manager.workspace.connectionConfig)
    var blank = config
    blank.database = ""
    manager.workspace.connectionConfig = blank
    let key = manager.liveSessionKey
    let other = WorkspaceManager.AIProposalRunOutcome.refused(
      WorkspaceManager.proposalOtherDatabaseRefusal)

    // Past the database check, the typed name is asked for (nothing runs)
    let named = AIProposal(
      sql: "db.orders.drop()", reason: "r", sessionKey: key,
      database: MongoSession.defaultDatabase)
    #expect(
      manager.runAIProposal(named, confirmedName: nil)
        == .refused("Type orders to run this statement."))
    #expect(manager.runAIProposal(named, confirmedName: nil) != other)
    #expect(WorkspaceManager.aiProposalMongoDatabase("") == MongoSession.defaultDatabase)
    #expect(WorkspaceManager.aiProposalMongoDatabase("shop") == "shop")
  }

  @Test("dropDatabase() on a blank MongoDB database confirms the default database's name")
  func mongoBlankDropDatabase() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = try await connectedManager(live: live, databaseType: .mongodb)
    var blank = try #require(manager.workspace.connectionConfig)
    blank.database = ""
    manager.workspace.connectionConfig = blank
    let proposal = AIProposal(
      sql: "db.dropDatabase()", reason: "r", sessionKey: manager.liveSessionKey, database: "")

    // Run asks for the default name instead of refusing for a missing one
    let typeName = WorkspaceManager.AIProposalRunOutcome.refused(
      "Type \(MongoSession.defaultDatabase) to run this statement.")
    #expect(manager.runAIProposal(proposal, confirmedName: nil) == typeName)
    #expect(manager.runAIProposal(proposal, confirmedName: "other") == typeName)
    #expect(manager.tabs.isEmpty)
    #expect(live.typedCommands.isEmpty)
    // The card reads the same name through its normalized database
    let card = AIProposalCheck.make(
      sql: proposal.sql, dialect: .mongodb,
      database: WorkspaceManager.aiProposalMongoDatabase(proposal.database ?? ""))
    #expect(card.confirmName == MongoSession.defaultDatabase)
    #expect(card.runRefusal == nil)
  }

  @Test("A saved proposal over the length cap never runs")
  func overlongRefused() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    let sql = "SELECT " + String(repeating: "1", count: AITools.maxSQLCharacters)

    #expect(
      manager.runAIProposal(proposal(sql, for: manager), confirmedName: nil)
        == .refused(AIProposalCheck.tooLongRefusal))
    #expect(manager.tabs.isEmpty)
  }

  @Test("Receiving and drawing a proposal runs nothing; only an explicit Run does")
  func noAutoRun() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connectedManager(live: live)
    manager.aiAccessSource = {
      AIAccessContext(
        config: manager.workspace.connectionConfig!, savedPolicies: [], gate: AIAccessGate())
    }
    let tabID = manager.newSQLFile()
    let before = live.statements.count
    let sql = "UPDATE users SET a = 1 WHERE id = 2"

    // Received: the tool call only shows a proposal
    let call = AIToolCall(
      id: "p1", name: AITools.proposeSQL, inputJSON: #"{"reason":"r","sql":"\#(sql)"}"#)
    let outcome = await manager.runAITool(
      call, dialect: .postgresql, sessionKey: manager.liveSessionKey, runsQueries: true,
      sendsResultRows: false)
    let entry = AIAssistantViewModel.toolEntry(
      call, outcome, id: UUID(), dialect: .postgresql, sessionKey: manager.liveSessionKey)
    let proposal = try #require(entry.proposal)
    #expect(
      proposal.sessionKey == manager.workspace.connectionConfig.map(AIAccessGate.sessionKey(for:)))
    manager.aiAssistant.messages.append(entry)

    // Drawn: the card and its message view lay out
    let view = NSHostingView(
      rootView: AIMessageView(
        entry: entry, onInsert: { _ in }, dialect: .postgresql,
        onRunProposal: manager.aiAssistant.proposalRunner
      )
      .frame(width: 320))
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(live.statements.count == before)
    #expect(!live.statements.contains(sql))

    // Run
    #expect(manager.aiAssistant.proposalRunner?(proposal, nil) == .ran(tabID: tabID))
    await waitUntil { live.statements.contains(sql) }
    #expect(live.statements.contains(sql))
  }
}
