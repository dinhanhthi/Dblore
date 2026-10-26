//
//  MongoConnectionDraft.swift
//  Dblore
//
//  MongoDB rules of the connection form. The fields live in `ConnectionConfig`; the auth source
//  and the other allow-listed URI options live only in `mongoURI`, which is rebuilt through
//  `MongoURIParser` after every field edit and never holds credentials.
//

import Foundation

enum MongoConnectionDraft {
  /// A pasted connection string applied to the form.
  struct Paste: Equatable, Sendable {
    var config: ConnectionConfig
    /// Option keys the parser dropped, shown as a note.
    var ignoredOptions: [String]
  }

  /// The fields `mongoURI` is rebuilt from. The form rebuilds when this changes.
  struct FieldsKey: Equatable {
    var databaseType: DatabaseType
    var host: String
    var port: Int
    var database: String
    var sslMode: SSLMode

    init(_ config: ConnectionConfig) {
      databaseType = config.databaseType
      host = config.host
      port = config.port
      database = config.database
      sslMode = config.sslMode
    }
  }

  /// New MongoDB forms start without TLS, like a `mongodb://` URI without `tls`.
  static let defaultSSLMode: SSLMode = .disable

  /// MongoKitten always verifies chain and host name, so MongoDB TLS is two-valued (2.6 Q4).
  static func sslModes(for type: DatabaseType) -> [SSLMode] {
    type == .mongodb ? [.disable, .verifyFull] : SSLMode.allCases
  }

  /// The MongoDB mode a stored `sslMode` means: anything but Disable is Verify Full.
  static func normalizedSSLMode(_ mode: SSLMode) -> SSLMode {
    mode == .disable ? .disable : .verifyFull
  }

  /// Without transactions (MongoDB) there is nothing to review, so Review is not offered.
  static func commitStyles(for type: DatabaseType) -> [CommitStyle] {
    CommitStyle.allCases.filter { $0 != .review || type.capabilities.supportsTransactions }
  }

  static let authSourcePlaceholder = "Database above, or admin"
  static let authSourceHelp =
    "Database that stores the user. Empty uses the database above, or admin when that is "
    + "empty. Users created in admin (Atlas and most admin users) need admin here."

  // MARK: - Connection string

  /// Parses `text` and applies it to `config`. A password in the URI moves to `config.password`
  /// (saved in the Keychain); the stored `mongoURI` has no credentials.
  static func paste(_ text: String, into config: ConnectionConfig) throws -> Paste {
    let uri = try MongoURIParser.parse(text)
    var applied = uri.applied(to: config)
    if let password = uri.password { applied.password = password }
    return Paste(config: applied, ignoredOptions: uri.ignoredOptions)
  }

  /// Parser messages carry fixed text only, never values from the input.
  static func message(for error: any Error) -> String {
    (error as? MongoURIParser.ParseError)?.errorDescription
      ?? "The connection string is not valid."
  }

  static func ignoredOptionsNote(_ options: [String]) -> String? {
    guard !options.isEmpty else { return nil }
    return "Ignored options (not used by Dblore): " + options.joined(separator: ", ")
  }

  /// The URI shown in the Connection String tab: the stored one plus the user name, never the
  /// password.
  static func connectionString(for config: ConnectionConfig) -> String {
    guard let stored = rebuilt(config).mongoURI else { return "" }
    guard !config.username.isEmpty, let scheme = stored.range(of: "://") else { return stored }
    return stored.replacingCharacters(
      in: scheme, with: "://" + MongoURIParser.encoded(config.username) + "@")
  }

  // MARK: - Fields

  /// The `authSource` stored in `mongoURI` ("" when none).
  static func authSource(of config: ConnectionConfig) -> String {
    storedURI(of: config)?.authSource ?? ""
  }

