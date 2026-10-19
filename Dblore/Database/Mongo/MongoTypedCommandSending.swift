// MongoTypedCommandSending.swift
// The typed send seam of the MongoDB write gate: a `MongoCommand` built by the app (restore,
// import, admin forms) goes to the session as is, never rendered to mongosh text and parsed
// again. Not part of the engine-neutral `DatabaseSession`; the manager casts the session to it.
// `MongoSession` and the test fake conform.

import Foundation

/// The server's write limits from `hello`: the largest document (`maxBsonObjectSize`), the
/// largest wire message (`maxMessageSizeBytes`) and the most statements in one write command
/// (`maxWriteBatchSize`).
nonisolated struct MongoWriteLimits: Equatable, Sendable {
  var maxBsonObjectSize: Int
  var maxMessageSizeBytes: Int
  var maxWriteBatchSize: Int

  /// The defaults of every supported server, used when `hello` cannot be read.
  static let fallback = MongoWriteLimits(
    maxBsonObjectSize: 16 * 1_048_576, maxMessageSizeBytes: 48_000_000,
    maxWriteBatchSize: 100_000)
}

nonisolated protocol MongoTypedCommandSending: AnyObject, Sendable {
  /// Runs one write, `$out`/`$merge` aggregate or admin command and returns its tag. Read
  /// commands are refused before anything is sent.
  func command(_ command: MongoCommand) async throws -> CommandResult

  /// The server's write limits, read once per session; `.fallback` when they cannot be read.
  func writeLimits() async -> MongoWriteLimits
}
