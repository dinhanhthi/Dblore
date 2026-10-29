// LockGateTests.swift
// Lock state source: the identity a lock covers, the registry (grants, relock, a config's own
// flag ignored) and the saved-row invariant (every saved row of a locked identity carries the
// lock). The connection manager refuses a blocked identity before any script, session or
// statement, and its own internal resets keep a live session after a relock. Each test injects
// its own LockRegistry and an isolated UserDefaults suite: no test touches LockRegistry.shared,
// the real Keychain or UserDefaults.standard. Sessions are fakes (no live database).

import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

/// Answers every unlock with `answer` without showing anything
@MainActor
private final class AnsweringUnlockPrompter: UnlockPrompter {
  let answer: Bool
  private(set) var asked: [LockIdentity] = []

  init(answer: Bool) { self.answer = answer }

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool {
    asked.append(item)
    return answer
  }
}

/// Owner authentication without a prompt: refuses until `grants`, and counts the asks
@MainActor
private final class AnsweringOwnerAuthenticator: BiometricAuthenticator {
  var grants = false
  private(set) var prompts = 0

  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }

  func authenticateOwner(reason: String) async -> OwnerAuthentication? {
    prompts += 1
    guard grants else { return nil }
    return await GrantingOwnerTestAuthenticator().authenticateOwner(reason: reason)
  }
}

/// Relocks every item while its prompt is open, then answers that the owner authenticated
private struct RelockingUnlockPrompter: UnlockPrompter {
  let registry: LockRegistry

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool {
    registry.relockAll()
    return true
  }
}

/// Names of the connection scripts started, in order
private nonisolated final class StartedScripts: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  func append(_ name: String) { lock.withLock { names.append(name) } }
  var all: [String] { lock.withLock { names } }
}

/// Records its start and succeeds; `pw.sh` prints a password
private nonisolated final class RecordingScript: ConnectionScriptTask, @unchecked Sendable {
  var standardOutput: FileHandle?
  var standardError: FileHandle?
  let name: String
  let started: StartedScripts

  init(name: String, started: StartedScripts) {
    self.name = name
    self.started = started
  }

  func execute(
    withArguments arguments: [String]?, completionHandler handler: NSUserUnixTask.CompletionHandler?
  ) {
    started.append(name)
    let (out, name) = (standardOutput, name)
    DispatchQueue.global().async {
      if name == "pw.sh" { try? out?.write(contentsOf: Data("from-command\n".utf8)) }
      handler?(nil)
    }
  }
}

@Suite("Lock Gate")
@MainActor
struct LockGateTests {
  /// A login on a host unique to this test, so rows never meet another test's
  private static func server(
    host: String = "lock-\(UUID().uuidString).example", database: String = "app"
  ) -> ConnectionConfig {
    ConnectionConfig(host: host, database: database, username: "ada")
  }

