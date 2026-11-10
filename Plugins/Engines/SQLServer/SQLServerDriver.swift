// SQLServerDriver.swift
// The SQL Server engine of the plugin: FreeTDS db-lib through the CFreeTDS shim. Spike scope:
// open, query (every value as text), command, cancel and close.
//
// TLS (`open.tls.mode`):
// - off → encryption off; request → encryption request (TLS when the server offers it);
//   require → mandatory TLS without verification.
// - verifyCA → mandatory TLS, chain checked against the CA.
// - verifyFull → chain and host name (`tlsServerName`) checked. It first tries encryption strict
//   (TDS 8.0, SQL Server 2022 and later). Only when that login reached the server and failed, and
//   the server then presents no certificate to a direct TLS handshake (SQL Server 2019 and older
//   answer it with a reset), it reconnects once with mandatory TLS, chain and host name checked.
//   A server that presents a certificate never gets the second try, so a chain or host-name
//   failure never falls back; nor does a local failure (configuration, temporary files).
//   `open.options.tdsStrict: false` skips the strict try.
// The CA is `open.tls.caPEM`, or the system anchors (`SecTrustCopyAnchorCertificates`), written as
// PEM to a folder of this open in the process tmp dir, with the FreeTDS configuration of the open
// (see dblore_tds.c); the folder is deleted once the open ends.
//
// `opened.serverVersion` is the server's ProductVersion followed by the encryption the connection
// used, e.g. "16.0.4135.4 (encryption: strict)"; verifyFull reads strict or require. The same is
// logged (os_log, subsystem ace.thi.Dblore.SQLServer), never the password.

import CFreeTDS
import Foundation
import Security
import os

/// This bundle's engine
let engineDriver: any EngineDriver = SQLServerDriver()

private let log = Logger(subsystem: "ace.thi.Dblore.SQLServer", category: "Connection")

struct SQLServerDriver: EngineDriver {
  var engine: String { "sqlserver" }
  var queryLanguage: String { "sql" }

  var libraries: [String: String] {
    [
      "freetds": String(cString: dblore_tds_freetds_version()),
      "openssl": String(cString: dblore_tds_openssl_version()),
    ]
  }

  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection {
    guard dblore_tds_global_init() else {
      throw EngineFailure(code: .connect, message: "FreeTDS could not start.")
    }
    // Checked once, before any try: both reach C as Int32, and the timeout as milliseconds
    guard (1...65535).contains(open.port) else {
      throw EngineFailure(code: .connect, message: "The port must be between 1 and 65535.")
    }
    let timeoutSeconds =
      open.timeoutSeconds > 0 ? min(open.timeoutSeconds, ConnectionSettings.maxTimeoutSeconds) : 30
    let files = try OpenFiles()
    defer { files.remove() }
    let serverName = open.tlsServerName.isEmpty ? open.host : open.tlsServerName
    let caPath: String? =
      switch open.tls.mode {
      case .verifyCA, .verifyFull:
        try files.write(try certificateAuthorities(open), named: "ca.pem")
      case .off, .request, .require: nil
      }
    let settings = ConnectionSettings(
      host: open.host, port: open.port, timeoutSeconds: timeoutSeconds,
      caPath: caPath, serverName: serverName)

    // Set once db-lib tried the server (`dbopen` ran); a local failure before that never falls back
    var reachedServer = false
    switch open.tls.mode {
    case .off: return try connect(open, settings, .off, files: files, reachedServer: &reachedServer)
    case .request:
      return try connect(open, settings, .request, files: files, reachedServer: &reachedServer)
    case .require:
      return try connect(open, settings, .require, files: files, reachedServer: &reachedServer)
    case .verifyCA:
      return try connect(
        open, settings, .require, checkHostName: false, files: files,
        reachedServer: &reachedServer)
    case .verifyFull:
      guard open.options["tdsStrict"] != .bool(false) else {
        return try connect(
          open, settings, .require, checkHostName: true, files: files,
          reachedServer: &reachedServer)
      }
      do {
        return try connect(
          open, settings, .strict, checkHostName: true, files: files,
          reachedServer: &reachedServer)
      } catch {
        // Fall back only when the login reached the server, and the server then shows no
        // certificate to a direct TLS handshake
        guard reachedServer else { throw error }
        let presents = dblore_tds_server_presents_certificate(
          open.host, Int32(settings.port), Int32(settings.timeoutSeconds))
        guard presents == 0 else { throw error }
        log.notice(
          "\(open.host, privacy: .public): strict encryption is not served; trying mandatory TLS")
        return try connect(
          open, settings, .require, checkHostName: true, files: files,
          reachedServer: &reachedServer)
      }
    }
  }

