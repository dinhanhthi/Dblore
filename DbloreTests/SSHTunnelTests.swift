import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import Testing

@testable import Dblore

@Suite("SSH tunnel core")
struct SSHTunnelTests {
  @Test func fingerprintMatchesOpenSSHFormat() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey

    // OpenSSH hashes the key blob: string "ssh-ed25519" || string <32-byte key>.
    var blob = Data([0, 0, 0, 11])
    blob.append(contentsOf: Array("ssh-ed25519".utf8))
    blob.append(contentsOf: [0, 0, 0, 32])
    blob.append(privateKey.publicKey.rawRepresentation)
    let base64 = Data(SHA256.hash(data: blob)).base64EncodedString()
    let expected = "SHA256:" + base64.replacingOccurrences(of: "=", with: "")

    let fingerprint = try #require(SSHTunnel.fingerprint(of: publicKey))
    #expect(fingerprint == expected)
    #expect(fingerprint.count == "SHA256:".count + 43)
  }

  @Test func keyExchangeFailureMapsToUnsupportedHostKey() {
    let error = SSHTunnelError(sshErrorType: .keyExchangeNegotiationFailure)
    #expect(error == .unsupportedHostKeyAlgorithm)
    #expect(error?.errorDescription?.contains("RSA") == true)
  }

  @Test func channelRejectionMapsToChannelOpenRejected() {
    #expect(SSHTunnelError(sshErrorType: .channelSetupRejected) == .channelOpenRejected)
  }

  @Test func unrelatedSSHErrorIsNotMapped() {
    #expect(SSHTunnelError(sshErrorType: .invalidPacketFormat) == nil)
  }

  @Test func passwordIsOfferedOnceThenAuthenticationFails() throws {
    let loop = EmbeddedEventLoop()
    let delegate = SSHUserAuthDelegate(username: "dblore", authentication: .password("secret"))

    let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
    let offer = try #require(try first.futureResult.wait())
    #expect(offer.username == "dblore")
    guard case .password(let password) = offer.offer else {
      Issue.record("expected a password offer")
      return
    }
    #expect(password.password == "secret")

    let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
    #expect(throws: SSHTunnelError.authenticationFailed) { try second.futureResult.wait() }
  }

  @Test func authenticationFailsWhenServerDoesNotOfferTheMethod() {
    let loop = EmbeddedEventLoop()
    let delegate = SSHUserAuthDelegate(username: "dblore", authentication: .password("secret"))
    let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
    #expect(throws: SSHTunnelError.authenticationFailed) { try promise.futureResult.wait() }
  }

  @Test func privateKeyIsOfferedOnceThenAuthenticationFails() throws {
    let loop = EmbeddedEventLoop()
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let delegate = SSHUserAuthDelegate(username: "dblore", authentication: .privateKey(key))

    let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
    let offer = try #require(try first.futureResult.wait())
    #expect(offer.username == "dblore")
    guard case .privateKey(let offered) = offer.offer else {
      Issue.record("expected a private key offer")
      return
    }
    #expect(offered.privateKey.publicKey == key.publicKey)

    let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
    #expect(throws: SSHTunnelError.authenticationFailed) { try second.futureResult.wait() }
  }

  @Test func privateKeyFailsWhenServerDoesNotOfferPublicKey() {
    let loop = EmbeddedEventLoop()
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let delegate = SSHUserAuthDelegate(username: "dblore", authentication: .privateKey(key))
    let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: promise)
    #expect(throws: SSHTunnelError.authenticationFailed) { try promise.futureResult.wait() }
  }

  @Test func silentServerFailsWithHandshakeTimeout() async throws {
    // Accepts TCP and never sends an SSH banner: only the handshake timeout ends connect.
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
      .bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)

    let start = ContinuousClock.now
    await #expect(throws: SSHTunnelError.handshakeTimedOut) {
      _ = try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
        hostKeyValidator: { _, _ in }, handshakeTimeout: .milliseconds(300))
    }
    #expect(ContinuousClock.now - start < .seconds(5))

    try await server.close()
    try await group.shutdownGracefully()
  }

  @Test func cancellingHostKeyValidationFailsPromiseAndCancelsValidator() async throws {
    // A validator still running when the handshake times out must not complete its promise
    // later, on a loop that may be shut down; cancel() fails it now and cancels the task.
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let validatorCancelled = CompletionFlag()
    let delegate = SSHHostKeyDelegate { _, _ in
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        validatorCancelled.set()
      }
    }
    let promise = group.next().makePromise(of: Void.self)
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    delegate.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

    delegate.cancel()
    await #expect(throws: SSHTunnelError.closedBeforeReady) {
      try await promise.futureResult.get()
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while !validatorCancelled.isSet, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(validatorCancelled.isSet)

    // Validations after cancel fail at once instead of starting a validator.
    let late = group.next().makePromise(of: Void.self)
    delegate.validateHostKey(hostKey: hostKey, validationCompletePromise: late)
    await #expect(throws: SSHTunnelError.closedBeforeReady) { try await late.futureResult.get() }
    try await group.shutdownGracefully()
  }

  // The host-key delegate holds the caller's validator, so a validator capture outliving the
  // connect means the delegate (and the deadline, channel and loop around it) leaked.
  @Test func connectReleasesDelegateAfterClose() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await Self.sshServer(group: group, users: AcceptAllUsers())
    let port = try #require(server.localAddress?.port)
    let released = WeakSentinel()

    var tunnel: SSHTunnel? = try await SSHTunnel.connect(
      host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
      hostKeyValidator: released.validator())
    await tunnel?.close()
    tunnel = nil
    #expect(await released.isReleased())

    try await server.close()
    try await group.shutdownGracefully()
  }

  @Test func connectReleasesDelegateAfterFailure() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await Self.sshServer(group: group, users: DenyAllSSHUsers())
    let port = try #require(server.localAddress?.port)
    let released = WeakSentinel()

    await #expect(throws: SSHTunnelError.authenticationFailed) {
      _ = try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
        hostKeyValidator: released.validator())
    }
    #expect(await released.isReleased())

    try await server.close()
    try await group.shutdownGracefully()
  }

  @Test func connectReleasesDelegateAfterTimeout() async throws {
    // A server that delays its banner past the handshake timeout: the deadline fires.
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
      .bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let released = WeakSentinel()

    await #expect(throws: SSHTunnelError.handshakeTimedOut) {
      _ = try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore", authentication: .password("x"),
        hostKeyValidator: released.validator(), handshakeTimeout: .milliseconds(200))
    }
    #expect(await released.isReleased())

    try await server.close()
    try await group.shutdownGracefully()
  }

  private static func sshServer(
    group: EventLoopGroup, users: any NIOSSHServerUserAuthenticationDelegate & Sendable
  ) async throws -> any Channel {
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    return try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: users)),
              allocator: channel.allocator, inboundChildChannelInitializer: nil))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
  }

  @Test func adapterUnwrapsInboundChannelData() throws {
    let channel = EmbeddedChannel(handler: SSHChannelDataAdapter())
    var buffer = channel.allocator.buffer(capacity: 4)
    buffer.writeString("ping")
    try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    let read = try #require(try channel.readInbound(as: ByteBuffer.self))
    #expect(read == buffer)
    _ = try channel.finish()
  }

  @Test func adapterWrapsOutboundBytes() throws {
    let channel = EmbeddedChannel(handler: SSHChannelDataAdapter())
    var buffer = channel.allocator.buffer(capacity: 4)
    buffer.writeString("pong")
    try channel.writeOutbound(buffer)
    let written = try #require(try channel.readOutbound(as: SSHChannelData.self))
    #expect(written.type == .channel)
    #expect(written.data == .byteBuffer(buffer))
    _ = try channel.finish()
  }

  @Test func adapterTreatsRepeatedCloseAsAlreadyClosing() throws {
    // swift-nio-ssh throws a protocol violation for a second close on a closing child channel
    // (seen when NIOSSL and PostgresNIO both close it). Later closes follow the first one.
    let pending = PendingCloseHandler()
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(pending)
    try channel.pipeline.syncOperations.addHandler(SSHChannelDataAdapter())

    let first = CompletionFlag()
    let second = CompletionFlag()
    channel.close().whenSuccess { first.set() }
    channel.close().whenSuccess { second.set() }
    #expect(pending.closeCount == 1)

    pending.finishClose()
    channel.embeddedEventLoop.run()
    #expect(first.isSet)
    #expect(second.isSet)
  }

  @Test func adapterClosesOnRemoteEOFAndAbsorbsLaterCloses() throws {
    // The child channel allows remote half-closure so EOF arrives here; the adapter turns it
    // into the only close the SSH channel sees.
    let pending = PendingCloseHandler()
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(pending)
    try channel.pipeline.syncOperations.addHandler(SSHChannelDataAdapter())

    channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
    #expect(pending.closeCount == 1)
    channel.close(promise: nil)
    #expect(pending.closeCount == 1)

    pending.finishClose()
    channel.embeddedEventLoop.run()
  }

  @Test func adapterRejectsExtendedData() throws {
    let channel = EmbeddedChannel(handler: SSHChannelDataAdapter())
    var buffer = channel.allocator.buffer(capacity: 3)
    buffer.writeString("err")
    #expect(throws: SSHTunnelError.invalidChannelData) {
      try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)))
    }
    _ = try? channel.finish()
  }
}

