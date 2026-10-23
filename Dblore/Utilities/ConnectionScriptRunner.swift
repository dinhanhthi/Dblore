//
//  ConnectionScriptRunner.swift
//  Dblore
//
//  A connection's scripts: pre-connect, post-disconnect and the password command. They are
//  plain file names in the app's Application Scripts folder
//  (`~/Library/Application Scripts/<bundle id>`), the only place a sandboxed app may run user
//  scripts from (`NSUserUnixTask`). A name is a single path component, checked again after
//  standardizing and resolving symlinks, so nothing outside that folder runs.
//
//  Scripts get host, port, user and database as arguments, refused when one starts with `-` or
//  holds a control character (it could pass for an option). `NSUserUnixTask` has no
//  environment, working directory, terminate or exit status API: scripts inherit the user's
//  environment, not the app's, the exit status is read from the failure reason, and a script
//  that times out is abandoned, still running.
//
//  Output is a secret (the password command prints a password): stdout is read at most 64 KiB,
//  stderr 4 KiB, the rest drained so the script never blocks on a full pipe. Neither is ever
//  logged or stored. Errors carry the exit status, and only a pre-connect failure carries its
//  capped stderr, in the message shown to the user, never in its `description` (which logs see).
//

import Foundation

/// One run of a user script: `NSUserUnixTask` in the app.
nonisolated protocol ConnectionScriptTask: AnyObject {
  var standardOutput: FileHandle? { get set }
  var standardError: FileHandle? { get set }
  func execute(
    withArguments arguments: [String]?, completionHandler handler: NSUserUnixTask.CompletionHandler?
  )
}

extension NSUserUnixTask: ConnectionScriptTask {}

