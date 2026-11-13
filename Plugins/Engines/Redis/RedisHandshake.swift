// RedisHandshake.swift
// The open handshake of a Redis connection, without a socket: the commands it sends, how it
// reads their replies, and the texts of its failures. RedisConnection.swift runs it over the
// transport; the tests run it over scripted replies.
//
// 1. `HELLO 3`, with `AUTH <user> <password>` when a user or a password is set (the user
//    defaults to `default`). A user without a password still authenticates, with an empty
//    password: an ACL `nopass` user accepts any password, and a user with one answers
//    `WRONGPASS`, instead of the session silently running as `default`.
// 2. A server that does not know `HELLO` (`ERR unknown command`, also when it was renamed away)
//    or refuses protocol 3 (`NOPROTO`) gets RESP2 instead: `AUTH [user] password` when a user or
//    a password is set, then `INFO server` for its version.
// 3. A server older than 6.0 is refused. In RESP3 the version is the HELLO map's `version`;
//    in RESP2 it is `redis_version:` of `INFO server`, and a version that cannot be read there is
//    refused too (nothing else proves 6.0).
// 4. `SELECT <home database>` when it is not 0.

import Foundation

enum RedisHandshake {
  /// The oldest server opened: `HELLO`, ACL users, `KEEPTTL`, `SCAN ... TYPE`
  static let minimumVersion = (major: 6, minor: 0)

  /// What the handshake learned
  struct Outcome: Equatable {
    /// 3 after `HELLO 3`, 2 after the RESP2 fallback
    let protocolVersion: Int
    /// The server's version as it reports it, nil when unknown
    let version: String?
  }

  /// Runs the handshake. `send` writes one command and returns its whole reply as nodes; a
  /// server error reply throws as an `EngineFailure` with its `serverCode`.
  static func run(
    username: String, password: String, database home: Int,
    send: ([String]) throws -> [RESPNode]
  ) throws -> Outcome {
    let outcome: Outcome
    do {
      let reply = try send(hello(username: username, password: password))
      let version = helloVersion(reply)
      try checkVersion(version, required: false)
      outcome = Outcome(protocolVersion: 3, version: version)
    } catch let failure as EngineFailure where fallsBack(failure) {
      outcome = try resp2(username: username, password: password, send: send)
    }
    if home != 0 {
      _ = try send(["SELECT", String(home)])
    }
    return outcome
  }

  /// The RESP2 path: `AUTH` when needed, then the version from `INFO server`
  private static func resp2(
    username: String, password: String, send: ([String]) throws -> [RESPNode]
  ) throws -> Outcome {
    if let auth = auth(username: username, password: password) {
      do {
        _ = try send(auth)
      } catch let failure as EngineFailure
        where auth.count == 3 && failure.message.lowercased().contains("wrong number of arguments")
      {
        // A server before 6.0 knows `AUTH <password>` only
        throw versionRefusal("this server does not know ACL users (AUTH with a user name)")
      }
    }
    let info: [RESPNode]
    do {
      info = try send(["INFO", "server"])
    } catch let failure as EngineFailure where isUnknownCommand(failure) {
      throw versionRefusal("this server's version could not be read")
    }
    let version = info.first?.text.flatMap(infoVersion)
    try checkVersion(version, required: true)
    return Outcome(protocolVersion: 2, version: version)
  }

  // MARK: Commands

  /// `HELLO 3`, with `AUTH` when a user or a password is set
  static func hello(username: String, password: String) -> [String] {
    guard !username.isEmpty || !password.isEmpty else { return ["HELLO", "3"] }
    return ["HELLO", "3", "AUTH", username.isEmpty ? "default" : username, password]
  }

  /// RESP2 `AUTH`: `AUTH <password>` for the default user, `AUTH <user> <password>` for a named
  /// one (also with an empty password); nil when neither is set
  static func auth(username: String, password: String) -> [String]? {
    if !username.isEmpty { return ["AUTH", username, password] }
    return password.isEmpty ? nil : ["AUTH", password]
  }

  // MARK: Replies

  /// Whether a `HELLO` error means the server takes RESP2 only: it does not know `HELLO` (or
  /// it was renamed away), or it refuses protocol 3
  static func fallsBack(_ failure: EngineFailure) -> Bool {
    failure.serverCode == "NOPROTO" || isUnknownCommand(failure)
  }

  private static func isUnknownCommand(_ failure: EngineFailure) -> Bool {
    failure.serverCode == "ERR" && failure.message.lowercased().contains("unknown command")
  }

  /// The `version` of a `HELLO` reply: a map (RESP3) or a flat array of key, value (RESP2)
  static func helloVersion(_ nodes: [RESPNode]) -> String? {
    // The reply's direct children alternate key and value
    let pairs = nodes.filter { $0.path.split(separator: ".").count == 2 }
    var index = 0
    while index + 1 < pairs.count {
      if pairs[index].text == "version" { return pairs[index + 1].text }
      index += 2
    }
    return nil
  }

  /// `redis_version:` of an `INFO server` text
  static func infoVersion(_ text: String) -> String? {
    let prefix = "redis_version:"
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
      let version = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      return version.isEmpty ? nil : version
    }
    return nil
  }

  /// The major and minor numbers of a version ("7.4.0-rc1" → 7, 4), nil when it does not start
  /// with a number
  static func majorMinor(_ version: String) -> (major: Int, minor: Int)? {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    func leadingNumber(_ part: Substring) -> Int? { Int(part.prefix(while: \.isNumber)) }
    guard let first = parts.first, let major = leadingNumber(first) else { return nil }
    let minor = parts.count > 1 ? leadingNumber(parts[1]) ?? 0 : 0
    return (major, minor)
  }

  /// Throws when `version` is older than 6.0, or (when `required`) cannot be read
  static func checkVersion(_ version: String?, required: Bool) throws {
    guard let version, let number = majorMinor(version) else {
      if required { throw versionRefusal("this server's version could not be read") }
      return
    }
    if (number.major, number.minor) < minimumVersion {
      throw versionRefusal("this server is \(version)")
    }
  }

  private static func versionRefusal(_ detail: String) -> EngineFailure {
    EngineFailure(code: .connect, message: "Dblore needs Redis 6.0 or later; \(detail).")
  }

  /// `serverVersion` of an open connection: "Redis x.y.z", plus " (TLS)" over TLS
  static func serverVersion(_ version: String?, usesTLS: Bool) -> String {
    "Redis" + (version.map { " \($0)" } ?? "") + (usesTLS ? " (TLS)" : "")
  }

  // MARK: Failures

  /// `failure` without the password. A server text (one with a `serverCode`) that holds it has
  /// it masked when it is 4 characters or more; a shorter one would mask unrelated letters, so
  /// the server text is dropped instead. Dblore's own texts never hold it.
  static func redact(_ failure: EngineFailure, password: String) -> EngineFailure {
    guard !password.isEmpty, failure.message.contains(password) else { return failure }
    let message: String
    if password.count >= 4 {
      message = failure.message.replacingOccurrences(of: password, with: "••••")
    } else if let code = failure.serverCode {
      message = "The server refused the connection (\(code))."
    } else {
      return failure
    }
    return EngineFailure(code: failure.code, message: message, serverCode: failure.serverCode)
  }
}

extension RESPProtocolError {
  /// The user's text: the cap that was passed, else the generic text of
  /// `RedisTransportError.malformed`
  var failure: EngineFailure {
    EngineFailure(code: .query, message: message ?? "The server's reply could not be read.")
  }
}
