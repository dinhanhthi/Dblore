// DataGripImporterTests.swift
// Unit tests for importing connections from a DataGrip project's `.idea` folder.
// Fixtures follow the layout DataGrip writes to `dataSources.xml` and `dataSources.local.xml`.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("DataGrip importer")
struct DataGripImporterTests {

  // MARK: - Fixtures

  @MainActor private final class Folder {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datagrip-import-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, to name: String = DataGripImporter.dataSourcesFileName) throws {
      try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }
  }

  private static func source(
    name: String, uuid: String = UUID().uuidString, driver: String = "postgresql",
    url: String?
  ) -> String {
    let jdbc = url.map { "<jdbc-url>\($0)</jdbc-url>" } ?? ""
    return """
          <data-source source="LOCAL" name="\(name)" uuid="\(uuid)">
            <driver-ref>\(driver)</driver-ref>
            <synchronize>true</synchronize>
            <jdbc-driver>org.postgresql.Driver</jdbc-driver>
            \(jdbc)
            <working-dir>$ProjectFileDir$</working-dir>
          </data-source>
      """
  }

  private static func dataSources(_ sources: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <project version="4">
      <component name="DataSourceManagerImpl" format="xml" multifile-model="true">
    \(sources.joined(separator: "\n"))
      </component>
    </project>
    """
  }

  private static func local(_ sources: [(uuid: String, body: String)]) -> String {
    let items = sources.map {
      """
          <data-source name="ignored" uuid="\($0.uuid)">
            <secret-storage>master_key</secret-storage>
            \($0.body)
          </data-source>
      """
    }
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <project version="4">
        <component name="dataSourceStorageLocal" created-in="DB-253.1">
      \(items.joined(separator: "\n"))
        </component>
      </project>
      """
  }

  // MARK: - Mapping

  @Test("maps host, port, database, sslmode and the user name from the local file")
  func mapsPostgres() throws {
    let folder = try Folder()
    try folder.write(
      Self.dataSources([
        Self.source(
          name: "Prod", uuid: "u1",
          url: "jdbc:postgresql://db.example.com:5433/sales?sslmode=require&amp;password=url-secret"
        )
      ]))
    try folder.write(
      Self.local([("u1", "<user-name>alice</user-name>")]),
      to: DataGripImporter.localDataSourcesFileName)

    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)

    let connection = try #require(result.connections.first)
    #expect(result.connections.count == 1)
    #expect(connection.config.name == "Prod")
    #expect(connection.config.databaseType == .postgresql)
    #expect(connection.config.host == "db.example.com")
    #expect(connection.config.port == 5433)
    #expect(connection.config.database == "sales")
    #expect(connection.config.username == "alice")
    #expect(connection.config.sslMode == .require)
    #expect(connection.config.sshTunnel == nil)
    #expect(connection.password == nil)
    #expect(connection.source == .dataGrip)
    let text = (result.warnings + connection.warnings).joined() + connection.description
    #expect(!text.contains("url-secret"))
  }

  @Test("maps a bracketed IPv6 host and defaults the port; works without the local file")
  func ipv6() throws {
    let folder = try Folder()
    try folder.write(
      Self.dataSources([Self.source(name: "", url: "jdbc:postgresql://[::1]/app")]))

    let connection = try #require(
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url).connections.first)

    #expect(connection.config.host == "::1")
    #expect(connection.config.port == 5432)
    #expect(connection.config.database == "app")
    #expect(connection.config.username == "")
    #expect(connection.config.name == "@::1/app")
  }

  @Test("skips multiple hosts, short URLs, other drivers and sources without a URL")
  func skipsUnsupported() throws {
    let folder = try Folder()
    try folder.write(
      Self.dataSources([
        Self.source(name: "Cluster", url: "jdbc:postgresql://h1:5432,h2:5433/db"),
        Self.source(name: "Short", url: "jdbc:postgresql:db"),
        Self.source(name: "Shop", driver: "mysql.8", url: "jdbc:mysql://m:3306/shop"),
        Self.source(name: "Empty", url: nil),
        Self.source(name: "Kept", driver: "postgresql", url: "jdbc:postgresql://k/db"),
      ]))

    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)

    #expect(result.connections.map(\.config.name) == ["Kept"])
    #expect(result.warnings.count == 4)
    #expect(
      result.warnings.contains { $0.contains("\"Cluster\"") && $0.contains("multiple hosts") })
    #expect(result.warnings.contains { $0.contains("\"Short\"") })
    #expect(result.warnings.contains { $0.contains("\"Shop\"") })
    #expect(result.warnings.contains { $0.contains("\"Empty\"") })
  }

  @Test("keeps a source whose driver-ref differs when the URL is PostgreSQL")
  func urlDecidesPostgres() throws {
    let folder = try Folder()
    try folder.write(
      Self.dataSources([Self.source(name: "Custom", driver: "custom", url: "jdbc:postgresql://h/d")]
      ))
    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    #expect(result.connections.map(\.config.host) == ["h"])
  }

  @Test("an enabled SSH configuration is not imported and warns")
  func sshWarning() throws {
    let folder = try Folder()
    try folder.write(
      Self.dataSources([
        Self.source(name: "Tunnel", uuid: "t", url: "jdbc:postgresql://h/d"),
        Self.source(name: "Off", uuid: "o", url: "jdbc:postgresql://h/e"),
      ]))
    try folder.write(
      Self.local([
        (
          "t",
          "<ssh-properties><enabled>true</enabled><ssh-config-id>abc</ssh-config-id></ssh-properties>"
        ),
        ("o", "<ssh-properties><enabled>false</enabled></ssh-properties>"),
      ]), to: DataGripImporter.localDataSourcesFileName)

    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)

    let tunnel = try #require(result.connections.first { $0.config.name == "Tunnel" })
    #expect(tunnel.config.sshTunnel == nil)
    #expect(tunnel.warnings == [DataGripImporter.sshWarning])
    let off = try #require(result.connections.first { $0.config.name == "Off" })
    #expect(off.warnings.isEmpty)
  }

  @Test("accepts the project folder that contains .idea")
  func projectFolder() throws {
    let folder = try Folder()
    let idea = folder.url.appendingPathComponent(".idea", isDirectory: true)
    try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
    try Data(Self.dataSources([Self.source(name: "P", url: "jdbc:postgresql://h/d")]).utf8)
      .write(to: idea.appendingPathComponent(DataGripImporter.dataSourcesFileName))

    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    #expect(result.connections.map(\.config.name) == ["P"])
  }

  // MARK: - Hostile input

  @Test("does not resolve an external entity")
  func externalEntityNotResolved() throws {
    let folder = try Folder()
    try folder.write(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE project [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
      <project version="4">
        <component name="DataSourceManagerImpl">
          <data-source name="X" uuid="x">
            <driver-ref>postgresql</driver-ref>
            <jdbc-url>jdbc:postgresql://h/&xxe;</jdbc-url>
            <user-name>u&xxe;</user-name>
          </data-source>
        </component>
      </project>
      """)

    let result = try DataGripImporter.importConnections(fromIdeaFolder: folder.url)

    let connection = try #require(result.connections.first)
    #expect(connection.config.host == "h")
    #expect(connection.config.username == "u")
    #expect(!connection.config.database.contains("root:"))
  }

  @Test("rejects a document that declares entities")
  func entityDeclarationsRejected() throws {
    let folder = try Folder()
    try folder.write(
      """
      <?xml version="1.0"?>
      <!DOCTYPE project [
        <!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">
        <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
      ]>
      <project><component><data-source name="&c;" uuid="x">
        <jdbc-url>jdbc:postgresql://h/d</jdbc-url>
      </data-source></component></project>
      """)

    #expect(throws: DataGripImporter.ImportError.malformedDataSources) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
  }

  @Test("rejects oversize files, malformed XML and a missing dataSources.xml")
  func errors() throws {
    let folder = try Folder()
    #expect(throws: DataGripImporter.ImportError.dataSourcesNotFound) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
    try folder.write("<project><component>")
    #expect(throws: DataGripImporter.ImportError.malformedDataSources) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
    try folder.write(Self.dataSources([]))
    try Data(count: DataGripImporter.maxFileSize + 1).write(
      to: folder.url.appendingPathComponent(DataGripImporter.localDataSourcesFileName))
    #expect(throws: DataGripImporter.ImportError.fileTooLarge) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
  }

  @Test("a symlinked dataSources.xml is not followed")
  func symlinkRejected() throws {
    let folder = try Folder()
    try folder.write(Self.dataSources([]), to: "elsewhere.xml")
    try FileManager.default.createSymbolicLink(
      at: folder.url.appendingPathComponent(DataGripImporter.dataSourcesFileName),
      withDestinationURL: folder.url.appendingPathComponent("elsewhere.xml"))
    #expect(throws: DataGripImporter.ImportError.dataSourcesNotFound) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
  }

  @Test("a symlinked .idea folder is not followed")
  func symlinkedFolderRejected() throws {
    let folder = try Folder()
    let target = folder.url.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data(Self.dataSources([Self.source(name: "L", url: "jdbc:postgresql://h/d")]).utf8)
      .write(to: target.appendingPathComponent(DataGripImporter.dataSourcesFileName))
    try FileManager.default.createSymbolicLink(
      at: folder.url.appendingPathComponent(".idea"), withDestinationURL: target)
    #expect(throws: DataGripImporter.ImportError.dataSourcesNotFound) {
      try DataGripImporter.importConnections(fromIdeaFolder: folder.url)
    }
  }
}
