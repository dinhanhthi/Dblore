// SSHTunnelSpyFactory.swift
// Real SSH tunnels wrapped in spies, so live tests can count the tunnels a session or manager
// opened, see which ones are closed, and reach the parent channel to simulate a drop. Also an
// echo tunnel (no SSH) whose channels reach a loopback echo server (or a given loopback port),
// for forwarder and session unit tests, and an SSH server that refuses every user (host-key
// prompt tests).

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import Dblore

struct AcceptAnySSHHostKey: SSHHostKeyValidating {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String
  )
    async throws
  {}
}

/// Wraps a real tunnel so tests can see when it was closed and what was closed before it.
final class SpySSHTunnel: SSHTunneling, @unchecked Sendable {
  let tunnel: SSHTunnel
  private let lock = NSLock()
  private var closeHook: (@Sendable () -> Bool)?
  private var observed: Bool?
  private var opened: [any Channel] = []

  init(_ tunnel: SSHTunnel) {
    self.tunnel = tunnel
  }

  var parentChannel: any Channel { tunnel.parentChannel }
  var isClosed: Bool { tunnel.isClosed }
  /// Closed by the app and its SSH connection is gone.
  var isTornDown: Bool { isClosed && !parentChannel.isActive }
  var onClose: (@Sendable () -> Bool)? {
    get { lock.withLock { closeHook } }
    set { lock.withLock { closeHook = newValue } }
  }
  var connectionClosedFirst: Bool? { lock.withLock { observed } }
  /// The channels opened through this tunnel.
  var channels: [any Channel] { lock.withLock { opened } }

  func openDirectTCPIP(
    targetHost: String, targetPort: Int, autoRead: Bool
  ) async throws -> any Channel {
    let channel = try await tunnel.openDirectTCPIP(
      targetHost: targetHost, targetPort: targetPort, autoRead: autoRead)
    lock.withLock { opened.append(channel) }
    return channel
  }

  func whenClosed(_ callback: @escaping @Sendable () -> Void) {
    tunnel.whenClosed(callback)
  }

  func close() async {
    if let hook = onClose {
      let value = hook()
      lock.withLock { if observed == nil { observed = value } }
    }
    await tunnel.close()
  }
}

final class SpySSHTunnelFactory: SSHTunnelFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var made: [SpySSHTunnel] = []

  var tunnels: [SpySSHTunnel] { lock.withLock { made } }

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    let tunnel = try await SSHTunnel.connect(
      host: host, port: port, username: username, authentication: authentication,
      hostKeyValidator: hostKeyValidator, connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout)
    let spy = SpySSHTunnel(tunnel)
    lock.withLock { made.append(spy) }
    return spy
  }
}

/// PostgreSQL sessions whose tunnels come from `tunnelFactory`.
struct SpyPostgresSessionFactory: DatabaseSessionFactory {
  let tunnelFactory: SpySSHTunnelFactory
  var hostKeyValidator: any SSHHostKeyValidating = AcceptAnySSHHostKey()

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    PostgresSession(
      config: config, tunnelFactory: tunnelFactory, hostKeyValidator: hostKeyValidator)
  }
}

/// MySQL sessions whose tunnels come from `tunnelFactory`.
struct SpyMySQLSessionFactory: DatabaseSessionFactory {
  let tunnelFactory: any SSHTunnelFactory
  var hostKeyValidator: any SSHHostKeyValidating = AcceptAnySSHHostKey()

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    MySQLSession(config: config, tunnelFactory: tunnelFactory, hostKeyValidator: hostKeyValidator)
  }
}

/// MongoDB sessions whose tunnels come from `tunnelFactory`.
struct SpyMongoSessionFactory: DatabaseSessionFactory {
  let tunnelFactory: any SSHTunnelFactory
  var hostKeyValidator: any SSHHostKeyValidating = AcceptAnySSHHostKey()

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    MongoSession(config: config, tunnelFactory: tunnelFactory, hostKeyValidator: hostKeyValidator)
  }
}

/// Bastion connects without SSH: each one is an `EchoSSHTunnel` to 127.0.0.1:`targetPort`, or
/// fails with `connectError`. Records the tunnels it made.
final class EchoSSHTunnelFactory: SSHTunnelFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var made: [EchoSSHTunnel] = []
  private var attempts = 0
  private let targetPort: Int
  private let connectError: (any Error)?

  init(targetPort: Int, connectError: (any Error)? = nil) {
    self.targetPort = targetPort
    self.connectError = connectError
  }

  var connectCount: Int { lock.withLock { attempts } }
  var tunnels: [EchoSSHTunnel] { lock.withLock { made } }

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    lock.withLock { attempts += 1 }
    if let connectError { throw connectError }
    let tunnel = try EchoSSHTunnel.connecting(toPort: targetPort)
    lock.withLock { made.append(tunnel) }
    return tunnel
  }
}

