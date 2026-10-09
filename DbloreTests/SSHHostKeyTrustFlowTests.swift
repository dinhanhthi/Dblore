import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import Dblore

@Suite("SSH host-key trust flow")
@MainActor
struct SSHHostKeyTrustFlowTests {
  private static func request(
    host: String = "bastion.example", port: Int = 22, fingerprint: String = "SHA256:abc"
  ) -> SSHHostKeyTrustRequest {
    SSHHostKeyTrustRequest(
      host: host, port: port, algorithm: "ssh-ed25519", fingerprint: fingerprint)
  }

  @Test("The sheet decision answers the prompt")
  func sheetDecisionAnswers() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let request = Self.request()

    let trusted = Task { await coordinator.confirmUnknownHost(request) }
    try await waitFor { presenter.presented.count == 1 }
    #expect(presenter.presented == [request])
    presenter.answer(true)
    #expect(await trusted.value)

    let declined = Task { await coordinator.confirmUnknownHost(request) }
    try await waitFor { presenter.presented.count == 2 }
    presenter.answer(false)
    #expect(await declined.value == false)
  }

  @Test("Concurrent requests for the same host share one sheet and one answer")
  func sameHostCoalesces() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let first = Task { await coordinator.confirm(Self.request()) }
    let second = Task { await coordinator.confirm(Self.request()) }
    try await waitFor { presenter.presented.count == 1 }
    await Task.yield()

    presenter.answer(true)
    #expect(await first.value)
    #expect(await second.value)
    #expect(presenter.presented.count == 1)
  }

  @Test("Requests for different hosts queue: one sheet at a time")
  func differentHostsQueue() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let hostA = Self.request(host: "a.example")
    let hostB = Self.request(host: "b.example")
    let first = Task { await coordinator.confirm(hostA) }
    let second = Task { await coordinator.confirm(hostB) }
    try await waitFor { presenter.presented.count == 1 }
    await Task.yield()
    #expect(presenter.presented == [hostA])

    presenter.answer(true)
    #expect(await first.value)
    try await waitFor { presenter.presented.count == 2 }
    #expect(presenter.presented == [hostA, hostB])
    presenter.answer(false)
    #expect(await second.value == false)
  }

  @Test("No window to host the sheet, or the host went away: not trusted")
  func missingHostAnswersFalse() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    presenter.canPresent = false
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    #expect(await coordinator.confirm(Self.request()) == false)

    presenter.canPresent = true
    let pending = Task { await coordinator.confirm(Self.request()) }
    try await waitFor { presenter.presented.count == 1 }
    presenter.hostWentAway()
    #expect(await pending.value == false)

    #expect(await SSHHostKeyTrustCoordinator(presenter: nil).confirm(Self.request()) == false)
  }

  @Test("A cancelled connect (server closed it) closes the sheet and answers false")
  func cancelledWaiterDismissesSheet() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let pending = Task { await coordinator.confirm(Self.request()) }
    try await waitFor { presenter.presented.count == 1 }
    pending.cancel()
    #expect(await pending.value == false)
    try await waitFor { presenter.dismissCount == 1 }

    // The next request gets its own sheet.
    let next = Task { await coordinator.confirm(Self.request(host: "next.example")) }
    try await waitFor { presenter.presented.count == 2 }
    presenter.answer(true)
    #expect(await next.value)
  }

  @Test("Welcome Test Connection and workspaces use the app-wide coordinator")
  func appManagersUseCoordinator() {
    let welcome = AppWelcomeView.makeTestConnectionManager()
    #expect(
      (welcome.sshHostKeyPolicy.prompt as? SSHHostKeyTrustCoordinator)
        === SSHHostKeyTrustCoordinator.shared)
    let workspace = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    #expect(
      (workspace.connectionManager.sshHostKeyPolicy.prompt as? SSHHostKeyTrustCoordinator)
        === SSHHostKeyTrustCoordinator.shared)
  }

  @Test("A changed host key shows the blocking alert; Cancel and other errors do not")
  func failureReporting() {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)

    let changed = coordinator.report(
      DatabaseError.sshHostKeyChanged(
        host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new"))
    #expect(
      presenter.changes == [
        SSHHostKeyChange(
          host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new")
      ])
    #expect(changed.contains("bastion.example:22"))

    let cancelled = coordinator.report(
      DatabaseError.sshHostKeyNotTrusted(host: "bastion.example", fingerprint: "SHA256:new"))
    #expect(cancelled == "Connection cancelled. The SSH host key was not trusted.")

    let other = coordinator.report(DatabaseError.sshAuthenticationFailed)
    #expect(other == DatabaseError.sshAuthenticationFailed.localizedDescription)
    #expect(presenter.changes.count == 1)
  }

  @Test("No window for the sheet and a failed pin are reported apart from Cancel")
  func unpresentableAndPinFailureReporting() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    presenter.canPresent = false
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let request = Self.request(host: "hidden.example", fingerprint: "SHA256:hidden")
    #expect(await coordinator.confirm(request) == false)
    let unshown = coordinator.report(
      DatabaseError.sshHostKeyNotTrusted(host: "hidden.example", fingerprint: "SHA256:hidden"))
    #expect(unshown.contains("could not be shown"))

    // Shown later and cancelled by the user: a plain Cancel again.
    presenter.canPresent = true
    let pending = Task { await coordinator.confirm(request) }
    try await waitFor { presenter.presented.count == 1 }
    presenter.answer(false)
    #expect(await pending.value == false)
    #expect(
      coordinator.report(
        DatabaseError.sshHostKeyNotTrusted(host: "hidden.example", fingerprint: "SHA256:hidden"))
        == "Connection cancelled. The SSH host key was not trusted.")

    let pinFailed = coordinator.report(
      DatabaseError.sshHostKeyPinFailed(host: "bastion.example", port: 22))
    #expect(pinFailed.contains("could not be saved"))
    #expect(pinFailed != "Connection cancelled. The SSH host key was not trusted.")
  }

  @Test("Trust clicked but the pin cannot be saved: blocked with its own error")
  func pinFailureFailsClosed() async throws {
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    let fingerprint = try #require(SSHTunnel.fingerprint(of: key))
    let policy = SSHHostKeyPolicy(
      store: UnwritableSSHKnownHostStore(), prompt: FakeSSHHostKeyPrompt(answer: true))
    await #expect {
      try await policy.validate(
        host: "bastion.example", port: 22, hostKey: key, fingerprint: fingerprint)
    } throws: {
      guard case DatabaseError.sshHostKeyPinFailed(let host, let port) = $0 else { return false }
      return host == "bastion.example" && port == 22
    }
  }

  @Test(
    "Cancelling a connect while the sheet is open withdraws it and pins nothing",
    .timeLimit(.minutes(1)))
  func cancelledConnectWithdrawsPrompt() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let server = try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: DenyAllUsers())),
              allocator: channel.allocator, inboundChildChannelInitializer: nil))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let presenter = FakeSSHHostKeyTrustPresenter()
    let store = InMemorySSHKnownHostStore()
    let policy = SSHHostKeyPolicy(
      store: store, prompt: SSHHostKeyTrustCoordinator(presenter: presenter))

    let connect = Task {
      try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
        hostKeyValidator: { key, fingerprint in
          try await policy.validate(
            host: "127.0.0.1", port: port, hostKey: key, fingerprint: fingerprint)
        }, group: group, handshakeTimeout: .seconds(30))
    }
    try await waitFor { presenter.presented.count == 1 }
    connect.cancel()
    await #expect(throws: (any Error).self) { _ = try await connect.value }
    try await waitFor { presenter.dismissCount == 1 }
    // A late Trust on the withdrawn sheet changes nothing.
    presenter.answer(true)
    #expect(try store.lookup(host: "127.0.0.1", port: port) == nil)
    try await server.close()
    try await group.shutdownGracefully()
  }

  @Test("Cancel in the sheet: not trusted and nothing pinned")
  func cancelPinsNothing() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let store = InMemorySSHKnownHostStore()
    let policy = SSHHostKeyPolicy(
      store: store, prompt: SSHHostKeyTrustCoordinator(presenter: presenter))
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    let fingerprint = try #require(SSHTunnel.fingerprint(of: key))

    let validation = Task {
      try await policy.validate(
        host: "bastion.example", port: 22, hostKey: key, fingerprint: fingerprint)
    }
    try await waitFor { presenter.presented.count == 1 }
    #expect(presenter.presented.first?.fingerprint == fingerprint)
    presenter.answer(false)
    await #expect {
      try await validation.value
    } throws: {
      guard case DatabaseError.sshHostKeyNotTrusted = $0 else { return false }
      return true
    }
    #expect(try store.lookup(host: "bastion.example", port: 22) == nil)
  }

  @Test(
    "The server closing while the prompt is open fails with a clear error",
    .timeLimit(.minutes(1)))
  func serverClosesDuringPrompt() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let accepted = AcceptedChannels()
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let server = try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        accepted.add(channel)
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: DenyAllUsers())),
              allocator: channel.allocator, inboundChildChannelInitializer: nil))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let prompting = FiredFlag()

    let connect = Task {
      try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
        hostKeyValidator: { _, _ in
          prompting.set()
          try await Task.sleep(for: .seconds(60))
        }, group: group, handshakeTimeout: .milliseconds(300))
    }
    let end = ContinuousClock.now + .seconds(5)
    while !prompting.isSet, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(prompting.isSet)
    // Longer than the handshake timeout: the prompt time is not counted.
    try await Task.sleep(for: .milliseconds(800))
    accepted.closeAll()

    await #expect(throws: SSHTunnelError.closedWhileConfirmingHostKey) {
      _ = try await connect.value
    }
    try await server.close()
    try await group.shutdownGracefully()
  }

  @Test("The handshake deadline does not run while paused")
  func handshakeDeadlinePauses() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let fired = FiredFlag()
    let deadline = SSHHandshakeDeadline(.milliseconds(300))
    deadline.pause()
    deadline.arm(on: group.next()) { fired.set() }
    try await Task.sleep(for: .milliseconds(600))
    #expect(!fired.isSet)

    deadline.resume()
    let end = ContinuousClock.now + .seconds(5)
    while !fired.isSet, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(fired.isSet)
    try await group.shutdownGracefully()
  }
}

