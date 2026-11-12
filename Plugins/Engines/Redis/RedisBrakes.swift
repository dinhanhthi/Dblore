// RedisBrakes.swift
// The session brakes of a Redis connection, without a socket: what the `settings` request
// applies, the failure a command stopped by the statement timeout answers, and the commands of
// the short-lived second connection that asks a busy server to stop its script.
//
// - The statement timeout is the only brake Redis has: a per-command deadline on the reply's
//   first node, kept by the plugin (Redis has no server-side command timeout). Passing it takes
//   the interrupt path (the drain of RedisConnection.swift). 0 turns it off.
// - A lock or idle timeout has no Redis counterpart: once the statement timeout is applied, a
//   non-zero one is answered `unsupported` (the app logs it and opens anyway).
// - The kill connection sends only its authentication (`HELLO 3 AUTH …` after a RESP3 open,
//   RESP2 `AUTH` after a RESP2 one, nothing without a user or a password), then `SCRIPT KILL`,
//   then `FUNCTION KILL`. Never `SELECT` or `INFO`: a server busy with a script answers `BUSY`
//   to every command but a few, these among them.

import Foundation

enum RedisBrakes {
  /// How long the kill connection may take in all: longer than Redis's default 5 s
  /// `busy-reply-threshold`, before which a busy server reads no other client
  static let killSeconds: TimeInterval = 6

  /// What a `settings` request applies: the statement timeout to keep (0 for none), and the
  /// failure to answer once it is kept, when a brake Redis lacks is asked for
  typealias Applied = (statementTimeoutSeconds: Int, refusal: EngineFailure?)

  static func apply(_ settings: EngineRequest.Settings) -> Applied {
    let seconds = max(0, settings.statementTimeoutSeconds)
    guard settings.lockTimeoutSeconds > 0 || settings.idleTimeoutSeconds > 0 else {
      return (seconds, nil)
    }
    return (
      seconds,
      EngineFailure(
        code: .unsupported,
        message: "Redis has no lock or idle timeout; only the statement timeout applies.")
    )
  }

  /// A command stopped by the statement timeout
  static func timeoutFailure(seconds: Int) -> EngineFailure {
    EngineFailure(
      code: .query, message: "The command was stopped by the \(seconds) s statement timeout.")
  }

  /// The commands of the kill connection, in order: the authentication of the open (in the
  /// open's protocol), then `SCRIPT KILL` and `FUNCTION KILL`
  static func killCommands(
    username: String, password: String, protocolVersion: Int
  )
    -> [[String]]
  {
    var commands: [[String]] = []
    if !username.isEmpty || !password.isEmpty {
      if protocolVersion >= 3 {
        commands.append(RedisHandshake.hello(username: username, password: password))
      } else if let auth = RedisHandshake.auth(username: username, password: password) {
        commands.append(auth)
      }
    }
    commands.append(["SCRIPT", "KILL"])
    commands.append(["FUNCTION", "KILL"])
    return commands
  }
}