  private func connect(
    _ open: EngineRequest.Open, _ settings: ConnectionSettings, _ encryption: Encryption,
    checkHostName: Bool = false, files: OpenFiles, reachedServer: inout Bool
  ) throws -> SQLServerConnection {
    reachedServer = false
    let confPath = try files.write(
      try settings.configuration(encryption: encryption, checkHostName: checkHostName),
      named: "connection.conf")
    guard let handle = dblore_tds_conn_create() else {
      throw EngineFailure(code: .connect, message: "Out of memory.")
    }
    let result = dblore_tds_connect(
      handle, confPath, ConnectionSettings.section, open.username, open.password, open.database)
    reachedServer = result == 0
    guard result == 1 else {
      let failure = SQLServerConnection.failure(of: handle, code: .connect)
      dblore_tds_conn_destroy(handle)
      let mode = encryption.rawValue
      let message = failure.message
      log.error(
        "\(open.host, privacy: .public): \(mode, privacy: .public) failed: \(message, privacy: .public)"
      )
      throw failure
    }
    let connection = SQLServerConnection(handle: handle, encryption: encryption)
    log.notice(
      "\(open.host, privacy: .public): connected, \(connection.serverVersion, privacy: .public)")
    return connection
  }

  /// The CA PEM to trust: the connection's, or the system anchors
  private func certificateAuthorities(_ open: EngineRequest.Open) throws -> String {
    if let caPEM = open.tls.caPEM, !caPEM.isEmpty { return caPEM }
    guard let systemAnchorsPEM else {
      throw EngineFailure(
        code: .connect, message: "The system certificate authorities could not be read.")
    }
    return systemAnchorsPEM
  }
}

