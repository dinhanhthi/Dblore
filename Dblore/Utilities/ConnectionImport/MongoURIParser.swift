//
//  MongoURIParser.swift
//  Dblore
//
//  Parses mongodb:// and mongodb+srv:// connection strings. Input is external: errors never
//  echo values from it, and the parsed result redacts its credentials when printed.
//

import Foundation

/// SCRAM mechanisms, the only ones MongoKitten speaks.
nonisolated enum MongoAuthMechanism: String, Equatable, Sendable {
  case scramSHA1 = "SCRAM-SHA-1"
  case scramSHA256 = "SCRAM-SHA-256"
}

/// The five read preference modes of the URI spec.
nonisolated enum MongoReadPreference: String, CaseIterable, Equatable, Sendable {
  case primary
  case primaryPreferred
  case secondary
  case secondaryPreferred
  case nearest
}

/// One parsed connection string. Only allow-listed options are kept.
nonisolated struct ParsedMongoURI: Equatable, Sendable {
  nonisolated struct Host: Equatable, Sendable {
    /// Without IPv6 brackets.
    var name: String
    /// Nil when the URI gives no port.
    var port: Int?
  }

  var isSRV: Bool
  var hosts: [Host]
  /// Nil when the URI has no path.
  var database: String?
  /// Nil without userinfo.
  var username: String?
  /// Nil without a `:` in the userinfo; empty for `user:@host`.
  var password: String?
  var authSource: String?
  var authMechanism: MongoAuthMechanism?
  /// The `tls` / `ssl` value given in the URI; nil when absent.
  var tls: Bool?
  var replicaSet: String?
  var directConnection: Bool?
  var appName: String?
  var readPreference: MongoReadPreference?
  /// Option keys that were dropped (not stored), for the form to show.
  var ignoredOptions: [String]

  /// Whether the connection uses TLS: an explicit `tls`/`ssl`, else on for `+srv` only.
  var usesTLS: Bool { tls ?? isSRV }

  /// MongoKitten always verifies, so MongoDB TLS is two-valued (2.6 Q4).
  var sslMode: SSLMode { usesTLS ? .verifyFull : .disable }

  /// The stored form: rebuilt from the parsed fields, without userinfo or ignored options.
  var storedURI: String {
    let hostList = hosts.map { host in
      let name = host.name.contains(":") ? "[\(host.name)]" : host.name
      return host.port.map { "\(name):\($0)" } ?? name
    }
    var text = (isSRV ? "mongodb+srv://" : "mongodb://") + hostList.joined(separator: ",")
    if let database { text += "/" + MongoURIParser.encoded(database) }
    let options: [(String, String?)] = [
      ("authSource", authSource), ("authMechanism", authMechanism?.rawValue),
      ("tls", tls.map(String.init)), ("replicaSet", replicaSet),
      ("directConnection", directConnection.map(String.init)), ("appName", appName),
      ("readPreference", readPreference?.rawValue),
    ]
    let query = options.compactMap { key, value in
      value.map { "\(key)=\(MongoURIParser.encoded($0))" }
    }
    if !query.isEmpty {
      text += (database == nil ? "/?" : "?") + query.joined(separator: "&")
    }
    return text
  }

  /// `config` as a MongoDB connection to this URI. Host and port come from the first host (port
  /// 27017 when absent, also for `+srv`). The password is left as it is.
  func applied(to config: ConnectionConfig) -> ConnectionConfig {
    var config = config
    config.databaseType = .mongodb
    config.host = hosts[0].name
    config.port = hosts[0].port ?? MongoURIParser.defaultPort
    config.database = database ?? ""
    config.username = username ?? ""
    config.sslMode = sslMode
    config.mongoURI = storedURI
    return config
  }
}

extension ParsedMongoURI: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String {
    let userState = username == nil ? "none" : "<redacted>"
    let passwordState = password == nil ? "none" : "<redacted>"
    return
      "ParsedMongoURI(hosts: \(hosts.count), srv: \(isSRV), user: \(userState), password: \(passwordState), ignored: \(ignoredOptions.count))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(self, children: ["summary": description], displayStyle: .struct)
  }
}

