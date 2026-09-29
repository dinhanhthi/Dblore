// AIEndpoint.swift
// Wire protocols and base-URL normalization for AI providers

import Foundation

/// The wire protocol a provider speaks
nonisolated enum AIWire: String, Codable, Sendable {
  case anthropicMessages
  case chatCompletions
}

nonisolated enum AIEndpointError: LocalizedError, Sendable, Equatable {
  case empty
  case invalidURL
  case unsupportedScheme
  case credentialsNotAllowed
  case missingHost
  case insecureRemoteHTTP

  var errorDescription: String? {
    switch self {
    case .empty:
      return "Enter a base URL."
    case .invalidURL:
      return "The base URL is not valid."
    case .unsupportedScheme:
      return "The base URL must start with http:// or https://."
    case .credentialsNotAllowed:
      return "Do not put a username or password in the base URL. Use the API key field instead."
    case .missingHost:
      return "The base URL has no host name."
    case .insecureRemoteHTTP:
      return
        "Plain http:// is only allowed for localhost, private-network IP addresses and .local hosts. Use https://."
    }
  }
}

nonisolated enum AIEndpoint: Sendable {

  /// Path suffixes users commonly paste that are not part of the base URL
  private static let strippedSuffixes = ["chat/completions", "messages", "responses", "models"]

  /// Normalizes a user-entered base URL: trims, strips endpoint suffixes, ensures a version segment
  static func normalize(_ raw: String) throws(AIEndpointError) -> URL {
    let trimmed = trimSlashes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else { throw .empty }
    guard var components = URLComponents(string: trimmed) else { throw .invalidURL }

    guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { throw .unsupportedScheme }
    if components.user != nil || components.password != nil { throw .credentialsNotAllowed }
    guard let host = components.host, !host.isEmpty else { throw .missingHost }
    if scheme == "http" && !isLocalHost(host) { throw .insecureRemoteHTTP }

    var path = trimSlashes(components.path)
    for suffix in strippedSuffixes where path == suffix || path.hasSuffix("/" + suffix) {
      path = trimSlashes(String(path.dropLast(suffix.count)))
      break
    }
    let last = path.split(separator: "/").last.map(String.init) ?? ""
    if last.range(of: #"^v\d+(beta)?$"#, options: .regularExpression) == nil {
      path += "/v1"
    }

    components.scheme = scheme
    components.path = path.hasPrefix("/") ? path : "/" + path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw .invalidURL }
    return url
  }

  static func chatURL(base: URL, wire: AIWire) -> URL {
    switch wire {
    case .chatCompletions: return base.appendingPathComponent("chat/completions")
    case .anthropicMessages: return base.appendingPathComponent("messages")
    }
  }

  static func modelsURL(base: URL) -> URL {
    base.appendingPathComponent("models")
  }

  private static func trimSlashes(_ value: String) -> String {
    var result = Substring(value)
    while result.hasSuffix("/") { result = result.dropLast() }
    return String(result)
  }

  /// localhost, mDNS `.local`, or a loopback / private / link-local / CGNAT IP literal
  private static func isLocalHost(_ rawHost: String) -> Bool {
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    if host == "localhost" || host.hasSuffix(".local") { return true }
    if host.contains(":") { return isPrivateIPv6(host) }
    return isPrivateIPv4(host)
  }

  private static func isPrivateIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    var octets: [Int] = []
    for part in parts {
      guard part.count <= 3, !(part.count > 1 && part.first == "0"),
        part.allSatisfy({ $0.isASCII && $0.isNumber }),
        let value = Int(part), value <= 255
      else { return false }
      octets.append(value)
    }
    let (a, b) = (octets[0], octets[1])
    return a == 127 || a == 10 || (a == 172 && (16...31).contains(b))
      || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
  }

  private static func isPrivateIPv6(_ host: String) -> Bool {
    if host == "::1" { return true }
    guard let first = host.split(separator: ":", omittingEmptySubsequences: true).first,
      host.first != ":", let group = UInt16(first, radix: 16)
    else { return false }
    return (group & 0xFE00) == 0xFC00 || (group & 0xFFC0) == 0xFE80
  }
}
