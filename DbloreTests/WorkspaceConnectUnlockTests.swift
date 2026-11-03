// WorkspaceConnectUnlockTests.swift
// Reconnecting to the same database with a weaker resolved commit style needs the Safe Mode
// unlock when the old style is review or password and a password or Touch ID is configured.
// confirm → immediate does not. A different database or a stronger style connects immediately.
// Turning protectedMode off without applyCommitStyle is not a user-facing path.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace Connect Unlock Tests")
@MainActor
struct WorkspaceConnectUnlockTests {
  private static func styled(
    _ style: CommitStyle, host: String = "db.example.com", database: String = "app",
    username: String = "admin", protectionLevel: ConnectionProtectionLevel = .none
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: host, port: 5432, database: database, username: username,
      protectionLevel: protectionLevel)
    config.applyCommitStyle(style)
    return config
  }

  private static let strict = styled(.review, protectionLevel: .readOnly)
  private static let weak = styled(.immediate)

  // MARK: - Decision (pure)

  @Test("Same target, lowering review or password needs the unlock")
  func sameTargetWeakeningNeedsUnlock() {
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: Self.styled(.review),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.strict, new: Self.weak,
        defaultCommitStyle: .review, hasPassword: false, hasTouchID: true))
  }

  @Test("Same target, password style, lowering the protection level needs the unlock")
  func sameTargetProtectionLevelNeedsUnlock() {
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password, protectionLevel: .readOnly),
        new: Self.styled(.password, protectionLevel: .none),
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.review, protectionLevel: .readOnly),
        new: Self.styled(.review, protectionLevel: .none),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: true))
  }

  @Test("Same target compared case-insensitively and ignoring surrounding spaces")
  func sameTargetCaseInsensitive() {
    let weakUpper = Self.styled(
      .confirm, host: " DB.Example.COM ", database: "APP", username: "Admin")
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: weakUpper,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Same target ignores one trailing dot on the host")
  func sameTargetTrailingDot() {
    let weakDot = Self.styled(.immediate, host: "db.example.com.")
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.review), new: weakDot,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Legacy unprotected nil safe mode uses the default commit style")
  func defaultStyleFallbackNeedsUnlock() {
    let current = ConnectionConfig(
      host: "db.example.com", port: 5432, database: "app", username: "admin", password: "pw",
      protectionLevel: .none, safeMode: nil, protectedMode: false)
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: current, new: Self.styled(.confirm),
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("confirm → immediate connects without unlock")
  func confirmToImmediateNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.confirm, protectionLevel: .readOnly),
        new: Self.styled(.immediate),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Strengthening connects immediately")
  func strengtheningNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.confirm, protectionLevel: .schemaOnly),
        new: Self.styled(.password, protectionLevel: .readOnly),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("A different database, host or user is a new connection: no unlock")
  func differentTargetNoUnlock() {
    for new in [
      Self.styled(.immediate, database: "other"),
      Self.styled(.immediate, host: "other.example.com"),
      Self.styled(.immediate, username: "reader"),
    ] {
      #expect(
        !WorkspaceManager.connectRequiresUnlock(
          current: Self.styled(.password), new: new,
          defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
    }
    var otherPort = Self.weak
    otherPort.port = 6543
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: otherPort,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("PostgreSQL and MySQL on the same host, port, database and user are different targets")
  func differentEngineNoUnlock() {
    var mysql = Self.weak
    mysql.databaseType = .mysql
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: mysql,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
    var mysqlStrict = Self.styled(.password)
    mysqlStrict.databaseType = .mysql
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: mysqlStrict, new: mysql,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("No password and no Touch ID: a weaker style is not gated")
  func noUnlockConfiguredNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: Self.weak,
        defaultCommitStyle: .review, hasPassword: false, hasTouchID: false))
  }

  @Test("No current config: no unlock")
  func noCurrentNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: nil, new: Self.weak,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("Weaker than the saved row needs the unlock, whatever the workspace config")
  func weakerThanSavedRowNeedsUnlock() {
    for current in [nil, Self.weak] {
      #expect(
        WorkspaceManager.connectRequiresUnlock(
          current: current, saved: Self.strict, new: Self.weak,
          defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
    }
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: nil, saved: Self.styled(.review, database: "other"), new: Self.weak,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  // MARK: - Welcome form against its saved row (isolated suite, in-memory passwords)

  /// A row saved with Review and Read-only on a host unique to this test
  private static func withSavedStrictRow(
    _ body: (UserDefaults, ConnectionConfig) async throws -> Void
  ) async throws {
    let name = "WorkspaceConnectUnlockTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let saved = Self.styled(
      .review, host: "welcome-\(UUID().uuidString).example", protectionLevel: .readOnly)
    #expect(
      SessionManager.saveConnection(
        saved, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
    try await body(defaults, saved)
  }

  /// `saved` as the Welcome form weakens it: Immediate, no protection level, a typed password
  private static func weakened(_ saved: ConnectionConfig) -> ConnectionConfig {
    var config = saved
    config.protectionLevel = .none
    config.applyCommitStyle(.immediate)
    config.password = "typed"
    return config
  }

  private static func savedRow(
    of config: ConnectionConfig, defaults: UserDefaults
  ) -> ConnectionConfig? {
    SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
      .first { $0.isSavedRow(of: config) }?.config
  }

  /// What `newWorkspace(connection:)` builds for the Welcome form, on a fake session
  private static func welcomeWorkspace(
    _ config: ConnectionConfig, defaults: UserDefaults
  ) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace.newUntitled(connection: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: config.databaseType.capabilities)),
      defaults: defaults, passwords: RecordingConnectionPasswordStore(),
      sanitizesFileConfig: false)
  }

  @Test("Welcome weaker than the saved row: one unlock before any workspace, then it connects")
  func welcomeWeakeningUnlocksOnceThenSaves() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      let weak = Self.weakened(saved)
      var asked: [ConnectionConfig] = []
      let unlocked = try await WorkspaceManager.unlockWelcomeWeakening(
        of: weak, defaults: defaults, defaultCommitStyle: .review, hasPassword: true,
        hasTouchID: false
      ) { row in
        asked.append(row)
        return true
      }
      #expect(unlocked)
      #expect(asked.count == 1)
      // The sheet is offered the saved row (its Keychain password), never the typed one
      #expect(asked.first?.protectionLevel == .readOnly)
      #expect(asked.first?.password == "")

      let workspace = Self.welcomeWorkspace(weak, defaults: defaults)
      try await workspace.connectFromWelcome(
        config: weak, aiFieldsEdited: false, weakeningUnlocked: unlocked,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      #expect(asked.count == 1)
      #expect(workspace.pendingWeakeningConnect == nil)
      #expect(await workspace.connectionManager.isConnected)
      let row = try #require(Self.savedRow(of: weak, defaults: defaults))
      #expect(row.protectionLevel == ConnectionProtectionLevel.none)
      #expect(row.commitStyle == weak.commitStyle)
      await workspace.disconnect()
    }
  }

  @Test("Welcome weaker than the saved row, unlock cancelled: nothing created or saved")
  func welcomeWeakeningCancelledSavesNothing() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      let weak = Self.weakened(saved)
      var asks = 0
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        _ = try await WorkspaceManager.unlockWelcomeWeakening(
          of: weak, defaults: defaults, defaultCommitStyle: .review, hasPassword: true,
          hasTouchID: false
        ) { _ in
          asks += 1
          return false
        }
      }
      #expect(asks == 1)
      #expect(Self.savedRow(of: weak, defaults: defaults)?.protectionLevel == .readOnly)

      // Created without the unlock anyway, its connect is held by the saved row
      let workspace = Self.welcomeWorkspace(weak, defaults: defaults)
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await workspace.connectFromWelcome(
          config: weak, aiFieldsEdited: false, weakeningUnlocked: false,
          defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      }
      #expect(await !workspace.connectionManager.isConnected)
      let row = try #require(Self.savedRow(of: weak, defaults: defaults))
      #expect(row.protectionLevel == .readOnly)
      #expect(row.commitStyle == saved.commitStyle)
    }
  }

  @Test("Welcome as strict as the saved row asks nothing")
  func welcomeNotWeakerAsksNothing() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      var asks = 0
      let unlocked = try await WorkspaceManager.unlockWelcomeWeakening(
        of: saved, defaults: defaults, defaultCommitStyle: .review, hasPassword: true,
        hasTouchID: false
      ) { _ in
        asks += 1
        return true
      }
      #expect(!unlocked)
      #expect(asks == 0)
    }
  }

  /// The Welcome Edit → Save path: the weakening unlock, then the replace unless it threw
  private static func saveWelcomeEdit(
    _ row: ConnectionConfig, defaults: UserDefaults, granted: Bool
  ) async throws -> Int {
    let id = try #require(
      SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()).first?.id)
    var asks = 0
    _ = try await WorkspaceManager.unlockWelcomeEditWeakening(
      of: row, editing: id, defaults: defaults, defaultCommitStyle: .review, hasPassword: true,
      hasTouchID: false
    ) { saved in
      asks += 1
      #expect(saved.protectionLevel == .readOnly)
      return granted
    }
    #expect(
      SessionManager.replaceConnection(
        id: id, with: row, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
    return asks
  }

  @Test("Welcome Edit weaker than the saved row, unlock cancelled: the row is unchanged")
  func welcomeEditWeakeningCancelledSavesNothing() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      var weak = Self.weakened(saved)
      weak.password = ""
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        _ = try await Self.saveWelcomeEdit(weak, defaults: defaults, granted: false)
      }
      let row = try #require(Self.savedRow(of: saved, defaults: defaults))
      #expect(row.protectionLevel == .readOnly)
      #expect(row.commitStyle == saved.commitStyle)
    }
  }

  @Test("Welcome Edit weaker than the saved row: one unlock, then the row takes it")
  func welcomeEditWeakeningUnlockedSaves() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      var weak = Self.weakened(saved)
      weak.password = ""
      let asks = try await Self.saveWelcomeEdit(weak, defaults: defaults, granted: true)
      #expect(asks == 1)
      let row = try #require(Self.savedRow(of: weak, defaults: defaults))
      #expect(row.protectionLevel == ConnectionProtectionLevel.none)
      #expect(row.commitStyle == weak.commitStyle)
    }
  }

  @Test("Welcome Edit that retargets and weakens the row still asks; cancel saves nothing")
  func welcomeEditRetargetWeakeningNeedsUnlock() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      var weak = Self.weakened(saved)
      weak.password = ""
      weak.database = "other"
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        _ = try await Self.saveWelcomeEdit(weak, defaults: defaults, granted: false)
      }
      #expect(Self.savedRow(of: weak, defaults: defaults) == nil)
      #expect(Self.savedRow(of: saved, defaults: defaults)?.protectionLevel == .readOnly)
    }
  }

  @Test("Welcome Edit onto a stricter saved row of its new target asks with that row")
  func welcomeEditMergingStricterTargetRowNeedsUnlock() async throws {
    let name = "WorkspaceConnectUnlockTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let host = "merge-\(UUID().uuidString).example"
    // S: strict, at the target T the edit moves onto; R: the edited row, less strict, at U
    let target = Self.styled(.review, host: host, protectionLevel: .readOnly)
    let edited = Self.styled(.immediate, host: host, database: "other")
    for config in [target, edited] {
      #expect(
        SessionManager.saveConnection(
          config, defaults: defaults, passwords: RecordingConnectionPasswordStore()))
    }
    let rows = { SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()) }
    let targetID = try #require(rows().first { $0.isSavedRow(of: target) }?.id)
    let editedID = try #require(rows().first { $0.isSavedRow(of: edited) }?.id)
    // Not weaker than R, weaker than S, which the save merges away
    var row = edited
    row.database = target.database

    for granted in [false, true] {
      var asked: [ConnectionConfig] = []
      let ask = {
        try await WorkspaceManager.unlockWelcomeEditWeakening(
          of: row, editing: editedID, defaults: defaults, defaultCommitStyle: .review,
          hasPassword: true, hasTouchID: false
        ) { saved in
          asked.append(saved)
          return granted
        }
      }
      if granted {
        #expect(try await ask())
      } else {
        await #expect(throws: WorkspaceConnectError.unlockRequired) { _ = try await ask() }
      }
      #expect(asked.count == 1)
      #expect(asked.first?.protectionLevel == .readOnly)
      #expect(asked.first?.database == target.database)
      guard granted else {
        #expect(rows().count == 2)
        #expect(Self.savedRow(of: target, defaults: defaults)?.protectionLevel == .readOnly)
        #expect(Self.savedRow(of: target, defaults: defaults)?.commitStyle == target.commitStyle)
        #expect(Self.savedRow(of: edited, defaults: defaults)?.commitStyle == edited.commitStyle)
        continue
      }
      #expect(
        SessionManager.replaceConnection(
          id: editedID, with: row, defaults: defaults,
          passwords: RecordingConnectionPasswordStore()))
      let kept = try #require(rows().first)
      #expect(rows().count == 1)
      #expect(kept.id == editedID)
      #expect(kept.id != targetID)
      #expect(kept.isSavedRow(of: target))
      #expect(kept.config.protectionLevel == ConnectionProtectionLevel.none)
      #expect(kept.config.commitStyle == row.commitStyle)
    }
  }

  @Test("Welcome Edit as strict as the saved row asks nothing")
  func welcomeEditNotWeakerAsksNothing() async throws {
    try await Self.withSavedStrictRow { defaults, saved in
      var renamed = saved
      renamed.name = "Renamed"
      let asks = try await Self.saveWelcomeEdit(renamed, defaults: defaults, granted: false)
      #expect(asks == 0)
      #expect(Self.savedRow(of: saved, defaults: defaults)?.name == "Renamed")
    }
  }

  @Test("A Remember-off workspace weakened from its form still needs the unlock")
  func rememberOffWeakeningNeedsUnlock() async throws {
    let name = "WorkspaceConnectUnlockTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var strict = Self.strict
    strict.rememberConnection = false
    var weak = Self.weak
    weak.rememberConnection = false
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: strict), restoreTabs: false, defaults: defaults,
      passwords: RecordingConnectionPasswordStore())
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    }
    #expect(manager.pendingWeakeningConnect == weak)
    #expect(await !manager.connectionManager.isConnected)
  }

  // MARK: - Deferred connect (no database needed)

  @Test("Weakening connect is deferred: not connected, config unchanged, pending set")
  func weakeningConnectDeferred() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    }
    #expect(manager.pendingWeakeningConnect == Self.weak)
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(manager.connectionState == .disconnected)
    #expect(await !manager.connectionManager.isConnected)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .none)
  }

  @Test("Cancelling the unlock drops the pending connect and connects nothing")
  func cancelPendingConnect() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    _ = try? await manager.connect(
      config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(await !manager.connectionManager.isConnected)
  }

  @Test("Cancelling an unlock also drops its pending private key")
  func cancelPendingCertificate() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    let material = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: Self.weak), material: material)
    await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      }
    }
    scoped.clear()
    #expect(manager.pendingWeakeningCertificate == material)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningCertificate == nil)
    #expect(scoped.material == nil)
  }

  @Test("Closing a lost workspace releases its ephemeral certificate")
  func closingLostWorkspaceReleasesCertificate() {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.weak), restoreTabs: false)
    let material = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    manager.activeUnrememberedCertificate = .init(
      account: ClientCertificateStoreFactory.account(for: Self.weak), material: material)
    manager.releaseFileAccess()
    #expect(manager.activeUnrememberedCertificate == nil)
  }

  /// Replace Pin's retry goes through the Safe Mode gate again: the unlock sheet comes back and
  /// nothing opens before it is granted.
  @Test("A changed SSH host key after the unlock shows the blocking alert and an inline error")
  func unlockedConnectReportsChangedHostKey() async throws {
    let changed = DatabaseError.sshHostKeyChanged(
      host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new",
      presentedAlgorithm: "ssh-ed25519")
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), openError: changed)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
    _ = try? await manager.connect(
      config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    #expect(manager.pendingWeakeningConnect == Self.weak)

    let presenter = FakeSSHHostKeyTrustPresenter()
    let store = InMemorySSHKnownHostStore()
    try store.trust(
      host: "bastion.example", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:old")
    let connected = await manager.completePendingWeakeningConnectReportingFailure(
      coordinator: SSHHostKeyTrustCoordinator(presenter: presenter, store: store),
      defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)

    #expect(!connected)
    #expect(
      presenter.changes == [
        SSHHostKeyChange(
          host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new",
          presentedAlgorithm: "ssh-ed25519")
      ])
    // The unlock sheet closes (no pending connect); the still-open form shows the message.
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.lastUnlockConnectError?.contains("bastion.example:22") == true)
    // The toast state is shared with tests running in parallel: only read it (never dismiss)
    // and check this failure's message is not toasted
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("bastion.example")
        != true)

    let opened = factory.sessions.count
    presenter.replaceChanged()
    let end = ContinuousClock.now + .seconds(30)
    while manager.pendingWeakeningConnect == nil, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(manager.pendingWeakeningConnect == Self.weak)
    #expect(factory.sessions.count == opened)
    #expect(try store.lookup(host: "bastion.example", port: 22)?.fingerprint == "SHA256:new")
  }

  @Test("A failed connect after the unlock shows inline; the next attempt clears it")
  func unlockedConnectReportsFailureInline() async {
    let failure = DatabaseError.connectionFailed("password authentication failed for user admin")
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), openError: failure)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
    _ = try? await manager.connect(
      config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)

    let presenter = FakeSSHHostKeyTrustPresenter()
    let connected = await manager.completePendingWeakeningConnectReportingFailure(
      coordinator: SSHHostKeyTrustCoordinator(presenter: presenter))

    #expect(!connected)
    #expect(presenter.changes.isEmpty)
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.lastUnlockConnectError?.contains("password authentication failed") == true)
    // The toast state is shared with tests running in parallel: only read it (never dismiss)
    // and check this failure's message is not toasted
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains(
        "password authentication failed") != true)

    _ = try? await manager.connect(
      config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    #expect(manager.lastUnlockConnectError == nil)
  }

  @Test("Completing without a pending connect does nothing")
  func completeWithoutPending() async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    try await manager.completePendingWeakeningConnect()
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(await !manager.connectionManager.isConnected)
  }
}