/// The system anchors as PEM, read once per process
private let systemAnchorsPEM: String? = {
  var anchors: CFArray?
  guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess,
    let certificates = anchors as? [SecCertificate], !certificates.isEmpty
  else { return nil }
  return certificates.map { certificate in
    let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(
      options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
  }.joined()
}()

// MARK: - Configuration

/// FreeTDS `encryption` values
enum Encryption: String {
  case off, request, require, strict
}

/// The FreeTDS configuration of one open. Its values go into a line-based file, so a value that
/// could end a line or start a comment or section is refused instead of written. FreeTDS reads
/// each line into a 256-byte buffer and splits a longer one, so a longer line is refused too.
struct ConnectionSettings {
  static let section = "dblore"
  /// FreeTDS sends `SET TEXTSIZE` at login: the protocol's largest value (256 MiB)
  static let textSize = EnginePluginProtocol.maxValueBytes
  /// The app's connect timeout range ends here (1...3600 s)
  static let maxTimeoutSeconds = 3_600
  /// Bytes of one line without its newline that FreeTDS reads whole (`char line[256]`, fgets)
  static let maxLineBytes = 254

  let host: String
  /// 1...65535, checked by the driver before building the settings
  let port: Int
  /// 1...3600, clamped by the driver before building the settings
  let timeoutSeconds: Int
  let caPath: String?
  let serverName: String

  func configuration(encryption: Encryption, checkHostName: Bool) throws -> String {
    var lines = [
      "[\(Self.section)]",
      "host = \(try Self.value(host, "host"))",
      "port = \(port)",
      "encryption = \(encryption.rawValue)",
      "connect timeout = \(timeoutSeconds)",
      "client charset = UTF-8",
      "text size = \(Self.textSize)",
    ]
    // Strict picks TDS 8.0 itself
    if encryption != .strict { lines.append("tds version = 7.4") }
    if let caPath {
      // A home folder name may hold spaces
      lines.append(
        "ca file = \(try Self.value(caPath, "temporary folder", allowsInnerSpaces: true))")
      lines.append("check certificate hostname = \(checkHostName ? "yes" : "no")")
      if checkHostName {
        lines.append("certificate hostname = \(try Self.value(serverName, "TLS server name"))")
      }
    }
    guard lines.allSatisfy({ $0.utf8.count <= Self.maxLineBytes }) else {
      throw EngineFailure(
        code: .connect,
        message: "The host, TLS server name or temporary folder path is too long.")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `allowsInnerSpaces`: single U+0020 between other characters pass. FreeTDS trims a value's
  /// ends and turns every run of whitespace inside it into one space, so only that form survives.
  private static func value(
    _ text: String, _ name: String, allowsInnerSpaces: Bool = false
  )
    throws -> String
  {
    var refused = CharacterSet(charactersIn: ";#[]=").union(.controlCharacters).union(
      .whitespacesAndNewlines)
    if allowsInnerSpaces { refused.remove(" ") }
    guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !refused.contains($0) }),
      !text.hasPrefix(" "), !text.hasSuffix(" "), !text.contains("  ")
    else {
      throw EngineFailure(
        code: .connect, message: "The \(name) holds characters that are not allowed.")
    }
    return text
  }
}

/// A folder of one open in the process tmp dir (the sandbox container's), removed afterwards
struct OpenFiles {
  let folder: URL

  init() throws {
    folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("dblore-sqlserver-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw EngineFailure(code: .connect, message: "The temporary folder could not be created.")
    }
  }

  /// Writes `text` (mode 0600) and returns its path
  func write(_ text: String, named name: String) throws -> String {
    let path = folder.appendingPathComponent(name).path
    try? FileManager.default.removeItem(atPath: path)
    guard
      FileManager.default.createFile(
        atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    else { throw EngineFailure(code: .connect, message: "A temporary file could not be written.") }
    return path
  }

  func remove() {
    try? FileManager.default.removeItem(at: folder)
  }
}

// MARK: - Connection

/// One db-lib connection. Used on its connection queue only, except `interrupt`.
final class SQLServerConnection: EngineConnection, @unchecked Sendable {
  private let handle: OpaquePointer
  private var columnCount = 0
  private var closed = false
  private(set) var serverVersion = ""

  init(handle: OpaquePointer, encryption: Encryption) {
    self.handle = handle
    let version = productVersion() ?? "unknown"
    serverVersion = "\(version) (encryption: \(encryption.rawValue))"
  }

  deinit { close() }

  func interrupt() { dblore_tds_request_cancel(handle) }

  func resetInterrupt() { dblore_tds_reset_cancel(handle) }

  func execute(_ sql: String) throws {
    // db-lib reads the statement as a C string: a NUL would cut it short and the rest would run
    guard !sql.utf8.contains(0) else {
      throw EngineFailure(code: .query, message: "The statement contains a NUL character.")
    }
    guard dblore_tds_execute(handle, sql) else { throw Self.failure(of: handle, code: .query) }
  }

  func nextResult() throws -> [EngineEvent.Column]? {
    switch dblore_tds_next_result(handle) {
    case 1:
      columnCount = Int(dblore_tds_column_count(handle))
      return (0..<columnCount).map { index in
        let column = Int32(index + 1)
        return EngineEvent.Column(
          name: String(cString: dblore_tds_column_name(handle, column)),
          type: String(cString: dblore_tds_column_type_name(handle, column)))
      }
    case 0: return nil
    default: throw Self.failure(of: handle, code: .query)
    }
  }

  func nextRow() throws -> [EngineCell]? {
    switch dblore_tds_next_row(handle) {
    case 1: return (0..<columnCount).map { cell(at: Int32($0 + 1)) }
    case 0: return nil
    default: throw Self.failure(of: handle, code: .query)
    }
  }

  /// The cell as text; NULL, and a value db-lib cannot turn into text, are null
  private func cell(at column: Int32) -> EngineCell {
    var text: UnsafePointer<CChar>?
    let length = dblore_tds_cell_text(handle, column, &text)
    guard length >= 0, let text else { return .null }
    return .text(
      String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self))
  }

  var affectedRows: Int? {
    let count = dblore_tds_rows_affected(handle)
    return count >= 0 ? count : nil
  }

  func discardResults() { dblore_tds_discard_results(handle) }

  var isLost: Bool { dblore_tds_is_dead(handle) }

  func close() {
    guard !closed else { return }
    closed = true
    dblore_tds_conn_destroy(handle)
  }

  /// `SERVERPROPERTY('ProductVersion')`, e.g. "16.0.4135.4"
  private func productVersion() -> String? {
    defer { discardResults() }
    guard (try? execute("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))")) != nil,
      (try? nextResult()) != nil, let row = try? nextRow(), case .text(let version)? = row.first
    else { return nil }
    return version
  }

  static func failure(of handle: OpaquePointer, code: EngineErrorCode) -> EngineFailure {
    let message = String(cString: dblore_tds_error_message(handle))
    let number = dblore_tds_error_number(handle)
    return EngineFailure(
      code: code, message: message.isEmpty ? "The server refused the request." : message,
      serverCode: number != 0 ? String(number) : nil)
  }
}
