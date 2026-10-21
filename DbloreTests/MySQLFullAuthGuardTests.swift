// MySQLFullAuthGuardTests.swift
// The full-authentication guard keeps mysql-nio from sending the real password when the TLS
// mode does not verify the server. No server: the login runs over EmbeddedChannels with
// scripted packets (and an in-memory TLS server for the unverified TLS rows).

import Foundation
import MySQLNIO
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing
import os

@testable import Dblore

@Suite(.serialized)
struct MySQLFullAuthGuardTests {
  static let password = "guarded-secret"

  /// Control: without the guard, the fork refuses full authentication over a plain channel with
  /// its own error. This also proves the scripted greeting reaches the 0x04 branch.
  @Test func forkAloneRefusesFullAuthWithItsOwnError() throws {
    let (channel, _) = try Self.channel(guard: nil)
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    #expect(try Self.outbound(channel).count == 1)  // HandshakeResponse41
    try channel.writeInbound(Self.packet(2, MySQLWireFixtures.performFullAuthentication))

    #expect(Self.isPublicKeyRetrievalNotAllowed(login.error))
  }

  /// The armed guard drops [0x01, 0x04] before the fork's decoder, closes the channel and
  /// records the refusal; the fork then fails the login with `.closed`, never with its own
  /// refusal, and nothing more leaves the client (no password, no COM_QUIT).
  @Test func guardDropsFullAuthBeforeTheForkSeesIt() throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    let response = try Self.outbound(channel)
    #expect(response.count == 1 && response.first?[3] == 1)  // HandshakeResponse41, sequence 1

    // The packet arrives in two reads: header split from its payload.
    let fullAuth = MySQLWireFixtures.frame(sequence: 2, MySQLWireFixtures.performFullAuthentication)
    try channel.writeInbound(ByteBuffer(bytes: fullAuth.prefix(3)))
    #expect(!refusal.refused && channel.isActive && login.result == nil)
    try channel.writeInbound(ByteBuffer(bytes: fullAuth.dropFirst(3)))

