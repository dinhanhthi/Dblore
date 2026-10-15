// MongoSSHTunnelLifecycleTests.swift
// MongoSession over an SSH tunnel without a bastion or a MongoDB server: `EchoSSHTunnel`s whose
// channels reach `FakeMongoServer` (just enough OP_MSG for a handshake and a killOp, junk for a
// TLS ClientHello), and the manager's host-key policy against an in-process SSH server that
// accepts no user. The live login, verified TLS, killOp, close order and tunnel loss run in
// SSHTunnelIntegrationTests against mongo-ssh.

import BSON
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import Dblore

@Suite("MongoSession SSH tunnel", .serialized, .timeLimit(.minutes(1))) @MainActor
struct MongoSSHTunnelLifecycleTests {
  /// A distinct identity per test, so tests never share a stored SSH credential. No MongoDB
  /// user: the fake server only answers the handshake.
  private static func config(
    _ name: String, uri: String? = nil, sslMode: SSLMode = .disable,
    bastion: (host: String, port: Int)? = nil
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "mongo-\(name).invalid", port: 27017, database: "app",
      username: "", password: "", sslMode: sslMode,
      sshTunnel: SSHTunnelConfig(
        host: bastion?.host ?? "bastion-\(name).example", port: bastion?.port ?? 2200,
        username: "jump"),
      timeoutSeconds: 5)
    config.mongoURI = uri
    return config
  }

  private static func saveCredential(for config: ConnectionConfig) {
    let account = SSHCredentialStoreFactory.account(for: config)!
    SSHCredentialStoreFactory.shared.save(.password("jump-pass"), account: account)
  }

  private static func session(
    _ config: ConnectionConfig, factory: EchoSSHTunnelFactory,
    resolver: (any MongoSRVResolving)? = nil
  ) -> MongoSession {
    MongoSession(
      config: config, resolver: resolver, tunnelFactory: factory,
      hostKeyValidator: AcceptAnySSHHostKey())
  }

  private static func failure(_ body: () async throws -> Void) async -> (any Error)? {
    do {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  private static func connectionFailure(_ error: (any Error)?) -> String? {
    guard case .connectionFailed(let message)? = error as? DatabaseError else { return nil }
    return message
  }

  private static func eventually(
    within seconds: Double = 5, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
  }

  @Test(
    "+srv and multi-host URIs are refused before the tunnel or a DNS lookup",
    arguments: [
      "mongodb+srv://cluster0.example.com/app",
      "mongodb://a.example.com,b.example.com:27018/app",
    ])
  func singleHostOnly(uri: String) async {
    #expect(
      MongoSession.sshSingleHostMessage
        == "SSH tunnels support a single MongoDB host. Remove +srv or extra hosts.")
    let config = Self.config("single", uri: uri)
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: 1)
    for isProbe in [false, true] {
      let resolver = RecordingResolver()
      let session = Self.session(config, factory: factory, resolver: resolver)
      let error = await Self.failure {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
      }
      await session.close()
      #expect(
        Self.connectionFailure(error) == MongoSession.sshSingleHostMessage,
        "\(String(describing: error))")
      #expect(resolver.lookups == 0)
    }
    #expect(factory.connectCount == 0)
  }

  @Test("The single host is reached through one tunnel channel; close is client, then tunnel")
  func connectsThroughTunnel() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("inject")
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    let session = Self.session(config, factory: factory)
    // No local DNS: `mongo-inject.invalid` resolves only on the (fake) bastion.
    try await session.open()
    try await session.hello()
    let tunnel = try #require(factory.tunnels.first)
    #expect(factory.tunnels.count == 1)
    #expect(tunnel.opens == [.init(host: "mongo-inject.invalid", port: 27017, autoRead: true)])
    #expect(server.commands.map(\.connection) == Array(repeating: 0, count: 2))
    #expect(server.commands.last?.name == "hello")

    tunnel.onClose = { tunnel.channels.allSatisfy { !$0.isActive } }
    let events = session.closeEvents
    await session.close()
    #expect(tunnel.connectionClosedFirst == true)
    #expect(tunnel.isClosed)
    var reasons: [SessionCloseReason] = []
    for await reason in events { reasons.append(reason) }
    #expect(reasons == [.closedByApp])
    await server.stop()
  }

  @Test("A lost tunnel is reported as connection lost")
  func tunnelLossReported() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("loss")
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    let session = Self.session(config, factory: factory)
    try await session.open()
    let events = session.closeEvents
    await try #require(factory.tunnels.first).close()
    var reasons: [SessionCloseReason] = []
    for await reason in events { reasons.append(reason) }
    #expect(reasons == [.connectionLost])
    await session.close()
    await server.stop()
  }

  @Test("Cancel sends killOp from a control connection through the same tunnel")
  func killOpThroughTunnel() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("kill")
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    let session = Self.session(config, factory: factory)
    try await session.open()
    let slow = Task { _ = try await session.query("db.c.find()", binds: []) }
    #expect(await Self.eventually { server.commands.contains { $0.name == "find" } })
    await session.interrupt()
    let error = await Self.failure { try await slow.value }
    guard case .queryCancelled(_, _, let kept)? = error as? DatabaseError else {
      Issue.record("Expected queryCancelled, got \(String(describing: error))")
      await session.close()
      await server.stop()
      return
    }
    #expect(kept)
    let tunnel = try #require(factory.tunnels.first)
    #expect(factory.tunnels.count == 1)
    #expect(tunnel.opens.count == 2)
    #expect(server.commands.contains { $0.name == "killOp" && $0.connection == 1 })
    #expect(!server.commands.contains { $0.name == "killOp" && $0.connection == 0 })
    await session.close()
    #expect(tunnel.channels.allSatisfy { !$0.isActive })
    await server.stop()
  }

  @Test("Cancel after close never dials the server around the closed tunnel")
  func killOpAfterCloseStaysInTunnel() async throws {
    let server = try await FakeMongoServer.start()
    // A host the test machine reaches directly, so a dial around the tunnel would show.
    var config = Self.config("bypass")
    config.host = "127.0.0.1"
    config.port = server.port
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    let session = Self.session(config, factory: factory)
    try await session.open()
    let tunnel = try #require(factory.tunnels.first)
    let connectionsBefore = server.connections
    let opensBefore = tunnel.opens.count
    // A statement whose token stays registered until the test releases it.
    let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let statement = Task.detached {
      try await session.withStatement { _, _ in
        startedContinuation.finish()
        for await _ in release {}
      }
    }
    for await _ in started {}
    await session.close()
    await session.interrupt()
    #expect(server.connections == connectionsBefore)
    #expect(tunnel.opens.count == opensBefore)
    releaseContinuation.finish()
    _ = await statement.result
    await server.stop()
  }

  @Test("Close waits for a killOp control connection under way before closing the tunnel")
  func closeWaitsForKillOp() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("lease")
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    let session = Self.session(config, factory: factory)
    try await session.open()
    let tunnel = try #require(factory.tunnels.first)
    // At the tunnel close: no channel still opening, and every opened one closed.
    tunnel.onClose = {
      tunnel.opens.count == tunnel.channels.count && tunnel.channels.allSatisfy { !$0.isActive }
    }
    let slow = Task { _ = try await session.query("db.c.find()", binds: []) }
    #expect(await Self.eventually { server.commands.contains { $0.name == "find" } })
    let kill = Task.detached { await session.interrupt() }
    // The control channel is being opened (the echo tunnel takes 50 ms to hand it over).
    #expect(await Self.eventually { tunnel.opens.count == 2 })
    await session.close()
    #expect(tunnel.connectionClosedFirst == true)
    #expect(tunnel.isClosed)
    await kill.value
    _ = await slow.result
    await server.stop()
  }

  @Test("A TLS failure over the tunnel reports its cause, not only the closed channel")
  func tlsFailureNamesCause() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("tls", sslMode: .verifyFull)
    Self.saveCredential(for: config)
    for isProbe in [false, true] {
      let factory = EchoSSHTunnelFactory(targetPort: server.port)
      let session = Self.session(config, factory: factory)
      let error = await Self.failure {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
      }
      if !isProbe { await session.close() }
      let message = try #require(Self.connectionFailure(error), "\(String(describing: error))")
      #expect(message.hasPrefix(MongoSession.tlsHint), "\(message)")
      #expect(message != MongoSession.tlsHint, "\(message)")
      let tunnel = try #require(factory.tunnels.first)
      #expect(tunnel.isClosed)
      #expect(tunnel.channels.allSatisfy { !$0.isActive })
    }
    await server.stop()
  }

  @Test("The probe closes its tunnel after a success")
  func probeClosesTunnel() async throws {
    let server = try await FakeMongoServer.start()
    let config = Self.config("probe")
    Self.saveCredential(for: config)
    let factory = EchoSSHTunnelFactory(targetPort: server.port)
    #expect(try await Self.session(config, factory: factory).probe())
    let tunnel = try #require(factory.tunnels.first)
    #expect(factory.tunnels.count == 1)
    #expect(tunnel.isClosed)
    #expect(tunnel.channels.allSatisfy { !$0.isActive })
    await server.stop()
  }

  @Test("A refused bastion keeps its typed error in open and probe")
  func bastionErrorStaysTyped() async {
    let config = Self.config("typed")
    Self.saveCredential(for: config)
    for isProbe in [false, true] {
      let factory = EchoSSHTunnelFactory(
        targetPort: 1, connectError: SSHTunnelError.hostKeyRejected)
      let session = Self.session(config, factory: factory)
      let error = await Self.failure {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
      }
      #expect(error as? SSHTunnelError == .hostKeyRejected, "\(String(describing: error))")
      await session.close()
      #expect(factory.connectCount == 1)
    }
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

// MARK: - Doubles

/// Counts SRV and TXT lookups and finds nothing.
private final class RecordingResolver: MongoSRVResolving, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var lookups: Int { lock.withLock { count } }

  func srvRecords(_ name: String) async throws -> [MongoSRVRecord] {
    lock.withLock { count += 1 }
    return []
  }

  func txtRecords(_ name: String) async throws -> [String] {
    lock.withLock { count += 1 }
    return []
  }
}