  private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "LockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  private static func rows(
    _ config: ConnectionConfig, defaults: UserDefaults, registry: LockRegistry
  ) -> [ConnectionHistoryEntry] {
    SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore(), registry: registry)
      .filter { $0.config.host == config.host }
  }

  @Test("A server lock covers every database of the login; file locks follow the file")
  func identityFromConfig() {
    let login = Self.server(host: "DB.Example")
    var other = login
    other.database = "reports"
    other.host = "db.example"
    #expect(LockIdentity(login) == LockIdentity(other))
    #expect(
      LockIdentity(login)
        == .server(engine: .postgresql, host: "db.example", port: 5432, username: "ada"))
    var otherUser = login
    otherUser.username = "bob"
    #expect(LockIdentity(login) != LockIdentity(otherUser))

    let file = ConnectionConfig(databaseType: .sqlite, database: "/tmp/qa/..//app.sqlite")
    #expect(LockIdentity(file) == .file(engine: .sqlite, path: "/tmp/app.sqlite"))
    let memory = ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath)
    #expect(LockIdentity(memory) == .file(engine: .duckdb, path: DuckDBSession.inMemoryPath))
  }

  @Test("Every spelling of one server host or one file names the same identity")
  func identitySpellingsMatch() throws {
    func host(_ name: String) -> LockIdentity { LockIdentity(Self.server(host: name)) }
    #expect(host(" DB.Example. ") == host("db.example"))
    let ipv6 = host("2001:db8::1")
    for spelling in ["[2001:DB8::1]", "2001:0db8:0:0:0:0:0:0001", "2001:db8::0:1"] {
      #expect(host(spelling) == ipv6)
    }
    let loopback = host("localhost")
    for alias in [
      "LOCALHOST.", "127.0.0.1", "127.1.2.3", "::1", "[::1]", "::ffff:127.0.0.1",
      // The numeric forms the resolver accepts, the unspecified address, zones, local names
      "127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "0", "0.0.0.0", "0.1.2.3", "::",
      "::1%lo0", "[::1%lo0]", "app.localhost", "LOCALHOST.LOCALDOMAIN.",
    ] {
      #expect(host(alias) == loopback, "\(alias)")
    }
    #expect(host("128.0.0.1") != loopback)
    #expect(host("0x80.1") == host("128.0.0.1"))
    // Hex-looking host names stay names; a name with spaces is never parsed as an address
    #expect(
      host("deadbeef")
        == .server(engine: .postgresql, host: "deadbeef", port: 5432, username: "ada"))
    #expect(host("127.1 x") != loopback)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-paths-\(UUID().uuidString)", isDirectory: true)
    let real = folder.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = real.appendingPathComponent("App.sqlite")
    try Data().write(to: file)
    let link = folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    func path(_ text: String) -> LockIdentity {
      LockIdentity(ConnectionConfig(databaseType: .sqlite, database: text))
    }
    let identity = path(file.path)
    #expect(path(link.appendingPathComponent("App.sqlite").path) == identity)
    #expect(path(file.absoluteString) == identity)
    // A file not created yet resolves through its folder's link too
    #expect(
      path(link.appendingPathComponent("new.sqlite").path)
        == path(real.appendingPathComponent("new.sqlite").path))
    let caseInsensitive =
      try real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      .volumeSupportsCaseSensitiveNames == false
    #expect((path(real.appendingPathComponent("APP.SQLITE").path) == identity) == caseInsensitive)
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(path("~/lock-\(file.lastPathComponent)") == path(home.path + "/lock-App.sqlite"))
    // A relative path names the file the engine opens: the one in the working directory
    let cwd = FileManager.default.currentDirectoryPath
    #expect(path("lock-rel.sqlite") == path(cwd + "/lock-rel.sqlite"))
    #expect(path("./lock-rel.sqlite") == path(cwd + "/lock-rel.sqlite"))
  }

  @Test("A renamed or hard-linked locked file stays locked; one grant opens both names")
  func fileIDFollowsTheFile() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-ids-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("locked.sqlite")
    try Data().write(to: original)
    func config(_ url: URL) -> ConnectionConfig {
      ConnectionConfig(databaseType: .sqlite, database: url.path)
    }
    let registry = LockRegistry()
    registry.setLockedConnections(LockIdentity.all(config(original)))

    let link = folder.appendingPathComponent("alias.sqlite")
    try FileManager.default.linkItem(at: original, to: link)
    #expect(registry.refusal(for: config(link)) != nil)
    registry.grant(LockIdentity(config(original)))
    #expect(registry.refusal(for: config(original)) == nil)
    #expect(registry.refusal(for: config(link)) == nil)
    registry.revoke(LockIdentity(config(original)))
    #expect(registry.refusal(for: config(link)) != nil)

    try FileManager.default.removeItem(at: link)
    let moved = folder.appendingPathComponent("moved.sqlite")
    try FileManager.default.moveItem(at: original, to: moved)
    #expect(registry.refusal(for: config(moved)) != nil)
    // Another file in the same folder is not locked
    let other = folder.appendingPathComponent("other.sqlite")
    try Data().write(to: other)
    #expect(registry.refusal(for: config(other)) == nil)
  }

  @Test("A path's grant or revoke covers the fileID published for it, whatever stat sees then")
  func fileGrantFollowsThePublishedFileID() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-pairing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("locked.sqlite")
    let config = ConnectionConfig(databaseType: .sqlite, database: path.path)
    let identity = LockIdentity(config)
    let registry = LockRegistry()

    // Unlocked while stat saw no file; a later publish adds its fileID: the grant still opens it
    registry.setLockedConnections(LockIdentity.all(config))
    registry.grant(identity)
    try Data().write(to: path)
    registry.setLockedConnections(LockIdentity.all(config))
    #expect(LockIdentity.all(config).count == 2)
    #expect(registry.refusal(for: config) == nil)

    // Granted again while stat sees the file, revoked once it sees none: the fileID's unlock
    // goes too
    registry.grant(identity)
    let moved = folder.appendingPathComponent("moved.sqlite")
    try FileManager.default.moveItem(at: path, to: moved)
    let movedConfig = ConnectionConfig(databaseType: .sqlite, database: moved.path)
    #expect(registry.refusal(for: movedConfig) == nil)
    registry.revoke(identity)
    #expect(registry.refusal(for: movedConfig) != nil)
  }

  @Test("A republish after the locked file was renamed or replaced keeps every fileID it had")
  func republishKeepsRenamedFileLocked() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-republish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("locked.sqlite")
    try Data().write(to: path)
    let config = ConnectionConfig(databaseType: .sqlite, database: path.path)
    let identity = LockIdentity(config)
    let registry = LockRegistry()
    registry.setLockedConnections([identity])

    // Renamed outside Dblore, then the history loads again: stat no longer finds the path
    let moved = folder.appendingPathComponent("moved.sqlite")
    try FileManager.default.moveItem(at: path, to: moved)
    let movedConfig = ConnectionConfig(databaseType: .sqlite, database: moved.path)
    registry.setLockedConnections([identity])
    #expect(registry.refusal(for: movedConfig) != nil)
    registry.grant(identity)
    #expect(registry.refusal(for: movedConfig) == nil)
    registry.revoke(identity)
    #expect(registry.refusal(for: movedConfig) != nil)

    // A new file at the saved path: the renamed one and the new one are both locked
    try Data().write(to: path)
    registry.setLockedConnections([identity])
    #expect(registry.refusal(for: movedConfig) != nil)
    #expect(registry.refusal(for: config) != nil)
    // The path leaves the locked set: its pairing goes with it
    registry.setLockedConnections([])
    #expect(registry.refusal(for: movedConfig) == nil)
  }

  @Test("A MongoDB connection string's hosts share the row's lock; a decoy host hides none")
  func mongoURIHostsShareTheLock() throws {
    try Self.withDefaults { defaults in
      let registry = LockRegistry()
      let (first, second) = (
        "lock-a-\(UUID().uuidString).example", "lock-b-\(UUID().uuidString).example"
      )
      var locked = ConnectionConfig(
        databaseType: .mongodb, host: first, port: 27017, database: "db", username: "ada")
      locked.mongoURI = "mongodb://\(first):27017,\(second):27018/db"
      locked.isLocked = true
      #expect(
        SessionManager.saveConnection(
          locked, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      // Locked in an earlier session: the first save's grant ends with a relock
      registry.relockAll()

      // Every member of the locked row's seed list is locked
      let member = ConnectionConfig(
        databaseType: .mongodb, host: second, port: 27018, database: "db", username: "ada")
      #expect(registry.refusal(for: member) != nil)
      // A config whose host is a decoy but whose connection string reaches a locked member
      var decoy = ConnectionConfig(
        databaseType: .mongodb, host: "decoy-\(UUID().uuidString).example", port: 27017,
        database: "db", username: "ada")
      decoy.mongoURI = "mongodb://\(second):27018/db"
      #expect(registry.refusal(for: decoy) != nil)
      decoy.mongoURI = "mongodb+srv://\(first)/db"
      #expect(registry.refusal(for: decoy) != nil)
      decoy.mongoURI = "mongodb://decoy-\(UUID().uuidString).example/db"
      #expect(registry.refusal(for: decoy) == nil)
    }
  }

  @Test("Trimming the history to its cap evicts unlocked rows, never a locked one")
  func historyTrimKeepsLockedRows() throws {
    try Self.withDefaults { defaults in
      let registry = LockRegistry()
      var locked = Self.server()
      locked.isLocked = true
      // Saved first: the oldest row, the one a plain trim drops
      for config in [locked]
        + (0..<SessionManager.maxConnectionHistorySize).map({ _ in
          Self.server()
        })
      {
        #expect(
          SessionManager.saveConnection(
            config, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
        // Locked in an earlier session: the first save's grant ends with a relock
        if config.isLocked { registry.relockAll() }
      }
      let history = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry)
      #expect(history.count == SessionManager.maxConnectionHistorySize)
      #expect(history.contains { $0.config.host == locked.host && $0.config.isLocked })
      #expect(registry.isBlocked(LockIdentity(locked)))
    }
  }

  @Test("Grants unlock one identity until revoked or relocked; isLocked ignores grants")
  func grantsAndRelock() {
    let registry = LockRegistry()
    let locked = Self.server()
    let identity = LockIdentity(locked)
    registry.setLockedConnections([identity])

    #expect(registry.isBlocked(identity))
    #expect(registry.refusal(for: locked) != nil)
    // A config claiming to be unlocked is still refused: only saved rows count
    var claim = locked
    claim.isLocked = false
    #expect(registry.refusal(for: claim) != nil)
    // And a config claiming a lock no saved row has is not refused
    var stranger = Self.server()
    stranger.isLocked = true
    #expect(registry.refusal(for: stranger) == nil)

    registry.grant(identity)
    #expect(!registry.isBlocked(identity))
    #expect(registry.refusal(for: locked) == nil)
    #expect(registry.isLocked(identity))

    registry.revoke(identity)
    #expect(registry.isBlocked(identity))

    registry.grant(identity)
    let generation = registry.generation
    registry.relockAll()
    #expect(registry.isBlocked(identity))
    #expect(registry.generation == generation + 1)
    // A grant read against the generation before that relock is void; the current one grants
    #expect(!registry.grant(identity, ifGeneration: generation))
    #expect(registry.isBlocked(identity))
    #expect(registry.grant(identity, ifGeneration: generation + 1))
    #expect(!registry.isBlocked(identity))
  }

  @Test("A grant stores only identities that are locked: locking one later still asks")
  func grantSkipsUnlockedIdentities() {
    let registry = LockRegistry()
    let locked = LockIdentity(Self.server())
    let later = LockIdentity(Self.server())
    registry.setLockedConnections([locked])

    #expect(registry.grant([locked, later], ifGeneration: registry.generation))
    #expect(!registry.isBlocked(locked))
    registry.setLockedConnections([locked, later])
    #expect(!registry.isBlocked(locked))
    #expect(registry.isBlocked(later))
  }

  @Test(
    "A new row of a locked login is saved locked; deleting the first row asks and keeps the lock")
  func newRowOfLockedLoginStaysLocked() throws {
    try Self.withDefaults { defaults in
      let registry = LockRegistry()
      var first = Self.server()
      first.isLocked = true
      #expect(
        SessionManager.saveConnection(
          first, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      // Locked in an earlier session: the first save's grant ends with a relock
      registry.relockAll()
      #expect(registry.isBlocked(LockIdentity(first)))
      // An isolated history never reaches the shared registry (the default `registry:`); the
      // shared registry is only read
      var isolated = Self.server()
      isolated.isLocked = true
      #expect(
        SessionManager.saveConnection(isolated, defaults: defaults, passwords: NoPasswordStore()))
      #expect(!LockRegistry.shared.isLocked(LockIdentity(isolated)))

      // A second database of the same login, from a fresh form draft
      var second = first
      second.database = "reports"
      second.isLocked = false
      #expect(
        SessionManager.saveConnection(
          second, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      // An imported third database
      var third = first
      third.database = "audit"
      third.isLocked = false
      let report = SessionManager.saveConnections(
        [ImportedConnection(config: third, source: .uri)], defaults: defaults,
        passwords: NoPasswordStore(), registry: registry)
      #expect(report.added == 1)

      let rows = Self.rows(first, defaults: defaults, registry: registry)
      #expect(rows.count == 3)
      #expect(rows.allSatisfy { $0.config.isLocked })

      // Deleting the original row is refused until the login is unlocked
      let original = try #require(rows.first { $0.config.database == "app" })
      #expect(
        !SessionManager.removeConnection(
          id: original.id, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(registry.grant(LockIdentity.all(first), ifGeneration: registry.generation))
      #expect(
        SessionManager.removeConnection(
          id: original.id, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      #expect(Self.rows(first, defaults: defaults, registry: registry).count == 2)
      #expect(registry.isLocked(LockIdentity(first)))
    }
  }

  @Test("Editing an unlocked row onto a locked login's key keeps that login locked")
  func replaceOntoLockedLoginKeepsLock() throws {
    try Self.withDefaults { defaults in
      let registry = LockRegistry()
      var locked = Self.server()
      locked.isLocked = true
      let unlocked = Self.server()
      for config in [locked, unlocked] {
        #expect(
          SessionManager.saveConnection(
            config, defaults: defaults, passwords: NoPasswordStore(), registry: registry))
      }
      // Locked in an earlier session: the first save's grant ends with a relock
      registry.relockAll()
      let row = try #require(Self.rows(unlocked, defaults: defaults, registry: registry).first)

      // The edit retargets the unlocked row to the locked row's host, port, database and user,
      // which overwrites the locked row: refused until that login is unlocked
      var edited = unlocked
      edited.host = locked.host
      #expect(
        !SessionManager.replaceConnection(
          id: row.id, with: edited, defaults: defaults, passwords: NoPasswordStore(),
          registry: registry))
      #expect(registry.grant(LockIdentity.all(locked), ifGeneration: registry.generation))
      #expect(
        SessionManager.replaceConnection(
          id: row.id, with: edited, defaults: defaults, passwords: NoPasswordStore(),
          registry: registry))

      let rows = Self.rows(locked, defaults: defaults, registry: registry)
      #expect(rows.map(\.id) == [row.id])
      #expect(rows.first?.config.isLocked == true)
      #expect(registry.isLocked(LockIdentity(locked)))
    }
  }

  @Test(
    "Saving onto the key of another engine's blocked locked row is refused until it is unlocked")
  func saveOverLockedRowOfAnotherEngineKeepsLock() throws {
    try Self.withDefaults { defaults in
      let registry = LockRegistry()
      let passwords = RecordingConnectionPasswordStore()
      var locked = Self.server()
      locked.isLocked = true
      locked.password = "secret"
      let key = ConnectionKeychainKey.password(for: locked)
      #expect(
        SessionManager.saveConnection(
          locked, defaults: defaults, passwords: passwords, registry: registry))
      // Locked in an earlier session: the first save's grant ends with a relock
      registry.relockAll()
      // SQLite, like PostgreSQL, has no Keychain scope: the same fields name the same row
      let other = ConnectionConfig(
        databaseType: .sqlite, host: locked.host, port: locked.port, database: locked.database,
        username: locked.username)
      // Overwriting the blocked row would drop its login's lock
      #expect(
        !SessionManager.saveConnection(
          other, defaults: defaults, passwords: passwords, registry: registry))
      #expect(
        Self.rows(locked, defaults: defaults, registry: registry).map(\.config.databaseType) == [
          .postgresql
        ])
      #expect(passwords.loadPassword(forKey: key) == "secret")

      #expect(registry.grant(LockIdentity.all(locked), ifGeneration: registry.generation))
      #expect(
        SessionManager.saveConnection(
          other, defaults: defaults, passwords: passwords, registry: registry))
      let rows = Self.rows(locked, defaults: defaults, registry: registry)
      #expect(rows.map(\.config.databaseType) == [.sqlite])
      #expect(rows.first?.config.isLocked == true)
      #expect(registry.isBlocked(LockIdentity(other)))
      // The overwritten login's password does not stay behind under the new row's key
      #expect(passwords.loadPassword(forKey: key) == nil)
    }
  }

  @Test("An unlock grants the identity only after the prompt succeeds")
  func requestUnlockGrantsOnlyOnSuccess() async {
    let registry = LockRegistry()
    let identity = LockIdentity(Self.server())
    registry.setLockedConnections([identity])
    let vault = UnlockPasswordVault.lockPassword(store: InMemoryPasswordStore())

    let refusing = AnsweringUnlockPrompter(answer: false)
    let refused = LockCenter(registry: registry, lockVault: vault, prompter: refusing)
    #expect(await refused.requestUnlock(identity, reason: "Open", anchor: nil) == false)
    #expect(refusing.asked == [identity])
    #expect(registry.isBlocked(identity))

    let granting = AnsweringUnlockPrompter(answer: true)
    let center = LockCenter(registry: registry, lockVault: vault, prompter: granting)
    #expect(await center.requestUnlock(identity, reason: "Open", anchor: nil))
    #expect(!registry.isBlocked(identity))
  }

  @Test("A first Lock password asks owner authentication while anything is locked")
  @MainActor
  func setLockPasswordAsksOwnerWhileLocked() async {
    let registry = LockRegistry()
    let vault = UnlockPasswordVault(
      store: InMemoryPasswordStore(), minimumLength: UnlockPasswordVault.lockMinimumLength,
      iterations: 1_000)
    let owner = AnsweringOwnerAuthenticator()
    let center = LockCenter(
      registry: registry, lockVault: vault, prompter: RefusingUnlockPrompter(),
      ownerAuthenticator: owner)

    // Nothing locked: nothing the new password could unlock, so no prompt
    #expect(await center.setLockPassword("first password", reason: "set") == .set)
    #expect(owner.prompts == 0)
    #expect(await center.setLockPassword("other password", reason: "set") == .alreadySet)

    // A locked identity: the Lock password would unlock it, so the owner proves first
    vault.removePassword()
    registry.registerWorkspace(UUID())
    #expect(await center.setLockPassword("short", reason: "set") == .tooShort)
    #expect(await center.setLockPassword("second password", reason: "set") == .notAuthenticated)
    #expect(owner.prompts == 1)
    #expect(vault.passwordState == .absent)

    owner.grants = true
    #expect(await center.setLockPassword("second password", reason: "set") == .set)
    #expect(owner.prompts == 2)
    #expect(vault.verify("second password") == .accepted)
  }

  @Test("A relock that lands while the unlock prompt is open voids that unlock")
  func relockDuringPromptRefusesGrant() async {
    let registry = LockRegistry()
    let identity = LockIdentity(Self.server())
    registry.setLockedConnections([identity])
    let center = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: RelockingUnlockPrompter(registry: registry))
    #expect(await center.requestUnlock(identity, reason: "Open", anchor: nil) == false)
    #expect(registry.isBlocked(identity))
  }

  @Test("Unlocking a config whose own login is open asks for it and grants its locked URI host")
  func requestUnlockCoversEveryBlockedMemberOfAConfig() async {
    let registry = LockRegistry()
    let (member, second) = (
      "lock-m-\(UUID().uuidString).example", "lock-n-\(UUID().uuidString).example"
    )
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "lock-own-\(UUID().uuidString).example", port: 27017,
      database: "db", username: "ada")
    config.mongoURI = "mongodb://\(member):27018,\(second):27019/db"
    func identity(_ host: String, _ port: Int) -> LockIdentity {
      LockIdentity(
        ConnectionConfig(
          databaseType: .mongodb, host: host, port: port, database: "db", username: "ada"))
    }
    registry.setLockedConnections([identity(member, 27018), identity(second, 27019)])
    #expect(!registry.isBlocked(LockIdentity(config)))
    #expect(registry.refusal(for: config) != nil)
    let vault = UnlockPasswordVault.lockPassword(store: InMemoryPasswordStore())

    let refusing = AnsweringUnlockPrompter(answer: false)
    let refused = LockCenter(registry: registry, lockVault: vault, prompter: refusing)
    #expect(await refused.requestUnlock(for: config, reason: "Open", anchor: nil) == false)
    #expect(refusing.asked == [LockIdentity(config)])
    #expect(registry.refusal(for: config) != nil)

    let granting = AnsweringUnlockPrompter(answer: true)
    let center = LockCenter(registry: registry, lockVault: vault, prompter: granting)
    #expect(await center.requestUnlock(for: config, reason: "Open", anchor: nil))
    // One prompt grants both locked hosts
    #expect(granting.asked == [LockIdentity(config)])
    #expect(!registry.isBlocked(identity(member, 27018)))
    #expect(!registry.isBlocked(identity(second, 27019)))
    #expect(registry.refusal(for: config) == nil)
  }

  @Test("Unlocking another name of a locked file asks for that name, never its fileID")
  func requestUnlockGrantsAFileIDThroughItsPath() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-unlock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("locked.sqlite")
    try Data().write(to: original)
    let link = folder.appendingPathComponent("alias.sqlite")
    try FileManager.default.linkItem(at: original, to: link)
    let lockedConfig = ConnectionConfig(databaseType: .sqlite, database: original.path)
    let linkConfig = ConnectionConfig(databaseType: .sqlite, database: link.path)
    let registry = LockRegistry()
    registry.setLockedConnections([LockIdentity(lockedConfig)])
    #expect(registry.refusal(for: linkConfig) != nil)

    let prompter = AnsweringUnlockPrompter(answer: true)
    let center = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: prompter)
    #expect(await center.requestUnlock(for: linkConfig, reason: "Open", anchor: nil))
    #expect(prompter.asked == [LockIdentity(linkConfig)])
    #expect(registry.refusal(for: linkConfig) == nil)
    // The grant is the locked path's, so revoking that path covers the other name again
    registry.revoke(LockIdentity(lockedConfig))
    #expect(registry.refusal(for: linkConfig) != nil)
  }

  @Test("A grant ends when its identity leaves the locked set; locking it again blocks it")
  func republishDropsGrantsOfUnlockedIdentities() {
    let registry = LockRegistry()
    let (kept, dropped) = (LockIdentity(Self.server()), LockIdentity(Self.server()))
    registry.setLockedConnections([kept, dropped])
    registry.grant(kept)
    registry.grant(dropped)

    registry.setLockedConnections([kept])
    registry.setLockedConnections([kept, dropped])
    #expect(!registry.isBlocked(kept))
    #expect(registry.isBlocked(dropped))
  }
  // MARK: - Connection manager refusal

  /// A fake PostgreSQL login on a host unique to this test
  private static func fakeServer() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "lock-\(UUID().uuidString).example", port: 1,
      database: "db", username: "u", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
  }

  private static func manager(
    _ factory: FakeDatabaseSessionFactory, registry: LockRegistry,
    scripts: ConnectionScriptRunner = .app
  ) -> DatabaseConnectionManager {
    DatabaseConnectionManager(sessionFactory: factory, scripts: scripts, lockSource: registry)
  }

  /// True when `body` throws `DatabaseError.connectionLocked`
  private static func refusedAsLocked(_ body: () async throws -> Void) async -> Bool {
    do {
      try await body()
      return false
    } catch DatabaseError.connectionLocked {
      return true
    } catch {
      Issue.record("Unexpected error \(error)")
      return false
    }
  }

  @Test("Connect, script connect and test refuse a locked identity before anything runs")
  func connectRefusesLockedIdentity() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["up.sh", "pw.sh", "down.sh"] {
      try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent(name))
    }
    let started = StartedScripts()
    let scripts = ConnectionScriptRunner(
      scriptsFolder: { folder },
      makeTask: { RecordingScript(name: $0.lastPathComponent, started: started) })
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.manager(factory, registry: registry, scripts: scripts)
    var config = Self.fakeServer()
    registry.setLockedConnections([LockIdentity(config)])
    // The config's own flag says unlocked: only the registry counts
    config.isLocked = false
    config.preConnectScript = "up.sh"
    config.passwordCommandScript = "pw.sh"
    config.postDisconnectScript = "down.sh"
    config.scriptTimeoutSeconds = 5

    #expect(await Self.refusedAsLocked { try await manager.connect(config: config) })
    #expect(
      await Self.refusedAsLocked { try await manager.connectRunningScripts(config: config) })
    #expect(started.all.isEmpty)
    #expect(!manager.hasPendingPostDisconnect)

    let file = ConnectionConfig(
      databaseType: .sqlite, database: "/tmp/lock-\(UUID().uuidString).sqlite")
    registry.setLockedConnections([LockIdentity(file)])
    #expect(await Self.refusedAsLocked { _ = try await manager.testConnection(config: file) })
    #expect(factory.sessions.isEmpty)
    #expect(await !manager.isConnected)
  }

  @Test("A bookmark is checked against the file it opens, not the saved path text")
  func bookmarkTargetIsChecked() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lock-bookmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let locked = folder.appendingPathComponent("locked.sqlite")
    try Data().write(to: locked)
    let bookmark = try #require(SecurityScopedAccess.bookmarkIfPossible(for: locked))
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.manager(factory, registry: registry)
    registry.setLockedConnections(
      [LockIdentity(ConnectionConfig(databaseType: .sqlite, database: locked.path))])
    // A stale saved path that names no locked file, with the locked file's bookmark
    let config = ConnectionConfig(
      databaseType: .sqlite, database: folder.appendingPathComponent("gone.sqlite").path,
      fileBookmark: bookmark, readOnlyFile: true)

    #expect(await Self.refusedAsLocked { try await manager.connect(config: config) })
    #expect(await Self.refusedAsLocked { _ = try await manager.testConnection(config: config) })
    #expect(factory.sessions.isEmpty)
    #expect(await !manager.isConnected)
  }

  @Test(
    "A grant opens the connection; after relockAll every user entry and side connect is refused")
  func relockRefusesUserEntries() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.manager(factory, registry: registry)
    let config = Self.fakeServer()
    let identity = LockIdentity(config)
    let open = ProtectionPolicy(protectionLevel: .none)
    registry.setLockedConnections([identity])
    registry.grant(identity)
    try await manager.connect(config: config)
    _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
    #expect(factory.statements == ["SELECT 1"])

    registry.relockAll()
    let sessions = factory.sessions.count
    let epoch = await manager.connectionEpoch
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.execute(userSQL: "SELECT 2", policy: open)
      })
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.execute(
          userSQL: "SELECT :id", parameters: ["id": .text("1")], policy: open)
      })
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.executeGatedSequentialBatch(
          ["DELETE FROM t WHERE id = 1"], policy: open, connectionEpoch: epoch,
          expectedRows: nil)
      })
    #expect(
      await Self.refusedAsLocked {
        try await manager.connectSideManager(manager.makeReadOnlySideManager())
      })
    // The SQL dump's snapshot reads every row
    #expect(await Self.refusedAsLocked { _ = try await manager.withDumpSnapshot { _ in 0 } })
    #expect(factory.statements == ["SELECT 1"])
    #expect(factory.sessions.count == sessions)
    // The refusals keep the live session: unlocking again runs on it
    #expect(await manager.isConnected)

    registry.grant(identity)
    _ = try await manager.execute(userSQL: "SELECT 3", policy: open)
    registry.relockAll()
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.execute(userSQL: "SELECT 4", policy: open)
      })
    #expect(factory.statements == ["SELECT 1", "SELECT 3"])
    await manager.disconnect()
  }

  @Test("After relockAll a MongoDB write, document stream and schema sample send nothing")
  func relockRefusesMongoWrite() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = Self.manager(factory, registry: registry)
    let config = ConnectionConfig(
      databaseType: .mongodb, host: "lock-\(UUID().uuidString).example", port: 27017,
      database: "db", username: "u", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    registry.setLockedConnections([LockIdentity(config)])
    registry.grant(LockIdentity(config))
    try await manager.connect(config: config)

    registry.relockAll()
    let epoch = await manager.connectionEpoch
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.executeGatedMongoCommands(
          [.insertOne(collection: "c", document: .document([]))],
          policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: epoch,
          expectedRows: nil)
      })
    // Export and backup stream every document; the Schema tab samples up to 1000
    let pages = StartedScripts()
    let find = try MongoshParser.parse("db.c.find({})")
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.streamMongoDocuments(
          find, policy: ProtectionPolicy(protectionLevel: .none), pageSize: 100,
          onPage: { _ in pages.append("page") })
      })
    #expect(pages.all.isEmpty)
    #expect(
      await Self.refusedAsLocked {
        _ = try await manager.sampleMongoDocuments(database: nil, collection: "c", filterText: "")
      })
    #expect(factory.typedCommands.isEmpty)
    #expect(factory.statements.isEmpty)
    await manager.disconnect()
  }

  @Test("After relockAll Commit is refused and the staged writes stay; Rollback still runs")
  func relockRefusesCommit() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.manager(factory, registry: registry)
    var config = Self.fakeServer()
    config.protectedMode = true
    registry.setLockedConnections([LockIdentity(config)])
    registry.grant(LockIdentity(config))
    try await manager.connect(config: config)
    _ = try await manager.execute(
      userSQL: "INSERT INTO t VALUES (1)",
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))
    let generation = await manager.transactionStatus().generation

    registry.relockAll()
    #expect(
      await Self.refusedAsLocked {
        try await manager.commitAppTransaction(expectedGeneration: generation)
      })
    #expect(!factory.statements.contains("COMMIT"))
    #expect(await manager.transactionSnapshot().pending.count == 1)
    try await manager.rollbackAppTransaction()
    #expect(factory.statements.contains("ROLLBACK"))
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("A capped read's internal reset after relockAll keeps the connection")
  func internalResetSurvivesRelock() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: [ColumnInfo(name: "id", type: "int4")],
      rows: (1...5).map { [.int($0)] })
    let manager = Self.manager(factory, registry: registry)
    let config = Self.fakeServer()
    registry.setLockedConnections([LockIdentity(config)])
    registry.grant(LockIdentity(config))
    try await manager.connect(config: config)
    let epoch = await manager.connectionEpoch
    // The lock comes back while the read runs, just before the session is reset
    await manager.setScriptCheckpointHook { checkpoint in
      if checkpoint == .beforeCapReset { registry.relockAll() }
    }

    let read = try await manager.execute(
      userSQL: "SELECT id FROM t", policy: ProtectionPolicy(protectionLevel: .none), maxRows: 2)
    #expect(read.truncated)
    #expect(read.sessionReset)
    #expect(await manager.isConnected)
    #expect(await manager.lastSessionLoss == nil)
    #expect(await manager.connectionEpoch != epoch)
    #expect(factory.sessions.count == 2)
    await manager.setScriptCheckpointHook(nil)
    await manager.disconnect()
  }

  // MARK: - MCP

  /// A pool on fake sessions whose managers check `registry`, with `entry` as its lookup
  private static func mcpPool(
    _ factory: FakeDatabaseSessionFactory, registry: LockRegistry,
    entry: @escaping MCPConnectionPool.EntryLookup
  ) -> MCPConnectionPool {
    MCPConnectionPool(
      entry: entry, sessionFactory: factory, certificates: InMemoryClientCertificateStore(),
      sshCredentials: InMemorySSHCredentialStore(), knownHosts: InMemorySSHKnownHostStore(),
      lockSource: registry)
  }

  /// The app's lookup over `rows`, all allowlisted, in an isolated settings suite
  private static func withMCPLookup(
    _ rows: [ConnectionHistoryEntry], registry: LockRegistry,
    _ body: (@escaping MCPConnectionPool.EntryLookup) async throws -> Void
  ) async throws {
    let name = "LockGateTests-\(UUID().uuidString)"
    let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    settings.mcpAllowedConnectionIDs = Set(rows.map(\.id))
    try await body(
      MCPServerController.entryLookup(
        settings: settings, savedConnections: { rows }, password: { _ in nil },
        lockSource: registry))
  }

  /// True when `body` throws `MCPConnectionError.unknownConnection`
  private static func unknownToMCP(_ body: () async throws -> Void) async -> Bool {
    do {
      try await body()
      return false
    } catch MCPConnectionError.unknownConnection {
      return true
    } catch {
      Issue.record("Unexpected error \(error)")
      return false
    }
  }

  @Test("MCP refuses every row of a locked login as unknown, even after an unlock in the app")
  func mcpRefusesLockedLogin() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let locked = Self.fakeServer()
    var sameLogin = locked
    sameLogin.database = "other"
    let rows = [locked, sameLogin, Self.fakeServer()].map { ConnectionHistoryEntry(config: $0) }
    registry.setLockedConnections(LockIdentity.all(locked))

    try await Self.withMCPLookup(rows, registry: registry) { lookup in
      let pool = Self.mcpPool(factory, registry: registry, entry: lookup)
      for row in rows.prefix(2) {
        #expect(await lookup(row.id) == nil)
        #expect(await Self.unknownToMCP { _ = try await pool.withManager(for: row.id) { $0 } })
      }
      // A session unlock in the app does not open the login to MCP
      registry.grant(LockIdentity(locked))
      #expect(await Self.unknownToMCP { _ = try await pool.withManager(for: rows[0].id) { $0 } })
      #expect(factory.sessions.isEmpty)
      // An unlocked login still connects, on a manager that checks the same registry
      let manager = try await pool.withManager(for: rows[2].id) { $0 }
      #expect(await manager.isConnected)
      #expect(manager.lockSource === registry)
      await pool.closeAll()
    }
  }

  @Test("list_connections omits every row reaching a locked identity; its tools refuse it")
  func mcpListOmitsLockedRows() async throws {
    let registry = LockRegistry()
    let locked = Self.fakeServer()
    var sameLogin = locked
    sameLogin.database = "other"
    let (first, second) = (
      "lock-a-\(UUID().uuidString).example", "lock-b-\(UUID().uuidString).example"
    )
    var lockedMongo = ConnectionConfig(
      databaseType: .mongodb, host: first, port: 27017, database: "db", username: "ada")
    lockedMongo.mongoURI = "mongodb://\(first):27017,\(second):27018/db"
    // Its own host is unlocked; its connection string reaches a locked one
    var decoy = ConnectionConfig(
      databaseType: .mongodb, host: "decoy-\(UUID().uuidString).example", port: 27017,
      database: "db", username: "ada")
    decoy.mongoURI = "mongodb://\(second):27018/db"
    let open = ConnectionHistoryEntry(config: Self.fakeServer())
    let hidden = [locked, sameLogin, decoy].map { ConnectionHistoryEntry(config: $0) }
    registry.setLockedConnections(LockIdentity.all(locked).union(LockIdentity.all(lockedMongo)))
    registry.grant(LockIdentity(locked))

    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let pool = Self.mcpPool(factory, registry: registry) { _ in nil }
    let rows = hidden + [open]
    let ids = Set(rows.map(\.id))
    let service = MCPToolService(
      connections: { rows }, allowlist: { ids }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: InMemoryQueryHistoryRecorder(),
      historyEnabled: { false }, gate: AIAccessGate(), lockSource: registry)
    let listed = await service.call("list_connections", arguments: [:])
    #expect(!listed.isError)
    #expect(listed.text.contains(open.id.uuidString))
    for row in hidden {
      #expect(!listed.text.contains(row.id.uuidString))
      let tables = await service.call(
        "list_tables", arguments: ["connection_id": JSONValue.string(row.id.uuidString)])
      #expect(tables.isError && tables.text.contains("No connection with this id"))
    }
    #expect(factory.sessions.isEmpty)
    await pool.closeAll()
  }

  @Test("The MCP pool retires a manager whose login becomes locked")
  func mcpPoolRetiresNewlyLockedManager() async throws {
    let registry = LockRegistry()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let config = Self.fakeServer()
    let row = ConnectionHistoryEntry(config: config)
    let id = row.id
    let pool = Self.mcpPool(factory, registry: registry) { $0 == id ? row : nil }
    let manager = try await pool.withManager(for: id) { $0 }
    #expect(await manager.isConnected)

    registry.setLockedConnections(LockIdentity.all(config))
    let deadline = ContinuousClock.now + .seconds(10)
    while await manager.isConnected, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await !manager.isConnected)
    #expect(await Self.unknownToMCP { _ = try await pool.withManager(for: id) { $0 } })
    await pool.closeAll()
  }
}

