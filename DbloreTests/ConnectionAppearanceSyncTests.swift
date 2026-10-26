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

  private static func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
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

      var file = saved
      file.colorTag = nil
      file.groupName = nil
      file.preConnectScript = nil
      file.passwordCommandScript = "other.sh"
      let kept = WorkspaceManager.keepingSavedAppearance(file, defaults: defaults)
      #expect(kept.colorTag == .pink)
      #expect(kept.groupName == "Prod")
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

  @Test("An auto-connect from an opened file keeps the saved color and group")
  func fileConnectKeepsSavedAppearance() async throws {
    try await Self.withDefaults { defaults in
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
    try await Self.withDefaults { defaults in
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
    try await Self.withDefaults { defaults in
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
    try await Self.withDefaults { defaults in
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

  @Test("The welcome filter also matches the group name")
  func welcomeFilterMatchesGroup() {
    let prod = ConnectionHistoryEntry(config: Self.config(group: "Production"))
    let none = ConnectionHistoryEntry(config: Self.config())
    let rows = [prod, none]
    #expect(WelcomeRecents.matchingConnections(rows, query: "product").map(\.id) == [prod.id])
    #expect(WelcomeRecents.matchingConnections(rows, query: "").count == 2)
    #expect(WelcomeRecents.matchingConnections(rows, query: "nothing-like-this").isEmpty)
  }
}