/// A MongoDB stand-in on 127.0.0.1 that speaks just enough OP_MSG: `hello`/`isMaster` answer as
/// a standalone server, a `find` is held until a `killOp` fails it with 11601 (Interrupted),
/// `currentOp` lists the held find, anything else is `{ok: 1}`. A TLS ClientHello gets junk and
/// a close. Records each command with the index of the connection it came on.
private final class FakeMongoServer: @unchecked Sendable {
  struct Received: Equatable {
    var connection: Int
    var name: String
  }

  private let lock = NSLock()
  private var received: [Received] = []
  private var accepted = 0
  private var held: (channel: any Channel, requestID: Int32)?
  private var listener: (any Channel)?

  var port: Int { lock.withLock { listener?.localAddress?.port ?? 0 } }
  var commands: [Received] { lock.withLock { received } }
  /// Connections accepted so far.
  var connections: Int { lock.withLock { accepted } }

  static func start() async throws -> FakeMongoServer {
    let server = FakeMongoServer()
    let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        let index = server.lock.withLock {
          defer { server.accepted += 1 }
          return server.accepted
        }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            FakeMongoHandler(server: server, connection: index))
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    server.lock.withLock { server.listener = listener }
    return server
  }

  func stop() async {
    try? await lock.withLock { listener }?.close()
  }

  private static let ok: Document = ["ok": Int32(1)]

  /// The reply to `name`, or nil to hold it.
  func reply(
    to name: String, on channel: any Channel, requestID: Int32, connection: Int
  ) -> Document? {
    lock.withLock { received.append(Received(connection: connection, name: name)) }
    switch name.lowercased() {
    case "hello", "ismaster":
      return [
        "ismaster": true, "isWritablePrimary": true, "maxBsonObjectSize": Int32(16_777_216),
        "maxMessageSizeBytes": Int32(48_000_000), "maxWriteBatchSize": Int32(100_000),
        "localTime": Date(), "logicalSessionTimeoutMinutes": Int32(30),
        "minWireVersion": Int32(0), "maxWireVersion": Int32(21), "readOnly": false,
        "ok": Int32(1),
      ]
    case "find":
      lock.withLock { held = (channel, requestID) }
      return nil
    case "currentop":
      let busy = lock.withLock { held != nil }
      let operations: [Document] = busy ? [["opid": Int32(7)]] : []
      return ["inprog": operations, "ok": Int32(1)]
    case "killop":
      let stopped = lock.withLock {
        defer { held = nil }
        return held
      }
      if let stopped {
        let interrupted: Document = [
          "ok": Int32(0), "code": Int32(11601), "codeName": "Interrupted",
          "errmsg": "operation was interrupted",
        ]
        stopped.channel.writeAndFlush(
          FakeMongoHandler.message(interrupted, responseTo: stopped.requestID), promise: nil)
      }
      return Self.ok
    default:
      return Self.ok
    }
  }
}