// MARK: - Relocked windows

/// Counts what is handed in, from any isolation
private nonisolated final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func add() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

extension LockGateTests {
  /// An open locked workspace: its session held by its manager, unlocked (granted) here
  @MainActor private struct OpenLockedWorkspace {
    let registry = LockRegistry()
    let sessions = WorkspaceLockSessions()
    let focus: FocusedActionRegistry
    let center: LockCenter
    let session: WorkspaceLockSession
    let manager: WorkspaceManager
    /// Isolated: no test reads or writes the standard defaults
    let suite = "LockGateTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init(keyWindow: @escaping () -> NSWindow? = { nil }) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      focus = FocusedActionRegistry(keyWindow: keyWindow)
      center = LockCenter(
        registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
        prompter: AnsweringUnlockPrompter(answer: true), sessions: sessions,
        focusRegistry: focus)
      let id = UUID()
      let key = SymmetricKey(size: .bits256)
      session = WorkspaceLockSession(
        workspaceId: id, contentKey: key,
        wrapBlock: try LockEnvelope.makeWrapBlock(
          contentKey: key, password: Self.password, workspaceId: id, iterations: 100_000))
      manager = WorkspaceManager(
        workspace: Workspace(id: id, name: "Ledger"), restoreTabs: false, defaults: defaults,
        passwords: NoPasswordStore(), lockCenter: center)
      manager.lockedIO = LockedFileIO(sessions: sessions, registry: registry)
      manager.lockKeyId = id
      sessions.hold(session, by: manager.id)
      registry.registerWorkspace(id)
      registry.grant(.workspace(id))
    }

