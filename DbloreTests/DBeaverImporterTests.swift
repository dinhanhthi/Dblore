// DBeaverImporterTests.swift
// Unit tests for importing connections from a DBeaver `.dbeaver` workspace folder.
// Fixtures are built in memory and the secrets file is encrypted here with DBeaver's key.

import CommonCrypto
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("DBeaver importer")
struct DBeaverImporterTests {

  // MARK: - Fixtures

  private static let secretsFileName = "credentials-config.json"
  private static let dataSourcesFileName = "data-sources.json"
  /// DBeaver's published static key (`BaseProjectImpl.LOCAL_KEY_CACHE`).
  private static let key: [UInt8] = [
    0xba, 0xbb, 0x4a, 0x9f, 0x77, 0x4a, 0xb8, 0x53, 0xc9, 0x6c, 0x2d, 0x65, 0x3d, 0xfe, 0x54, 0x4a,
  ]

  @MainActor private final class Folder {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbeaver-import-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ data: Data, to name: String) throws {
      try data.write(to: url.appendingPathComponent(name))
    }
    func writeJSON(_ object: Any, to name: String) throws {
      try write(JSONSerialization.data(withJSONObject: object), to: name)
    }
    func writeSecrets(_ object: Any) throws {
      try write(
        DBeaverImporterTests.encrypt(JSONSerialization.data(withJSONObject: object)),
        to: DBeaverImporterTests.secretsFileName)
    }
  }

  /// Encrypts like DBeaver's `DefaultValueEncryptor`: random IV, then AES-128-CBC/PKCS7.
  private static func encrypt(_ plaintext: Data) -> Data {
    var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
    _ = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
    var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
    var written = 0
    let status = plaintext.withUnsafeBytes { input in
      CCCrypt(
        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        key, key.count, iv, input.baseAddress, plaintext.count, &output, output.count, &written)
    }
    precondition(status == kCCSuccess)
    return Data(iv) + Data(output.prefix(written))
  }

  private static func postgres(
    name: String = "Prod", host: String = "db.example.com", port: Any = "5433",
    database: String = "sales", user: String? = "alice", handlers: [String: Any]? = nil
  ) -> [String: Any] {
    var configuration: [String: Any] = [
      "host": host, "port": port, "database": database, "auth-model": "native",
    ]
    if let user { configuration["user"] = user }
    if let handlers { configuration["handlers"] = handlers }
    return [
      "provider": "postgresql", "driver": "postgres-jdbc", "name": name,
      "configuration": configuration,
    ]
  }

  private static func dataSources(_ connections: [String: Any]) -> [String: Any] {
    ["folders": [:], "connections": connections]
  }

  // MARK: - data-sources.json

  @Test("maps PostgreSQL connections and skips other providers with a warning")
  func mapsPostgresAndSkipsOthers() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "postgres-jdbc-1": Self.postgres(),
        "postgres-jdbc-2": Self.postgres(
          name: "", host: "localhost", port: 5432, database: "app", user: "bob"),
        "mysql8-1": [
          "provider": "mysql", "driver": "mysql8", "name": "Shop",
          "configuration": ["host": "m", "port": "3306", "database": "shop"],
        ],
        "redshift-1": [
          "provider": "postgresql", "driver": "redshift", "name": "Warehouse",
          "configuration": ["host": "r", "port": "5439", "database": "dw"],
        ],
      ]), to: Self.dataSourcesFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)

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
    #expect(prod.source == .dbeaver)
    let unnamed = try #require(result.connections.first { $0.config.host == "localhost" })
    #expect(unnamed.config.name == "bob@localhost/app")
    #expect(unnamed.config.port == 5432)
    #expect(result.warnings.count == 2)
    #expect(result.warnings.contains { $0.contains("mysql") })
    #expect(result.warnings.contains { $0.contains("redshift") })
  }

  @Test("maps the postgre_ssl handler mode")
  func sslMode() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "pg": Self.postgres(handlers: [
          "postgre_ssl": [
            "type": "CONFIG", "enabled": true, "properties": ["sslMode": "verify-full"],
          ]
        ])
      ]), to: Self.dataSourcesFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.first?.config.sslMode == .verifyFull)
  }

  @Test("maps an SSH tunnel with its password from the encrypted secrets file")
  func sshPasswordTunnel() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "pg": Self.postgres(handlers: [
          "ssh_tunnel": [
            "type": "TUNNEL", "enabled": true, "save-password": true,
            "properties": ["host": "bastion.example.com", "port": 2222, "authType": "PASSWORD"],
          ]
        ])
      ]), to: Self.dataSourcesFileName)
    try folder.writeSecrets([
      "pg": [
        "#connection": ["user": "dbuser", "password": "db-pass"],
        "network/ssh_tunnel": ["user": "jump", "password": "ssh-pass"],
      ]
    ])

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)

    #expect(result.warnings.isEmpty)
    let connection = try #require(result.connections.first)
    #expect(connection.config.username == "dbuser")
    #expect(connection.password == "db-pass")
    #expect(connection.config.password == "")
    #expect(
      connection.config.sshTunnel
        == SSHTunnelConfig(
          host: "bastion.example.com", port: 2222, username: "jump", authMethod: .password))
    #expect(connection.sshCredential == .password("ssh-pass"))
  }

  @Test("a key-auth SSH tunnel imports the config, no credential, and asks for the key")
  func sshKeyTunnel() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "pg": Self.postgres(handlers: [
          "ssh_tunnel": [
            "type": "TUNNEL", "enabled": true, "user": "jump",
            "properties": [
              "host": "bastion", "port": "22", "authType": "PUBLIC_KEY", "keyPath": "/k",
            ],
          ],
          "ssh_disabled_ignored": ["enabled": false],
        ])
      ]), to: Self.dataSourcesFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)

    let connection = try #require(result.connections.first)
    #expect(
      connection.config.sshTunnel
        == SSHTunnelConfig(host: "bastion", port: 22, username: "jump", authMethod: .privateKey))
    #expect(connection.sshCredential == nil)
    #expect(connection.warnings.contains { $0.contains("choose the SSH key again after import") })
  }

  @Test("a disabled SSH tunnel is ignored")
  func disabledTunnel() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "pg": Self.postgres(handlers: [
          "ssh_tunnel": ["enabled": false, "properties": ["host": "bastion"]]
        ])
      ]), to: Self.dataSourcesFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.first?.config.sshTunnel == nil)
  }

  // MARK: - Secrets file

  @Test("a missing secrets file imports without passwords and without warnings")
  func missingSecrets() throws {
    let folder = try Folder()
    try folder.writeJSON(Self.dataSources(["pg": Self.postgres()]), to: Self.dataSourcesFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.count == 1)
    #expect(result.connections.first?.password == nil)
    #expect(result.warnings.isEmpty)
  }

  @Test(
    "an unreadable secrets file imports without passwords and one warning",
    arguments: [
      Data("not encrypted at all".utf8),  // wrong length
      Data(repeating: 7, count: 48),  // bad padding
      Data(),  // empty
    ])
  func corruptSecrets(_ contents: Data) throws {
    let folder = try Folder()
    try folder.writeJSON(Self.dataSources(["pg": Self.postgres()]), to: Self.dataSourcesFileName)
    try folder.write(contents, to: Self.secretsFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.count == 1)
    #expect(result.connections.first?.password == nil)
    #expect(result.warnings == ["Saved passwords could not be read."])
  }

  @Test("encrypted content that is not JSON imports without passwords and one warning")
  func encryptedNonJSON() throws {
    let folder = try Folder()
    try folder.writeJSON(Self.dataSources(["pg": Self.postgres()]), to: Self.dataSourcesFileName)
    try folder.write(Self.encrypt(Data("hello, not json".utf8)), to: Self.secretsFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.first?.password == nil)
    #expect(result.warnings == ["Saved passwords could not be read."])
  }

  @Test("warnings never contain passwords")
  func warningsHaveNoSecrets() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources([
        "pg": Self.postgres(
          port: "SecretPortZ",
          handlers: ["ssh_tunnel": ["enabled": true, "properties": ["authType": "AGENT"]]]),
        "pg2": Self.postgres(
          name: "Two",
          handlers: [
            "ssh_tunnel": [
              "enabled": true, "properties": ["host": "b", "authType": "PUBLIC_KEY"],
            ]
          ]),
        "other": ["provider": "oracle", "driver": "oracle_thin", "name": "O"],
      ]), to: Self.dataSourcesFileName)
    try folder.writeSecrets([
      "pg": ["#connection": ["password": "SecretOne"]],
      "pg2": [
        "#connection": ["password": "SecretTwo"],
        "network/ssh_tunnel": ["password": "SecretThree"],
      ],
      "other": ["#connection": ["password": "SecretFour"]],
    ])

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)

    let keyAuth = try #require(result.connections.first { $0.config.name == "Two" })
    #expect(keyAuth.sshCredential == nil)
    let allWarnings = result.warnings + result.connections.flatMap(\.warnings)
    #expect(!allWarnings.isEmpty)
    #expect(allWarnings.allSatisfy { !$0.contains("Secret") })
    #expect(result.connections.allSatisfy { $0.config.password.isEmpty })
    #expect(result.connections.allSatisfy { !$0.description.contains("Secret") })
  }

  // MARK: - Errors

  @Test("a missing data-sources.json is an error")
  func missingDataSources() throws {
    let folder = try Folder()
    #expect(throws: DBeaverImporter.ImportError.dataSourcesNotFound) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
  }

  @Test("a malformed data-sources.json is an error")
  func malformedDataSources() throws {
    let folder = try Folder()
    try folder.write(Data("{ not json".utf8), to: Self.dataSourcesFileName)
    #expect(throws: DBeaverImporter.ImportError.malformedDataSources) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
    try folder.writeJSON(["connections": ["a", "b"]], to: Self.dataSourcesFileName)
    #expect(throws: DBeaverImporter.ImportError.malformedDataSources) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
  }

  @Test("an oversize data-sources.json is rejected")
  func oversizeDataSources() throws {
    let folder = try Folder()
    try folder.write(
      Data(count: DBeaverImporter.maxFileSize + 1), to: Self.dataSourcesFileName)
    #expect(throws: DBeaverImporter.ImportError.fileTooLarge) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
  }

  @Test("an oversize secrets file imports without passwords and one warning")
  func oversizeSecrets() throws {
    let folder = try Folder()
    try folder.writeJSON(Self.dataSources(["pg": Self.postgres()]), to: Self.dataSourcesFileName)
    try folder.write(Data(count: DBeaverImporter.maxFileSize + 1), to: Self.secretsFileName)

    let result = try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    #expect(result.connections.count == 1)
    #expect(result.warnings == ["Saved passwords could not be read."])
  }

  @Test("a symlinked data-sources.json is not followed")
  func symlinkRejected() throws {
    let folder = try Folder()
    try folder.writeJSON(
      Self.dataSources(["pg": Self.postgres(name: "Linked")]), to: "elsewhere.json")
    try FileManager.default.createSymbolicLink(
      at: folder.url.appendingPathComponent(Self.dataSourcesFileName),
      withDestinationURL: folder.url.appendingPathComponent("elsewhere.json"))
    #expect(throws: DBeaverImporter.ImportError.dataSourcesNotFound) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
  }

  @Test("a symlinked .dbeaver folder is not followed")
  func symlinkedFolderRejected() throws {
    let folder = try Folder()
    let target = folder.url.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try JSONSerialization.data(
      withJSONObject: Self.dataSources(["pg": Self.postgres(name: "Linked")])
    ).write(to: target.appendingPathComponent(Self.dataSourcesFileName))
    try FileManager.default.createSymbolicLink(
      at: folder.url.appendingPathComponent(".dbeaver"), withDestinationURL: target)
    #expect(throws: DBeaverImporter.ImportError.dataSourcesNotFound) {
      try DBeaverImporter.importConnections(fromWorkspaceFolder: folder.url)
    }
  }
}
