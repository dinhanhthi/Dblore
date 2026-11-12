// RESPTests.swift
// The Redis wire format without a server: the command encoder, the reply decoder fed a few bytes
// at a time, draining the rest of a reply, and the decoder's caps (nesting depth, value size,
// bad counts).

import Foundation
import Testing

// MARK: - Source

/// A reply's bytes arriving `chunk` bytes per receive, read whole tokens at a time as a
/// `RedisReader` reads them: `line` and `bytes` wait (receive) until their whole token is in,
/// `skip` drops only what has been received. Past the end of the bytes they throw `EndOfData`
/// without consuming anything.
nonisolated private final class ChunkedSource: RESPSource {
  struct EndOfData: Error {}
  /// An interrupt: the read stopped, nothing was consumed
  struct Stopped: Error {}

  private let data: [UInt8]
  private let chunk: Int
  /// Bytes received from the wire so far
  private var received = 0
  /// Bytes consumed so far
  private var offset = 0
  /// `bytes` calls, made or stopped
  private(set) var bytesCalls = 0
  /// The next `bytes` call throws `Stopped`
  var stopsNextPayload = false

  init(_ data: Data, chunk: Int = 1) {
    self.data = Array(data)
    self.chunk = chunk
  }

  /// Bytes not consumed yet
  var remaining: Int { data.count - offset }

  func line() throws -> Data {
    while true {
      var index = offset
      while index + 1 < received {
        if data[index] == 0x0D, data[index + 1] == 0x0A {
          let line = Data(data[offset..<index])
          offset = index + 2
          return line
        }
        index += 1
      }
      try receive()
    }
  }

  func bytes(_ count: Int) throws -> Data {
    bytesCalls += 1
    if stopsNextPayload {
      stopsNextPayload = false
      throw Stopped()
    }
    while received - offset < count { try receive() }
    defer { offset += count }
    return Data(data[offset..<offset + count])
  }

  func skip(_ count: inout Int) throws {
    guard count > 0 else { return }
    if received == offset { try receive() }
    let dropped = min(count, received - offset)
    offset += dropped
    count -= dropped
  }

  private func receive() throws {
    guard received < data.count else { throw EndOfData() }
    received = min(received + chunk, data.count)
  }
}

/// The wire bytes of `text` (CRLFs written out as `\r\n`)
private func wire(_ text: String) -> Data { Data(text.utf8) }

private func row(_ path: String, _ type: String, _ value: EngineCell) -> [EngineCell] {
  [.text(path), .text(type), value]
}

/// Every row of the next reply in `source`
private func rows(of source: ChunkedSource) throws -> [[EngineCell]] {
  let reply = RESPReply()
  var rows: [[EngineCell]] = []
  while let node = try reply.next(from: source) { rows.append(node.row) }
  #expect(reply.isComplete)
  return rows
}

/// Reads the whole reply in `source`, building rows (`keep`) or skipping them
private func readAll(_ source: ChunkedSource, keep: Bool) throws {
  let reply = RESPReply()
  if keep {
    while try reply.next(from: source) != nil {}
  } else {
    while try reply.skipNext(from: source) {}
  }
}

// MARK: - Tests

