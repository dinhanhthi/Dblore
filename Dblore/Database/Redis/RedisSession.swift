// RedisSession.swift
// A Redis connection: the Redis plugin's `EnginePluginSession`, which speaks commands only.
// - `open` loads the plugin and checks its `hello` before the `open` request (the only one with
//   the password): a plugin that is not `redis` or lacks the `argv` feature is refused.
// - Commands go through `RedisCommandSending.send` as their exact argument bytes, in the
//   command's db (`EnginePluginSession.sendArgv`); only the gate and the Test Connection probe
//   send. The SQL text entry points (`query`, `command`, cursors) throw and send nothing.
// - Everything else the manager relies on (brakes, close events, cancel, close, error text with
//   the password replaced, server version, capabilities) is the plugin session's own.

import Foundation

nonisolated final class RedisSession: DatabaseSession, RedisCommandSending {
  private let plugin: EnginePluginSession

  init(pluginID: String, config: ConnectionConfig, hostKeyValidator: any SSHHostKeyValidating) {
    plugin = EnginePluginSession(
      pluginID: pluginID, config: config, hostKeyValidator: hostKeyValidator)
  }

  var capabilities: DatabaseCapabilities { plugin.capabilities }

  var closeEvents: AsyncStream<SessionCloseReason> { plugin.closeEvents }

  /// The plugin's `opened.serverVersion`; nil before a successful open
  var serverVersion: String? { plugin.serverVersion }

  // MARK: - Open / close

  /// Refuses a plugin whose `hello` is not `redis` with the `argv` feature before anything is
  /// sent to it, then opens the plugin session.
  /// - Throws: `DatabaseError.connectionFailed` asking to update the Redis plugin, or what
  ///   `EnginePluginSession.open` throws.
  func open() async throws {
    let hello = try await EnginePluginRuntime.runtime(for: plugin.pluginID).start()
    guard hello.engine == "redis" else {
      throw DatabaseError.connectionFailed(
        "The installed plugin is not a Redis plugin. Update the Redis plugin.")
    }
    guard hello.features.contains("argv") else {
      throw DatabaseError.connectionFailed(
        "This Redis plugin cannot send commands. Update the Redis plugin.")
    }
    try await plugin.open()
  }

  func close() async { await plugin.close() }

  // MARK: - Commands

  /// `command.args` as is, in database `command.db`, answered as reply rows
  /// `[path, type, value]`
  func send(_ command: RedisCommand) async throws -> SessionRowSource {
    try await plugin.sendArgv(command.args, db: command.db)
  }

  // MARK: - SQL text (refused: Redis runs only through the gate)

  private static let refusal = EnginePluginSessionError.unsupported("A SQL statement")

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    throw Self.refusal
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    throw Self.refusal
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw Self.refusal
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw Self.refusal
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    throw Self.refusal
  }

  func columnOrigins(ofViewBody body: String) async throws -> [ColumnOrigin?] {
    throw Self.refusal
  }

  // MARK: - Brakes, cancel, errors

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await plugin.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await plugin.interrupt() }

  func transactionOpenAfterInterrupt() async -> Bool? {
    await plugin.transactionOpenAfterInterrupt()
  }

  /// The plugin session's text, with the password replaced
  func formatError(_ error: Error) -> String { plugin.formatError(error) }
}