nonisolated struct ConnectionScriptRunner: Sendable {
  enum Role: Sendable, Equatable {
    case preConnect
    case postDisconnect
    case passwordCommand

    var title: String {
      switch self {
      case .preConnect: "Pre-connect script"
      case .postDisconnect: "Post-disconnect script"
      case .passwordCommand: "Password command"
      }
    }
  }

  enum ScriptError: Error, Equatable, LocalizedError, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
  {
    /// Not a plain file name directly inside the scripts folder (never echoed back)
    case invalidName(Role)
    case folderUnavailable(Role)
    case notFound(Role, name: String)
    /// `stderr` is set only for a pre-connect failure, capped and sanitized
    case failed(Role, name: String, status: Int?, stderr: String)
    case timedOut(Role, name: String, seconds: Int)
    case emptyPassword(name: String)
    /// The host, user or database could pass for an option (never echoed back)
    case unsafeArguments(Role, name: String)

    var errorDescription: String? {
      switch self {
      case .invalidName(let role):
        return "\(role.title) is not a plain file name in the scripts folder."
      case .folderUnavailable(let role):
        return "\(role.title) cannot run: the scripts folder is not available."
      case .notFound(let role, let name):
        return "\(role.title) \"\(name)\" is not in the scripts folder."
      case .failed(let role, let name, let status, let stderr):
        let summary = Self.summary(role: role, name: name, status: status)
        return stderr.isEmpty ? summary : summary + "\n" + stderr
      case .timedOut(let role, let name, let seconds):
        return
          "\(role.title) \"\(name)\" did not finish within \(seconds) s. It may still be running: "
          + "Dblore cannot stop it."
      case .emptyPassword(let name):
        return "Password command \"\(name)\" printed no password on its first line."
      case .unsafeArguments(let role, let name):
        return
          "\(role.title) \"\(name)\" was not run: the connection's host, user or database "
          + "starts with \"-\" or holds a control character."
      }
    }

    /// What logs and `String(describing:)` see: never the script's output.
    var description: String {
      switch self {
      case .failed(let role, let name, let status, _):
        Self.summary(role: role, name: name, status: status)
      default:
        errorDescription ?? "Connection script error"
      }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
      Mirror(self, children: ["summary": description], displayStyle: .enum)
    }

    private static func summary(role: Role, name: String, status: Int?) -> String {
      let exit = status.map { "exit status \($0)" } ?? "no exit status"
      return "\(role.title) \"\(name)\" failed (\(exit))."
    }
  }

  static let stdoutLimit = 64 * 1024
  static let stderrLimit = 4 * 1024
  /// Characters of a pre-connect script's stderr shown in its failure
  static let shownStderrLimit = 1_000
  static let timeoutRange = 1...300
  static let defaultTimeout = 30
  static let nameByteLimit = 255

  /// The scripts folder; throws when it cannot be found.
  var scriptsFolder: @Sendable () throws -> URL
  var makeTask: @Sendable (URL) throws -> any ConnectionScriptTask

  /// `NSUserUnixTask` on the app's Application Scripts folder
  static let app = ConnectionScriptRunner(
    scriptsFolder: { try applicationScriptsFolder() },
    makeTask: { try NSUserUnixTask(url: $0) })

  /// `~/Library/Application Scripts/<bundle id>`; `create` makes it when missing.
  static func applicationScriptsFolder(create: Bool = false) throws -> URL {
    try FileManager.default.url(
      for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
  }

  // MARK: - Names

  /// A plain file name: not empty, at most 255 bytes, no leading `.` (so no `..`), and no `/`,
  /// `:`, `"`, control, format (bidi) or line separator characters.
  static func isValidName(_ name: String) -> Bool {
    let refused = CharacterSet.controlCharacters.union(.newlines)
      .union(CharacterSet(charactersIn: "/:\"\u{0}"))
    return !name.isEmpty && name.utf8.count <= nameByteLimit && !name.hasPrefix(".")
      && !name.unicodeScalars.contains(where: refused.contains)
  }

  /// `name` in the scripts folder, once its standardized, symlink-resolved path is directly
  /// inside that folder and names an existing file.
  func resolvedURL(for name: String, role: Role) throws -> URL {
    guard Self.isValidName(name) else { throw ScriptError.invalidName(role) }
    let folder: URL
    do {
      folder = try scriptsFolder().standardizedFileURL.resolvingSymlinksInPath()
    } catch {
      throw ScriptError.folderUnavailable(role)
    }
    let url = folder.appendingPathComponent(name, isDirectory: false).standardizedFileURL
      .resolvingSymlinksInPath()
    guard url.deletingLastPathComponent().path == folder.path else {
      throw ScriptError.invalidName(role)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { throw ScriptError.notFound(role, name: name) }
    return url
  }

  /// The scripts the form offers: files of the folder that `resolvedURL` accepts, sorted.
  func availableNames() -> [String] {
    guard let folder = try? scriptsFolder(),
      let urls = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return urls.map(\.lastPathComponent)
      .filter { (try? resolvedURL(for: $0, role: .preConnect)) != nil }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - Running

  /// Host, port, user and database, in that order. Configs also come from files and imports,
  /// so a host, user or database a command could read as an option (a leading `-`) or that
  /// holds a control, format or line separator character is refused.
  static func arguments(for config: ConnectionConfig, role: Role, name: String) throws -> [String] {
    guard [config.host, config.username, config.database].allSatisfy(isSafeArgument) else {
      throw ScriptError.unsafeArguments(role, name: name)
    }
    return [config.host, String(config.port), config.username, config.database]
  }

  /// Not starting with `-`, and no control, format (bidi) or line separator character.
  static func isSafeArgument(_ value: String) -> Bool {
    let refused = CharacterSet.controlCharacters.union(.newlines)
    return !value.hasPrefix("-") && !value.unicodeScalars.contains(where: refused.contains)
  }

  /// Seconds a script may run: 1 to 300, 30 when unset.
  static func clampedTimeout(_ seconds: Int?) -> Int {
    guard let seconds else { return defaultTimeout }
    return min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
  }

  /// Runs `name` before connecting with `config`; a failure carries its exit status and capped
  /// stderr.
  func runPreConnect(_ name: String, for config: ConnectionConfig) async throws {
    _ = try await run(name, role: .preConnect, config: config)
  }

  /// The first line of `name`'s stdout, trimmed. A failure carries its exit status only: a
  /// password tool's stderr may echo the secret.
  func password(from name: String, for config: ConnectionConfig) async throws -> String {
    let output = try await run(name, role: .passwordCommand, config: config)
    let text = String(decoding: output.stdout, as: UTF8.self)
    let firstLine =
      text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .first.map(String.init) ?? ""
    let password = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !password.isEmpty else { throw ScriptError.emptyPassword(name: name) }
    return password
  }

  /// Starts `name` after a disconnect and returns once it runs, without waiting for it to
  /// finish, so a quit can start it right before the app exits. Its output goes to /dev/null
  /// (nothing reads it, and a pipe would break when the app exits). A failure is logged (exit
  /// status only) and never shown as a connect error.
  func runPostDisconnect(_ name: String, for config: ConnectionConfig) {
    let seconds = Self.clampedTimeout(config.scriptTimeoutSeconds)
    let run = ScriptRun()
    do {
      try launch(run, name: name, role: .postDisconnect, config: config, capturesOutput: false)
    } catch {
      let message = String(describing: error)
      Task.detached { await AppLogger.shared.warning(message, category: "Scripts") }
      return
    }
    Task.detached {
      await AppLogger.shared.info(
        "Running \(Role.postDisconnect.title.lowercased()) \"\(name)\"", category: "Scripts")
      do {
        _ = try Self.output(
          of: await run.outcome(), role: .postDisconnect, name: name, seconds: seconds)
      } catch {
        await AppLogger.shared.warning("\(error)", category: "Scripts")
      }
    }
  }

  /// Captured output: never logged, never stored past the caller.
  private struct Output: CustomStringConvertible, CustomReflectable {
    var stdout: Data
    var stderr: Data
    var description: String { "ConnectionScriptRunner.Output(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
  }

  /// Off the caller's actor: the script starts and its timeout is armed before any await, and
  /// nothing between the start and the outcome waits on a busy actor.
  @concurrent private func run(
    _ name: String, role: Role, config: ConnectionConfig
  ) async throws -> Output {
    let seconds = Self.clampedTimeout(config.scriptTimeoutSeconds)
    let run = ScriptRun()
    let outcome = try await withTaskCancellationHandler {
      // Already cancelled: `onCancel` ran first, so nothing is made or started
      try Task.checkCancellation()
      try launch(run, name: name, role: role, config: config, capturesOutput: true)
      await AppLogger.shared.info(
        "Running \(role.title.lowercased()) \"\(name)\"", category: "Scripts")
      return await run.outcome()
    } onCancel: {
      run.finish(.cancelled)
    }
    return try Self.output(of: outcome, role: role, name: name, seconds: seconds)
  }

  /// Checks `name` and the arguments, then starts the script in `run` (unless a cancel already
  /// finished it) and arms its timeout, synchronously.
  private func launch(
    _ run: ScriptRun, name: String, role: Role, config: ConnectionConfig, capturesOutput: Bool
  ) throws {
    let url = try resolvedURL(for: name, role: role)
    let arguments = try Self.arguments(for: config, role: role, name: name)
    let task: any ConnectionScriptTask
    do {
      task = try makeTask(url)
    } catch {
      throw ScriptError.notFound(role, name: name)
    }
    run.start(
      task, arguments: arguments, timeoutSeconds: Self.clampedTimeout(config.scriptTimeoutSeconds),
      capturesOutput: capturesOutput)
  }

  private static func output(
    of outcome: ScriptRun.Outcome, role: Role, name: String, seconds: Int
  ) throws -> Output {
    switch outcome {
    case .cancelled:
      throw CancellationError()
    case .timedOut:
      throw ScriptError.timedOut(role, name: name, seconds: seconds)
    case .completed(let error, let stdout, let stderr):
      guard let error else { return Output(stdout: stdout, stderr: stderr) }
      throw ScriptError.failed(
        role, name: name, status: exitStatus(of: error),
        stderr: role == .preConnect ? shownStderr(stderr) : "")
    }
  }

  /// N of the failure reason "Script task exited with status N", the only place
  /// `NSUserUnixTask` reports it.
  static func exitStatus(of error: any Error) -> Int? {
    let reason = (error as NSError).userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ""
    guard let match = reason.firstMatch(of: /exited with status (\d+)/) else { return nil }
    return Int(match.1)
  }

  /// At most `shownStderrLimit` characters, without control or format (bidi) characters
  /// other than line breaks, trimmed.
  static func shownStderr(_ data: Data) -> String {
    let removed = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n"))
    let text = String(
      String(decoding: data, as: UTF8.self).unicodeScalars.filter { !removed.contains($0) })
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > shownStderrLimit
      ? String(trimmed.prefix(shownStderrLimit)) + "…" : trimmed
  }
}

/// One script run. The completion, the timeout and a cancel race to `finish`, which keeps the
/// outcome exactly once for `outcome()`. The timers are GCD, never the Swift cooperative pool or
/// an actor, so a busy app cannot delay them.
///
/// With `capturesOutput`, two bounded pipe readers. Once the script exits, the run finishes when
/// both pipes reach EOF, or `exitGrace` later with what was read: a background child the script
/// started (`… &`) inherits the pipes and may keep them open for its whole life. After `finish`,
/// the readers keep draining (keeping nothing) so no child ever blocks on a full pipe. Handles:
/// the app's write ends are closed at exit or `finish`; each read end's readability handler
/// holds this run until its pipe reaches EOF, that is until the script and every child holding
/// the pipe have exited, then drops it, and the run is freed.
private nonisolated final class ScriptRun: @unchecked Sendable {
  enum Outcome {
    case completed(error: (any Error)?, stdout: Data, stderr: Data)
    case timedOut
    case cancelled
  }

  /// Time after the script's exit before a run whose pipes are still open finishes anyway
  static let exitGrace: DispatchTimeInterval = .milliseconds(300)

  private let lock = NSLock()
  private var pipes: (stdout: Pipe, stderr: Pipe)?
  private var writersClosed = false
  private var continuation: CheckedContinuation<Outcome, Never>?
  /// The outcome until `outcome()` takes it
  private var result: Outcome?
  private var finished = false
  private var stdout = Data()
  private var stderr = Data()
  private var openReaders = 0
  private var exited = false
  private var exitError: (any Error)?
  private var timers: [DispatchWorkItem] = []

  /// Starts `task` unless the run is already finished (cancelled), and arms the timeout.
  func start(
    _ task: any ConnectionScriptTask, arguments: [String], timeoutSeconds: Int,
    capturesOutput: Bool
  ) {
    lock.lock()
    // A cancel that came first: no pipe or handler that nothing would ever close
    guard !finished else {
      lock.unlock()
      return
    }
    let pipes = capturesOutput ? (stdout: Pipe(), stderr: Pipe()) : nil
    self.pipes = pipes
    openReaders = pipes == nil ? 0 : 2
    lock.unlock()

    if let pipes {
      pipes.stdout.fileHandleForReading.readabilityHandler = { [self] handle in
        received(handle.availableData, isStdout: true)
      }
      pipes.stderr.fileHandleForReading.readabilityHandler = { [self] handle in
        received(handle.availableData, isStdout: false)
      }
      task.standardOutput = pipes.stdout.fileHandleForWriting
      task.standardError = pipes.stderr.fileHandleForWriting
    }
    lock.lock()
    let cancelled = finished
    lock.unlock()
    guard !cancelled else {
      closeWriters()
      return
    }
    task.execute(withArguments: arguments) { [self] error in
      exitedWith(error)
    }
    schedule(after: .seconds(timeoutSeconds)) { $0.finish(.timedOut) }
  }

  /// The outcome, once `finish` has one.
  func outcome() async -> Outcome {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let result {
        self.result = nil
        lock.unlock()
        continuation.resume(returning: result)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  /// Keeps the first bytes up to the stream's limit and drops the rest, also after `finish`, so
  /// the script never blocks on a full pipe; empty data is EOF.
  private func received(_ data: Data, isStdout: Bool) {
    lock.lock()
    if data.isEmpty {
      if let pipes {
        (isStdout ? pipes.stdout : pipes.stderr).fileHandleForReading.readabilityHandler = nil
      }
      openReaders -= 1
    } else if finished {
      // Abandoned or done: drained, not kept
    } else if isStdout {
      stdout.append(data.prefix(max(0, ConnectionScriptRunner.stdoutLimit - stdout.count)))
    } else {
      stderr.append(data.prefix(max(0, ConnectionScriptRunner.stderrLimit - stderr.count)))
    }
    let done = !finished && exited && openReaders == 0
    lock.unlock()
    if done { finishCompleted() }
  }

  /// The script exited: close the app's write ends so the readers reach EOF, and finish now
  /// when they did, else after `exitGrace`.
  private func exitedWith(_ error: (any Error)?) {
    lock.lock()
    exited = true
    exitError = error
    let done = openReaders == 0
    lock.unlock()
    closeWriters()
    if done {
      finishCompleted()
    } else {
      schedule(after: Self.exitGrace) { $0.finishCompleted() }
    }
  }

  private func finishCompleted() {
    lock.lock()
    let outcome = Outcome.completed(error: exitError, stdout: stdout, stderr: stderr)
    lock.unlock()
    finish(outcome)
  }

  func finish(_ outcome: Outcome) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    if continuation == nil { result = outcome }
    stdout = Data()
    stderr = Data()
    let timers = timers
    self.timers = []
    lock.unlock()
    for timer in timers { timer.cancel() }
    // The read ends stay open: their handlers keep draining until the script closes its ends
    closeWriters()
    continuation?.resume(returning: outcome)
  }

  /// Runs `action` after `delay` on a GCD queue while the run lives and is not finished.
  private func schedule(
    after delay: DispatchTimeInterval, _ action: @escaping @Sendable (ScriptRun) -> Void
  ) {
    let item = DispatchWorkItem { [weak self] in
      if let self { action(self) }
    }
    lock.lock()
    let finished = finished
    if !finished { timers.append(item) }
    lock.unlock()
    guard !finished else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
  }

  /// Closes the app's copies of the write ends, once there are pipes, and only once.
  private func closeWriters() {
    lock.lock()
    guard !writersClosed, let pipes else {
      lock.unlock()
      return
    }
    writersClosed = true
    lock.unlock()
    try? pipes.stdout.fileHandleForWriting.close()
    try? pipes.stderr.fileHandleForWriting.close()
  }
}
