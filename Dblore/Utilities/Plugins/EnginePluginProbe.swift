// EnginePluginProbe.swift
// DEBUG only: a launch with `-DbloreEngineProbe <json>` runs this probe instead of the app
// (`DbloreMain`): no SwiftUI app, AppDelegate, window, menu bar, workspace or auto-connect, so
// launch-session state, the Recent list, query history, Rewind data and settings are neither read
// nor written. It needs no click:
// - with `-DbloreDevPluginDir <dir>`, it installs the sqlserver plugin through `PluginManager`
//   (every size, SHA-256, cdhash and version check runs) unless the launch check finds it installed;
// - then it loads the plugin (`hello`), opens one `EnginePluginSession`, runs `query` (cancelled
//   `cancelAfterSeconds` after it started, then `SELECT 1`), closes the session and exits.
// Results go to `dblore-engine-probe.log` in the temporary directory (the container's tmp when
// sandboxed), or to the file after `-DbloreEngineProbeLog <path>` (a leading `~` is the real home,
// so ~/Downloads works under the downloads entitlement), appended per launch; never the password
// or the open request JSON. First come `state:` lines (SHA-256 and size of the preferences plist,
// which holds the launch session and the Recent list) to prove a probe launch leaves them as is.
//
// The JSON object (every field optional; without `host` the probe stops after `hello`):
//   host, port (1433), user, password, database,
//   tls: { mode: off | request | require | verifyCA | verifyFull,
//          caPEM: inline PEM, or caPath: a file, e.g. under ~/Downloads (the real home) },
//   tlsServerName (the name the server certificate must match, in place of host),
//   options (sent as `open.options`, e.g. {"tdsStrict": false}), query, cancelAfterSeconds

