// TablePlusImporterTests.swift
// Unit tests for importing connections from TablePlus's `Connections.plist`.
// Fixtures are built in memory with the key names TablePlus writes.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("TablePlus importer")
struct TablePlusImporterTests {

  // MARK: - Fixtures

  @MainActor private final class Folder {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tableplus-import-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ data: Data, to name: String = "Connections.plist") throws -> URL {
      let file = url.appendingPathComponent(name)
      try data.write(to: file)
      return file
    }
    func writePlist(
      _ object: Any, format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> URL {
      try write(
        PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0))
    }
  }

  private static func postgres(
    name: String = "Prod", host: String = "db.example.com", port: String = "5433",
    database: String = "sales", user: String = "alice", extra: [String: Any] = [:]
  ) -> [String: Any] {
    var entry: [String: Any] = [
      "ID": UUID().uuidString, "ConnectionName": name, "Driver": "PostgreSQL",
      "DatabaseHost": host, "DatabasePort": port, "DatabaseName": database,
      "DatabaseUser": user, "isOverSSH": false, "Enviroment": "production",
    ]
    entry.merge(extra) { _, new in new }
    return entry
  }

  // MARK: - Mapping

  @Test("maps PostgreSQL, MySQL and Redis connections and skips sockets with a warning")
  func mapsPostgresAndSkipsOthers() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(),
      Self.postgres(name: "", host: "localhost", port: "", database: "", user: "bob"),
      ["ConnectionName": "Shop", "Driver": "MySQL", "DatabaseHost": "m"],
      ["ConnectionName": "Cache", "Driver": "Redis", "DatabaseHost": "r"],
      Self.postgres(name: "Local socket", extra: ["isUseSocket": 1]),
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    #expect(result.connections.count == 4)
    let prod = try #require(result.connections.first { $0.config.name == "Prod" })
    #expect(prod.config.databaseType == .postgresql)
    #expect(prod.config.host == "db.example.com")
    #expect(prod.config.port == 5433)
    #expect(prod.config.database == "sales")
    #expect(prod.config.username == "alice")
    #expect(prod.config.sslMode == .prefer)
    #expect(prod.config.sshTunnel == nil)
    #expect(prod.password == nil)
    #expect(prod.source == .tablePlus)
    #expect(prod.warnings.isEmpty)
    let unnamed = try #require(result.connections.first { $0.config.host == "localhost" })
    #expect(unnamed.config.name == "bob@localhost/postgres")
    #expect(unnamed.config.port == 5432)
    let shop = try #require(result.connections.first { $0.config.name == "Shop" })
    #expect(shop.config.databaseType == .mysql)
    #expect(shop.config.port == 3306)
    #expect(shop.config.database == "")
    #expect(shop.warnings.contains(PostgresURIParser.missingDatabaseWarning))
    let cache = try #require(result.connections.first { $0.config.name == "Cache" })
    #expect(cache.config.databaseType == .redis)
    #expect(cache.config.host == "r")
    #expect(cache.config.port == 6379)
    #expect(cache.config.database == "0")
    #expect(cache.config.username == "")
    #expect(cache.config.sslMode == .verifyFull)
    #expect(cache.password == nil)
    #expect(result.warnings.count == 1)
    #expect(result.warnings.contains { $0.contains("\"Local socket\"") })
  }

  @Test("maps Redis entries: user, port, a database index of the form's range, and TLS")
  func mapsRedis() throws {
    func redis(_ name: String, database: Any, tls: Any? = nil) -> [String: Any] {
      var entry: [String: Any] = [
        "ConnectionName": name, "Driver": "Redis", "DatabaseHost": "cache.example.com",
        "DatabasePort": "6380", "DatabaseUser": "app", "DatabaseName": database,
      ]
      entry["tLSMode"] = tls
      return entry
    }
    let folder = try Folder()
    let file = try folder.writePlist([
      redis("Exact", database: "3", tls: "verify-full"),
      redis("Plain", database: "", tls: "disable"),
      redis("Index", database: "15", tls: 0),
      redis("Name", database: "sales", tls: "require"),
      redis("Past", database: "16"),
      redis("Padded", database: "03", tls: 4),
      redis("Number", database: 7, tls: "verify-full"),
      redis("Listed", database: [3], tls: "disable"),
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    #expect(result.warnings.isEmpty)
    #expect(result.connections.count == 8)
    func connection(_ name: String) throws -> ImportedConnection {
      try #require(result.connections.first { $0.config.name == name })
    }
    let exact = try connection("Exact")
    #expect(exact.config.databaseType == .redis)
    #expect(exact.config.host == "cache.example.com")
    #expect(exact.config.port == 6380)
    #expect(exact.config.username == "app")
    #expect(exact.config.database == "3")
    #expect(exact.config.sslMode == .verifyFull)
    #expect(exact.warnings.isEmpty)
    let plain = try connection("Plain")
    #expect(plain.config.database == "0")
    #expect(plain.config.sslMode == .disable)
    #expect(plain.warnings.isEmpty)
    // A TLS setting other than the two Redis modes, or none, is Verify Full with a note
    for name in ["Index", "Name", "Past", "Padded"] {
      let imported = try connection(name)
      #expect(imported.config.sslMode == .verifyFull, "\(name)")
      #expect(imported.warnings.contains { $0.contains("TLS mode") }, "\(name)")
    }
    #expect(try connection("Index").config.database == "15")
    #expect(try connection("Number").config.database == "7")
    // Never another database than the one named: an index the form refuses opens 0, with a note
    for name in ["Name", "Past", "Padded", "Listed"] {
      let imported = try connection(name)
      #expect(imported.config.database == "0", "\(name)")
      #expect(imported.warnings.contains { $0.contains("database index") }, "\(name)")
    }
    for name in ["Exact", "Plain", "Index", "Number"] {
      #expect(!(try connection(name)).warnings.contains { $0.contains("database index") })
    }
    for imported in result.connections {
      #expect(MongoConnectionDraft.sslModes(for: .redis).contains(imported.config.sslMode))
      #expect(ConnectionFormContent.redisDatabaseIndexError(imported.config) == nil)
    }
  }

  @Test("maps MySQL and MariaDB entries with their database, port and SSH tunnel")
  func mapsMySQLAndMariaDB() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(
        name: "Shop", host: "mysql.example.com", port: "3307", database: "shop", user: "root",
        extra: [
          "Driver": "MySQL", "tLSMode": 0, "isOverSSH": 1, "ServerAddress": "bastion",
          "ServerPort": "22", "ServerUser": "jump", "isUsePrivateKey": 0,
        ]),
      Self.postgres(
        name: "Maria", host: "maria.local", port: "", database: "app", user: "app",
        extra: ["Driver": "MariaDB"]),
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    #expect(result.warnings.isEmpty)
    let shop = try #require(result.connections.first { $0.config.name == "Shop" })
    #expect(shop.config.databaseType == .mysql)
    #expect(shop.config.host == "mysql.example.com")
    #expect(shop.config.port == 3307)
    #expect(shop.config.database == "shop")
    #expect(shop.config.username == "root")
    #expect(shop.config.sslMode == .prefer)
    #expect(shop.config.sshTunnel?.host == "bastion")
    #expect(shop.password == nil)
    #expect(!shop.warnings.contains(PostgresURIParser.missingDatabaseWarning))
    let maria = try #require(result.connections.first { $0.config.name == "Maria" })
    #expect(maria.config.databaseType == .mysql)
    #expect(maria.config.port == 3306)
    #expect(maria.warnings.isEmpty)
  }

  @Test("maps tLSMode 0 to prefer and warns on a mode it cannot map")
  func tlsMode() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(name: "A", extra: ["tLSMode": 0]),
      Self.postgres(name: "B", extra: ["tLSMode": 4]),
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    let first = try #require(result.connections.first { $0.config.name == "A" })
    #expect(first.config.sslMode == .prefer)
    #expect(first.warnings.isEmpty)
    let second = try #require(result.connections.first { $0.config.name == "B" })
    #expect(second.config.sslMode == .prefer)
    #expect(second.warnings.contains { $0.contains("TLS mode") })
  }

  @Test("maps an SSH password tunnel without its secret")
  func sshPasswordTunnel() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(extra: [
        "isOverSSH": 1, "ServerAddress": "bastion.example.com", "ServerPort": "2222",
        "ServerUser": "jump", "isUsePrivateKey": false,
      ])
    ])

    let connection = try #require(
      try TablePlusImporter.importConnections(fromFile: file).connections.first)

    #expect(
      connection.config.sshTunnel
        == SSHTunnelConfig(
          host: "bastion.example.com", port: 2222, username: "jump", authMethod: .password))
    #expect(connection.sshCredential == nil)
    #expect(connection.warnings.contains { $0.contains("SSH password not imported") })
  }

  @Test("maps an SSH key tunnel and asks for the key")
  func sshKeyTunnel() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(extra: [
        "isOverSSH": true, "ServerAddress": "bastion", "ServerUser": "jump",
        "isUsePrivateKey": true, "ServerPrivateKeyName": "/Users/x/.ssh/id_ed25519",
      ])
    ])

    let connection = try #require(
      try TablePlusImporter.importConnections(fromFile: file).connections.first)

    #expect(
      connection.config.sshTunnel
        == SSHTunnelConfig(host: "bastion", port: 22, username: "jump", authMethod: .privateKey))
    #expect(connection.sshCredential == nil)
    #expect(connection.warnings.contains { $0.contains("choose the SSH key again after import") })
  }

  @Test("an SSH entry without a host is skipped")
  func sshWithoutHost() throws {
    let folder = try Folder()
    let file = try folder.writePlist([Self.postgres(extra: ["isOverSSH": 1])])
    let result = try TablePlusImporter.importConnections(fromFile: file)
    #expect(result.connections.isEmpty)
    #expect(result.warnings.contains { $0.contains("\"Prod\"") && $0.contains("SSH") })
  }

  @Test("passwords in the file are never imported or echoed")
  func passwordsNeverImported() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(extra: [
        "DatabasePassword": "db-secret", "isOverSSH": 1, "ServerAddress": "b",
        "ServerPassword": "ssh-secret",
      ]),
      [
        "ConnectionName": "Other", "Driver": "Redis", "DatabaseHost": "r",
        "DatabasePassword": "redis-secret",
      ],
      ["ConnectionName": "Legacy", "Driver": "Oracle", "DatabasePassword": "oracle-secret"],
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    let connection = try #require(result.connections.first { $0.config.name == "Prod" })
    #expect(connection.password == nil)
    #expect(connection.sshCredential == nil)
    let redis = try #require(result.connections.first { $0.config.name == "Other" })
    #expect(redis.config.databaseType == .redis)
    #expect(redis.password == nil)
    #expect(redis.config.password.isEmpty)
    #expect(result.warnings.contains { $0.contains("\"Legacy\"") && $0.contains("Oracle") })
    let text =
      (result.warnings + connection.warnings + redis.warnings).joined()
      + connection.description + redis.description
    for secret in ["db-secret", "ssh-secret", "redis-secret", "oracle-secret"] {
      #expect(!text.contains(secret))
    }
  }

  // MARK: - Errors

  @Test("rejects a file larger than the limit")
  func oversize() throws {
    let folder = try Folder()
    let file = try folder.write(Data(count: TablePlusImporter.maxFileSize + 1))
    #expect(throws: TablePlusImporter.ImportError.fileTooLarge) {
      try TablePlusImporter.importConnections(fromFile: file)
    }
  }

  @Test("rejects malformed content and a root that is not an array")
  func malformed() throws {
    let folder = try Folder()
    let garbage = try folder.write(Data("not a plist {".utf8), to: "a.plist")
    #expect(throws: TablePlusImporter.ImportError.malformedConnections) {
      try TablePlusImporter.importConnections(fromFile: garbage)
    }
    let dictionary = try folder.writePlist(["ConnectionName": "x"])
    #expect(throws: TablePlusImporter.ImportError.malformedConnections) {
      try TablePlusImporter.importConnections(fromFile: dictionary)
    }
  }

  @Test("reports a missing file and an encrypted export")
  func missingAndEncrypted() throws {
    let folder = try Folder()
    #expect(throws: TablePlusImporter.ImportError.fileNotFound) {
      try TablePlusImporter.importConnections(
        fromFile: folder.url.appendingPathComponent("Connections.plist"))
    }
    let export = try folder.write(Data([3, 1, 0, 0]), to: "x.tableplusconnection")
    #expect(throws: TablePlusImporter.ImportError.encryptedExportNotSupported) {
      try TablePlusImporter.importConnections(fromFile: export)
    }
  }

  @Test("a symlink or a folder is not read")
  func symlinkAndFolderRejected() throws {
    let folder = try Folder()
    let real = try folder.writePlist([Self.postgres()])
    let link = folder.url.appendingPathComponent("Link.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: TablePlusImporter.ImportError.fileNotFound) {
      try TablePlusImporter.importConnections(fromFile: link)
    }
    let directory = folder.url.appendingPathComponent("Folder.plist", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(throws: TablePlusImporter.ImportError.fileNotFound) {
      try TablePlusImporter.importConnections(fromFile: directory)
    }
  }
}
