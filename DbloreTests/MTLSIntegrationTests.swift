import Foundation
import Logging
import NIOPosix
import NIOSSL
import PostgresNIO
import Testing

@testable import Dblore

@MainActor
@Suite("PostgreSQL mTLS integration", .requiresMTLSPostgres, .serialized)
struct MTLSIntegrationTests {
  private static let certificates = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/postgresql/data/mtls", isDirectory: true)

  private static var config: ConnectionConfig {
    let env = ProcessInfo.processInfo.environment
    let port =
      Int(env["MTLS_POSTGRES_PORT"] ?? env["TEST_RUNNER_MTLS_POSTGRES_PORT"] ?? "5436") ?? 5436
    return ConnectionConfig(
      host: "localhost", port: port, database: "dblore_mtls", username: "dblore_mtls",
      password: "dblore123", sslMode: .verifyFull, timeoutSeconds: 5)
  }

  private static func ephemeralConfig() -> ConnectionConfig {
    var config = Self.config
    config.rememberConnection = false
    config.protectedMode = false
    config.clientCertificate = ClientCertificateInfo(
      subject: "CN=dblore_mtls", expiry: nil, hasCA: true)
    return config
  }

  private static func validMaterial() throws -> ClientCertificateMaterial {
    ClientCertificateMaterial(
      certificatePEM: try String(
        contentsOf: certificates.appendingPathComponent("client.crt"), encoding: .utf8),
      privateKeyPEM: try String(
        contentsOf: certificates.appendingPathComponent("client.key"), encoding: .utf8),
      caPEM: try String(
        contentsOf: certificates.appendingPathComponent("ca.crt"), encoding: .utf8))
  }

  private static func invalidSavedMaterial(for config: ConnectionConfig) -> String {
    let account = ClientCertificateStoreFactory.account(for: config)
    _ = ClientCertificateStoreFactory.shared.save(
      ClientCertificateMaterial(certificatePEM: "stale", privateKeyPEM: "stale"), account: account)
    return account
  }

