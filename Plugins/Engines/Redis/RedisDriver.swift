// RedisDriver.swift
// The Redis engine of the plugin, over RESP3 on a raw TCP socket (see RedisTransport.swift for
// TLS and the plain-host policy, RESP.swift for the reply rows, RedisConnection.swift for
// requests and cancel).
//
// Open: dial, `HELLO 3` (with `AUTH <user> <password>` when a password is set; the user defaults
// to `default`), then `SELECT <database>` when the home database is not 0, all within the open's
// timeout. `opened.serverVersion` is "Redis x.y.z", plus " (TLS)" over TLS. Only the `argv`
// request runs commands (`hello.features` = ["argv"]).
//
// The host and the outcome are logged (os_log, subsystem ace.thi.Dblore.Redis); never the
// password or a command's arguments, and server texts only as private.

import Foundation
import os

/// This bundle's engine
let engineDriver: any EngineDriver = RedisDriver()

private let log = Logger(subsystem: "ace.thi.Dblore.Redis", category: "Driver")

struct RedisDriver: EngineDriver {
  var engine: String { "redis" }
  var queryLanguage: String { "redis" }
  var libraries: [String: String] { [:] }
  var features: [String] { ["argv"] }

  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection {
    let endpoint = try RedisEndpoint(open)
    let database = try Self.homeDatabase(open.database)
    let timeoutSeconds = open.timeoutSeconds > 0 ? min(open.timeoutSeconds, 3_600) : 10
    let deadline = Date(timeIntervalSinceNow: TimeInterval(timeoutSeconds))
    let connection = RedisConnection(
      transport: RedisTransport(endpoint: endpoint, connectTimeoutSeconds: timeoutSeconds),
      usesTLS: endpoint.usesTLS)
    do {
      try connection.open(
        username: open.username, password: open.password, database: database, deadline: deadline)
    } catch {
      connection.close()
      let failure = Self.openFailure(error, password: open.password)
      let message = failure.message
      log.error("\(endpoint.host, privacy: .public): open failed: \(message, privacy: .private)")
      throw failure
    }
    log.notice(
      "\(endpoint.host, privacy: .public): connected, \(connection.serverVersion, privacy: .public)"
    )
    return connection
  }

  /// The open's database field as a Redis database index; empty is 0
  static func homeDatabase(_ text: String) throws -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    guard let index = Int(trimmed), index >= 0 else {
      throw EngineFailure(
        code: .connect, message: "The database must be a Redis database number (0, 1, 2, ...).")
    }
    return index
  }

  /// An open failure as a `connect` error whose message holds neither the password nor the
  /// arguments a server error may echo
  static func openFailure(_ error: any Error, password: String) -> EngineFailure {
    var failure = EngineFailure.from(error, code: .connect)
    var message = failure.message
    if failure.serverCode == "ERR", message.lowercased().contains("unknown command") {
      message = "The server does not know HELLO: Dblore needs Redis 6.0 or later."
    } else if failure.serverCode == "NOPROTO" {
      message = "The server does not speak RESP3 (HELLO 3): Dblore needs Redis 6.0 or later."
    } else if failure.serverCode == "NOAUTH", password.isEmpty {
      message = "The server needs a password."
    } else if (error as? EngineFailure)?.message
      == RedisTransportError.closedByServer.failure.message
    {
      message = "The server closed the connection during the handshake (does it need TLS?)."
    }
    if !password.isEmpty {
      message = message.replacingOccurrences(of: password, with: "••••")
    }
    failure = EngineFailure(code: .connect, message: message, serverCode: failure.serverCode)
    return failure
  }
}
