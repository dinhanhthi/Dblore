import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import PostgresNIO
import Testing

@testable import Dblore

// MARK: - Unit (fake tunnel factory, no server)

@Suite("PostgresSession SSH tunnel seam")
struct PostgresSSHTunnelSeamTests {
  /// A distinct identity per test, so parallel tests never share a stored SSH credential.
  private static func config(_ name: String, timeoutSeconds: Int = 2) -> ConnectionConfig {
    ConnectionConfig(
      host: "db-\(name).internal", port: 5432, database: "app", username: "ada",
      password: "secret", sslMode: .disable,
      sshTunnel: SSHTunnelConfig(host: "bastion-\(name).example", port: 2200, username: "jump"),
      timeoutSeconds: timeoutSeconds)
  }

  private static func save(_ credential: SSHStoredCredential, for config: ConnectionConfig) {
    let account = SSHCredentialStoreFactory.account(for: config)!
    SSHCredentialStoreFactory.shared.save(credential, account: account)
  }

  /// `ParsedSSHKey.keychainRepresentation` of an ed25519 seed: string(alg) || string(seed).
  private static func ed25519KeychainRepresentation() -> Data {
    func sshString(_ bytes: [UInt8]) -> [UInt8] {
      let count = UInt32(bytes.count)
      return [
        UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff),
        UInt8(count & 0xff),
      ] + bytes
    }
    let seed = [UInt8](repeating: 7, count: 32)
    return Data(sshString(Array("ssh-ed25519".utf8)) + sshString(seed))
  }

  @Test("open and probe fail with a typed error when the SSH credential is missing")
  func missingCredential() async {
    let config = Self.config("missing")
    for isProbe in [false, true] {
      let factory = FakeSSHTunnelFactory()
      let session = PostgresSession(
        config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A tunnel without a stored credential must fail")
      } catch DatabaseError.sshCredentialMissing {
      } catch {
        Issue.record("Expected sshCredentialMissing, got \(error)")
      }
      #expect(factory.connectCount == 0)
    }
  }

  @Test("A connection without SSH never calls the tunnel factory")
  func nonSSHConfigSkipsFactory() async {
    let config = ConnectionConfig(
      host: "127.0.0.1", port: 1, database: "app", username: "ada", sslMode: .disable,
      timeoutSeconds: 1)
    let factory = FakeSSHTunnelFactory()
    let session = PostgresSession(
      config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
    _ = try? await session.probe()
    #expect(factory.connectCount == 0)
  }

  @Test("The factory gets the bastion endpoint, the password and the session timeout")
  func factoryReceivesBastion() async {
    let config = Self.config("endpoint", timeoutSeconds: 3)
    Self.save(.password("jump-pass"), for: config)
    let factory = FakeSSHTunnelFactory(connectError: SSHTunnelError.authenticationFailed)
    let session = PostgresSession(
      config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
    do {
      try await session.open()
      Issue.record("A failed SSH login must fail open")
    } catch DatabaseError.sshAuthenticationFailed {
    } catch {
      Issue.record("Expected sshAuthenticationFailed, got \(error)")
    }
    let request = factory.requests.first
    #expect(request?.host == "bastion-endpoint.example")
    #expect(request?.port == 2200)
    #expect(request?.username == "jump")
    #expect(request?.password == "jump-pass")
    #expect(request?.connectTimeout == .seconds(3))
    #expect(request?.handshakeTimeout == .seconds(3))
  }

  @Test("A stored private key is restored for authentication")
  func privateKeyRestored() async {
    let config = Self.config("key")
    Self.save(
      .privateKey(keychainRepresentation: Self.ed25519KeychainRepresentation()), for: config)
    let factory = FakeSSHTunnelFactory(connectError: SSHTunnelError.authenticationFailed)
    let session = PostgresSession(
      config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
    _ = try? await session.probe()
    #expect(factory.requests.first?.usedPrivateKey == true)
  }

  @Test("open and probe use the scoped credential before the store, only for its account")
  func scopedCredentialBeforeStore() async throws {
    let config = Self.config("scoped")
    Self.save(.password("stored"), for: config)
    let account = try #require(SSHCredentialStoreFactory.account(for: config))
    for isProbe in [false, true] {
      for (scopedAccount, expected) in [(account, "scoped"), ("v2|other", "stored")] {
        let factory = FakeSSHTunnelFactory(connectError: SSHTunnelError.authenticationFailed)
        let session = PostgresSession(
          config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
        let scoped = SSHCredentialStoreFactory.ScopedSSHCredential(
          account: scopedAccount, credential: .password("scoped"))
        await SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
          if isProbe { _ = try? await session.probe() } else { try? await session.open() }
        }
        #expect(factory.requests.first?.password == expected)
      }
    }
  }

  @Test("A failure after the tunnel exists closes the tunnel (open and probe)")
  func channelOpenFailureClosesTunnel() async {
    let config = Self.config("channel")
    Self.save(.password("jump-pass"), for: config)
    for isProbe in [false, true] {
      let factory = FakeSSHTunnelFactory(openError: SSHTunnelError.channelOpenRejected)
      let session = PostgresSession(
        config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A rejected channel must fail")
      } catch {
        #expect(error as? SSHTunnelError == .channelOpenRejected, "\(error)")
      }
      #expect(factory.tunnels.count == 1)
      #expect(factory.tunnels.allSatisfy { $0.isClosed })
      #expect(factory.tunnels.first?.openRequests.count == 1)
      #expect(factory.tunnels.first?.openRequests.first?.host == "db-channel.internal")
      #expect(factory.tunnels.first?.openRequests.first?.port == 5432)
    }
  }

  @Test(
    "Tunneled TLS uses the direct path's mode, context and DB-host name for every SSL mode",
    arguments: ["db.internal", "10.0.0.5", "fd00::5"])
  func tunneledTLSMatchesDirect(host: String) throws {
    let modes: [SSLMode] = [.disable, .allow, .prefer, .require, .verifyCa, .verifyFull]
    for mode in modes {
      let config = ConnectionConfig(
        host: host, port: 5432, database: "app", username: "ada", sslMode: mode,
        sshTunnel: SSHTunnelConfig(host: "bastion.example", username: "jump"))
      let tls = try PostgresSession.configureTLS(sslMode: mode, material: nil)
      let direct = PostgresSession.postgresConfiguration(config, tls: tls)
      let tunneled = PostgresSession.tunneledConfiguration(
        channel: EmbeddedChannel(), config: config, tls: tls)
      #expect(tunneled.tls.isAllowed == direct.tls.isAllowed, "\(mode)")
      #expect(tunneled.tls.isEnforced == direct.tls.isEnforced, "\(mode)")
      #expect(tunneled.tls.sslContext === direct.tls.sslContext, "\(mode)")
      // PostgresNIO derives a direct connection's TLS name from the host unless it is an IP
      // literal (not valid in SNI); the tunnel sets the same name explicitly.
      let isIP = host != "db.internal"
      #expect(tunneled.options.tlsServerName == (isIP ? nil : host), "\(mode)")
      #expect(tunneled.options.tlsServerName != "bastion.example")
    }
  }

  @Test("The default host-key validator rejects every key until trust is wired")
  func defaultValidatorRejects() async {
    let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    await #expect(throws: SSHTunnelError.hostKeyRejected) {
      try await RejectUnknownSSHHostKeys().validate(
        host: "bastion.example", port: 22, hostKey: key, fingerprint: "SHA256:x")
    }
  }
}

// MARK: - Live (docker/postgresql/docker-compose.ssh.yml)

@Suite("PostgresSession SSH tunnel lifecycle", .requiresSSHPostgres, .serialized)
@MainActor
struct PostgresSSHTunnelLifecycleTests {
  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/postgresql/data/ssh", isDirectory: true)

  private static func config(
    password: String = "dblore123", sslMode: SSLMode = .disable
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: "postgres", port: 5432, database: "dblore_ssh", username: "dblore_ssh",
      password: password, sslMode: sslMode,
      sshTunnel: SSHTunnelConfig(host: "127.0.0.1", port: 2222, username: "dblore"),
      timeoutSeconds: 15, safeMode: .silent)
  }

  private static func saveCredential(for config: ConnectionConfig) {
    let account = SSHCredentialStoreFactory.account(for: config)!
    SSHCredentialStoreFactory.shared.save(.password("dblore-ssh-123"), account: account)
  }

  private static func session(
    _ config: ConnectionConfig, spy: SpySSHTunnelFactory
  ) -> PostgresSession {
    saveCredential(for: config)
    return PostgresSession(
      config: config, tunnelFactory: spy, hostKeyValidator: AcceptAnySSHHostKey())
  }

  private static func selectOne(_ session: PostgresSession) async throws -> CellValue? {
    let rows = try await session.readQuery(
      "SELECT 1::int4 AS one", binds: [], maxRows: 10, readToEnd: false)
    return rows.rows.first?.first
  }

  @Test("open runs SELECT 1 through the tunnel and close tears it down", .timeLimit(.minutes(1)))
  func openWithoutTLS() async throws {
    let spy = SpySSHTunnelFactory()
    let session = Self.session(Self.config(), spy: spy)
    try await session.open()
    #expect(try await Self.selectOne(session) == .int(1))
    #expect(spy.tunnels.count == 1)
    #expect(spy.tunnels.allSatisfy { !$0.isClosed })
    await session.close()
    #expect(spy.tunnels.allSatisfy { $0.isClosed && !$0.parentChannel.isActive })
  }

  @Test(
    "verify-full TLS over the tunnel checks the DB host name, not the bastion",
    .timeLimit(.minutes(1)))
  func openWithVerifiedTLS() async throws {
    let serverCertificate = try String(
      contentsOf: Self.fixtures.appendingPathComponent("postgres/server.crt"), encoding: .utf8)
    var config = Self.config(sslMode: .verifyFull)
    config.clientCertificate = ClientCertificateInfo(
      subject: "CN=client.test", expiry: nil, hasCA: true)
    ClientCertificateStoreFactory.shared.save(
      ClientCertificateMaterial(
        certificatePEM: TLSFixture.certificate, privateKeyPEM: TLSFixture.privateKey,
        caPEM: serverCertificate),
      account: ClientCertificateStoreFactory.account(for: config))
    defer { ClientCertificateStoreFactory.delete(for: config) }

    let spy = SpySSHTunnelFactory()
    let session = Self.session(config, spy: spy)
    try await session.open()
    let ssl = try await session.readQuery(
      "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", binds: [], maxRows: 1,
      readToEnd: false)
    #expect(ssl.rows.first?.first == .bool(true))
    await session.close()
    #expect(spy.tunnels.allSatisfy { $0.isClosed })
  }

  @Test("close closes the PostgreSQL connection before the tunnel", .timeLimit(.minutes(1)))
  func closeOrder() async throws {
    let spy = SpySSHTunnelFactory()
    let session = Self.session(Self.config(), spy: spy)
    try await session.open()
    let connection = try #require(session.connection)
    let tunnel = try #require(spy.tunnels.first)
    tunnel.onClose = { connection.isClosed }
    await session.close()
    #expect(tunnel.connectionClosedFirst == true)
    #expect(tunnel.isClosed)
  }

  @Test(
    "A failure after the tunnel exists (wrong DB password) closes every tunnel",
    .timeLimit(.minutes(1)))
  func wrongPasswordClosesTunnel() async {
    for isProbe in [false, true] {
      let spy = SpySSHTunnelFactory()
      let session = Self.session(Self.config(password: "wrong"), spy: spy)
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A wrong database password must fail")
      } catch DatabaseError.connectionFailed {
      } catch {
        Issue.record("Expected connectionFailed, got \(error)")
      }
      #expect(!spy.tunnels.isEmpty)
      #expect(spy.tunnels.allSatisfy { $0.isClosed && !$0.parentChannel.isActive })
    }
  }

  @Test("probe tears the tunnel down after SELECT 1", .timeLimit(.minutes(1)))
  func probeTearsDownTunnel() async throws {
    let spy = SpySSHTunnelFactory()
    let session = Self.session(Self.config(), spy: spy)
    #expect(try await session.probe())
    #expect(spy.tunnels.count == 1)
    #expect(spy.tunnels.allSatisfy { $0.isClosed && !$0.parentChannel.isActive })
  }

  @Test("The tunnel dropping emits connectionLost", .timeLimit(.minutes(1)))
  func tunnelDropEmitsConnectionLost() async throws {
    let spy = SpySSHTunnelFactory()
    let session = Self.session(Self.config(), spy: spy)
    try await session.open()
    let tunnel = try #require(spy.tunnels.first)
    let reason = ReasonBox()
    let events = session.closeEvents
    try await tunnel.parentChannel.close()
    let outcome = await bounded(.seconds(5)) {
      for await event in events {
        reason.set(event)
        return
      }
    }
    guard case .returned = outcome else {
      Issue.record("connectionLost was not emitted: \(outcome)")
      return
    }
    #expect(reason.value == .connectionLost)
    await session.close()
    #expect(tunnel.isClosed)
  }

  @Test("detach hands the tunnel over and closeForgotten closes it", .timeLimit(.minutes(1)))
  func detachAndCloseForgotten() async throws {
    for includingConnection in [true, false] {
      let spy = SpySSHTunnelFactory()
      let session = Self.session(Self.config(), spy: spy)
      try await session.open()
      let detached = session.detach()
      #expect(detached.connection != nil)
      #expect(detached.tunnel != nil)
      #expect(session.connection == nil)
      #expect(spy.tunnels.allSatisfy { !$0.isClosed })
      await DatabaseConnectionManager.closeForgotten(
        ForgottenSession(
          session: session, connection: detached.connection, group: detached.group,
          tunnel: detached.tunnel),
        includingConnection: includingConnection)
      #expect(spy.tunnels.allSatisfy { $0.isClosed && !$0.parentChannel.isActive })
    }
  }

  @Test(
    "A capped-read reset leaves only the new session's SSH channel open", .timeLimit(.minutes(1)))
  func cappedReadResetClosesOldTunnel() async throws {
    let spy = SpySSHTunnelFactory()
    let config = Self.config()
    Self.saveCredential(for: config)
    let manager = DatabaseConnectionManager(
      sessionFactory: SpyPostgresSessionFactory(tunnelFactory: spy))
    try await manager.connect(config: config)
    let table = "ssh_capped_reset"
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await manager.executeInternal(
      "CREATE TABLE \(table) AS SELECT g AS id FROM generate_series(1, 500) g")
    #expect(spy.tunnels.count == 1)

    let read = try await manager.execute(
      userSQL: "SELECT * FROM \(table)", policy: ProtectionPolicy(protectionLevel: .none),
      maxRows: 10)
    #expect(read.sessionReset)
    #expect(spy.tunnels.count == 2)
    #expect(spy.tunnels.first.map { $0.isClosed && !$0.parentChannel.isActive } == true)
    #expect(spy.tunnels.last.map { !$0.isClosed } == true)

    _ = try await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
    await manager.disconnect()
    #expect(spy.tunnels.allSatisfy { $0.isClosed && !$0.parentChannel.isActive })
  }

  @Test("The default validator rejects the unknown bastion", .timeLimit(.minutes(1)))
  func unknownHostRejectedByDefault() async {
    let config = Self.config()
    Self.saveCredential(for: config)
    await #expect(throws: SSHTunnelError.hostKeyRejected) {
      try await PostgresSession(config: config).open()
    }
  }

  // MARK: Host-key policy through DatabaseConnectionManager

  private static let bastionFingerprint: String = {
    let url = fixtures.appendingPathComponent("host_fingerprint.txt")
    return (try? String(contentsOf: url, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }()

  private static func expectConnectFails(
    _ manager: DatabaseConnectionManager, _ config: ConnectionConfig,
    matching: (any Error) -> Bool
  ) async {
    do {
      try await manager.connect(config: config)
      Issue.record("The connection must fail")
      await manager.disconnect()
    } catch {
      #expect(matching(error), "\(error)")
    }
  }

  @Test(
    "A confirmed unknown bastion is pinned, then trusted without a prompt",
    .timeLimit(.minutes(1)))
  func confirmedHostIsPinned() async throws {
    let store = SSHKnownHostStoreFactory.shared
    store.remove(host: "127.0.0.1", port: 2222)
    defer { store.remove(host: "127.0.0.1", port: 2222) }
    let config = Self.config()
    Self.saveCredential(for: config)
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    let manager = DatabaseConnectionManager(sshHostKeyPrompt: prompt)

    try await manager.connect(config: config)
    #expect(prompt.requests.count == 1)
    #expect(prompt.requests.first?.fingerprint == Self.bastionFingerprint)
    #expect(prompt.requests.first?.algorithm == "ssh-ed25519")
    #expect(
      try store.lookup(host: "127.0.0.1", port: 2222)?.fingerprint == Self.bastionFingerprint)
    await manager.disconnect()

    try await manager.connect(config: config)
    #expect(try await manager.testConnection(config: config))
    #expect(prompt.requests.count == 1)
    await manager.disconnect()
  }

  @Test("The production prompt rejects an unknown bastion", .timeLimit(.minutes(1)))
  func productionPromptRejects() async throws {
    let store = SSHKnownHostStoreFactory.shared
    store.remove(host: "127.0.0.1", port: 2222)
    let config = Self.config()
    Self.saveCredential(for: config)
    await Self.expectConnectFails(DatabaseConnectionManager(), config) {
      guard case DatabaseError.sshHostKeyNotTrusted(_, let fingerprint) = $0 else { return false }
      return fingerprint == Self.bastionFingerprint
    }
    #expect(try store.lookup(host: "127.0.0.1", port: 2222) == nil)
  }

  @Test("A changed bastion key blocks connect and test", .timeLimit(.minutes(1)))
  func changedHostKeyBlocks() async throws {
    let store = SSHKnownHostStoreFactory.shared
    store.replacePin(
      host: "127.0.0.1", port: 2222, algorithm: "ssh-ed25519", fingerprint: "SHA256:wrong")
    defer { store.remove(host: "127.0.0.1", port: 2222) }
    let config = Self.config()
    Self.saveCredential(for: config)
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    let manager = DatabaseConnectionManager(sshHostKeyPrompt: prompt)
    let isChanged: (any Error) -> Bool = {
      guard case DatabaseError.sshHostKeyChanged(_, 2222, "SHA256:wrong", let presented) = $0
      else { return false }
      return presented == Self.bastionFingerprint
    }
    await Self.expectConnectFails(manager, config, matching: isChanged)
    do {
      _ = try await manager.testConnection(config: config)
      Issue.record("testConnection must fail on a changed key")
    } catch {
      #expect(isChanged(error), "\(error)")
    }
    #expect(prompt.requests.isEmpty)
    #expect(try store.lookup(host: "127.0.0.1", port: 2222)?.fingerprint == "SHA256:wrong")
  }

  @Test("An RSA-only bastion fails with a clear error", .timeLimit(.minutes(1)))
  func rsaOnlyHost() async {
    var config = Self.config()
    config.sshTunnel = SSHTunnelConfig(host: "127.0.0.1", port: 2223, username: "dblore")
    Self.saveCredential(for: config)
    let manager = DatabaseConnectionManager(sshHostKeyPrompt: FakeSSHHostKeyPrompt(answer: true))
    await Self.expectConnectFails(manager, config) {
      guard case DatabaseError.sshUnsupportedHostKeyAlgorithm("127.0.0.1", 2223) = $0 else {
        return false
      }
      return true
    }
  }
}