#if DEBUG
  import CryptoKit
  import Foundation

  nonisolated enum EnginePluginProbe {
    static let argument = "-DbloreEngineProbe"
    static let pluginID = "sqlserver"
    static let logFileName = "dblore-engine-probe.log"
    static let logArgument = "-DbloreEngineProbeLog"
    /// The probe exits by then whatever still runs (queries have no deadline)
    static let deadline: Duration = .seconds(300)
    /// Rows written to the log per query
    static let loggedRows = 20

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// Runs the probe off the main thread and exits; the main run loop serves the main actor
    /// (`PluginManager`) meanwhile.
    @MainActor static func runAndExit() -> Never {
      let log = ProbeLog(url: logURL())
      logState(log)
      Task.detached {
        await run(log)
        log.finish(status: 0)
      }
      Task.detached {
        try? await Task.sleep(for: deadline)
        log.write("probe: still running after \(deadline); exiting")
        log.finish(status: 1)
      }
      RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .default)
      while true { RunLoop.main.run() }
    }

    /// The file after `-DbloreEngineProbeLog` (a leading `~` is the real home, not the
    /// container), else `logFileName` in the temporary directory
    private static func logURL() -> URL {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: logArgument), arguments.indices.contains(index + 1)
      else { return FileManager.default.temporaryDirectory.appendingPathComponent(logFileName) }
      var path = arguments[index + 1]
      if path == "~" || path.hasPrefix("~/"), let home = getpwuid(getuid())?.pointee.pw_dir {
        path = String(cString: home) + path.dropFirst()
      }
      return URL(fileURLWithPath: path)
    }

    // MARK: - State

    /// Logs the SHA-256 and size of the files a launch could change, before any other work.
    /// `LaunchSessionStore` (key `LaunchSessionStore.key`) and `RecentManager.sharedDefaults` both
    /// use `UserDefaults.standard` in the app, so the preferences plist holds all of them.
    /// Read-only: a missing file is reported, never created.
    @MainActor private static func logState(_ log: ProbeLog) {
      guard
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      else {
        log.write("state: no library directory")
        return
      }
      let bundleID = Bundle.main.bundleIdentifier ?? "ace.thi.Dblore"
      let preferences = library.appendingPathComponent("Preferences/\(bundleID).plist")
      log.write("state: preferences \(fingerprint(preferences)) \(preferences.path)")
      log.write(
        "state: launch session is UserDefaults-only (key \(LaunchSessionStore.key) in the "
          + "preferences plist)")
      log.write("state: Recent list is UserDefaults-only (.standard, the preferences plist)")
    }

    /// `sha256 <hex> <bytes> bytes`, `missing`, or `unreadable: <reason>`
    private static func fingerprint(_ url: URL) -> String {
      guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
      do {
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256 \(hex) \(data.count) bytes"
      } catch {
        return "unreadable: \(error.localizedDescription)"
      }
    }

    // MARK: - Request

    private struct Request: Decodable {
      struct TLS: Decodable {
        var mode: String?
        var caPEM: String?
        var caPath: String?
      }

      var host: String?
      var port: Int?
      var user: String?
      var password: String?
      var database: String?
      var tls: TLS?
      var tlsServerName: String?
      var options: [String: EngineJSONValue]?
      var query: String?
      var cancelAfterSeconds: Double?
    }

    private enum ProbeError: Error, CustomStringConvertible {
      case missingValue
      case unreadable(String)

      var description: String {
        switch self {
        case .missingValue: "\(argument) has no value"
        case .unreadable(let reason): reason
        }
      }
    }

    /// The JSON after `-DbloreEngineProbe`. Errors never quote it (it holds the password).
    private static func request() throws -> Request {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1)
      else { throw ProbeError.missingValue }
      do {
        return try JSONDecoder().decode(Request.self, from: Data(arguments[index + 1].utf8))
      } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(
        _, context),
        let DecodingError.keyNotFound(_, context), let DecodingError.dataCorrupted(context)
      {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        throw ProbeError.unreadable("\(argument) is not a valid probe object (at '\(path)')")
      } catch {
        throw ProbeError.unreadable("\(argument) is not a valid probe object")
      }
    }

    /// ABI TLS mode names as the `SSLMode` that `EnginePluginSession.tlsMode` maps back to them
    private static func sslMode(_ name: String?) -> SSLMode? {
      switch name ?? "off" {
      case "off": .disable
      case "request": .prefer
      case "require": .require
      case "verifyCA": .verifyCa
      case "verifyFull": .verifyFull
      default: nil
      }
    }

    /// The CA PEM, inline or read from `caPath` (a leading `~` is the real home, not the
    /// container); nil when neither is given
    private static func caPEM(_ tls: Request.TLS?) throws -> (pem: String, source: String)? {
      if let pem = tls?.caPEM { return (pem, "inline") }
      guard var path = tls?.caPath else { return nil }
      if path == "~" || path.hasPrefix("~/"), let home = getpwuid(getuid())?.pointee.pw_dir {
        path = String(cString: home) + path.dropFirst()
      }
      do {
        return (try String(contentsOfFile: path, encoding: .utf8), path)
      } catch {
        throw ProbeError.unreadable(
          "cannot read the CA file \(path): \(error.localizedDescription)")
      }
    }

    // MARK: - Run

    @concurrent private static func run(_ log: ProbeLog) async {
      log.write("probe: start (pid \(getpid()), plugin \(pluginID))")
      let request: Request
      do {
        request = try Self.request()
      } catch {
        log.write("probe: \(error); stopped")
        return
      }
      if ProcessInfo.processInfo.arguments.contains("-DbloreDevPluginDir") {
        guard await installPlugin(log) else { return }
      }
      let runtime = EnginePluginRuntime.runtime(for: pluginID)
      let loadStart = ContinuousClock.now
      do {
        let hello = try await runtime.start()
        log.write(
          "hello: protocol \(hello.protocolVersion) (app speaks \(EnginePluginProtocol.version)), "
            + "engine \(hello.engine), version \(hello.version), query language "
            + "\(hello.queryLanguage), in \(milliseconds(since: loadStart)) ms")
        let libraries = hello.libraries.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        log.write("hello: libraries \(libraries.joined(separator: ", "))")
        log.write("hello: features \(hello.features.joined(separator: ", "))")
      } catch {
        log.write("hello: failed: \(message(error)); stopped")
        return
      }
      guard let host = request.host else {
        log.write("probe: no host; hello only")
        return
      }
      await connect(host: host, request: request, log: log)
    }

    /// Installs the plugin once the launch check is done (`install()` ignores calls while it is
    /// `.checking`); true when it ends `.installed`.
    @MainActor private static func installPlugin(_ log: ProbeLog) async -> Bool {
      guard let manager = PluginRegistry.shared.manager(id: pluginID) else {
        log.write("install: the bundled catalog has no \(pluginID) entry; stopped")
        return false
      }
      if await manager.isInstalledAfterLaunchCheck() {
        log.write("install: already installed (\(manager.state)); not installed again")
      } else {
        log.write("install: \(manager.state) after the launch check; installing")
        let start = ContinuousClock.now
        await manager.install()
        log.write("install: ended in \(milliseconds(since: start)) ms")
      }
      guard case .installed = manager.state else {
        log.write("install: state \(manager.state), not installed; stopped")
        return false
      }
      log.write("install: \(manager.state)")
      return true
    }

    /// Opens one session from `request`, runs its query, then closes it.
    @concurrent private static func connect(
      host: String, request: Request, log: ProbeLog
    ) async {
      guard let sslMode = sslMode(request.tls?.mode) else {
        log.write("open: unknown tls.mode \(request.tls?.mode ?? ""); stopped")
        return
      }
      let ca: (pem: String, source: String)?
      do {
        ca = try caPEM(request.tls)
      } catch {
        log.write("open: \(error); stopped")
        return
      }
      // `.postgresql` until `.sqlserver` exists; the plugin is chosen by `pluginID` alone
      var config = ConnectionConfig(
        databaseType: .postgresql, host: host, port: request.port ?? 1433,
        database: request.database ?? "", username: request.user ?? "",
        password: request.password ?? "", sslMode: sslMode, rememberConnection: false)
      // The CA reaches the session only behind this marker, from the operation material below
      // (no Keychain read or write)
      if ca != nil {
        config.clientCertificate = ClientCertificateInfo(subject: nil, expiry: nil, hasCA: true)
      }
      let options = request.options ?? [:]
      let session = EnginePluginSession(
        pluginID: pluginID, config: config, hostKeyValidator: SSHHostKeyPolicy(),
        tlsServerNameOverride: request.tlsServerName, openOptions: options)
      log.write(
        "open: \(host):\(config.port) database '\(config.database)' user '\(config.username)' "
          + "tls \(request.tls?.mode ?? "off") CA \(ca?.source ?? "none") tlsServerName "
          + "\(request.tlsServerName ?? host) options \(json(options))")
      let openStart = ContinuousClock.now
      do {
        if let ca {
          let scoped = ClientCertificateStoreFactory.ScopedMaterial(
            account: ClientCertificateStoreFactory.account(for: config),
            material: ClientCertificateMaterial(caPEM: ca.pem))
          defer { scoped.clear() }
          try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
            try await session.open()
          }
        } else {
          try await session.open()
        }
        log.write("open: opened in \(milliseconds(since: openStart)) ms")
        log.write("opened: \(session.redacting(session.serverVersion ?? ""))")
      } catch {
        log.write(
          "open: failed after \(milliseconds(since: openStart)) ms: \(session.formatError(error))")
        await session.close()
        log.write("close: closed")
        return
      }
      if let query = request.query {
        await run(query, cancelAfter: request.cancelAfterSeconds, session: session, log: log)
        if request.cancelAfterSeconds != nil {
          await run("SELECT 1", cancelAfter: nil, session: session, log: log)
        }
      }
      await session.close()
      log.write("close: closed")
    }

    /// Runs `sql` and logs its columns and first rows; with `cancelAfter`, sends cancel that many
    /// seconds after the query started and logs the time from cancel to `cancelled`.
    @concurrent private static func run(
      _ sql: String, cancelAfter: Double?, session: EnginePluginSession, log: ProbeLog
    ) async {
      log.write("query: \(sql)")
      let start = ContinuousClock.now
      let canceller = cancelAfter.map { seconds in
        Task { () -> ContinuousClock.Instant? in
          do { try await Task.sleep(for: .seconds(seconds)) } catch { return nil }
          let sent = ContinuousClock.now
          log.write("query: cancel sent \(milliseconds(start, sent)) ms after the start")
          await session.interrupt()
          return sent
        }
      }
      var columns: [ColumnInfo] = []
      var rows: [[CellValue]] = []
      var rowCount = 0
      var failure: Error?
      do {
        // A statement without a result set (WAITFOR) suspends here until it ends or is cancelled
        let source = try await session.query(sql, binds: [])
        columns = source.columns
        for try await row in source.rows {
          rowCount += 1
          if rows.count < loggedRows { rows.append(row) }
        }
      } catch {
        failure = error
      }
      let end = ContinuousClock.now
      canceller?.cancel()
      let cancelSent = await canceller?.value ?? nil
      guard let failure else {
        log.write("query: done in \(milliseconds(start, end)) ms, \(rowCount) rows")
        if !columns.isEmpty {
          log.write(
            "query: columns \(columns.map { "\($0.name) (\($0.type))" }.joined(separator: ", "))")
        }
        for row in rows { log.write("query: row \(row.map(describe).joined(separator: " | "))") }
        if cancelAfter != nil { log.write("query: ended before the cancel took effect") }
        return
      }
      if (failure as? EnginePluginSessionError) == .cancelled {
        let fromCancel = cancelSent.map { "\(milliseconds($0, end)) ms from cancel to cancelled" }
        log.write(
          "query: cancelled, \(fromCancel ?? "no cancel sent"), "
            + "\(milliseconds(start, end)) ms after the start")
      } else {
        log.write(
          "query: failed after \(milliseconds(start, end)) ms: \(session.formatError(failure))")
      }
    }

    // MARK: - Formatting

    private static func message(_ error: Error) -> String {
      (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func describe(_ cell: CellValue) -> String {
      let text = String(describing: cell)
      return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    private static func json(_ options: [String: EngineJSONValue]) -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return (try? encoder.encode(options)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
      milliseconds(start, .now)
    }

    private static func milliseconds(
      _ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant
    ) -> Int {
      let elapsed = (end - start).components
      return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
  }

  /// Appends timestamped lines to the probe log, each written through at once.
  nonisolated private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle?
    private let formatter: ISO8601DateFormatter

    init(url: URL) {
      if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      file = try? FileHandle(forWritingTo: url)
      _ = try? file?.seekToEnd()
      formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      write("probe: log \(url.path)")
    }

    func write(_ message: String) {
      lock.withLock {
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        try? file?.write(contentsOf: line)
      }
    }

    /// Flushes the log and exits; a second caller waits on the lock until the process is gone.
    func finish(status: Int32) -> Never {
      lock.lock()
      try? file?.synchronize()
      try? file?.close()
      exit(status)
    }
  }
#endif
