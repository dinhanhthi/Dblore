// ConnectionScriptRunnerTests.swift
// Connection scripts: only plain names inside the scripts folder run, never with an argument
// that could pass for an option, a script that never finishes is abandoned at the timeout, one
// whose background child keeps the pipes open finishes anyway, and no script output reaches
// the log or an error. Not on the main actor: a busy main actor must not delay a run.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection script runner")
struct ConnectionScriptRunnerTests {

  /// A script that writes `stdout` and `stderr`, then completes with `error`; or never completes.
  /// With `backgroundChild`, a child it started keeps a copy of its stdout open after it exits,
  /// until `endBackgroundChild()`.
  private nonisolated final class FakeTask: ConnectionScriptTask, @unchecked Sendable {
    var standardOutput: FileHandle?
    var standardError: FileHandle?
    let stdout: Data
    let stderr: Data
    let error: (any Error)?
    let completes: Bool
    let backgroundChild: Bool
    private(set) var arguments: [String]?
    private var childOutput: Int32 = -1

    init(
      stdout: String = "", stderr: String = "", error: (any Error)? = nil, completes: Bool = true,
      backgroundChild: Bool = false
    ) {
      self.stdout = Data(stdout.utf8)
      self.stderr = Data(stderr.utf8)
      self.error = error
      self.completes = completes
      self.backgroundChild = backgroundChild
    }

    func execute(
      withArguments arguments: [String]?,
      completionHandler handler: NSUserUnixTask.CompletionHandler?
    ) {
      self.arguments = arguments
      if backgroundChild, let out = standardOutput { childOutput = dup(out.fileDescriptor) }
      guard completes else { return }
      let (out, err, stdout, stderr, error) = (
        standardOutput, standardError, self.stdout, self.stderr, self.error
      )
      DispatchQueue.global().async {
        try? out?.write(contentsOf: stdout)
        try? err?.write(contentsOf: stderr)
        handler?(error)
      }
    }

    func endBackgroundChild() {
      if childOutput >= 0 { close(childOutput) }
      childOutput = -1
    }
  }

