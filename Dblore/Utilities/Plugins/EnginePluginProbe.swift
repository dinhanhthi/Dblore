// EnginePluginProbe.swift
// DEBUG only: a launch with `-DbloreEngineProbe <json>` runs this probe instead of the app
// (`DbloreMain`): no SwiftUI app, AppDelegate, window, menu bar, workspace or auto-connect, so
// launch-session state, the Recent list, query history, Rewind data and settings are neither read
// nor written. It needs no click:
// - with `-DbloreDevPluginDir <dir>`, it installs the engine plugin `plugin` through
//   `PluginManager` (every size, SHA-256, cdhash and version check runs) unless the launch check
//   finds it installed;
// - then it loads the plugin (`hello`), opens `parallel` `EnginePluginSession`s on that one
//   loaded bundle, runs the step list on each of them concurrently, closes them and exits.
// Results go to `dblore-engine-probe.log` in the temporary directory (the container's tmp when
// sandboxed), or to the file after `-DbloreEngineProbeLog <path>` (a leading `~` is the real home,
// so ~/Downloads works under the downloads entitlement), appended per launch; never the password
// (replaced in every logged text, argument and cell) or the open request JSON. First come `state:`
// lines (SHA-256 and size of the preferences plist, which holds the launch session and the Recent
// list) to prove a probe launch leaves them as is. With `parallel` over 1, each line of a session
// starts with `s<n>:`.
//
// The JSON object (every field optional; without `host` the probe stops after `hello`):
//   plugin (the engine plugin id, default sqlserver; the config's database type is the one with
//     that plugin id, else a stand-in, since the session opens the plugin by id),
//   host, port (the database type's default port, 6379 for redis), user, password, database,
//   tls: { mode: off | request | require | verifyCA | verifyFull,
//          caPEM: inline PEM, or caPath: a file, e.g. under ~/Downloads (the real home) },
//   tlsServerName (the name the server certificate must match, in place of host),
//   options (sent as `open.options`, e.g. {"tdsStrict": false}),
//   readOnly (true: the config is `.readOnly`, so `open.readOnly` is sent),
//   parallel (sessions opened on the one loaded bundle, default 1),
//   query, cancelAfterSeconds (a SQL query run first, cancelled that long after it started and
//     then followed by `SELECT 1`),
//   steps: run in order on each session; each holds exactly one of
//     { argv: [ "text" | {"x": "<base64>"} ], db (default 0) }   `sendArgv` (hello `argv`)
//     { query: "<sql>" }                                         `query`, no binds
//     { settings: { statementTimeoutSeconds, lockTimeoutSeconds, idleTimeoutSeconds } }
//       (each 0 by default, which turns it off; an `unsupported` answer is not an error here)
//   and, on an argv or query step, cancelAfterMs (interrupt the session that long after the
//   request started) and cancelAfterFirstRows (interrupt it once the first rows arrived); on any
//   step, expect: "ok" (the probe exits 1 when that step fails; any other failure is logged and
//   the next step runs).
// Each step logs its start, its end with the elapsed ms and its outcome (rows, cancelled, or the
// error code and message), its columns, and its first `loggedRows` rows as `path | type | value`
// cells (`.data` as hex of the first `loggedBytes` bytes plus the length). One task per session
// logs each close event with its time. A session yields only its first close reason: a loss after
// the last step is masked by the probe's own close, so put a step after a cancel to record it.
// Exit status: 0 when the probe completed, 1 when an `expect: "ok"` step failed or the probe ran
// past `deadline`, 2 when it stopped early (unreadable JSON, install, `hello` or open failed).

