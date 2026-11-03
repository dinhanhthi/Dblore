// SocketKeepalive.swift
// TCP keepalive for the database sockets Dblore opens itself (PostgreSQL direct, MySQL,
// MongoDB direct and the SSH bastion socket). An idle connection is probed after 30 s, then
// every 10 s; 3 unanswered probes drop it, so a dead path (sleep, NAT or VPN timeout) fails in
// about a minute instead of hanging until the next query.

import Darwin
import NIOCore
import NIOPosix

extension ClientBootstrap {
  /// This bootstrap with keepalive (30 s idle, 10 s interval, 3 probes) on its sockets.
  nonisolated func withKeepalive() -> ClientBootstrap {
    let tcp = SocketOptionLevel(IPPROTO_TCP)
    return
      self
      .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
      .channelOption(ChannelOptions.socket(tcp, TCP_KEEPALIVE), value: 30)
      .channelOption(ChannelOptions.socket(tcp, TCP_KEEPINTVL), value: 10)
      .channelOption(ChannelOptions.socket(tcp, TCP_KEEPCNT), value: 3)
  }
}
