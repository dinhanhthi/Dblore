// ConnectionManagerScriptTests.swift
// The connection's scripts around a connect: a failing pre-connect script opens no session, the
// password command's password reaches the live connection only, and the post-disconnect script
// runs once per real close (never on an internal reset that succeeds).

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Connection scripts on connect and disconnect")
struct ConnectionManagerScriptTests {

  /// Names of the scripts started, in order.
  private nonisolated final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
  }

  /// `pw.sh` prints the password, `fail.sh` exits with status 1, any other script succeeds.
  private nonisolated final class Script: ConnectionScriptTask, @unchecked Sendable {
    var standardOutput: FileHandle?
    var standardError: FileHandle?
    let name: String
    let started: Started

    init(name: String, started: Started) {
      self.name = name
      self.started = started
    }

    func execute(
      withArguments arguments: [String]?,
      completionHandler handler: NSUserUnixTask.CompletionHandler?
    ) {
      started.append(name)
      let (out, name) = (standardOutput, name)
      DispatchQueue.global().async {
        if name == "pw.sh" { try? out?.write(contentsOf: Data("from-command\n".utf8)) }
        handler?(
          name == "fail.sh"
            ? NSError(
              domain: NSPOSIXErrorDomain, code: 1,
              userInfo: [NSLocalizedFailureReasonErrorKey: "Script task exited with status 1"])
            : nil)
      }
    }
  }

  /// Opens one session, then fails every later open (a failed internal reset).
  private nonisolated final class FailsAfterFirstOpen: DatabaseSessionFactory,
    @unchecked Sendable
  {
    let working = FakeDatabaseSessionFactory(capabilities: .contract())
    let failing = FakeDatabaseSessionFactory(
      capabilities: .contract(), openError: FakeQueryError())
    private let lock = NSLock()
    private var opened = false

    func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
      let first = lock.withLock {
        defer { opened = true }
        return !opened
      }
      return first ? working.makeSession(config: config) : failing.makeSession(config: config)
    }
  }

  private let folder: URL
  private let started = Started()

  init() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["up.sh", "pw.sh", "fail.sh", "down.sh"] {
      try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent(name))
    }
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func manager(
    _ factory: any DatabaseSessionFactory = FakeDatabaseSessionFactory(capabilities: .contract())
  ) -> DatabaseConnectionManager {
    let (folder, started) = (folder, started)
    return DatabaseConnectionManager(
      sessionFactory: factory,
      scripts: ConnectionScriptRunner(
        scriptsFolder: { folder },
        makeTask: { Script(name: $0.lastPathComponent, started: started) }))
  }

  private static func config(
    pre: String? = nil, password: String? = nil, post: String? = nil
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "keychain-pw", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    config.preConnectScript = pre
    config.passwordCommandScript = password
    config.postDisconnectScript = post
    config.scriptTimeoutSeconds = 5
    return config
  }

  @Test("A failing pre-connect script opens no session; a connect failing after one runs post")
  func preConnectFailureAborts() async throws {
    defer { cleanUp() }
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let connection = manager(factory)

    await #expect(throws: ConnectionScriptRunner.ScriptError.self) {
      try await connection.connectRunningScripts(
        config: Self.config(pre: "fail.sh", post: "down.sh"))
    }
    #expect(factory.sessions.isEmpty)
    #expect(started.all == ["fail.sh"], "no pre-connect ran, so nothing to undo")

    // The pre-connect script ran (a tunnel is up), then the database refused: undo it
    let refusing = manager(
      FakeDatabaseSessionFactory(capabilities: .contract(), openError: FakeQueryError()))
    await #expect(throws: FakeQueryError.self) {
      try await refusing.connectRunningScripts(config: Self.config(pre: "up.sh", post: "down.sh"))
    }
    #expect(started.all == ["fail.sh", "up.sh", "down.sh"])
    #expect(!refusing.hasPendingPostDisconnect)
  }

  @Test("The password command's password reaches the live connection only, never the workspace")
  func passwordCommandStaysInTheConnection() async throws {
    defer { cleanUp() }
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: nil), restoreTabs: false,
      connectionManager: manager())
    let config = Self.config(pre: "up.sh", password: "pw.sh")

    try await workspace.connectWithoutUnlockCheck(config: config, savesConnection: false)
    workspace.cancelSchemaLoad()

    #expect(started.all == ["up.sh", "pw.sh"])
    #expect(await workspace.connectionManager.config?.password == "from-command")
    // What a save writes and the form shows: the Keychain password, never the command's
    #expect(workspace.workspace.connectionConfig?.password == "keychain-pw")
    #expect(workspace.editingConnectionConfig.password == "keychain-pw")
    await workspace.connectionManager.disconnect()
  }

  @Test("The post-disconnect script starts once, by the time disconnect returns")
  func postDisconnectRunsOnce() async throws {
    defer { cleanUp() }
    let connection = manager()
    try await connection.connectRunningScripts(config: Self.config(post: "down.sh"))
    #expect(started.all.isEmpty)
    #expect(connection.hasPendingPostDisconnect)

    await connection.disconnect()
    #expect(started.all == ["down.sh"])
    await connection.disconnect()
    #expect(started.all == ["down.sh"])
  }

  @Test("An internal reset keeps the post-disconnect script; a failed one runs it")
  func resetKeepsPostDisconnect() async throws {
    defer { cleanUp() }
    let connection = manager()
    try await connection.connectRunningScripts(config: Self.config(post: "down.sh"))
    let live = try #require(await connection.config)
    try await connection.reconnectWithActiveCertificate(config: live, material: nil)
    #expect(started.all.isEmpty)
    await connection.disconnect()
    #expect(started.all == ["down.sh"])

    let failing = manager(FailsAfterFirstOpen())
    try await failing.connectRunningScripts(config: Self.config(post: "down.sh"))
    let failingLive = try #require(await failing.config)
    await #expect(throws: FakeQueryError.self) {
      try await failing.reconnectWithActiveCertificate(config: failingLive, material: nil)
    }
    #expect(started.all == ["down.sh", "down.sh"])
    await failing.disconnect()
    #expect(started.all == ["down.sh", "down.sh"])
  }
}