  /// `config` with `mongoURI` rebuilt from the fields (and `authSource` when given, "" = none).
  /// Other engines get no URI. When the fields do not form a valid URI, the last valid one is
  /// kept (with the new auth source) and `fieldError` reports why: `mongoURI` is always nil or
  /// parseable, and `prepared` refuses to save the mismatch.
  static func rebuilt(_ config: ConnectionConfig, authSource: String? = nil) -> ConnectionConfig {
    var config = config
    guard config.databaseType == .mongodb else {
      config.mongoURI = nil
      return config
    }
    config.sslMode = normalizedSSLMode(config.sslMode)
    var base = storedURI(of: config) ?? defaultURI
    if let authSource { base.authSource = authSource.isEmpty ? nil : authSource }
    config.mongoURI = ((try? reparsed(applyingFields(of: config, to: base))) ?? base).storedURI
    return config
  }

  /// Why the fields do not form a valid connection (nil when they do, or the host is empty).
  static func fieldError(_ config: ConnectionConfig) -> String? {
    guard config.databaseType == .mongodb, !config.host.isEmpty else { return nil }
    do {
      _ = try validated(config)
      return nil
    } catch {
      return message(for: error)
    }
  }

  /// The config to test, connect or save: `mongoURI` matches the fields, or this throws the
  /// parser's error. Other engines lose any `mongoURI`.
  static func prepared(_ config: ConnectionConfig) throws -> ConnectionConfig {
    let config = rebuilt(config)
    guard config.databaseType == .mongodb else { return config }
    _ = try validated(config)
    return config
  }

  /// TLS is off and the connection leaves this Mac (or names a `+srv` cluster).
  static func tlsWarning(for config: ConnectionConfig) -> String? {
    guard config.databaseType == .mongodb, normalizedSSLMode(config.sslMode) == .disable,
      !config.host.isEmpty
    else { return nil }
    let uri = storedURI(of: config)
    let hosts = [config.host] + (uri?.hosts.dropFirst().map(\.name) ?? [])
    guard uri?.isSRV == true || hosts.contains(where: { !isLoopback($0) }) else { return nil }
    return "TLS is off: the password and data cross the network unencrypted. Choose Verify Full "
      + "unless this network is trusted."
  }

  // MARK: - Private

  private static let defaultURI = ParsedMongoURI(
    isSRV: false, hosts: [ParsedMongoURI.Host(name: "localhost", port: nil)], database: nil,
    username: nil, password: nil, authSource: nil, authMechanism: nil, tls: nil, replicaSet: nil,
    directConnection: nil, appName: nil, readPreference: nil, ignoredOptions: [])

  /// The stored URI, nil when absent or not parseable.
  private static func storedURI(of config: ConnectionConfig) -> ParsedMongoURI? {
    config.mongoURI.flatMap { try? MongoURIParser.parse($0) }
  }

  /// `base` with the first host, port, database and TLS of `config`. A `+srv` host has no port;
  /// an unchanged default port stays implicit, as does TLS where the scheme already implies it.
  /// A host with a URI delimiter or whitespace is refused, so the parser cannot split it into
  /// other hosts, a database or options.
  private static func applyingFields(
    of config: ConnectionConfig, to base: ParsedMongoURI
  ) throws -> ParsedMongoURI {
    guard !config.host.contains(where: { "?/#@,".contains($0) || $0.isWhitespace }) else {
      throw MongoURIParser.ParseError.invalidHost
    }
    var uri = base
    uri.ignoredOptions = []
    uri.hosts[0].name = config.host
    if !uri.isSRV, config.port != (uri.hosts[0].port ?? MongoURIParser.defaultPort) {
      uri.hosts[0].port = config.port
    }
    uri.database = config.database.isEmpty ? nil : config.database
    let usesTLS = config.sslMode != .disable
    uri.tls = (uri.tls == nil && usesTLS == uri.isSRV) ? nil : usesTLS
    return uri
  }

  /// The parser's own validation of `uri`, through its stored text.
  private static func reparsed(_ uri: ParsedMongoURI) throws -> ParsedMongoURI {
    try MongoURIParser.parse(uri.storedURI)
  }

  private static func validated(_ config: ConnectionConfig) throws -> ParsedMongoURI {
    try reparsed(applyingFields(of: config, to: storedURI(of: config) ?? defaultURI))
  }

  private static func isLoopback(_ host: String) -> Bool {
    let name = host.lowercased()
    if name == "localhost" || name == "::1" { return true }
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
  }
}
