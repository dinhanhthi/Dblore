// VaultLeaseManagerTests.swift
// Vault leases per connect, with a fake clock and a fake Vault client (no live Vault): the slot
// semantics of `DatabaseConnectionManager` (keep on an internal reset, revoke after close on any
// other connect or disconnect, on a dropped manager and on a cancelled connect), renewal timing
// and its definitive ends, AppRole renew-self and revoke-self, the secret's destination binding,
// unremembered secrets, the quit close set, and the "Vault lease ended." banner text.

import Foundation
import Testing

@testable import Dblore

/// A clock the test moves by hand. `sleep` suspends until `advance` passes its deadline.
private nonisolated final class FakeLeaseClock: VaultLeaseClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: TimeInterval = 0
  private var sleepers: [UUID: (deadline: TimeInterval, wake: CheckedContinuation<Void, Error>)] =
    [:]
  /// Sleeps that suspended so far
  private var suspended = 0
  private var waiters: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []

  func now() -> TimeInterval { lock.withLock { current } }

  func sleep(until deadline: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, Error>) in
        let ready: [CheckedContinuation<Void, Never>]? = lock.withLock {
          guard deadline > current, !Task.isCancelled else { return nil }
          sleepers[id] = (deadline, wake)
          suspended += 1
          return takeWaiters()
        }
        if let ready {
          ready.forEach { $0.resume() }
        } else {
          wake.resume()
        }
      }
    } onCancel: {
      lock.withLock { sleepers.removeValue(forKey: id) }?.wake.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
  }

  /// Moves the clock to `time` and wakes every sleeper whose deadline has passed.
  func advance(to time: TimeInterval) {
    let due = lock.withLock {
      current = time
      let due = sleepers.filter { $0.value.deadline <= time }
      for id in due.keys { sleepers[id] = nil }
      return due.values.map(\.wake)
    }
    due.forEach { $0.resume() }
  }

  /// Returns once `count` sleeps have suspended in total.
  func waitForSleeps(_ count: Int) async {
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      let now = lock.withLock {
        guard suspended < count else { return true }
        waiters.append((count, resume))
        return false
      }
      if now { resume.resume() }
    }
  }

  var deadlines: [TimeInterval] { lock.withLock { sleepers.values.map(\.deadline).sorted() } }

  /// Under the lock
  private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
    let ready = waiters.filter { $0.count <= suspended }.map(\.resume)
    waiters.removeAll { $0.count <= suspended }
    return ready
  }
}

/// Vault answers set by a test; every call is recorded.
private nonisolated final class FakeVaultClient: VaultClient, @unchecked Sendable {
  enum Call: Equatable {
    case read(token: String)
    case renew(id: String, token: String)
    case revoke(id: String)
    case login
    case lookup
    case renewSelf(token: String)
    case revokeSelf(token: String)
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private var waiters:
    [(test: (Call) -> Bool, count: Int, resume: CheckedContinuation<Void, Never>)] =
      []
  private var leases = 0
  private var heldRenew: CheckedContinuation<Void, Never>?
  private var heldRead: CheckedContinuation<Void, Never>?
  private var readReleased = false

  var leaseDuration = 90
  /// The duration renewals answer (`leaseDuration` when nil)
  var renewDuration: Int?
  /// Every creds read fails with this when set
  var readFails: VaultClientError?
  /// The next creds read waits for `releaseRead` once recorded
  var holdsNextRead = false
  /// Answers of the next renewals in order; a success with `leaseDuration` once empty
  var renewErrors: [VaultClientError?] = []
  /// Every renewal fails with this when set
  var renewAlwaysFails: VaultClientError?
  var lookupFails: VaultClientError?
  var login = VaultAuth(clientToken: "approle-token", duration: 3_600, renewable: true)
  /// The next renewal waits for `releaseRenew`
  var holdsNextRenew = false
  /// Called with the lease id when a revoke arrives
  var onRevoke: (@Sendable (String) -> Void)?

  var calls: [Call] { lock.withLock { recorded } }

  func count(_ test: (Call) -> Bool) -> Int { calls.filter(test).count }

  /// Returns once `count` calls matching `test` were made.
  func waitFor(_ count: Int, _ test: @escaping (Call) -> Bool) async {
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      let now = lock.withLock {
        guard recorded.filter(test).count < count else { return true }
        waiters.append((test, count, resume))
        return false
      }
      if now { resume.resume() }
    }
  }

  func releaseRenew() {
    lock.withLock {
      defer { heldRenew = nil }
      return heldRenew
    }?.resume()
  }

  func releaseRead() {
    lock.withLock {
      defer { heldRead = nil }
      if heldRead == nil { readReleased = true }
      return heldRead
    }?.resume()
  }

  func readCredentials(token: String) async throws -> VaultLeasedCredentials {
    let (number, holds) = lock.withLock {
      leases += 1
      defer { holdsNextRead = false }
      return (leases, holdsNextRead)
    }
    record(.read(token: token))
    if holds {
      await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
        let go = lock.withLock {
          if readReleased { return true }
          heldRead = resume
          return false
        }
        if go { resume.resume() }
      }
    }
    if let readFails { throw readFails }
    return VaultLeasedCredentials(
      lease: VaultLease(id: "lease-\(number)", duration: leaseDuration, renewable: true),
      username: "v-user-\(number)", password: "v-pass-\(number)")
  }

  func renewLease(id: String, increment: Int?, token: String) async throws -> VaultLease {
    let holds = lock.withLock {
      defer { holdsNextRenew = false }
      return holdsNextRenew
    }
    record(.renew(id: id, token: token))
    if holds {
      await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
        lock.withLock { heldRenew = resume }
      }
    }
    let error = lock.withLock { renewErrors.isEmpty ? renewAlwaysFails : renewErrors.removeFirst() }
    if let error { throw error }
    return VaultLease(id: id, duration: renewDuration ?? leaseDuration, renewable: true)
  }

  /// Fails in a cancelled task, as URLSession does: a revoke must be sent from a task of its own
  func revokeLease(id: String, token: String) async throws {
    try Task.checkCancellation()
    onRevoke?(id)
    record(.revoke(id: id))
  }

  func revokeSelf(token: String) async throws {
    try Task.checkCancellation()
    record(.revokeSelf(token: token))
  }

  func appRoleLogin(roleID: String, secretID: String) async throws -> VaultAuth {
    record(.login)
    return login
  }

  func lookupSelf(token: String) async throws -> VaultTokenInfo {
    record(.lookup)
    if let lookupFails { throw lookupFails }
    return VaultTokenInfo(ttl: 30, expireTime: nil, renewable: true, period: nil)
  }

  func renewSelf(increment: Int?, token: String) async throws -> VaultAuth {
    record(.renewSelf(token: token))
    return login
  }

  private func record(_ call: Call) {
    let ready = lock.withLock {
      recorded.append(call)
      let ready = waiters.filter { waiter in recorded.filter(waiter.test).count >= waiter.count }
      waiters.removeAll { waiter in recorded.filter(waiter.test).count >= waiter.count }
      return ready.map(\.resume)
    }
    ready.forEach { $0.resume() }
  }
}

