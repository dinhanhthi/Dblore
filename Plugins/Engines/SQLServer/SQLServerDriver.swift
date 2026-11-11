// SQLServerDriver.swift
// The SQL Server engine of the plugin: FreeTDS db-lib through the CFreeTDS shim. Open, query
// and command (with binds), typed cells (SQLServerTypes.swift), catalog reads
// (SQLServerCatalog.swift), settings, transaction state, cancel and close.
//
// TLS (`open.tls.mode`), planned by `SQLServerTLSPlan` (SQLServerTypes.swift):
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
// Mandatory TLS and strict also refuse a session the server left unencrypted (dblore_tds.c).
// The CA is `open.tls.caPEM`, or the system anchors (`SecTrustCopyAnchorCertificates`), written as
// PEM to a folder of this open in the process tmp dir, with the FreeTDS configuration of the open
// (see dblore_tds.c); the folder is deleted once the open ends.
//
// Binds: the app writes `@p1`, `@p2`, ...; the batch declares them as nvarchar(max) variables
// ahead of the statement (`SQLServerTypes.batch`). Not `sp_executesql`: db-lib reports no row
// count for a statement inside a procedure (a DONEINPROC token), and its RPC parameters can be
// neither an empty string (length 0 is NULL) nor over 4000 characters. SQL Server reports the
// declaring prelude as the batch's first result, counting one row (a variable assignment counts
// as a row); that count is not added (`SQLServerTypes.countsRows`).
//
// Results: a batch may return several results. The rows of its last tabular result are returned
// and the row counts of its other statements summed (`done.affectedRows`), the bind prelude's
// left out. To find the last one, the rows of a tabular result are read ahead up to
// `readAheadBytes`; a bigger result is streamed at once, and tabular results after it are dropped.
//
// Settings: `SET LOCK_TIMEOUT` and the client statement timeout (the statement is stopped like a
// cancel); the idle timeout has no SQL Server counterpart and is ignored.
//
// `opened.serverVersion` is the server's ProductVersion followed by the encryption the connection
// used, e.g. "16.0.4135.4 (encryption: strict)"; verifyFull reads strict or require. The same is
// logged (os_log, subsystem ace.thi.Dblore.SQLServer), never the password; server and FreeTDS
// texts are logged private.

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
    let plan = SQLServerTLSPlan(
      mode: open.tls.mode, tdsStrict: open.options["tdsStrict"] != .bool(false))
    let files = try OpenFiles()
    defer { files.remove() }
    let serverName = open.tlsServerName.isEmpty ? open.host : open.tlsServerName
    let caPath: String? =
      plan.attempts.contains(where: \.verifiesChain)
      ? try files.write(try certificateAuthorities(open), named: "ca.pem") : nil
    let settings = ConnectionSettings(
      host: open.host, port: open.port, timeoutSeconds: timeoutSeconds,
      caPath: caPath, serverName: serverName)

    var attempt = plan.first
    while true {
      let failed: AttemptFailure
      switch connect(open, settings, attempt, files: files) {
      case .success(let connection): return connection
      case .failure(let failure): failed = failure
      }
      let failure = classify(failed, of: attempt, plan: plan, settings: settings)
      guard let next = plan.next(after: attempt, failure: failure) else { throw failed.failure }
      log.notice(
        "\(open.host, privacy: .public): strict encryption is not served; trying mandatory TLS")
      attempt = next
    }
  }

  /// A failed attempt: its failure and `dblore_tds_connect`'s result (-1 before the server was
  /// tried)
  private struct AttemptFailure: Error {
    let failure: EngineFailure
    let result: Int32
  }

  private func connect(
    _ open: EngineRequest.Open, _ settings: ConnectionSettings, _ attempt: SQLServerTLSPlan.Attempt,
    files: OpenFiles
  ) -> Result<SQLServerConnection, AttemptFailure> {
    let confPath: String
    do {
      confPath = try files.write(try settings.configuration(attempt), named: "connection.conf")
    } catch {
      return .failure(AttemptFailure(failure: .from(error, code: .connect), result: -1))
    }
    guard let handle = dblore_tds_conn_create() else {
      return .failure(
        AttemptFailure(
          failure: EngineFailure(code: .connect, message: "Out of memory."), result: -1))
    }
    let result = dblore_tds_connect(
      handle, confPath, ConnectionSettings.section, open.username, open.password, open.database,
      attempt.requiresEncryption)
    guard result == 1 else {
      let failure = SQLServerConnection.failure(of: handle, code: .connect)
      dblore_tds_conn_destroy(handle)
      let mode = attempt.encryption.rawValue
      let message = failure.message
      log.error(
        "\(open.host, privacy: .public): \(mode, privacy: .public) failed: \(message, privacy: .private)"
      )
      return .failure(AttemptFailure(failure: failure, result: result))
    }
    let connection = SQLServerConnection(handle: handle, encryption: attempt.encryption)
    log.notice(
      "\(open.host, privacy: .public): connected, \(connection.serverVersion, privacy: .public)")
    return .success(connection)
  }

  /// How the attempt failed. Only an attempt that may fall back asks the server, with a direct TLS
  /// handshake, whether it presents a certificate at all.
  private func classify(
    _ failed: AttemptFailure, of attempt: SQLServerTLSPlan.Attempt, plan: SQLServerTLSPlan,
    settings: ConnectionSettings
  ) -> SQLServerTLSPlan.Failure {
    switch failed.result {
    case -1: return .local
    case -2: return .unencrypted
    default:
      guard plan.mayFallBack(from: attempt) else { return .refused }
      switch dblore_tds_server_presents_certificate(
        settings.host, Int32(settings.port), Int32(settings.timeoutSeconds))
      {
      case 0: return .beforeCertificate
      case 1: return .afterCertificate
      default: return .unreachable
      }
    }
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

  func configuration(_ attempt: SQLServerTLSPlan.Attempt) throws -> String {
    let encryption = attempt.encryption
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
    if attempt.verifiesChain, let caPath {
      // A home folder name may hold spaces
      lines.append(
        "ca file = \(try Self.value(caPath, "temporary folder", allowsInnerSpaces: true))")
      lines.append("check certificate hostname = \(attempt.checksHostName ? "yes" : "no")")
      if attempt.checksHostName {
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
    // Per Unicode scalar, as FreeTDS reads the bytes: a space joined to a combining scalar is
    // still a space
    let scalars = Array(text.unicodeScalars)
    let doubleSpace = zip(scalars, scalars.dropFirst()).contains { $0 == " " && $1 == " " }
    guard !scalars.isEmpty, scalars.allSatisfy({ !refused.contains($0) }),
      scalars.first != " ", scalars.last != " ", !doubleSpace
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
  /// Bytes (as `RowStreamer.cost` counts them) of a tabular result held to see whether another
  /// one follows it; a bigger result is streamed as it comes
  static let readAheadBytes = 8 << 20

  private let handle: OpaquePointer
  /// Guards `closed` against `interrupt` from another thread, so it never reaches a freed handle
  private let handleLock = NSLock()
  private var closed = false
  private(set) var serverVersion = ""

  /// Where the running batch stands
  private enum Phase {
    /// No batch, or its results were dropped
    case idle
    /// Sent, no result chosen yet
    case started
    /// The chosen result's columns went out; its rows are served
    case streaming
    /// Nothing more to serve
    case finished
  }

  private var phase = Phase.idle
  private var columns: [SQLServerColumn] = []
  /// Rows of the chosen result read ahead, served before the rest
  private var buffered: [[EngineCell]] = []
  private var bufferedIndex = 0
  /// The chosen result still has rows in db-lib
  private var rowsPending = false
  /// db-lib has no more results for the batch
  private var batchDone = false
  /// Summed row counts of the batch's results without columns, but the bind prelude's
  private var affected: Int?
  /// The batch has a bind prelude (`SQLServerTypes.countsRows`)
  private var hasBinds = false
  /// Results db-lib has begun for the batch
  private var resultCount = 0

  init(handle: OpaquePointer, encryption: SQLServerEncryption) {
    self.handle = handle
    let version = productVersion() ?? "unknown"
    serverVersion = "\(version) (encryption: \(encryption.rawValue))"
  }

  deinit { close() }

  func interrupt() {
    handleLock.withLock {
      guard !closed else { return }
      dblore_tds_request_cancel(handle)
    }
  }

  func resetInterrupt() { dblore_tds_reset_cancel(handle) }

  func execute(_ sql: String) throws {
    try execute(sql, binds: [])
  }

  /// `sql` with bind N (1-based) as `@pN`
  func execute(_ sql: String, binds: [String?]) throws {
    let batch = SQLServerTypes.batch(sql, binds: binds)
    // db-lib reads the batch as a C string: a NUL would cut it short and the rest would run
    guard !batch.utf8.contains(0) else {
      throw EngineFailure(
        code: .query, message: "The statement or a parameter contains a NUL character.")
    }
    resetResults()
    guard dblore_tds_execute(handle, batch) else { throw failure(code: .query) }
    hasBinds = !binds.isEmpty
    phase = .started
  }

  func nextResult() throws -> [EngineEvent.Column]? {
    switch phase {
    case .idle, .finished: return nil
    case .started: return try chooseResult().map(\.event)
    case .streaming:
      // The rest of the batch adds row counts only; an empty result lets the caller read them
      let before = affected
      try drainRest()
      phase = .finished
      return affected != before ? [] : nil
    }
  }

  /// Reads the batch up to its last tabular result and returns its columns: an empty list when
  /// the batch has none. A tabular result over `readAheadBytes` is chosen as it is.
  private func chooseResult() throws -> [SQLServerColumn] {
    var chosen: (columns: [SQLServerColumn], rows: [[EngineCell]])?
    while let count = try nextBatchResult() {
      guard count > 0 else {
        try countRows()
        continue
      }
      let resultColumns = try describe(count)
      var rows: [[EngineCell]] = []
      var bytes = 0
      while let row = try readRow(resultColumns) {
        rows.append(row)
        bytes += row.reduce(0) { $0 + RowStreamer.cost($1) }
        if bytes > Self.readAheadBytes {
          serve(resultColumns, rows: rows, rowsPending: true)
          return resultColumns
        }
      }
      chosen = (resultColumns, rows)
    }
    guard let chosen else {
      phase = .finished
      return []
    }
    serve(chosen.columns, rows: chosen.rows, rowsPending: false)
    return chosen.columns
  }

  private func serve(_ resultColumns: [SQLServerColumn], rows: [[EngineCell]], rowsPending: Bool) {
    columns = resultColumns
    buffered = rows
    bufferedIndex = 0
    self.rowsPending = rowsPending
    phase = .streaming
  }

  func nextRow() throws -> [EngineCell]? {
    guard phase == .streaming else { return nil }
    if bufferedIndex < buffered.count {
      defer { bufferedIndex += 1 }
      return buffered[bufferedIndex]
    }
    buffered = []
    bufferedIndex = 0
    guard rowsPending else { return nil }
    if let row = try readRow(columns) { return row }
    rowsPending = false
    return nil
  }

  var affectedRows: Int? { affected }

  func discardResults() {
    resetResults()
    dblore_tds_discard_results(handle)
  }

  var isLost: Bool { dblore_tds_is_dead(handle) }

  func close() {
    let first = handleLock.withLock {
      defer { closed = true }
      return !closed
    }
    guard first else { return }
    dblore_tds_conn_destroy(handle)
  }

  // MARK: Requests

  /// The `settings` request: `SET LOCK_TIMEOUT` (0 waits for ever) and the client statement
  /// timeout (0: none). The idle timeout is ignored.
  func apply(_ settings: EngineRequest.Settings) throws {
    let lockMilliseconds =
      settings.lockTimeoutSeconds > 0 ? min(settings.lockTimeoutSeconds, 2_000_000) * 1000 : -1
    _ = try rows("SET LOCK_TIMEOUT \(lockMilliseconds)")
    dblore_tds_set_statement_timeout(
      handle, Int32(clamping: max(0, settings.statementTimeoutSeconds)))
  }

  /// `@@TRANCOUNT > 0`
  func transactionOpen() throws -> Bool? {
    guard case .int(let count)? = try rows("SELECT @@TRANCOUNT").first?.first else { return nil }
    return count > 0
  }

  func catalog(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult {
    try SQLServerCatalog(connection: self).read(request)
  }

  /// Every row of the batch's last tabular result, bind N as `@pN` (catalog reads)
  func rows(_ sql: String, binds: [String?] = []) throws -> [[EngineCell]] {
    defer { discardResults() }
    try execute(sql, binds: binds)
    guard let columns = try nextResult(), !columns.isEmpty else { return [] }
    var rows: [[EngineCell]] = []
    while let row = try nextRow() { rows.append(row) }
    return rows
  }

  // MARK: db-lib

  private func resetResults() {
    phase = .idle
    columns = []
    buffered = []
    bufferedIndex = 0
    rowsPending = false
    batchDone = false
    affected = nil
    hasBinds = false
    resultCount = 0
  }

  /// The next result's column count, nil when the batch has no more
  private func nextBatchResult() throws -> Int? {
    guard !batchDone else { return nil }
    switch dblore_tds_next_result(handle) {
    case 1:
      resultCount += 1
      return Int(dblore_tds_column_count(handle))
    case 0:
      batchDone = true
      return nil
    default: throw failure(code: .query)
    }
  }

  /// Ends a result without columns and adds its row count, unless it is the bind prelude's
  private func countRows() throws {
    while try readRow([]) != nil {}
    guard SQLServerTypes.countsRows(result: resultCount - 1, hasBinds: hasBinds) else { return }
    let count = dblore_tds_rows_affected(handle)
    if count >= 0 { affected = (affected ?? 0) + count }
  }

  /// Drops the rest of the chosen result and the tabular results after it; counts the others
  private func drainRest() throws {
    if rowsPending {
      while try readRow(columns) != nil {}
      rowsPending = false
    }
    buffered = []
    while let count = try nextBatchResult() {
      if count > 0 {
        while try readRow([]) != nil {}
      } else {
        try countRows()
      }
    }
  }

  private func describe(_ count: Int) throws -> [SQLServerColumn] {
    try (1...count).map { index in
      var info = dblore_tds_column()
      guard dblore_tds_column_get(handle, Int32(index), &info) else {
        throw EngineFailure(code: .query, message: "The server described no column \(index).")
      }
      return SQLServerColumn(
        name: info.name.map { String(cString: $0) } ?? "", type: TDSType(rawValue: info.type),
        serverType: TDSType(rawValue: info.server_type), userType: info.user_type,
        maxLength: Int(info.max_length))
    }
  }

  /// The next row of the current result as cells of `resultColumns`, nil at its end
  private func readRow(_ resultColumns: [SQLServerColumn]) throws -> [EngineCell]? {
    switch dblore_tds_next_row(handle) {
    case 1:
      return try resultColumns.indices.map { index in
        var cell = dblore_tds_cell()
        guard dblore_tds_cell_get(handle, Int32(index + 1), &cell), !cell.is_null else {
          return .null
        }
        return try SQLServerTypes.cell(
          type: TDSType(rawValue: cell.type),
          bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(cell.data), count: cell.length))
      }
    case 0: return nil
    default: throw failure(code: .query)
    }
  }

  /// `SERVERPROPERTY('ProductVersion')`, e.g. "16.0.4135.4"
  private func productVersion() -> String? {
    guard
      case .text(let version)? = try? rows(
        "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))"
      ).first?.first
    else { return nil }
    return version
  }

  private func failure(code: EngineErrorCode) -> EngineFailure {
    Self.failure(of: handle, code: code)
  }

  static func failure(of handle: OpaquePointer, code: EngineErrorCode) -> EngineFailure {
    SQLServerTypes.failure(
      code: code, message: String(cString: dblore_tds_error_message(handle)),
      number: dblore_tds_error_number(handle), state: dblore_tds_error_state(handle))
  }
}
