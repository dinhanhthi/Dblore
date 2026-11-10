// ConnectionAppearanceSyncTests.swift
// A connection's color and group are set in the connection form: saves from the form write
// them (clearing included), and every other save (opened file, rename) keeps the saved row's.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection Appearance Sync Tests")
@MainActor
struct ConnectionAppearanceSyncTests {
  /// Remember on and no password (nothing reaches the Keychain); a unique host finds this
  /// test's row in the shared recent list.
  private static func config(_ color: AccentColor? = nil, group: String? = nil) -> ConnectionConfig
  {
    ConnectionConfig(
      host: "appearance-\(UUID().uuidString).example", database: "app", username: "ada",
      colorTag: color, groupName: group)
  }

  private static func savedEntry(
    _ config: ConnectionConfig, defaults: UserDefaults
  ) -> ConnectionHistoryEntry? {
    SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
      .first { $0.config.host == config.host }
  }

  /// Saves and connects go to `defaults` and an in-memory password store, never the Keychain
  private static func workspace(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: DatabaseType.postgresql.capabilities)),
      defaults: defaults, passwords: RecordingConnectionPasswordStore())
  }

  private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "ConnectionAppearanceSyncTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  private static func withDefaultsAsync(_ body: (UserDefaults) async throws -> Void) async throws {
    let name = "ConnectionAppearanceSyncTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(defaults)
  }

  @Test("A save from outside the form takes the saved row's color, group and scripts")
  func keepsSavedAppearance() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config(.pink, group: "Prod")
      saved.preConnectScript = "vpn-up.sh"
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      let savedRow = try #require(Self.savedEntry(saved, defaults: defaults))
      #expect(SessionManager.setFavoriteConnection(true, id: savedRow.id, defaults: defaults))

      var file = saved
      file.colorTag = nil
      file.groupName = nil
      file.preConnectScript = nil
      file.passwordCommandScript = "other.sh"
      let kept = WorkspaceManager.keepingSavedAppearance(file, defaults: defaults)
      #expect(kept.colorTag == .pink)
      #expect(kept.groupName == "Prod")
      #expect(kept.isFavoriteConnection)
      #expect(kept.preConnectScript == "vpn-up.sh")
      #expect(kept.passwordCommandScript == nil)
      let opened = WorkspaceManager.keepingSavedScripts(file, defaults: defaults)
      #expect(opened.preConnectScript == "vpn-up.sh")
      #expect(opened.passwordCommandScript == nil)

      // An opened file without a saved row runs none of the user's scripts
      var stranger = Self.config()
      stranger.passwordCommandScript = "pw.sh"
      #expect(
        WorkspaceManager.keepingSavedScripts(stranger, defaults: defaults).passwordCommandScript
          == nil)

      // Another engine on the same unscoped key is not the saved row
      var otherEngine = file
      otherEngine.databaseType = .sqlite
      #expect(
        ConnectionKeychainKey.password(for: otherEngine)
          == ConnectionKeychainKey.password(for: saved))
      #expect(
        WorkspaceManager.keepingSavedScripts(otherEngine, defaults: defaults).preConnectScript
          == nil)
      #expect(
        WorkspaceManager.keepingSavedAppearance(otherEngine, defaults: defaults).colorTag == nil)

      // Remember off writes nothing, so the live values stay
      file.rememberConnection = false
      #expect(WorkspaceManager.keepingSavedAppearance(file, defaults: defaults) == file)

      // No saved row: unchanged
      let other = Self.config(.green, group: "Staging")
      #expect(WorkspaceManager.keepingSavedAppearance(other, defaults: defaults) == other)
    }
  }

  @Test("A save from outside the form keeps the saved row's engine preset")
  func keepsSavedFlavor() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config()
      saved.flavor = .cockroachdb
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))

      // A plain config of the same endpoint (an older file) takes the row's preset
      var plain = saved
      plain.flavor = nil
      #expect(
        WorkspaceManager.keepingSavedAppearance(plain, defaults: defaults).flavor == .cockroachdb)

      // No saved row: unchanged
      let other = Self.config()
      #expect(WorkspaceManager.keepingSavedAppearance(other, defaults: defaults) == other)
    }
  }

  @Test("Only the engine picker changes a saved row's preset; other connects open with the row's")
  func savedFlavorWinsOutsideThePicker() async throws {
    try await Self.withDefaultsAsync { defaults in
      let passwords = RecordingConnectionPasswordStore()
      let plain = Self.config()
      let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
      let manager = WorkspaceManager(
        workspace: Workspace(connectionConfig: plain), restoreTabs: false,
        connectionManager: DatabaseConnectionManager(sessionFactory: factory),
        defaults: defaults, passwords: passwords)
      // The window opened plain; the preset is then saved for its endpoint (Welcome's picker)
      var cockroach = plain
      cockroach.flavor = .cockroachdb
      #expect(SessionManager.saveConnection(cockroach, defaults: defaults, passwords: passwords))

      // A rename takes the row's preset into the workspace info form too
      manager.renameConnection(to: "Renamed", defaults: defaults, passwords: passwords)
      #expect(manager.editingConnectionConfig.flavor == .cockroachdb)

      // A reconnect, then workspace info's Save & Reconnect (no picker) of a plain draft
      for fromForm in [false, true] {
        try await manager.connect(
          config: plain, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
          fromForm: fromForm)
        #expect(factory.configs.last?.flavor == .cockroachdb)
        #expect(Self.savedEntry(plain, defaults: defaults)?.config.flavor == .cockroachdb)
      }

      // PostgreSQL picked in the engine picker clears it
      try await manager.connect(
        config: plain, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        fromForm: true, picksEngine: true)
      #expect(factory.configs.last?.flavor == nil)
      #expect(Self.savedEntry(plain, defaults: defaults)?.config.flavor == nil)
    }
  }

  @Test("An opened file, an older copy or a fresh form draft never clears the saved lock")
  func savedLockIsKept() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config()
      saved.isLocked = true
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))

      var copy = saved
      copy.isLocked = false
      #expect(WorkspaceManager.keepingSavedAppearance(copy, defaults: defaults).isLocked)
      #expect(WorkspaceManager.keepingSavedAIFields(copy, defaults: defaults).isLocked)

      // A form connect saves a fresh draft of the same connection
      #expect(
        SessionManager.saveConnection(copy, defaults: defaults, passwords: NoPasswordStore()))
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.isLocked == true)

      // An Edit saves a stale draft over the row
      let row = try #require(Self.savedEntry(saved, defaults: defaults))
      #expect(
        SessionManager.replaceConnection(
          id: row.id, with: copy, defaults: defaults, passwords: NoPasswordStore()))
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.isLocked == true)

      // A first save keeps the draft's own value
      var other = Self.config()
      other.isLocked = true
      #expect(
        SessionManager.saveConnection(other, defaults: defaults, passwords: NoPasswordStore()))
      #expect(Self.savedEntry(other, defaults: defaults)?.config.isLocked == true)
    }
  }

  @Test("Renaming the connection keeps the saved color and group")
  func renameKeepsSavedAppearance() throws {
    try Self.withDefaults { defaults in
      let saved = Self.config(.orange, group: "Reporting")
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      var opened = saved
      opened.colorTag = nil
      opened.groupName = nil
      let manager = Self.workspace(opened)

      manager.renameConnection(to: "Renamed", defaults: defaults, passwords: NoPasswordStore())

      let row = try #require(Self.savedEntry(saved, defaults: defaults))
      #expect(row.config.name == "Renamed")
      #expect(row.config.colorTag == .orange)
      #expect(row.config.groupName == "Reporting")
      #expect(manager.workspace.connectionConfig?.colorTag == .orange)
    }
  }

  // MARK: - Mask rules

  @Test("A rename save keeps the saved mask rules; an opened file never runs with fewer")
  func maskRulesFollowTheSavedRow() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config()
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      saved.maskRules = [email]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      var opened = saved
      opened.maskRules = []

      let manager = Self.workspace(opened)
      manager.renameConnection(to: "Renamed", defaults: defaults, passwords: NoPasswordStore())
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [email])

      // The file's own extra rule stays: a rule only hides data
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      opened.maskRules = [try ColumnMaskRule(pattern: "USERS.email", style: .null), card]
      let file = try #require(WorkspaceManager.sanitizedFileAIPolicy(opened, defaults: defaults))
      #expect(file.maskRules == [email, card])
      opened.maskRules = []
      #expect(
        WorkspaceManager.sanitizedFileAIPolicy(opened, defaults: defaults)?.maskRules == [email])
    }
  }

  @Test("A rule saved through a save or a Welcome edit reaches a live config without rules")
  func savedMaskRulesSeeEverySave() throws {
    try Self.withDefaults { defaults in
      let live = Self.config()
      #expect(SessionManager.saveConnection(live, defaults: defaults, passwords: NoPasswordStore()))
      // Read once, so a stale cache would hide the rule
      #expect(SavedMaskRules.rules(for: live, defaults: defaults).isEmpty)

      var edited = live
      let email = try ColumnMaskRule(pattern: "email", style: .full)
      edited.maskRules = [email]
      #expect(
        SessionManager.saveConnection(edited, defaults: defaults, passwords: NoPasswordStore()))
      #expect(SavedMaskRules.rules(for: live, defaults: defaults) == [email])

      let row = try #require(Self.savedEntry(live, defaults: defaults))
      let card = try ColumnMaskRule(pattern: "*.card", style: .lastFour)
      edited.maskRules = [email, card]
      #expect(
        SessionManager.replaceConnection(
          id: row.id, with: edited, defaults: defaults, passwords: NoPasswordStore()))
      #expect(SavedMaskRules.rules(for: live, defaults: defaults) == [email, card])
    }
  }

  @Test("A connect with edited AI fields keeps the saved mask rules")
  func aiEditedConnectKeepsSavedMaskRules() async throws {
    try await Self.withDefaultsAsync { defaults in
      var saved = Self.config()
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      saved.maskRules = [email]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      let manager = Self.workspace(saved, defaults: defaults)
      var edited = saved
      edited.aiRules = "Never read the payments table."
      edited.maskRules = []

      try await manager.connect(
        config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        aiFieldsEdited: true, fromForm: true)

      let row = Self.savedEntry(saved, defaults: defaults)?.config
      #expect(row?.aiRules == "Never read the payments table.")
      #expect(row?.maskRules == [email])
      #expect(manager.workspace.connectionConfig?.maskRules == [email])
    }
  }

  @Test("A rename or a hidden-schemas save after opening a file keeps the file's extra rule")
  func renameKeepsOpenedFileMaskRules() throws {
    try Self.withDefaults { defaults in
      var saved = Self.config()
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      saved.maskRules = [email]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      var file = saved
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      file.maskRules = [card]
      let manager = WorkspaceManager(
        workspace: Workspace(connectionConfig: file), restoreTabs: false,
        connectionManager: DatabaseConnectionManager(
          sessionFactory: FakeDatabaseSessionFactory(
            capabilities: DatabaseType.postgresql.capabilities)),
        defaults: defaults, passwords: RecordingConnectionPasswordStore())
      #expect(manager.workspace.connectionConfig?.maskRules == [email, card])

      manager.renameConnection(to: "Renamed", defaults: defaults, passwords: NoPasswordStore())
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [email, card])

      // The saved row gained a rule since: the next save keeps it too
      var row = try #require(Self.savedEntry(saved, defaults: defaults)?.config)
      let phone = try ColumnMaskRule(pattern: "phone", style: .full)
      row.maskRules = [email, card, phone]
      #expect(SessionManager.saveConnection(row, defaults: defaults, passwords: NoPasswordStore()))
      manager.setHiddenSchemas(["audit"], defaults: defaults, passwords: NoPasswordStore())
      #expect(
        Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [email, card, phone])
    }
  }

  @Test("A connect with edited mask rules writes the given list, through the Safe Mode unlock too")
  func maskRulesEditedReplacesSavedRules() async throws {
    try await Self.withDefaultsAsync { defaults in
      var saved = Self.config()
      saved.applyCommitStyle(.review)
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      saved.maskRules = [email, card]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      let manager = Self.workspace(saved, defaults: defaults)

      var edited = saved
      edited.maskRules = [card]
      try await manager.connect(
        config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        maskRulesEdited: true, fromForm: true)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [card])

      // Held for the unlock: the flag is kept until the connect completes
      edited.applyCommitStyle(.immediate)
      edited.maskRules = []
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: edited, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false,
          maskRulesEdited: true, fromForm: true)
      }
      #expect(manager.pendingWeakeningMaskRulesEdited == true)
      try await manager.completePendingWeakeningConnect()
      #expect(manager.pendingWeakeningMaskRulesEdited == false)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [])
    }
  }

  @Test("An unedited edit of a saved row never writes back a rule another window removed")
  func uneditedMaskRulesKeepOtherWindowRemoval() throws {
    try Self.withDefaults { defaults in
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      var saved = Self.config()
      saved.maskRules = [email, card]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      let id = try #require(Self.savedEntry(saved, defaults: defaults)?.id)
      // The form was seeded with email and card, then another window removed card
      var row = saved
      row.maskRules = [email]
      #expect(
        SessionManager.replaceConnection(
          id: id, with: row, defaults: defaults, passwords: NoPasswordStore()))
      let merged = WorkspaceManager.keepingSavedMaskRules(saved, editing: id, defaults: defaults)
      #expect(merged.maskRules == [email])
    }
  }

  @Test("An edited rule list drops only the rules the user removed from the saved row's")
  func editedMaskRulesKeepUnseenSavedRules() throws {
    try Self.withDefaults { defaults in
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      let phone = try ColumnMaskRule(pattern: "phone", style: .full)
      // Another window saved phone after this form was seeded with email and card
      var saved = Self.config()
      saved.maskRules = [email, card, phone]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      var form = saved
      form.maskRules = [try ColumnMaskRule(pattern: "USERS.email", style: .null)]
      let merged = WorkspaceManager.keepingSavedMaskRules(
        form, seed: [email, card], defaults: defaults)
      #expect(merged.maskRules == [form.maskRules[0], phone])

      // The form moved to another saved connection after it was seeded: its rule stays
      var other = Self.config()
      other.maskRules = [email]
      #expect(
        SessionManager.saveConnection(other, defaults: defaults, passwords: NoPasswordStore()))
      var moved = other
      moved.maskRules = []
      #expect(
        WorkspaceManager.keepingSavedMaskRules(moved, seed: [card], defaults: defaults)
          .maskRules == [email])
    }
  }

  @Test("A saved removal reaches the other open windows of the row, so they never write it back")
  func savedMaskRuleRemovalReachesOtherWindows() async throws {
    try await Self.withDefaultsAsync { defaults in
      var saved = Self.config()
      let email = try ColumnMaskRule(pattern: "users.email", style: .email)
      let card = try ColumnMaskRule(pattern: "card", style: .lastFour)
      saved.maskRules = [email, card]
      #expect(
        SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
      let editing = Self.workspace(saved, defaults: defaults)
      // An opened file's extra rule stays in the other window
      var file = saved
      let phone = try ColumnMaskRule(pattern: "phone", style: .full)
      file.maskRules = [phone]
      let other = Self.workspace(file, defaults: defaults)
      #expect(other.workspace.connectionConfig?.maskRules == [email, card, phone])
      let unrelated = Self.workspace(Self.config(), defaults: defaults)
      editing.openWorkspaces = { [editing, other, unrelated] }

      var edited = saved
      edited.maskRules = [email]
      try await editing.connect(
        config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        maskRulesEdited: true, fromForm: true)

      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [email])
      #expect(other.workspace.connectionConfig?.maskRules == [email, phone])
      #expect(other.editingConnectionConfig.maskRules == [email, phone])
      #expect(unrelated.workspace.connectionConfig?.maskRules == [])
      other.renameConnection(to: "Renamed", defaults: defaults, passwords: NoPasswordStore())
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.maskRules == [email, phone])
    }
  }

  @Test("An auto-connect from an opened file keeps the saved color and group")
  func fileConnectKeepsSavedAppearance() async throws {
    try await Self.withDefaultsAsync { defaults in
      let saved = Self.config(.cyan, group: "Prod")
      #expect(
        SessionManager.saveConnection(
          saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
      var file = saved
      file.colorTag = nil
      file.groupName = nil
      let manager = Self.workspace(file, defaults: defaults)

      try await manager.connectWithoutUnlockCheck(config: file, isAutoConnect: true)

      #expect(Self.savedEntry(saved, defaults: defaults)?.config.colorTag == .cyan)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.groupName == "Prod")
      #expect(manager.workspace.connectionConfig?.colorTag == .cyan)
    }
  }

  @Test("An untouched form connect from an opened file keeps the saved color and group")
  func untouchedFormConnectKeepsSavedAppearance() async throws {
    try await Self.withDefaultsAsync { defaults in
      let saved = Self.config(.cyan, group: "Prod")
      #expect(
        SessionManager.saveConnection(
          saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
      // An older file without color and group
      var file = saved
      file.colorTag = nil
      file.groupName = nil
      let manager = Self.workspace(file, defaults: defaults)

      // The form (Workspace Info, or a failed auto-connect) opens on the manager's draft
      #expect(manager.editingConnectionConfig.colorTag == .cyan)
      #expect(manager.editingConnectionConfig.groupName == "Prod")
      let autoConnect = try #require(manager.workspace.connectionConfig)
      manager.presentConnectErrorIfActionable(
        DatabaseError.engineUnavailable(.duckdb), config: autoConnect)
      #expect(manager.editingConnectionConfig.colorTag == .cyan)

      try await manager.connect(
        config: manager.editingConnectionConfig, defaultCommitStyle: .immediate,
        hasPassword: false, hasTouchID: false, fromForm: true)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.colorTag == .cyan)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.groupName == "Prod")
    }
  }

  @Test("A DuckDB file opened from Finder opens the form on its saved color and group")
  func duckDBFileFormKeepsSavedAppearance() throws {
    let path = "/private/tmp/appearance-\(UUID().uuidString).duckdb"
    let draft = ConnectionFormContent.applyingDuckDBChoice(
      .open(path: path, bookmark: nil),
      to: ConnectionFormContent.newFormDraft(databaseType: .duckdb), selected: nil
    ).config
    var saved = draft
    saved.colorTag = .orange
    saved.groupName = "Files"
    #expect(SessionManager.saveConnection(saved, passwords: NoPasswordStore()))
    defer {
      if let entry = SessionManager.loadHistory(passwords: NoPasswordStore())
        .first(where: { $0.config.database == path })
      {
        SessionManager.removeConnection(id: entry.id, passwords: NoPasswordStore())
      }
    }
    let manager = Self.workspace(Self.config())

    manager.presentDuckDBFile(URL(fileURLWithPath: path))

    #expect(manager.editingConnectionConfig.database == path)
    #expect(manager.editingConnectionConfig.colorTag == .orange)
    #expect(manager.editingConnectionConfig.groupName == "Files")
  }

  @Test("A form connect writes the form's color and group, clearing included")
  func formConnectWritesAppearance() async throws {
    try await Self.withDefaultsAsync { defaults in
      let saved = Self.config(.purple, group: "Prod")
      #expect(
        SessionManager.saveConnection(
          saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
      let manager = Self.workspace(saved, defaults: defaults)

      var cleared = saved
      cleared.colorTag = nil
      cleared.groupName = nil
      try await manager.connect(
        config: cleared, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        fromForm: true)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.colorTag == nil)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.groupName == nil)

      var edited = saved
      edited.colorTag = .green
      edited.groupName = "Staging"
      try await manager.connect(
        config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false,
        fromForm: true)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.colorTag == .green)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.groupName == "Staging")
      #expect(manager.workspace.connectionConfig?.groupName == "Staging")
    }
  }

  @Test("A form connect held for the Safe Mode unlock still writes the form's color and group")
  func heldFormConnectWritesAppearance() async throws {
    try await Self.withDefaultsAsync { defaults in
      var saved = Self.config(.purple, group: "Prod")
      saved.applyCommitStyle(.review)
      #expect(
        SessionManager.saveConnection(
          saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
      let manager = Self.workspace(saved, defaults: defaults)
      var edited = saved
      edited.applyCommitStyle(.immediate)
      edited.colorTag = nil
      edited.groupName = "Archive"
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: edited, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false,
          fromForm: true)
      }
      #expect(manager.pendingWeakeningFromForm == true)
      manager.cancelPendingWeakeningConnect()
      #expect(manager.pendingWeakeningFromForm == false)
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: edited, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false,
          fromForm: true)
      }

      try await manager.completePendingWeakeningConnect()

      #expect(manager.pendingWeakeningFromForm == false)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.colorTag == nil)
      #expect(Self.savedEntry(saved, defaults: defaults)?.config.groupName == "Archive")
    }
  }

  @Test("The welcome filter also matches the group name and the shown endpoint")
  func welcomeFilterMatchesGroup() {
    let prod = ConnectionHistoryEntry(config: Self.config(group: "Production"))
    var tunneledConfig = Self.config()
    tunneledConfig.sshTunnel = SSHTunnelConfig(host: "bastion.example.com", username: "ops")
    let tunneled = ConnectionHistoryEntry(config: tunneledConfig)
    let rows = [prod, tunneled]
    #expect(WelcomeRecents.matchingConnections(rows, query: "product").map(\.id) == [prod.id])
    // The SSH host is only in the row's endpoint line
    #expect(WelcomeRecents.matchingConnections(rows, query: "bastion").map(\.id) == [tunneled.id])
    #expect(WelcomeRecents.matchingConnections(rows, query: "").count == 2)
    #expect(WelcomeRecents.matchingConnections(rows, query: "nothing-like-this").isEmpty)
  }
}