    static let password = "a lock password"

    /// A workspace manager on these stores: no Keychain, no standard defaults
    func makeManager(_ workspace: Workspace) -> WorkspaceManager {
      WorkspaceManager(
        workspace: workspace, restoreTabs: false, defaults: defaults,
        passwords: NoPasswordStore(), lockCenter: center)
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
    }
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  /// Relocks `registry` and waits until `center` saw it (the notification is delivered later)
  private static func relock(_ registry: LockRegistry, seenBy center: LockCenter) async throws {
    registry.relockAll()
    let deadline = ContinuousClock.now + .seconds(5)
    while center.relocked.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!center.relocked.isEmpty)
  }

  @Test("A relocked key window withholds its menu values on both paths until the unlock")
  func relockedKeyWindowWithholdsMenuValues() async throws {
    let window = Self.makeWindow()
    let other = Self.makeWindow()
    var keyWindow: NSWindow? = window
    let open = try OpenLockedWorkspace { keyWindow }
    defer { open.cleanUp() }
    let owner = ObjectIdentifier(window)
    open.focus.publish(open.manager, for: \.activeWorkspace, owner: owner, in: window)
    open.focus.publish(DocumentMode.editor, for: \.documentMode, owner: owner, in: window)
    open.focus.publish(DocumentMode.notebook, for: \.documentMode, owner: owner, in: other)
    typealias Mode = BridgedFocusedValue<DocumentMode>
    // Unlocked: the key window's record, even over a native value (a hosted window's native
    // value lags behind a tab switch), else the native value
    #expect(Mode.resolve(.markdown, \.documentMode, in: open.focus) == .editor)
    #expect(Mode.resolve(nil, \.documentMode, in: open.focus) == .editor)
    #expect(
      BridgedFocusedValue<Bool>.resolve(true, \.isSchemaVisualizerActive, in: open.focus) == true)

    try await Self.relock(open.registry, seenBy: open.center)
    #expect(open.manager.lockCoverage == .workspace(open.session.workspaceId))
    #expect(open.focus.isKeyWindowLocked)
    #expect(Mode.resolve(.markdown, \.documentMode, in: open.focus) == nil)
    #expect(Mode.resolve(nil, \.documentMode, in: open.focus) == nil)

    // Another key window is untouched
    keyWindow = other
    #expect(!open.focus.isKeyWindowLocked)
    #expect(Mode.resolve(nil, \.documentMode, in: open.focus) == .notebook)

    // A wrong Lock password keeps the cover; the right one (against the open session's own
    // wrap block) lifts it
    keyWindow = window
    let header = open.session.header
    #expect(await open.center.unlockWorkspace(header, password: "wrong password").message != nil)
    #expect(open.manager.lockCoverage != nil)
    guard case .unlocked = await open.center.unlockWorkspace(header, password: Self.lockPassword)
    else {
      Issue.record("The open workspace's own Lock password did not unlock it")
      return
    }
    #expect(open.manager.lockCoverage == nil)
    #expect(Mode.resolve(.markdown, \.documentMode, in: open.focus) == .editor)
    #expect(Mode.resolve(nil, \.documentMode, in: open.focus) == .editor)
  }

  private static let lockPassword = OpenLockedWorkspace.password

  @Test("A window on a relocked connection is covered until its unlock; banner and plain are not")
  func relockedConnectionCoversItsWindows() async throws {
    let open = try OpenLockedWorkspace()
    defer { open.cleanUp() }
    let config = Self.server()
    let plain = Self.server()
    open.registry.setLockedConnections([LockIdentity(config)])
    open.registry.grant(LockIdentity(config))
    let connected = open.makeManager(Workspace(name: "Connected", connectionConfig: config))
    let other = open.makeManager(Workspace(name: "Plain", connectionConfig: plain))
    #expect(connected.lockCoverage == nil)

    try await Self.relock(open.registry, seenBy: open.center)
    #expect(
      connected.lockCoverage == .connection(try #require(connected.workspace.connectionConfig)))
    #expect(other.lockCoverage == nil)
    // Auto-connect stopped on the lock: nothing of it was loaded, its banner stays
    connected.isConnectLocked = true
    #expect(connected.lockCoverage == nil)
    connected.isConnectLocked = false

    #expect(await open.center.requestUnlock(for: config, reason: "unlock", anchor: nil))
    #expect(connected.lockCoverage == nil)
    // The workspace lock is its own: still covered until its own unlock
    #expect(open.manager.lockCoverage == .workspace(open.session.workspaceId))
  }

  @Test("A window whose connection attaches a relocked file is covered, named after that file")
  func relockedAttachmentCoversItsWindows() async throws {
    let open = try OpenLockedWorkspace()
    defer { open.cleanUp() }
    let folder = "/tmp/dblore-cover-\(UUID().uuidString)"
    var config = ConnectionConfig(databaseType: .sqlite, database: folder + "/main.sqlite")
    config.attachedDatabases = [AttachedDatabase(name: "aux", path: folder + "/aux.sqlite")]
    var file = SQLiteFileAccess.lockConfig(forFile: folder + "/aux.sqlite")
    file.name = "aux.sqlite"
    open.registry.setLockedConnections([LockIdentity(file)])
    open.registry.grant(LockIdentity(file))
    let connected = open.makeManager(Workspace(name: "Attached", connectionConfig: config))
    // As a connect sets it (an opened file keeps only its saved row's attachments)
    connected.workspace.connectionConfig = config
    #expect(connected.lockCoverage == nil)

    try await Self.relock(open.registry, seenBy: open.center)
    #expect(connected.lockCoverage == .connection(file))
    #expect(await open.center.requestUnlock(for: file, reason: "unlock", anchor: nil))
    #expect(connected.lockCoverage == nil)
  }

  @Test("LockCenter re-renders the menus on relock and on unlock")
  func lockCenterRefreshesMenus() async throws {
    let open = try OpenLockedWorkspace()
    defer { open.cleanUp() }
    let renders = Counter()
    let subscription = open.focus.objectWillChange.sink { _ in renders.add() }
    defer { subscription.cancel() }
    func waitForRender(after count: Int) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while renders.value == count, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    let beforeRelock = renders.value
    try await Self.relock(open.registry, seenBy: open.center)
    try await waitForRender(after: beforeRelock)
    #expect(renders.value > beforeRelock)

    let beforeUnlock = renders.value
    _ = await open.center.unlockWorkspace(open.session.header, password: Self.lockPassword)
    try await waitForRender(after: beforeUnlock)
    #expect(renders.value > beforeUnlock)
  }

  @Test("Renaming from Welcome an open relocked workspace asks first; cancel writes nothing")
  func renameOfOpenRelockedWorkspaceAsks() async throws {
    let open = try OpenLockedWorkspace()
    defer { open.cleanUp() }
    let id = open.session.workspaceId
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("LockGateTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("ledger.sqlws")
    let destination = folder.appendingPathComponent("renamed.sqlws")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try LockEnvelope.seal(
      encoder.encode(Workspace(id: id, name: "Ledger")), kind: .workspace, workspaceId: id,
      wrapBlock: open.session.wrapBlock, contentKey: open.session.contentKey
    ).write(to: source)
    open.manager.workspace.fileURL = source
    let before = try Data(contentsOf: source)
    let suite = "LockGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let recents = RecentManager(defaults: defaults)
    let entry = WorkspaceHistoryEntry(id: id, fileURL: source, name: "Ledger")
    recents.addWorkspace(entry)
    open.registry.relockAll()

    let asked = Counter()
    await #expect(throws: LockedFileIOError.unlockRefused(id)) {
      try await RecentWorkspaceEditor.apply(
        entry: entry, name: "Renamed", destination: destination, iconColor: nil,
        recents: recents, openWorkspaces: [open.manager], io: open.manager.lockedIO,
        unlock: { _ in
          asked.add()
          return nil
        })
    }
    #expect(asked.value == 1)
    #expect(open.manager.workspace.name == "Ledger")
    #expect(try Data(contentsOf: source) == before)
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    // The unlock grants (as the Welcome sheet does through LockCenter): the rename goes on
    let registry = open.registry
    let session = open.session
    try await RecentWorkspaceEditor.apply(
      entry: entry, name: "Renamed", destination: destination, iconColor: nil,
      recents: recents, openWorkspaces: [open.manager], io: open.manager.lockedIO,
      unlock: { header in
        asked.add()
        registry.grant(.workspace(header.workspaceId))
        return session
      })
    #expect(asked.value == 2)
    #expect(open.manager.workspace.name == "Renamed")
    #expect(try LockEnvelope.sniff(Data(contentsOf: destination))?.workspaceId == id)
  }

  @Test("Commands on the active workspace get nothing from a covered key window, nor create one")
  func coveredKeyWindowGivesCommandsNoWorkspace() async throws {
    let window = Self.makeWindow()
    let other = Self.makeWindow()
    var keyWindow: NSWindow? = window
    let open = try OpenLockedWorkspace { keyWindow }
    defer { open.cleanUp() }
    let plain = open.makeManager(Workspace(name: "Plain"))
    open.focus.publish(
      open.manager, for: \.activeWorkspace, owner: ObjectIdentifier(window), in: window)
    open.focus.publish(plain, for: \.activeWorkspace, owner: ObjectIdentifier(other), in: other)
    #expect(open.focus.commandWorkspace(open.manager) === open.manager)

    try await Self.relock(open.registry, seenBy: open.center)
    let created = Counter()
    #expect(open.focus.commandWorkspace(open.manager) == nil)
    #expect(open.focus.commandWorkspace(nil) == nil)
    #expect(
      open.focus.commandWorkspace(nil) {
        created.add()
        return plain
      } == nil)
    #expect(created.value == 0)

    // Another key window: its own workspace, never the covered one
    keyWindow = other
    #expect(open.focus.commandWorkspace(plain) === plain)
    #expect(open.focus.commandWorkspace(open.manager) == nil)
  }

  @Test("A sheet on a sheet of a covered window counts as that window")
  func sheetOfSheetOfCoveredWindowIsLocked() async throws {
    let window = Self.makeWindow()
    let sheet = Self.makeWindow()
    let inner = Self.makeWindow()
    var keyWindow: NSWindow? = inner
    let open = try OpenLockedWorkspace { keyWindow }
    defer {
      sheet.endSheet(inner)
      window.endSheet(sheet)
      window.orderOut(nil)
      open.cleanUp()
    }
    open.focus.publish(
      open.manager, for: \.activeWorkspace, owner: ObjectIdentifier(window), in: window)
    window.orderFront(nil)
    window.beginSheet(sheet, completionHandler: nil)
    sheet.beginSheet(inner, completionHandler: nil)
    let deadline = ContinuousClock.now + .seconds(5)
    while inner.sheetParent == nil || sheet.sheetParent == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(inner.sheetParent === sheet)
    #expect(sheet.sheetParent === window)

    try await Self.relock(open.registry, seenBy: open.center)
    #expect(open.focus.isKeyWindowLocked)
    keyWindow = sheet
    #expect(open.focus.isKeyWindowLocked)
  }

  @Test("Settings' Remove Lock of a connection always asks, also after an unlock this session")
  func settingsRemoveLockAlwaysAsks() async throws {
    let registry = LockRegistry()
    let config = Self.server()
    registry.setLockedConnections([LockIdentity(config)])
    registry.grant(LockIdentity(config))
    #expect(!registry.isBlocked(LockIdentity(config)))

    let refusing = AnsweringUnlockPrompter(answer: false)
    var center = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: refusing, sessions: WorkspaceLockSessions(),
      focusRegistry: FocusedActionRegistry(keyWindow: { nil }))
    #expect(
      !(await center.confirmLockRemoval(
        for: config, rows: [config], reason: "remove", anchor: nil)))
    #expect(refusing.asked == [LockIdentity(config)])

    let answering = AnsweringUnlockPrompter(answer: true)
    center = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: answering, sessions: WorkspaceLockSessions(),
      focusRegistry: FocusedActionRegistry(keyWindow: { nil }))
    #expect(
      await center.confirmLockRemoval(for: config, rows: [config], reason: "remove", anchor: nil))
    #expect(answering.asked == [LockIdentity(config)])
  }

  @Test("The SSH trust sheet ended from outside (the cover's sweep) answers not trusted once")
  func sshTrustSheetEndedFromOutside() async throws {
    let window = Self.makeWindow()
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let presenter = AppKitSSHHostKeyTrustPresenter()
    defer { presenter.dismissTrust() }
    let request = SSHHostKeyTrustRequest(
      host: "bastion.example", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc")
    var answers: [Bool] = []
    #expect(presenter.presentTrust(request) { answers.append($0) })
    // The frontmost window hosts it (this test's, unless the test host shows one)
    func host() -> NSWindow? {
      NSApp.windows.first {
        $0.attachedSheet?.contentViewController is NSHostingController<SSHHostKeyTrustSheet>
      }
    }
    var deadline = ContinuousClock.now + .seconds(5)
    while host() == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let parent = try #require(host())
    let sheet = try #require(parent.attachedSheet)

    parent.endSheet(sheet)
    deadline = ContinuousClock.now + .seconds(5)
    while answers.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(answers == [false])

    // The next request shows its own sheet; closing it answers nothing more
    #expect(presenter.presentTrust(request) { answers.append($0) })
    presenter.dismissTrust()
    try await Task.sleep(for: .milliseconds(100))
    #expect(answers == [false])
  }
}
