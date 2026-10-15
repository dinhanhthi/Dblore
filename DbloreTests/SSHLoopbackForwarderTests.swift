// SSHLoopbackForwarderTests.swift
// SSHLoopbackForwarder over an EchoSSHTunnel (no SSH): TCP client -> forwarder on 127.0.0.1 ->
// a tunnel channel to an in-process echo server -> back to the client.

import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import Dblore

@Suite("SSH loopback forwarder", .timeLimit(.minutes(1)))
struct SSHLoopbackForwarderTests {
  @Test func bytesRoundTripThroughOnePausedTunnelChannel() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db.internal", targetPort: 3306)
    let client = try await ForwarderClient.connect(port: forwarder.localPort)

    try await client.send("ping")
    #expect(await client.receive(count: 4) == Array("ping".utf8))
    #expect(tunnel.opens == [.init(host: "db.internal", port: 3306, autoRead: false)])

    // The client closing closes its tunnel channel.
    try await client.channel.close()
    let channel = try #require(tunnel.channels.first)
    #expect(await eventually { !channel.isActive })

    await forwarder.stop()
    await tunnel.close()
  }

  @Test func eachAcceptedConnectionGetsItsOwnTunnelChannel() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    var clients: [ForwarderClient] = []
    for _ in 0..<3 {
      clients.append(try await ForwarderClient.connect(port: forwarder.localPort))
    }

    for (index, client) in clients.enumerated() {
      try await client.send("client-\(index)")
    }
    for (index, client) in clients.enumerated() {
      #expect(await client.receive(count: 8) == Array("client-\(index)".utf8))
    }
    #expect(tunnel.opens.count == 3)
    #expect(Set(tunnel.channels.map(ObjectIdentifier.init)).count == 3)

    await forwarder.stop()
    await tunnel.close()
  }

  @Test func serverGreetingSentOnOpenIsNotLost() async throws {
    let tunnel = try await EchoSSHTunnel.start(greeting: "HELLO")
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)

    for _ in 0..<5 {
      let client = try await ForwarderClient.connect(port: forwarder.localPort)
      #expect(await client.receive(count: 5) == Array("HELLO".utf8))
      try await client.channel.close()
    }

    await forwarder.stop()
    await tunnel.close()
  }

  @Test func stopClosesListenerAndConnectionsAndIsIdempotent() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let client = try await ForwarderClient.connect(port: forwarder.localPort)
    try await client.send("x")
    #expect(await client.receive(count: 1) == Array("x".utf8))

    await forwarder.stop()
    #expect(await eventually { !client.channel.isActive })
    await #expect(throws: (any Error).self) {
      _ = try await ForwarderClient.connect(port: forwarder.localPort)
    }
    let channel = try #require(tunnel.channels.first)
    #expect(await eventually { !channel.isActive })
    await forwarder.stop()

    await tunnel.close()
  }

  /// A stopped forwarder's port is free for any local process: a client that read it dials it
  /// while the forwarder still holds it (and gets no forward once stopping), or not at all.
  @Test func stopWaitsForADialUnderWayThenRefusesDials() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let dial = Task {
      await forwarder.whileListening {
        enter.yield()
        for await _ in released { break }
        return try? await ForwarderClient.connect(port: forwarder.localPort)
      }
    }
    for await _ in entered { break }
    let stop = Task { await forwarder.stop() }
    try await Task.sleep(for: .milliseconds(200))
    release.yield()

    // The port was still the forwarder's, which closed the connection without a tunnel channel.
    let client = try #require(await dial.value ?? nil)
    #expect(await eventually { !client.channel.isActive })
    await stop.value
    #expect(tunnel.opens.isEmpty)
    #expect(await forwarder.whileListening { true } == nil)

    await tunnel.close()
  }

  @Test func tunnelCloseClosesConnectionsAndStopsAccepting() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let client = try await ForwarderClient.connect(port: forwarder.localPort)
    try await client.send("x")
    #expect(await client.receive(count: 1) == Array("x".utf8))

    await tunnel.close()
    #expect(await eventually { !client.channel.isActive })
    #expect(
      await eventually {
        (try? await ForwarderClient.connect(port: forwarder.localPort)) == nil
      })

    await forwarder.stop()
  }

  @Test func failureToOpenTheTunnelChannelClosesTheConnection() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    tunnel.openError = SSHTunnelError.channelOpenRejected
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let client = try await ForwarderClient.connect(port: forwarder.localPort)

    #expect(await eventually { !client.channel.isActive })
    #expect(tunnel.opens.count == 1)

    await forwarder.stop()
    await tunnel.close()
  }

  /// Any local process can reach the port: beyond the cap a connection is closed without a
  /// tunnel channel, and a closed connection frees its slot.
  @Test func connectionsBeyondTheCapAreClosedWithoutATunnelChannel() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let cap = SSHLoopbackForwarder.maxConnections
    var clients: [ForwarderClient] = []
    // Each round trip proves the forwarder registered that connection before the next one.
    for index in 0..<cap {
      let client = try await ForwarderClient.connect(port: forwarder.localPort)
      try await client.send("\(index % 10)")
      #expect(await client.receive(count: 1) == Array("\(index % 10)".utf8))
      clients.append(client)
    }

    let extra = try await ForwarderClient.connect(port: forwarder.localPort)
    #expect(await eventually { !extra.channel.isActive })
    #expect(tunnel.opens.count == cap)

    try await clients[0].channel.close()
    #expect(
      await eventually(within: 10) {
        guard let client = try? await ForwarderClient.connect(port: forwarder.localPort),
          (try? await client.send("y")) != nil
        else { return false }
        defer { client.channel.close(promise: nil) }
        return await client.receive(count: 1, within: 1) == Array("y".utf8)
      })
    #expect(tunnel.opens.count == cap + 1)

    await forwarder.stop()
    await tunnel.close()
  }

  @Test func listensOnLoopbackOnly() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)

    // Every non-loopback IPv4 address of this Mac refuses the forwarder's port.
    let external = try System.enumerateDevices().compactMap { device -> String? in
      guard let address = device.address, case .v4 = address, let ip = address.ipAddress,
        !ip.hasPrefix("127.")
      else { return nil }
      return ip
    }
    for ip in Set(external) {
      let address = try SocketAddress(ipAddress: ip, port: forwarder.localPort)
      await #expect(throws: (any Error).self, "reachable on \(ip)") {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
          .connectTimeout(.seconds(2))
          .connect(to: address)
          .get()
        try? await channel.close()
      }
    }
    let local = try await ForwarderClient.connect(port: forwarder.localPort)
    try await local.channel.close()

    await forwarder.stop()
    await tunnel.close()
  }

  /// The client writes everything before it reads anything, so the forwarder's side of the
  /// client connection becomes unwritable and reading from the tunnel channel must pause, then
  /// resume once the client drains it.
  @Test func largePayloadArrivesIntact() async throws {
    let tunnel = try await EchoSSHTunnel.start()
    let forwarder = try await SSHLoopbackForwarder.start(
      tunnel: tunnel, targetHost: "db", targetPort: 3306)
    let client = try await ForwarderClient.connect(port: forwarder.localPort, autoRead: false)
    let payload = (0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 12) }

    let sent = client.channel.eventLoop.makePromise(of: Void.self)
    client.channel.writeAndFlush(ByteBuffer(bytes: payload), promise: sent)
    try await Task.sleep(for: .milliseconds(300))
    try await client.channel.setOption(ChannelOptions.autoRead, value: true).get()
    client.channel.read()

    let received = await client.receive(count: payload.count, within: 30)
    try await sent.futureResult.get()
    #expect(received.count == payload.count)
    #expect(received == payload)

    await forwarder.stop()
    await tunnel.close()
  }

  /// Polls `condition` every 10 ms for up to `seconds`.
  private func eventually(
    within seconds: Double = 5, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }
}

