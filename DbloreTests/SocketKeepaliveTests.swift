// SocketKeepaliveTests.swift
// A client socket made with `withKeepalive()` carries the keepalive options (loopback only).

import Darwin
import NIOCore
import NIOPosix
import Testing

@testable import Dblore

@Suite("TCP keepalive on database sockets", .timeLimit(.minutes(1)))
struct SocketKeepaliveTests {
  @Test("The client socket probes after 30 s idle, every 10 s, 3 times")
  func clientSocketHasKeepalive() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
      .bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let client = try await ClientBootstrap(group: group).withKeepalive()
      .connect(host: "127.0.0.1", port: port).get()

    let tcp = SocketOptionLevel(IPPROTO_TCP)
    let enabled = try await client.getOption(
      ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE)
    ).get()
    let idle = try await client.getOption(ChannelOptions.socket(tcp, TCP_KEEPALIVE)).get()
    let interval = try await client.getOption(ChannelOptions.socket(tcp, TCP_KEEPINTVL)).get()
    let count = try await client.getOption(ChannelOptions.socket(tcp, TCP_KEEPCNT)).get()

    try await client.close()
    try await server.close()
    try await group.shutdownGracefully()
    #expect(enabled != 0)
    #expect(idle == 30)
    #expect(interval == 10)
    #expect(count == 3)
  }
}
