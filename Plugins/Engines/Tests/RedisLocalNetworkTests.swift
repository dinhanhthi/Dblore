// RedisLocalNetworkTests.swift
// Where plain RESP may go, without a socket: the host policy checked before dialing, which hosts
// are IP literals, when a connected peer must be checked, and which peer addresses are local.

import Foundation
import Network
import Testing

/// An endpoint for an IPv4 or IPv6 literal, nil for nil
private func endpoint(_ text: String?) throws -> NWEndpoint? {
  guard let text else { return nil }
  let host: NWEndpoint.Host =
    text.contains(":")
    ? .ipv6(try #require(IPv6Address(text))) : .ipv4(try #require(IPv4Address(text)))
  return .hostPort(host: host, port: 6379)
}

struct RedisLocalNetworkTests {
  @Test(
    "Local names and local IP literals are accepted",
    arguments: [
      "localhost", "LocalHost", "redis.local", "127.0.0.1", "10.1.2.3", "192.168.64.1",
      "172.16.0.1", "169.254.1.1", "100.64.0.1", "::1", "[::1]", "fe80::1%en0", "fd00::1",
    ])
  func acceptsLocalHosts(_ host: String) {
    #expect(RedisLocalNetwork.isLocalHost(host))
  }

  @Test(
    "Other names, public addresses and odd forms are refused",
    arguments: [
      "example.com", "redis.local.", "evil.local.example.com", "8.8.8.8", "010.0.0.1",
      "2001:db8::1", "", "local host",
    ])
  func refusesOtherHosts(_ host: String) {
    #expect(!RedisLocalNetwork.isLocalHost(host))
  }

  @Test func ipLiterals() {
    for host in ["192.168.64.1", "[2001:db8::1]", "fe80::1%en0"] {
      #expect(RedisLocalNetwork.isIPLiteral(host), "\(host)")
    }
    for host in ["localhost", "redis.local", "example.com", "1.2.3"] {
      #expect(!RedisLocalNetwork.isIPLiteral(host), "\(host)")
    }
  }

  @Test func onlyPlainHostNamesNeedThePeerCheck() {
    #expect(RedisLocalNetwork.needsPeerCheck(host: "localhost", usesTLS: false))
    #expect(!RedisLocalNetwork.needsPeerCheck(host: "localhost", usesTLS: true))
    #expect(!RedisLocalNetwork.needsPeerCheck(host: "127.0.0.1", usesTLS: false))
    #expect(!RedisLocalNetwork.needsPeerCheck(host: "fe80::1%en0", usesTLS: true))
  }

  @Test(
    "A peer is local by its class, or on the same /64 as this Mac's IPv6 address",
    arguments: [
      // (remote, local, expected)
      ("10.0.0.5", "10.0.0.2", true), ("192.168.1.2", nil, true), ("172.16.0.1", nil, true),
      ("172.31.255.1", nil, true), ("127.0.0.1", nil, true), ("169.254.3.4", nil, true),
      ("100.64.0.1", nil, true), ("8.8.8.8", "10.0.0.2", false), ("172.32.0.1", nil, false),
      ("100.128.0.1", nil, false), ("::ffff:192.168.1.2", nil, true),
      ("::ffff:8.8.8.8", "2001:db8:1:2::10", false), ("::1", nil, true), ("fc00::1", nil, true),
      ("fd12::1", nil, true), ("fe80::1", nil, true),
      ("2001:db8:1:2::99", "2001:db8:1:2::10", true),
      ("2001:db8:1:3::99", "2001:db8:1:2::10", false), (nil, "10.0.0.2", false),
      ("2001:db8:1:2::99", nil, false), ("2001:db8:1:2::99", "10.0.0.2", false),
      // A mapped or zero-prefix address never counts as being on this Mac's /64
      ("::ffff:8.8.8.8", "::ffff:192.168.64.3", false),
      ("::ffff:192.168.64.1", "::ffff:192.168.64.3", true), ("::808:808", "::1", false),
      ("::808:808", "::ffff:192.168.64.3", false),
    ] as [(String?, String?, Bool)])
  func localPeers(_ remote: String?, _ local: String?, _ expected: Bool) throws {
    #expect(
      RedisLocalNetwork.isLocalPeer(try endpoint(remote), local: try endpoint(local)) == expected)
  }
}
