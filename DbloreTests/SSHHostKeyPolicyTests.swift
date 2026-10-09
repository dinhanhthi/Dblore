import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing

@testable import Dblore

@Suite("SSH host-key policy (TOFU)")
struct SSHHostKeyPolicyTests {
  private static let host = "bastion.example"
  private static let port = 2200

  private static func presentedKey() -> (key: NIOSSHPublicKey, fingerprint: String) {
    let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    return (key, SSHTunnel.fingerprint(of: key)!)
  }

  private static func validate(
    _ policy: SSHHostKeyPolicy, _ presented: (key: NIOSSHPublicKey, fingerprint: String)
  ) async throws {
    try await policy.validate(
      host: host, port: port, hostKey: presented.key, fingerprint: presented.fingerprint)
  }

  @Test("A pinned key is accepted without prompting")
  func trustedNoPrompt() async throws {
    let store = InMemorySSHKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: false)
    let presented = Self.presentedKey()
    try store.trust(
      host: Self.host, port: Self.port, algorithm: "ssh-ed25519",
      fingerprint: presented.fingerprint)
    try await Self.validate(SSHHostKeyPolicy(store: store, prompt: prompt), presented)
    #expect(prompt.requests.isEmpty)
  }

  @Test("An unknown key the user confirms is pinned and accepted")
  func unknownConfirmedIsPinned() async throws {
    let store = InMemorySSHKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    let presented = Self.presentedKey()
    try await Self.validate(SSHHostKeyPolicy(store: store, prompt: prompt), presented)
    #expect(
      prompt.requests == [
        SSHHostKeyTrustRequest(
          host: Self.host, port: Self.port, algorithm: "ssh-ed25519",
          fingerprint: presented.fingerprint)
      ])
    let pinned = try #require(try store.lookup(host: Self.host, port: Self.port))
    #expect(pinned.algorithm == "ssh-ed25519")
    #expect(pinned.fingerprint == presented.fingerprint)
  }

  @Test("An unknown key the user declines is rejected and not pinned")
  func unknownDeclined() async throws {
    let store = InMemorySSHKnownHostStore()
    let presented = Self.presentedKey()
    let policy = SSHHostKeyPolicy(store: store, prompt: FakeSSHHostKeyPrompt(answer: false))
    do {
      try await Self.validate(policy, presented)
      Issue.record("A declined key must be rejected")
    } catch DatabaseError.sshHostKeyNotTrusted(let host, let fingerprint) {
      #expect(host == Self.host)
      #expect(fingerprint == presented.fingerprint)
    } catch {
      Issue.record("Expected sshHostKeyNotTrusted, got \(error)")
    }
    #expect(try store.lookup(host: Self.host, port: Self.port) == nil)
  }

  @Test("An unreadable pin fails closed: no prompt, no write")
  func unreadablePinFailsClosed() async {
    let store = UnreadableKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    do {
      try await Self.validate(SSHHostKeyPolicy(store: store, prompt: prompt), Self.presentedKey())
      Issue.record("An unreadable pin must block the connection")
    } catch DatabaseError.sshHostKeyStoreUnreadable(let host, let port) {
      #expect(host == Self.host)
      #expect(port == Self.port)
    } catch {
      Issue.record("Expected sshHostKeyStoreUnreadable, got \(error)")
    }
    #expect(prompt.requests.isEmpty)
    #expect(store.writes == 0)
    #expect(
      DatabaseError.sshHostKeyStoreUnreadable(host: Self.host, port: Self.port)
        .localizedDescription.contains("\(Self.host):\(Self.port)"))
  }

  @Test("A prompt answered after the handshake was cancelled never pins", .timeLimit(.minutes(1)))
  func cancelledPromptNeverPins() async throws {
    let store = InMemorySSHKnownHostStore()
    let prompt = PendingSSHHostKeyPrompt()
    let policy = SSHHostKeyPolicy(store: store, prompt: prompt)
    let presented = Self.presentedKey()
    let task = Task { try await Self.validate(policy, presented) }
    await prompt.waitUntilPending()
    task.cancel()
    prompt.answer(true)
    do {
      try await task.value
      Issue.record("A cancelled validation must not trust the key")
    } catch DatabaseError.sshHostKeyNotTrusted {
    } catch {
      Issue.record("Expected sshHostKeyNotTrusted, got \(error)")
    }
    #expect(try store.lookup(host: Self.host, port: Self.port) == nil)
  }

  @Test("The production prompt declines until the trust sheet exists")
  func defaultPromptDeclines() async {
    let request = SSHHostKeyTrustRequest(
      host: Self.host, port: Self.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:x")
    #expect(await RejectingSSHHostKeyPrompt().confirmUnknownHost(request) == false)
  }

  @Test("A changed key blocks without prompting and keeps the pin")
  func changedBlocks() async throws {
    let store = InMemorySSHKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    try store.trust(
      host: Self.host, port: Self.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:old")
    let presented = Self.presentedKey()
    do {
      try await Self.validate(SSHHostKeyPolicy(store: store, prompt: prompt), presented)
      Issue.record("A changed key must be blocked")
    } catch DatabaseError.sshHostKeyChanged(let host, let port, let expected, let got) {
      #expect(host == Self.host)
      #expect(port == Self.port)
      #expect(expected == "SHA256:old")
      #expect(got == presented.fingerprint)
    } catch {
      Issue.record("Expected sshHostKeyChanged, got \(error)")
    }
    #expect(prompt.requests.isEmpty)
    #expect(try store.lookup(host: Self.host, port: Self.port)?.fingerprint == "SHA256:old")
  }

  @Test("A re-key with the pinned key does not prompt again")
  func rekeyDoesNotRePrompt() async throws {
    let store = InMemorySSHKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    let policy = SSHHostKeyPolicy(store: store, prompt: prompt)
    let presented = Self.presentedKey()
    try await Self.validate(policy, presented)
    try await Self.validate(policy, presented)
    #expect(prompt.requests.count == 1)
  }

  @Test("Tunnel errors map to readable connection errors at the session boundary")
  func tunnelErrorMapping() {
    func mapped(_ error: SSHTunnelError) -> DatabaseError? {
      error.databaseError(host: "bastion.example", port: 2223)
    }
    guard case .sshAuthenticationFailed = mapped(.authenticationFailed) else {
      Issue.record("authenticationFailed")
      return
    }
    guard case .sshHandshakeTimedOut = mapped(.handshakeTimedOut) else {
      Issue.record("handshakeTimedOut")
      return
    }
    guard
      case .sshUnsupportedHostKeyAlgorithm(let host, let port) = mapped(
        .unsupportedHostKeyAlgorithm)
    else {
      Issue.record("unsupportedHostKeyAlgorithm")
      return
    }
    #expect(host == "bastion.example")
    #expect(port == 2223)
    for passthrough: SSHTunnelError in [
      .hostKeyRejected, .channelOpenRejected, .closedBeforeReady, .invalidChannelData,
      .hostKeyFingerprintUnavailable,
    ] {
      #expect(mapped(passthrough) == nil, "\(passthrough)")
    }
  }

  @Test("SSH error messages explain the problem and the fix")
  func messages() {
    let changed = DatabaseError.sshHostKeyChanged(
      host: "bastion.example", port: 2200, expected: "SHA256:old", presented: "SHA256:new")
    #expect(
      changed.localizedDescription
        == "The SSH host key for bastion.example:2200 changed. Expected SHA256:old, got "
        + "SHA256:new. This can mean a man-in-the-middle attack. If the server key was "
        + "legitimately replaced, remove the pin in Settings > Data and connect again.")
    let notTrusted = DatabaseError.sshHostKeyNotTrusted(
      host: "bastion.example", fingerprint: "SHA256:abc")
    #expect(notTrusted.localizedDescription.contains("bastion.example"))
    #expect(notTrusted.localizedDescription.contains("SHA256:abc"))
    let rsa = DatabaseError.sshUnsupportedHostKeyAlgorithm(host: "bastion.example", port: 2223)
    #expect(rsa.localizedDescription.contains("bastion.example:2223"))
    #expect(
      rsa.localizedDescription.contains(
        "uses an RSA host key, which is not supported; enable an ed25519 or ECDSA host key"))
    #expect(DatabaseError.sshAuthenticationFailed.localizedDescription.contains("SSH"))
    #expect(DatabaseError.sshHandshakeTimedOut.localizedDescription.contains("SSH"))
  }

  @Test("A session reports SSH auth failure as a readable error without secrets")
  func sessionMapsAuthFailureWithoutSecrets() async {
    let config = ConnectionConfig(
      host: "db-policy.internal", port: 5432, database: "app", username: "ada",
      password: "db-secret-pw", sslMode: .disable,
      sshTunnel: SSHTunnelConfig(host: "bastion-policy.example", port: 2200, username: "jump"),
      timeoutSeconds: 2)
    let account = SSHCredentialStoreFactory.account(for: config)!
    SSHCredentialStoreFactory.shared.save(.password("jump-secret-pw"), account: account)
    defer { SSHCredentialStoreFactory.shared.delete(account: account) }
    for isProbe in [false, true] {
      let session = PostgresSession(
        config: config,
        tunnelFactory: FailingSSHTunnelFactory(error: SSHTunnelError.authenticationFailed),
        hostKeyValidator: SSHHostKeyPolicy(
          store: InMemorySSHKnownHostStore(), prompt: FakeSSHHostKeyPrompt(answer: false)))
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("Auth failure must throw")
      } catch DatabaseError.sshAuthenticationFailed {
      } catch {
        Issue.record("Expected sshAuthenticationFailed, got \(error)")
      }
    }
    let texts = [
      DatabaseError.sshAuthenticationFailed, .sshHandshakeTimedOut,
      .sshUnsupportedHostKeyAlgorithm(host: "bastion-policy.example", port: 2200),
      .sshHostKeyNotTrusted(host: "bastion-policy.example", fingerprint: "SHA256:a"),
      .sshHostKeyChanged(
        host: "bastion-policy.example", port: 2200, expected: "SHA256:a", presented: "SHA256:b"),
    ].map(\.localizedDescription)
    for text in texts {
      #expect(!text.contains("jump-secret-pw"))
      #expect(!text.contains("db-secret-pw"))
    }
  }
}

