// WorkspaceFileSecurityTests.swift
// An opened workspace file never chooses which saved password auto-connect reads: the Keychain
// key comes from the file's own connection config, never from a stored key. Nor how it travels:
// the TLS mode, SSH tunnel, client certificate and connection string come from the saved row of
// that key and engine, and without one nothing is read and the connect form opens. Nor does it
// weaken the saved row's protection.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct WorkspaceFileSecurityTests {
  private static func config(
    _ type: DatabaseType = .postgresql, host: String, database: String = "app",
    sslMode: SSLMode = .disable
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: host, port: 5432, database: database, username: "ada",
      sslMode: sslMode)
  }

  /// A manager on `workspace` with an isolated recent list and the in-memory `store`.
  private static func manager(
    _ workspace: Workspace, type: DatabaseType, defaults: UserDefaults,
    store: RecordingConnectionPasswordStore
  ) -> WorkspaceManager {
    WorkspaceManager(
      workspace: workspace, restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: type.capabilities)),
      defaults: defaults, passwords: store)
  }

  @Test("A stored key naming another saved connection never reads its password")
  func foreignKeyNeverRead() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var victim = Self.config(host: "victim.example")
    victim.password = "victim-secret"
    #expect(SessionManager.saveConnection(victim, defaults: defaults, passwords: store))
    let victimKey = ConnectionKeychainKey.password(for: victim)

    var attacker = Self.config(host: "attacker.example")
    attacker.password = "file-password"  // the form never shows what the file carries
    let manager = Self.manager(
      Workspace(connectionConfig: attacker, connectionKeychainKey: victimKey),
      type: .postgresql, defaults: defaults, store: store)
    await manager.autoConnectIfNeeded()

    // No saved row of the attacker's key either: nothing is read, the form opens prefilled
    #expect(store.loadedKeys.isEmpty)
    #expect(manager.isConnectionFormModalVisible)
    #expect(manager.editingConnectionConfig.host == "attacker.example")
    #expect(manager.editingConnectionConfig.password.isEmpty)
    #expect(manager.connectionState == .disconnected)
    #expect(manager.connectionFormOpensOnDraft)
    // A Connect button opens the form fresh, on the most recent row
    manager.showConnectionForm()
    #expect(!manager.connectionFormOpensOnDraft)

    // With the attacker's own row saved, auto-connect reads the attacker's key, not the victim's
    var attackerRow = attacker
    attackerRow.password = "attacker-secret"
    #expect(SessionManager.saveConnection(attackerRow, defaults: defaults, passwords: store))
    let attackerKey = ConnectionKeychainKey.password(for: attacker)
    let saved = Self.manager(
      Workspace(connectionConfig: attacker, connectionKeychainKey: victimKey),
      type: .postgresql, defaults: defaults, store: store)
    let before = store.loadedKeys.count
    await saved.autoConnectIfNeeded()
    // The connect's own save then reloads the recent list, which reads every row's password
    #expect(store.loadedKeys.dropFirst(before).first == attackerKey)
    #expect(await saved.connectionManager.config?.password == "attacker-secret")
    await saved.performDisconnect()
  }

  @Test("A switched MongoDB workspace still reads its saved key")
  func switchedMongoReadsSavedKey() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var switched = Self.config(.mongodb, host: "mongo.example", database: "sales")
    switched.mongoHomeDatabase = "app"
    var home = Self.config(.mongodb, host: "mongo.example")
    home.password = "secret"
    #expect(SessionManager.saveConnection(home, defaults: defaults, passwords: store))
    let key = ConnectionKeychainKey.password(for: home)
    #expect(ConnectionKeychainKey.password(for: switched) == key)

    let workspace = Workspace(connectionConfig: switched, connectionKeychainKey: key)
    #expect(workspace.keychainKey == key)
    let manager = Self.manager(workspace, type: .mongodb, defaults: defaults, store: store)
    await manager.autoConnectIfNeeded()

    #expect(store.loadedKeys == [key])
    #expect(manager.editingConnectionConfig.password == "secret")
    #expect(manager.connectionState == .connected)
    await manager.performDisconnect()
  }

  /// How a file's transport differs from the saved row of the same key.
  enum TransportCase: CaseIterable, Sendable {
    case tlsOff, foreignTunnel, foreignMongoHost, droppedCA
  }

  /// The saved row and the file of `transport`.
  private static func transportPair(
    _ transport: TransportCase
  ) -> (ConnectionConfig, ConnectionConfig) {
    var saved = config(host: "victim.example", sslMode: .verifyFull)
    var file = saved
    switch transport {
    case .tlsOff:
      file.sslMode = .disable
      file.rememberConnection = false  // the file cannot opt out of its saved row
    case .foreignTunnel:
      file.sshTunnel = SSHTunnelConfig(host: "bastion.attacker.example", username: "ada")
    case .foreignMongoHost:
      saved = config(.mongodb, host: "mongo.example", sslMode: .verifyFull)
      saved.mongoURI = "mongodb://mongo.example:5432/app?tls=true"
      file = saved
      file.mongoURI = "mongodb://mongo.example:5432,attacker.example:27017/app?tls=true"
    case .droppedCA:
      // Without it the saved custom CA is skipped and the system roots verify the server
      saved.sslMode = .verifyCa
      saved.clientCertificate = ClientCertificateInfo(subject: nil, expiry: nil, hasCA: true)
      file = saved
      file.clientCertificate = nil
    }
    return (saved, file)
  }

  @Test(
    "A file's TLS mode, SSH tunnel or connection string never carries the saved password",
    arguments: TransportCase.allCases)
  func savedTransportWins(_ transport: TransportCase) async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var (saved, file) = Self.transportPair(transport)
    saved.password = "secret"
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    let key = ConnectionKeychainKey.password(for: saved)

    let manager = Self.manager(
      Workspace(connectionConfig: file, connectionKeychainKey: key),
      type: saved.databaseType, defaults: defaults, store: store)
    await manager.autoConnectIfNeeded()

    let handed = try #require(await manager.connectionManager.config)
    #expect(handed.password == "secret")
    #expect(handed.sslMode == saved.sslMode)
    #expect(handed.sshTunnel == saved.sshTunnel)
    #expect(handed.mongoURI == saved.mongoURI)
    #expect(handed.clientCertificate == saved.clientCertificate)
    #expect(Set(store.loadedKeys) == [key])
    #expect(manager.connectionState == .connected)
    await manager.performDisconnect()
  }

  @Test("Auto-connect uses the saved row's transport and protection as they are when connecting")
  func savedTransportReadAtConnect() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var saved = Self.config(host: "db.example", sslMode: .verifyFull)
    saved.password = "secret"
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    var file = saved
    file.password = ""
    let manager = Self.manager(
      Workspace(connectionConfig: file), type: .postgresql, defaults: defaults, store: store)

    // The saved row changes after the file was opened
    saved.sslMode = .require
    saved.protectionLevel = .schemaOnly
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    await manager.autoConnectIfNeeded()

    #expect(await manager.connectionManager.config?.sslMode == .require)
    #expect(await manager.connectionManager.config?.protectionLevel == .schemaOnly)
    let row = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()).first
    #expect(row?.config.protectionLevel == .schemaOnly)
    await manager.performDisconnect()
  }

  @Test("A file never weakens the saved row's protection, and a stricter file keeps its own")
  func savedProtectionNeverWeakened() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var saved = Self.config(host: "db.example")
    saved.protectionLevel = .schemaOnly
    saved.applyCommitStyle(.password)
    saved.password = "secret"
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    saved.password = ""

    var weaker = saved
    weaker.protectionLevel = .none
    weaker.applyCommitStyle(.immediate)
    let manager = Self.manager(
      Workspace(connectionConfig: weaker), type: .postgresql, defaults: defaults, store: store)
    await manager.autoConnectIfNeeded()
    #expect(manager.connectionState == .connected)
    let live = try #require(manager.workspace.connectionConfig)
    let row = try #require(
      SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()).first?.config)
    for config in [live, row] {
      #expect(config.protectionLevel == .schemaOnly)
      #expect(config.commitStyle == .password)
      #expect(config.protectedMode == saved.protectedMode)
      #expect(config.safeMode == saved.safeMode)
    }
    await manager.performDisconnect()

    // A protection picker writes only the workspace: a stricter file is the user's own change
    var stricter = saved
    stricter.protectionLevel = .readOnly
    let kept = Self.manager(
      Workspace(connectionConfig: stricter), type: .postgresql, defaults: defaults, store: store)
    #expect(kept.workspace.connectionConfig?.protectionLevel == .readOnly)

    // Each part is decided on its own: a stricter level never resets a weaker commit style's pin
    var mixed = saved
    mixed.protectionLevel = .readOnly
    mixed.applyCommitStyle(.immediate)
    let pinnedStyle = WorkspaceManager.keepingSavedProtection(
      mixed, defaults: defaults, defaultCommitStyle: .immediate)
    #expect(pinnedStyle.protectionLevel == .readOnly)
    #expect(pinnedStyle.commitStyle == .password)
    #expect(pinnedStyle.safeMode == saved.safeMode)

    // And the reverse: a weaker level is pinned, a stricter commit style kept
    saved.applyCommitStyle(.confirm)
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    mixed.protectionLevel = .none
    mixed.applyCommitStyle(.password)
    let pinnedLevel = WorkspaceManager.keepingSavedProtection(
      mixed, defaults: defaults, defaultCommitStyle: .immediate)
    #expect(pinnedLevel.protectionLevel == .schemaOnly)
    #expect(pinnedLevel.commitStyle == .password)
  }

  @Test(
    "The commit style is decided on the resolved style: Password beats a saved protected mode",
    arguments: [DatabaseType.postgresql, .mongodb])
  func resolvedCommitStyleDecides(_ type: DatabaseType) throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // Review sets protected mode (MongoDB resolves it to Confirm); Password clears it
    var saved = Self.config(type, host: "db.example")
    saved.applyCommitStyle(.review)
    #expect(
      SessionManager.saveConnection(
        saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))

    var file = saved
    file.applyCommitStyle(.password)
    let kept = WorkspaceManager.keepingSavedProtection(
      file, defaults: defaults, defaultCommitStyle: .immediate)
    #expect(kept.commitStyle == .password)
    #expect(!kept.protectedMode)

    // A weaker resolved style is still pinned to the saved row's
    file.applyCommitStyle(.immediate)
    let pinned = WorkspaceManager.keepingSavedProtection(
      file, defaults: defaults, defaultCommitStyle: .immediate)
    #expect(pinned.commitStyle == .review)
    #expect(pinned.protectedMode)
    #expect(pinned.safeMode == saved.safeMode)
  }

  @Test("A config the user typed (not a file's) keeps its weaker protection and transport")
  func typedConfigNotSanitized() throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var saved = Self.config(host: "db.example", sslMode: .verifyFull)
    saved.protectionLevel = .schemaOnly
    saved.applyCommitStyle(.password)
    #expect(
      SessionManager.saveConnection(
        saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))

    var typed = saved
    typed.protectionLevel = .none
    typed.applyCommitStyle(.immediate)
    typed.sslMode = .disable
    // What `createNew(connection:)` builds for the Welcome form, a recent card or a moved tab
    let manager = WorkspaceManager(
      workspace: Workspace.newUntitled(connection: typed), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: typed.databaseType.capabilities)),
      defaults: defaults, passwords: RecordingConnectionPasswordStore(),
      sanitizesFileConfig: false)

    for config in [manager.workspace.connectionConfig, manager.editingConnectionConfig] {
      #expect(config?.protectionLevel == ConnectionProtectionLevel.none)
      #expect(config?.commitStyle == typed.commitStyle)
      #expect(config?.sslMode == .disable)
    }
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: manager.workspace.connectionConfig, new: typed, defaultCommitStyle: .immediate,
        hasPassword: true, hasTouchID: false))
  }

  @Test("A workspace file's own password never reaches the workspace or the form")
  func filePasswordCleared() throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var file = Self.config(host: "db.example")
    file.password = "file-password"  // the Password commit style checks writes against it
    let manager = Self.manager(
      Workspace(connectionConfig: file), type: .postgresql, defaults: defaults,
      store: RecordingConnectionPasswordStore())
    #expect(manager.workspace.connectionConfig?.password == "")
    #expect(manager.editingConnectionConfig.password == "")
  }

  @Test(
    "A file never opens a saved read-only database file writable",
    arguments: [DatabaseType.duckdb, .sqlite])
  func savedReadOnlyFileKept(_ type: DatabaseType) throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = ConnectionConfig(
      databaseType: type, host: "", port: 0, database: "/Users/ada/Downloads/shop.db",
      readOnlyFile: true)
    #expect(
      SessionManager.saveConnection(
        saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))

    var file = saved
    file.readOnlyFile = false
    let manager = Self.manager(
      Workspace(connectionConfig: file), type: type, defaults: defaults,
      store: RecordingConnectionPasswordStore())
    #expect(manager.workspace.connectionConfig?.readOnlyFile == true)
  }

  @Test("A file whose fields only collide with a saved row's key never reads its password")
  func collidingKeyNeverRead() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var saved = ConnectionConfig(
      host: "h", port: 5432, database: "x:6000:y", username: "ada", sslMode: .verifyFull)
    saved.password = "victim-secret"
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    let file = ConnectionConfig(
      host: "h:5432:x", port: 6000, database: "y", username: "ada", sslMode: .disable)
    #expect(ConnectionKeychainKey.password(for: file) == ConnectionKeychainKey.password(for: saved))

    let manager = Self.manager(
      Workspace(connectionConfig: file), type: .postgresql, defaults: defaults, store: store)
    #expect(manager.workspace.connectionConfig?.sslMode == .disable)
    await manager.autoConnectIfNeeded()

    #expect(store.loadedKeys.isEmpty)
    #expect(manager.isConnectionFormModalVisible)
    #expect(manager.connectionFormOpensOnDraft)
    #expect(manager.connectionState == .disconnected)
  }

  @Test("A file without a saved row keeps its connection string only on its own host and port")
  func unsavedMongoURIChecked() throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var file = Self.config(.mongodb, host: "mongo.example", sslMode: .verifyFull)
    let own = "mongodb://mongo.example:5432/app?tls=true"
    let cases: [(uri: String, kept: String?)] = [
      (own, own), ("mongodb://mongo.example:5432,attacker.example:27017/app", nil),
      ("mongodb://attacker.example:5432/app", nil),
      ("mongodb://mongo.example:5432/?tls=false", nil),
    ]
    for (uri, kept) in cases {
      file.mongoURI = uri
      let manager = Self.manager(
        Workspace(connectionConfig: file), type: .mongodb, defaults: defaults,
        store: RecordingConnectionPasswordStore())
      #expect(manager.workspace.connectionConfig?.mongoURI == kept)
    }
  }

  @Test("A normal saved workspace still auto-connects with its password")
  func savedWorkspaceAutoConnects() async throws {
    let suiteName = "WorkspaceFileSecurityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var saved = Self.config(host: "db.example", sslMode: .verifyFull)
    saved.password = "secret"
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: store))
    let key = ConnectionKeychainKey.password(for: saved)
    saved.password = ""

    let manager = Self.manager(
      Workspace(connectionConfig: saved, connectionKeychainKey: key), type: .postgresql,
      defaults: defaults, store: store)
    await manager.autoConnectIfNeeded()

    #expect(manager.connectionState == .connected)
    #expect(await manager.connectionManager.config?.password == "secret")
    #expect(!manager.isConnectionFormModalVisible)
    await manager.performDisconnect()
  }

  @Test("The key is always derived from the config, whatever key the file stores")
  func storedKeyForms() {
    let config = Self.config(.mysql, host: "db.example")
    let derived = ConnectionKeychainKey.password(for: config)
    // The unscoped form is the PostgreSQL row's key for the same host, database and user
    let legacy = "db.example:5432:app:ada"
    #expect(derived != legacy)
    #expect(
      Workspace(connectionConfig: config, connectionKeychainKey: derived).keychainKey == derived)
    #expect(
      Workspace(connectionConfig: config, connectionKeychainKey: legacy).keychainKey == derived)
    #expect(Workspace(connectionConfig: config).keychainKey == derived)
    let other = ConnectionKeychainKey.password(for: Self.config(.mysql, host: "other.example"))
    #expect(
      Workspace(connectionConfig: config, connectionKeychainKey: other).keychainKey == derived)
    #expect(Workspace(connectionKeychainKey: other).keychainKey == nil)
  }
}