  /// URLs the runner asked a task for
  private nonisolated final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
      lock.lock()
      urls.append(url)
      lock.unlock()
    }
    var all: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return urls
    }
  }

  /// A scripts folder holding `names`, removed by `body`'s caller.
  private static func withFolder(
    _ names: [String], _ body: (URL) async throws -> Void
  ) async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in names {
      try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent(name))
    }
    try await body(folder)
  }

  private static func runner(
    _ folder: URL, task: FakeTask, made: Made = Made()
  ) -> ConnectionScriptRunner {
    ConnectionScriptRunner(
      scriptsFolder: { folder },
      makeTask: { url in
        made.append(url)
        return task
      })
  }

  /// db.example.com:6543, user ada, database sales, 1 s timeout by default. Built on the main
  /// actor: the config's members are main-actor isolated outside the app module.
  @MainActor private static func config(
    host: String = "db.example.com", user: String = "ada", database: String = "sales",
    timeout: Int = 1
  ) -> ConnectionConfig {
    var config = ConnectionConfig(host: host, port: 6543, database: database, username: user)
    config.scriptTimeoutSeconds = timeout
    return config
  }

  private static func exitError(_ status: Int) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain, code: 2,
      userInfo: [NSLocalizedFailureReasonErrorKey: "Script task exited with status \(status)"])
  }

  @Test(
    "Traversal, absolute, hidden and control-character names are refused before any task is made",
    arguments: [
      "../ok.sh", "/bin/sh", "sub/ok.sh", ".ok.sh", "..", "", "ok.sh\u{0}", "ok\n.sh",
      "ok\u{202E}hs.sh", "outside.sh",
    ])
  func refusesNamesOutsideTheFolder(name: String) async throws {
    let config = await Self.config()
    try await Self.withFolder(["ok.sh"]) { folder in
      // A link in the folder to a file outside it
      try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("outside.sh"),
        withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
      let made = Made()
      let runner = Self.runner(folder, task: FakeTask(), made: made)

      await #expect(throws: ConnectionScriptRunner.ScriptError.invalidName(.preConnect)) {
        try await runner.runPreConnect(name, for: config)
      }
      #expect(made.all.isEmpty)
      #expect(!runner.availableNames().contains(name))
    }
  }

  @Test("A plain name in the folder runs with host, port, user and database as arguments")
  func runsWithConnectionArguments() async throws {
    let config = await Self.config()
    try await Self.withFolder(["ok.sh"]) { folder in
      let task = FakeTask()
      let made = Made()
      try await Self.runner(folder, task: task, made: made).runPreConnect(
        "ok.sh", for: config)

      #expect(made.all.map(\.lastPathComponent) == ["ok.sh"])
      #expect(task.arguments == ["db.example.com", "6543", "ada", "sales"])
    }
  }

  @Test("A script that never finishes is abandoned at the timeout, and the error says so")
  func timeoutAbandonsTheScript() async throws {
    let config = await Self.config()
    try await Self.withFolder(["slow.sh"]) { folder in
      let runner = Self.runner(folder, task: FakeTask(completes: false))
      let start = ContinuousClock.now

      let error = await #expect(throws: ConnectionScriptRunner.ScriptError.self) {
        try await runner.runPreConnect("slow.sh", for: config)
      }
      #expect(error == .timedOut(.preConnect, name: "slow.sh", seconds: 1))
      #expect(error?.localizedDescription.contains("may still be running") == true)
      #expect(ContinuousClock.now - start < .seconds(5))
    }
  }

  @Test("A run cancelled before it starts never makes or runs a task")
  func cancelledBeforeStartNeverRuns() async throws {
    let config = await Self.config()
    try await Self.withFolder(["ok.sh"]) { folder in
      let task = FakeTask(stdout: "secret\n")
      let made = Made()
      let runner = Self.runner(folder, task: task, made: made)

      let preConnect = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await runner.runPreConnect("ok.sh", for: config)
      }
      await #expect(throws: CancellationError.self) { try await preConnect.value }
      let password = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await runner.password(from: "ok.sh", for: config)
      }
      await #expect(throws: CancellationError.self) { try await password.value }
      #expect(made.all.isEmpty)
      #expect(task.arguments == nil)
    }
  }

  @Test("A script whose background child keeps its output open finishes once it exits")
  func backgroundChildDoesNotHoldTheRun() async throws {
    // A long timeout: under a loaded test run the 300 ms grace must not race a short one
    let config = await Self.config(timeout: 30)
    try await Self.withFolder(["tunnel.sh"]) { folder in
      let task = FakeTask(stdout: "started\n", backgroundChild: true)
      defer { task.endBackgroundChild() }

      // Succeeds: if the run waited for the child's end of the pipe, the timeout would fail it
      try await Self.runner(folder, task: task).runPreConnect("tunnel.sh", for: config)
    }
  }

  @Test(
    "A host, user or database that could pass for an option is never passed to a script",
    arguments: [
      ("-oProxyCommand=evil", "ada", "sales"),
      ("db.example.com", "--help", "sales"),
      ("db.example.com", "ada", "sales\nrm"),
      ("db.example.com\u{202E}", "ada", "sales"),
    ])
  func refusesOptionLikeArguments(host: String, user: String, database: String) async throws {
    let config = await Self.config(host: host, user: user, database: database)
    try await Self.withFolder(["ok.sh"]) { folder in
      let made = Made()

      await #expect(
        throws: ConnectionScriptRunner.ScriptError.unsafeArguments(.preConnect, name: "ok.sh")
      ) {
        try await Self.runner(folder, task: FakeTask(), made: made).runPreConnect(
          "ok.sh", for: config)
      }
      #expect(made.all.isEmpty)
    }
  }

  @Test("Script output never reaches the log or an error; only a pre-connect failure shows stderr")
  @MainActor func outputNeverLogged() async throws {
    let config = await Self.config()
    try await Self.withFolder(["pw.sh", "fail.sh"]) { folder in
      // More than the 64 KiB cap: the rest is drained, so the script does not block
      let filler = String(repeating: "x", count: 200 * 1024)
      let password = try await Self.runner(
        folder, task: FakeTask(stdout: "  PLANTED-pw-1  \r\nPLANTED-line-2\n\(filler)")
      ).password(from: "pw.sh", for: config)
      #expect(password == "PLANTED-pw-1")

      let preConnect = await #expect(throws: ConnectionScriptRunner.ScriptError.self) {
        try await Self.runner(
          folder,
          task: FakeTask(
            stdout: "PLANTED-out", stderr: "VPN down\u{202E}", error: Self.exitError(3))
        ).runPreConnect("fail.sh", for: config)
      }
      let shown = try #require(preConnect?.localizedDescription)
      #expect(shown == "Pre-connect script \"fail.sh\" failed (exit status 3).\nVPN down")

      let command = await #expect(throws: ConnectionScriptRunner.ScriptError.self) {
        try await Self.runner(
          folder,
          task: FakeTask(stdout: "PLANTED-pw-2", stderr: "PLANTED-err", error: Self.exitError(1))
        ).password(from: "pw.sh", for: config)
      }
      await #expect(throws: ConnectionScriptRunner.ScriptError.emptyPassword(name: "pw.sh")) {
        try await Self.runner(folder, task: FakeTask(stdout: " \nPLANTED-pw-3")).password(
          from: "pw.sh", for: config)
      }

      let texts = [preConnect, command].compactMap { $0 }.flatMap {
        [$0.localizedDescription, String(describing: $0), String(reflecting: $0)]
      }
      let logs = await AppLogger.shared.getAllLogs().map(\.message)
      #expect(logs.contains { $0.contains("pw.sh") }, "the run itself is logged")
      for text in texts + logs {
        #expect(!text.contains("PLANTED"), "output leaked: \(text)")
      }
      #expect(!String(describing: preConnect).contains("VPN down"))
    }
  }
}
