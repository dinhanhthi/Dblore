// Bulk save of imported connections: one history load and one write, no silent overwrite.

import Foundation
import Testing

@testable import Dblore

@Suite("Session manager bulk save")
@MainActor
struct SessionManagerBulkSaveTests {
  private nonisolated static let historyKey = "ace.thi.dblore.connectionHistory"

  private static func imported(
    _ name: String, host: String = "db.example", database: String = "app",
    password: String? = nil, bastion: String? = nil, sshCredential: SSHStoredCredential? = nil
  ) -> ImportedConnection {
    var config = ConnectionConfig(
      host: host, port: 5432, database: database, username: "ada", rememberConnection: false,
      name: name)
    if let bastion {
      config.sshTunnel = SSHTunnelConfig(host: bastion, username: "jump")
    }
    return ImportedConnection(
      config: config, password: password, sshCredential: sshCredential, source: .uri)
  }

  private func history(_ harness: Harness) -> [ConnectionHistoryEntry] {
    SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
  }

  @Test("N items load history once and write it once")
  func oneLoadOneWrite() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    SessionManager.saveConnection(
      ConnectionConfig(
        host: "old.example", database: "app", username: "ada", password: "old",
        rememberConnection: true),
      defaults: harness.defaults, passwords: harness.store)
    let loadsBefore = harness.store.loadedKeys.count
    harness.defaults.historyWrites = 0

