//
//  SessionManagerTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

@Suite("SessionManager launch restore")
@MainActor
struct SessionManagerTests {
  // MARK: - Unknown engine entries

  private static let historyKey = "ace.thi.dblore.connectionHistory"

  @Test("History with an unknown engine still loads the known entry")
  func unknownEntryDoesNotHideKnownOnes() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    try harness.write(valid: valid, unknown: Self.unknownEntry())

    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(loaded.map(\.id) == [valid.id])
  }

  @Test("Save and remove keep the unknown entry unchanged")
  func saveAndRemoveKeepUnknownEntry() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    let unknown = try Self.unknownEntry()
    try harness.write(valid: valid, unknown: unknown)

    SessionManager.saveConnection(
      ConnectionConfig(host: "other", database: "app", username: "ada", password: "pw"),
      defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).count == 2)

    let replaced = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    var renamed = replaced.config
    renamed.name = "Renamed"
    SessionManager.replaceConnection(
      id: replaced.id, with: renamed, defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])

    SessionManager.removeConnection(
      id: valid.id, defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).map(
        \.config.name) == ["Renamed"])
  }

  @Test("Reconnecting a saved row keeps its id, so settings keyed by id (MCP allowlist) survive")
  func resaveKeepsRowID() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    var config = ConnectionConfig(host: "db.example", database: "app", username: "ada")
    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let saved = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    config.name = "Reconnected"
    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let reloaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(reloaded.map(\.id) == [saved.id])
    #expect(reloaded.first?.config.name == "Reconnected")

    // Another engine on the same unscoped key is another connection: its save is refused
    var sqlite = config
    sqlite.databaseType = .sqlite
    #expect(
      ConnectionKeychainKey.password(for: sqlite) == ConnectionKeychainKey.password(for: config))
    #expect(SessionManager.keyUsedByAnotherIdentity(sqlite, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(sqlite, defaults: harness.defaults, passwords: harness.store))
    let kept = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(kept.map(\.id) == [saved.id])
    #expect(kept.map(\.config.databaseType) == [.postgresql])
  }

  /// Same engine and user; host, port and database differ but join into the same unscoped key
  private static let collidingA = ConnectionConfig(
    host: "h", port: 5432, database: "x:6000:y", username: "ada", password: "a-secret")
  private static let collidingB = ConnectionConfig(
    host: "h:5432:x", port: 6000, database: "y", username: "ada", password: "b-secret")

  @Test("Saving a connection whose Keychain key another saved connection uses is refused")
  func saveOntoAnotherConnectionsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    #expect(ConnectionKeychainKey.password(for: Self.collidingB) == key)
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(SessionManager.keyUsedByAnotherIdentity(Self.collidingB, defaults: harness.defaults))
    #expect(!SessionManager.keyUsedByAnotherIdentity(Self.collidingA, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(
        Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    #expect(
      SessionManagerError.keychainKeyInUse.errorDescription
        == "Another saved connection uses the same Keychain entry.")

    let rows = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(rows.map(\.id) == [a.id])
    #expect(rows.first?.config.host == "h")
    #expect(rows.first?.config.password == "a-secret")
    #expect(harness.store.savedKeys == [key])
    #expect(harness.store.deletedKeys.isEmpty)

    // The same tuple under a new name is still its own row: renamed in place, same id
    var renamed = Self.collidingA
    renamed.name = "Renamed"
    #expect(
      SessionManager.saveConnection(renamed, defaults: harness.defaults, passwords: harness.store))
    let renamedRows = SessionManager.loadHistory(
      defaults: harness.defaults, passwords: harness.store)
    #expect(renamedRows.map(\.id) == [a.id])
    #expect(renamedRows.first?.config.name == "Renamed")
  }

  @Test("Retargeting a row onto another saved connection's Keychain key is refused")
  func retargetOntoAnotherConnectionsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    var elsewhere = Self.collidingB
    elsewhere.host = "elsewhere"
    for config in [Self.collidingA, elsewhere] {
      #expect(
        SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store))
    }
    let before = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    let row = try #require(before.first { $0.config.host == "elsewhere" })
    let saves = harness.store.savedKeys.count

    #expect(
      SessionManager.keyUsedByAnotherIdentity(
        Self.collidingB, excluding: row.id, defaults: harness.defaults))
    #expect(
      !SessionManager.replaceConnection(
        id: row.id, with: Self.collidingB, defaults: harness.defaults, passwords: harness.store))

    let after = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.config.host) == before.map(\.config.host))
    #expect(try harness.store.readPassword(forKey: key) == "a-secret")
    #expect(harness.store.savedKeys.count == saves)
    #expect(!harness.store.deletedKeys.contains(key))
  }

  @Test("A row moved onto its own Keychain key under another identity is not refused by itself")
  func retargetOntoOwnKeyIsNotRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(
      !SessionManager.keyUsedByAnotherIdentity(
        Self.collidingB, excluding: a.id, defaults: harness.defaults))
    #expect(
      SessionManager.replaceConnection(
        id: a.id, with: Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    let rows = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(rows.map(\.id) == [a.id])
    #expect(rows.first?.config.password == "b-secret")
  }

  @Test("Deleting a connection deletes its Keychain password")
  func removeDeletesPassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    #expect(
      !SessionManager.saveConnection(
        Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(
      SessionManager.removeConnection(
        id: a.id, defaults: harness.defaults, passwords: harness.store))
    #expect(harness.store.deletedKeys == [key])
    #expect(try harness.store.readPassword(forKey: key) == nil)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).isEmpty)
  }

  @Test("Saving onto the Keychain key of a row this build cannot decode is refused")
  func saveOntoUndecodableRowsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    let unknown = try Self.unknownEntry()
    try harness.write(valid: valid, unknown: unknown)
    // The unknown engine keeps the unscoped key, which a PostgreSQL row of the same fields uses
    let colliding = ConnectionConfig(
      host: "future", database: "lake", username: "bob", password: "pw")

    #expect(SessionManager.keyUsedByAnotherIdentity(colliding, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(
        colliding, defaults: harness.defaults, passwords: harness.store))
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(harness.store.savedKeys.isEmpty)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).map(\.id)
        == [valid.id])
  }

  @Test("Export then replace keeps the unknown entry")
  func exportReplaceRoundTripKeepsUnknownEntry() throws {
    let source = try Harness()
    let target = try Harness()
    defer {
      source.cleanup()
      target.cleanup()
    }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    var unknown = try Self.unknownEntry()
    try source.write(valid: valid, unknown: unknown)

    let snapshot = SessionManager.exportSnapshot(
      defaults: source.defaults, domainName: source.suiteName)
    SessionManager.replace(
      history: snapshot.history, legacySession: snapshot.legacy, defaults: target.defaults,
      domainName: target.suiteName)

    // Export strips password keys, so compare against the entry without them.
    var config = try #require(unknown["config"] as? [String: Any])
    config.removeValue(forKey: "password")
    unknown["config"] = config
    #expect(try target.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: target.defaults, passwords: target.store).map(\.id)
        == [valid.id])
  }

  // MARK: - Vault secrets

  private static func vaultConfig(host: String = "db.internal") -> ConnectionConfig {
    ConnectionFormVaultDraftTests.vaultConfig(host: host)
  }

  /// Runs `body` with `secret` as the operation's scoped Vault secret for `config` (the form's
  /// draft on Connect or Save).
  private static func withDraft<T>(
    _ secret: VaultSecret, for config: ConnectionConfig, _ body: () throws -> T
  ) rethrows -> T {
    let scoped = VaultCredentialStore.scoped(secret, for: config)
    defer { scoped?.clear() }
    return try VaultCredentialStore.$operationSecret.withValue(scoped, operation: body)
  }

  @Test("A Vault save writes no password Keychain item and deletes a stale one")
  func vaultSaveWritesNoPassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    var plain = Self.vaultConfig()
    plain.vault = nil
    plain.password = "old-password"
    #expect(
      SessionManager.saveConnection(
        plain, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults))
    let key = ConnectionKeychainKey.password(for: plain)
    #expect(harness.store.savedKeys == [key])

    var vault = Self.vaultConfig()
    vault.password = "leased-or-stale"
    #expect(
      Self.withDraft(.token("t"), for: vault) {
        SessionManager.saveConnection(
          vault, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    #expect(harness.store.savedKeys == [key])
    #expect(harness.store.deletedKeys == [key])
    #expect(try harness.store.readPassword(forKey: key) == nil)
    #expect(VaultCredentialStore.lookup(for: vault, from: vaults) == .found(.token("t")))
  }

  @Test("A refused colliding save writes no Vault secret")
  func refusedSaveWritesNoVaultSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store,
        vaultSecrets: vaults))
    var colliding = Self.collidingB
    colliding.password = ""
    colliding.vault = Self.vaultConfig().vault
    let saved = Self.withDraft(.token("t"), for: colliding) {
      SessionManager.saveConnection(
        colliding, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
    }
    #expect(!saved)
    #expect(VaultCredentialStore.lookup(for: colliding, from: vaults) == .missing)
    #expect(harness.store.deletedKeys.isEmpty)
  }

  @Test("A replaced row with a new key and no other user deletes its Vault secret")
  func replacedRowDeletesVaultSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    let original = Self.vaultConfig()
    #expect(
      Self.withDraft(.token("t"), for: original) {
        SessionManager.saveConnection(
          original, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    let oldAccount = try #require(VaultCredentialStore.account(for: original))
    let id = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?.id)

    // New key, other Vault settings, no draft: the old secret is not re-bound, and goes
    var edited = Self.vaultConfig(host: "db2.internal")
    edited.vault?.role = "app-rw"
    #expect(
      SessionManager.replaceConnection(
        id: id, with: edited, defaults: harness.defaults, passwords: harness.store,
        vaultSecrets: vaults))
    #expect(vaults.load(account: oldAccount) == nil)
    #expect(VaultCredentialStore.lookup(for: edited, from: vaults) == .missing)

    // Switching the source away on the same key deletes it too
    #expect(
      Self.withDraft(.token("t2"), for: edited) {
        SessionManager.replaceConnection(
          id: id, with: edited, defaults: harness.defaults, passwords: harness.store,
          vaultSecrets: vaults)
      })
    let newAccount = try #require(VaultCredentialStore.account(for: edited))
    #expect(vaults.load(account: newAccount) != nil)
    var plain = edited
    plain.vault = nil
    #expect(
      SessionManager.replaceConnection(
        id: id, with: plain, defaults: harness.defaults, passwords: harness.store,
        vaultSecrets: vaults))
    #expect(vaults.load(account: newAccount) == nil)
  }

  @Test("A retargeted row with unchanged Vault settings keeps its secret under the new key")
  func retargetMovesVaultSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    let original = Self.vaultConfig()
    #expect(
      Self.withDraft(.token("t"), for: original) {
        SessionManager.saveConnection(
          original, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    let id = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?.id)
    let edited = Self.vaultConfig(host: "db2.internal")
    #expect(
      SessionManager.replaceConnection(
        id: id, with: edited, defaults: harness.defaults, passwords: harness.store,
        vaultSecrets: vaults))
    #expect(VaultCredentialStore.lookup(for: edited, from: vaults) == .found(.token("t")))
    #expect(VaultCredentialStore.lookup(for: original, from: vaults) == .missing)
  }

  @Test("A retarget whose old Vault secret cannot be read keeps that secret")
  func retargetKeepsUnreadableVaultSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = UnreadableVaultSecretStore()
    let original = Self.vaultConfig()
    #expect(
      Self.withDraft(.token("t"), for: original) {
        SessionManager.saveConnection(
          original, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    let id = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?.id)
    let oldAccount = try #require(VaultCredentialStore.account(for: original))
    vaults.failReads(of: [oldAccount])

    // Same destination, new key: the secret to move cannot be read, so it is not deleted
    let edited = Self.vaultConfig(host: "db2.internal")
    #expect(
      SessionManager.replaceConnection(
        id: id, with: edited, defaults: harness.defaults, passwords: harness.store,
        vaultSecrets: vaults))
    #expect(!vaults.deletedAccounts.contains(oldAccount))
    #expect(vaults.base.load(account: oldAccount) != nil)
  }

  @Test("An edited Vault role re-saves the draft's secret under the new settings")
  func editedVaultSettingResavesSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    let original = Self.vaultConfig()
    #expect(
      Self.withDraft(.token("t"), for: original) {
        SessionManager.saveConnection(
          original, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    let id = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?.id)

    // The form restored the stored secret into its draft; the edit binds it to the new role
    // (an edited address or CA asks for it again: ConnectionFormVaultDraftTests)
    var restored = VaultFormDraft(restoringFor: original, blocked: false)
    restored.apply(VaultCredentialStore.lookup(for: original, from: vaults))
    var edited = original
    edited.vault?.role = "app-rw"
    #expect(VaultCredentialStore.lookup(for: edited, from: vaults) == .destinationChanged)
    let secret = try #require(restored.preparedSecret(for: edited))
    #expect(
      Self.withDraft(secret, for: edited) {
        SessionManager.replaceConnection(
          id: id, with: edited, defaults: harness.defaults, passwords: harness.store,
          vaultSecrets: vaults)
      })
    #expect(VaultCredentialStore.lookup(for: edited, from: vaults) == .found(.token("t")))
  }

  @Test("Removing the last row of a Vault secret deletes it")
  func removeDeletesVaultSecret() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    let config = Self.vaultConfig()
    #expect(
      Self.withDraft(.token("t"), for: config) {
        SessionManager.saveConnection(
          config, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
      })
    let id = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?.id)
    #expect(
      SessionManager.removeConnection(
        id: id, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults))
    #expect(VaultCredentialStore.lookup(for: config, from: vaults) == .missing)
  }

  @Test("A connect with only the form's scoped secret leases, and the remembered save keeps it")
  func connectWithScopedSecretLeases() async throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let vaults = InMemoryVaultSecretStore()
    let client = VaultFormFakeClient()
    let manager = DatabaseConnectionManager(
      sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()),
      vaultLeasing: VaultLeasing(makeClient: { _ in client }, store: vaults))
    var config = Self.vaultConfig()
    config.sslMode = .disable
    config.protectionLevel = .none
    config.protectedMode = false
    let scoped = VaultCredentialStore.scoped(.token("typed"), for: config)
    defer { scoped?.clear() }
    let saved = try await VaultCredentialStore.$operationSecret.withValue(scoped) {
      try await manager.connect(config: config)
      return SessionManager.saveConnection(
        config, defaults: harness.defaults, passwords: harness.store, vaultSecrets: vaults)
    }
    #expect(saved)
    #expect(client.calls == [.read(token: "typed")])
    #expect(manager.holdsLease)
    #expect(VaultCredentialStore.lookup(for: config, from: vaults) == .found(.token("typed")))
    await manager.disconnect()
    #expect(client.calls.last == .revoke(id: "lease-1"))
  }

  // MARK: - Unreadable passwords

  @Test("A save never deletes a saved password the Keychain could not read")
  func saveKeepsUnreadablePassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let store = UnreadableConnectionPasswordStore()
    var plain = Self.vaultConfig()
    plain.vault = nil
    let row = ConnectionHistoryEntry(config: plain)
    harness.defaults.set(try JSONEncoder().encode([row]), forKey: Self.historyKey)

    // Switching the row to Vault deletes a readable saved password; this one could not be read
    #expect(
      SessionManager.saveConnection(
        Self.vaultConfig(), defaults: harness.defaults, passwords: store,
        vaultSecrets: InMemoryVaultSecretStore()))
    #expect(store.readKeys == [row.keychainKey])
    #expect(store.deletedKeys.isEmpty)
  }

  @Test("An edit never deletes a saved password the Keychain could not read")
  func replaceKeepsUnreadablePassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let store = UnreadableConnectionPasswordStore()
    let row = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    harness.defaults.set(try JSONEncoder().encode([row]), forKey: Self.historyKey)

    // The form could not read the password either, so its field is empty
    var renamed = row.config
    renamed.name = "Renamed"
    #expect(
      SessionManager.replaceConnection(
        id: row.id, with: renamed, defaults: harness.defaults, passwords: store))
    #expect(store.deletedKeys.isEmpty)

    var retargeted = renamed
    retargeted.host = "db.other"
    #expect(
      SessionManager.replaceConnection(
        id: row.id, with: retargeted, defaults: harness.defaults, passwords: store))
    #expect(!store.deletedKeys.contains(row.keychainKey))
  }

  /// A saved entry from a newer build whose engine this build does not know.
  private static func unknownEntry() throws -> [String: Any] {
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "future", database: "lake", username: "bob"))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    var config = try #require(object["config"] as? [String: Any])
    config["databaseType"] = "FutureEngine"
    config["futureOnlyField"] = ["nested": true]
    object["config"] = config
    return object
  }

  @MainActor
  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.session-manager.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func write(valid: ConnectionHistoryEntry, unknown: [String: Any]) throws {
      let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
      defaults.set(
        try JSONSerialization.data(withJSONObject: [validObject, unknown]),
        forKey: SessionManagerTests.historyKey)
    }

    /// Stored entries whose engine is unknown, normalized for comparison.
    func storedUnknownEntries() throws -> [Data?] {
      let data = try #require(defaults.data(forKey: SessionManagerTests.historyKey))
      let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
      return array.filter {
        ($0["config"] as? [String: Any])?["databaseType"] as? String == "FutureEngine"
      }.map { LocalDataJSON.jsonData(from: $0) }
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