nonisolated enum MongoURIParser {
  enum ParseError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedScheme
    case invalidPercentEncoding
    case unescapedUserInfo
    case emptyUsername
    case missingHost
    case invalidHost
    case unixSocketNotSupported
    case invalidPort
    case invalidDatabaseName
    /// Carries the option name from the allow list, never input text.
    case invalidOptionValue(String)
    case unsupportedAuthMechanism
    case conflictingTLSOptions
    case tlsFileNotSupported
    case insecureTLSNotSupported
    case directConnectionWithMultipleHosts
    case srvWithPort
    case srvWithMultipleHosts
    case srvWithDirectConnection

    var errorDescription: String? {
      switch self {
      case .unsupportedScheme:
        "The connection string must start with mongodb:// or mongodb+srv://."
      case .invalidPercentEncoding: "The connection string has invalid percent-encoding."
      case .unescapedUserInfo: "Percent-encode @, : and / in the user name and password."
      case .emptyUsername: "The user name is empty."
      case .missingHost: "The connection string is missing a host."
      case .invalidHost: "A host name is not valid."
      case .unixSocketNotSupported: "Unix socket connections are not supported. Use a host name."
      case .invalidPort: "A port must be a number from 1 to 65535."
      case .invalidDatabaseName:
        "The database name is not valid: it must be shorter than 64 bytes, without / \\ . \" $, "
          + "spaces or NUL."
      case .invalidOptionValue(let key): "The value of the \(key) option is not valid."
      case .unsupportedAuthMechanism:
        "Only SCRAM-SHA-256 and SCRAM-SHA-1 authentication are supported (no X.509, Kerberos, "
          + "LDAP or AWS)."
      case .conflictingTLSOptions: "The tls and ssl options disagree."
      case .tlsFileNotSupported:
        "Certificate files in a connection string cannot be read. Choose the certificate in the "
          + "connection form instead (Keychain)."
      case .insecureTLSNotSupported:
        "MongoDB connections always verify the server certificate and host name. Remove the "
          + "option that turns verification off."
      case .directConnectionWithMultipleHosts: "directConnection=true needs exactly one host."
      case .srvWithPort: "A mongodb+srv:// host cannot have a port."
      case .srvWithMultipleHosts: "A mongodb+srv:// connection string takes exactly one host."
      case .srvWithDirectConnection:
        "directConnection=true cannot be used with mongodb+srv://."
      }
    }
  }

  static let defaultPort = 27017

  /// Why `checkedMongoURI` refused a connection string.
  enum URIMismatch: Error, Equatable, Sendable {
    /// Not MongoDB, not parsable, or it names another host or port
    case host
    /// It lists other hosts besides this one
    case otherHosts
    /// Its tls/ssl option disagrees with the TLS mode
    case tls
  }

  /// The stored form of a connection string from a file (an imported connection, an opened
  /// workspace) when it reaches only `host` and `port` (MongoSession seeds every host it names)
  /// and its tls/ssl option agrees with `sslMode`.
  static func checkedMongoURI(
    _ text: String, host: String, port: Int, engine: DatabaseType, sslMode: SSLMode
  ) -> Result<String, URIMismatch> {
    guard engine == .mongodb, let uri = try? parse(text) else { return .failure(.host) }
    let sameHosts =
      uri.isSRV
      ? uri.hosts.count == 1 && uri.hosts[0].name == host
      : uri.hosts.allSatisfy { $0.name == host && ($0.port ?? defaultPort) == port }
    guard sameHosts else { return .failure(uri.hosts.count > 1 ? .otherHosts : .host) }
    if let flag = uri.tls, flag != (sslMode != .disable) { return .failure(.tls) }
    return .success(uri.storedURI)
  }

  /// Options that would read a file, refused in the sandbox.
  private static let fileOptions: Set<String> = [
    "tlscafile", "tlscertificatekeyfile", "tlscertificatekeyfilepassword",
  ]

  /// Options that weaken verification. MongoKitten always verifies (2.6 Q4), so `true` is
  /// refused and `false` changes nothing.
  private static let insecureOptions: Set<String> = [
    "tlsinsecure", "tlsallowinvalidcertificates", "tlsallowinvalidhostnames",
    "sslallowinvalidcertificates", "sslallowinvalidhostnames",
  ]

  static func parse(_ string: String) throws -> ParsedMongoURI {
    let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schemeEnd = input.range(of: "://") else { throw ParseError.unsupportedScheme }
    let isSRV: Bool
    switch input[..<schemeEnd.lowerBound].lowercased() {
    case "mongodb": isSRV = false
    case "mongodb+srv": isSRV = true
    default: throw ParseError.unsupportedScheme
    }

    // Drop a fragment, then split authority / path / query.
    let body = input[schemeEnd.upperBound...].prefix { $0 != "#" }
    let authorityEnd = body.firstIndex { $0 == "/" || $0 == "?" } ?? body.endIndex
    var authority = body[..<authorityEnd]
    var remainder = body[authorityEnd...]
    var query: Substring = ""
    if let questionMark = remainder.firstIndex(of: "?") {
      query = remainder[remainder.index(after: questionMark)...]
      remainder = remainder[..<questionMark]
    }

    var uri = ParsedMongoURI(
      isSRV: isSRV, hosts: [], database: nil, username: nil, password: nil, authSource: nil,
      authMechanism: nil, tls: nil, replicaSet: nil, directConnection: nil, appName: nil,
      readPreference: nil, ignoredOptions: [])

    if let at = authority.firstIndex(of: "@") {
      let userInfo = authority[..<at]
      authority = authority[authority.index(after: at)...]
      if authority.contains("@") || userInfo.filter({ $0 == ":" }).count > 1 {
        throw ParseError.unescapedUserInfo
      }
      let colon = userInfo.firstIndex(of: ":")
      uri.username = try decode(userInfo[..<(colon ?? userInfo.endIndex)])
      if let colon { uri.password = try decode(userInfo[userInfo.index(after: colon)...]) }
      if uri.username?.isEmpty == true { throw ParseError.emptyUsername }
    }

    guard !authority.isEmpty else { throw ParseError.missingHost }
    uri.hosts = try authority.split(separator: ",", omittingEmptySubsequences: false)
      .map(host)

    let path = remainder.dropFirst()
    if !path.isEmpty { uri.database = try databaseName(path) }

    try applyOptions(query, to: &uri)
    try validate(uri)
    return uri
  }

  // MARK: - Hosts

  private static func host(_ text: Substring) throws -> ParsedMongoURI.Host {
    guard !text.isEmpty else { throw ParseError.missingHost }
    var name: String
    var portText: Substring?
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { throw ParseError.invalidHost }
      name = String(text[text.index(after: text.startIndex)..<close])
      let after = text[text.index(after: close)...]
      if !after.isEmpty {
        guard after.hasPrefix(":") else { throw ParseError.invalidHost }
        portText = after.dropFirst()
      }
      guard !name.isEmpty, name.contains(":"),
        name.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
      else { throw ParseError.invalidHost }
    } else {
      let parts = text.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count <= 2 else { throw ParseError.invalidHost }
      name = try decode(parts[0])
      if parts.count == 2 { portText = parts[1] }
      if name.hasPrefix("/") || name.hasSuffix(".sock") {
        throw ParseError.unixSocketNotSupported
      }
      guard !name.isEmpty else { throw ParseError.missingHost }
      guard
        name.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        })
      else { throw ParseError.invalidHost }
    }
    return ParsedMongoURI.Host(name: name, port: try portText.map(port))
  }

  private static func port(_ text: Substring) throws -> Int {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
      (1...65535).contains(value)
    else { throw ParseError.invalidPort }
    return value
  }

  /// MongoDB's rules for database names on Unix: shorter than 64 bytes, without `/\. "$` or NUL.
  private static func databaseName(_ text: Substring) throws -> String {
    let name = try decode(text)
    guard name.utf8.count < 64, !name.contains(where: { "/\\. \"$\0".contains($0) }) else {
      throw ParseError.invalidDatabaseName
    }
    return name
  }

  // MARK: - Options

  private static func applyOptions(_ query: Substring, to uri: inout ParsedMongoURI) throws {
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = try decode(parts[0])
      let value = parts.count > 1 ? try decode(parts[1]) : ""
      let lowered = key.lowercased()
      switch lowered {
      case "authsource": uri.authSource = try nonEmpty(value, option: "authSource")
      case "authmechanism":
        guard let mechanism = MongoAuthMechanism(rawValue: value.uppercased()) else {
          throw ParseError.unsupportedAuthMechanism
        }
        uri.authMechanism = mechanism
      case "tls", "ssl":
        let flag = try boolean(value, option: lowered)
        if let tls = uri.tls, tls != flag { throw ParseError.conflictingTLSOptions }
        uri.tls = flag
      case "replicaset": uri.replicaSet = try nonEmpty(value, option: "replicaSet")
      case "directconnection":
        uri.directConnection = try boolean(value, option: "directConnection")
      case "appname": uri.appName = try nonEmpty(value, option: "appName")
      case "readpreference":
        guard
          let mode = MongoReadPreference.allCases.first(where: {
            $0.rawValue.lowercased() == value.lowercased()
          })
        else { throw ParseError.invalidOptionValue("readPreference") }
        uri.readPreference = mode
      default:
        if fileOptions.contains(lowered) { throw ParseError.tlsFileNotSupported }
        if insecureOptions.contains(lowered), value.lowercased() != "false" {
          throw ParseError.insecureTLSNotSupported
        }
        let name = sanitized(key)
        if !uri.ignoredOptions.contains(name) { uri.ignoredOptions.append(name) }
      }
    }
  }

  private static func validate(_ uri: ParsedMongoURI) throws {
    if uri.isSRV {
      if uri.hosts.count > 1 { throw ParseError.srvWithMultipleHosts }
      if uri.hosts[0].port != nil { throw ParseError.srvWithPort }
      if uri.directConnection == true { throw ParseError.srvWithDirectConnection }
    } else if uri.directConnection == true, uri.hosts.count > 1 {
      throw ParseError.directConnectionWithMultipleHosts
    }
  }

  private static func boolean(_ value: String, option: String) throws -> Bool {
    switch value.lowercased() {
    case "true": true
    case "false": false
    default: throw ParseError.invalidOptionValue(option)
    }
  }

  private static func nonEmpty(_ value: String, option: String) throws -> String {
    guard !value.isEmpty else { throw ParseError.invalidOptionValue(option) }
    return value
  }

  // MARK: - Text

  /// Unreserved characters only, so a stored value never splits the query or the path.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func encoded(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
  }

  /// External keys in `ignoredOptions`: one line, bounded length.
  private static func sanitized(_ text: String) -> String {
    let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    return line.count > 60 ? String(line.prefix(60)) + "…" : line
  }

  private static func decode(_ text: Substring) throws -> String {
    guard let decoded = String(text).removingPercentEncoding else {
      throw ParseError.invalidPercentEncoding
    }
    return decoded
  }
}
