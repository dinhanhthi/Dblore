// RedisHandshakeTests.swift
// The Redis open handshake without a server: the commands it sends and how it reads scripted
// replies (RESP3, the RESP2 fallback, the 6.0 floor, a user without a password), password
// masking in open errors, and the text of a reply that breaks a decoder cap.

import Foundation
import Testing

// MARK: - Scripted server

/// A reply's whole bytes, read token by token
nonisolated private final class WireSource: RESPSource {
  private let data: [UInt8]
  private var offset = 0

  init(_ text: String) { data = Array(text.utf8) }

  func line() throws -> Data {
    var index = offset
    while index + 1 < data.count {
      if data[index] == 0x0D, data[index + 1] == 0x0A {
        defer { offset = index + 2 }
        return Data(data[offset..<index])
      }
      index += 1
    }
    throw RESPProtocolError()
  }

  func bytes(_ count: Int) throws -> Data {
    guard offset + count <= data.count else { throw RESPProtocolError() }
    defer { offset += count }
    return Data(data[offset..<offset + count])
  }

  func skip(_ count: inout Int) throws {
    let dropped = min(count, data.count - offset)
    offset += dropped
    count -= dropped
  }
}

/// A server that answers each command with the next scripted reply: wire bytes, or a server
/// error as the connection throws it
nonisolated private final class ScriptedServer {
  enum Reply {
    case wire(String)
    case error(String)
  }

  private var replies: [Reply]
  private(set) var commands: [[String]] = []

  init(_ replies: [Reply]) { self.replies = replies }

  func send(_ args: [String]) throws -> [RESPNode] {
    commands.append(args)
    guard !replies.isEmpty else { throw RESPProtocolError() }
    switch replies.removeFirst() {
    case .wire(let text):
      let source = WireSource(text)
      let reply = RESPReply()
      var nodes: [RESPNode] = []
      while let node = try reply.next(from: source) { nodes.append(node) }
      return nodes
    case .error(let text):
      throw EngineFailure(
        code: .query, message: text,
        serverCode: text.split(separator: " ", maxSplits: 1).first.map(String.init))
    }
  }
}

/// A RESP3 `HELLO` reply of a server at `version`
private func helloMap(_ version: String) -> String {
  "%3\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$\(version.utf8.count)\r\n\(version)\r\n"
    + "$5\r\nproto\r\n:3\r\n"
}

/// An `INFO server` reply (a RESP2 bulk string) of a server at `version`
private func infoServer(_ version: String) -> String {
  let text = "# Server\r\nredis_version:\(version)\r\nredis_mode:standalone\r\n"
  return "$\(text.utf8.count)\r\n\(text)\r\n"
}

private let unknownHello = "ERR unknown command 'HELLO'"

/// The `EngineFailure` `body` throws, nil when it throws none
private func failure(_ body: () throws -> Void) -> EngineFailure? {
  do {
    try body()
    return nil
  } catch {
    return error as? EngineFailure
  }
}

private func run(
  _ server: ScriptedServer, username: String = "", password: String = "", database: Int = 0
) throws -> RedisHandshake.Outcome {
  try RedisHandshake.run(username: username, password: password, database: database) {
    try server.send($0)
  }
}

// MARK: - Tests