/// Holds the first close like an SSH child channel waiting for the peer's CHANNEL_CLOSE.
private final class PendingCloseHandler: ChannelOutboundHandler {
  typealias OutboundIn = Any

  private(set) var closeCount = 0
  private var held: (context: ChannelHandlerContext, promise: EventLoopPromise<Void>?)?

  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    closeCount += 1
    if held == nil {
      held = (context, promise)
    } else {
      promise?.fail(ChannelError.alreadyClosed)
    }
  }

  func finishClose() {
    guard let held else { return }
    held.context.close(promise: held.promise)
  }
}

private final class CompletionFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

/// Hands out a validator that captures an object, then reports whether it was freed.
private final class WeakSentinel: @unchecked Sendable {
  private final class Sentinel: Sendable {}
  private let lock = NSLock()
  private weak var sentinel: Sentinel?

  func validator() -> SSHHostKeyValidator {
    let sentinel = Sentinel()
    lock.withLock { self.sentinel = sentinel }
    return { _, _ in withExtendedLifetime(sentinel) {} }
  }

  /// Polls for up to 5 s: channel teardown finishes on the event loop.
  func isReleased() async -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while lock.withLock({ sentinel != nil }) {
      guard ContinuousClock.now < end else { return false }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return true
  }
}

private final class AcceptAllUsers: NIOSSHServerUserAuthenticationDelegate, Sendable {
  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    responsePromise.succeed(.success)
  }
}

private final class DenyAllSSHUsers: NIOSSHServerUserAuthenticationDelegate, Sendable {
  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    responsePromise.succeed(.failure)
  }
}