@Suite struct RESPTests {
  @Test func anArgumentWithCRLFAndInvalidUTF8IsOneBulkString() throws {
    let argument = Data([0xFF, 0x00, 0x0D, 0x0A])
    let encoded = RESP.command([Data("SET".utf8), Data("k".utf8), argument])

    var expected = wire("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\n")
    expected.append(argument)
    expected.append(wire("\r\n"))
    #expect(encoded == expected)

    // Read back as a reply: three bulk strings, the last one as its exact bytes
    #expect(
      try rows(of: ChunkedSource(encoded)) == [
        row("0", "array", .int(3)),
        row("0.0", "bulk", .text("SET")),
        row("0.1", "bulk", .text("k")),
        row("0.2", "bulk", .bytes(argument)),
      ])
  }

  @Test(arguments: [1, 7, 4096])
  func nestedRESP3SplitAcrossReadsYieldsPathTypeValueRows(chunk: Int) throws {
    // An out-of-band push and an attribute before the reply, an attribute before a set member
    var data = wire(
      ">2\r\n+message\r\n$2\r\nhi\r\n"
        + "|1\r\n+meta\r\n*1\r\n:1\r\n"
        + "%4\r\n"
        + "+list\r\n*3\r\n,3.14\r\n(12345678901234567890\r\n:-42\r\n"
        + "$3\r\nset\r\n~3\r\n_\r\n#t\r\n|1\r\n+ttl\r\n:3600\r\n=15\r\ntxt:Some string\r\n"
        + "+err\r\n!21\r\nSYNTAX invalid syntax\r\n"
        + "+raw\r\n$2\r\n")
    data.append(contentsOf: [0xFF, 0xFE])
    data.append(wire("\r\n"))
    let source = ChunkedSource(data, chunk: chunk)

    #expect(
      try rows(of: source) == [
        row("0", "map", .int(8)),
        row("0.0", "simple", .text("list")),
        row("0.1", "array", .int(3)),
        row("0.1.0", "double", .text("3.14")),
        row("0.1.1", "bignum", .text("12345678901234567890")),
        row("0.1.2", "integer", .int(-42)),
        row("0.2", "bulk", .text("set")),
        row("0.3", "set", .int(3)),
        row("0.3.0", "null", .null),
        row("0.3.1", "boolean", .text("true")),
        row("0.3.2", "verbatim", .text("Some string")),
        row("0.4", "simple", .text("err")),
        row("0.5", "error", .text("SYNTAX invalid syntax")),
        row("0.6", "simple", .text("raw")),
        row("0.7", "bulk", .bytes(Data([0xFF, 0xFE]))),
      ])
    #expect(source.remaining == 0)
  }

  /// `stopsInPayload`: an interrupt stops the read of a kept bulk string's payload; else the
  /// reader just stops after two nodes
  @Test(arguments: [true, false])
  func skippingTheRestOfAReplyLeavesTheNextOneIntact(stopsInPayload: Bool) throws {
    let source = ChunkedSource(
      wire(
        "*3\r\n$5\r\nhello\r\n$3\r\nabc\r\n*2\r\n:1\r\n$4\r\nlast\r\n"
          + "*2\r\n+OK\r\n$3\r\nend\r\n"))
    let reply = RESPReply()
    #expect(try reply.next(from: source)?.row == row("0", "array", .int(3)))
    if stopsInPayload {
      source.stopsNextPayload = true
      #expect(throws: ChunkedSource.Stopped.self) { _ = try reply.next(from: source) }
    } else {
      #expect(try reply.next(from: source)?.row == row("0.0", "bulk", .text("hello")))
    }
    #expect(!reply.isComplete)

    while try reply.skipNext(from: source) {}
    #expect(reply.isComplete)
    #expect(
      try rows(of: source) == [
        row("0", "array", .int(2)),
        row("0.0", "simple", .text("OK")),
        row("0.1", "bulk", .text("end")),
      ])
    #expect(source.remaining == 0)
  }

  @Test(arguments: [true, false])
  func aReplyNestedToTheCapCompletes(keep: Bool) throws {
    let data = wire(String(repeating: "*1\r\n", count: RESPReply.maxDepth) + ":1\r\n")
    let source = ChunkedSource(data, chunk: data.count)
    if keep {
      let rows = try rows(of: source)
      #expect(rows.count == RESPReply.maxDepth + 1)
      #expect(rows.last?[1] == .text("integer"))
    } else {
      try readAll(source, keep: false)
    }
    #expect(source.remaining == 0)
  }

  /// A chain of last children (`*1`), of first-then-last children (`*2 :1`) and of map values
  @Test(arguments: [true, false], ["*1\r\n", "*2\r\n:1\r\n", "%1\r\n+k\r\n"])
  func aReplyNestedPastTheCapThrows(keep: Bool, level: String) throws {
    let data = wire(String(repeating: level, count: RESPReply.maxDepth + 1) + ":1\r\n")
    let source = ChunkedSource(data, chunk: data.count)
    let error = #expect(throws: RESPProtocolError.self) { try readAll(source, keep: keep) }
    #expect(error?.message == "The reply is nested deeper than 128 levels.")
  }

  @Test func aValueOver256MiBIsTooLargeAndNeverRead() throws {
    let source = ChunkedSource(wire("$\(EnginePluginProtocol.maxValueBytes + 1)\r\n"))
    let error = #expect(throws: EngineFailure.self) { try readAll(source, keep: true) }
    #expect(error?.code == .tooLarge)
    #expect(source.bytesCalls == 0)
  }

  @Test(arguments: ["$-1\r\n", "*-1\r\n"])
  func resp2NullsAreNullRows(header: String) throws {
    #expect(try rows(of: ChunkedSource(wire(header))) == [row("0", "null", .null)])
  }

  @Test(arguments: ["$-2\r\n", "*-5\r\n", "%-3\r\n", "|-1\r\n:1\r\n"])
  func negativeCountsOtherThanMinusOneAreProtocolErrors(header: String) throws {
    #expect(throws: RESPProtocolError.self) {
      try readAll(ChunkedSource(wire(header)), keep: true)
    }
  }

  @Test(arguments: [true, false])
  func hugeAttributeCountsDoNotTrap(keep: Bool) throws {
    let source = ChunkedSource(wire(String(repeating: "|2147483647\r\n", count: 4)))
    #expect(throws: (any Error).self) { try readAll(source, keep: keep) }
  }
}
