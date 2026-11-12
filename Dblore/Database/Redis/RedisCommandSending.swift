// RedisCommandSending.swift
// The send seam of the Redis gate: one `RedisCommand` goes to the session as its exact argument
// bytes. Not part of the engine-neutral `DatabaseSession`; only
// `DatabaseConnectionManager.executeGatedRedisCommand` casts a session to it (a source scan in
// `RedisGateTests` keeps it that way). The Redis session and the test fake conform.

import Foundation

nonisolated protocol RedisCommandSending: AnyObject, Sendable {
  /// Sends `command.args` as is in database `command.db` and returns the reply as rows
  /// `[path, type, value]`, one per RESP node, depth first (`RedisReply(rows:maxNodes:)`
  /// rebuilds the tree). Never called outside the gate.
  func send(_ command: RedisCommand) async throws -> SessionRowSource
}
