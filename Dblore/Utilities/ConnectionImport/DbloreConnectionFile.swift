//
//  DbloreConnectionFile.swift
//  Dblore
//
//  Dblore's own connections file: a versioned JSON envelope
//  `{format: "dblore-connections", version: 1, exportedAt, connections, favorites}`.
//
//  Each connection is copied from an explicit allow list, never by encoding ConnectionConfig:
//  name, engine, host, port, database, user, TLS mode, SSH host/port/user/auth method, the
//  MongoDB connection string rebuilt without userinfo, timeouts and row cap, protection, commit
//  style, AI access and rules, color, group, hidden schemas, and the connection scripts' plain
//  file names and timeout (never a path or a script's content; an import never applies them).
//  Never written: passwords, SSH
//  passwords, passphrases and keys (nor the key's algorithm and fingerprint), client
//  certificates and their metadata, file bookmarks, the remember flag and the MongoDB identity
//  pin (the saved database is written as `database`).
//
//  File databases (SQLite, DuckDB) are left out on both sides: their `database` is a local path
//  that only works with a security-scoped bookmark, and the other importers do not take paths.
//
//  The file is external input on import: its size, entry counts and field lengths are bounded,
//  an unknown format or a newer version is refused, every value is checked again (ports,
//  engines, TLS modes, timeouts) and sanitized by ConnectionConfig's own rules (color, group,
//  hidden schemas). AI access "Always" falls back to the AI settings. Each row warns about what
//  a file could use against the user: an SSH tunnel host, a weakened protection, custom AI
//  rules, a connection string that names other hosts (then dropped). Scripts are never imported:
//  a file must not pick which of the user's scripts run against its host (a password command
//  would hand the user's password to it), so the row only names the file's valid script names
//  for the user to choose again. Warnings never carry file
//  content beyond a short, one-line label, except the SSH host and user: they are validated
//  (an entry with a host or user that could pass for another bastion is skipped) and shown
//  whole. Database and SSH hosts are ASCII DNS names, IPv4 or IPv6 literals (a bracketed IPv6
//  literal is saved bare); a Unicode host name is not round-tripped (the entry is skipped), so
//  no lookalike host reaches a warning or the import preview. A host, user or database that
//  starts with `-` or holds a control character skips the entry: scripts get them as arguments.
//

import Foundation