    let report = SessionManager.saveConnections(
      (1...3).map { Self.imported("c\($0)", database: "db\($0)", password: "p\($0)") },
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 3)
    #expect(harness.store.loadedKeys.count - loadsBefore == 1)
    #expect(harness.defaults.historyWrites == 1)
    let saved = history(harness)
    #expect(saved.count == 4)
    #expect(
      saved.filter { $0.config.name.hasPrefix("c") }.allSatisfy { $0.config.rememberConnection })
  }

  @Test("A duplicate of a saved connection is skipped and the saved one is untouched")
  func duplicateOfExistingSkipped() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    SessionManager.saveConnection(
      ConnectionConfig(
        host: "db.example", database: "app", username: "ada", password: "original",
        rememberConnection: true, name: "Mine"),
      defaults: harness.defaults, passwords: harness.store)
    let before = try #require(history(harness).first)
    let savesBefore = harness.store.savedKeys.count

    let report = SessionManager.saveConnections(
      [Self.imported("Imported", password: "clobber")], defaults: harness.defaults,
      passwords: harness.store, sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 0)
    #expect(report.skippedDuplicates == ["Imported"])
    #expect(harness.store.savedKeys.count == savesBefore)
    #expect(harness.store.loadPassword(forKey: before.keychainKey) == "original")
    #expect(history(harness) == [before])
  }

  @Test("Duplicates within the batch keep the first")
  func duplicateWithinBatchSkipped() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let report = SessionManager.saveConnections(
      [Self.imported("First", password: "one"), Self.imported("Second", password: "two")],
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 1)
    #expect(report.skippedDuplicates == ["Second"])
    let saved = history(harness)
    #expect(saved.map(\.config.name) == ["First"])
    #expect(saved.first?.config.password == "one")
  }

  @Test("An import sharing a saved row's Keychain key but not its bastion is skipped")
  func bastionDifferingSkipped() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    SessionManager.saveConnection(
      ConnectionConfig(
        host: "db.example", database: "app", username: "ada", password: "original",
        rememberConnection: true, name: "Mine"),
      defaults: harness.defaults, passwords: harness.store)
    let before = try #require(history(harness).first)
    let savesBefore = harness.store.savedKeys.count
    let credentials = InMemorySSHCredentialStore()
    let variant = Self.imported(
      "Bastion", password: "attacker", bastion: "evil.example",
      sshCredential: .password("ssh-secret"))
    var variantConfig = variant.config
    variantConfig.rememberConnection = true
    let account = try #require(SSHCredentialStoreFactory.account(for: variantConfig))

    let report = SessionManager.saveConnections(
      [variant], defaults: harness.defaults, passwords: harness.store,
      sshCredentials: credentials)

    #expect(report.added == 0)
    #expect(report.skippedDuplicates == ["Bastion"])
    #expect(harness.store.savedKeys.count == savesBefore)
    #expect(harness.store.loadPassword(forKey: before.keychainKey) == "original")
    #expect(history(harness) == [before])
    #expect(credentials.load(account: account) == nil)
  }

  @Test("Batch rows sharing a Keychain key keep only the first")
  func bastionDifferingWithinBatch() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let report = SessionManager.saveConnections(
      [
        Self.imported("A", password: "first", bastion: "a.example"),
        Self.imported("B", password: "second", bastion: "b.example"),
      ],
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 1)
    #expect(report.skippedDuplicates == ["B"])
    #expect(history(harness).map(\.config.name) == ["A"])
    #expect(harness.store.loadPassword(forKey: "db.example:5432:app:ada") == "first")
  }

  @Test("Passwords are saved only when present; SSH secrets under their account")
  func secretsSaved() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let credentials = InMemorySSHCredentialStore()
    let tunneled = Self.imported(
      "Tunnel", database: "t", bastion: "jump.example", sshCredential: .password("ssh-secret"))
    var expectedConfig = tunneled.config
    expectedConfig.rememberConnection = true
    let account = try #require(SSHCredentialStoreFactory.account(for: expectedConfig))

    let report = SessionManager.saveConnections(
      [
        Self.imported("WithPassword", database: "a", password: "pw"),
        Self.imported("Empty", database: "b", password: ""),
        Self.imported("None", database: "c"),
        tunneled,
      ],
      defaults: harness.defaults, passwords: harness.store, sshCredentials: credentials)

    #expect(report.added == 4)
    #expect(harness.store.savedKeys == ["db.example:5432:a:ada"])
    #expect(credentials.load(account: account) == .password("ssh-secret"))
  }

  @Test("The report holds no secrets")
  func reportHasNoSecrets() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    SessionManager.saveConnection(
      ConnectionConfig(
        host: "db.example", database: "app", username: "ada", password: "x",
        rememberConnection: true),
      defaults: harness.defaults, passwords: harness.store)
    let report = SessionManager.saveConnections(
      [
        Self.imported("Dup", password: "dup-secret-1"),
        Self.imported(
          "Bad", database: "z", password: "bad-secret-2", bastion: "j.example",
          sshCredential: .password("ssh-secret-3")),
      ],
      defaults: harness.defaults, passwords: harness.store, sshCredentials: RejectingSSHStore())

    let text = String(describing: report) + String(reflecting: report)
    for secret in ["dup-secret-1", "bad-secret-2", "ssh-secret-3"] {
      #expect(!text.contains(secret))
    }
  }

  @Test("A failed Keychain write leaves the entry out of history")
  func keychainFailure() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let report = SessionManager.saveConnections(
      [
        Self.imported(
          "Bad", database: "z", password: "pw", bastion: "j.example",
          sshCredential: .password("s")),
        Self.imported("Good", database: "g"),
      ],
      defaults: harness.defaults, passwords: harness.store, sshCredentials: RejectingSSHStore())

    #expect(report.added == 1)
    #expect(report.failed.map(\.name) == ["Bad"])
    #expect(history(harness).map(\.config.name) == ["Good"])
    #expect(harness.store.savedKeys.isEmpty)
  }

  @Test("Entries from an unknown engine survive a bulk save")
  func unknownEntriesPreserved() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(
        host: "old.example", database: "app", username: "ada", rememberConnection: true))
    let unknown: [String: Any] = [
      "id": UUID().uuidString, "lastUsedAt": 0,
      "config": ["databaseType": "FutureEngine", "host": "x"],
    ]
    let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
    harness.defaults.set(
      try JSONSerialization.data(withJSONObject: [validObject, unknown]), forKey: Self.historyKey)

    SessionManager.saveConnections(
      [Self.imported("New")], defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    let data = try #require(harness.defaults.data(forKey: Self.historyKey))
    let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(array.count == 3)
    #expect(
      array.contains {
        ($0["config"] as? [String: Any])?["databaseType"] as? String == "FutureEngine"
      })
  }

  @Test("An import sharing an undecodable row's Keychain key is skipped")
  func duplicateOfUnknownEntrySkipped() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let unknown: [String: Any] = [
      "id": UUID().uuidString, "lastUsedAt": 0,
      "config": [
        "databaseType": "FutureEngine", "host": "db.example", "port": 5432, "database": "app",
        "username": "ada",
      ],
    ]
    harness.defaults.set(
      try JSONSerialization.data(withJSONObject: [unknown]), forKey: Self.historyKey)
    let before = try #require(harness.defaults.data(forKey: Self.historyKey))

    let report = SessionManager.saveConnections(
      [Self.imported("Imported", password: "clobber", bastion: "evil.example")],
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 0)
    #expect(report.skippedDuplicates == ["Imported"])
    #expect(harness.store.savedKeys.isEmpty)
    #expect(harness.defaults.data(forKey: Self.historyKey) == before)
  }

  @Test("Saved keys include decodable and undecodable rows")
  func savedConnectionKeys() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    SessionManager.saveConnection(
      ConnectionConfig(
        host: "old.example", database: "app", username: "ada", rememberConnection: true),
      defaults: harness.defaults, passwords: harness.store)
    let data = try #require(harness.defaults.data(forKey: Self.historyKey))
    var rows = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    rows.append([
      "id": UUID().uuidString, "lastUsedAt": 0,
      "config": [
        "databaseType": "FutureEngine", "host": "db.example", "port": 5432, "database": "app",
        "username": "ada",
      ],
    ])
    harness.defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: Self.historyKey)
    let loadsBefore = harness.store.loadedKeys.count

    let keys = SessionManager.savedConnectionKeys(defaults: harness.defaults)

    #expect(keys == ["old.example:5432:app:ada", "db.example:5432:app:ada"])
    #expect(harness.store.loadedKeys.count == loadsBefore)
  }

  @Test("Report names are one line and bounded")
  func reportNamesBounded() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let long = String(repeating: "x", count: 200)
    let report = SessionManager.saveConnections(
      [
        Self.imported("first"),
        Self.imported(long),
        Self.imported(
          "bad\n" + long, database: "z", bastion: "j.example", sshCredential: .password("s")),
      ],
      defaults: harness.defaults, passwords: harness.store, sshCredentials: RejectingSSHStore())

    let names = report.skippedDuplicates + report.failed.map(\.name)
    #expect(names.count == 2)
    #expect(names.allSatisfy { $0.count <= 80 && !$0.contains("\n") })
  }

  @Test("Imports past the limit are dropped without saving their secrets")
  func limitOnImports() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let report = SessionManager.saveConnections(
      (1...51).map { Self.imported("c\($0)", database: "db\($0)", password: "p\($0)") },
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 50)
    #expect(report.droppedByLimit == 1)
    #expect(history(harness).count == 50)
    #expect(!harness.store.savedKeys.contains("db.example:5432:db51:ada"))
  }

  @Test("Imports fill only free slots and never evict saved connections")
  func limitKeepsExisting() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    for index in 1...49 {
      SessionManager.saveConnection(
        ConnectionConfig(
          host: "old.example", database: "o\(index)", username: "ada", password: "old\(index)",
          rememberConnection: true),
        defaults: harness.defaults, passwords: harness.store)
    }

    let report = SessionManager.saveConnections(
      (1...3).map { Self.imported("c\($0)", database: "db\($0)", password: "p\($0)") },
      defaults: harness.defaults, passwords: harness.store,
      sshCredentials: InMemorySSHCredentialStore())

    #expect(report.added == 1)
    #expect(report.droppedByLimit == 2)
    let databases = history(harness).map(\.config.database)
    #expect(databases.count == 50)
    #expect((1...49).allSatisfy { databases.contains("o\($0)") })
    #expect(databases.contains("db1"))
    #expect(harness.store.deletedKeys.isEmpty)
    #expect(harness.store.loadPassword(forKey: "old.example:5432:o1:ada") == "old1")
    #expect(!harness.store.savedKeys.contains("db.example:5432:db2:ada"))
    #expect(!harness.store.savedKeys.contains("db.example:5432:db3:ada"))
  }

  // MARK: - Helpers

  private final class RejectingSSHStore: SSHCredentialStore, @unchecked Sendable {
    func load(account: String) -> SSHStoredCredential? { nil }
    func save(_ credential: SSHStoredCredential, account: String) -> Bool { false }
    func delete(account: String) {}
  }

  /// Counts writes of the history key.
  private final class CountingDefaults: UserDefaults {
    var historyWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
      if defaultName == SessionManagerBulkSaveTests.historyKey { historyWrites += 1 }
      super.set(value, forKey: defaultName)
    }
  }

  private struct Harness {
    let suiteName: String
    let defaults: CountingDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.bulk-save.\(UUID().uuidString)"
      defaults = try #require(CountingDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
