// MySQLFullAuthGuard.swift
// Keeps mysql-nio from sending the real password when the TLS mode does not verify the server.
// caching_sha2_password asks for "full authentication" ([0x01, 0x04]) when the server's cache
// misses; the fork then writes the password (in cleartext inside unverified TLS). The guard is
// an inbound/outbound handler the app adds to the channel before `MySQLConnection.connect(over:)`.
// The fork appends its codec and connection handler at `.last` and puts NIOSSLClientHandler at
// `.first`, so the guard reads decrypted packets and sits before the packet decoder: the fork
// never sees what the guard drops.

import Foundation
import NIOCore
import os

/// Whether a MySQL login arms the full-authentication guard. Only Verify CA and Verify Full
/// check the server's certificate. A direct connection to this Mac (127.0.0.1, ::1 or
/// localhost, by the host string, no DNS) is exempt; the SSH tunnel's loopback forwarder never
/// is, so the decision comes from the connection settings, not from the socket address.
nonisolated func armsFullAuthGuard(tlsMode: SSLMode, host: String, usesSSH: Bool) -> Bool {
  switch tlsMode {
  case .verifyCa, .verifyFull: return false
  case .disable, .allow, .prefer, .require: break
  }
  if usesSSH { return true }
  return !["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
}

/// Set once the guard refused a login packet, with why. The login error is then
/// `MySQLError.closed`, so the reason is what tells the user what the server asked for. The
/// first reason is kept.
nonisolated final class FullAuthRefusal: Sendable {
  nonisolated enum Reason: Equatable, Sendable {
    /// An AuthMoreData packet other than fast_auth_success (perform_full_authentication).
    case fullAuthentication
    /// An auth switch to a plugin outside the allow-list. `plugin` holds at most the name's
    /// first 65 bytes: it comes from an untrusted server.
    case authSwitch(plugin: String)
    /// A frame longer than 64 KiB (0xFFFFFF bytes included, which the fork would join with the
    /// frames after it).
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
/// mysql_native_password with a NUL-terminated name. The fork reads just the status and command
/// bytes of AuthMoreData, so matching [0x01, 0x04] alone would let [0x01, 0x04, ...] through;
/// and the app always passes `allowPublicKeyRetrieval: false`, so no legitimate login more-data
/// packet other than [0x01, 0x03] exists. The greeting, OK (0x00) and ERR (0xFF) pass.
/// The greeting's auth plugin name passes unchecked: what the fork does with it is bounded by
/// the plugins the fork supports, pinned by `forkSwitchesOnlyToItsKnownPlugins`. A fork bump
/// that adds a plugin sending the password in cleartext must re-review the guard.
///
/// The guard sees wire frames, but the fork's decoder joins a frame of 0xFFFFFF bytes with the
/// frames after it into one message that the first frame's first byte classifies. So, while
/// armed, a frame longer than 64 KiB is refused on its header, before the guard buffers it (no
/// greeting or login packet comes near that, and a hostile server cannot make the guard hold
/// 16 MiB), and no byte the guard reads ends the login: only the fork knows when it is over.
/// The guard stays armed until the caller runs `disarm()` once the fork's login future
/// succeeded, before the first command, so query results are never inspected.
///
/// A refused packet is dropped: the guard records the reason and closes the channel from its
/// own position, so the close skips the fork's handler (which would write a COM_QUIT), and
/// drops every later write.
nonisolated final class MySQLFullAuthGuard: ChannelDuplexHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private enum Phase { case greeting, authentication, passthrough, refused }
  private static let fastAuthSuccess: [UInt8] = [0x01, 0x03]
  static let switchablePlugins = ["caching_sha2_password", "mysql_native_password"]
  /// The longest login frame the armed guard buffers; a frame of 0xFFFFFF bytes continues in
  /// the next one.
  private static let maxLoginFrameLength = 64 * 1024

  private var phase: Phase
  private var pending = ByteBuffer()
  private var context: ChannelHandlerContext?
  /// True while `forwardLoginPackets` runs: a `disarm()` from inside it (the login future
  /// completing on the OK it forwarded) leaves the held bytes to the loop's own forward.
  private var forwarding = false
  private let refusal: FullAuthRefusal

  init(armed: Bool, refusal: FullAuthRefusal) {
    self.phase = armed ? .greeting : .passthrough
    self.refusal = refusal
  }

  /// Stops inspecting packets. Call it on the channel's event loop once the fork's login
  /// future succeeded; it forwards what the guard still holds, once and in order. No effect
  /// after a refusal.
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
      guard length <= Self.maxLoginFrameLength else {
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
      // At most 65 bytes: longer than any name the message shows, so no huge String is built.
      let bytes = payload.dropFirst().prefix(65)
      let name = bytes.prefix { $0 != 0 }
      let plugin = String(decoding: name, as: UTF8.self)
      guard name.count < bytes.count, switchablePlugins.contains(plugin) else {
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