// MARK: - Doubles

private final class FakeSSHTunnel: SSHTunneling, @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var opens: [(host: String, port: Int)] = []
  private let openError: (any Error)?

  init(openError: (any Error)?) {
    self.openError = openError
  }

  var isClosed: Bool { lock.withLock { closed } }
  var openRequests: [(host: String, port: Int)] { lock.withLock { opens } }

  func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> any Channel {
    lock.withLock { opens.append((targetHost, targetPort)) }
    throw openError ?? SSHTunnelError.closedBeforeReady
  }

  func close() async {
    lock.withLock { closed = true }
  }
}

private final class FakeSSHTunnelFactory: SSHTunnelFactory, @unchecked Sendable {
  struct Request {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var usedPrivateKey: Bool
    var connectTimeout: TimeAmount
    var handshakeTimeout: TimeAmount
  }

  private let lock = NSLock()
  private var recorded: [Request] = []
  private var made: [FakeSSHTunnel] = []
  private let connectError: (any Error)?
  private let openError: (any Error)?

  init(connectError: (any Error)? = nil, openError: (any Error)? = nil) {
    self.connectError = connectError
    self.openError = openError
  }

  var connectCount: Int { lock.withLock { recorded.count } }
  var requests: [Request] { lock.withLock { recorded } }
  var tunnels: [FakeSSHTunnel] { lock.withLock { made } }

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    var password: String?
    var usedPrivateKey = false
    switch authentication {
    case .password(let value): password = value
    case .privateKey: usedPrivateKey = true
    }
    lock.withLock {
      recorded.append(
        Request(
          host: host, port: port, username: username, password: password,
          usedPrivateKey: usedPrivateKey, connectTimeout: connectTimeout,
          handshakeTimeout: handshakeTimeout))
    }
    if let connectError { throw connectError }
    let tunnel = FakeSSHTunnel(openError: openError)
    lock.withLock { made.append(tunnel) }
    return tunnel
  }
}