nonisolated struct DbloreConnectionFile: Codable, Equatable, Sendable {
  enum ReadError: Error, Equatable, Sendable {
    case fileNotFound
    case fileTooLarge
    case malformed
    case unknownFormat
    case newerVersion
    case tooManyEntries
    case fieldTooLong
  }

  static let formatName = "dblore-connections"
  static let currentVersion = 1
  static let maxFileSize = 5 * 1024 * 1024
  static let maxConnections = 1_000
  static let maxFavorites = 5_000
  /// Names, hosts, users, databases, connection strings and folders.
  static let maxFieldLength = 1_024
  static let maxSQLLength = 1_000_000
  /// Connect timeout range; the form leaves it unbounded.
  static let connectTimeoutRange = 1...3_600

  nonisolated struct SSH: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var username: String
    var authMethod: String
  }

  /// One allow-listed connection. Enum values are kept as raw text so a file is checked entry by
  /// entry rather than refused whole.
  nonisolated struct Connection: Codable, Equatable, Sendable {
    var name: String
    var databaseType: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var sslMode: String
    var ssh: SSH?
    var mongoURI: String?
    var timeoutSeconds: Int
    var protectionLevel: String
    var protectedMode: Bool
    var safeMode: Int?
    var commitStyle: String?
    var statementTimeoutSeconds: Int?
    var lockTimeoutSeconds: Int?
    var idleInTransactionTimeoutSeconds: Int?
    var rowCapOverride: Int?
    var aiAccess: String
    var aiRules: String
    var colorTag: String?
    var groupName: String?
    var hiddenSchemas: [String]
    /// Plain file names in the Application Scripts folder (absent from files without them)
    var preConnectScript: String?
    var postDisconnectScript: String?
    var passwordCommandScript: String?
    var scriptTimeoutSeconds: Int?
  }

  /// A favorite statement as plain text: no ids, no file references.
  nonisolated struct Favorite: Codable, Equatable, Sendable {
    var name: String
    var sql: String
  }

  /// Row warnings for settings weaker than a new connection's defaults. Protection level None
  /// and Safe Mode Silent are those defaults, so they are not flagged.
  enum Warning {
    static let tlsOff = "TLS is off: the connection is not encrypted."
    static let protectedModeOff = "Protected mode is off."
    static let aiAccessClamped = "AI access \"Always\" was changed to \"Use default\"."
    static let aiRules = "Custom AI rules included: review them before using AI."
  }

  /// What an import reads from a file.
  nonisolated struct Contents: Sendable {
    var connections: [ImportedConnection]
    var warnings: [String]
    var favorites: [Favorite]
  }

  var format: String
  var version: Int
  var exportedAt: Date
  var connections: [Connection]
  var favorites: [Favorite]

  init(
    connections: [Connection], favorites: [Favorite] = [], exportedAt: Date = Date()
  ) {
    format = Self.formatName
    version = Self.currentVersion
    self.exportedAt = exportedAt
    self.connections = connections
    self.favorites = favorites
  }

  // MARK: - Encoding

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  // MARK: - Decoding

  private struct Header: Decodable {
    var format: String?
    var version: Int?
  }

  /// Refuses an oversized file, another format, a newer version and over-long content.
  static func decode(_ data: Data) throws -> DbloreConnectionFile {
    guard data.count <= maxFileSize else { throw ReadError.fileTooLarge }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let header = try? decoder.decode(Header.self, from: data) else {
      throw ReadError.malformed
    }
    guard header.format == formatName, let version = header.version, version >= 1 else {
      throw ReadError.unknownFormat
    }
    guard version <= currentVersion else { throw ReadError.newerVersion }
    guard let file = try? decoder.decode(DbloreConnectionFile.self, from: data) else {
      throw ReadError.malformed
    }
    try file.checkLimits()
    return file
  }

  private func checkLimits() throws {
    guard connections.count <= Self.maxConnections, favorites.count <= Self.maxFavorites else {
      throw ReadError.tooManyEntries
    }
    let limit = Self.maxFieldLength
    func fits(_ text: String?) -> Bool { (text?.count ?? 0) <= limit }
    for item in connections {
      // Hidden schemas are normalized by ConnectionConfig itself.
      let fields: [String?] = [
        item.name, item.databaseType, item.host, item.database, item.username, item.sslMode,
        item.mongoURI, item.protectionLevel, item.commitStyle, item.aiAccess, item.colorTag,
        item.groupName, item.ssh?.host, item.ssh?.username, item.ssh?.authMethod,
        item.preConnectScript, item.postDisconnectScript, item.passwordCommandScript,
      ]
      guard fields.allSatisfy(fits), item.aiRules.count <= ConnectionConfig.aiRulesLimit else {
        throw ReadError.fieldTooLong
      }
    }
    for favorite in favorites {
      guard fits(favorite.name), favorite.sql.count <= Self.maxSQLLength
      else { throw ReadError.fieldTooLong }
    }
  }

  /// Reads a regular, non-symlinked file of at most `maxFileSize` bytes. `O_NOFOLLOW` and an
  /// `fstat` of the open descriptor check the file that is read, not a path that could change.
  static func read(from url: URL) throws -> Contents {
    let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReadError.fileNotFound }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw ReadError.fileNotFound
    }
    let data = try handle.read(upToCount: maxFileSize + 1) ?? Data()
    return try decode(data).contents()
  }

  /// The connections as import rows, without a password, and the favorites.
  func contents() -> Contents {
    var imported: [ImportedConnection] = []
    var warnings: [String] = []
    for item in connections {
      switch item.importedConnection() {
      case .success(let connection): imported.append(connection)
      case .failure(let skipped): warnings.append(skipped.message)
      }
    }
    return Contents(connections: imported, warnings: warnings, favorites: favorites)
  }
}

// MARK: - Export

nonisolated extension DbloreConnectionFile.Connection {
  /// The allow-listed fields of `config`. Nil for a file database.
  init?(config: ConnectionConfig) {
    guard config.databaseType.capabilities.usesNetwork else { return nil }
    name = config.name
    databaseType = config.databaseType.rawValue
    host = config.host
    port = config.port
    database = config.identityDatabase
    username = config.username
    sslMode = config.sslMode.rawValue
    ssh = config.sshTunnel.map {
      DbloreConnectionFile.SSH(
        host: $0.host, port: $0.port, username: $0.username, authMethod: $0.authMethod.rawValue)
    }
    // Rebuilt from its allow-listed options: never userinfo.
    mongoURI = config.mongoURI.flatMap { try? MongoURIParser.parse($0).storedURI }
    timeoutSeconds = config.timeoutSeconds
    protectionLevel = config.protectionLevel.rawValue
    protectedMode = config.protectedMode
    safeMode = config.safeMode?.rawValue
    commitStyle = config.commitStyle?.rawValue
    statementTimeoutSeconds = config.statementTimeoutSeconds
    lockTimeoutSeconds = config.lockTimeoutSeconds
    idleInTransactionTimeoutSeconds = config.idleInTransactionTimeoutSeconds
    rowCapOverride = config.rowCapOverride
    aiAccess = config.aiAccess.rawValue
    aiRules = config.aiRules
    colorTag = config.colorTag?.rawValue
    groupName = config.groupName
    hiddenSchemas = config.hiddenSchemas
    preConnectScript = config.preConnectScript
    postDisconnectScript = config.postDisconnectScript
    passwordCommandScript = config.passwordCommandScript
    scriptTimeoutSeconds = config.scriptTimeoutSeconds
  }
}