/// A TCP client of the forwarder that collects every byte it receives.
private final class ForwarderClient: Sendable {
  let channel: any Channel
  private let inbox: Inbox

  private init(channel: any Channel, inbox: Inbox) {
    self.channel = channel
    self.inbox = inbox
  }

  static func connect(port: Int, autoRead: Bool = true) async throws -> ForwarderClient {
    let inbox = Inbox()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(.seconds(5))
      .channelOption(ChannelOptions.autoRead, value: autoRead)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(Collector(inbox: inbox))
        }
      }
      .connect(host: "127.0.0.1", port: port)
      .get()
    return ForwarderClient(channel: channel, inbox: inbox)
  }

  func send(_ text: String) async throws {
    try await channel.writeAndFlush(ByteBuffer(string: text)).get()
  }

  /// What arrived once `count` bytes are in, or after `seconds`.
  func receive(count: Int, within seconds: Double = 5) async -> [UInt8] {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while inbox.count < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return inbox.bytes
  }
}

private final class Inbox: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [UInt8] = []

  var bytes: [UInt8] { lock.withLock { received } }
  var count: Int { lock.withLock { received.count } }

  func append(_ buffer: ByteBuffer) {
    lock.withLock { received.append(contentsOf: buffer.readableBytesView) }
  }
}

private final class Collector: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let inbox: Inbox

  init(inbox: Inbox) {
    self.inbox = inbox
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    inbox.append(unwrapInboundIn(data))
  }
}