private final class FakeMongoHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let server: FakeMongoServer
  private let connection: Int
  private var buffer = ByteBuffer()
  private var started = false

  init(server: FakeMongoServer, connection: Int) {
    self.server = server
    self.connection = connection
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var bytes = unwrapInboundIn(data)
    if !started {
      started = true
      // 0x16: a TLS handshake record.
      if bytes.getInteger(at: bytes.readerIndex, as: UInt8.self) == 0x16 {
        context.writeAndFlush(
          wrapOutboundOut(ByteBuffer(string: "HTTP/1.1 400 Bad Request\r\n\r\n")), promise: nil)
        context.close(promise: nil)
        return
      }
    }
    buffer.writeBuffer(&bytes)
    while let length = buffer.getInteger(
      at: buffer.readerIndex, endianness: .little, as: Int32.self),
      length > 0, buffer.readableBytes >= Int(length),
      var message = buffer.readSlice(length: Int(length))
    {
      handle(&message, context: context)
    }
  }

  /// One OP_MSG: header, flag bits, then the kind-0 section holding the command document.
  private func handle(_ message: inout ByteBuffer, context: ChannelHandlerContext) {
    guard message.readInteger(endianness: .little, as: Int32.self) != nil,
      let requestID = message.readInteger(endianness: .little, as: Int32.self),
      message.readInteger(endianness: .little, as: Int32.self) != nil,
      message.readInteger(endianness: .little, as: Int32.self) == 2013,
      message.readInteger(endianness: .little, as: UInt32.self) != nil,
      message.readInteger(as: UInt8.self) == 0,
      let length = message.getInteger(
        at: message.readerIndex, endianness: .little, as: Int32.self),
      let body = message.readSlice(length: Int(length))
    else {
      context.close(promise: nil)
      return
    }
    let name = Document(buffer: body).keys.first ?? ""
    if let reply = server.reply(
      to: name, on: context.channel, requestID: requestID, connection: connection)
    {
      context.writeAndFlush(
        wrapOutboundOut(Self.message(reply, responseTo: requestID)), promise: nil)
    }
  }

  static func message(_ document: Document, responseTo: Int32) -> ByteBuffer {
    var body = document.makeByteBuffer()
    var out = ByteBuffer()
    out.writeInteger(Int32(16 + 4 + 1 + body.readableBytes), endianness: .little)
    out.writeInteger(Int32(1), endianness: .little)
    out.writeInteger(responseTo, endianness: .little)
    out.writeInteger(Int32(2013), endianness: .little)
    out.writeInteger(UInt32(0), endianness: .little)
    out.writeInteger(UInt8(0))
    out.writeBuffer(&body)
    return out
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}
