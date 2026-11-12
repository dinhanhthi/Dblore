// RedisLocalNetwork.swift
// Where plain RESP may go (RedisTransport.swift): a local host before dialing, and once a host
// name is connected, a local peer address. Pure, so the policy is tested without a socket.

import Foundation
import Network

// MARK: - Local hosts

/// Hosts that may be reached over plain RESP: localhost, mDNS `.local`, or a loopback / private /
/// link-local / CGNAT IP literal. An IP literal must parse (`inet_pton`; IPv4 in its canonical
/// dotted form only), and a name must be letters, digits, dots and hyphens.
enum RedisLocalNetwork {
  static func isLocalHost(_ rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if host.contains(":") {
      // A zone (`fe80::1%en0`) only picks the interface
      let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
      return ipv6(address).map(isLocalIPv6) ?? false
    }
    if let octets = ipv4(host) { return isLocalIPv4(octets) }
    guard isHostName(host) else { return false }
    return host == "localhost" || host.hasSuffix(".local")
  }

  /// Whether `host` is an IP literal (IPv4, or IPv6 with or without brackets and zone)
  static func isIPLiteral(_ rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if host.contains(":") { return true }
    return ipv4(host) != nil
  }

  /// Whether a connected socket's peer is local: a loopback / private / link-local / CGNAT
  /// address, or an IPv6 address on the same /64 as the socket's own (`local`). An IPv4-mapped
  /// peer goes by its IPv4 address alone, and a /64 of all zeros is nobody's own network.
  static func isLocalPeer(_ remote: NWEndpoint?, local: NWEndpoint?) -> Bool {
    guard case .hostPort(let host, _)? = remote else { return false }
    switch host {
    case .ipv4(let address):
      return isLocalIPv4(Array(address.rawValue))
    case .ipv6(let address):
      let bytes = Array(address.rawValue)
      if let octets = mappedIPv4(bytes) { return isLocalIPv4(octets) }
      if isLocalIPv6(bytes) { return true }
      guard !bytes.prefix(8).allSatisfy({ $0 == 0 }),
        case .hostPort(.ipv6(let own), _)? = local
      else { return false }
      return Array(own.rawValue).prefix(8) == bytes.prefix(8)
    default:
      return false
    }
  }

  /// Whether a connection must check its peer once connected: plain RESP to a host name, whose
  /// address is known only once resolved (an IP literal was checked whole before dialing)
  static func needsPeerCheck(host: String, usesTLS: Bool) -> Bool {
    !usesTLS && !isIPLiteral(host)
  }

  /// The 4 bytes of a canonical dotted IPv4 literal
  private static func ipv4(_ text: String) -> [UInt8]? {
    var address = in_addr()
    guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
    let octets = withUnsafeBytes(of: &address) { Array($0) }
    guard octets.map(String.init).joined(separator: ".") == text else { return nil }
    return octets
  }

  /// The 16 bytes of an IPv6 literal
  private static func ipv6(_ text: String) -> [UInt8]? {
    var address = in6_addr()
    guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
  }

  private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
    let (a, b) = (octets[0], octets[1])
    return a == 127 || a == 10 || (a == 172 && (16...31).contains(b))
      || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
  }

  private static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
    if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }  // ::1
    if let octets = mappedIPv4(bytes) { return isLocalIPv4(octets) }
    return (bytes[0] & 0xFE) == 0xFC  // fc00::/7
      || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)  // fe80::/10
  }

  /// The IPv4 address of an IPv4-mapped ::ffff:a.b.c.d
  private static func mappedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
    guard bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF else {
      return nil
    }
    return Array(bytes[12..<16])
  }

  /// Letters, digits, dots and hyphens; no empty label, no trailing dot
  private static func isHostName(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253,
      host.unicodeScalars.allSatisfy({
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
      })
    else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
    }
  }
}
