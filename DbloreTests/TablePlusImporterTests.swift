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

  @Test("maps PostgreSQL connections and skips other drivers and sockets with a warning")
  func mapsPostgresAndSkipsOthers() throws {
    let folder = try Folder()
    let file = try folder.writePlist([
      Self.postgres(),
      Self.postgres(name: "", host: "localhost", port: "", database: "", user: "bob"),
      ["ConnectionName": "Shop", "Driver": "MySQL", "DatabaseHost": "m"],
      Self.postgres(name: "Local socket", extra: ["isUseSocket": 1]),
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    #expect(result.connections.count == 2)
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
    #expect(prod.warnings == [TablePlusImporter.passwordWarning])
    let unnamed = try #require(result.connections.first { $0.config.host == "localhost" })
    #expect(unnamed.config.name == "bob@localhost/postgres")
    #expect(unnamed.config.port == 5432)
    #expect(result.warnings.count == 2)
    #expect(result.warnings.contains { $0.contains("\"Shop\"") && $0.contains("MySQL") })
    #expect(result.warnings.contains { $0.contains("\"Local socket\"") })
  }

  @Test("reads a binary plist")
  func binaryPlist() throws {
    let folder = try Folder()
    let file = try folder.writePlist([Self.postgres()], format: .binary)
    let result = try TablePlusImporter.importConnections(fromFile: file)
    #expect(result.connections.first?.config.host == "db.example.com")
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
    #expect(first.warnings == [TablePlusImporter.passwordWarning])
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
      ["ConnectionName": "Other", "Driver": "Redis", "DatabasePassword": "redis-secret"],
    ])

    let result = try TablePlusImporter.importConnections(fromFile: file)

    let connection = try #require(result.connections.first)
    #expect(connection.password == nil)
    #expect(connection.sshCredential == nil)
    let text = (result.warnings + connection.warnings).joined() + connection.description
    for secret in ["db-secret", "ssh-secret", "redis-secret"] {
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
