//
//  DataGripImporter.swift
//  Dblore
//
//  Imports PostgreSQL connections from a DataGrip (JetBrains) project `.idea` folder:
//  `dataSources.xml` (name, driver, JDBC URL) and the optional `dataSources.local.xml`
//  (user name, SSH settings), joined by data source `uuid`. Passwords live in the JetBrains
//  secret storage and are never imported. Both files are external input: sizes are bounded,
//  internal entity declarations are rejected, external entities are never resolved, and
//  warnings never carry secret values.
//
//  Layout (`<project><component><data-source name uuid>` with `<driver-ref>`, `<jdbc-url>`,
//  `<user-name>`, `<ssh-properties><enabled>`), cross-checked in public DataGrip project files
//  and the open-source DataGrip importers of Tabularis and TablePro.
//

import Foundation

nonisolated enum DataGripImporter {
  enum ImportError: Error, Equatable, Sendable {
    case dataSourcesNotFound
    case fileTooLarge
    case malformedDataSources
  }

  static let maxFileSize = 10 * 1024 * 1024
  static let dataSourcesFileName = "dataSources.xml"
  static let localDataSourcesFileName = "dataSources.local.xml"
  static let sshWarning = "SSH settings not imported; set up the SSH tunnel after import."

  private static let jdbcPrefix = "jdbc:postgresql:"

  static func importConnections(
    fromIdeaFolder url: URL
  ) throws -> (
    connections: [ImportedConnection], warnings: [String]
  ) {
    let folder = resolveFolder(url)
    guard !isSymbolicLink(folder) else { throw ImportError.dataSourcesNotFound }
    guard let shared = try readBounded(folder.appendingPathComponent(dataSourcesFileName)) else {
      throw ImportError.dataSourcesNotFound
    }
    let sources = try parse(shared)
    let local = try readBounded(folder.appendingPathComponent(localDataSourcesFileName))
    var localByUUID: [String: DataSource] = [:]
    for source in try local.map(parse) ?? [] where !source.uuid.isEmpty {
      localByUUID[source.uuid] = source
    }

    var connections: [ImportedConnection] = []
    var warnings: [String] = []
    for source in sources {
      let merged = source.merged(with: localByUUID[source.uuid])
      switch mapConnection(merged) {
      case .success(let connection): connections.append(connection)
      case .failure(let skipped): warnings.append(skipped.message)
      }
    }
    connections.sort {
      $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending
    }
    return (connections, warnings)
  }

  // MARK: - Files

  /// Accepts the `.idea` folder itself or the project folder that contains it.
  private static func resolveFolder(_ url: URL) -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.appendingPathComponent(dataSourcesFileName).path) {
      return url
    }
    let nested = url.appendingPathComponent(".idea", isDirectory: true)
    if fileManager.fileExists(atPath: nested.appendingPathComponent(dataSourcesFileName).path) {
      return nested
    }
    return url
  }

  /// The folder itself, not a parent. A linked folder could point anywhere.
  private static func isSymbolicLink(_ url: URL) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
  }

  /// Reads at most `maxFileSize` bytes. Nil when the file does not exist, is a symlink, or is
  /// not a regular file.
  private static func readBounded(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxFileSize + 1) ?? Data()
    guard data.count <= maxFileSize else { throw ImportError.fileTooLarge }
    return data
  }

  // MARK: - XML

  private struct DataSource {
    var name = ""
    var uuid = ""
    var driverRef: String?
    var jdbcURL: String?
    var userName: String?
    var sshEnabled: Bool?

    /// Local values fill what the shared file leaves out.
    func merged(with local: DataSource?) -> DataSource {
      guard let local else { return self }
      var result = self
      result.driverRef = driverRef ?? local.driverRef
      result.jdbcURL = jdbcURL ?? local.jdbcURL
      result.userName = local.userName ?? userName
      result.sshEnabled = local.sshEnabled ?? sshEnabled
      return result
    }
  }

  private static func parse(_ data: Data) throws -> [DataSource] {
    let delegate = DataSourcesParser()
    let parser = XMLParser(data: data)
    // XXE: external entities are never fetched (their references read as empty); internal
    // entity declarations abort the parse below, so no expansion bomb is evaluated.
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.delegate = delegate
    guard parser.parse(), !delegate.rejected else { throw ImportError.malformedDataSources }
    return delegate.sources
  }

  /// Collects `<data-source>` elements. Child elements are read only directly under
  /// `<data-source>` (and `<enabled>` under its `<ssh-properties>`).
  private nonisolated final class DataSourcesParser: NSObject, XMLParserDelegate {
    var sources: [DataSource] = []
    var rejected = false
    private var current: DataSource?
    private var path: [String] = []
    private var text = ""

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      if elementName == "data-source", current == nil {
        current = DataSource(name: attributes["name"] ?? "", uuid: attributes["uuid"] ?? "")
        path = []
      } else if current != nil {
        path.append(elementName)
        if path == ["ssh-properties"], let enabled = attributes["enabled"] {
          current?.sshEnabled = Bool(enabled.lowercased())
        }
      }
      text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard current != nil, text.utf8.count < 64 * 1024 else { return }
      text += string
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      guard current != nil else { return }
      if path.isEmpty {
        if elementName == "data-source", let source = current { sources.append(source) }
        current = nil
        return
      }
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      switch path {
      case ["driver-ref"]: current?.driverRef = value
      case ["jdbc-url"]: current?.jdbcURL = value
      case ["user-name"]: current?.userName = value
      case ["ssh-properties", "enabled"]: current?.sshEnabled = Bool(value.lowercased())
      default: break
      }
      path.removeLast()
      text = ""
    }

    func parser(
      _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
    ) {
      reject(parser)
    }

    func parser(
      _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
      systemID: String?
    ) {
      reject(parser)
    }

    func parser(
      _ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?
    ) -> Data? {
      reject(parser)
      return nil
    }

    private func reject(_ parser: XMLParser) {
      rejected = true
      parser.abortParsing()
    }
  }

  // MARK: - Mapping

  private struct Skipped: Error {
    var message: String
  }

  private static func mapConnection(_ source: DataSource) -> Result<ImportedConnection, Skipped> {
    let label = "\"\(sanitized(source.name.isEmpty ? "unnamed" : source.name))\""
    let url = source.jdbcURL ?? ""
    let isPostgresURL = url.lowercased().hasPrefix(jdbcPrefix)
    guard isPostgresURL || source.driverRef?.lowercased() == "postgresql" else {
      return .failure(
        Skipped(
          message: "Skipped \(label): unsupported driver \(sanitized(source.driverRef ?? ""))."))
    }
    guard isPostgresURL else {
      return .failure(Skipped(message: "Skipped \(label): no PostgreSQL JDBC URL."))
    }
    let rest = url.dropFirst(jdbcPrefix.count)
    guard rest.hasPrefix("//") else {
      return .failure(Skipped(message: "Skipped \(label): the JDBC URL has no host."))
    }

    var connection: ImportedConnection
    do {
      connection = try PostgresURIParser.parse("postgresql:" + rest)
    } catch PostgresURIParser.ParseError.multipleHostsNotSupported {
      return .failure(Skipped(message: "Skipped \(label): multiple hosts are not supported."))
    } catch {
      return .failure(Skipped(message: "Skipped \(label): invalid JDBC URL."))
    }

    // A URL may carry `user`/`password` parameters; the password is never imported.
    connection.password = nil
    connection.source = .dataGrip
    if let userName = source.userName, !userName.isEmpty {
      connection.config.username = userName
    }
    let config = connection.config
    connection.config.name =
      source.name.isEmpty
      ? ImportedConnection.defaultName(
        username: config.username, host: config.host, database: config.database)
      : source.name
    if source.sshEnabled == true { connection.warnings.append(sshWarning) }
    return .success(connection)
  }

  /// External labels in warnings: one line, bounded length.
  private static func sanitized(_ text: String) -> String {
    let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    return line.count > 60 ? String(line.prefix(60)) + "…" : line
  }
}
