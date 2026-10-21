// MySQLFullAuthGuardSpikeTests.swift
// Phase 3.1 spike: can the app keep mysql-nio from sending the real password in
// caching_sha2_password "full authentication" ([0x01, 0x04]) when the TLS mode does not verify
// the server, without changing the fork? The guard below is a prototype (production code comes
// in task 4.1): an inbound/outbound handler the app adds to the channel before
// `MySQLConnection.connect(over:)`. The fork appends its codec and connection handler at
// `.last` and puts NIOSSLClientHandler at `.first`, so the guard ends up after TLS (it reads
// decrypted packets) and before the packet decoder (the fork never sees what it drops).
// No server: the login runs over EmbeddedChannels with scripted packets.

import Foundation
import MySQLNIO
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing
import os

@testable import Dblore

@Suite(.serialized)
struct MySQLFullAuthGuardSpikeTests {
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
    let (channel, spy) = try Self.channel(guard: FullAuthGuard(armed: true, refusal: refusal))
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

  /// An OK does not disarm the guard; `disarm()`, run when the fork's login future succeeds (as
  /// the app does), does. After it a packet that looks like [0x01, 0x04] (a one-column text row
  /// holding 0x04, say) reaches the fork untouched; before it the guard would refuse it.
  @Test(arguments: [true, false])
  func lookalikeRowPassesOnlyAfterDisarm(disarmed: Bool) throws {
    let refusal = FullAuthRefusal()
    let fullAuthGuard = FullAuthGuard(armed: true, refusal: refusal)
    let (channel, spy) = try Self.channel(guard: fullAuthGuard)
    let login = Self.login(over: channel, tls: nil, disarming: disarmed ? fullAuthGuard : nil)

    try channel.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try Self.outbound(channel)
    // fast_auth_success and OK in one read.
    try channel.writeInbound(
      ByteBuffer(
        bytes: MySQLWireFixtures.frame(sequence: 2, MySQLWireFixtures.fastAuthSuccess)
          + MySQLWireFixtures.frame(sequence: 3, MySQLWireFixtures.ok)))
    let connection = try #require(try login.result?.get())

    let lookalike = MySQLWireFixtures.frame(
      sequence: 1, MySQLWireFixtures.performFullAuthentication)
    try channel.writeInbound(ByteBuffer(bytes: lookalike))

    if disarmed {
      #expect(spy.seen.last == lookalike)
      #expect(!refusal.refused)
    } else {
      #expect(!spy.seen.contains(lookalike))
      #expect(refusal.reason == .fullAuthentication)
    }
    // Disarmed, no command was waiting, so the fork closed on the stray packet; armed, the guard.
    #expect(connection.isClosed)
  }

  /// The fork reads only the status and command bytes of AuthMoreData, so any more-data packet
  /// but fast_auth_success is refused, however it is framed or split across reads.
  @Test(arguments: RefusedScript.all)
  func guardRefusesEveryOtherMoreDataPacket(script: RefusedScript) throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(guard: FullAuthGuard(armed: true, refusal: refusal))
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
  /// later chunk (an OK-looking [0x00, ...]) cannot change. The guard refuses such a frame on its
  /// header, here in the greeting phase, so no HandshakeResponse is written.
  @Test func guardRefusesAnOversizedGreetingOnItsHeader() throws {
    let refusal = FullAuthRefusal()
    let (channel, spy) = try Self.channel(guard: FullAuthGuard(armed: true, refusal: refusal))
    let login = Self.login(over: channel, tls: nil)

    let greeting = MySQLWireFixtures.frame(
      sequence: 0, MySQLWireFixtures.padded(MySQLWireFixtures.greeting(ssl: false)))
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
    let (channel, spy) = try Self.channel(guard: FullAuthGuard(armed: true, refusal: refusal))
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
    let (channel, _) = try Self.channel(guard: FullAuthGuard(armed: true, refusal: refusal))
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
  /// authentication with the password in cleartext inside the tunnel. With the guard the
  /// in-memory TLS server receives nothing after the handshake response. The guard reads the
  /// decrypted [0x01, 0x04], so it sits after NIOSSLClientHandler, which the fork put `.first`.
  @Test(arguments: [false, true])
  func unverifiedTLSFullAuth(guarded: Bool) throws {
    let refusal = FullAuthRefusal()
    let (client, spy) = try Self.channel(
      guard: guarded ? FullAuthGuard(armed: true, refusal: refusal) : nil)
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    let login = Self.login(over: client, tls: tls)

    try client.writeInbound(Self.packet(0, MySQLWireFixtures.greeting(ssl: true)))
    let sslRequest = try #require(try client.readOutbound(as: ByteBuffer.self))
    #expect(sslRequest.readableBytes == 4 + 32 && sslRequest.getInteger(at: 3) == UInt8(1))
    let pipeline = String(describing: client.pipeline)
    let tlsAt = try #require(pipeline.range(of: "NIOSSLClientHandler")).lowerBound
    let spyAt = try #require(pipeline.range(of: "InboundSpy")).lowerBound
    #expect(tlsAt < spyAt)
    if guarded {
      let guardAt = try #require(pipeline.range(of: "FullAuthGuard")).lowerBound
      #expect(tlsAt < guardAt && guardAt < spyAt)
    }

    let server = try Self.tlsServer()
    let response = try Self.shuttle(client, server) { !$0.isEmpty }
    #expect(response.count > 4 && response[3] == 2)  // HandshakeResponse41 after SSLRequest

    server.writeAndFlush(Self.packet(3, MySQLWireFixtures.performFullAuthentication), promise: nil)
    let afterResponse = try Self.shuttle(client, server) { !$0.isEmpty || refusal.refused }

    if guarded {
      #expect(afterResponse.isEmpty)
      #expect(refusal.reason == .fullAuthentication)
      #expect(!spy.seen.contains(MySQLWireFixtures.frame(sequence: 3, [0x01, 0x04])))
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
        Self.armsFullAuthGuard(tlsMode: mode, host: host, usesSSH: usesSSH) == armed,
        "\(mode.rawValue) \(host) ssh=\(usesSSH)")
    }
  }
}