/// The fake session factory, recording each config it gets and what the certificate and SSH
/// stores return for it.
private nonisolated final class RecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let inner: FakeDatabaseSessionFactory
  private let lock = NSLock()
  private var made:
    [(config: ConnectionConfig, certificate: ClientCertificateMaterial?, ssh: SSHStoredCredential?)] =
      []
  private var hook: (@Sendable (Int) async throws -> Void)?

  /// Awaited in `makeSession` with the session's index, before it is made (a throw fails it)
  var onMake: (@Sendable (Int) async throws -> Void)? {
    get { lock.withLock { hook } }
    set { lock.withLock { hook = newValue } }
  }

  init(_ inner: FakeDatabaseSessionFactory = FakeDatabaseSessionFactory(capabilities: .contract()))
  {
    self.inner = inner
  }

  var configs: [ConnectionConfig] { lock.withLock { made.map(\.config) } }
  var certificates: [ClientCertificateMaterial?] { lock.withLock { made.map(\.certificate) } }
  var sshSecrets: [SSHStoredCredential?] { lock.withLock { made.map(\.ssh) } }
  var sessions: [FakeDatabaseSession] { inner.sessions }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    let certificate = ClientCertificateStoreFactory.load(for: config)
    let ssh = SSHCredentialStoreFactory.load(for: config)
    let index = lock.withLock {
      made.append((config, certificate, ssh))
      return made.count - 1
    }
    try await onMake?(index)
    return inner.makeSession(config: config)
  }
}

private func isRead(_ call: FakeVaultClient.Call) -> Bool {
  if case .read = call { return true }
  return false
}

private func isRenew(_ call: FakeVaultClient.Call) -> Bool {
  if case .renew = call { return true }
  return false
}

private func isRevoke(_ call: FakeVaultClient.Call) -> Bool {
  if case .revoke = call { return true }
  return false
}

private func isRenewSelf(_ call: FakeVaultClient.Call) -> Bool {
  if case .renewSelf = call { return true }
  return false
}

private func isRevokeSelf(_ call: FakeVaultClient.Call) -> Bool {
  if case .revokeSelf = call { return true }
  return false
}

@MainActor
@Suite("Vault lease per connect", .timeLimit(.minutes(1)))
struct VaultLeaseManagerTests {
  private let clock = FakeLeaseClock()
  private let client = FakeVaultClient()
  private let store = InMemoryVaultSecretStore()
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private static let token = "hvs.test-token"

  private var leasing: VaultLeasing {
    let client = client
    return VaultLeasing(clock: clock, makeClient: { _ in client }, store: store)
  }

  private func manager(_ factory: any DatabaseSessionFactory) -> DatabaseConnectionManager {
    DatabaseConnectionManager(sessionFactory: factory, vaultLeasing: leasing)
  }

