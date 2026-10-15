// SSHLoopbackForwarder.swift
// A listener on 127.0.0.1:<ephemeral port> for clients that can only connect to a host and port
// (mysql-nio with TLS). Each accepted connection gets its own direct-tcpip channel of an
// `SSHTunneling` and bytes are copied both ways, with backpressure: when one side cannot take
// more, reading from the other pauses until it can. Either side closing closes the other.
//
// Shape proven in SSHChannelSpikeTests (phase 2.5): the tunnel channel is opened from the
// accepted channel's `channelActive` (inside the child initializer the accepted channel is not
// registered yet, so a greeting written to it would be dropped) and opened paused, so a server
// that speaks first (MySQL) keeps its greeting buffered until the glue is in place.

import Foundation
import NIOCore
import NIOPosix

nonisolated final class SSHLoopbackForwarder: Sendable {
  /// Accepted connections open at once; beyond it a connection is closed without a tunnel
  /// channel. Any local process can reach the port, and each connection would otherwise open a
  /// channel on the bastion. A MySQL session needs two at most (the session and a KILL QUERY
  /// control connection); the rest is margin for retries whose closed connections are not
  /// released yet.
  static let maxConnections = 8

  /// The port the forwarder listens on, on 127.0.0.1.
  let localPort: Int
  private let state: SSHForwarderState

  private init(localPort: Int, state: SSHForwarderState) {
    self.localPort = localPort
    self.state = state
  }

  /// Listens on 127.0.0.1 (never another interface) and forwards every accepted connection to
  /// `targetHost:targetPort` through `tunnel`, which must already be connected. Stops by itself
  /// when the tunnel closes; otherwise call `stop()` before closing the tunnel.
  static func start(
    tunnel: any SSHTunneling, targetHost: String, targetPort: Int
  ) async throws -> SSHLoopbackForwarder {
    let state = SSHForwarderState()
    let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      // Nothing is read before the tunnel side is glued.
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            SSHForwardingConnector(
              tunnel: tunnel, targetHost: targetHost, targetPort: targetPort, state: state))
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    guard let port = listener.localAddress?.port else {
      try? await listener.close()
      throw ChannelError.unknownLocalAddress
    }
    state.setListener(listener)
    tunnel.whenClosed {
      Task { await state.stop() }
    }
    return SSHLoopbackForwarder(localPort: port, state: state)
  }

  /// Closes the listener and every accepted connection (after any `whileListening` dial under
  /// way returned), and returns once they are closed.
  /// Their tunnel channels are closed too but not awaited: on a dead SSH link they only finish
  /// when the tunnel closes. Idempotent; a second call waits for the first.
  func stop() async {
    await state.stop()
  }

  /// Runs `dial` (a client connecting to `localPort`) unless the forwarder is stopping; nil
  /// then. Once stopped, the port is free for any local process to bind, so a client that read
  /// it earlier must not dial it: `stop()` waits for `dial` to return before it releases the
  /// port, and refuses the connection meanwhile.
  func whileListening<T>(_ dial: () async throws -> T) async rethrows -> T? {
    guard state.beginDial() else { return nil }
    defer { state.endDial() }
    return try await dial()
  }
}

