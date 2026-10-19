// WorkspaceAIAccessSyncTests.swift
// The AI access policy and rules follow the saved connection into an open workspace, its tabs
// and its source, and a file's weaker policy never replaces the saved one.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace AI Access Sync Tests")
@MainActor
struct WorkspaceAIAccessSyncTests {
  private let settings = AIConfiguration(
    activeProvider: nil, configs: [:], defaultConnectionAccess: .always)

  /// Remember on and no password (nothing reaches the Keychain); a unique host finds this
  /// test's row in the shared recent list.
  private static func config(_ policy: AIAccessPolicy, rules: String = "") -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "ai-sync-\(UUID().uuidString).example", database: "app", username: "ada")
    config.aiAccess = policy
    config.aiRules = rules
    return config
  }

  private static func savedEntry(_ config: ConnectionConfig) -> ConnectionHistoryEntry? {
    SessionManager.loadHistory(passwords: NoPasswordStore())
      .first { $0.config.host == config.host }
  }

  private static func removeSaved(_ config: ConnectionConfig) {
    if let entry = savedEntry(config) {
      SessionManager.removeConnection(id: entry.id, passwords: NoPasswordStore())
    }
  }

  private static func workspace(_ config: ConnectionConfig) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: DatabaseType.postgresql.capabilities)))
  }

  @Test("Never on the saved connection denies an open workspace without reopening")
  func savedNeverDeniesOpenWorkspace() throws {
    let saved = Self.config(.always)
    defer { Self.removeSaved(saved) }
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    let manager = Self.workspace(saved)
    let before = try #require(manager.aiAccessSource())
    #expect(before.decision(settings: settings) == .allowed)

    var never = saved
    never.aiAccess = .never
    #expect(SessionManager.saveConnection(never, passwords: NoPasswordStore()))

    let after = try #require(manager.aiAccessSource())
    #expect(after.savedPolicies == [.never])
    #expect(after.decision(settings: settings) == .denied)
  }

  @Test("A form save of edited AI fields updates the workspace, open tabs and the saved list")
  func formSaveSyncsEveryCopy() async throws {
    let original = Self.config(.always)
    defer { Self.removeSaved(original) }
    #expect(SessionManager.saveConnection(original, passwords: NoPasswordStore()))
    let manager = Self.workspace(original)
    let tab = try #require(manager.viewModel(for: manager.newNotebook()))

    var edited = original
    edited.aiAccess = .askOncePerSession
    edited.aiRules = "Never read the payments table."
    try await manager.connect(
      config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
      aiFieldsEdited: true)

    #expect(manager.workspace.connectionConfig?.aiAccess == .askOncePerSession)
    #expect(tab.notebook.connectionConfig?.aiAccess == .askOncePerSession)
    #expect(tab.notebook.connectionConfig?.aiRules == "Never read the payments table.")
    let saved = try #require(Self.savedEntry(original))
    #expect(saved.config.aiAccess == .askOncePerSession)
    #expect(saved.config.aiRules == "Never read the payments table.")
    #expect(manager.aiAccessSource()?.config.aiRules == "Never read the payments table.")
  }

  /// Saved with Review and Always, then a form connect to Immediate with edited AI fields: held
  /// for the Safe Mode unlock.
  private static func heldUnlockConnect(
    aiFieldsEdited: Bool
  ) async throws -> (
    WorkspaceManager, ConnectionConfig
  ) {
    var saved = Self.config(.always, rules: "Old rules.")
    saved.applyCommitStyle(.review)
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    let manager = Self.workspace(saved)
    var edited = saved
    edited.applyCommitStyle(.immediate)
    edited.aiAccess = .never
    edited.aiRules = "New rules."
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: edited, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false,
        aiFieldsEdited: aiFieldsEdited)
    }
    return (manager, saved)
  }

  @Test("Edited AI fields survive the Safe Mode unlock into the save and the workspace")
  func unlockKeepsEditedAIFields() async throws {
    let (manager, saved) = try await Self.heldUnlockConnect(aiFieldsEdited: true)
    defer { Self.removeSaved(saved) }
    try await manager.completePendingWeakeningConnect()
    #expect(manager.pendingWeakeningAIFieldsEdited == false)
    #expect(Self.savedEntry(saved)?.config.aiAccess == .never)
    #expect(Self.savedEntry(saved)?.config.aiRules == "New rules.")
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    #expect(manager.workspace.connectionConfig?.aiRules == "New rules.")
  }

  @Test("A cancelled unlock drops the edited flag: a later plain connect keeps the saved fields")
  func cancelledUnlockDropsEditedFlag() async throws {
    let (manager, saved) = try await Self.heldUnlockConnect(aiFieldsEdited: true)
    defer { Self.removeSaved(saved) }
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningAIFieldsEdited == false)

    var plain = saved
    plain.applyCommitStyle(.immediate)
    plain.aiAccess = .never
    plain.aiRules = "New rules."
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: plain, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    }
    try await manager.completePendingWeakeningConnect()
    #expect(Self.savedEntry(saved)?.config.aiAccess == .always)
    #expect(Self.savedEntry(saved)?.config.aiRules == "Old rules.")
    #expect(manager.workspace.connectionConfig?.aiAccess == .always)
  }

  /// Saved Always, workspace open and connected, then the saved row becomes Never: the
  /// workspace still holds the old Always copy.
  private static func workspaceWithRowTurnedNever() async throws -> (
    WorkspaceManager, ConnectionConfig
  ) {
    let saved = Self.config(.always, rules: "Old rules.")
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    let manager = Self.workspace(saved)
    try await manager.connect(
      config: saved, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
    var never = saved
    never.aiAccess = .never
    never.aiRules = "New rules."
    #expect(SessionManager.saveConnection(never, passwords: NoPasswordStore()))
    #expect(manager.workspace.connectionConfig?.aiAccess == .always)
    return (manager, saved)
  }

  private func expectRowStillNever(_ manager: WorkspaceManager, _ saved: ConnectionConfig) throws {
    #expect(Self.savedEntry(saved)?.config.aiAccess == .never)
    #expect(Self.savedEntry(saved)?.config.aiRules == "New rules.")
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    #expect(try #require(manager.aiAccessSource()).decision(settings: settings) == .denied)
  }

  @Test("Reconnect after a connection loss never writes the old policy over a stricter row")
  func reconnectKeepsStricterSavedRow() async throws {
    let (manager, saved) = try await Self.workspaceWithRowTurnedNever()
    defer { Self.removeSaved(saved) }
    await manager.performDisconnect(preserveCertificateForReconnect: true)
    await manager.reconnectAfterConnectionLoss()
    #expect(manager.connectionState == .connected)
    try expectRowStillNever(manager, saved)
  }

  @Test("Renaming the connection never writes the old policy over a stricter row")
  func renameKeepsStricterSavedRow() async throws {
    let (manager, saved) = try await Self.workspaceWithRowTurnedNever()
    defer { Self.removeSaved(saved) }
    manager.renameConnection(to: "Renamed", passwords: NoPasswordStore())
    #expect(Self.savedEntry(saved)?.config.name == "Renamed")
    try expectRowStillNever(manager, saved)
  }

  /// Saved Always, then a form save with Remember off sets Never: nothing is written, so the old
  /// Always row stays while the workspace holds Never.
  private static func rememberOffWorkspaceOverAlwaysRow() async throws -> (
    WorkspaceManager, ConnectionConfig
  ) {
    let saved = Self.config(.always, rules: "Old rules.")
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    let manager = Self.workspace(saved)
    var never = saved
    never.aiAccess = .never
    never.rememberConnection = false
    try await manager.connect(
      config: never, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
      aiFieldsEdited: true)
    #expect(Self.savedEntry(saved)?.config.aiAccess == .always)
    return (manager, saved)
  }

  private func expectLiveStillNever(_ manager: WorkspaceManager, _ saved: ConnectionConfig) throws {
    #expect(Self.savedEntry(saved)?.config.aiAccess == .always)
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    #expect(try #require(manager.aiAccessSource()).decision(settings: settings) == .denied)
  }

  @Test("With Remember off, Reconnect never takes the policy of the row it does not write")
  func rememberOffReconnectKeepsLivePolicy() async throws {
    let (manager, saved) = try await Self.rememberOffWorkspaceOverAlwaysRow()
    defer { Self.removeSaved(saved) }
    await manager.performDisconnect(preserveCertificateForReconnect: true)
    await manager.reconnectAfterConnectionLoss()
    #expect(manager.connectionState == .connected)
    try expectLiveStillNever(manager, saved)
  }

  @Test("With Remember off, a rename never takes the policy of the row it does not write")
  func rememberOffRenameKeepsLivePolicy() async throws {
    let (manager, saved) = try await Self.rememberOffWorkspaceOverAlwaysRow()
    defer { Self.removeSaved(saved) }
    manager.renameConnection(to: "Renamed", passwords: NoPasswordStore())
    #expect(manager.workspace.connectionConfig?.name == "Renamed")
    try expectLiveStillNever(manager, saved)
  }

  @Test("A tab moved to a new window keeps the connection's AI policy and rules")
  func newWindowKeepsSourceAIFields() throws {
    let source = Self.workspace(Self.config(.never))
    var live = Self.config(.always, rules: "Only the orders schema.")
    live.rememberConnection = false
    source.workspace.connectionConfig = live
    source.makeWindowManager = { Self.workspace($0 ?? live) }

    let target = source.makeNewWindowManager()
    #expect(target.workspace.connectionConfig?.aiAccess == .always)
    #expect(target.workspace.connectionConfig?.aiRules == "Only the orders schema.")
    #expect(target.editingConnectionConfig.aiRules == "Only the orders schema.")
  }

  @Test("An opened file's weaker policy is replaced by the saved one")
  func savedPolicyWinsOverFile() async throws {
    let saved = Self.config(.never, rules: "No customer data.")
    defer { Self.removeSaved(saved) }
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    var file = saved
    file.aiAccess = .always
    file.aiRules = ""

    let manager = Self.workspace(file)
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    #expect(manager.editingConnectionConfig.aiRules == "No customer data.")
    #expect(try #require(manager.aiAccessSource()).decision(settings: settings) == .denied)

    // Auto-connect saves the workspace config: the saved policy stays Never
    let opened = try #require(manager.workspace.connectionConfig)
    try await manager.connectWithoutUnlockCheck(config: opened, isAutoConnect: true)
    #expect(Self.savedEntry(saved)?.config.aiAccess == .never)
    #expect(Self.savedEntry(saved)?.config.aiRules == "No customer data.")
  }

  @Test("Another user's saved policy never applies to a file, nor overwrites this user's row")
  func savedMatchIncludesUsername() async throws {
    var admin = Self.config(.never)
    admin.username = "admin"
    var reporter = admin
    reporter.username = "reporter"
    reporter.aiAccess = .always
    reporter.aiRules = "Reporter rules."
    defer {
      Self.removeSaved(admin)
      Self.removeSaved(reporter)
    }
    #expect(SessionManager.saveConnection(admin, passwords: NoPasswordStore()))
    #expect(SessionManager.saveConnection(reporter, passwords: NoPasswordStore()))
    let newest = SessionManager.loadHistory(passwords: NoPasswordStore())
      .first { $0.config.host == admin.host }
    #expect(newest?.config.username == "reporter")

    var file = admin
    file.aiAccess = .always
    let manager = Self.workspace(file)
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    #expect(manager.workspace.connectionConfig?.aiRules == "")

    let opened = try #require(manager.workspace.connectionConfig)
    try await manager.connectWithoutUnlockCheck(config: opened, isAutoConnect: true)
    #expect(manager.workspace.connectionConfig?.aiAccess == .never)
    let adminRow = SessionManager.loadHistory(passwords: NoPasswordStore())
      .first { $0.config.host == admin.host && $0.config.username == "admin" }
    #expect(adminRow?.config.aiAccess == .never)
  }

  // MARK: - Saved-list helpers (suite-named defaults)

  private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "WorkspaceAIAccessSyncTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  @Test("A file spelling the host differently still gets the saved policy")
  func hostSpellingMatchesSaved() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config(.never, rules: "Saved rules.")
      saved.host = "prod.example.com"
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      for host in ["PROD.example.com", "prod.example.com.", " prod.example.com "] {
        var file = saved
        file.host = host
        file.aiAccess = .always
        file.aiRules = "File rules."
        let sanitized = try #require(
          WorkspaceManager.sanitizedFileAIPolicy(file, defaults: defaults))
        #expect(sanitized.aiAccess == .never)
        #expect(sanitized.aiRules == "Saved rules.")
      }

      // A newer, weaker row with a variant spelling never applies to the exact row's spelling:
      // auto-connect writes to the exact row
      var variant = saved
      variant.host = "PROD.example.com"
      variant.aiAccess = .always
      variant.aiRules = "Variant rules."
      #expect(
        SessionManager.saveConnection(variant, defaults: defaults, passwords: NoPasswordStore()))
      var file = saved
      file.aiAccess = .always
      let exact = try #require(WorkspaceManager.sanitizedFileAIPolicy(file, defaults: defaults))
      #expect(exact.aiAccess == .never)
      #expect(exact.aiRules == "Saved rules.")

      // Without an exact row, the strictest variant applies, not the most recent one
      file.host = "prod.example.com."
      let strictest = try #require(
        WorkspaceManager.sanitizedFileAIPolicy(file, defaults: defaults))
      #expect(strictest.aiAccess == .never)
      #expect(strictest.aiRules == "Saved rules.")
    }
  }

  @Test(
    "The stricter of the live and saved policies wins",
    arguments: [
      (AIAccessPolicy.always, AIAccessPolicy.never, AIAccessPolicy.always),
      (.never, .always, .always),
      (.useDefault, .always, .never),
    ])
  func stricterPolicyWins(
    saved: AIAccessPolicy, live: AIAccessPolicy, global: AIAccessPolicy
  ) throws {
    try Self.withDefaults { defaults in
      let row = Self.config(saved, rules: "Saved rules.")
      #expect(SessionManager.saveConnection(row, defaults: defaults, passwords: NoPasswordStore()))
      var connected = row
      connected.aiAccess = live
      connected.aiRules = "Form rules."
      connected.rememberConnection = false
      connected.password = "secret"
      connected.mongoURI = "mongodb://ada:secret@\(row.host)/app"
      let context = try #require(
        WorkspaceManager.aiAccessContext(for: connected, defaults: defaults))
      #expect(context.config.password.isEmpty)
      #expect(context.config.mongoURI == nil)
      let settings = AIConfiguration(
        activeProvider: nil, configs: [:], defaultConnectionAccess: global)
      #expect(context.decision(settings: settings) == .denied)
      #expect(context.config.aiRules == "Saved rules.")
    }
  }

  private static func saveRow(_ host: String, _ policy: AIAccessPolicy, _ defaults: UserDefaults) {
    var row = Self.config(policy)
    row.host = host
    #expect(SessionManager.saveConnection(row, defaults: defaults, passwords: NoPasswordStore()))
  }

  /// The decision for a live Always config with Remember off on `host`
  private static func decision(
    _ host: String, global: AIAccessPolicy, _ defaults: UserDefaults
  ) throws -> AIAccessGate.Decision {
    var live = Self.config(.always)
    live.host = host
    live.rememberConnection = false
    let context = try #require(WorkspaceManager.aiAccessContext(for: live, defaults: defaults))
    return context.decision(
      settings: AIConfiguration(activeProvider: nil, configs: [:], defaultConnectionAccess: global))
  }

  @Test("Every saved row of the identity counts, after resolving Use default")
  func everyMatchingRowCounts() throws {
    try Self.withDefaults { defaults in
      // A stricter variant spelling wins over the exact row (they share session approvals)
      Self.saveRow("prod.example.com", .never, defaults)
      Self.saveRow("PROD.example.com", .always, defaults)
      let exact = try Self.decision("PROD.example.com", global: .always, defaults)
      #expect(exact == .denied)

      // Use default follows the global default before the strictest is taken
      Self.saveRow("stage.example.com.", .useDefault, defaults)
      Self.saveRow("STAGE.example.com", .askOncePerSession, defaults)
      let variants = try Self.decision("stage.example.com", global: .never, defaults)
      #expect(variants == .denied)
    }
  }

  @Test("Without a saved match a file's policy may only tighten and its rules are dropped")
  func unsavedFileOnlyTightens() throws {
    try Self.withDefaults { defaults in
      for (filePolicy, expected) in [
        (AIAccessPolicy.always, AIAccessPolicy.useDefault), (.never, .never),
        (.askOncePerSession, .askOncePerSession),
      ] {
        let sanitized = try #require(
          WorkspaceManager.sanitizedFileAIPolicy(
            Self.config(filePolicy, rules: "Injected rules."), defaults: defaults))
        #expect(sanitized.aiAccess == expected)
        #expect(sanitized.aiRules == "")
      }

      // An unreadable saved list is no match: fail closed
      defaults.set(Data("not json".utf8), forKey: "ace.thi.dblore.connectionHistory")
      let unreadable = try #require(
        WorkspaceManager.sanitizedFileAIPolicy(
          Self.config(.always, rules: "Injected rules."), defaults: defaults))
      #expect(unreadable.aiAccess == .useDefault)
      #expect(unreadable.aiRules == "")
    }
  }
}