    #expect(refusal.reason == .fullAuthentication)
    #expect(!spy.seen.contains(fullAuth))
    #expect(Self.isClosed(login.error))
    #expect(!Self.isPublicKeyRetrievalNotAllowed(login.error))
    #expect(try Self.outbound(channel).isEmpty)
    #expect(!channel.isActive)
  }

  /// A wrong password (ERR 1045) passes the armed guard: the login fails with the server's
  /// error, not `.closed`, and no refusal is recorded.
  @Test func serverErrorPassesWhileArmed() throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try Self.outbound(channel)
    let message = "Access denied for user 'dblore'@'localhost' (using password: YES)"
    let err = MySQLWireFixtures.frame(
      sequence: 2, MySQLWireFixtures.err(code: 1045, sqlState: "28000", message: message))
    try channel.writeInbound(ByteBuffer(bytes: err))

    #expect(!refusal.refused)
    #expect(spy.seen.last == err)
    #expect(!Self.isClosed(login.error))
    guard case .server(let packet)? = login.error as? MySQLError else {
      Issue.record("expected the server's error, got \(String(describing: login.error))")
      return
    }
    #expect(packet.errorCode == 1045)
    #expect(packet.sqlState == "28000")
    #expect(packet.errorMessage == message)
  }

  /// An OK does not disarm the guard; `disarm()`, run when the fork's login future succeeds (as
  /// the app does), does. After it a packet that looks like [0x01, 0x04] (a one-column text row
  /// holding 0x04, say) reaches the fork untouched; before it the guard refuses it. With
  /// `oneRead`, fast_auth_success, OK and that packet arrive in one read: `disarm()` runs inside
  /// the guard's forwarding loop and the packet still reaches the fork once, after the OK.
  @Test(arguments: [(false, false), (true, false), (true, true)])
  func lookalikeRowPassesOnlyAfterDisarm(disarmed: Bool, oneRead: Bool) throws {
    let refusal = FullAuthRefusal()
    let fullAuthGuard = MySQLFullAuthGuard(armed: true, refusal: refusal)
    let (channel, spy) = try Self.channel(guard: fullAuthGuard)
    let login = Self.login(over: channel, tls: nil, disarming: disarmed ? fullAuthGuard : nil)

    let greeting = MySQLWireFixtures.frame(sequence: 0, MySQLWireFixtures.greeting(ssl: false))
    let fastAuth = MySQLWireFixtures.frame(sequence: 2, MySQLWireFixtures.fastAuthSuccess)
    let ok = MySQLWireFixtures.frame(sequence: 3, MySQLWireFixtures.ok)
    let lookalike = MySQLWireFixtures.frame(
      sequence: 1, MySQLWireFixtures.performFullAuthentication)

    try channel.writeInbound(ByteBuffer(bytes: greeting))
    _ = try Self.outbound(channel)
    if oneRead {
      try channel.writeInbound(ByteBuffer(bytes: fastAuth + ok + lookalike))
      #expect(try login.result?.get() != nil)
    } else {
      try channel.writeInbound(ByteBuffer(bytes: fastAuth + ok))
      #expect(try login.result?.get() != nil)
      try channel.writeInbound(ByteBuffer(bytes: lookalike))
    }

    if disarmed {
      #expect(spy.seen == [greeting, fastAuth, ok, lookalike])
      #expect(!refusal.refused)
    } else {
      #expect(spy.seen == [greeting, fastAuth, ok])
      #expect(refusal.reason == .fullAuthentication)
    }
    // Disarmed, no command was waiting, so the fork closed on the stray packet; armed, the guard.
    #expect(!channel.isActive)
  }

  /// The fork reads only the status and command bytes of AuthMoreData, so any more-data packet
  /// but fast_auth_success is refused, however it is framed or split across reads.
  @Test(arguments: RefusedScript.all)
  func guardRefusesEveryOtherMoreDataPacket(script: RefusedScript) throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    for chunk in script.chunks { try channel.writeInbound(ByteBuffer(bytes: chunk)) }

    #expect(refusal.reason == script.reason)
    // A Bool, so a failure does not print a 16 MiB array.
    let forwardedAsScripted = spy.seen.flatMap { $0 } == script.forwarded
    #expect(forwardedAsScripted)
    let outbound = try Self.outbound(channel)
    #expect(outbound.count == 1 && outbound.first?[3] == 1)  // HandshakeResponse41 only
    #expect(Self.isClosed(login.error))
    #expect(!channel.isActive)
  }

  /// The fork joins a 0xFFFFFF-byte frame with the frames after it into one message, which a
  /// later chunk (an OK-looking [0x00, ...]) cannot change, and a hostile server could make the
  /// guard buffer up to 16 MiB. The guard refuses any frame over 64 KiB on its header, here in
  /// the greeting phase, so no HandshakeResponse is written.
  @Test(arguments: [64 * 1024 + 1, 0xFF_FF_FF])
  func guardRefusesAnOversizedGreetingOnItsHeader(length: Int) throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    let greeting = MySQLWireFixtures.frame(
      sequence: 0, MySQLWireFixtures.padded(MySQLWireFixtures.greeting(ssl: false), to: length))
    try channel.writeInbound(ByteBuffer(bytes: greeting.prefix(4)))
    #expect(refusal.reason == .oversizedFrame)
    try channel.writeInbound(ByteBuffer(bytes: greeting.dropFirst(4)))
    try channel.writeInbound(Self.packet(1, MySQLWireFixtures.ok))

    let forkSawNothing = spy.seen.isEmpty
    #expect(forkSawNothing)
    #expect(try Self.outbound(channel).isEmpty)
    #expect(Self.isClosed(login.error))
    #expect(!channel.isActive)
  }

  /// A switch to a plugin outside the allow-list is refused before the fork sees it, so a fork
  /// that learns a cleartext plugin still cannot send the password.
  @Test func guardRefusesASwitchToAnotherPlugin() throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    #expect(try Self.outbound(channel).count == 1)
    let request = MySQLWireFixtures.frame(
      sequence: 2, MySQLWireFixtures.authSwitchRequest(plugin: "mysql_clear_password"))
    try channel.writeInbound(ByteBuffer(bytes: request))

    #expect(refusal.reason == .authSwitch(plugin: "mysql_clear_password"))
    #expect(!spy.seen.contains(request))
    #expect(try Self.outbound(channel).isEmpty)
    #expect(Self.isClosed(login.error))
    #expect(!channel.isActive)
  }

  /// A switch to mysql_native_password reaches the fork, which answers with the scramble.
  @Test func guardPassesASwitchToNativePassword() throws {
    let refusal = FullAuthRefusal()
    let (channel, _) = try Self.channel(
      guard: MySQLFullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try Self.outbound(channel)
    try channel.writeInbound(
      Self.packet(2, MySQLWireFixtures.authSwitchRequest(plugin: "mysql_native_password")))
    let switchResponse = try Self.outbound(channel)
    #expect(switchResponse.count == 1 && switchResponse.first?.count == 4 + 20)
    try channel.writeInbound(Self.packet(4, MySQLWireFixtures.ok))

    #expect(!refusal.refused)
    let connection = try #require(try login.result?.get())
    try connection.close().wait()
  }

  /// Pins the plugins the fork can switch to, as observed: a fork bump that changes the set
  /// fails here, and the guard's allow-list must be reviewed with it.
  @Test(arguments: [
    ("caching_sha2_password", true), ("mysql_native_password", true),
    ("mysql_clear_password", false), ("sha256_password", false),
  ])
  func forkSwitchesOnlyToItsKnownPlugins(plugin: String, supported: Bool) throws {
    let (channel, _) = try Self.channel(guard: nil)
    let login = Self.login(over: channel, tls: nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try Self.outbound(channel)
    try channel.writeInbound(
      Self.packet(2, MySQLWireFixtures.authSwitchRequest(plugin: plugin)))

    if supported {
      #expect(try Self.outbound(channel).count == 1)
      try channel.writeInbound(Self.packet(4, MySQLWireFixtures.ok))
      let connection = try #require(try login.result?.get())
      try connection.close().wait()
    } else {
      #expect(Self.isUnsupportedAuthPlugin(login.error, name: plugin))
    }
  }

  /// Over TLS that does not verify the server (the Require mode), the fork answers full
  /// authentication with the password in cleartext inside the tunnel, also when the more-data
  /// packet carries a trailing byte. With the guard the in-memory TLS server receives nothing
  /// after the handshake response. The guard reads the decrypted packet, so it sits after
  /// NIOSSLClientHandler (which the fork put `.first`) and before the fork's decoder.
  @Test(
    arguments: [
      (false, [0x01, 0x04]), (true, [0x01, 0x04]), (false, [0x01, 0x04, 0x00]),
      (true, [0x01, 0x04, 0x00]),
    ] as [(Bool, [UInt8])])
  func unverifiedTLSFullAuth(guarded: Bool, moreData: [UInt8]) throws {
    let refusal = FullAuthRefusal()
    let fullAuthGuard = guarded ? MySQLFullAuthGuard(armed: true, refusal: refusal) : nil
    let (client, spy) = try Self.channel(guard: fullAuthGuard)
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    let login = Self.login(over: client, tls: tls)

    try client.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: true)))
    let sslRequest = try #require(try client.readOutbound(as: ByteBuffer.self))
    #expect(sslRequest.readableBytes == 4 + 32 && sslRequest.getInteger(at: 3) == UInt8(1))
    try Self.expectGuardBetweenTLSAndSpy(client, fullAuthGuard: fullAuthGuard, spy: spy)

    let server = try Self.tlsServer()
    let response = try Self.shuttle(client, server) { !$0.isEmpty }
    #expect(response.count > 4 && response[3] == 2)  // HandshakeResponse41 after SSLRequest

    let fullAuth = MySQLWireFixtures.frame(sequence: 3, moreData)
    server.writeAndFlush(ByteBuffer(bytes: fullAuth), promise: nil)
    let afterResponse = try Self.shuttle(client, server) { !$0.isEmpty || refusal.refused }

    if guarded {
      #expect(afterResponse.isEmpty)
      #expect(refusal.reason == .fullAuthentication)
      #expect(!spy.seen.contains(fullAuth))
      #expect(Self.isClosed(login.error))
    } else {
      #expect(
        afterResponse == MySQLWireFixtures.frame(sequence: 4, Array(Self.password.utf8) + [0]))
      #expect(!refusal.refused)
      client.close(promise: nil)
      _ = try? Self.shuttle(client, server) { _ in !client.isActive }
    }
  }

  /// Verify CA and Verify Full never arm the guard. A direct connection to this Mac is exempt;
  /// the SSH forwarder's 127.0.0.1 is not, nor is any other host.
  @Test func policyArmsOnlyUnverifiedTLSOffThisMac() {
    let rows: [(SSLMode, String, Bool, Bool)] = [
      (.verifyCa, "db.example.com", false, false),
      (.verifyFull, "127.0.0.1", true, false),
      (.prefer, "127.0.0.1", false, false),
      (.require, "::1", false, false),
      (.disable, "LocalHost", false, false),
      (.prefer, "127.0.0.1", true, true),
      (.allow, "db.example.com", false, true),
      (.prefer, "db.example.com", false, true),
      (.require, "10.0.0.5", true, true),
    ]
    for (mode, host, usesSSH, armed) in rows {
      #expect(
        armsFullAuthGuard(tlsMode: mode, host: host, usesSSH: usesSSH) == armed,
        "\(mode.rawValue) \(host) ssh=\(usesSSH)")
    }
  }
}

