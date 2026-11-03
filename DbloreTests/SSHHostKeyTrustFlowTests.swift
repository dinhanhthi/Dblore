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
        host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new",
        presentedAlgorithm: "ssh-ed25519"),
      retry: {})
    #expect(
      presenter.changes == [
        SSHHostKeyChange(
          host: "bastion.example", port: 22, expected: "SHA256:old", presented: "SHA256:new",
          presentedAlgorithm: "ssh-ed25519")
      ])
    #expect(changed.contains("bastion.example:22"))

    let cancelled = coordinator.report(
      DatabaseError.sshHostKeyNotTrusted(host: "bastion.example", fingerprint: "SHA256:new"),
      retry: {})
    #expect(cancelled == "Connection cancelled. The SSH host key was not trusted.")

    let other = coordinator.report(DatabaseError.sshAuthenticationFailed, retry: {})
    #expect(other == DatabaseError.sshAuthenticationFailed.localizedDescription)
    #expect(presenter.changes.count == 1)
  }

  /// A pin of `SHA256:old` for `host`:22, a coordinator and policy on it, and what connecting
  /// with a new ed25519 key threw.
  private static func changedKey(
    _ presenter: FakeSSHHostKeyTrustPresenter, host: String = "bastion.example",
    store: any SSHKnownHostStore = InMemorySSHKnownHostStore()
  ) async throws -> (
    store: any SSHKnownHostStore, coordinator: SSHHostKeyTrustCoordinator,
    policy: SSHHostKeyPolicy, key: NIOSSHPublicKey, fingerprint: String, error: any Error
  ) {
    try store.trust(host: host, port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:old")
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter, store: store)
    let policy = SSHHostKeyPolicy(store: store, prompt: coordinator)
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    let fingerprint = try #require(SSHTunnel.fingerprint(of: key))
    do {
      try await policy.validate(host: host, port: 22, hostKey: key, fingerprint: fingerprint)
    } catch {
      return (store, coordinator, policy, key, fingerprint, error)
    }
    Issue.record("A changed key must be blocked")
    throw CancellationError()
  }

  @Test("Replace Pin stores exactly the presented key, then the retry trusts it")
  func replacePinStoresPresentedKey() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let changed = try await Self.changedKey(presenter)
    let retried = FiredFlag()
    _ = changed.coordinator.report(changed.error, retry: { retried.set() })
    #expect(
      presenter.changes == [
        SSHHostKeyChange(
          host: "bastion.example", port: 22, expected: "SHA256:old",
          presented: changed.fingerprint, presentedAlgorithm: "ssh-ed25519")
      ])

    presenter.replaceChanged()
    try await waitFor { retried.isSet }
    let pinned = try #require(try changed.store.lookup(host: "bastion.example", port: 22))
    #expect(pinned.algorithm == "ssh-ed25519")
    #expect(pinned.fingerprint == changed.fingerprint)
    // The retried connect is trusted without a prompt
    try await changed.policy.validate(
      host: "bastion.example", port: 22, hostKey: changed.key, fingerprint: changed.fingerprint)
    #expect(presenter.presented.isEmpty)
  }

  @Test("Cancel on a changed key keeps the old pin and the connect stays blocked")
  func cancelKeepsOldPin() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let changed = try await Self.changedKey(presenter)
    let retried = FiredFlag()
    _ = changed.coordinator.report(changed.error, retry: { retried.set() })
    presenter.cancelChanged()

    #expect(!retried.isSet)
    #expect(
      try changed.store.lookup(host: "bastion.example", port: 22)?.fingerprint == "SHA256:old")
    await #expect {
      try await changed.policy.validate(
        host: "bastion.example", port: 22, hostKey: changed.key,
        fingerprint: changed.fingerprint)
    } throws: {
      guard case DatabaseError.sshHostKeyChanged = $0 else { return false }
      return true
    }
  }

  @Test("The retry and the secrets it holds go once the changed-key alert ends without Replace")
  func retryReleasedWithoutReplace() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let changed = try await Self.changedKey(presenter)
    weak var cancelled: RetrySecret?
    weak var dropped: RetrySecret?
    do {
      let secret = RetrySecret()
      cancelled = secret
      _ = changed.coordinator.report(changed.error) { secret.use() }
      // A second report while the alert shows is dropped: one alert at a time
      let second = RetrySecret()
      dropped = second
      _ = changed.coordinator.report(changed.error) { second.use() }
    }
    #expect(dropped == nil)
    presenter.cancelChanged()
    #expect(cancelled == nil)

    weak var closed: RetrySecret?
    do {
      let secret = RetrySecret()
      closed = secret
      _ = changed.coordinator.report(changed.error) { secret.use() }
    }
    // The window closed: AppKit may keep the alert's handler, never the retry
    presenter.closeChangedAlertWindow()
    #expect(closed == nil)
    #expect(presenter.changes.count == 2)
  }

  @Test("Replace Pin keeps a pin that changed since the alert and does not retry")
  func replaceKeepsPinChangedMeanwhile() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    let store = TouchFlagSSHKnownHostStore()
    // Its own host: the toast this shows is shared with tests running in parallel
    let host = "pin-race.example"
    let changed = try await Self.changedKey(presenter, host: host, store: store)
    let retried = FiredFlag()
    _ = changed.coordinator.report(changed.error, retry: { retried.set() })
    // Another window replaced the pin while this alert was open
    store.replacePin(host: host, port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:other")
    store.arm()

    presenter.replaceChanged()
    try await waitFor { store.touched.isSet }
    #expect(try store.lookup(host: host, port: 22)?.fingerprint == "SHA256:other")
    #expect(!retried.isSet)
  }

  @Test("No window for the sheet and a failed pin are reported apart from Cancel")
  func unpresentableAndPinFailureReporting() async throws {
    let presenter = FakeSSHHostKeyTrustPresenter()
    presenter.canPresent = false
    let coordinator = SSHHostKeyTrustCoordinator(presenter: presenter)
    let request = Self.request(host: "hidden.example", fingerprint: "SHA256:hidden")
    #expect(await coordinator.confirm(request) == false)
    let unshown = coordinator.report(
      DatabaseError.sshHostKeyNotTrusted(host: "hidden.example", fingerprint: "SHA256:hidden"),
      retry: {})
    #expect(unshown.contains("could not be shown"))

    // Shown later and cancelled by the user: a plain Cancel again.
    presenter.canPresent = true
    let pending = Task { await coordinator.confirm(request) }
    try await waitFor { presenter.presented.count == 1 }
    presenter.answer(false)
    #expect(await pending.value == false)
    #expect(
      coordinator.report(
        DatabaseError.sshHostKeyNotTrusted(host: "hidden.example", fingerprint: "SHA256:hidden"),
        retry: {})
        == "Connection cancelled. The SSH host key was not trusted.")

    let pinFailed = coordinator.report(
      DatabaseError.sshHostKeyPinFailed(host: "bastion.example", port: 22), retry: {})
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
    await presenter.wait { presenter.presented.count == 1 }
    connect.cancel()
    await #expect(throws: (any Error).self) { _ = try await connect.value }
    await presenter.wait { presenter.dismissCount == 1 }
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
    let error = try await closeServerDuringPrompt(handshakeTimeout: .seconds(30), hold: .zero)
    #expect(error as? SSHTunnelError == .closedWhileConfirmingHostKey)
  }

  @Test(
    "Time in the host-key prompt does not count against the handshake timeout",
    .timeLimit(.minutes(1)))
  func promptTimeDoesNotCountAgainstHandshakeTimeout() async throws {
    // The prompt stays open past the timeout; without the pause the deadline would fire and
    // fail with handshakeTimedOut. The timeout leaves room for key exchange under load.
    let error = try await closeServerDuringPrompt(
      handshakeTimeout: .seconds(5), hold: .seconds(6))
    #expect(error as? SSHTunnelError == .closedWhileConfirmingHostKey)
  }

  /// Connects to a local SSH server, keeps the host-key prompt open for `hold`, then closes
  /// the server side. Returns what `SSHTunnel.connect` threw.
  private func closeServerDuringPrompt(
    handshakeTimeout: TimeAmount, hold: Duration
  ) async throws -> (any Error)? {
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
          // Only the server closing ends it: the close cancels the validator.
          try await Task.sleep(for: .seconds(3600))
        }, group: group, handshakeTimeout: handshakeTimeout)
    }
    // The validator sets the flag after the deadline is paused.
    var result: Result<SSHTunnel, any Error>?
    if await boundedWait("The host-key validator call", { await prompting.wait() }) != nil {
      try await Task.sleep(for: hold)
      accepted.closeAll()
      // Shorter than the default so a stall is reported before the test's time limit.
      result = await boundedWait("Connect returning after the server closed", timeout: .seconds(20))
      {
        await connect.result
      }
    }
    if result == nil {
      // Cleanup only: the timeout is already recorded. What connect threw shows in the expect.
      connect.cancel()
      result = await connect.result
    }
    try await server.close()
    try await group.shutdownGracefully()
    guard case .failure(let error) = result else { return nil }
    return error
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

