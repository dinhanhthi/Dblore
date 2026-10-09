// SSHTunnel.swift
// One SSH connection (swift-nio-ssh) that opens direct-tcpip child channels. A child
// channel carries plain bytes, so PostgresNIO can use it as an established channel; no
// local listener is involved. Closing the SSH connection closes every child channel.

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// How the SSH user authenticates. RSA keys cannot be represented: swift-nio-ssh has no RSA type.
nonisolated enum SSHTunnelAuthentication: Sendable {
  case password(String)
  case privateKey(NIOSSHPrivateKey)
}

/// Called on every key exchange (the first one and each re-key) with the server host key and
/// its OpenSSH-style SHA256 fingerprint. Throw to reject the key; returning trusts it.
typealias SSHHostKeyValidator =
  @Sendable (_ hostKey: NIOSSHPublicKey, _ fingerprint: String) async throws -> Void

nonisolated enum SSHTunnelError: Error, Equatable, LocalizedError {
  case unsupportedHostKeyAlgorithm
  case authenticationFailed
  case hostKeyRejected
  case channelOpenRejected
  case closedBeforeReady
  case invalidChannelData
  case handshakeTimedOut
  case hostKeyFingerprintUnavailable
  case closedWhileConfirmingHostKey

  /// Maps the swift-nio-ssh errors that have a clearer meaning for the user.
  init?(sshErrorType: NIOSSHError.ErrorType) {
    switch sshErrorType {
    // swift-nio-ssh reports no diagnostics here. With OpenSSH servers the usual cause is a
    // host key type it does not implement (RSA), since ciphers and kex overlap.
    case .keyExchangeNegotiationFailure: self = .unsupportedHostKeyAlgorithm
    case .channelSetupRejected: self = .channelOpenRejected
    default: return nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .unsupportedHostKeyAlgorithm:
      "The SSH server offers no supported host key algorithm. RSA host keys are not supported; "
        + "the server likely only has an RSA host key. Use an ed25519 or ECDSA host key."
    case .authenticationFailed:
      "SSH authentication failed. Check the SSH user name and password or key."
    case .hostKeyRejected:
      "The SSH server host key was not trusted."
    case .channelOpenRejected:
      "The SSH server refused to forward the connection to the database host."
    case .closedBeforeReady:
      "The SSH connection closed before it was ready."
    case .invalidChannelData:
      "The SSH tunnel received unexpected data."
    case .handshakeTimedOut:
      "The SSH server did not complete the handshake in time."
    case .hostKeyFingerprintUnavailable:
      "The SSH server host key could not be read."
    case .closedWhileConfirmingHostKey:
      "The SSH server closed the connection while waiting for confirmation."
    }
  }

  /// Returns the mapped error when there is one, otherwise the original error.
  static func mapped(_ error: any Error) -> any Error {
    if let sshError = error as? NIOSSHError,
      let mapped = SSHTunnelError(sshErrorType: sshError.type)
    {
      return mapped
    }
    return error
  }
}

/// What a PostgreSQL session needs from a tunnel. `SSHTunnel` in production; tests use fakes.
nonisolated protocol SSHTunneling: Sendable {
  func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> any Channel
  /// Idempotent. Closes every channel opened through the tunnel, then its owned event loop.
  func close() async
}