/// Polls on the main actor until `condition` holds (fails after 5 s).
@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
  let end = ContinuousClock.now + .seconds(5)
  while !condition() {
    guard ContinuousClock.now < end else {
      Issue.record("condition not met in time")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Records what the coordinator presents; the test answers like the user would.
@MainActor
final class FakeSSHHostKeyTrustPresenter: SSHHostKeyTrustPresenting {
  var canPresent = true
  /// Answers every sheet by itself after `delay` when set.
  var autoAnswer: (answer: Bool, delay: Duration)?
  private(set) var presented: [SSHHostKeyTrustRequest] = []
  private(set) var dismissCount = 0
  private(set) var changes: [SSHHostKeyChange] = []
  private var decide: ((Bool) -> Void)?

  init(autoAnswer: (answer: Bool, delay: Duration)? = nil) {
    self.autoAnswer = autoAnswer
  }

  func presentTrust(
    _ request: SSHHostKeyTrustRequest, decide: @escaping @MainActor (Bool) -> Void
  ) -> Bool {
    guard canPresent else { return false }
    presented.append(request)
    self.decide = decide
    if let autoAnswer {
      Task {
        try? await Task.sleep(for: autoAnswer.delay)
        self.answer(autoAnswer.answer)
      }
    }
    return true
  }

  func dismissTrust() {
    dismissCount += 1
    decide = nil
  }

  func presentHostKeyChanged(_ change: SSHHostKeyChange) {
    changes.append(change)
  }

  func answer(_ trusted: Bool) {
    let pending = decide
    decide = nil
    pending?(trusted)
  }

  /// The window hosting the sheet closed.
  func hostWentAway() { answer(false) }
}

extension SSHHostKeyTrustFlowTests {
  /// Live: docker/postgresql/docker-compose.ssh.yml through the workspace connect flow.
  @Suite("SSH host-key trust flow (live)", .requiresSSHPostgres, .serialized)
  @MainActor
  struct Live {
    private static let fixtures = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("docker/postgresql/data/ssh", isDirectory: true)

    private static func bastionFingerprint() throws -> String {
      try String(
        contentsOf: fixtures.appendingPathComponent("host_fingerprint.txt"), encoding: .utf8
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func config(timeoutSeconds: Int) -> ConnectionConfig {
      let config = ConnectionConfig(
        host: "postgres", port: 5432, database: "dblore_ssh", username: "dblore_ssh",
        password: "dblore123", sslMode: .disable,
        sshTunnel: SSHTunnelConfig(host: "127.0.0.1", port: 2222, username: "dblore"),
        timeoutSeconds: timeoutSeconds, safeMode: .silent)
      let account = SSHCredentialStoreFactory.account(for: config)!
      SSHCredentialStoreFactory.shared.save(.password("dblore-ssh-123"), account: account)
      return config
    }

    private static func workspace(
      _ presenter: FakeSSHHostKeyTrustPresenter
    ) -> WorkspaceManager {
      WorkspaceManager(
        workspace: Workspace.newUntitled(connection: nil), restoreTabs: false,
        connectionManager: DatabaseConnectionManager(
          sshHostKeyPrompt: SSHHostKeyTrustCoordinator(presenter: presenter)))
    }

    @Test("Trust and Connect pins the bastion and connects", .timeLimit(.minutes(1)))
    func trustPinsAndConnects() async throws {
      let store = SSHKnownHostStoreFactory.shared
      store.remove(host: "127.0.0.1", port: 2222)
      defer { store.remove(host: "127.0.0.1", port: 2222) }
      let presenter = FakeSSHHostKeyTrustPresenter(autoAnswer: (true, .zero))
      let manager = Self.workspace(presenter)

      try await manager.connect(
        config: Self.config(timeoutSeconds: 15), defaultCommitStyle: .immediate)
      #expect(await manager.connectionManager.isConnected)
      #expect(presenter.presented.count == 1)
      #expect(presenter.presented.first?.fingerprint == (try Self.bastionFingerprint()))
      #expect(
        try store.lookup(host: "127.0.0.1", port: 2222)?.fingerprint
          == (try Self.bastionFingerprint()))
      await manager.disconnect()
    }

    @Test(
      "Time in the trust sheet does not count against the connection timeout",
      .timeLimit(.minutes(1)))
    func promptTimeExcludedFromTimeout() async throws {
      let store = SSHKnownHostStoreFactory.shared
      let config = Self.config(timeoutSeconds: 3)
      let presenter = FakeSSHHostKeyTrustPresenter(autoAnswer: (true, .seconds(5)))
      let manager = Self.workspace(presenter)

      store.remove(host: "127.0.0.1", port: 2222)
      defer { store.remove(host: "127.0.0.1", port: 2222) }
      #expect(try await manager.connectionManager.testConnection(config: config))
      #expect(presenter.presented.count == 1)

      store.remove(host: "127.0.0.1", port: 2222)
      try await manager.connect(config: config, defaultCommitStyle: .immediate)
      #expect(await manager.connectionManager.isConnected)
      #expect(presenter.presented.count == 2)
      await manager.disconnect()
    }
  }
}

private final class FiredFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false

  var isSet: Bool { lock.withLock { fired } }

  func set() { lock.withLock { fired = true } }
}

private final class AcceptedChannels: @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [any Channel] = []

  func add(_ channel: any Channel) { lock.withLock { channels.append(channel) } }

  func closeAll() {
    for channel in lock.withLock({ channels }) {
      channel.close(promise: nil)
    }
  }
}

private final class DenyAllUsers: NIOSSHServerUserAuthenticationDelegate {
  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    responsePromise.succeed(.failure)
  }
}

/// Lookups find nothing and every pin fails to save (e.g. a Keychain write error).
private final class UnwritableSSHKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  func load(account: String) throws -> SSHKnownHost? { nil }
  func add(_ host: SSHKnownHost, account: String) -> Bool { false }
  func save(_ host: SSHKnownHost, account: String) -> Bool { false }
  func delete(account: String) {}
}