private final class ReasonBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: SessionCloseReason?
  var value: SessionCloseReason? { lock.withLock { stored } }
  func set(_ value: SessionCloseReason) { lock.withLock { stored = value } }
}

/// A throwaway client certificate. The SSH stack's server does not request one; it only has to
/// load so `caPEM` can carry the server's self-signed certificate as the trust root.
private enum TLSFixture {
  static let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIBgjCCASegAwIBAgIUAklrIK0F2veiAbCErW8IIR+ZS1QwCgYIKoZIzj0EAwIw
    FjEUMBIGA1UEAwwLY2xpZW50LnRlc3QwHhcNMjYxMDA0MTQwNjMwWhcNMjYxMDA1
    MTQwNjMwWjAWMRQwEgYDVQQDDAtjbGllbnQudGVzdDBZMBMGByqGSM49AgEGCCqG
    SM49AwEHA0IABIIXWTq/3uC4Z3xskTXVizF9urCEWVXVp8tyxOvVEQiC+BcTimWD
    c8mszL2Fz/12ngJixTobVvZdJlt80Bs/l2WjUzBRMB0GA1UdDgQWBBQtGYAEI4GY
    0EbttySa29pM7EVk8DAfBgNVHSMEGDAWgBQtGYAEI4GY0EbttySa29pM7EVk8DAP
    BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQC0XrIbvKvzTcQAgu0y
    IAWvaCI96Cay7ETrVmdVfTE0VwIhALNoktIitpdCRKM+LeLBg7GV3/xGeNM81Vbi
    Awghat2J
    -----END CERTIFICATE-----
    """

  static let privateKey = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgYFtkXJAH5hZJCwd4
    2df3AfXwthSsYdaA+8sdieUnwcahRANCAASCF1k6v97guGd8bJE11YsxfbqwhFlV
    1afLcsTr1REIgvgXE4plg3PJrMy9hc/9dp4CYsU6G1b2XSZbfNAbP5dl
    -----END PRIVATE KEY-----
    """
}