nonisolated final class SSHTunnel: SSHTunneling, @unchecked Sendable {
  /// The TCP channel that carries the SSH session.
  let parentChannel: any Channel

  private let ownedGroup: EventLoopGroup?
  private let hostKeyDelegate: SSHHostKeyDelegate
  private let lock = NSLock()
  private var children: [ObjectIdentifier: any Channel] = [:]
  private var closed = false
  /// Opens between the isClosed check and child registration. close() waits for them before
  /// shutting the owned loop down, since work submitted to a shut-down loop is dropped.
  private var inFlightOpens = 0
  private var opensDrained: CheckedContinuation<Void, Never>?

  /// True once `close()` has started.
  var isClosed: Bool { lock.withLock { closed } }

  private init(
    parentChannel: any Channel, ownedGroup: EventLoopGroup?, hostKeyDelegate: SSHHostKeyDelegate
  ) {
    self.parentChannel = parentChannel
    self.ownedGroup = ownedGroup
    self.hostKeyDelegate = hostKeyDelegate
  }

  /// Connects and authenticates. Pass a `group` to share one; otherwise the tunnel owns a
  /// single-thread group and shuts it down in `close()`.
  /// `connectTimeout` bounds the TCP connect; `handshakeTimeout` bounds everything after it
  /// (key exchange, user auth) except the host-key validator: the deadline is paused while it
  /// runs, since it may wait for the user (TOFU sheet). A server that gives up meanwhile
  /// (sshd LoginGraceTime) closes the connection, which cancels the validator.
  static func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, group: EventLoopGroup? = nil,
    connectTimeout: TimeAmount = .seconds(10), handshakeTimeout: TimeAmount = .seconds(30)
  ) async throws -> SSHTunnel {
    let ownedGroup: EventLoopGroup? =
      group == nil ? MultiThreadedEventLoopGroup(numberOfThreads: 1) : nil
    let loop = (group ?? ownedGroup!).next()
    let ready = loop.makePromise(of: Void.self)
    let deadline = SSHHandshakeDeadline(handshakeTimeout)
    let hostKeyDelegate = SSHHostKeyDelegate { key, fingerprint in
      deadline.pause()
      defer { deadline.resume() }
      try await hostKeyValidator(key, fingerprint)
    }
    let bootstrap = ClientBootstrap(group: loop)
      .connectTimeout(connectTimeout)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let configuration = SSHClientConfiguration(
            userAuthDelegate: SSHUserAuthDelegate(
              username: username, authentication: authentication),
            serverAuthDelegate: hostKeyDelegate)
          let sync = channel.pipeline.syncOperations
          try sync.addHandler(
            NIOSSHHandler(
              role: .client(configuration), allocator: channel.allocator,
              inboundChildChannelInitializer: nil))
          try sync.addHandler(SSHSessionReadyHandler(ready: ready))
        }
      }

    do {
      let channel = try await bootstrap.connect(host: host, port: port).get()
      // NIO futures ignore task cancellation, so a silent server would hang connect forever.
      // Fail `ready` before closing: the close would otherwise fail it as closedBeforeReady.
      deadline.arm(on: loop) {
        ready.fail(SSHTunnelError.handshakeTimedOut)
        hostKeyDelegate.cancel()
        channel.close(promise: nil)
      }
      ready.futureResult.whenComplete { _ in deadline.finish() }
      do {
        // A cancelled connect withdraws its trust sheet: the validator runs in its own task,
        // so only `cancel()` reaches it, and it never pins.
        try await withTaskCancellationHandler {
          try await ready.futureResult.get()
        } onCancel: {
          ready.fail(CancellationError())
          hostKeyDelegate.cancel()
          channel.close(promise: nil)
        }
        // Cancelled after the handshake succeeded: the caller no longer wants the tunnel.
        try Task.checkCancellation()
      } catch {
        try? await channel.close()
        throw error
      }
      return SSHTunnel(
        parentChannel: channel, ownedGroup: ownedGroup, hostKeyDelegate: hostKeyDelegate)
    } catch {
      ready.fail(error)
      deadline.finish()
      // Still validating: the deadline is paused and auth has not begun, so any failure now
      // means the server hung up while the user was asked to confirm its key.
      // A user cancel also ends a pending validation; it is not the server hanging up.
      let cancelled = Task.isCancelled || error is CancellationError
      let closedWhileConfirming = hostKeyDelegate.isValidating && !cancelled
      // A validator still running would complete its promise on the shut-down loop.
      hostKeyDelegate.cancel()
      try? await ownedGroup?.shutdownGracefully()
      if closedWhileConfirming { throw SSHTunnelError.closedWhileConfirmingHostKey }
      throw SSHTunnelError.mapped(error)
    }
  }

  /// Opens a direct-tcpip channel to `targetHost:targetPort` as seen from the SSH server.
  /// The returned channel reads and writes `ByteBuffer`.
  func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> any Channel {
    // After close() the owned event loop may be shut down; a task submitted to it never runs.
    // Counting the open under the same lock keeps the loop alive until it is registered.
    let started = lock.withLock {
      guard !closed else { return false }
      inFlightOpens += 1
      return true
    }
    guard started else { throw SSHTunnelError.closedBeforeReady }
    defer { finishOpen() }
    let parent = parentChannel
    let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
    let child: any Channel
    do {
      child = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
        let promise = parent.eventLoop.makePromise(of: (any Channel).self)
        do {
          let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
          let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
          ssh.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { child, _ in
            child.eventLoop.makeCompletedFuture {
              // EOF must reach the adapter; see SSHChannelDataAdapter.
              try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
              try child.pipeline.syncOperations.addHandler(SSHChannelDataAdapter())
            }
          }
        } catch {
          promise.fail(error)
        }
        return promise.futureResult
      }.get()
    } catch {
      // A close() racing this open surfaces as a NIO error; report it as the close.
      if lock.withLock({ closed }) { throw SSHTunnelError.closedBeforeReady }
      throw SSHTunnelError.mapped(error)
    }

    let id = ObjectIdentifier(child)
    let accepted = lock.withLock {
      guard !closed else { return false }
      children[id] = child
      return true
    }
    guard accepted else {
      // Not awaited: the closing parent tears it down; this only has to be enqueued in time.
      child.close(promise: nil)
      throw SSHTunnelError.closedBeforeReady
    }
    child.closeFuture.whenComplete { [weak self] _ in
      guard let self else { return }
      self.lock.withLock { _ = self.children.removeValue(forKey: id) }
    }
    return child
  }

  private func finishOpen() {
    let drained: CheckedContinuation<Void, Never>? = lock.withLock {
      inFlightOpens -= 1
      guard inFlightOpens == 0 else { return nil }
      defer { opensDrained = nil }
      return opensDrained
    }
    drained?.resume()
  }

  /// Returns once no open is in flight. Only the first close() calls this.
  private func waitForOpens() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let idle = lock.withLock {
        guard inFlightOpens > 0 else { return true }
        opensDrained = continuation
        return false
      }
      if idle { continuation.resume() }
    }
  }

  /// Closes the SSH connection, waits for its child channels to close, then shuts down the
  /// owned event-loop group. Closing a child first would wait for the peer's CHANNEL_CLOSE,
  /// which never comes on a dead link; closing the parent tears the children down locally.
  /// Child `closeFuture`s (e.g. a PostgresConnection's) have fired when this returns.
  /// An open racing this call either throws `closedBeforeReady` or returns a closed channel.
  func close() async {
    let first = lock.withLock {
      defer { closed = true }
      return !closed
    }
    guard first else { return }
    try? await parentChannel.close()
    // Opens in flight end once the parent is closed (swift-nio-ssh fails pending children).
    await waitForOpens()
    let open = lock.withLock {
      defer { children.removeAll() }
      return Array(children.values)
    }
    for child in open {
      try? await child.closeFuture.get()
    }
    hostKeyDelegate.cancel()
    try? await ownedGroup?.shutdownGracefully()
  }

  /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64 of the SHA-256 of the key blob.
  /// Nil when the key cannot be serialized.
  static func fingerprint(of key: NIOSSHPublicKey) -> String? {
    let fields = String(openSSHPublicKey: key).split(separator: " ")
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
    let base64 = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
  }
}