// MARK: - Helpers

extension MySQLFullAuthGuardTests {
  /// A user inbound event fired from one handler's context: it reaches only the handlers after
  /// it, which is how the tests read the pipeline's order.
  enum PipelineMarker: Equatable, Sendable { case fromTLS, fromGuard }

  /// Records what the guard forwarded to the fork's decoder, and the markers that reached it
  /// (kept from the fork's handlers).
  final class InboundSpy: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    var seen: [[UInt8]] = []
    var markers: [PipelineMarker] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      seen.append(Array(unwrapInboundIn(data).readableBytesView))
      context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
      if let marker = event as? PipelineMarker {
        markers.append(marker)
      } else {
        context.fireUserInboundEventTriggered(event)
      }
    }
  }

  /// Placed directly before the guard: it sees a marker exactly when the guard would.
  final class MarkerProbe: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var markers: [PipelineMarker] = []

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
      if let marker = event as? PipelineMarker { markers.append(marker) }
      context.fireUserInboundEventTriggered(event)
    }
  }

  /// The connect future's outcome (EmbeddedEventLoop completes it synchronously).
  final class Captured<Value: Sendable>: Sendable {
    private let box = OSAllocatedUnfairLock<Result<Value, any Error>?>(initialState: nil)
    init(_ future: EventLoopFuture<Value>) {
      future.whenComplete { outcome in self.box.withLock { $0 = outcome } }
    }
    var result: Result<Value, any Error>? { box.withLock { $0 } }
    var error: (any Error)? {
      guard case .failure(let error) = result else { return nil }
      return error
    }
  }

  /// An active channel with the guard (if any) and the spy in front, as the app's bootstrap
  /// initializer leaves it before `connect(over:)` appends the fork's handlers after them.
  static func channel(
    guard fullAuthGuard: MySQLFullAuthGuard?
  ) throws -> (EmbeddedChannel, InboundSpy) {
    let channel = EmbeddedChannel()
    let spy = InboundSpy()
    if let fullAuthGuard { try channel.pipeline.syncOperations.addHandler(fullAuthGuard) }
    try channel.pipeline.syncOperations.addHandler(spy)
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3306)).wait()
    return (channel, spy)
  }

  /// Starts the fork's login; `disarming` is disarmed when it succeeds, as the app will do.
  static func login(
    over channel: EmbeddedChannel, tls: TLSConfiguration?,
    disarming: MySQLFullAuthGuard? = nil
  ) -> Captured<MySQLConnection> {
    let connect = MySQLConnection.connect(
      over: channel, username: "dblore", database: "app", password: password,
      tlsConfiguration: tls, serverHostname: nil, allowPublicKeyRetrieval: false)
    if let disarming {
      let bound = NIOLoopBound(disarming, eventLoop: channel.eventLoop)
      connect.whenSuccess { _ in bound.value.disarm() }
    }
    return Captured(connect)
  }

  /// Reads the order from markers: one fired from NIOSSLClientHandler's context reaches the
  /// probe placed directly before the guard (so TLS comes first), and one fired from the
  /// guard's context reaches the spy but not the probe (so the guard comes before the spy and
  /// the fork's handlers appended after it). Without a guard, TLS still comes before the spy.
  static func expectGuardBetweenTLSAndSpy(
    _ channel: EmbeddedChannel, fullAuthGuard: MySQLFullAuthGuard?, spy: InboundSpy
  ) throws {
    let pipeline = channel.pipeline.syncOperations
    let tlsContext = try pipeline.context(handlerType: NIOSSLClientHandler.self)
    guard let fullAuthGuard else {
      tlsContext.fireUserInboundEventTriggered(PipelineMarker.fromTLS)
      #expect(spy.markers == [.fromTLS])
      return
    }
    let probe = MarkerProbe()
    try pipeline.addHandler(probe, position: .before(fullAuthGuard))
    tlsContext.fireUserInboundEventTriggered(PipelineMarker.fromTLS)
    try pipeline.context(handler: fullAuthGuard)
      .fireUserInboundEventTriggered(PipelineMarker.fromGuard)
    #expect(probe.markers == [.fromTLS])
    #expect(spy.markers == [.fromTLS, .fromGuard])
  }

  static func packet(_ sequence: UInt8, _ payload: [UInt8]) -> ByteBuffer {
    ByteBuffer(bytes: MySQLWireFixtures.frame(sequence: sequence, payload))
  }

  static func outbound(_ channel: EmbeddedChannel) throws -> [[UInt8]] {
    var buffers: [[UInt8]] = []
    while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
      buffers.append(Array(buffer.readableBytesView))
    }
    return buffers
  }

  static func inbound(_ channel: EmbeddedChannel) throws -> [UInt8] {
    var bytes: [UInt8] = []
    while let buffer = try channel.readInbound(as: ByteBuffer.self) {
      bytes += buffer.readableBytesView
    }
    return bytes
  }

  /// A TLS server end with the throwaway certificate; the MySQL side is scripted by the test.
  static func tlsServer() throws -> EmbeddedChannel {
    let certificate = try NIOSSLCertificate(
      bytes: Array(MySQLWireFixtures.serverCertificatePEM.utf8), format: .pem)
    let key = try NIOSSLPrivateKey(
      bytes: Array(MySQLWireFixtures.serverPrivateKeyPEM.utf8), format: .pem)
    let context = try NIOSSLContext(
      configuration: .makeServerConfiguration(
        certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)))
    let server = EmbeddedChannel()
    try server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
    try server.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 50_000)).wait()
    return server
  }

  /// Moves bytes both ways until `done` holds for what the server read (decrypted), then for a
  /// short quiet period, and returns what the server read. It polls: here the client's answer
  /// to the server's handshake flight shows up only some milliseconds after the write that
  /// delivered the flight (observed with TLS 1.2 and 1.3), not within it.
  static func shuttle(
    _ client: EmbeddedChannel, _ server: EmbeddedChannel, until done: ([UInt8]) -> Bool
  ) throws -> [UInt8] {
    let deadline = Date().addingTimeInterval(5)
    var quietSince = Date()
    var received: [UInt8] = []
    while Date() < deadline {
      client.embeddedEventLoop.run()
      server.embeddedEventLoop.run()
      var moved = false
      while let bytes = try client.readOutbound(as: ByteBuffer.self) {
        try server.writeInbound(bytes)
        moved = true
      }
      while let bytes = try server.readOutbound(as: ByteBuffer.self) {
        try client.writeInbound(bytes)
        moved = true
      }
      received += try inbound(server)
      if moved {
        quietSince = Date()
      } else if done(received), Date().timeIntervalSince(quietSince) > 0.2 {
        return received
      }
      usleep(2_000)
    }
    return received
  }

  static func isClosed(_ error: (any Error)?) -> Bool {
    guard case .closed? = error as? MySQLError else { return false }
    return true
  }

  static func isPublicKeyRetrievalNotAllowed(_ error: (any Error)?) -> Bool {
    guard case .publicKeyRetrievalNotAllowed? = error as? MySQLError else { return false }
    return true
  }

  static func isUnsupportedAuthPlugin(_ error: (any Error)?, name: String) -> Bool {
    guard case .unsupportedAuthPlugin(let plugin)? = error as? MySQLError else { return false }
    return plugin == name
  }

  /// A server byte stream, cut into reads, that the armed guard must refuse; `forwarded` is
  /// what the fork may see of it.
  struct RefusedScript: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let chunks: [[UInt8]]
    let forwarded: [UInt8]
    var reason: FullAuthRefusal.Reason = .fullAuthentication

    static let all: [RefusedScript] = {
      let greeting = MySQLWireFixtures.frame(sequence: 0, MySQLWireFixtures.greeting(ssl: false))
      let fullAuth = MySQLWireFixtures.frame(
        sequence: 2, MySQLWireFixtures.performFullAuthentication)
      let trailing = MySQLWireFixtures.frame(sequence: 2, [0x01, 0x04, 0x00])
      let fastAuth = MySQLWireFixtures.frame(sequence: 2, MySQLWireFixtures.fastAuthSuccess)
      let fullAuthAfterFast = MySQLWireFixtures.frame(
        sequence: 3, MySQLWireFixtures.performFullAuthentication)
      // An allowed switch the fork would join with the next frame: a 0x00 continuation would
      // look like OK to a guard that classifies frames, the fork would answer the switch.
      let oversizedSwitch = MySQLWireFixtures.frame(
        sequence: 2,
        MySQLWireFixtures.padded(
          MySQLWireFixtures.authSwitchRequest(plugin: "caching_sha2_password")))
      let fullAuthAfterSwitch = MySQLWireFixtures.frame(
        sequence: 4, MySQLWireFixtures.performFullAuthentication)
      return [
        .init(
          testDescription: "0x00 continuation of an oversized switch",
          chunks: [
            greeting, oversizedSwitch, MySQLWireFixtures.frame(sequence: 3, [0x00]),
            fullAuthAfterSwitch,
          ],
          forwarded: greeting, reason: .oversizedFrame),
        .init(
          testDescription: "empty continuation of an oversized switch",
          chunks: [
            greeting, oversizedSwitch, MySQLWireFixtures.frame(sequence: 3, []),
            fullAuthAfterSwitch,
          ],
          forwarded: greeting, reason: .oversizedFrame),
        .init(
          testDescription: "trailing byte after 0x04", chunks: [greeting, trailing],
          forwarded: greeting),
        .init(
          testDescription: "0x04 after fast_auth_success",
          chunks: [greeting, fastAuth, fullAuthAfterFast], forwarded: greeting + fastAuth),
        .init(
          testDescription: "0x04 in the greeting's read", chunks: [greeting + fullAuth],
          forwarded: greeting),
        .init(
          testDescription: "header in the greeting's read",
          chunks: [greeting + trailing.prefix(2), Array(trailing.dropFirst(2))],
          forwarded: greeting),
        .init(
          testDescription: "one byte per read", chunks: [greeting] + trailing.map { [$0] },
          forwarded: greeting),
      ]
    }()
  }
}