  @Test("Client certificate connects and runs a query")
  func clientCertificateConnects() async throws {
    var config = Self.config
    let root = Self.certificates
    let material = ClientCertificateMaterial(
      certificatePEM: try String(
        contentsOf: root.appendingPathComponent("client.crt"), encoding: .utf8),
      privateKeyPEM: try String(
        contentsOf: root.appendingPathComponent("client.key"), encoding: .utf8),
      caPEM: try String(contentsOf: root.appendingPathComponent("ca.crt"), encoding: .utf8))
    let account = ClientCertificateStoreFactory.account(for: config)
    let store = ClientCertificateStoreFactory.shared
    #expect(store.save(material, account: account))
    defer { store.delete(account: account) }
    config.clientCertificate = ClientCertificateInfo(
      subject: "CN=dblore_mtls", expiry: nil, hasCA: true)

    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: config)
      #expect(await manager.isConnected)
      let result = try await manager.executeInternal("SELECT 1 AS value")
      #expect(result.rows.count == 1)
      await manager.disconnect()
    } catch {
      await manager.disconnect()
      throw error
    }
  }

  @Test("Test Connection uses scoped material without saving it")
  func scopedProbeDoesNotPersist() async throws {
    var config = Self.config
    let material = ClientCertificateMaterial(
      certificatePEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("client.crt"), encoding: .utf8),
      privateKeyPEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("client.key"), encoding: .utf8),
      caPEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("ca.crt"), encoding: .utf8))
    config.clientCertificate = ClientCertificateInfo(
      subject: "CN=dblore_mtls", expiry: nil, hasCA: true)
    let account = ClientCertificateStoreFactory.account(for: config)
    let store = ClientCertificateStoreFactory.shared
    store.delete(account: account)
    let manager = DatabaseConnectionManager()

    let connected = try await ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      try await manager.testConnection(config: config)
    }
    #expect(connected)
    #expect(store.load(account: account) == nil)
  }

  @Test("An unremembered connection uses scoped material and leaves no saved certificate")
  func scopedConnectDoesNotPersist() async throws {
    var config = Self.config
    config.rememberConnection = false
    config.clientCertificate = ClientCertificateInfo(
      subject: "CN=dblore_mtls", expiry: nil, hasCA: true)
    let material = ClientCertificateMaterial(
      certificatePEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("client.crt"), encoding: .utf8),
      privateKeyPEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("client.key"), encoding: .utf8),
      caPEM: try String(
        contentsOf: Self.certificates.appendingPathComponent("ca.crt"), encoding: .utf8))
    let account = ClientCertificateStoreFactory.account(for: config)
    let store = ClientCertificateStoreFactory.shared
    store.delete(account: account)
    let manager = DatabaseConnectionManager()

    try await ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      try await manager.connect(config: config)
      #expect(await manager.isConnected)
    }
    #expect(store.load(account: account) == nil)
    await manager.disconnect()
    #expect(await manager.activeUnrememberedCertificate == nil)
  }

  @Test("Capped read resets with the active ephemeral certificate")
  func ephemeralCappedReadReset() async throws {
    let config = Self.ephemeralConfig()
    let account = Self.invalidSavedMaterial(for: config)
    defer { ClientCertificateStoreFactory.shared.delete(account: account) }
    let manager = DatabaseConnectionManager()
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: account, material: try Self.validMaterial())
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await manager.connect(config: config)
    }
    scoped.clear()
    defer { Task { await manager.disconnect() } }

    let read = try await manager.execute(
      userSQL: "SELECT oid FROM pg_class", policy: ProtectionPolicy(protectionLevel: .none),
      maxRows: 1)
    #expect(read.truncated)
    #expect(read.sessionReset)
    #expect(await manager.isConnected)
    #expect(try await manager.executeInternal("SELECT 1").rows.count == 1)
  }

  @Test("Cancel reconnects with the active ephemeral certificate")
  func ephemeralCancelReset() async throws {
    let config = Self.ephemeralConfig()
    let account = Self.invalidSavedMaterial(for: config)
    defer { ClientCertificateStoreFactory.shared.delete(account: account) }
    let manager = DatabaseConnectionManager()
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: account, material: try Self.validMaterial())
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await manager.connect(config: config)
    }
    scoped.clear()
    defer { Task { await manager.disconnect() } }

    let running = Task {
      try? await manager.execute(
        userSQL: "SELECT pg_sleep(30)", policy: ProtectionPolicy(protectionLevel: .none))
    }
    for _ in 0..<100 {
      if await manager.runningStatementStatus().inFlight { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let status = await manager.runningStatementStatus()
    #expect(status.inFlight)
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    _ = await running.value
    #expect(await manager.isConnected)
    #expect(try await manager.executeInternal("SELECT 1").rows.count == 1)
  }

  @Test("Banner Reconnect keeps an ephemeral certificate after session loss")
  func ephemeralBannerReconnect() async throws {
    let config = Self.ephemeralConfig()
    let account = Self.invalidSavedMaterial(for: config)
    defer { ClientCertificateStoreFactory.shared.delete(account: account) }
    let manager = WorkspaceManager(
      workspace: Workspace.newUntitled(connection: nil), restoreTabs: false)
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: account, material: try Self.validMaterial())
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await manager.connect(config: config, defaultCommitStyle: .immediate)
    }
    scoped.clear()
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionManager.connectionEpoch
    await manager.connectionManager.disconnect()
    await manager.connectionWasLost(
      SessionLostEvent(state: .idle, userTxOpen: false, epoch: epoch))

    await manager.reconnectAfterConnectionLoss()
    #expect(await manager.connectionManager.isConnected)
    #expect(try await manager.connectionManager.executeInternal("SELECT 1").rows.count == 1)
    await manager.disconnect()
    #expect(manager.activeUnrememberedCertificate == nil)
    #expect(await manager.connectionManager.activeUnrememberedCertificate == nil)
  }

  @Test("App cannot connect without client material")
  func appWithoutClientCertificateFails() async {
    let config = Self.config
    do {
      _ = try await PostgresSession(config: config).probe()
      Issue.record("App connected without a client certificate")
    } catch {
      // The app also has no custom CA in this configuration. Check server enforcement below.
    }
  }

  @Test("Server requires a client certificate even when its CA is trusted")
  func serverRequiresClientCertificate() async throws {
    let caPEM = try String(
      contentsOf: Self.certificates.appendingPathComponent("ca.crt"), encoding: .utf8)
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(caPEM.utf8)))
    let context = try NIOSSLContext(configuration: tls)
    let config = Self.config
    let postgresConfig = PostgresConnection.Configuration(
      host: config.host, port: config.port, username: config.username,
      password: config.password, database: config.database, tls: .require(context))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      let connection = try await PostgresConnection.connect(
        on: group.next(), configuration: postgresConfig, id: 1,
        logger: Logger(label: "dblore.mtls.negative"))
      try? await connection.close()
      try? await group.shutdownGracefully()
      Issue.record("Server accepted a trusted TLS connection without a client certificate")
    } catch let error as PSQLError {
      try? await group.shutdownGracefully()
      #expect(error.serverInfo?[.message] == "connection requires a valid client certificate")
    } catch {
      try? await group.shutdownGracefully()
      Issue.record("Expected PostgreSQL to reject the missing client certificate: \(error)")
    }
  }
}