/// Offers the configured credential once. A second request means the server rejected it,
/// so it fails instead of returning nil (nil leaves swift-nio-ssh waiting forever).
nonisolated final class SSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
  private let username: String
  private var pending: SSHTunnelAuthentication?

  init(username: String, authentication: SSHTunnelAuthentication) {
    self.username = username
    self.pending = authentication
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard let authentication = pending else {
      nextChallengePromise.fail(SSHTunnelError.authenticationFailed)
      return
    }
    pending = nil
    let offer: NIOSSHUserAuthenticationOffer.Offer
    switch authentication {
    case .password(let password) where availableMethods.contains(.password):
      offer = .password(.init(password: password))
    case .privateKey(let key) where availableMethods.contains(.publicKey):
      offer = .privateKey(.init(privateKey: key))
    default:
      nextChallengePromise.fail(SSHTunnelError.authenticationFailed)
      return
    }
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
  }
}

/// Runs the async validator off the event loop and completes the promise with its result.
/// `cancel()` (called before the loop shuts down) fails a pending validation and cancels its
/// task, so a late validator result never lands on a shut-down loop. Each promise is
/// completed exactly once: NIO traps on a promise that is dropped unfulfilled.
nonisolated final class SSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate,
  @unchecked Sendable
{
  private let validator: SSHHostKeyValidator
  private let lock = NSLock()
  private var pending: (promise: EventLoopPromise<Void>, task: Task<Void, Never>)?
  private var isCancelled = false

  init(validator: @escaping SSHHostKeyValidator) {
    self.validator = validator
  }

  func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>)
  {
    guard let fingerprint = SSHTunnel.fingerprint(of: hostKey) else {
      validationCompletePromise.fail(SSHTunnelError.hostKeyFingerprintUnavailable)
      return
    }
    let validator = validator
    lock.withLock {
      guard !isCancelled else {
        validationCompletePromise.fail(SSHTunnelError.closedBeforeReady)
        return
      }
      let task = Task {
        let result: Result<Void, any Error>
        do {
          try await validator(hostKey, fingerprint)
          result = .success(())
        } catch {
          result = .failure(error)
        }
        self.complete(validationCompletePromise, with: result)
      }
      pending = (validationCompletePromise, task)
    }
  }

  /// A validation is still running (e.g. waiting for the user).
  var isValidating: Bool { lock.withLock { pending != nil } }

  /// Fails the pending validation and cancels its validator. Later validations fail at once.
  func cancel() {
    lock.withLock {
      isCancelled = true
      guard let pending else { return }
      self.pending = nil
      pending.task.cancel()
      pending.promise.fail(SSHTunnelError.closedBeforeReady)
    }
  }

  /// Completes under the lock so cancel() cannot return while a completion is in progress.
  private func complete(_ promise: EventLoopPromise<Void>, with result: Result<Void, any Error>) {
    lock.withLock {
      guard let pending, pending.promise.futureResult === promise.futureResult else { return }
      self.pending = nil
      promise.completeWith(result)
    }
  }
}