// MARK: - Import

nonisolated extension DbloreConnectionFile.Connection {
  struct Skipped: Error {
    var message: String
  }

  /// A connection to save, or why the entry is skipped. Unknown enum values skip the entry,
  /// rather than fall back to a weaker setting; an unknown color shows no color. AI access
  /// "Always" becomes "Use default".
  func importedConnection() -> Result<ImportedConnection, Skipped> {
    let label = "\"\(Self.sanitized(name.isEmpty ? host : name))\""
    func skip(_ reason: String) -> Result<ImportedConnection, Skipped> {
      .failure(Skipped(message: "Skipped \(label): \(reason)."))
    }
    guard let engine = DatabaseType(rawValue: databaseType) else {
      return skip("unsupported engine")
    }
    guard engine.capabilities.usesNetwork else { return skip("file databases are not imported") }
    guard !host.isEmpty else { return skip("no host") }
    guard let savedHost = Self.normalizedHost(host) else { return skip("invalid host") }
    guard ConnectionScriptRunner.isSafeArgument(username) else { return skip("invalid user") }
    guard ConnectionScriptRunner.isSafeArgument(database) else {
      return skip("invalid database")
    }
    guard Self.validPorts.contains(port) else { return skip("invalid port") }
    guard let tls = SSLMode(rawValue: sslMode),
      let protection = ConnectionProtectionLevel(rawValue: protectionLevel),
      let access = AIAccessPolicy(rawValue: aiAccess)
    else { return skip("a setting this version does not read") }
    let safe: SafeMode?
    if let safeMode {
      guard let value = SafeMode(rawValue: safeMode) else {
        return skip("a setting this version does not read")
      }
      safe = value
    } else {
      safe = nil
    }
    let style: CommitStyle?
    if let commitStyle {
      guard let value = CommitStyle(rawValue: commitStyle) else {
        return skip("a setting this version does not read")
      }
      style = value
    } else {
      style = nil
    }
    var warnings: [String] = []
    var tunnel: SSHTunnelConfig?
    if let ssh {
      guard let sshHost = Self.normalizedHost(ssh.host),
        Self.isValidSSHUsername(ssh.username),
        Self.validPorts.contains(ssh.port),
        let method = SSHTunnelConfig.AuthMethod(rawValue: ssh.authMethod)
      else { return skip("invalid SSH tunnel") }
      tunnel = SSHTunnelConfig(
        host: sshHost, port: ssh.port, username: ssh.username, authMethod: method)
      // Both are validated and bounded: shown whole, so no suffix of the host can be hidden.
      warnings.append(
        "SSH tunnel via host \"\(sshHost)\" port \(ssh.port), user \"\(ssh.username)\"")
      if ssh.username.isEmpty { warnings.append("SSH user is missing; set it after import.") }
    }

    var config = ConnectionConfig(
      databaseType: engine, host: savedHost, port: port, database: database, username: username,
      sslMode: tls, sshTunnel: tunnel,
      timeoutSeconds: SessionBrakeLimits.clamp(
        timeoutSeconds, to: DbloreConnectionFile.connectTimeoutRange, default: 30),
      protectionLevel: protection, name: name, safeMode: safe, protectedMode: protectedMode,
      statementTimeoutSeconds: SessionBrakeLimits.clampOverride(
        statementTimeoutSeconds, to: SessionBrakeLimits.statementTimeoutRange),
      lockTimeoutSeconds: SessionBrakeLimits.clampOverride(
        lockTimeoutSeconds, to: SessionBrakeLimits.lockTimeoutRange),
      idleInTransactionTimeoutSeconds: SessionBrakeLimits.clampOverride(
        idleInTransactionTimeoutSeconds, to: SessionBrakeLimits.idleTimeoutRange),
      rowCapOverride: SessionBrakeLimits.clampRowCap(rowCapOverride),
      colorTag: colorTag.flatMap(AccentColor.init(rawValue:)), groupName: groupName)
    config.commitStyle = style
    config.aiAccess = access == .always ? .useDefault : access
    config.aiRules = ConnectionConfig.clampedAIRules(aiRules)
    config.hiddenSchemas = ConnectionConfig.normalizedHiddenSchemas(hiddenSchemas)

    typealias Warning = DbloreConnectionFile.Warning
    if tls == .disable { warnings.append(Warning.tlsOff) }
    if !protectedMode { warnings.append(Warning.protectedModeOff) }
    if access == .always { warnings.append(Warning.aiAccessClamped) }
    if !aiRules.isEmpty { warnings.append(Warning.aiRules) }
    if let warning = scriptsWarning() { warnings.append(warning) }
    if let mongoURI {
      switch MongoURIParser.checkedMongoURI(
        mongoURI, host: savedHost, port: port, engine: engine, sslMode: tls)
      {
      case .success(let uri): config.mongoURI = uri
      case .failure(let mismatch): warnings.append(Self.message(for: mismatch))
      }
    }
    return .success(ImportedConnection(config: config, source: .dblore, warnings: warnings))
  }

  /// Scripts are never imported (see the file header): when the file names some, the row says
  /// so, with the names that pass `ConnectionScriptRunner.isValidName` (no quote, control or
  /// format character); others are left out.
  private func scriptsWarning() -> String? {
    let names = [preConnectScript, passwordCommandScript, postDisconnectScript].compactMap { $0 }
    guard !names.isEmpty else { return nil }
    var shown: [String] = []
    for name in names where ConnectionScriptRunner.isValidName(name) && !shown.contains(name) {
      shown.append(name)
    }
    let list = shown.isEmpty ? "" : " (\(shown.map { "\"\($0)\"" }.joined(separator: ", ")))"
    return "Scripts named in the file are not applied: choose them in the connection form\(list)."
  }

  /// The warning for a connection string `MongoURIParser.checkedMongoURI` refused.
  private static func message(for mismatch: MongoURIParser.URIMismatch) -> String {
    switch mismatch {
    case .host: "Connection string not imported: it does not match this connection's host."
    case .otherHosts: "Connection string not imported: it lists other hosts besides this one."
    case .tls: "Connection string not imported: its TLS option does not match the TLS mode."
    }
  }

  private static let validPorts = 1...65535

  /// The database or SSH host to save, or nil: a DNS name or IPv4 address (ASCII letters,
  /// digits, `.`, `-`, `_`; a MongoDB SRV name too) or an IPv6 literal with an optional ASCII
  /// `%zone`, at most 253 characters, not starting with `-`. A bracketed IPv6 literal is
  /// returned bare, the form the connectors pass on. Nothing that could pass for another host in
  /// a warning or the preview.
  private static func normalizedHost(_ host: String) -> String? {
    // A leading `-` could pass for an option of a command a script hands the host to
    guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-") else { return nil }
    let isDNSName = host.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
    }
    if isDNSName { return host }
    var literal = Substring(host)
    if literal.hasPrefix("["), literal.hasSuffix("]") { literal = literal.dropFirst().dropLast() }
    let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
      let zone = parts[1]
      guard !zone.isEmpty, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
        return nil
      }
    }
    // Only the address characters: `inet_pton` stops at a NUL, so it must not see one
    guard parts[0].allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else {
      return nil
    }
    var address = in6_addr()
    guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
      return nil
    }
    return String(literal)
  }

  /// At most 64 unicode scalars; no `"` (it delimits the warning), control, format or line
  /// separator characters, and no whitespace but a plain space (`DOMAIN\user` and names with a
  /// space are kept, as the form saves them). Empty is allowed: the importers save a tunnel
  /// without a user and ask for it after import.
  private static func isValidSSHUsername(_ username: String) -> Bool {
    let refused = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
      .union(CharacterSet(charactersIn: "\""))
    return username.unicodeScalars.count <= 64
      && !username.unicodeScalars.contains { $0 != " " && refused.contains($0) }
  }

  /// External labels in warnings: one line, bounded length. Control and format (Cf, such as
  /// bidi overrides) characters and line separators are removed.
  private static func sanitized(_ text: String) -> String {
    let removed = CharacterSet.controlCharacters.union(.newlines)
    let line = String(text.unicodeScalars.filter { !removed.contains($0) })
    return line.count > 60 ? String(line.prefix(60)) + "…" : line
  }
}
