// DbloreConnectionFileTests.swift
// The Dblore connections export file: no secret ever reaches it, it reads back what it wrote,
// and a file of another format or a newer version is refused.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Dblore connection file")
struct DbloreConnectionFileTests {

  /// A PostgreSQL connection with every allow-listed field set to a non-default value.
  private static func fullConfig() -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "db.example.com", port: 6543, database: "sales", username: "ada",
      sslMode: .verifyFull,
      sshTunnel: SSHTunnelConfig(
        host: "bastion.example.com", port: 2222, username: "jump", authMethod: .password),
      timeoutSeconds: 45, protectionLevel: .schemaOnly, name: "Sales", safeMode: .alertRead,
      protectedMode: false, statementTimeoutSeconds: 120, lockTimeoutSeconds: 9,
      idleInTransactionTimeoutSeconds: 900, rowCapOverride: 5_000, colorTag: .purple,
      groupName: "Prod")
    config.commitStyle = .confirm
    config.aiAccess = .never
    config.aiRules = "Never touch billing."
    config.hiddenSchemas = ["audit", "pg_toast"]
    return config
  }

  private static func json(_ data: Data) throws -> String {
    try #require(String(data: data, encoding: .utf8))
  }

  /// Every key in a JSON value, at any depth.
  private static func keys(in value: Any) -> Set<String> {
    if let object = value as? [String: Any] {
      return object.reduce(into: Set(object.keys)) { $0.formUnion(keys(in: $1.value)) }
    }
    if let array = value as? [Any] {
      return array.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
    }
    return []
  }

  @Test("No secret, key reference, certificate or bookmark reaches the file")
  func secretsNeverEncoded() throws {
    var config = Self.fullConfig()
    config.password = "PLANTED-db-password"
    config.sshTunnel = SSHTunnelConfig(
      host: "bastion.example.com", username: "jump", authMethod: .privateKey,
      keyAlgorithm: "PLANTED-key-algorithm", keyFingerprint: "PLANTED-key-fingerprint")
    config.clientCertificate = ClientCertificateInfo(
      subject: "PLANTED-cert-subject", expiry: Date(), hasCA: true)
    config.fileBookmark = Data("PLANTED-bookmark".utf8)
    var mongo = ConnectionConfig(
      databaseType: .mongodb, host: "mongo.example.com", port: 27017, database: "app",
      username: "ada", password: "PLANTED-mongo-password")
    mongo.mongoURI = "mongodb://ada:PLANTED-uri-secret@mongo.example.com:27017/app?replicaSet=rs0"
    mongo.mongoHomeDatabase = "app"
    let sqlite = ConnectionConfig(
      databaseType: .sqlite, database: "/Users/ada/PLANTED-path.sqlite",
      fileBookmark: Data("PLANTED-sqlite-bookmark".utf8))

    let file = DbloreConnectionFile(
      connections: [config, mongo, sqlite].compactMap(DbloreConnectionFile.Connection.init))
    let data = try file.encoded()
    let text = try Self.json(data)

    #expect(file.connections.count == 2, "a file database is left out")
    for planted in [
      "PLANTED", "UExBTlRFRC", "password\"", "bookmark", "certificate", "fingerprint",
      "passphrase", "keyAlgorithm", "credential", "mongoHomeDatabase", "rememberConnection",
    ] {
      #expect(!text.contains(planted), "found \(planted)")
    }
    let keys = Self.keys(in: try JSONSerialization.jsonObject(with: data))
    let forbidden = ["password", "bookmark", "certificate", "passphrase", "key", "credential"]
    let leaked = keys.filter { key in forbidden.contains { key.lowercased().contains($0) } }
    #expect(leaked.isEmpty, "secret-like keys: \(leaked.sorted())")
    #expect(text.contains("replicaSet=rs0"), "the connection string keeps its options")
  }

  @Test("A written file reads back the same connections and favorites")
  func roundTrip() throws {
    let config = Self.fullConfig()
    let favorite = DbloreConnectionFile.Favorite(
      name: "Top customers", sql: "SELECT * FROM customers LIMIT 10;")
    let file = DbloreConnectionFile(
      connections: [try #require(DbloreConnectionFile.Connection(config: config))],
      favorites: [favorite], exportedAt: Date(timeIntervalSince1970: 1_800_000_000))

    let decoded = try DbloreConnectionFile.decode(try file.encoded())
    #expect(decoded == file)

    let contents = decoded.contents()
    #expect(contents.warnings.isEmpty)
    #expect(contents.favorites == [favorite])
    let imported = try #require(contents.connections.first)
    #expect(imported.password == nil)
    #expect(imported.source == .dblore)
    #expect(imported.config == config)
    #expect(
      imported.warnings.contains(
        "SSH tunnel via host \"bastion.example.com\" port 2222, user \"jump\""))

    // A key this version does not write (an older draft's favorite folder) is ignored.
    let lenient = try DbloreConnectionFile.decode(
      Data(
        #"{"format":"dblore-connections","version":1,"exportedAt":"2027-01-15T00:00:00Z","connections":[],"favorites":[{"name":"a","sql":"SELECT 1","folder":"x"}]}"#
          .utf8))
    #expect(lenient.favorites == [.init(name: "a", sql: "SELECT 1")])
  }

  /// A MongoDB row at mongo.example.com:27017 carrying `uri`.
  private static func mongoEntry(
    uri: String, sslMode: SSLMode
  ) throws
    -> DbloreConnectionFile.Connection
  {
    let config = ConnectionConfig(
      databaseType: .mongodb, host: "mongo.example.com", port: 27017, database: "app",
      username: "ada", sslMode: sslMode)
    var entry = try #require(DbloreConnectionFile.Connection(config: config))
    entry.mongoURI = uri
    return entry
  }

  @Test(
    "A connection string is kept only when every host and its TLS option match the row",
    arguments: [
      ("mongodb://mongo.example.com:27017/app", SSLMode.verifyFull, true),
      ("mongodb+srv://mongo.example.com/app", .verifyFull, true),
      ("mongodb://evil.example.com:27017/app", .verifyFull, false),
      ("mongodb://mongo.example.com:27017,evil.example.com:27017/app", .verifyFull, false),
      ("mongodb://mongo.example.com:27017/app?tls=false", .verifyFull, false),
      ("mongodb://mongo.example.com:27017/app?ssl=true", .disable, false),
    ] as [(String, SSLMode, Bool)])
  func mongoURIMustMatchRow(uri: String, sslMode: SSLMode, kept: Bool) throws {
    let entry = try Self.mongoEntry(uri: uri, sslMode: sslMode)
    let imported = try entry.importedConnection().get()
    let dropped = imported.warnings.contains { $0.hasPrefix("Connection string not imported") }
    #expect((imported.config.mongoURI != nil) == kept)
    #expect(dropped == !kept)
  }

  @Test("Weakened protections are flagged, AI access Always is clamped and AI rules are capped")
  func flagsWeakenedProtections() throws {
    var entry = try #require(DbloreConnectionFile.Connection(config: Self.fullConfig()))
    entry.sslMode = SSLMode.disable.rawValue
    entry.protectionLevel = ConnectionProtectionLevel.none.rawValue
    entry.safeMode = SafeMode.silent.rawValue
    entry.protectedMode = false
    entry.aiAccess = AIAccessPolicy.always.rawValue
    entry.aiRules = String(repeating: "r", count: ConnectionConfig.aiRulesLimit)

    let contents = try DbloreConnectionFile.decode(
      try DbloreConnectionFile(connections: [entry]).encoded()
    ).contents()
    let imported = try #require(contents.connections.first)

    #expect(imported.config.aiAccess == .useDefault)
    for expected in [
      DbloreConnectionFile.Warning.tlsOff, DbloreConnectionFile.Warning.protectedModeOff,
      DbloreConnectionFile.Warning.aiAccessClamped, DbloreConnectionFile.Warning.aiRules,
      "SSH tunnel via host \"bastion.example.com\" port 2222, user \"jump\"",
    ] {
      #expect(imported.warnings.contains(expected), "missing \(expected)")
    }
    // Protection None and Safe Mode Silent are the defaults of a new connection: no warning
    #expect(imported.warnings.count == 5)

    entry.aiRules += "r"
    #expect(throws: DbloreConnectionFile.ReadError.fieldTooLong) {
      try DbloreConnectionFile.decode(try DbloreConnectionFile(connections: [entry]).encoded())
    }
  }

  @Test(
    "An SSH host or user that could hide the real bastion skips the entry; a valid one is shown whole",
    arguments: [
      (String(repeating: "a", count: 254), "ops", nil),
      ("bastion.corp.example.com\u{2024}attacker.net", "ops", nil),
      ("bastion.corp/x", "ops", nil),
      ("bastion example.com", "ops", nil),
      ("bastion\".example.com", "ops", nil),
      ("bastion.example.com", "jump\"", nil),
      ("bastion.example.com", "CORP\\jdoe", "bastion.example.com"),
      ("bastion.example.com", "Jane Doe", "bastion.example.com"),
      ("bastion.example.com", "jump\u{00A0}x", nil),
      ("bastion.example.com", "jump\u{202E}", nil),
      ("::1\u{0}x", "ops", nil),
      ("[::1\u{0}]", "ops", nil),
      ("::1", "ops", "::1"),
      ("fe80::1%en0", "ops", "fe80::1%en0"),
      ("[2001:db8::1]", "ops", "2001:db8::1"),
      ("bastion.example.com", "jdoe@corp.example.com", "bastion.example.com"),
      (
        String(repeating: "b", count: 200) + ".corp.example.com.attacker.net", "ops",
        String(repeating: "b", count: 200) + ".corp.example.com.attacker.net"
      ),
    ] as [(String, String, String?)])
  func sshTunnelIsValidatedAndShownWhole(host: String, user: String, savedHost: String?) throws {
    var entry = try #require(DbloreConnectionFile.Connection(config: Self.fullConfig()))
    entry.ssh?.host = host
    entry.ssh?.username = user

    switch entry.importedConnection() {
    case .success(let imported):
      let expected = try #require(savedHost, "kept \(host) / \(user)")
      #expect(imported.config.sshTunnel?.host == expected)
      #expect(
        imported.warnings.contains(
          "SSH tunnel via host \"\(expected)\" port 2222, user \"\(user)\""))
    case .failure(let skipped):
      #expect(savedHost == nil)
      #expect(skipped.message == "Skipped \"Sales\": invalid SSH tunnel.")
    }
  }

  @Test("A tunnel without a user is kept, with the importers' note to set it")
  func sshTunnelWithoutUser() throws {
    var entry = try #require(DbloreConnectionFile.Connection(config: Self.fullConfig()))
    entry.ssh?.username = ""

    let imported = try entry.importedConnection().get()
    #expect(imported.config.sshTunnel?.username == "")
    #expect(imported.warnings.contains("SSH user is missing; set it after import."))
  }

  @Test("A symlink to an export file is refused")
  func refusesSymlink() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("real.json")
    try DbloreConnectionFile(connections: []).encoded().write(to: target)
    let link = folder.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: DbloreConnectionFile.ReadError.fileNotFound) {
      try DbloreConnectionFile.read(from: link)
    }
    #expect(try DbloreConnectionFile.read(from: target).connections.isEmpty)
  }

  @Test(
    "Another format, a newer version or an oversized file is refused",
    arguments: [
      (
        Data(#"{"format":"other-app","version":1,"connections":[],"favorites":[]}"#.utf8),
        .unknownFormat
      ),
      (Data(#"{"format":"dblore-connections","version":2,"shape":"new"}"#.utf8), .newerVersion),
      (Data(#"{"format":"dblore-connections"}"#.utf8), .unknownFormat),
      (Data(count: DbloreConnectionFile.maxFileSize + 1), .fileTooLarge),
    ] as [(Data, DbloreConnectionFile.ReadError)])
  func refusesUnknownFiles(data: Data, expected: DbloreConnectionFile.ReadError) {
    #expect(throws: expected) { try DbloreConnectionFile.decode(data) }
  }
}