/// A tunnel without SSH: each `openDirectTCPIP` is a TCP connection to an in-process echo server
/// on 127.0.0.1 (or to the port given to `connecting(toPort:)`), opened with the requested
/// `autoRead`, so a paused channel buffers what the server sends first (`greeting`) exactly like
/// a paused SSH child. `close()` closes every opened channel and the echo server, then reports
/// the close to `whenClosed` observers.
final class EchoSSHTunnel: SSHTunneling, @unchecked Sendable {
  struct Open: Equatable {
    var host: String
    var port: Int
    var autoRead: Bool
  }

  private let server: (any Channel)?
  private let target: SocketAddress?
  private let greets: Bool
  private let lock = NSLock()
  private var recorded: [Open] = []
  private var opened: [any Channel] = []
  private var observers: [@Sendable () -> Void] = []
  private var closed = false
  private var failure: (any Error)?
  private var closeHook: (@Sendable () -> Bool)?
  private var observed: Bool?

  private init(server: (any Channel)?, target: SocketAddress?, greets: Bool) {
    self.server = server
    self.target = target
    self.greets = greets
  }

  /// `greeting` is written by the server as soon as a connection is accepted.
  static func start(greeting: String? = nil) async throws -> EchoSSHTunnel {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(EchoHandler(greeting: greeting))
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    return EchoSSHTunnel(server: server, target: nil, greets: greeting != nil)
  }

  /// Opens reach the server listening on 127.0.0.1:`port`, which speaks first (like MySQL).
  static func connecting(toPort port: Int) throws -> EchoSSHTunnel {
    EchoSSHTunnel(
      server: nil, target: try SocketAddress(ipAddress: "127.0.0.1", port: port), greets: true)
  }

  var opens: [Open] { lock.withLock { recorded } }
  var isClosed: Bool { lock.withLock { closed } }
  var channels: [any Channel] { lock.withLock { opened } }
  /// Runs when `close()` starts; its first answer is `connectionClosedFirst`.
  var onClose: (@Sendable () -> Bool)? {
    get { lock.withLock { closeHook } }
    set { lock.withLock { closeHook = newValue } }
  }
  var connectionClosedFirst: Bool? { lock.withLock { observed } }
  /// Makes every later open throw this error.
  var openError: (any Error)? {
    get { lock.withLock { failure } }
    set { lock.withLock { failure = newValue } }
  }

  func openDirectTCPIP(
    targetHost: String, targetPort: Int, autoRead: Bool
  ) async throws -> any Channel {
    let error = lock.withLock { () -> (any Error)? in
      recorded.append(Open(host: targetHost, port: targetPort, autoRead: autoRead))
      return closed ? SSHTunnelError.closedBeforeReady : failure
    }
    if let error { throw error }
    guard let address = target ?? server?.localAddress else {
      throw SSHTunnelError.closedBeforeReady
    }
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelOption(ChannelOptions.autoRead, value: autoRead)
      .connect(to: address)
      .get()
    // Like SSH, where the greeting comes with the open confirmation: it has arrived before the
    // caller gets the channel, so an auto-reading channel has already dropped it.
    if greets { try await Task.sleep(for: .milliseconds(50)) }
    let accepted = lock.withLock {
      guard !closed else { return false }
      opened.append(channel)
      return true
    }
    guard accepted else {
      try? await channel.close()
      throw SSHTunnelError.closedBeforeReady
    }
    return channel
  }

  func whenClosed(_ callback: @escaping @Sendable () -> Void) {
    let now = lock.withLock {
      guard !closed else { return true }
      observers.append(callback)
      return false
    }
    if now { callback() }
  }

  func close() async {
    if let hook = onClose {
      let value = hook()
      lock.withLock { if observed == nil { observed = value } }
    }
    let (channels, callbacks) = lock.withLock {
      guard !closed else { return ([any Channel](), [@Sendable () -> Void]()) }
      closed = true
      defer { observers.removeAll() }
      return (opened, observers)
    }
    for channel in channels {
      try? await channel.close()
    }
    try? await server?.close()
    for callback in callbacks { callback() }
  }
}

/// Writes the greeting on accept, then echoes every byte back.
private final class EchoHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let greeting: String?

  init(greeting: String?) {
    self.greeting = greeting
  }

  func channelActive(context: ChannelHandlerContext) {
    if let greeting {
      context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: greeting)), promise: nil)
    }
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    context.write(data, promise: nil)
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    context.flush()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}

/// An SSH server on 127.0.0.1 with a fresh ed25519 host key that refuses every user.
final class UserlessSSHServer: Sendable {
  let channel: any Channel
  let fingerprint: String

  private init(channel: any Channel, fingerprint: String) {
    self.channel = channel
    self.fingerprint = fingerprint
  }

  var port: Int { channel.localAddress?.port ?? 0 }

  static func start() async throws -> UserlessSSHServer {
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let fingerprint = try #require(SSHTunnel.fingerprint(of: hostKey.publicKey))
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: DenyEveryUser())),
              allocator: channel.allocator, inboundChildChannelInitializer: nil))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    return UserlessSSHServer(channel: channel, fingerprint: fingerprint)
  }

  func stop() async { try? await channel.close() }
}

final class DenyEveryUser: NIOSSHServerUserAuthenticationDelegate {
  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    responsePromise.succeed(.failure)
  }
}
