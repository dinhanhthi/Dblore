//
//  PostgresURIParser.swift
//  Dblore
//
//  Parses postgres:// URIs and libpq key=value strings into an ImportedConnection, plus
//  mysql:// and mariadb:// URIs (also JDBC URLs without their `jdbc:` prefix). The name predates
//  MySQL and is kept. Input is external: errors and warnings never echo values from it.
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
      let engine: DatabaseType
      switch input[..<schemeEnd.lowerBound].lowercased() {
      case "postgres", "postgresql": engine = .postgresql
      case "mysql", "mariadb": engine = .mysql
      default: throw ParseError.unsupportedScheme
      }
      return try parseURI(input[schemeEnd.upperBound...], engine: engine)
    }
    guard input.contains("=") else { throw ParseError.invalidFormat }
    return try parseKeyValue(input)
  }

  // MARK: - URI

  private static func parseURI(
    _ rest: Substring, engine: DatabaseType
  ) throws -> ImportedConnection {
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

    let (host, portText) = try splitHostPort(hostPort)
    var fields = Fields(
      engine: engine, host: host, port: try port(portText, engine: engine),
      database: try decode(path), username: username, password: password)

    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = try decode(parts[0])
      let value = parts.count > 1 ? try decode(parts[1]) : ""
      if key == "host" || key == "hostaddr" { throw ParseError.hostParameterNotSupported }
      // libpq and Connector/J apply query parameters after the URI components, so they
      // override them.
      try fields.apply(key: key, value: value)
    }
    return try fields.build()
  }

  /// The host and the raw port text (empty when the URI has no port).
  private static func splitHostPort(_ text: Substring) throws -> (String, Substring) {
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
    return (host, portText)
  }

  // MARK: - libpq key=value

  private static func parseKeyValue(_ input: String) throws -> ImportedConnection {
    var fields = Fields(
      engine: .postgresql, host: "", port: defaultPort, database: "", username: "", password: nil)
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
    let engine: DatabaseType
    var host: String
    var port: Int
    var database: String
    var username: String
    var password: String?
    var sslMode: SSLMode = .prefer
    /// A MySQL `sslMode` / `ssl-mode` was given, so the legacy Connector/J flags no longer apply.
    var hasExplicitSSLMode = false
    /// Deprecated Connector/J flags, resolved in `build()` whatever their order.
    var legacyUseSSL: Bool?
    var legacyRequireSSL = false
    var legacyVerifyServerCertificate = false
    var warnings: [String] = []

    /// Shared by URI query parameters and key=value pairs. `password` is not handled here:
    /// a URI query password is ignored like any other unknown parameter.
    mutating func apply(key: String, value: String) throws {
      switch engine {
      case .mysql: try applyMySQL(key: key, value: value)
      case .postgresql, .sqlite, .duckdb, .mongodb: try applyPostgres(key: key, value: value)
      }
    }

    private mutating func applyPostgres(key: String, value: String) throws {
      switch key {
      case "port":
        if value.contains(",") { throw ParseError.multipleHostsNotSupported }
        port = try PostgresURIParser.port(Substring(value), engine: engine)
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

    /// Connector/J and MySQL Shell parameter names, matched case-insensitively.
    private mutating func applyMySQL(key: String, value: String) throws {
      switch key.lowercased() {
      case "port":
        if value.contains(",") { throw ParseError.multipleHostsNotSupported }
        port = try PostgresURIParser.port(Substring(value), engine: engine)
      case "user": username = value
      case "sslmode", "ssl-mode":
        hasExplicitSSLMode = true
        if let mode = PostgresURIParser.mysqlSSLMode(value) {
          sslMode = mode
        } else {
          sslMode = .prefer
          warnings.append("Unknown SSL mode; using \(SSLMode.prefer.rawValue).")
        }
      // Deprecated Connector/J flags, mapped like Connector/J 8 maps them to sslMode.
      case "usessl":
        if let flag = Bool(value.lowercased()) {
          legacyUseSSL = flag
        } else {
          warnings.append("Unknown useSSL value; ignored.")
        }
      case "requiressl": legacyRequireSSL = Bool(value.lowercased()) ?? false
      case "verifyservercertificate":
        legacyVerifyServerCertificate = Bool(value.lowercased()) ?? false
      default:
        let lowered = key.lowercased()
        if lowered.contains("ssl") || lowered.contains("tls") || lowered.contains("certificate") {
          warnings.append(
            "TLS setting \"\(PostgresURIParser.sanitized(key))\" not imported; "
              + "check the SSL mode.")
        } else {
          warnings.append("Ignored connection parameter \"\(PostgresURIParser.sanitized(key))\".")
        }
      }
    }

    /// Connector/J 8: useSSL=false is DISABLED, then verifyServerCertificate=true VERIFY_CA,
    /// then requireSSL=true REQUIRED, else PREFERRED. An explicit sslMode wins.
    private var resolvedSSLMode: SSLMode {
      guard engine == .mysql, !hasExplicitSSLMode else { return sslMode }
      if legacyUseSSL == false { return .disable }
      if legacyVerifyServerCertificate { return .verifyCa }
      if legacyRequireSSL { return .require }
      return sslMode
    }

    func build() throws -> ImportedConnection {
      guard !host.isEmpty else { throw ParseError.missingHost }
      if host.hasPrefix("/") { throw ParseError.unixSocketNotSupported }
      var database = database
      var warnings = warnings
      switch engine {
      case .mysql:
        // MySQL has no default database; the row is kept and flagged in the preview.
        if database.isEmpty { warnings.append(PostgresURIParser.missingDatabaseWarning) }
      case .postgresql, .sqlite, .duckdb, .mongodb:
        // libpq: dbname defaults to the user name.
        if database.isEmpty { database = username.isEmpty ? "postgres" : username }
      }
      let config = ConnectionConfig(
        databaseType: engine, host: host, port: port, database: database,
        username: username, sslMode: resolvedSSLMode,
        name: ImportedConnection.defaultName(username: username, host: host, database: database))
      return ImportedConnection(
        config: config, password: password, source: .uri, warnings: warnings)
    }
  }

  /// Shown on a MySQL row imported without a database.
  static let missingDatabaseWarning = "No database: set one after import."

  /// MySQL (`DISABLED` … `VERIFY_IDENTITY`), MariaDB Connector/J (`trust`) and libpq-style
  /// names, case-insensitive. Nil for an unknown value.
  static func mysqlSSLMode(_ value: String) -> SSLMode? {
    switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
    case "disable", "disabled": .disable
    case "allow": .allow
    case "prefer", "preferred": .prefer
    case "require", "required", "trust": .require
    case "verify-ca": .verifyCa
    case "verify-full", "verify-identity": .verifyFull
    default: nil
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

  private static func port(_ text: Substring, engine: DatabaseType) throws -> Int {
    if text.isEmpty {
      switch engine {
      case .mysql: return engine.defaultPort
      case .postgresql, .sqlite, .duckdb, .mongodb: return defaultPort
      }
    }
    guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
      (1...65535).contains(value)
    else {
      throw ParseError.invalidPort
    }
    return value
  }
}
