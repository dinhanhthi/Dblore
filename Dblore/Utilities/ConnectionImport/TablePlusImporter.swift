//
//  TablePlusImporter.swift
//  Dblore
//
//  Imports PostgreSQL connections from TablePlus's `Connections.plist`
//  (`~/Library/Application Support/com.tinyapp.TablePlus/Data/`), a plist array of dictionaries.
//  Passwords stay in TablePlus's Keychain and are never imported. The file is external input:
//  its size is bounded and warnings never carry secret values.
//
//  Key names (cross-checked in the open-source TablePlus importers of TablePro, Gridex, Tabularis
//  and the Raycast TablePlus extension): `ConnectionName`, `Driver` ("PostgreSQL"), `DatabaseHost`,
//  `DatabasePort` (string), `DatabaseName`, `DatabaseUser`, `isUseSocket`, `tLSMode` (integer),
//  `isOverSSH`, `ServerAddress`, `ServerPort` (string), `ServerUser`, `isUsePrivateKey`.
//  The `.tableplusconnection` export is RNCryptor-encrypted with a user passphrase: not supported.
//

import Foundation

nonisolated enum TablePlusImporter {
  enum ImportError: Error, Equatable, Sendable {
    case fileNotFound
    case fileTooLarge
    case malformedConnections
    case encryptedExportNotSupported
  }

  static let maxFileSize = 10 * 1024 * 1024
  static let passwordWarning = "Password not imported: TablePlus keeps it in its Keychain."

  static func importConnections(
    fromFile url: URL
  ) throws -> (
    connections: [ImportedConnection], warnings: [String]
  ) {
    if url.pathExtension.lowercased() == "tableplusconnection" {
      throw ImportError.encryptedExportNotSupported
    }
    guard let data = try readBounded(url) else { throw ImportError.fileNotFound }
    guard
      let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    else { throw ImportError.malformedConnections }

    var connections: [ImportedConnection] = []
    var warnings: [String] = []
    for entry in entries {
      switch mapConnection(entry) {
      case .success(let connection): connections.append(connection)
      case .failure(let skipped): warnings.append(skipped.message)
      }
    }
    connections.sort {
      $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending
    }
    return (connections, warnings)
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

  // MARK: - Mapping

  private struct Skipped: Error {
    var message: String
  }

  private static func mapConnection(_ entry: Any) -> Result<ImportedConnection, Skipped> {
    guard let entry = entry as? [String: Any] else {
      return .failure(Skipped(message: "Skipped an entry that is not a connection."))
    }
    let rawName = string(entry["ConnectionName"]) ?? ""
    let label = "\"\(sanitized(rawName.isEmpty ? "unnamed" : rawName))\""

    let driver = string(entry["Driver"]) ?? ""
    guard driver.lowercased() == "postgresql" else {
      return .failure(
        Skipped(message: "Skipped \(label): unsupported driver \(sanitized(driver))."))
    }
    if bool(entry["isUseSocket"]) == true {
      return .failure(Skipped(message: "Skipped \(label): socket connections are not supported."))
    }
    let host = string(entry["DatabaseHost"]) ?? ""
    guard !host.isEmpty else { return .failure(Skipped(message: "Skipped \(label): no host.")) }
    guard let port = port(entry["DatabasePort"], default: PostgresURIParser.defaultPort) else {
      return .failure(Skipped(message: "Skipped \(label): invalid port."))
    }
    let database = string(entry["DatabaseName"]).flatMap { $0.isEmpty ? nil : $0 } ?? "postgres"
    let username = string(entry["DatabaseUser"]) ?? ""

    var warnings = [passwordWarning]
    let sslMode = sslMode(entry["tLSMode"], warnings: &warnings)

    var sshTunnel: SSHTunnelConfig?
    if bool(entry["isOverSSH"]) == true {
      switch mapTunnel(entry, warnings: &warnings) {
      case .success(let tunnel): sshTunnel = tunnel
      case .failure(let reason):
        return .failure(Skipped(message: "Skipped \(label): \(reason.message)"))
      }
    }

    let name =
      rawName.isEmpty
      ? ImportedConnection.defaultName(username: username, host: host, database: database)
      : rawName
    let config = ConnectionConfig(
      databaseType: .postgresql, host: host, port: port, database: database, username: username,
      sslMode: sslMode, sshTunnel: sshTunnel, name: name)
    return .success(ImportedConnection(config: config, source: .tablePlus, warnings: warnings))
  }

  /// TablePlus stores the TLS picker index. Importers disagree on the PostgreSQL index table,
  /// so only 0 (the default, "preferred") is mapped; a mode name string is accepted too.
  private static func sslMode(_ value: Any?, warnings: inout [String]) -> SSLMode {
    switch value {
    case nil: return .prefer
    case let text as String:
      if let mode = SSLMode(rawValue: text.lowercased()) { return mode }
    case let number as NSNumber:
      if number.intValue == 0 { return .prefer }
    default: break
    }
    warnings.append(
      "TLS mode not imported; using \(SSLMode.prefer.rawValue). Check it after import.")
    return .prefer
  }

  private static func mapTunnel(
    _ entry: [String: Any], warnings: inout [String]
  ) -> Result<SSHTunnelConfig, Skipped> {
    let host = string(entry["ServerAddress"]) ?? ""
    guard !host.isEmpty else { return .failure(Skipped(message: "SSH tunnel has no host.")) }
    guard let port = port(entry["ServerPort"], default: 22) else {
      return .failure(Skipped(message: "SSH tunnel has an invalid port."))
    }
    let username = string(entry["ServerUser"]) ?? ""
    if username.isEmpty { warnings.append("SSH user is missing; set it after import.") }
    if bool(entry["isUsePrivateKey"]) == true {
      warnings.append("SSH key authentication: choose the SSH key again after import.")
      return .success(
        SSHTunnelConfig(host: host, port: port, username: username, authMethod: .privateKey))
    }
    warnings.append("SSH password not imported.")
    return .success(
      SSHTunnelConfig(host: host, port: port, username: username, authMethod: .password))
  }

  // MARK: - Value helpers

  private static func string(_ value: Any?) -> String? {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Plist booleans and 0/1 integers both bridge to NSNumber.
  private static func bool(_ value: Any?) -> Bool? {
    if let number = value as? NSNumber { return number.intValue != 0 }
    if let text = value as? String { return Bool(text.lowercased()) }
    return nil
  }

  /// TablePlus writes ports as strings; accepts numbers too. Nil when present but invalid.
  private static func port(_ value: Any?, default defaultPort: Int) -> Int? {
    let port: Int?
    switch value {
    case nil: return defaultPort
    case let number as NSNumber: port = number.intValue
    case let text as String:
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { return defaultPort }
      port = trimmed.allSatisfy { $0.isASCII && $0.isNumber } ? Int(trimmed) : nil
    default: port = nil
    }
    guard let port, (1...65535).contains(port) else { return nil }
    return port
  }

  /// External labels in warnings: one line, bounded length.
  private static func sanitized(_ text: String) -> String {
    let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    return line.count > 60 ? String(line.prefix(60)) + "…" : line
  }
}