@Suite struct RedisHandshakeTests {
  @Test func helloAuthenticatesWhenAUserOrAPasswordIsSet() {
    #expect(RedisHandshake.hello(username: "", password: "") == ["HELLO", "3"])
    #expect(
      RedisHandshake.hello(username: "", password: "secret")
        == ["HELLO", "3", "AUTH", "default", "secret"])
    #expect(
      RedisHandshake.hello(username: "app", password: "secret")
        == ["HELLO", "3", "AUTH", "app", "secret"])
    // A user without a password: authenticated as that user (an ACL `nopass` user accepts any
    // password), never left on `default`
    #expect(
      RedisHandshake.hello(username: "app", password: "") == ["HELLO", "3", "AUTH", "app", ""])
  }

  @Test func resp2AuthNamesTheUserOnlyWhenOneIsSet() {
    #expect(RedisHandshake.auth(username: "", password: "") == nil)
    #expect(RedisHandshake.auth(username: "", password: "secret") == ["AUTH", "secret"])
    #expect(RedisHandshake.auth(username: "app", password: "secret") == ["AUTH", "app", "secret"])
    #expect(RedisHandshake.auth(username: "app", password: "") == ["AUTH", "app", ""])
  }

  @Test func resp3OpenReadsTheVersionThenSelectsTheHomeDatabase() throws {
    let server = ScriptedServer([.wire(helloMap("7.2.4")), .wire("+OK\r\n")])
    let outcome = try run(server, username: "app", password: "secret", database: 3)

    #expect(outcome == RedisHandshake.Outcome(protocolVersion: 3, version: "7.2.4"))
    #expect(
      server.commands == [["HELLO", "3", "AUTH", "app", "secret"], ["SELECT", "3"]])
    #expect(RedisHandshake.serverVersion("7.2.4", usesTLS: true) == "Redis 7.2.4 (TLS)")
    #expect(RedisHandshake.serverVersion("7.2.4", usesTLS: false) == "Redis 7.2.4")
  }

  @Test func homeDatabaseZeroSendsNoSelect() throws {
    let server = ScriptedServer([.wire(helloMap("6.0.0"))])
    _ = try run(server)
    #expect(server.commands == [["HELLO", "3"]])
  }

  @Test func helloVersionIsReadFromAFlatArrayToo() {
    let source = WireSource("*4\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$5\r\n6.2.1\r\n")
    let reply = RESPReply()
    var nodes: [RESPNode] = []
    while let node = try? reply.next(from: source) { nodes.append(node) }
    #expect(RedisHandshake.helloVersion(nodes) == "6.2.1")
  }

  @Test(arguments: [unknownHello, "NOPROTO unsupported protocol version"])
  func aServerWithoutHello3FallsBackToRESP2(helloError: String) throws {
    let server = ScriptedServer([
      .error(helloError), .wire("+OK\r\n"), .wire(infoServer("6.2.14")), .wire("+OK\r\n"),
    ])
    let outcome = try run(server, username: "app", password: "secret", database: 2)

    #expect(outcome == RedisHandshake.Outcome(protocolVersion: 2, version: "6.2.14"))
    #expect(
      server.commands == [
        ["HELLO", "3", "AUTH", "app", "secret"], ["AUTH", "app", "secret"], ["INFO", "server"],
        ["SELECT", "2"],
      ])
  }

  @Test func resp2WithoutCredentialsSendsNoAuth() throws {
    let server = ScriptedServer([.error(unknownHello), .wire(infoServer("7.0.0"))])
    #expect(try run(server).protocolVersion == 2)
    #expect(server.commands == [["HELLO", "3"], ["INFO", "server"]])
  }

  @Test func aServerOlderThan6IsRefused() {
    let server = ScriptedServer([
      .error(unknownHello), .wire("+OK\r\n"), .wire(infoServer("5.0.14")),
    ])
    let refused = failure { _ = try run(server, password: "secret", database: 1) }

    #expect(refused?.code == .connect)
    #expect(refused?.message == "Dblore needs Redis 6.0 or later; this server is 5.0.14.")
    // Refused before `SELECT`
    #expect(server.commands.last == ["INFO", "server"])
    #expect(server.commands[1] == ["AUTH", "secret"])
  }

  @Test func aHelloVersionOlderThan6IsRefused() {
    let server = ScriptedServer([.wire(helloMap("5.9.9"))])
    #expect(
      failure { _ = try run(server) }?.message
        == "Dblore needs Redis 6.0 or later; this server is 5.9.9.")
  }

  @Test func aServerWithoutACLUsersIsRefusedAsTooOld() {
    let server = ScriptedServer([
      .error(unknownHello), .error("ERR wrong number of arguments for 'auth' command"),
    ])
    let refused = failure { _ = try run(server, username: "app", password: "secret") }
    #expect(refused?.message.hasPrefix("Dblore needs Redis 6.0 or later;") == true)
    #expect(server.commands.count == 2)
  }

  @Test func aVersionThatCannotBeReadInRESP2IsRefused() {
    let renamed = ScriptedServer([.error(unknownHello), .error("ERR unknown command 'INFO'")])
    #expect(
      failure { _ = try run(renamed) }?.message
        == "Dblore needs Redis 6.0 or later; this server's version could not be read.")

    let unlabelled = ScriptedServer([.error(unknownHello), .wire("$8\r\n# Server\r\n")])
    #expect(failure { _ = try run(unlabelled) }?.code == .connect)
  }

  @Test func helloWithoutAVersionIsAccepted() throws {
    let server = ScriptedServer([.wire("%1\r\n+proto\r\n:3\r\n")])
    let outcome = try run(server)
    #expect(outcome == RedisHandshake.Outcome(protocolVersion: 3, version: nil))
    #expect(RedisHandshake.serverVersion(nil, usesTLS: false) == "Redis")
  }

  @Test(arguments: ["WRONGPASS invalid username-password pair", "NOAUTH Authentication required."])
  func anAuthFailureDoesNotFallBack(error: String) {
    let server = ScriptedServer([.error(error)])
    let refused = failure { _ = try run(server, username: "app") }
    #expect(refused?.message == error)
    #expect(server.commands == [["HELLO", "3", "AUTH", "app", ""]])
  }

  @Test func versionsCompareByMajorAndMinorNumbers() throws {
    let cases: [(String, Int, Int)] = [("10.0.0", 10, 0), ("7.4.0-rc1", 7, 4), ("5.0.14", 5, 0)]
    for (text, major, minor) in cases {
      let number = RedisHandshake.majorMinor(text)
      #expect(number?.major == major && number?.minor == minor)
    }
    #expect(RedisHandshake.majorMinor("unknown") == nil)
    try RedisHandshake.checkVersion("6.0.0", required: true)
    try RedisHandshake.checkVersion("10.0.0", required: true)
    try RedisHandshake.checkVersion(nil, required: false)
    #expect(failure { try RedisHandshake.checkVersion("5.0.14", required: false) } != nil)
    #expect(failure { try RedisHandshake.checkVersion(nil, required: true) } != nil)
  }

  @Test func aLongPasswordIsMaskedInAServerText() {
    let echoed = EngineFailure(
      code: .connect, message: "WRONGPASS bad password hunter2 here", serverCode: "WRONGPASS")
    let redacted = RedisHandshake.redact(echoed, password: "hunter2")
    #expect(redacted.message == "WRONGPASS bad password •••• here")
    #expect(redacted.serverCode == "WRONGPASS")
  }

  @Test func aShortPasswordDropsTheServerTextInsteadOfMaskingLetters() {
    let echoed = EngineFailure(
      code: .connect, message: "ERR invalid password", serverCode: "ERR")
    #expect(
      RedisHandshake.redact(echoed, password: "a").message
        == "The server refused the connection (ERR).")
    // Dblore's own texts never hold the password: kept whole
    let own = EngineFailure(code: .connect, message: "The server did not answer in time.")
    #expect(RedisHandshake.redact(own, password: "a").message == own.message)
    // A text without the password is kept whatever its length
    let other = EngineFailure(code: .connect, message: "WRONGPASS nope", serverCode: "WRONGPASS")
    #expect(RedisHandshake.redact(other, password: "xyz").message == "WRONGPASS nope")
  }

  @Test func aDecoderCapReachesTheUserWithItsOwnText() {
    let deep = RESPProtocolError(message: "The reply is nested deeper than 128 levels.")
    #expect(deep.failure.message == "The reply is nested deeper than 128 levels.")
    #expect(deep.failure.code == .query)
    #expect(RESPProtocolError().failure.message == "The server's reply could not be read.")
  }
}