// MARK: - Prototype (moves to production in task 4.1)

extension MySQLFullAuthGuardSpikeTests {
  /// Whether a MySQL login arms the full-authentication guard. Only Verify CA and Verify Full
  /// check the server's certificate; a direct connection to this Mac is exempt, but not the SSH
  /// forwarder's loopback address (decided from the connection settings, not the socket).
  static func armsFullAuthGuard(tlsMode: SSLMode, host: String, usesSSH: Bool) -> Bool {
    switch tlsMode {
    case .verifyCa, .verifyFull: return false
    case .disable, .allow, .prefer, .require: break
    }
    if usesSSH { return true }
    return !["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
  }

  /// Set once the guard refused a login packet, with why: the login error is then `.closed`, so
  /// the reason is what tells the user what the server asked for.
  final class FullAuthRefusal: Sendable {
    enum Reason: Equatable, Sendable {
      /// An AuthMoreData packet other than fast_auth_success (perform_full_authentication).
      case fullAuthentication
      /// An auth switch to a plugin outside the allow-list.
      case authSwitch(plugin: String)
      /// A frame of 0xFFFFFF bytes, which the fork would join with the frames after it.
      case oversizedFrame
    }

    private let state = OSAllocatedUnfairLock<Reason?>(initialState: nil)
    var reason: Reason? { state.withLock { $0 } }
    var refused: Bool { reason != nil }
    func record(_ reason: Reason) { state.withLock { $0 = $0 ?? reason } }
  }

  /// Frames the server's login packets (3-byte little-endian length, 1-byte sequence) and, while
  /// armed, allow-lists them: an AuthMoreData packet (0x01) passes only as exactly [0x01, 0x03]
  /// (fast_auth_success), and an auth switch request (0xFE) only to caching_sha2_password or
  /// mysql_native_password. The fork reads just the status and command bytes of AuthMoreData,
  /// so matching [0x01, 0x04] alone would let [0x01, 0x04, ...] through; and the app always
  /// passes `allowPublicKeyRetrieval: false`, so no legitimate login more-data packet other than
  /// [0x01, 0x03] exists. OK (0x00), ERR (0xFF) and the greeting pass.
  ///
  /// The guard sees wire frames, but the fork's decoder joins a frame of 0xFFFFFF bytes with the
  /// frames after it into one message that the first frame's first byte classifies. So, while
  /// armed, a 0xFFFFFF-byte frame is refused on its header (no greeting or login packet comes
  /// near 16 MiB), and no byte the guard reads ends the login: only the fork knows when it is
  /// over. The guard stays armed until the caller runs `disarm()` once the fork's login future
  /// succeeded, before the first command, so query results are never inspected.
  ///
  /// A refused packet is dropped: the guard records the reason and closes the channel from its
  /// own position, so the close skips the fork's handler (which would write a COM_QUIT), and
  /// drops every later write.
  final class FullAuthGuard: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase { case greeting, authentication, passthrough, refused }
    private static let fastAuthSuccess: [UInt8] = [0x01, 0x03]
    private static let switchablePlugins = ["caching_sha2_password", "mysql_native_password"]
    /// A frame this long continues in the next one.
    private static let continuedLength = 0xFF_FF_FF

    private var phase: Phase
    private var pending = ByteBuffer()
    private var context: ChannelHandlerContext?
    private var forwarding = false
    private let refusal: FullAuthRefusal

    init(armed: Bool, refusal: FullAuthRefusal) {
      self.phase = armed ? .greeting : .passthrough
      self.refusal = refusal
    }

    /// Stops inspecting packets. Call it on the channel's event loop once the fork's login
    /// future succeeded; it forwards what the guard still holds. No effect after a refusal.
    func disarm() {
      guard let context else { return }
      context.eventLoop.preconditionInEventLoop()
      guard phase == .greeting || phase == .authentication else { return }
      phase = .passthrough
      if !forwarding { forwardPending(context: context) }
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      switch phase {
      case .passthrough:
        context.fireChannelRead(data)
      case .refused:
        break
      case .greeting, .authentication:
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        forwardLoginPackets(context: context)
      }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
      guard phase != .refused else {
        promise?.fail(ChannelError.ioOnClosedChannel)
        return
      }
      context.write(data, promise: promise)
    }

    private func forwardLoginPackets(context: ChannelHandlerContext) {
      forwarding = true
      defer { forwarding = false }
      while phase == .greeting || phase == .authentication,
        let header = pending.getBytes(at: pending.readerIndex, length: 4)
      {
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
        guard length != Self.continuedLength else {
          refuse(.oversizedFrame, context: context)
          return
        }
        guard let packet = pending.readSlice(length: 4 + length) else { break }
        if phase == .greeting {
          phase = .authentication
        } else if let reason = Self.refusalReason(Array(packet.readableBytesView.dropFirst(4))) {
          refuse(reason, context: context)
          return
        }
        context.fireChannelRead(wrapInboundOut(packet))
      }
      forwardPending(context: context)
    }

    /// Once disarmed, hands the bytes still held to the fork; while armed, keeps them.
    private func forwardPending(context: ChannelHandlerContext) {
      if phase == .passthrough, pending.readableBytes > 0 {
        let rest = pending
        pending = ByteBuffer()
        context.fireChannelRead(wrapInboundOut(rest))
      } else {
        pending.discardReadBytes()
      }
    }

    private static func refusalReason(_ payload: [UInt8]) -> FullAuthRefusal.Reason? {
      switch payload.first {
      case 0x01:
        return payload == fastAuthSuccess ? nil : .fullAuthentication
      case 0xFE:
        let name = payload.dropFirst().prefix { $0 != 0 }
        let plugin = String(decoding: name, as: UTF8.self)
        guard name.endIndex < payload.endIndex, switchablePlugins.contains(plugin) else {
          return .authSwitch(plugin: plugin)
        }
        return nil
      default:
        return nil
      }
    }

    private func refuse(_ reason: FullAuthRefusal.Reason, context: ChannelHandlerContext) {
      phase = .refused
      pending.clear()
      refusal.record(reason)
      context.close(mode: .all, promise: nil)
    }
  }

  /// Records what the guard forwarded to the fork's decoder.
  final class InboundSpy: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    var seen: [[UInt8]] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      seen.append(Array(unwrapInboundIn(data).readableBytesView))
      context.fireChannelRead(data)
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
}

// MARK: - Helpers

extension MySQLFullAuthGuardSpikeTests {
  /// An active channel with the guard (if any) and the spy in front, as the app's bootstrap
  /// initializer would leave it before `connect(over:)` appends the fork's handlers.
  static func channel(guard fullAuthGuard: FullAuthGuard?) throws -> (EmbeddedChannel, InboundSpy) {
    let channel = EmbeddedChannel()
    let spy = InboundSpy()
    if let fullAuthGuard { try channel.pipeline.syncOperations.addHandler(fullAuthGuard) }
    try channel.pipeline.syncOperations.addHandler(spy)
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3306)).wait()
    return (channel, spy)
  }

  /// Starts the fork's login; `disarming` is disarmed when it succeeds, as the app will do.
  static func login(
    over channel: EmbeddedChannel, tls: TLSConfiguration?, disarming: FullAuthGuard? = nil
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