/// Polls on the main actor until `condition` holds (fails after 30 s: the full suite can be slow).
@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
  let end = ContinuousClock.now + .seconds(30)
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
  private var changedAnswer: (@MainActor (Bool) -> Void)?
  /// Handlers kept after their window closed, as AppKit may.
  private var leakedHandlers: [Any] = []
  private var waiters: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] =
    []

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
    resumeWaiters()
    return true
  }

  func dismissTrust() {
    dismissCount += 1
    decide = nil
    resumeWaiters()
  }

  /// Returns once `condition` holds; checked again after every present and dismiss.
  func wait(until condition: @escaping () -> Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if condition() {
        continuation.resume()
      } else {
        waiters.append((condition, continuation))
      }
    }
  }

  private func resumeWaiters() {
    let met = waiters.filter { $0.condition() }
    waiters.removeAll { $0.condition() }
    for waiter in met { waiter.continuation.resume() }
  }

  /// One alert at a time, as AppKit's: a report while one is open is not shown.
  func presentHostKeyChanged(
    _ change: SSHHostKeyChange, answered: @escaping @MainActor (_ replace: Bool) -> Void
  ) -> Bool {
    guard changedAnswer == nil else { return false }
    changes.append(change)
    changedAnswer = answered
    return true
  }

  /// The window under the changed-key alert closed: answered false, and the handler kept,
  /// as AppKit may.
  func closeChangedAlertWindow() {
    leakedHandlers.append(changedAnswer as Any)
    endChanged(replace: false)
  }

  /// Replace Pin in the changed-key alert.
  func replaceChanged() { endChanged(replace: true) }

  /// Cancel in the changed-key alert.
  func cancelChanged() { endChanged(replace: false) }

  private func endChanged(replace: Bool) {
    let pending = changedAnswer
    changedAnswer = nil
    pending?(replace)
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

/// Stands for a secret a retry captured; released with the retry.
private final class RetrySecret {
  func use() {}
}

/// An in-memory store that flags its first read or write after `arm()`.
private final class TouchFlagSSHKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  let touched = FiredFlag()
  private let base = InMemorySSHKnownHostStore()
  private let lock = NSLock()
  private var armed = false

  func arm() { lock.withLock { armed = true } }

  private func touch() {
    if lock.withLock({ armed }) { touched.set() }
  }

  func load(account: String) throws -> SSHKnownHost? {
    defer { touch() }
    return try base.load(account: account)
  }

  func add(_ host: SSHKnownHost, account: String) -> Bool {
    defer { touch() }
    return base.add(host, account: account)
  }

  func save(_ host: SSHKnownHost, account: String) -> Bool {
    defer { touch() }
    return base.save(host, account: account)
  }

  func delete(account: String) { base.delete(account: account) }
}

/// Lookups find nothing and every pin fails to save (e.g. a Keychain write error).
private final class UnwritableSSHKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  func load(account: String) throws -> SSHKnownHost? { nil }
  func add(_ host: SSHKnownHost, account: String) -> Bool { false }
  func save(_ host: SSHKnownHost, account: String) -> Bool { false }
  func delete(account: String) {}
}
