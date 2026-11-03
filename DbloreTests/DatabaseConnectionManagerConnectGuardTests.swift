// DatabaseConnectionManagerConnectGuardTests.swift
// An ask-on-connect connection is never opened with an empty password: connect and Test refuse
// it before any login attempt. The typed password lives in the connected config, so side
// managers and side paths that copy it reuse it. No server: fake sessions record the password a
// real session would send, and a Test that got past the guard would only reach a closed port.

import Foundation
import Testing

@testable import Dblore

@Suite("Ask on connect: connect guard")
@MainActor
struct DatabaseConnectionManagerConnectGuardTests {
  /// Nothing listens on port 9 here: a probe that got past the guard fails fast, logs in nowhere
  private static func askConfig(password: String = "") -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "127.0.0.1", port: 9, database: "app", username: "ada", password: password,
      timeoutSeconds: 1)
    config.askPasswordOnConnect = true
    return config
  }

  private static func isPasswordRequired(_ error: any Error) -> Bool {
    if case .passwordRequiredOnConnect = error as? DatabaseError { return true }
    return false
  }

  @Test("Connect and Test without the typed password throw and never attempt a login")
  func emptyPasswordIsRefused() async throws {
    let factory = PasswordRecordingFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory, lockSource: LockRegistry())

    await #expect {
      try await manager.connect(config: Self.askConfig())
    } throws: {
      Self.isPasswordRequired($0)
    }
    #expect(factory.passwords.isEmpty)
    #expect(await !manager.isConnected)

    await #expect {
      _ = try await manager.testConnection(config: Self.askConfig())
    } throws: {
      Self.isPasswordRequired($0)
    }

    // A refused connect leaves the live connection alone
    try await manager.connect(config: Self.askConfig(password: "typed"))
    await #expect {
      try await manager.connect(config: Self.askConfig())
    } throws: {
      Self.isPasswordRequired($0)
    }
    #expect(await manager.isConnected)
    #expect(factory.passwords == ["typed"])

    // A stale flag on a file engine blocks nothing: it has no password to ask for
    var file = ConnectionConfig(
      databaseType: .sqlite,
      database: FileManager.default.temporaryDirectory
        .appendingPathComponent("ask-\(UUID().uuidString).sqlite").path)
    file.askPasswordOnConnect = true
    do { try await manager.connect(config: file) } catch {
      #expect(!Self.isPasswordRequired(error))
    }
    await manager.disconnect()
  }

  @Test("A refused scripted connect runs no script and keeps the live connection")
  func refusedScriptedConnectRunsNothing() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-ask-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["up.sh", "down.sh"] {
      try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent(name))
    }
    let started = StartedScripts()
    let factory = PasswordRecordingFactory()
    let manager = DatabaseConnectionManager(
      sessionFactory: factory,
      scripts: ConnectionScriptRunner(
        scriptsFolder: { folder },
        makeTask: { RecordingScript(name: $0.lastPathComponent, started: started) }),
      lockSource: LockRegistry())
    try await manager.connect(config: Self.askConfig(password: "typed"))

    var scripted = Self.askConfig()
    scripted.preConnectScript = "up.sh"
    scripted.postDisconnectScript = "down.sh"
    scripted.scriptTimeoutSeconds = 5
    await #expect {
      try await manager.connectRunningScripts(config: scripted)
    } throws: {
      Self.isPasswordRequired($0)
    }
    #expect(started.all.isEmpty)
    #expect(!manager.hasPendingPostDisconnect)
    #expect(await manager.isConnected)
    #expect(factory.passwords == ["typed"])
    await manager.disconnect()
  }

  @Test("The typed password reaches a side manager and a side path that copies the config")
  func typedPasswordReachesSidePaths() async throws {
    let factory = PasswordRecordingFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory, lockSource: LockRegistry())
    try await manager.connect(config: Self.askConfig(password: "typed"))

    let sideFactory = PasswordRecordingFactory()
    let side = DatabaseConnectionManager(sessionFactory: sideFactory, lockSource: LockRegistry())
    try await manager.connectSideManager(side)
    #expect(sideFactory.passwords == ["typed"])
    await side.disconnect()

    // As the AI read session and the SQL dump do: a copy of the connected config
    let copied = try #require(await manager.config)
    let copyFactory = PasswordRecordingFactory()
    let copy = DatabaseConnectionManager(sessionFactory: copyFactory, lockSource: LockRegistry())
    try await copy.reconnectWithActiveCertificate(config: copied, material: nil)
    #expect(copyFactory.passwords == ["typed"])
    await copy.disconnect()
    await manager.disconnect()
  }
}

/// Records the password of every session it makes.
private final class PasswordRecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  private let inner = FakeDatabaseSessionFactory(capabilities: .contract())
  private let lock = NSLock()
  private var recorded: [ConnectionConfig] = []

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    lock.withLock { recorded.append(config) }
    return inner.makeSession(config: config)
  }

  @MainActor var passwords: [String] { lock.withLock { recorded }.map(\.password) }
}

/// Names of the connection scripts started, in order
private nonisolated final class StartedScripts: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  func append(_ name: String) { lock.withLock { names.append(name) } }
  var all: [String] { lock.withLock { names } }
}

/// Records its start and succeeds
private nonisolated final class RecordingScript: ConnectionScriptTask, @unchecked Sendable {
  var standardOutput: FileHandle?
  var standardError: FileHandle?
  let name: String
  let started: StartedScripts

  init(name: String, started: StartedScripts) {
    self.name = name
    self.started = started
  }

  func execute(
    withArguments arguments: [String]?, completionHandler handler: NSUserUnixTask.CompletionHandler?
  ) {
    started.append(name)
    DispatchQueue.global().async { handler?(nil) }
  }
}
