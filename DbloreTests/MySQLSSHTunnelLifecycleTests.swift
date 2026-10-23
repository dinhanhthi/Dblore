// MySQLSSHTunnelLifecycleTests.swift
// MySQLSession over an SSH tunnel without a bastion or a database server: an `EchoSSHTunnel`
// whose channels reach the `NoTLSServer` fixture (a MySQL greeting without TLS, every login
// refused with 1045 or asked for full authentication), and the manager's host-key policy against
// an in-process SSH server that accepts no user. The live login, TLS, KILL QUERY, close order
// and tunnel loss run in SSHTunnelIntegrationTests against mysql-ssh.

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import Dblore

@Suite("MySQLSession SSH tunnel", .serialized, .timeLimit(.minutes(1)))
struct MySQLSSHTunnelLifecycleTests {
  /// A distinct identity per test, so tests never share a stored SSH credential.
  private static func config(
    _ name: String, host: String? = nil, sslMode: SSLMode = .prefer,
    bastion: (host: String, port: Int)? = nil
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mysql, host: host ?? "db-\(name).invalid", port: 3306, database: "app",
      username: "ada", password: "secret", sslMode: sslMode,
      sshTunnel: SSHTunnelConfig(
        host: bastion?.host ?? "bastion-\(name).example", port: bastion?.port ?? 2200,
        username: "jump"),
      timeoutSeconds: 5)
  }

  private static func saveCredential(for config: ConnectionConfig) {
    let account = SSHCredentialStoreFactory.account(for: config)!
    SSHCredentialStoreFactory.shared.save(.password("jump-pass"), account: account)
  }

  @Test(
    "Every connect attempt, the plain retry after TLS too, gets its own tunnel channel; no local DNS"
  )
  func freshChannelPerAttempt() async throws {
    let server = try await NoTLSServer.start()
    let config = Self.config("retry")
    Self.saveCredential(for: config)
    for isProbe in [false, true] {
      let factory = EchoSSHTunnelFactory(targetPort: server.port)
      let session = MySQLSession(
        config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("The fixture refuses every login")
      } catch DatabaseError.connectionFailed(let message) {
        // The fixture's answer, not "Could not resolve host": the host resolves on the bastion.
        #expect(message.contains("1045"), "\(message)")
      }
      // The probe closes by itself.
      if !isProbe { await session.close() }
      #expect(factory.tunnels.count == 1)
      let tunnel = try #require(factory.tunnels.first)
      let open = EchoSSHTunnel.Open(host: "db-retry.invalid", port: 3306, autoRead: false)
      #expect(tunnel.opens == [open, open])
      #expect(Set(tunnel.channels.map(ObjectIdentifier.init)).count == 2)
      #expect(tunnel.isClosed)
      #expect(tunnel.channels.allSatisfy { !$0.isActive })
    }
    let connections = try await server.closedConnections(4)
    await server.stop()
    #expect(connections.count == 4)
    // The TLS attempt sends no login; the plain retry sends the user name.
    for pair in stride(from: 0, to: connections.count, by: 2) {
      #expect(NoTLSServer.sentNoLogin(connections[pair]))
      #expect(NoTLSServer.contains(connections[pair + 1], Array("ada".utf8)))
    }
  }

  /// The connect path's own bootstrap arms the guard over SSH, whatever the database host is:
  /// the forwarder's loopback address never counts as a direct loopback connection.
  @Test("Over SSH, a server asking for the full password gets nothing after the scramble")
  func sshLoginRefusesFullAuthentication() async throws {
    let server = try await NoTLSServer.start(
      loginReply: MySQLWireFixtures.frame(
        sequence: 2, MySQLWireFixtures.performFullAuthentication))
    let config = Self.config("guard")
    Self.saveCredential(for: config)
    let session = MySQLSession(
      config: config, tunnelFactory: EchoSSHTunnelFactory(targetPort: server.port),
      hostKeyValidator: AcceptAnySSHHostKey())
    do {
      try await session.open()
      Issue.record("The guard refuses full authentication")
    } catch DatabaseError.connectionFailed(let message) {
      // Unguarded, mysql-nio refuses it with the plain-TCP text instead.
      #expect(message == MySQLSession.fullAuthRefusedMessage, "\(message)")
    }
    await session.close()
    // Prefer: the TLS attempt, then the plain retry that reaches the login.
    let connections = try await server.closedConnections(2)
    await server.stop()
    #expect(connections.count == 2)
    #expect(NoTLSServer.sentNoLogin(connections[0]))
    let login = try #require(connections.last)
    #expect(NoTLSServer.payloads(login).count == 1, "\(login)")
    #expect(NoTLSServer.contains(login, Array("ada".utf8)))
    #expect(!NoTLSServer.contains(login, Array("secret".utf8)))
  }

  @Test("A refused bastion keeps its typed error in open and probe")
  func bastionErrorStaysTyped() async {
    let config = Self.config("typed")
    Self.saveCredential(for: config)
    for isProbe in [false, true] {
      let factory = EchoSSHTunnelFactory(
        targetPort: 1, connectError: SSHTunnelError.hostKeyRejected)
      let session = MySQLSession(
        config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A refused bastion must fail")
      } catch {
        #expect(error as? SSHTunnelError == .hostKeyRejected, "\(error)")
      }
      await session.close()
      #expect(factory.connectCount == 1)
    }
  }

  @Test("A bastion that refuses the channel to the database host says so in open and probe")
  func channelOpenRejectionStaysTyped() async throws {
    let config = Self.config("channel")
    Self.saveCredential(for: config)
    for isProbe in [false, true] {
      let factory = RejectingSSHTunnelFactory()
      let session = MySQLSession(
        config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A rejected channel must fail")
      } catch {
        // Not mysql-nio's "connection closed": the forwarder's open error, worded as PostgreSQL.
        #expect(error as? SSHTunnelError == .channelOpenRejected, "\(error)")
      }
      await session.close()
      let tunnel = try #require(factory.inner.tunnels.first)
      #expect(tunnel.opens.first == .init(host: "db-channel.invalid", port: 3306, autoRead: false))
      #expect(tunnel.isClosed)
    }
  }

  @Test(
    "Verify Full to an IP-literal database host over SSH is refused before the tunnel",
    arguments: ["10.0.0.5", "fd00::5"])
  func verifyFullNeedsHostName(host: String) async {
    let config = Self.config("ip", host: host, sslMode: .verifyFull)
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: 1)
    let session = MySQLSession(
      config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
    do {
      try await session.open()
      Issue.record("Verify Full cannot check an IP address through the forwarder")
    } catch DatabaseError.connectionFailed(let message) {
      #expect(message.contains("host name"), "\(message)")
    } catch {
      Issue.record("Expected connectionFailed, got \(error)")
    }
    await session.close()
    #expect(factory.connectCount == 0)
  }

  @Test("Test Connection and connect ask the manager's prompt about an unknown bastion")
  func managerPromptsForUnknownBastion() async throws {
    let ssh = try await UserlessSSHServer.start()
    let store = SSHKnownHostStoreFactory.shared
    for answer in [false, true] {
      store.remove(host: "127.0.0.1", port: ssh.port)
      let config = Self.config("prompt", bastion: ("127.0.0.1", ssh.port))
      Self.saveCredential(for: config)
      let prompt = FakeSSHHostKeyPrompt(answer: answer)
      let manager = DatabaseConnectionManager(sshHostKeyPrompt: prompt)
      for isProbe in [true, false] {
        do {
          if isProbe {
            _ = try await manager.testConnection(config: config)
          } else {
            try await manager.connect(config: config)
          }
          Issue.record("The SSH server accepts no user")
        } catch {
          // Trusted: the key check passed and the (userless) login failed.
          switch error {
          case DatabaseError.sshAuthenticationFailed: #expect(answer, "\(error)")
          case DatabaseError.sshHostKeyNotTrusted: #expect(!answer, "\(error)")
          default: Issue.record("Unexpected \(error)")
          }
        }
      }
      // Trust pinned the key at Test Connection, so connect did not ask again.
      #expect(prompt.requests.count == (answer ? 1 : 2))
      #expect(prompt.requests.allSatisfy { $0.fingerprint == ssh.fingerprint })
      #expect((try store.lookup(host: "127.0.0.1", port: ssh.port) != nil) == answer)
    }
    store.remove(host: "127.0.0.1", port: ssh.port)
    await ssh.stop()
  }
}

/// Echo tunnels whose every channel open is refused, like a bastion that cannot reach the
/// database host.
private struct RejectingSSHTunnelFactory: SSHTunnelFactory {
  let inner = EchoSSHTunnelFactory(targetPort: 1)

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    let tunnel = try await inner.connect(
      host: host, port: port, username: username, authentication: authentication,
      hostKeyValidator: hostKeyValidator, connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout)
    (tunnel as? EchoSSHTunnel)?.openError = SSHTunnelError.channelOpenRejected
    return tunnel
  }
}
