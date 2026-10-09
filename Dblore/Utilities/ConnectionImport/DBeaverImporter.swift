//
//  DBeaverImporter.swift
//  Dblore
//
//  Imports PostgreSQL connections from a DBeaver `.dbeaver` workspace folder: `data-sources.json`
//  plus the optional encrypted `credentials-config.json`. Both files are external input: sizes are
//  bounded, decrypted content is never logged, and warnings never carry secret values.
//
//  Format (DBeaver source, dbeaver/dbeaver on GitHub):
//  - `DefaultValueEncryptor`: AES/CBC/PKCS5Padding, the 16-byte IV is written before the
//    ciphertext. `BaseProjectImpl.LOCAL_KEY_CACHE` is the static key.
//  - `DataSourceParser`: secrets map `{ id: { "#connection": {user, password},
//    "network/<handlerId>": {user, password} } }`; handlers may also store user/password inline.
//  - `SSHConstants`: `authType` is PASSWORD, PUBLIC_KEY or AGENT. `PostgreConstants.PROP_SSL_MODE`
//    is `sslMode` on the `postgre_ssl` handler.
//

import CommonCrypto
import Foundation

nonisolated enum DBeaverImporter {
  enum ImportError: Error, Equatable, Sendable {
    case dataSourcesNotFound
    case fileTooLarge
    case malformedDataSources
  }

  static let maxFileSize = 10 * 1024 * 1024
  static let dataSourcesFileName = "data-sources.json"
  static let secretsFileName = "credentials-config.json"
  static let unreadableSecretsWarning = "Saved passwords could not be read."

  /// DBeaver's published static key (`BaseProjectImpl.LOCAL_KEY_CACHE`).
  private static let key: [UInt8] = [
    0xba, 0xbb, 0x4a, 0x9f, 0x77, 0x4a, 0xb8, 0x53, 0xc9, 0x6c, 0x2d, 0x65, 0x3d, 0xfe, 0x54, 0x4a,
  ]

  /// `user`/`password` pairs keyed by connection id, then by node (`#connection`, `network/…`).
  private typealias Secrets = [String: [String: Login]]

  private struct Login {
    var user: String?
    var password: String?
  }

  static func importConnections(
    fromWorkspaceFolder url: URL
  ) throws -> (
    connections: [ImportedConnection], warnings: [String]
  ) {
    let folder = resolveFolder(url)
    guard !isSymbolicLink(folder) else { throw ImportError.dataSourcesNotFound }
    guard let data = try readBounded(folder.appendingPathComponent(dataSourcesFileName)) else {
      throw ImportError.dataSourcesNotFound
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["connections"] as? [String: Any]
    else { throw ImportError.malformedDataSources }

    var warnings: [String] = []
    let secrets: Secrets
    if let loaded = loadSecrets(in: folder) {
      secrets = loaded ?? [:]
      if loaded == nil { warnings.append(unreadableSecretsWarning) }
    } else {
      secrets = [:]
    }

    var connections: [ImportedConnection] = []
    for id in entries.keys.sorted() {
      switch mapConnection(id: id, entry: entries[id], secrets: secrets[id] ?? [:]) {
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

  /// Accepts the `.dbeaver` folder itself or the workspace project folder that contains it.
  private static func resolveFolder(_ url: URL) -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.appendingPathComponent(dataSourcesFileName).path) {
      return url
    }
    let nested = url.appendingPathComponent(".dbeaver", isDirectory: true)
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

  /// Outer nil: no secrets file. Inner nil: the file exists but could not be read.
  private static func loadSecrets(in folder: URL) -> Secrets?? {
    let url = folder.appendingPathComponent(secretsFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return .none }
    guard var encrypted = try? readBounded(url) else { return .some(nil) }
    defer { encrypted.resetBytes(in: 0..<encrypted.count) }
    guard var plaintext = decrypt(encrypted) else { return .some(nil) }
    defer { plaintext.resetBytes(in: 0..<plaintext.count) }
    guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
      return .some(nil)
    }
    var secrets: Secrets = [:]
    for (id, value) in object {
      guard let nodes = value as? [String: Any] else { continue }
      for (node, fields) in nodes {
        guard let fields = fields as? [String: Any] else { continue }
        secrets[id, default: [:]][node] = Login(
          user: fields["user"] as? String, password: fields["password"] as? String)
      }
    }
    return .some(secrets)
  }

  /// AES-128-CBC with PKCS7 padding; the first block of `data` is the IV.
  private static func decrypt(_ data: Data) -> Data? {
    let block = kCCBlockSizeAES128
    guard data.count >= 2 * block, data.count % block == 0 else { return nil }
    let iv = Data(data.prefix(block))
    let ciphertext = Data(data.dropFirst(block))
    var output = Data(count: ciphertext.count)
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      iv.withUnsafeBytes { ivBytes in
        ciphertext.withUnsafeBytes { input in
          CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding), key, key.count, ivBytes.baseAddress,
            input.baseAddress, input.count, out.baseAddress, out.count, &written)
        }
      }
    }
    guard status == kCCSuccess else {
      output.resetBytes(in: 0..<output.count)
      return nil
    }
    output.resetBytes(in: written..<output.count)
    output.count = written
    return output
  }

  // MARK: - Mapping

  private struct Skipped: Error {
    var message: String
  }

  private static func mapConnection(
    id: String, entry: Any?, secrets: [String: Login]
  ) -> Result<ImportedConnection, Skipped> {
    guard let entry = entry as? [String: Any] else {
      return .failure(Skipped(message: "Skipped an entry that is not a connection."))
    }
    let rawName = string(entry["name"]) ?? ""
    let label = "\"\(sanitized(rawName.isEmpty ? id : rawName))\""

    let provider = string(entry["provider"]) ?? ""
    let driver = string(entry["driver"]) ?? ""
    guard provider.lowercased() == "postgresql", driver.lowercased().contains("postgres") else {
      return .failure(
        Skipped(
          message:
            "Skipped \(label): unsupported driver \(sanitized(provider))/\(sanitized(driver))."))
    }

    let configuration = entry["configuration"] as? [String: Any] ?? [:]
    let host = string(configuration["host"]) ?? ""
    guard !host.isEmpty else {
      return .failure(Skipped(message: "Skipped \(label): no host (URL-only connection)."))
    }
    guard let port = port(configuration["port"], default: PostgresURIParser.defaultPort) else {
      return .failure(Skipped(message: "Skipped \(label): invalid port."))
    }
    let database = string(configuration["database"]).flatMap { $0.isEmpty ? nil : $0 } ?? "postgres"
    let login = secrets["#connection"]
    let username = nonEmpty(login?.user) ?? string(configuration["user"]) ?? ""
    let password = nonEmpty(login?.password) ?? nonEmpty(configuration["password"] as? String)

    var warnings: [String] = []
    if let authModel = string(configuration["auth-model"]), !authModel.isEmpty,
      authModel != "native"
    {
      warnings.append(
        "Authentication \"\(sanitized(authModel))\" is not supported; check the login after import."
      )
    }

    let handlers = configuration["handlers"] as? [String: Any] ?? [:]
    let sslMode = sslMode(handlers: handlers, warnings: &warnings)

    var sshTunnel: SSHTunnelConfig?
    var sshCredential: SSHStoredCredential?
    if let handler = handlers["ssh_tunnel"] as? [String: Any], bool(handler["enabled"]) ?? true {
      switch mapTunnel(handler, login: secrets["network/ssh_tunnel"], warnings: &warnings) {
      case .success(let mapped): (sshTunnel, sshCredential) = mapped
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
    return .success(
      ImportedConnection(
        config: config, password: password, sshCredential: sshCredential, source: .dbeaver,
        warnings: warnings))
  }

  private static func sslMode(handlers: [String: Any], warnings: inout [String]) -> SSLMode {
    for id in ["postgre_ssl", "ssl"] {
      guard let handler = handlers[id] as? [String: Any], bool(handler["enabled"]) ?? true else {
        continue
      }
      let properties = handler["properties"] as? [String: Any] ?? [:]
      guard let raw = string(properties["sslMode"] ?? properties["sslmode"]), !raw.isEmpty else {
        return .prefer
      }
      if let mode = SSLMode(rawValue: raw.lowercased()) { return mode }
      warnings.append("Unknown SSL mode; using \(SSLMode.prefer.rawValue).")
      return .prefer
    }
    return .prefer
  }

  private static func mapTunnel(
    _ handler: [String: Any], login: Login?, warnings: inout [String]
  ) -> Result<(SSHTunnelConfig, SSHStoredCredential?), Skipped> {
    let properties = handler["properties"] as? [String: Any] ?? [:]
    let host = string(properties["host"] ?? handler["host"]) ?? ""
    guard !host.isEmpty else { return .failure(Skipped(message: "SSH tunnel has no host.")) }
    guard let port = port(properties["port"] ?? handler["port"], default: 22) else {
      return .failure(Skipped(message: "SSH tunnel has an invalid port."))
    }
    let username =
      nonEmpty(login?.user) ?? nonEmpty(handler["user"] as? String)
      ?? string(properties["user"]) ?? ""
    if username.isEmpty { warnings.append("SSH user is missing; set it after import.") }

    let authType = (string(properties["authType"] ?? handler["authType"]) ?? "").uppercased()
    guard authType.isEmpty || authType == "PASSWORD" else {
      warnings.append("SSH key authentication: choose the SSH key again after import.")
      return .success(
        (SSHTunnelConfig(host: host, port: port, username: username, authMethod: .privateKey), nil))
    }
    let password = nonEmpty(login?.password) ?? nonEmpty(handler["password"] as? String)
    return .success(
      (
        SSHTunnelConfig(host: host, port: port, username: username, authMethod: .password),
        password.map { .password($0) }
      ))
  }

  // MARK: - Value helpers

  private static func string(_ value: Any?) -> String? {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let text = value as? String { return Bool(text.lowercased()) }
    return nil
  }

  /// DBeaver writes ports as strings; accepts numbers too. Nil when present but invalid.
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
