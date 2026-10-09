//
//  PostgresURIParser.swift
//  Dblore
//
//  Parses postgres:// URIs and libpq key=value strings into an ImportedConnection.
//  Input is external: errors and warnings never echo values from it.
//

import Foundation

nonisolated enum PostgresURIParser {
  enum ParseError: Error, Equatable, Sendable {
    case invalidFormat
    case unsupportedScheme
    case invalidPercentEncoding
    case invalidPort
    case missingHost
    case multipleHostsNotSupported
    case unixSocketNotSupported
    case hostParameterNotSupported
  }

  static let defaultPort = 5432

  static func parse(_ string: String) throws -> ImportedConnection {
    let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if let schemeEnd = input.range(of: "://") {
      let scheme = input[..<schemeEnd.lowerBound].lowercased()
      guard scheme == "postgres" || scheme == "postgresql" else {
        throw ParseError.unsupportedScheme
      }
      return try parseURI(input[schemeEnd.upperBound...])
    }
    guard input.contains("=") else { throw ParseError.invalidFormat }
    return try parseKeyValue(input)
  }

  // MARK: - URI

  private static func parseURI(_ rest: Substring) throws -> ImportedConnection {
    // Drop a fragment, then split authority / path / query.
    let body = rest.prefix { $0 != "#" }
    let authorityEnd = body.firstIndex { $0 == "/" || $0 == "?" } ?? body.endIndex
    let authority = body[..<authorityEnd]
    var remainder = body[authorityEnd...]
    var query: Substring = ""
    if let questionMark = remainder.firstIndex(of: "?") {
      query = remainder[remainder.index(after: questionMark)...]
      remainder = remainder[..<questionMark]
    }
    let path = remainder.drop { $0 == "/" }

    var username = ""
    var password: String?
    var hostPort = authority
    if let at = authority.lastIndex(of: "@") {
      let userInfo = authority[..<at]
      hostPort = authority[authority.index(after: at)...]
      if let colon = userInfo.firstIndex(of: ":") {
        username = try decode(userInfo[..<colon])
        password = try decode(userInfo[userInfo.index(after: colon)...])
      } else {
        username = try decode(userInfo)
      }
    }

    let (host, port) = try splitHostPort(hostPort)
    var fields = Fields(
      host: host, port: port, database: try decode(path), username: username, password: password)

    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = try decode(parts[0])
      let value = parts.count > 1 ? try decode(parts[1]) : ""
      if key == "host" || key == "hostaddr" { throw ParseError.hostParameterNotSupported }
      // libpq applies query parameters after the URI components, so they override them.
      try fields.apply(key: key, value: value)
    }
    return try fields.build()
  }

  private static func splitHostPort(_ text: Substring) throws -> (String, Int) {
    var host: String
    var portText: Substring = ""
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { throw ParseError.invalidFormat }
      host = String(text[text.index(after: text.startIndex)..<close])
      let after = text[text.index(after: close)...]
      if after.contains(",") { throw ParseError.multipleHostsNotSupported }
      if !after.isEmpty {
        guard after.hasPrefix(":") else { throw ParseError.invalidFormat }
        portText = after.dropFirst()
      }
    } else {
      if text.contains(",") { throw ParseError.multipleHostsNotSupported }
      if let colon = text.lastIndex(of: ":") {
        host = try decode(text[..<colon])
        portText = text[text.index(after: colon)...]
      } else {
        host = try decode(text)
      }
    }
    return (host, try port(portText))
  }

  // MARK: - libpq key=value

  private static func parseKeyValue(_ input: String) throws -> ImportedConnection {
    var fields = Fields(host: "", port: defaultPort, database: "", username: "", password: nil)
    var hostSet = false
    var index = input.startIndex

    func skipSpaces() {
      while index < input.endIndex, input[index].isWhitespace { index = input.index(after: index) }
    }

    while true {
      skipSpaces()
      guard index < input.endIndex else { break }
      var key = ""
      while index < input.endIndex, input[index] != "=", !input[index].isWhitespace {
        key.append(input[index])
        index = input.index(after: index)
      }
      skipSpaces()
      guard !key.isEmpty, index < input.endIndex, input[index] == "=" else {
        throw ParseError.invalidFormat
      }
      index = input.index(after: index)
      skipSpaces()
      let value = try readValue(input, at: &index)

      switch key {
      case "host", "hostaddr":
        if value.contains(",") { throw ParseError.multipleHostsNotSupported }
        if value.hasPrefix("/") || value.hasPrefix("@") { throw ParseError.unixSocketNotSupported }
        fields.host = value
        hostSet = !value.isEmpty
      case "password": fields.password = value
      default: try fields.apply(key: key, value: value)
      }
    }
    guard hostSet else { throw ParseError.missingHost }
    return try fields.build()
  }

  /// Reads one value: single-quoted (with `\'` and `\\`) or bare up to whitespace.
  private static func readValue(_ input: String, at index: inout String.Index) throws -> String {
    var value = ""
    let quoted = index < input.endIndex && input[index] == "'"
    if quoted { index = input.index(after: index) }
    while index < input.endIndex {
      let character = input[index]
      if quoted, character == "'" {
        index = input.index(after: index)
        return value
      }
      if !quoted, character.isWhitespace { break }
      if character == "\\" {
        index = input.index(after: index)
        guard index < input.endIndex else { break }
      }
      value.append(input[index])
      index = input.index(after: index)
    }
    if quoted { throw ParseError.invalidFormat }
    return value
  }

  // MARK: - Shared

  private struct Fields {
    var host: String
    var port: Int
    var database: String
    var username: String
    var password: String?
    var sslMode: SSLMode = .prefer
    var warnings: [String] = []

    /// Shared by URI query parameters and key=value pairs. `password` is not handled here:
    /// a URI query password is ignored like any other unknown parameter.
    mutating func apply(key: String, value: String) throws {
      switch key {
      case "port":
        if value.contains(",") { throw ParseError.multipleHostsNotSupported }
        port = try PostgresURIParser.port(Substring(value))
      case "dbname": database = value
      case "user": username = value
      case "sslmode":
        if let mode = SSLMode(rawValue: value) {
          sslMode = mode
        } else {
          warnings.append("Unknown sslmode; using \(SSLMode.prefer.rawValue).")
        }
      default:
        warnings.append("Ignored connection parameter \"\(PostgresURIParser.sanitized(key))\".")
      }
    }

    func build() throws -> ImportedConnection {
      guard !host.isEmpty else { throw ParseError.missingHost }
      if host.hasPrefix("/") { throw ParseError.unixSocketNotSupported }
      // libpq: dbname defaults to the user name.
      let database =
        database.isEmpty ? (username.isEmpty ? "postgres" : username) : database
      let config = ConnectionConfig(
        databaseType: .postgresql, host: host, port: port, database: database,
        username: username, sslMode: sslMode,
        name: ImportedConnection.defaultName(username: username, host: host, database: database))
      return ImportedConnection(
        config: config, password: password, source: .uri, warnings: warnings)
    }
  }

  /// External keys in warnings: one line, bounded length.
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

  private static func port(_ text: Substring) throws -> Int {
    if text.isEmpty { return defaultPort }
    guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
      (1...65535).contains(value)
    else {
      throw ParseError.invalidPort
    }
    return value
  }
}