@Suite("Workspace Connect Unlock - Integration (Requires PostgreSQL)", .requiresPostgres)
@MainActor
struct WorkspaceConnectUnlockIntegrationTests {
  private static func styled(
    _ style: CommitStyle, protectionLevel: ConnectionProtectionLevel,
    database: String = TestDatabase.database
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      rememberConnection: false,
      timeoutSeconds: 30,
      protectionLevel: protectionLevel
    )
    config.applyCommitStyle(style)
    return config
  }

  /// Runs `body` on a fresh workspace and awaits its disconnect, even when `body` throws, so the
  /// next test never races this connection's teardown on the same database
  private static func withManager(
    current: ConnectionConfig, _ body: (WorkspaceManager) async throws -> Void
  ) async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    do {
      try await body(manager)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  @Test("Same DB weakened: deferred until unlock, then connects with the new config")
  func deferredThenConnects() async throws {
    let strict = Self.styled(.password, protectionLevel: .readOnly)
    let weak = Self.styled(.review, protectionLevel: .readOnly)
    try await Self.withManager(current: strict) { manager in
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      }
      #expect(await !manager.connectionManager.isConnected)
      var opened = strict
      opened.password = ""  // the init drops the workspace config's own password
      #expect(manager.workspace.connectionConfig == opened)

      try await manager.completePendingWeakeningConnect()
      #expect(manager.pendingWeakeningConnect == nil)
      #expect(await manager.connectionManager.isConnected)
      #expect(manager.workspace.connectionConfig == weak)
      #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .readOnly)
    }
  }

  @Test("Strengthening the same DB connects immediately")
  func strengtheningConnectsImmediately() async throws {
    let current = Self.styled(.confirm, protectionLevel: .schemaOnly)
    let stronger = Self.styled(.password, protectionLevel: .readOnly)
    try await Self.withManager(current: current) { manager in
      try await manager.connect(config: stronger, defaultCommitStyle: .immediate)
      #expect(manager.pendingWeakeningConnect == nil)
      #expect(await manager.connectionManager.isConnected)
      #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .readOnly)
    }
  }

  @Test("confirm → immediate connects immediately even when a password is configured")
  func confirmToImmediateConnectsImmediately() async throws {
    let current = Self.styled(.confirm, protectionLevel: .readOnly)
    let weak = Self.styled(.immediate, protectionLevel: .none)
    try await Self.withManager(current: current) { manager in
      try await manager.connect(
        config: weak, defaultCommitStyle: .immediate, hasPassword: true, hasTouchID: false)
      #expect(await manager.connectionManager.isConnected)
      #expect(manager.workspace.connectionConfig == weak)
    }
  }

  @Test("A different database connects immediately even when weaker")
  func differentDatabaseConnectsImmediately() async throws {
    let current = Self.styled(
      .password, protectionLevel: .readOnly, database: "some_other_database")
    let weak = Self.styled(.immediate, protectionLevel: .none)
    try await Self.withManager(current: current) { manager in
      try await manager.connect(
        config: weak, defaultCommitStyle: .immediate, hasPassword: true, hasTouchID: false)
      #expect(await manager.connectionManager.isConnected)
      #expect(manager.workspace.connectionConfig == weak)
    }
  }
}