#if DEBUG
  import CryptoKit
  import Foundation

  nonisolated enum EnginePluginProbe {
    static let argument = "-DbloreEngineProbe"
    static let defaultPluginID = "sqlserver"
    static let logFileName = "dblore-engine-probe.log"
    static let logArgument = "-DbloreEngineProbeLog"
    /// The probe exits by then whatever still runs (queries have no deadline)
    static let deadline: Duration = .seconds(300)
    /// Rows written to the log per step
    static let loggedRows = 50
    /// Bytes of a `.data` cell written to the log as hex
    static let loggedBytes = 256
    /// Default ports of the plugins with no `DatabaseType` yet
    static let defaultPorts = ["redis": 6379]

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// Runs the probe off the main thread and exits; the main run loop serves the main actor
    /// (`PluginManager`) meanwhile.
    @MainActor static func runAndExit() -> Never {
      let log = ProbeLog(url: logURL())
      logState(log)
      Task.detached {
        let status = await run(log)
        log.write("probe: exit \(status)")
        log.finish(status: status)
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

      var plugin: String?
      var host: String?
      var port: Int?
      var user: String?
      var password: String?
      var database: String?
      var tls: TLS?
      var tlsServerName: String?
      var options: [String: EngineJSONValue]?
      var readOnly: Bool?
      var parallel: Int?
      var query: String?
      var cancelAfterSeconds: Double?
      var steps: [Step]?
    }

    /// One step of the list; exactly one of `argv`, `query` and `settings`
    private struct Step: Decodable, Sendable {
      enum Action: Sendable {
        case argv([Argument], db: Int)
        case query(String)
        case settings(Settings)
      }

      /// An argv argument: JSON text, or `{"x": "<base64>"}` for bytes
      enum Argument: Decodable, Sendable {
        case text(String)
        case bytes(Data)

        private enum CodingKeys: String, CodingKey { case x }

        init(from decoder: any Decoder) throws {
          if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(text)
            return
          }
          let container = try decoder.container(keyedBy: CodingKeys.self)
          guard let bytes = Data(base64Encoded: try container.decode(String.self, forKey: .x))
          else {
            throw DecodingError.dataCorruptedError(
              forKey: .x, in: container, debugDescription: "not base64")
          }
          self = .bytes(bytes)
        }

        var data: Data {
          switch self {
          case .text(let text): Data(text.utf8)
          case .bytes(let bytes): bytes
          }
        }
      }

      struct Settings: Decodable, Sendable {
        var statementTimeoutSeconds: Int?
        var lockTimeoutSeconds: Int?
        var idleTimeoutSeconds: Int?
      }

      private enum CodingKeys: String, CodingKey {
        case argv, db, query, settings, cancelAfterMs, cancelAfterFirstRows, expect
      }

      let action: Action
      var cancelAfterMs: Int?
      var cancelAfterFirstRows = false
      var expectsOK = false

      init(_ action: Action, cancelAfterMs: Int? = nil) {
        self.action = action
        self.cancelAfterMs = cancelAfterMs
      }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let argv = try container.decodeIfPresent([Argument].self, forKey: .argv)
        let query = try container.decodeIfPresent(String.self, forKey: .query)
        let settings = try container.decodeIfPresent(Settings.self, forKey: .settings)
        switch (argv, query, settings) {
        case (let argv?, nil, nil):
          action = .argv(argv, db: try container.decodeIfPresent(Int.self, forKey: .db) ?? 0)
        case (nil, let query?, nil): action = .query(query)
        case (nil, nil, let settings?): action = .settings(settings)
        default:
          throw DecodingError.dataCorrupted(
            .init(
              codingPath: container.codingPath,
              debugDescription: "a step needs exactly one of argv, query and settings"))
        }
        cancelAfterMs = try container.decodeIfPresent(Int.self, forKey: .cancelAfterMs)
        cancelAfterFirstRows =
          try container.decodeIfPresent(Bool.self, forKey: .cancelAfterFirstRows) ?? false
        switch try container.decodeIfPresent(String.self, forKey: .expect) {
        case nil: expectsOK = false
        case "ok": expectsOK = true
        default:
          throw DecodingError.dataCorruptedError(
            forKey: .expect, in: container, debugDescription: "expect is only \"ok\"")
        }
      }
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

    /// The legacy `query` (with its cancel and the `SELECT 1` after it), then `steps`
    private static func steps(of request: Request) -> [Step] {
      var steps: [Step] = []
      if let query = request.query {
        steps.append(
          Step(
            .query(query),
            cancelAfterMs: request.cancelAfterSeconds.map { Int(($0 * 1000).rounded()) }))
        if request.cancelAfterSeconds != nil { steps.append(Step(.query("SELECT 1"))) }
      }
      return steps + (request.steps ?? [])
    }

    // MARK: - Run

    /// The exit status: 0 completed, 1 an `expect: "ok"` step failed, 2 stopped early
    @concurrent private static func run(_ log: ProbeLog) async -> Int32 {
      log.write("probe: start (pid \(getpid()))")
      let request: Request
      do {
        request = try Self.request()
      } catch {
        log.write("probe: \(error); stopped")
        return 2
      }
      let pluginID = request.plugin ?? defaultPluginID
      log.write("probe: plugin \(pluginID)")
      if ProcessInfo.processInfo.arguments.contains("-DbloreDevPluginDir") {
        guard await installPlugin(pluginID, log: log) else { return 2 }
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
        return 2
      }
      guard let host = request.host else {
        log.write("probe: no host; hello only")
        return 0
      }
      guard let config = config(pluginID: pluginID, host: host, request: request, log: log)
      else { return 2 }
      let ca: (pem: String, source: String)?
      do {
        ca = try caPEM(request.tls)
      } catch {
        log.write("open: \(error); stopped")
        return 2
      }
      let parallel = max(1, request.parallel ?? 1)
      let steps = steps(of: request)
      let options = request.options ?? [:]
      let tlsServerName = request.tlsServerName
      log.write(
        "open: \(host):\(config.port) database '\(config.database)' user '\(config.username)' "
          + "tls \(request.tls?.mode ?? "off") CA \(ca?.source ?? "none") tlsServerName "
          + "\(request.tlsServerName ?? host) readOnly \(config.protectionLevel == .readOnly) "
          + "options \(json(options)), \(parallel) session(s), \(steps.count) step(s)")
      return await withTaskGroup(of: Int32.self) { group in
        for index in 1...parallel {
          let log = SessionLog(log: log, prefix: parallel > 1 ? "s\(index): " : "")
          group.addTask {
            let session = EnginePluginSession(
              pluginID: pluginID, config: config, hostKeyValidator: SSHHostKeyPolicy(),
              tlsServerNameOverride: tlsServerName, openOptions: options)
            return await runSession(session, ca: ca, steps: steps, log: log)
          }
        }
        return await group.reduce(0) { max($0, $1) }
      }
    }

    /// Installs the plugin once the launch check is done (`install()` ignores calls while it is
    /// `.checking`); true when it ends `.installed`.
    @MainActor private static func installPlugin(_ pluginID: String, log: ProbeLog) async -> Bool {
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

    /// The session config: the database type that names `pluginID`, else `.postgresql` as a
    /// stand-in (the session opens the plugin by id and reads the type only for capabilities)
    private static func config(
      pluginID: String, host: String, request: Request, log: ProbeLog
    ) -> ConnectionConfig? {
      guard let sslMode = sslMode(request.tls?.mode) else {
        log.write("open: unknown tls.mode \(request.tls?.mode ?? ""); stopped")
        return nil
      }
      let type = DatabaseType.allCases.first { $0.pluginID == pluginID }
      var config = ConnectionConfig(
        databaseType: type ?? .postgresql, host: host,
        port: request.port ?? type?.defaultPort ?? defaultPorts[pluginID] ?? 0,
        database: request.database ?? "", username: request.user ?? "",
        password: request.password ?? "", sslMode: sslMode, rememberConnection: false)
      if request.readOnly == true { config.protectionLevel = .readOnly }
      // The CA reaches the session only behind this marker, from the operation material in
      // `open` (no Keychain read or write)
      if request.tls?.caPEM != nil || request.tls?.caPath != nil {
        config.clientCertificate = ClientCertificateInfo(subject: nil, expiry: nil, hasCA: true)
      }
      return config
    }

    /// Opens `session`, runs `steps` on it, then closes it. The status as for `run`.
    @concurrent private static func runSession(
      _ session: EnginePluginSession, ca: (pem: String, source: String)?, steps: [Step],
      log: SessionLog
    ) async -> Int32 {
      // Started before the open, so no close event is missed
      let watcher = Task {
        for await reason in session.closeEvents { log.write("close event: \(reason)") }
        log.write("close events: ended")
      }
      var status: Int32 = 0
      if await open(session, ca: ca, log: log) {
        for (index, step) in steps.enumerated() {
          let ok = await run(step, number: index + 1, session: session, log: log)
          if !ok && step.expectsOK {
            log.write("step \(index + 1): expected ok")
            status = 1
          }
        }
      } else {
        status = 2
      }
      await session.close()
      log.write("close: closed")
      await watcher.value
      return status
    }

    /// Opens `session` with the CA as the operation material; true when it opened
    private static func open(
      _ session: EnginePluginSession, ca: (pem: String, source: String)?, log: SessionLog
    ) async -> Bool {
      let openStart = ContinuousClock.now
      do {
        if let ca {
          let scoped = ClientCertificateStoreFactory.ScopedMaterial(
            account: ClientCertificateStoreFactory.account(for: session.config),
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
        return true
      } catch {
        log.write(
          "open: failed after \(milliseconds(since: openStart)) ms: \(session.formatError(error))")
        return false
      }
    }

    /// Runs one step and logs it; true when it succeeded
    @concurrent private static func run(
      _ step: Step, number: Int, session: EnginePluginSession, log: SessionLog
    ) async -> Bool {
      let label = "step \(number)"
      switch step.action {
      case .settings(let settings):
        log.write(
          "\(label): start settings statement \(settings.statementTimeoutSeconds ?? 0) s, lock "
            + "\(settings.lockTimeoutSeconds ?? 0) s, idle \(settings.idleTimeoutSeconds ?? 0) s")
        let start = ContinuousClock.now
        do {
          try await session.applySessionSettings(
            statementTimeoutSeconds: settings.statementTimeoutSeconds ?? 0,
            lockTimeoutSeconds: settings.lockTimeoutSeconds ?? 0,
            idleTimeoutSeconds: settings.idleTimeoutSeconds ?? 0)
          log.write(
            "\(label): end after \(milliseconds(since: start)) ms: ok (applied, or unsupported "
              + "and only logged by the session)")
          return true
        } catch {
          log.write(
            "\(label): end after \(milliseconds(since: start)) ms: \(outcome(error, session))")
          return false
        }
      case .argv(let arguments, let db):
        let words = arguments.map { describe($0, session: session) }.joined(separator: " ")
        log.write("\(label): start argv db \(db): \(words)")
        return await rows(of: step, label: label, session: session, log: log) {
          try await session.sendArgv(arguments.map(\.data), db: db)
        }
      case .query(let sql):
        log.write("\(label): start query: \(session.redacting(sql))")
        return await rows(of: step, label: label, session: session, log: log) {
          try await session.query(sql, binds: [])
        }
      }
    }

    /// Sends a row request and logs its columns and first rows; with `cancelAfterMs`, interrupts
    /// that long after the start (and with `cancelAfterFirstRows`, once the first rows came), and
    /// logs the time from the interrupt to `cancelled`.
    @concurrent private static func rows(
      of step: Step, label: String, session: EnginePluginSession, log: SessionLog,
      send: @escaping @Sendable () async throws -> SessionRowSource
    ) async -> Bool {
      let start = ContinuousClock.now
      // Started before the send: a blocking command suspends in its header read
      let canceller = step.cancelAfterMs.map { delay in
        Task { () -> ContinuousClock.Instant? in
          do { try await Task.sleep(for: .milliseconds(delay)) } catch { return nil }
          let sent = ContinuousClock.now
          log.write("\(label): interrupt sent \(milliseconds(start, sent)) ms after the start")
          await session.interrupt()
          return sent
        }
      }
      var firstRowsCancel: ContinuousClock.Instant?
      var columns: [ColumnInfo] = []
      var rows: [[CellValue]] = []
      var rowCount = 0
      var failure: Error?
      do {
        let source = try await send()
        columns = source.columns
        for try await row in source.rows {
          rowCount += 1
          if rows.count < loggedRows { rows.append(row) }
          if step.cancelAfterFirstRows && firstRowsCancel == nil {
            let sent = ContinuousClock.now
            firstRowsCancel = sent
            log.write(
              "\(label): interrupt sent after the first rows, \(milliseconds(start, sent)) ms "
                + "after the start")
            await session.interrupt()
          }
        }
      } catch {
        failure = error
      }
      let end = ContinuousClock.now
      canceller?.cancel()
      // The earlier of the timer's interrupt (nil when it never fired) and the first-rows one
      let timerSent = await canceller?.value ?? nil
      let cancelSent = [timerSent, firstRowsCancel].compactMap { $0 }.min()
      if !columns.isEmpty {
        let names = columns.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
        log.write("\(label): columns \(names)")
      }
      for (index, row) in rows.enumerated() {
        let cells = row.map { describe($0, session: session) }.joined(separator: " | ")
        log.write("\(label): row \(index + 1): \(cells)")
      }
      if rowCount > rows.count {
        log.write("\(label): \(rowCount - rows.count) more rows not logged")
      }
      let elapsed = "\(label): end after \(milliseconds(start, end)) ms"
      guard let failure else {
        let late = cancelSent != nil ? " (ended before the interrupt took effect)" : ""
        log.write("\(elapsed): ok, \(rowCount) rows\(late)")
        return true
      }
      if (failure as? EnginePluginSessionError) == .cancelled {
        let fromCancel = cancelSent.map {
          "\(milliseconds($0, end)) ms from interrupt to cancelled"
        }
        log.write("\(elapsed): cancelled, \(fromCancel ?? "no interrupt sent"), \(rowCount) rows")
      } else {
        log.write("\(elapsed): \(outcome(failure, session)), \(rowCount) rows")
      }
      return false
    }

    // MARK: - Formatting

    private static func message(_ error: Error) -> String {
      (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// `cancelled`, `error <code> [server <code>]: <message>`, or `error: <message>`, without
    /// the password
    private static func outcome(_ error: Error, _ session: EnginePluginSession) -> String {
      switch error {
      case EnginePluginSessionError.cancelled: return "cancelled"
      case EnginePluginError.server(let failure):
        let server = failure.serverCode.map { " server \($0)" } ?? ""
        return "error \(failure.code.rawValue)\(server): \(session.redacting(failure.message))"
      default: return "error: \(session.formatError(error))"
      }
    }

    private static func describe(_ argument: Step.Argument, session: EnginePluginSession) -> String
    {
      switch argument {
      case .text(let text): session.redacting(text)
      case .bytes(let bytes): describe(bytes, password: session.config.password)
      }
    }

    /// A cell as text without the password: `.string` as is, `.data` as `x'<hex>' (<n> bytes)`
    /// of the first `loggedBytes` bytes, any other as its case (`int(3)`, `null`)
    private static func describe(_ cell: CellValue, session: EnginePluginSession) -> String {
      switch cell {
      case .data(let bytes): describe(bytes, password: session.config.password)
      case .string(let text): cut(session.redacting(text))
      default: cut(session.redacting(String(describing: cell)))
      }
    }

    /// `x'<hex>' (<n> bytes)` of the first `loggedBytes` bytes, or no hex when they hold the
    /// password
    private static func describe(_ bytes: Data, password: String) -> String {
      let secret = Data(password.utf8)
      if !secret.isEmpty, bytes.range(of: secret) != nil {
        return "x'<holds the password>' (\(bytes.count) bytes)"
      }
      let hex = bytes.prefix(loggedBytes).map { String(format: "%02x", $0) }.joined()
      let more = bytes.count > loggedBytes ? "…" : ""
      return "x'\(hex)'\(more) (\(bytes.count) bytes)"
    }

    private static func cut(_ text: String) -> String {
      text.count > 500 ? String(text.prefix(500)) + "…" : text
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

  /// A session's lines in the probe log, each after the session's prefix
  nonisolated private struct SessionLog: Sendable {
    let log: ProbeLog
    let prefix: String

    func write(_ message: String) { log.write(prefix + message) }
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