  /// A Vault connection whose token is saved. `type` .sqlite sends Test Connection's probe
  /// through the session factory (the network engines probe with sessions of their own).
  private func vaultConfig(
    role: String = "app-ro", database: String = "db", type: DatabaseType = .postgresql,
    auth: VaultSource.AuthMethod = .token, protectedMode: Bool = false, saved: Bool = true
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: type, host: "vault-db.test", port: 5432, database: database,
      username: "saved-user", password: "", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: protectedMode)
    config.vault = VaultSource(
      address: "https://vault.test:8200", mount: "database", role: role, authMethod: auth,
      caPEM: nil)
    if saved {
      VaultCredentialStore.save(
        auth == .token ? .token(Self.token) : .appRole(roleID: "role-id", secretID: "secret-id"),
        for: config, to: store)
    }
    return config
  }

  /// The loss events `trigger` caused: once `lease`'s renewal has finished (every report it
  /// makes is yielded by then), a sentinel is yielded and the events before it are returned.
  private func lossEvents(
    _ manager: DatabaseConnectionManager, renewalOf lease: VaultLeaseManager?,
    after trigger: () async -> Void
  ) async -> [SessionLostEvent] {
    var events = manager.sessionEvents.makeAsyncIterator()
    await trigger()
    await lease?.renewalFinished()
    let continuation = await manager.sessionEventsContinuation
    continuation.yield(Self.sentinel)
    var seen: [SessionLostEvent] = []
    while let event = await events.next(), event != Self.sentinel {
      seen.append(event)
    }
    return seen
  }

  private static let sentinel = SessionLostEvent(state: .idle, userTxOpen: false, epoch: 999_999)

  // MARK: - Renewal timing

  @Test("The lease is renewed at 2/3 of its TTL, with the token that created it")
  func renewsAtTwoThirds() async throws {
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    await clock.waitForSleeps(1)
    #expect(clock.deadlines == [60])
    clock.advance(to: 59)
    #expect(client.count(isRenew) == 0)
    clock.advance(to: 60)
    await clock.waitForSleeps(2)
    #expect(client.calls.filter(isRenew) == [.renew(id: "lease-1", token: Self.token)])
    #expect(clock.deadlines == [120])
    await connection.disconnect()
  }

  @Test("A failed renewal followed by a successful retry keeps the session and reports nothing")
  func retryKeepsSession() async throws {
    client.renewErrors = [.http(status: 503, errors: ["Vault is sealed"])]
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    await clock.waitForSleeps(1)
    clock.advance(to: 60)
    await clock.waitForSleeps(2)
    // Every 10% of the 90 s TTL
    #expect(clock.deadlines == [69])
    clock.advance(to: 69)
    await clock.waitForSleeps(3)
    #expect(client.count(isRenew) == 2)
    #expect(clock.deadlines == [129])
    #expect(await connection.isConnected)
    #expect(await connection.lastSessionLoss == nil)
    #expect(await connection.lastLeaseEnd == nil)
    #expect(client.count(isRevoke) == 0)
    await connection.disconnect()
  }

  @Test("Renewals still failing at the lease's expiry yield exactly one loss report")
  func failingUntilExpiryReportsOnce() async throws {
    client.renewAlwaysFails = .network(code: -1004)
    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
      await clock.waitForSleeps(2)
      // The retry at 69 fails too; the next one (89 + 9) is past the expiry
      clock.advance(to: 89)
      await clock.waitForSleeps(3)
      #expect(client.count(isRenew) == 2)
      #expect(clock.deadlines == [90])
      clock.advance(to: 90)
    }
    #expect(events.count == 1)
    #expect(await connection.lastLeaseEnd?.reason == .expired)
    #expect(await connection.isConnected == false)
    #expect(factory.sessions.first?.didClose == true)
    #expect(!connection.holdsLease)
  }

  @Test("A 403 renewal while lookup-self still answers keeps the session until the known expiry")
  func forbiddenRenewalWithLiveTokenWaitsForExpiry() async throws {
    client.renewAlwaysFails = .http(status: 403, errors: ["1 error occurred: * permission denied"])
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
      await clock.waitForSleeps(2)
      #expect(client.count { $0 == .lookup } == 1)
      clock.advance(to: 87)
      await clock.waitForSleeps(3)
      #expect(await connection.isConnected)
      #expect(clock.deadlines == [90])
      clock.advance(to: 90)
    }
    #expect(events.count == 1)
    #expect(await connection.lastLeaseEnd?.reason == .expired)
  }

  @Test("A lease end closes the connection, sets lastLeaseEnd and yields the loss event")
  func leaseEndReportsLoss() async throws {
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig(protectedMode: true))
    _ = try await connection.execute(
      userSQL: "UPDATE t SET a = 1",
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))
    #expect(await connection.transactionSnapshot().pending.count == 1)
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
    }
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.pendingCount == 1)
    let end = try #require(await connection.lastLeaseEnd)
    #expect(end == VaultLeaseEnd(reason: .leaseGone, epoch: event.epoch))
    #expect(await connection.lastSessionLoss == event)
    #expect(await connection.isConnected == false)
    #expect(factory.sessions.first?.didClose == true)
    // A lease Vault no longer knows is not revoked
    #expect(client.count(isRevoke) == 0)

    // 22.5: the banner keeps the event's lines
    let message = WorkspaceManager.connectionLostMessage(for: event, leaseEnd: end)
    #expect(message.hasPrefix("Vault lease ended."))
    #expect(message.contains("1 pending change was rolled back by the server."))
    #expect(message.hasSuffix("Reconnect to continue."))
    // Another loss's event (an older epoch) keeps the plain text
    let other = SessionLostEvent(state: .idle, userTxOpen: false, epoch: event.epoch &- 1)
    #expect(WorkspaceManager.connectionLostMessage(for: other, leaseEnd: end) == other.message)
  }

  @Test("A renewal answering lease_duration 0 leaves the lease without expiry, like a new one")
  func renewWithoutTTLNeverExpires() async throws {
    client.renewDuration = 0
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    let lease = try #require(connection.vaultLease)
    await clock.waitForSleeps(1)
    clock.advance(to: 60)
    // Nothing left to renew and no expiry: the renewal stops
    await lease.renewalFinished()
    #expect(client.count(isRenew) == 1)
    #expect(clock.deadlines.isEmpty)
    clock.advance(to: 10_000)
    #expect(await connection.isConnected)
    #expect(await connection.lastLeaseEnd == nil)
    await connection.disconnect()
  }

  @Test("A kept lease that ends while a reset opens its session: closed, and one loss reported")
  func leaseEndDuringResetReportsLoss() async throws {
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let factory = RecordingFactory(
      FakeDatabaseSessionFactory(
        capabilities: .contract(supportsServerCursor: true),
        columns: [ColumnInfo(name: "id", type: "INTEGER")],
        rows: (1...5).map { [CellValue.int($0)] }))
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    let lease = try #require(connection.vaultLease)
    await clock.waitForSleeps(1)
    let clock = clock
    // The capped-read reset's new session: the kept lease ends while it is made
    factory.onMake = { index in
      guard index == 1 else { return }
      clock.advance(to: 60)
      await lease.renewalFinished()
    }
    let policy = open
    let events = await lossEvents(connection, renewalOf: lease) {
      let read = try? await connection.execute(
        userSQL: "SELECT * FROM t", policy: policy, maxRows: 2)
      #expect(read?.sessionReset == true)
    }
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(factory.sessions.count == 2)
    #expect(factory.sessions.last?.didClose == true)
    #expect(await connection.isConnected == false)
    #expect(await connection.lastLeaseEnd == VaultLeaseEnd(reason: .leaseGone, epoch: event.epoch))
    #expect(
      WorkspaceManager.connectionLostMessage(for: event, leaseEnd: await connection.lastLeaseEnd)
        .hasPrefix("Vault lease ended."))
    #expect(client.count(isRead) == 1)
    #expect(client.count(isRevoke) == 0)
    #expect(!connection.holdsLease)
  }

  // MARK: - Slot: keep, revoke, replace

  @Test("A final disconnect closes the session, then revokes the lease once")
  func disconnectRevokesAfterClose() async throws {
    let factory = RecordingFactory()
    let closedAtRevoke = Locked<[Bool]>([])
    client.onRevoke = { _ in
      closedAtRevoke.update { $0.append(factory.sessions.first?.didClose == true) }
    }
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    #expect(connection.holdsLease)
    await connection.disconnect()
    await connection.disconnect()
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(closedAtRevoke.value == [true])
    #expect(!connection.holdsLease)
    // The saved token is the user's: never revoked
    #expect(client.count(isRevokeSelf) == 0)
  }

  @Test("A capped-read reset reconnects with the same lease and revokes nothing")
  func cappedReadKeepsLease() async throws {
    let factory = RecordingFactory(
      FakeDatabaseSessionFactory(
        capabilities: .contract(supportsServerCursor: true),
        columns: [ColumnInfo(name: "id", type: "INTEGER")],
        rows: (1...5).map { [CellValue.int($0)] }))
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    let read = try await connection.execute(userSQL: "SELECT * FROM t", policy: open, maxRows: 2)
    #expect(read.sessionReset)
    #expect(factory.sessions.count == 2)
    #expect(factory.configs.map(\.username) == ["v-user-1", "v-user-1"])
    #expect(client.count(isRead) == 1)
    #expect(client.count(isRevoke) == 0)
    #expect(connection.vaultLease?.leaseID == "lease-1")
    await connection.disconnect()
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
  }

  @Test("A PostgreSQL Cancel reconnects with the same lease and revokes nothing")
  func cancelKeepsLease() async throws {
    let factory = RecordingFactory(
      FakeDatabaseSessionFactory(
        capabilities: .contract(cancelStrategy: .reconnect), slowQueries: true))
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    let session = try #require(factory.sessions.first)
    let policy = open
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: policy)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    await session.interrupt()
    _ = try? await running.value
    #expect(factory.sessions.count == 2)
    #expect(factory.configs.map(\.username) == ["v-user-1", "v-user-1"])
    #expect(client.count(isRead) == 1)
    #expect(client.count(isRevoke) == 0)
    await connection.disconnect()
  }

  @Test("Connect A then B on one manager revokes A once; B's session gets B's lease")
  func connectAnotherVaultConfig() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig(role: "a"))
    try await connection.connect(config: vaultConfig(role: "b"))
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(factory.configs.last?.username == "v-user-2")
    #expect(factory.configs.last?.password == "v-pass-2")
    #expect(connection.vaultLease?.leaseID == "lease-2")
    await connection.disconnect()
  }

  @Test("Overlapping connects: the first one's failed open leaves the second one's lease alone")
  func failedOverlappingConnectKeepsOtherLease() async throws {
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let factory = RecordingFactory()
    let connection = manager(factory)
    let config = vaultConfig()
    let reachedOpen = Gate()
    let failOpen = Gate()
    factory.onMake = { index in
      guard index == 0 else { return }
      reachedOpen.open()
      await failOpen.wait()
      throw FakeQueryError()
    }
    let first = Task { try await connection.connect(config: config) }
    await reachedOpen.wait()
    try await connection.connect(config: config)
    failOpen.open()
    await #expect(throws: FakeQueryError.self) { try await first.value }

    #expect(client.count { $0 == .revoke(id: "lease-2") } == 0)
    #expect(client.count { $0 == .revoke(id: "lease-1") } >= 1)
    #expect(connection.vaultLease?.leaseID == "lease-2")
    #expect(await connection.isConnected)
    #expect(factory.configs.last?.username == "v-user-2")
    // The second lease's renewal is still the held one: its end is reported
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
    }
    #expect(client.calls.filter(isRenew) == [.renew(id: "lease-2", token: Self.token)])
    #expect(events.count == 1)
    #expect(await connection.lastLeaseEnd?.reason == .leaseGone)
  }

  @Test("A connect whose lease another connect replaced closes its session and publishes nothing")
  func supersededConnectPublishesNothing() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    let config = vaultConfig()
    let reachedOpen = Gate()
    let finishOpen = Gate()
    factory.onMake = { index in
      guard index == 0 else { return }
      reachedOpen.open()
      await finishOpen.wait()
    }
    let first = Task { try await connection.connect(config: config) }
    await reachedOpen.wait()
    try await connection.connect(config: config)
    finishOpen.open()
    await #expect(throws: VaultLeaseError.leaseEnded) { try await first.value }

    // The second connect's session was made first (the first one waited in `onMake`)
    #expect(factory.sessions.count == 2)
    #expect(factory.sessions.first?.didClose == false)
    #expect(factory.sessions.last?.didClose == true)
    #expect(connection.vaultLease?.leaseID == "lease-2")
    #expect(client.count { $0 == .revoke(id: "lease-2") } == 0)
    #expect(await connection.isConnected)
    await connection.disconnect()
  }

  @Test("Connect A then a non-Vault config revokes A and applies no overlay")
  func connectNonVaultConfig() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    var plain = vaultConfig()
    plain.vault = nil
    plain.password = "plain-pw"
    try await connection.connect(config: plain)
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(factory.configs.last?.username == "saved-user")
    #expect(factory.configs.last?.password == "plain-pw")
    #expect(!connection.holdsLease)
    await connection.disconnect()
    #expect(client.count(isRevoke) == 1)
  }

  @Test("Connect A, then A again: a new lease; A's renewal answering 'lease not found' is ignored")
  func reconnectIgnoresOldRenewal() async throws {
    client.holdsNextRenew = true
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let factory = RecordingFactory()
    let connection = manager(factory)
    let config = vaultConfig()
    try await connection.connect(config: config)
    await clock.waitForSleeps(1)
    let leaseA = try #require(connection.vaultLease)
    clock.advance(to: 60)
    await client.waitFor(1, isRenew)

    try await connection.connect(config: config)
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(connection.vaultLease?.leaseID == "lease-2")
    let events = await lossEvents(connection, renewalOf: leaseA) {
      client.releaseRenew()
    }
    #expect(events.isEmpty)
    #expect(await connection.isConnected)
    #expect(await connection.lastLeaseEnd == nil)
    #expect(factory.sessions.last?.didClose == false)
    await connection.disconnect()
  }

  @Test("The manager's config never holds the lease username or password")
  func configKeepsSavedCredentials() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: vaultConfig())
    let live = try #require(await connection.config)
    #expect(live.username == "saved-user")
    #expect(live.password == "")
    #expect(factory.configs.first?.username == "v-user-1")
    #expect(factory.configs.first?.password == "v-pass-1")
    try await connection.reconnectWithActiveCertificate(config: live, material: nil)
    #expect(await connection.config?.username == "saved-user")
    #expect(await connection.config?.password == "")
    await connection.disconnect()
  }

  // MARK: - Test Connection, side managers, scoped secrets

  @Test("Test Connection takes and revokes its own lease; the config keeps the saved username")
  func testConnectionRevokesOnce() async throws {
    let factory = RecordingFactory(
      FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]]))
    let connection = manager(factory)
    let config = vaultConfig(type: .sqlite)
    #expect(try await connection.testConnection(config: config))
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(factory.configs.map(\.username) == ["v-user-1"])
    #expect(config.username == "saved-user")
    #expect(await connection.config == nil)
    #expect(!connection.holdsLease)
  }

  @Test("Test Connection on a manager connected with lease A uses lease B and leaves A alone")
  func testConnectionKeepsLiveLease() async throws {
    let factory = RecordingFactory(
      FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]]))
    let connection = manager(factory)
    let config = vaultConfig(type: .sqlite)
    try await connection.connect(config: config)
    #expect(try await connection.testConnection(config: config))
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-2")])
    #expect(await connection.isConnected)
    #expect(connection.vaultLease?.leaseID == "lease-1")
    #expect(factory.sessions.first?.didClose == false)
    await connection.disconnect()
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-2"), .revoke(id: "lease-1")])
  }

  @Test("A side manager on another database finds the identity's Vault secret")
  func sideManagerUsesIdentitySecret() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    let identity = vaultConfig()
    try await connection.connect(config: identity)
    let other = vaultConfig(database: "other", saved: false)

    // Without the identity, the other database's own (missing) secret is asked for
    let alone = manager(factory)
    await #expect(throws: VaultLeaseError.secretMissing) {
      try await connection.connectSideManager(alone, config: other)
    }

    let side = manager(factory)
    try await connection.connectSideManager(side, config: other, identity: identity)
    #expect(await side.isConnected)
    #expect(client.calls.filter(isRead) == [.read(token: Self.token), .read(token: Self.token)])
    #expect(side.vaultLease?.leaseID == "lease-2")
    #expect(factory.configs.last?.database == "other")
    #expect(factory.configs.last?.username == "v-user-2")
    await side.disconnect()
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-2")])
    await connection.disconnect()
  }

  @Test("SSH tunnel and client certificate: the session config finds the saved secrets")
  func scopedSecretsUnderLeaseAccounts() async throws {
    var config = vaultConfig()
    config.host = "vault-\(UUID().uuidString).test"
    config.sshTunnel = SSHTunnelConfig(host: "bastion.test", username: "jump")
    config.clientCertificate = ClientCertificateInfo(subject: "CN=app", expiry: nil, hasCA: false)
    VaultCredentialStore.save(.token(Self.token), for: config, to: store)
    let material = ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key")
    let certificateAccount = ClientCertificateStoreFactory.account(for: config)
    let sshAccount = try #require(SSHCredentialStoreFactory.account(for: config))
    ClientCertificateStoreFactory.shared.save(material, account: certificateAccount)
    SSHCredentialStoreFactory.shared.save(.password("ssh-pw"), account: sshAccount)
    defer {
      ClientCertificateStoreFactory.shared.delete(account: certificateAccount)
      SSHCredentialStoreFactory.shared.delete(account: sshAccount)
    }

    let factory = RecordingFactory()
    let connection = manager(factory)
    try await connection.connect(config: config)
    #expect(factory.configs.first?.username == "v-user-1")
    #expect(factory.certificates.first == material)
    #expect(factory.sshSecrets.first == .password("ssh-pw"))
    await connection.disconnect()
  }

  // MARK: - AppRole and token lifetime

  @Test("AppRole: renew-self at 2/3 of a short login token TTL, and never a second login")
  func appRoleRenewsSelf() async throws {
    client.login = VaultAuth(clientToken: "approle-token", duration: 30, renewable: true)
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig(auth: .appRole))
    #expect(client.calls.filter(isRead) == [.read(token: "approle-token")])
    await clock.waitForSleeps(1)
    #expect(clock.deadlines == [20])
    clock.advance(to: 20)
    await clock.waitForSleeps(2)
    #expect(client.calls.filter(isRenewSelf) == [.renewSelf(token: "approle-token")])
    #expect(clock.deadlines == [40])
    clock.advance(to: 40)
    await clock.waitForSleeps(3)
    clock.advance(to: 60)
    await clock.waitForSleeps(4)
    #expect(client.count(isRenewSelf) == 3)
    #expect(client.calls.filter(isRenew) == [.renew(id: "lease-1", token: "approle-token")])
    #expect(client.count { $0 == .login } == 1)
    #expect(await connection.isConnected)
    await connection.disconnect()
    #expect(client.count { $0 == .login } == 1)
  }

  @Test("AppRole with a TTL-0 login token: no renew-self, and nothing capped by the token")
  func ttlZeroTokenCapsNothing() async throws {
    client.login = VaultAuth(clientToken: "approle-token", duration: 0, renewable: false)
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig(auth: .appRole))
    await clock.waitForSleeps(1)
    #expect(clock.deadlines == [60])
    clock.advance(to: 60)
    await clock.waitForSleeps(2)
    clock.advance(to: 120)
    await clock.waitForSleeps(3)
    #expect(client.count(isRenew) == 2)
    #expect(client.count(isRenewSelf) == 0)
    #expect(await connection.isConnected)
    await connection.disconnect()
  }

  @Test("Token method: a token renewed elsewhere stays connected past its original expiry")
  func tokenRenewedElsewhereStays() async throws {
    // lookup-self would say ttl 30: no expiry is predicted from it
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    for (step, time) in [60.0, 120, 180].enumerated() {
      await clock.waitForSleeps(step + 1)
      clock.advance(to: time)
    }
    await clock.waitForSleeps(4)
    #expect(client.count(isRenew) == 3)
    #expect(client.count { $0 == .lookup } == 0)
    #expect(await connection.isConnected)
    await connection.disconnect()
  }

  @Test("A token that expired shows up as a definitive answer and ends the lease once")
  func expiredTokenEndsOnce() async throws {
    let gone = VaultClientError.http(status: 403, errors: ["permission denied", "invalid token"])
    client.renewAlwaysFails = gone
    client.lookupFails = gone
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
    }
    #expect(events.count == 1)
    let event = try #require(events.first)
    let end = try #require(await connection.lastLeaseEnd)
    #expect(end.reason == .tokenGone)
    #expect(client.count(isRenew) == 1)
    #expect(
      WorkspaceManager.connectionLostMessage(for: event, leaseEnd: end).hasPrefix(
        "Vault lease ended. Vault token expired or revoked; enter a new token."))
  }

  // MARK: - Revoke on every exit

  @Test("AppRole: disconnect revokes the lease, then the login token")
  func appRoleDisconnectRevokesToken() async throws {
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig(auth: .appRole))
    await connection.disconnect()
    #expect(
      client.calls.filter { isRevoke($0) || isRevokeSelf($0) } == [
        .revoke(id: "lease-1"), .revokeSelf(token: "approle-token"),
      ])
  }

  @Test("AppRole: a creds read failing after the login revokes the login token")
  func appRoleFailedReadRevokesToken() async throws {
    client.readFails = .http(status: 500, errors: ["internal error"])
    let connection = manager(RecordingFactory())
    await #expect(throws: VaultClientError.self) {
      try await connection.connect(config: vaultConfig(auth: .appRole))
    }
    #expect(
      client.calls == [
        .login, .read(token: "approle-token"), .revokeSelf(token: "approle-token"),
      ])
    #expect(!connection.holdsLease)
  }

  @Test("AppRole: a lease Vault no longer knows ends the session and revokes the login token")
  func appRoleLeaseGoneRevokesToken() async throws {
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig(auth: .appRole))
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
    }
    #expect(events.count == 1)
    #expect(await connection.lastLeaseEnd?.reason == .leaseGone)
    #expect(client.calls.filter(isRevokeSelf) == [.revokeSelf(token: "approle-token")])
    #expect(client.count(isRevoke) == 0)
  }

  @Test("AppRole: a login token Vault refuses is not revoked again when the lease ends")
  func appRoleTokenGoneSkipsRevoke() async throws {
    let gone = VaultClientError.http(status: 403, errors: ["permission denied", "invalid token"])
    client.renewAlwaysFails = gone
    client.lookupFails = gone
    client.login = VaultAuth(clientToken: "approle-token", duration: 0, renewable: false)
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig(auth: .appRole))
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      await clock.waitForSleeps(1)
      clock.advance(to: 60)
    }
    #expect(events.count == 1)
    #expect(await connection.lastLeaseEnd?.reason == .tokenGone)
    #expect(client.count(isRevokeSelf) == 0)
  }

  @Test("A manager dropped without a disconnect revokes its lease and login token")
  func droppedManagerRevokes() async throws {
    let factory = RecordingFactory()
    func connectAndDrop() async throws {
      let connection = manager(factory)
      try await connection.connect(config: vaultConfig(auth: .appRole))
      #expect(connection.holdsLease)
    }
    try await connectAndDrop()
    await client.waitFor(1, isRevokeSelf)
    #expect(
      client.calls.filter { isRevoke($0) || isRevokeSelf($0) } == [
        .revoke(id: "lease-1"), .revokeSelf(token: "approle-token"),
      ])
  }

  @Test("A lease that arrives once the connect was cancelled is revoked, not held")
  func cancelledConnectRevokesLease() async throws {
    client.holdsNextRead = true
    let factory = RecordingFactory()
    let connection = manager(factory)
    let config = vaultConfig()
    let connecting = Task { try await connection.connect(config: config) }
    await client.waitFor(1, isRead)
    connecting.cancel()
    client.releaseRead()
    await #expect(throws: CancellationError.self) { try await connecting.value }
    #expect(client.calls.filter(isRevoke) == [.revoke(id: "lease-1")])
    #expect(!connection.holdsLease)
    #expect(factory.configs.isEmpty)
  }

  // MARK: - Destination binding

  @Test("The destination ignores database and user, and covers every other Vault setting")
  func destinationFields() throws {
    var base = vaultConfig(saved: false)
    base.sshTunnel = SSHTunnelConfig(host: "bastion.test", username: "jump")
    let destination = try #require(VaultCredentialStore.destination(for: base))
    var sameDestination = base
    sameDestination.database = "other"
    sameDestination.username = "other-user"
    sameDestination.vault?.address = "HTTPS://Vault.Test:8200/"
    #expect(VaultCredentialStore.destination(for: sameDestination) == destination)
    let changes: [(String, (inout ConnectionConfig) -> Void)] = [
      ("address host", { $0.vault?.address = "https://evil.test:8200" }),
      ("address port", { $0.vault?.address = "https://vault.test:8201" }),
      ("address path", { $0.vault?.address = "https://vault.test:8200/proxy" }),
      ("address scheme", { $0.vault?.address = "http://vault.test:8200" }),
      ("CA", { $0.vault?.caPEM = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }),
      ("auth method", { $0.vault?.authMethod = .appRole }),
      ("mount", { $0.vault?.mount = "database2" }),
      ("role", { $0.vault?.role = "admin" }),
      ("SSH host", { $0.sshTunnel?.host = "evil-bastion.test" }),
      ("SSH port", { $0.sshTunnel?.port = 2222 }),
      ("SSH user", { $0.sshTunnel?.username = "other" }),
      ("no SSH", { $0.sshTunnel = nil }),
      ("TLS mode", { $0.sslMode = .require }),
    ]
    for (name, change) in changes {
      var changed = base
      change(&changed)
      #expect(VaultCredentialStore.destination(for: changed) != destination, "\(name)")
    }
  }

  @Test("A saved secret is not used, and nothing is sent, once the Vault settings change")
  func changedDestinationRefused() async throws {
    let saved = vaultConfig()
    let changes: [(inout ConnectionConfig) -> Void] = [
      { $0.vault?.address = "https://evil.test:8200" },
      { $0.vault?.caPEM = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" },
      { $0.vault?.mount = "database2" },
      { $0.vault?.role = "admin" },
      { $0.vault?.authMethod = .appRole },
      { $0.sshTunnel = SSHTunnelConfig(host: "evil-bastion.test", username: "jump") },
      { $0.sslMode = .require },
    ]
    for change in changes {
      var changed = saved
      change(&changed)
      // Same account: only the destination tells them apart
      #expect(
        VaultCredentialStore.account(for: changed) == VaultCredentialStore.account(for: saved))
      #expect(VaultCredentialStore.load(for: changed, from: store) == nil)
      let connection = manager(RecordingFactory())
      await #expect(throws: VaultLeaseError.destinationChanged) {
        try await connection.connect(config: changed)
      }
      #expect(await connection.isConnected == false)
    }
    #expect(client.calls.isEmpty)
    #expect(
      VaultLeaseError.destinationChanged.errorDescription?.contains("enter the Vault token") == true
    )

    let connection = manager(RecordingFactory())
    try await connection.connect(config: saved)
    #expect(client.calls.filter(isRead) == [.read(token: Self.token)])
    await connection.disconnect()
  }

  @Test("A scoped secret is used only for the destination it was entered for")
  func scopedSecretBound() {
    let config = vaultConfig(saved: false)
    var moved = config
    moved.vault?.address = "https://evil.test:8200"
    let scoped = VaultCredentialStore.scoped(.token("draft"), for: config)
    VaultCredentialStore.$operationSecret.withValue(scoped) {
      #expect(VaultCredentialStore.load(for: config, from: store) == .token("draft"))
      #expect(VaultCredentialStore.load(for: moved, from: store) == nil)
      #expect(VaultCredentialStore.lookup(for: moved, from: store) == .destinationChanged)
      #expect(VaultCredentialStore.currentSecret(for: moved) == nil)
    }
  }

  @Test("A Keychain item without a destination is never used")
  func itemWithoutDestinationRefused() {
    let legacy = Data(#"{"token":"hvs.old"}"#.utf8)
    #expect((try? JSONDecoder().decode(VaultStoredSecret.self, from: legacy)) == nil)
    let current = Data(#"{"token":"hvs.new","destination":"abc"}"#.utf8)
    #expect(
      (try? JSONDecoder().decode(VaultStoredSecret.self, from: current))
        == VaultStoredSecret(secret: .token("hvs.new"), destination: "abc"))
  }

  @Test("A side manager whose Vault settings differ from the identity's is refused")
  func sideManagerChecksDestination() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    let identity = vaultConfig()
    try await connection.connect(config: identity)
    var other = vaultConfig(database: "other", saved: false)
    other.vault?.address = "https://evil.test:8200"
    let side = manager(factory)
    await #expect(throws: VaultLeaseError.destinationChanged) {
      try await connection.connectSideManager(side, config: other, identity: identity)
    }
    #expect(client.count(isRead) == 1)
    await connection.disconnect()
  }

  // MARK: - Unremembered connections

  @Test("An unremembered Vault secret serves side managers and resets, and goes on disconnect")
  func unrememberedSecretKept() async throws {
    let factory = RecordingFactory()
    let connection = manager(factory)
    var config = vaultConfig(saved: false)
    config.rememberConnection = false
    let scoped = VaultCredentialStore.scoped(.token(Self.token), for: config)
    try await VaultCredentialStore.$operationSecret.withValue(scoped) {
      try await connection.connect(config: config)
    }
    scoped?.clear()
    let active = try #require(await connection.activeUnrememberedVaultSecret)
    #expect(active.secret == .token(Self.token))
    #expect(VaultCredentialStore.load(for: config, from: store) == nil)

    var other = config
    other.database = "other"
    let side = manager(factory)
    try await connection.connectSideManager(side, config: other, identity: config)
    #expect(await side.isConnected)
    // Both renewals sleep (the side's is cancelled by its disconnect)
    await clock.waitForSleeps(2)
    await side.disconnect()

    // The slot empties (the lease ends); a reset with the kept secret takes a new lease
    client.renewErrors = [.http(status: 400, errors: ["lease not found"])]
    let events = await lossEvents(connection, renewalOf: connection.vaultLease) {
      clock.advance(to: 60)
    }
    #expect(events.count == 1)
    #expect(!connection.holdsLease)
    try await connection.reconnectWithActiveCertificate(
      config: config, material: nil, vaultSecret: active)
    #expect(await connection.isConnected)
    #expect(client.calls.filter(isRead).count == 3)
    #expect(await connection.activeUnrememberedVaultSecret == active)

    await connection.disconnect()
    #expect(await connection.activeUnrememberedVaultSecret == nil)
    let late = manager(factory)
    await #expect(throws: VaultLeaseError.secretMissing) {
      try await connection.connectSideManager(late, config: other, identity: config)
    }
  }

  // MARK: - Quit

  @Test("The quit close set includes a lease holder without a script")
  func quitClosesLeaseHolder() async throws {
    let connection = manager(RecordingFactory())
    try await connection.connect(config: vaultConfig())
    #expect(!connection.hasPendingPostDisconnect)
    #expect(connection.closesAtQuit)
    var plain = vaultConfig()
    plain.vault = nil
    let other = manager(RecordingFactory())
    try await other.connect(config: plain)
    #expect(!other.closesAtQuit)
    await connection.disconnect()
    #expect(!connection.closesAtQuit)
    await other.disconnect()
  }
}

/// A value shared with a `@Sendable` hook
private nonisolated final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value { lock.withLock { stored } }

  func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Opened once; `wait` returns at once after that
private nonisolated final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    let ready = lock.withLock {
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    ready.forEach { $0.resume() }
  }

  func wait() async {
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      let now = lock.withLock {
        if isOpen { return true }
        waiters.append(resume)
        return false
      }
      if now { resume.resume() }
    }
  }
}
