// WelcomeLockGateTests.swift
// Welcome and recents on locked connections: a blocked row loads without its saved password,
// export leaves it out, and the history routes that would drop a locked row (remove, retarget,
// Remember off, clear all, Local Data restore and clear) refuse until it is unlocked. Each test
// injects its own LockRegistry, an isolated UserDefaults suite and an in-memory password store:
// no test touches LockRegistry.shared, the real Keychain or UserDefaults.standard.

import Foundation
import Testing

@testable import Dblore

@Suite("Welcome Lock Gate")
@MainActor
struct WelcomeLockGateTests {
  /// A login on a host unique to this test, so rows never meet another test's
  private static func server(locked: Bool = false, password: String = "") -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "welcome-\(UUID().uuidString).example", database: "app", username: "ada",
      password: password)
    config.isLocked = locked
    return config
  }

  private static func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
    let name = "WelcomeLockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults, name)
  }

  private static func save(
    _ config: ConnectionConfig, defaults: UserDefaults,
    passwords: any ConnectionPasswordStore = NoPasswordStore(), registry: LockRegistry
  ) throws -> ConnectionHistoryEntry {
    #expect(
      SessionManager.saveConnection(
        config, defaults: defaults, passwords: passwords, registry: registry))
    // Locked in an earlier session: the first save's grant ends with a relock
    if config.isLocked { registry.relockAll() }
    return try #require(
      SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry
      )
      .first { $0.keychainKey == ConnectionKeychainKey.password(for: config) })
  }

  /// What a successful unlock prompt grants
  private static func unlock(_ config: ConnectionConfig, in registry: LockRegistry) {
    #expect(registry.grant(LockIdentity.all(config), ifGeneration: registry.generation))
  }

  @Test("Recents read no saved password of a blocked row; after unlock they do")
  func recentsSkipBlockedPasswords() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let passwords = RecordingConnectionPasswordStore()
      let locked = try Self.save(
        Self.server(locked: true, password: "secret"), defaults: defaults, passwords: passwords,
        registry: registry)
      let open = try Self.save(
        Self.server(password: "open"), defaults: defaults, passwords: passwords,
        registry: registry)
      let recents = RecentManager(defaults: defaults, passwords: passwords, registry: registry)

      let before = passwords.loadedKeys.count
      let rows = recents.recentConnections
      #expect(rows.first { $0.id == locked.id }?.config.password == "")
      #expect(rows.first { $0.id == open.id }?.config.password == "open")
      #expect(!passwords.loadedKeys.dropFirst(before).contains(locked.keychainKey))

      Self.unlock(locked.config, in: registry)
      #expect(recents.recentConnections.first { $0.id == locked.id }?.config.password == "secret")
    }
  }

  @Test("Editing a locked row after unlock and saving keeps its saved password")
  func editAfterUnlockKeepsPassword() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let passwords = RecordingConnectionPasswordStore()
      let saved = try Self.save(
        Self.server(locked: true, password: "secret"), defaults: defaults, passwords: passwords,
        registry: registry)
      let recents = RecentManager(defaults: defaults, passwords: passwords, registry: registry)
      let row = try #require(recents.recentConnections.first { $0.id == saved.id })
      // Still blocked: the draft gets no saved password
      #expect(recents.withSavedPassword(row.config).password == "")

      Self.unlock(row.config, in: registry)
      var draft = recents.withSavedPassword(row.config)
      draft.name = "Renamed"
      #expect(recents.replaceConnection(id: row.id, with: draft))
      #expect(passwords.loadPassword(forKey: row.keychainKey) == "secret")
    }
  }

  @Test("Export leaves out a blocked row until it is unlocked")
  func exportExcludesBlockedRows() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let locked = try Self.save(
        Self.server(locked: true), defaults: defaults, registry: registry)
      let open = try Self.save(Self.server(), defaults: defaults, registry: registry)
      let history = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry)

      let blocked = ConnectionExportModel(
        connections: history, workspaces: [], registry: registry)
      #expect(blocked.rows.map(\.id) == [open.id])
      #expect(blocked.skippedFileDatabases == 0)

      Self.unlock(locked.config, in: registry)
      let unlocked = ConnectionExportModel(
        connections: history, workspaces: [], registry: registry)
      #expect(Set(unlocked.rows.map(\.id)) == [open.id, locked.id])
      // A relock while the picker is open leaves the row out of the file
      registry.relockAll()
      #expect(unlocked.exportedConnections.count == 1)
    }
  }

  @Test("Removing the only row of a locked file database is refused until it is unlocked")
  func removeLockedFileRowNeedsUnlock() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("welcome-lock-\(UUID().uuidString).sqlite").path
      var file = ConnectionConfig(databaseType: .sqlite, database: path)
      file.isLocked = true
      let row = try Self.save(file, defaults: defaults, registry: registry)
      let identity = LockIdentity(file)

      #expect(
        !SessionManager.removeConnection(
          id: row.id, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(registry.isBlocked(identity))
      #expect(
        SessionManager.loadHistory(
          defaults: defaults, passwords: NoPasswordStore(), registry: registry
        ).map(\.id) == [row.id])

      Self.unlock(file, in: registry)
      #expect(
        SessionManager.removeConnection(
          id: row.id, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(!registry.isLocked(identity))
    }
  }

  @Test("Retargeting a blocked row or turning its Remember off is refused and changes nothing")
  func retargetOfBlockedRowIsRefused() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let passwords = RecordingConnectionPasswordStore()
      let row = try Self.save(
        Self.server(locked: true, password: "secret"), defaults: defaults, passwords: passwords,
        registry: registry)

      var moved = row.config
      moved.host = "elsewhere-\(UUID().uuidString).example"
      var forgotten = row.config
      forgotten.rememberConnection = false
      for edit in [moved, forgotten] {
        #expect(
          !SessionManager.replaceConnection(
            id: row.id, with: edit, defaults: defaults, passwords: passwords,
            registry: registry))
      }
      let rows = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry)
      #expect(rows.map(\.config.host) == [row.config.host])
      #expect(passwords.loadPassword(forKey: row.keychainKey) == "secret")
      #expect(registry.isBlocked(LockIdentity(row.config)))
    }
  }

  @Test("Clear all and the Local Data restore and clear refuse while a row is blocked")
  func clearAndRestoreRefuseWhileBlocked() throws {
    try Self.withDefaults { defaults, name in
      let registry = LockRegistry()
      let row = try Self.save(Self.server(locked: true), defaults: defaults, registry: registry)
      let stored = SessionManager.storedHistory(defaults: defaults, domainName: name).history

      #expect(
        !SessionManager.clearAllHistory(
          defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(
        !SessionManager.replace(
          history: nil, legacySession: nil, defaults: defaults, domainName: name,
          registry: registry))
      #expect(!SessionManager.clearAll(defaults: defaults, domainName: name, registry: registry))
      #expect(SessionManager.storedHistory(defaults: defaults, domainName: name).history == stored)

      Self.unlock(row.config, in: registry)
      #expect(
        SessionManager.clearAllHistory(
          defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(
        SessionManager.loadHistory(
          defaults: defaults, passwords: NoPasswordStore(), registry: registry
        ).isEmpty)
      #expect(!registry.isLocked(LockIdentity(row.config)))
    }
  }

  @Test("A fresh form never prefills a blocked most-recent row; after unlock it does")
  func prefillSkipsBlockedRow() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      _ = try Self.save(Self.server(), defaults: defaults, registry: registry)
      let locked = try Self.save(Self.server(locked: true), defaults: defaults, registry: registry)
      let history = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry)
      #expect(history.first?.id == locked.id)

      let blocked = ConnectionFormContent.openingHistory(
        history: history, draft: ConnectionConfig(), opensOnDraft: false, registry: registry)
      #expect(blocked.load == nil)
      #expect(blocked.selectedHistoryId == nil)

      Self.unlock(locked.config, in: registry)
      let unlocked = ConnectionFormContent.openingHistory(
        history: history, draft: ConnectionConfig(), opensOnDraft: false, registry: registry)
      #expect(unlocked.load?.id == locked.id)
    }
  }

  @Test("Local Data restore and clear of the connection history throw while a row is blocked")
  func localDataRefusalThrows() async throws {
    let name = "WelcomeLockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let row = try Self.save(Self.server(locked: true), defaults: defaults, registry: registry)
    let stored = SessionManager.storedHistory(defaults: defaults, domainName: name).history
    let provider = ConnectionHistoryLocalDataProvider(
      defaults: defaults, domainName: name, registry: registry)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("welcome-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let isLocked: (any Error) -> Bool = {
      if case DatabaseError.connectionLocked = $0 { return true }
      return false
    }
    await #expect(performing: { try await provider.clear() }, throws: isLocked)
    await #expect(performing: { try await provider.importData(from: folder) }, throws: isLocked)
    #expect(SessionManager.storedHistory(defaults: defaults, domainName: name).history == stored)

    Self.unlock(row.config, in: registry)
    try await provider.clear()
    #expect(SessionManager.storedHistory(defaults: defaults, domainName: name).history == nil)
  }

  @Test("Local Data restore and clear of the connection history republish the locks")
  func localDataRepublishesLocks() async throws {
    let source = "WelcomeLockGateTests-\(UUID().uuidString)"
    let sourceDefaults = try #require(UserDefaults(suiteName: source))
    defer { sourceDefaults.removePersistentDomain(forName: source) }
    let row = try Self.save(
      Self.server(locked: true), defaults: sourceDefaults, registry: LockRegistry())
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("welcome-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try LocalDataFiles.write(
      SessionManager.storedHistory(defaults: sourceDefaults, domainName: source).history,
      named: "connectionHistory.json", to: folder)

    let name = "WelcomeLockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let provider = ConnectionHistoryLocalDataProvider(
      defaults: defaults, domainName: name, registry: registry)
    let identity = LockIdentity(row.config)

    try await provider.importData(from: folder)
    #expect(registry.isLocked(identity))
    #expect(registry.isBlocked(identity))

    Self.unlock(row.config, in: registry)
    try await provider.clear()
    #expect(!registry.isLocked(identity))
  }

  @Test("The lock toggle locks and unlocks every saved row of one login and republishes")
  func setLockedCoversEveryRowOfIdentity() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let first = try Self.save(Self.server(), defaults: defaults, registry: registry)
      var other = first.config
      other.database = "reports"
      let second = try Self.save(other, defaults: defaults, registry: registry)
      let elsewhere = try Self.save(Self.server(), defaults: defaults, registry: registry)
      let identity = LockIdentity(first.config)
      let rows = {
        SessionManager.loadHistory(
          defaults: defaults, passwords: NoPasswordStore(), registry: registry)
      }

      #expect(
        SessionManager.setLocked(true, for: identity, defaults: defaults, registry: registry))
      #expect(Set(rows().filter(\.config.isLocked).map(\.id)) == [first.id, second.id])
      #expect(registry.isLocked(identity))
      #expect(!registry.isLocked(LockIdentity(elsewhere.config)))
      // Locked here: this session keeps using it until the next relock
      #expect(!registry.isBlocked(identity))

      registry.relockAll()
      #expect(
        !SessionManager.setLocked(false, for: identity, defaults: defaults, registry: registry))
      #expect(rows().filter(\.config.isLocked).count == 2)
      #expect(registry.isBlocked(identity))

      Self.unlock(first.config, in: registry)
      #expect(
        SessionManager.setLocked(false, for: identity, defaults: defaults, registry: registry))
      #expect(!rows().contains { $0.config.isLocked })
      #expect(!registry.isLocked(identity))
    }
  }

  @Test("Locking a connected login keeps its window running until relockAll")
  func setLockedGrantsUntilRelock() async throws {
    let name = "WelcomeLockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(
      sessionFactory: factory, scripts: .app, lockSource: registry)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "welcome-\(UUID().uuidString).example", port: 1,
      database: "db", username: "u", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let open = ProtectionPolicy(protectionLevel: .none)
    _ = try Self.save(config, defaults: defaults, registry: registry)
    try await manager.connect(config: config)

    #expect(
      SessionManager.setLocked(
        true, for: LockIdentity(config), defaults: defaults, registry: registry))
    _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
    #expect(factory.statements == ["SELECT 1"])

    registry.relockAll()
    do {
      _ = try await manager.execute(userSQL: "SELECT 2", policy: open)
      Issue.record("A relocked login ran a statement")
    } catch DatabaseError.connectionLocked {}
    #expect(factory.statements == ["SELECT 1"])
    await manager.disconnect()
  }

  @Test("A first save of a row locked in the form stays unlocked for this session")
  func firstLockedSaveGrants() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let config = Self.server(locked: true)
      #expect(
        SessionManager.saveConnection(
          config, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(registry.isLocked(LockIdentity(config)))
      #expect(registry.refusal(for: config) == nil)

      // A new row the form locked onto a login locked before stays blocked
      registry.relockAll()
      var other = config
      other.database = "reports"
      #expect(
        SessionManager.saveConnection(
          other, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(registry.refusal(for: other) != nil)
    }
  }

  @Test("A blocked row's saved client certificate is not read until it is unlocked")
  func blockedCertificateIsNotRead() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let row = try Self.save(Self.server(locked: true), defaults: defaults, registry: registry)
      #expect(!ConnectionFormContent.readsSavedCertificate(for: row.config, registry: registry))

      Self.unlock(row.config, in: registry)
      #expect(ConnectionFormContent.readsSavedCertificate(for: row.config, registry: registry))
    }
  }

  @Test("A workspace or notebook file's lock flag never reaches the first save of its connection")
  func fileLockFlagIsNotSaved() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let config = Self.server(locked: true)
      let data = try JSONEncoder().encode(Workspace(connectionConfig: config))
      let decoded = try JSONDecoder().decode(Workspace.self, from: data)
      let fileConfig = try #require(decoded.connectionConfig)
      #expect(!fileConfig.isLocked)
      let notebook = try JSONDecoder().decode(
        DbloreNotebook.self,
        from: JSONEncoder().encode(DbloreNotebook(connectionConfig: config)))
      #expect(notebook.connectionConfig?.isLocked == false)

      let row = try Self.save(fileConfig, defaults: defaults, registry: registry)
      #expect(!row.config.isLocked)
      #expect(!registry.isLocked(LockIdentity(config)))
    }
  }

  @Test("Locking a retargeted draft in the form keeps the lock on save, open for this session")
  func lockedRetargetedDraftKeepsLock() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let row = try Self.save(Self.server(), defaults: defaults, registry: registry)
      var draft = row.config
      draft.host = "elsewhere-\(UUID().uuidString).example"
      // The toggle on a draft no saved row matches yet: the form mirrors the lock
      #expect(
        SessionManager.setLocked(
          true, for: LockIdentity(draft), defaults: defaults, registry: registry))
      draft.isLocked = true

      #expect(
        SessionManager.replaceConnection(
          id: row.id, with: draft, defaults: defaults, passwords: NoPasswordStore(),
          registry: registry))
      let saved = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry
      ).first { $0.id == row.id }
      #expect(saved?.config.host == draft.host)
      #expect(saved?.config.isLocked == true)
      #expect(registry.isLocked(LockIdentity(draft)))
      // Locked here: this session keeps using it until the next relock
      #expect(!registry.isBlocked(LockIdentity(draft)))
      #expect(!registry.isLocked(LockIdentity(row.config)))
    }
  }

  @Test("Retargeting onto the key of another engine's blocked locked row is refused until unlock")
  func retargetOverLockedRowOfAnotherEngineIsRefused() throws {
    try Self.withDefaults { defaults, _ in
      let registry = LockRegistry()
      let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("welcome-lock-\(UUID().uuidString).sqlite").path
      // SQLite, like PostgreSQL, has no Keychain scope: the same fields name the same row
      var file = ConnectionConfig(
        databaseType: .sqlite, host: "welcome-\(UUID().uuidString).example", database: path,
        username: "ada")
      file.isLocked = true
      let locked = try Self.save(file, defaults: defaults, registry: registry)
      let row = try Self.save(Self.server(), defaults: defaults, registry: registry)
      var edited = row.config
      edited.host = file.host
      edited.port = file.port
      edited.database = file.database
      edited.username = file.username
      let ids = {
        Set(
          SessionManager.loadHistory(
            defaults: defaults, passwords: NoPasswordStore(), registry: registry
          ).map(\.id))
      }

      // Overwriting the blocked row would drop its file's lock
      #expect(
        !SessionManager.replaceConnection(
          id: row.id, with: edited, defaults: defaults, passwords: NoPasswordStore(),
          registry: registry))
      #expect(ids() == [locked.id, row.id])
      #expect(registry.isBlocked(LockIdentity(file)))

      Self.unlock(file, in: registry)
      #expect(
        SessionManager.replaceConnection(
          id: row.id, with: edited, defaults: defaults, passwords: NoPasswordStore(),
          registry: registry))
      #expect(ids() == [row.id])
    }
  }
}