/// The handshake timeout of `SSHTunnel.connect`. Paused while the host-key validator runs;
/// `resume()` re-arms it with the time that was left. A pause before `arm` (key exchange can
/// start before the connecting task schedules the timeout) defers it until `resume()`.
nonisolated final class SSHHandshakeDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: TimeAmount
  private var loop: (any EventLoop)?
  private var expire: (@Sendable () -> Void)?
  private var scheduled: Scheduled<Void>?
  private var armedAt: NIODeadline?
  private var pauses = 0
  private var finished = false

  init(_ timeout: TimeAmount) {
    remaining = timeout
  }

  func arm(on loop: any EventLoop, _ expire: @escaping @Sendable () -> Void) {
    lock.withLock {
      self.loop = loop
      self.expire = expire
      scheduleLocked()
    }
  }

  func pause() {
    lock.withLock {
      pauses += 1
      guard pauses == 1, let running = scheduled, let armedAt else { return }
      running.cancel()
      scheduled = nil
      let left = remaining - (NIODeadline.now() - armedAt)
      remaining = left > .nanoseconds(0) ? left : .nanoseconds(0)
    }
  }

  func resume() {
    lock.withLock {
      pauses -= 1
      scheduleLocked()
    }
  }

  /// The handshake completed or failed: the timeout never fires after this.
  /// Drops `expire` and `loop`: `expire` captures the host-key delegate, whose validator
  /// captures this deadline, so keeping it would leak both (and the channel) per connect.
  func finish() {
    lock.withLock {
      finished = true
      scheduled?.cancel()
      scheduled = nil
      expire = nil
      loop = nil
    }
  }

  private func scheduleLocked() {
    guard !finished, pauses == 0, scheduled == nil, let loop, let expire else { return }
    armedAt = .now()
    scheduled = loop.scheduleTask(in: remaining) { [weak self] in
      guard let self else { return }
      // A pause that raced this run already took the remaining time; it re-arms on resume.
      let fire = self.lock.withLock {
        guard !self.finished, self.pauses == 0 else { return false }
        self.finished = true
        return true
      }
      if fire { expire() }
    }
  }
}

/// Completes `ready` when user auth succeeds, or fails it on the first error or on close.
/// NIOSSHHandler does not forward channelInactive, so close is seen through handlerRemoved.
nonisolated final class SSHSessionReadyHandler: ChannelInboundHandler {
  typealias InboundIn = Any

  private let ready: EventLoopPromise<Void>

  init(ready: EventLoopPromise<Void>) {
    self.ready = ready
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent {
      ready.succeed(())
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    ready.fail(SSHTunnelError.mapped(error))
    context.close(promise: nil)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    ready.fail(SSHTunnelError.closedBeforeReady)
  }
}

/// Converts between the SSH child channel's `SSHChannelData` and plain `ByteBuffer`.
/// Also owns closing. An SSH child channel that already sent CHANNEL_CLOSE throws a protocol
/// violation on another close, and that happens when it closes itself on remote EOF and then
/// NIOSSL or PostgresNIO closes it too. So remote EOF (half-closure is enabled to see it)
/// becomes a close here, and only the first close is forwarded.
nonisolated final class SSHChannelDataAdapter: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  private var isClosing = false

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard message.type == .channel, case .byteBuffer(let buffer) = message.data else {
      context.fireErrorCaught(SSHTunnelError.invalidChannelData)
      return
    }
    context.fireChannelRead(wrapInboundOut(buffer))
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let event = event as? ChannelEvent, event == .inputClosed else {
      context.fireUserInboundEventTriggered(event)
      return
    }
    // Like a socket without half-closure: remote EOF closes the whole channel.
    close(context: context, mode: .all, promise: nil)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let buffer = unwrapOutboundIn(data)
    context.write(
      wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
  }

  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    guard mode == .all else {
      context.close(mode: mode, promise: promise)
      return
    }
    if isClosing {
      promise.map { context.channel.closeFuture.cascade(to: $0) }
      return
    }
    isClosing = true
    context.close(mode: mode, promise: promise)
  }
}