/// The listener and the accepted connections, shared by the forwarder, its connectors and the
/// tunnel-close observer.
nonisolated final class SSHForwarderState: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: (any Channel)?
  private var accepted: [ObjectIdentifier: any Channel] = [:]
  private var stopping: Task<Void, Never>?
  /// `whileListening` dials under way, and what waits for them to end.
  private var dials = 0
  private var dialsEnded: [CheckedContinuation<Void, Never>] = []

  func setListener(_ channel: any Channel) {
    let stopped = lock.withLock {
      listener = channel
      return stopping != nil
    }
    if stopped { channel.close(promise: nil) }
  }

  /// Tracks an accepted connection until it closes. False once stopping or with
  /// `SSHLoopbackForwarder.maxConnections` already open: the caller closes it.
  func register(_ channel: any Channel) -> Bool {
    let id = ObjectIdentifier(channel)
    let registered = lock.withLock {
      guard stopping == nil, accepted.count < SSHLoopbackForwarder.maxConnections else {
        return false
      }
      accepted[id] = channel
      return true
    }
    guard registered else { return false }
    channel.closeFuture.whenComplete { [weak self] _ in
      guard let self else { return }
      self.lock.withLock { _ = self.accepted.removeValue(forKey: id) }
    }
    return true
  }

  func stop() async {
    let task = lock.withLock { () -> Task<Void, Never> in
      if let stopping { return stopping }
      let listener = self.listener
      let channels = Array(accepted.values)
      let task = Task {
        await self.dialsDone()
        try? await listener?.close()
        for channel in channels {
          channel.close(promise: nil)
        }
        for channel in channels {
          try? await channel.closeFuture.get()
        }
      }
      stopping = task
      return task
    }
    await task.value
  }

  /// False once stopping. Pair with `endDial()`.
  func beginDial() -> Bool {
    lock.withLock {
      guard stopping == nil else { return false }
      dials += 1
      return true
    }
  }

  func endDial() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      dials -= 1
      guard dials == 0 else { return [] }
      defer { dialsEnded.removeAll() }
      return dialsEnded
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once no dial is under way (none starts once stopping).
  private func dialsDone() async {
    await withCheckedContinuation { continuation in
      let done = lock.withLock { () -> Bool in
        guard dials > 0 else { return true }
        dialsEnded.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }
}

/// Sits on an accepted connection (autoRead off) and, once it is active, opens its tunnel
/// channel paused, glues the two, then starts reading: the tunnel side first (releasing a
/// buffered greeting), then the client side. Any failure closes both.
nonisolated final class SSHForwardingConnector: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let tunnel: any SSHTunneling
  private let targetHost: String
  private let targetPort: Int
  private let state: SSHForwarderState

  init(tunnel: any SSHTunneling, targetHost: String, targetPort: Int, state: SSHForwarderState) {
    self.tunnel = tunnel
    self.targetHost = targetHost
    self.targetPort = targetPort
    self.state = state
  }

  func channelActive(context: ChannelHandlerContext) {
    let inbound = context.channel
    context.fireChannelActive()
    guard state.register(inbound) else {
      inbound.close(promise: nil)
      return
    }
    let (tunnel, targetHost, targetPort) = (self.tunnel, self.targetHost, self.targetPort)
    Task {
      await Self.connect(inbound, through: tunnel, to: targetHost, port: targetPort)
    }
  }

  private static func connect(
    _ inbound: any Channel, through tunnel: any SSHTunneling, to host: String, port: Int
  ) async {
    let outbound: any Channel
    do {
      outbound = try await tunnel.openDirectTCPIP(
        targetHost: host, targetPort: port, autoRead: false)
    } catch {
      inbound.close(promise: nil)
      return
    }
    do {
      try await glue(outbound, to: inbound)
      try await glue(inbound, to: outbound)
      try await outbound.setOption(ChannelOptions.autoRead, value: true).get()
      outbound.read()
      try await inbound.setOption(ChannelOptions.autoRead, value: true).get()
    } catch {
      inbound.close(promise: nil)
      outbound.close(promise: nil)
    }
  }

  /// Adds the glue that copies `channel`'s inbound bytes to `partner`.
  private static func glue(_ channel: any Channel, to partner: any Channel) async throws {
    try await channel.eventLoop.submit {
      try channel.pipeline.syncOperations.addHandler(SSHForwardingGlue(partner: partner))
    }.get()
  }
}

/// Copies this channel's inbound bytes to `partner` (the other side of the forward, possibly on
/// another event loop, so only the thread-safe `Channel` API is used on it). Backpressure: while
/// this channel is unwritable, `partner` (which writes into it) stops reading. When this
/// channel closes, `partner` is closed once the bytes already handed to it are written.
nonisolated final class SSHForwardingGlue: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let partner: any Channel
  private var lastWrite: EventLoopFuture<Void>?

  init(partner: any Channel) {
    self.partner = partner
  }

  func handlerAdded(context: ChannelHandlerContext) {
    // Closed before the glue was in place: no channelInactive will reach this handler.
    if !context.channel.isActive { partner.close(promise: nil) }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    lastWrite = partner.write(unwrapInboundIn(data))
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    partner.flush()
    context.fireChannelReadComplete()
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    let writable = context.channel.isWritable
    let partner = partner
    // A closed partner's event loop may already be shut down (a closed tunnel).
    if partner.isActive {
      partner.setOption(ChannelOptions.autoRead, value: writable).whenSuccess {
        if writable { partner.read() }
      }
    }
    context.fireChannelWritabilityChanged()
  }

  func channelInactive(context: ChannelHandlerContext) {
    let partner = partner
    partner.flush()
    if let lastWrite {
      lastWrite.whenComplete { _ in partner.close(promise: nil) }
    } else {
      partner.close(promise: nil)
    }
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}