// MARK: - Doubles

final class FakeSSHHostKeyPrompt: SSHHostKeyPrompt, @unchecked Sendable {
  private let lock = NSLock()
  private let answer: Bool
  private var recorded: [SSHHostKeyTrustRequest] = []

  init(answer: Bool) {
    self.answer = answer
  }

  var requests: [SSHHostKeyTrustRequest] { lock.withLock { recorded } }

  func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool {
    lock.withLock { recorded.append(request) }
    return answer
  }
}

/// A pin that exists but cannot be read (Keychain error or corrupt JSON). Counts writes.
private final class UnreadableKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  private let lock = NSLock()
  private var writeCount = 0

  var writes: Int { lock.withLock { writeCount } }

  func load(account: String) throws -> SSHKnownHost? { throw SSHKnownHostStoreError.undecodable }

  func add(_ host: SSHKnownHost, account: String) -> Bool {
    lock.withLock { writeCount += 1 }
    return true
  }

  func save(_ host: SSHKnownHost, account: String) -> Bool {
    lock.withLock { writeCount += 1 }
    return true
  }

  func delete(account: String) { lock.withLock { writeCount += 1 } }
}

/// Holds the user's answer until the test calls `answer(_:)`.
private final class PendingSSHHostKeyPrompt: SSHHostKeyPrompt, @unchecked Sendable {
  private let lock = NSLock()
  private var reply: CheckedContinuation<Bool, Never>?
  private var pendingWaiter: CheckedContinuation<Void, Never>?

  func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool {
    await withCheckedContinuation { continuation in
      let waiter = lock.withLock {
        reply = continuation
        defer { pendingWaiter = nil }
        return pendingWaiter
      }
      waiter?.resume()
    }
  }

  func waitUntilPending() async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        if reply != nil { return true }
        pendingWaiter = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func answer(_ value: Bool) {
    let continuation = lock.withLock {
      defer { reply = nil }
      return reply
    }
    continuation?.resume(returning: value)
  }
}

private struct FailingSSHTunnelFactory: SSHTunnelFactory {
  let error: SSHTunnelError

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    throw error
  }
}
