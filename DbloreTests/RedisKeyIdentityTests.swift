// RedisKeyIdentityTests.swift
// The key browser's command builders: every key, member, field, value, pattern and stream id is
// its own argument with its exact bytes, the command runs in the key's database, and the gate
// classifies each command as the read or write it is

import Foundation
import Testing

@testable import Dblore

@Suite("Redis key command builders")
struct RedisKeyIdentityTests {

  private static func text(_ value: String) -> Data { Data(value.utf8) }

  /// `\xff\x00\r\nFLUSHALL`: a key that would run a second command if spliced into command text
  private static let injectionKey = Data([0xFF, 0x00, 0x0D, 0x0A]) + text("FLUSHALL")
  /// Not UTF-8 (a lone continuation byte, a truncated sequence), with a space and a quote
  private static let binaryKey = Data([0x80, 0x20, 0x22, 0xC3])
  /// "café" precomposed (U+00E9) and decomposed (e + U+0301): equal as Swift strings, not as bytes
  private static let cafeNFC = Data([0x63, 0x61, 0x66, 0xC3, 0xA9])
  private static let cafeNFD = Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81])

  /// Payloads with CR LF and spaces, so a splice would show as extra arguments
  private static let member = text("m 1\r\nDEL x")
  private static let field = text("f 2\r\nFLUSHDB")
  private static let value = Data([0x00, 0xFF]) + text(" v\r\nSHUTDOWN")
  private static let streamID = text("1-1\r\n*")
  /// An id `XADD` takes (it refuses `streamID`, which would not be one argument's worth of id)
  private static let addID = text("1526919030474-55")

  /// Every builder for `key` (db 3), with the exact argument array and the kind the gate gives it
  private static func everyBuilder(
    _ key: Data
  ) throws -> [(
    name: String, command: RedisCommand, args: [Data], kind: StatementKind
  )] {
    let ref = RedisKeyRef(db: 3, bytes: key)
    let other = RedisKeyRef(db: 3, bytes: key + injectionKey)
    let (m, f, v) = (member, field, value)
    return [
      // Reads
      (
        "SCAN", RedisKeyCommands.scan(db: 3, cursor: 42, match: key, type: key),
        [
          text("SCAN"), text("42"), text("MATCH"), key, text("COUNT"), text("500"), text("TYPE"),
          key,
        ],
        .read
      ),
      ("TYPE", RedisKeyCommands.type(ref), [text("TYPE"), key], .read),
      ("PTTL", RedisKeyCommands.pttl(ref), [text("PTTL"), key], .read),
      ("STRLEN", RedisKeyCommands.strlen(ref), [text("STRLEN"), key], .read),
      (
        "MEMORY USAGE", RedisKeyCommands.memoryUsage(ref),
        [text("MEMORY"), text("USAGE"), key], .read
      ),
      (
        "GETRANGE", RedisKeyCommands.getRange(ref),
        [text("GETRANGE"), key, text("0"), text("262143")], .read
      ),
      (
        "HSCAN", RedisKeyCommands.hscan(ref, cursor: 7, count: 100),
        [text("HSCAN"), key, text("7"), text("COUNT"), text("100")], .read
      ),
      (
        "LRANGE", RedisKeyCommands.lrange(ref, start: 0, stop: 99),
        [text("LRANGE"), key, text("0"), text("99")], .read
      ),
      (
        "SSCAN", RedisKeyCommands.sscan(ref, cursor: 0, count: 100),
        [text("SSCAN"), key, text("0"), text("COUNT"), text("100")], .read
      ),
      (
        "ZRANGE", RedisKeyCommands.zrange(ref, start: 100, stop: -1),
        [text("ZRANGE"), key, text("100"), text("-1"), text("WITHSCORES")], .read
      ),
      (
        "XRANGE", try #require(RedisKeyCommands.xrange(ref, after: text("5-3"), count: 100)),
        [text("XRANGE"), key, text("5-4"), text("+"), text("COUNT"), text("100")], .read
      ),
      ("INFO", RedisKeyCommands.infoKeyspace(db: 3), [text("INFO"), text("keyspace")], .read),
      // Writes
      (
        "SET", RedisKeyCommands.set(ref, value: v),
        [text("SET"), key, v, text("KEEPTTL"), text("XX")], .dml
      ),
      ("HSET", RedisKeyCommands.hset(ref, field: f, value: v), [text("HSET"), key, f, v], .dml),
      ("HDEL", RedisKeyCommands.hdel(ref, field: f), [text("HDEL"), key, f], .dml),
      (
        "LSET", RedisKeyCommands.lset(ref, index: -2, value: v),
        [text("LSET"), key, text("-2"), v], .dml
      ),
      ("RPUSH", RedisKeyCommands.rpush(ref, value: v), [text("RPUSH"), key, v], .dml),
      ("LPUSH", RedisKeyCommands.lpush(ref, value: v), [text("LPUSH"), key, v], .dml),
      ("SADD", RedisKeyCommands.sadd(ref, member: m), [text("SADD"), key, m], .dml),
      ("SREM", RedisKeyCommands.srem(ref, member: m), [text("SREM"), key, m], .dml),
      (
        "ZADD", try #require(RedisKeyCommands.zadd(ref, score: 1.5, member: m)),
        [text("ZADD"), key, text("1.5"), m], .dml
      ),
      ("ZREM", RedisKeyCommands.zrem(ref, member: m), [text("ZREM"), key, m], .dml),
      (
        "XADD", try #require(RedisKeyCommands.xadd(ref, id: addID, fields: [(f, v), (m, v)])),
        [text("XADD"), key, addID, f, v, m, v], .dml
      ),
      (
        "XADD *", try #require(RedisKeyCommands.xadd(ref, id: nil, fields: [(f, v)])),
        [text("XADD"), key, text("*"), f, v], .dml
      ),
      ("XDEL", RedisKeyCommands.xdel(ref, id: streamID), [text("XDEL"), key, streamID], .dml),
      (
        "PEXPIRE", try #require(RedisKeyCommands.pexpire(ref, milliseconds: 60_000)),
        [text("PEXPIRE"), key, text("60000")], .dml
      ),
      ("PERSIST", RedisKeyCommands.persist(ref), [text("PERSIST"), key], .dml),
      (
        "RENAMENX", try #require(RedisKeyCommands.renameNX(ref, to: other)),
        [text("RENAMENX"), key, other.bytes], .dml
      ),
      ("UNLINK", RedisKeyCommands.unlink(ref), [text("UNLINK"), key], .dml),
      // Create, one per type
      (
        "create string", RedisKeyCommands.createString(ref, value: v),
        [text("SET"), key, v, text("NX")], .dml
      ),
      (
        "create hash", RedisKeyCommands.createHash(ref, field: f, value: v),
        [text("HSET"), key, f, v], .dml
      ),
      ("create list", RedisKeyCommands.createList(ref, value: v), [text("RPUSH"), key, v], .dml),
      ("create set", RedisKeyCommands.createSet(ref, member: m), [text("SADD"), key, m], .dml),
      (
        "create sorted set",
        try #require(RedisKeyCommands.createSortedSet(ref, score: -2, member: m)),
        [text("ZADD"), key, text("-2.0"), m], .dml
      ),
      (
        "create stream", RedisKeyCommands.createStream(ref, field: f, value: v),
        [text("XADD"), key, text("*"), f, v], .dml
      ),
    ]
  }

  @Test(
    "Every builder keeps the key and each payload as one argument, byte for byte, in the key's db",
    arguments: [injectionKey, binaryKey, cafeNFC, cafeNFD])
  func everyBuilderKeepsArguments(key: Data) throws {
    for builder in try Self.everyBuilder(key) {
      #expect(builder.command.args == builder.args, "\(builder.name)")
      #expect(builder.command.db == 3, "\(builder.name)")
      let classification = RedisCommandClassifier.classify(builder.command.args)
      #expect(classification.refusal == nil, "\(builder.name)")
      #expect(classification.statement.kind == builder.kind, "\(builder.name)")
      #expect(classification.statement.isDestructive == false, "\(builder.name)")
    }
  }

  @Test("An NFC and an NFD \"café\" stay distinct keys with distinct argument bytes")
  func normalizationTwinsStayDistinct() {
    let nfc = RedisKeyRef(db: 0, bytes: Self.cafeNFC)
    let nfd = RedisKeyRef(db: 0, bytes: Self.cafeNFD)
    #expect(nfc != nfd)
    #expect(RedisKeyCommands.type(nfc).args[1] == Self.cafeNFC)
    #expect(RedisKeyCommands.type(nfd).args[1] == Self.cafeNFD)
    #expect(RedisKeyCommands.unlink(nfc) != RedisKeyCommands.unlink(nfd))
  }

  @Test(
    "The next stream page starts at the id right after the last one seen",
    arguments: [
      ("0-0", "0-1"),
      ("1526919030474-55", "1526919030474-56"),
      ("5-18446744073709551615", "6-0"),
      ("18446744073709551614-18446744073709551615", "18446744073709551615-0"),
    ])
  func nextStreamID(last: String, next: String) throws {
    #expect(RedisKeyCommands.nextStreamID(after: Self.text(last)) == Self.text(next))
    let command = try #require(
      RedisKeyCommands.xrange(
        RedisKeyRef(db: 0, bytes: Self.injectionKey), after: Self.text(last),
        count: 50))
    #expect(command.args[2] == Self.text(next))
  }

  @Test(
    "A malformed or final stream id gives no next page start, never a guessed one",
    arguments: [
      "", "5", "5-", "-5", "5-1-2", "+5-1", "5-+1", "5--1", " 5-1", "5-1 ", "a-1", "5-1\r\n",
      "0x5-1", "5.0-1", "5\u{2013}1", "18446744073709551616-0", "0-18446744073709551616",
      "18446744073709551615-18446744073709551615",
    ])
  func malformedStreamID(last: String) {
    #expect(RedisKeyCommands.nextStreamID(after: Self.text(last)) == nil)
    #expect(
      RedisKeyCommands.xrange(
        RedisKeyRef(db: 0, bytes: Self.text("s")), after: Self.text(last),
        count: 50) == nil)
  }

  @Test("The first stream page starts at -, the first SCAN page at cursor 0 without TYPE")
  func firstPages() throws {
    let key = RedisKeyRef(db: 15, bytes: Self.injectionKey)
    let xrange = try #require(RedisKeyCommands.xrange(key, after: nil, count: 100))
    #expect(
      xrange.args == [
        Self.text("XRANGE"), Self.injectionKey, Self.text("-"), Self.text("+"),
        Self.text("COUNT"), Self.text("100"),
      ])
    let scan = RedisKeyCommands.scan(db: 15, cursor: 0, match: Self.text("*"))
    #expect(
      scan.args == [
        Self.text("SCAN"), Self.text("0"), Self.text("MATCH"), Self.text("*"),
        Self.text("COUNT"), Self.text("500"),
      ])
    #expect(scan.db == 15)
    let last = RedisKeyCommands.scan(db: 0, cursor: .max, match: Self.text("*"))
    #expect(last.args[1] == Self.text("18446744073709551615"))
    #expect(RedisCommandClassifier.classify(scan.args).statement.kind == .read)
  }

  @Test(
    "XADD takes an id only as *, <ms>, <ms>-* or <ms>-<seq>, its exact bytes as one argument",
    arguments: [
      "*", "0", "5", "5-*", "5-0", "0-1", "007-0010", "18446744073709551615-18446744073709551615",
    ])
  func xaddValidID(id: String) throws {
    let key = RedisKeyRef(db: 2, bytes: Self.injectionKey)
    let command = try #require(
      RedisKeyCommands.xadd(key, id: Self.text(id), fields: [(Self.field, Self.value)]))
    #expect(
      command.args == [
        Self.text("XADD"), Self.injectionKey, Self.text(id), Self.field, Self.value,
      ])
    #expect(command.db == 2)
  }

  @Test(
    "XADD refuses an id Redis would read as an option or that is not a stream id",
    arguments: [
      "", "MAXLEN", "maxlen", "MINID", "NOMKSTREAM", "LIMIT", "~", "=", "-", "+", "5-", "-5",
      "*-1", "*-*", "5-*-1", "5-1-2", "+5-1", "5-+1", "-5-1", "5--1", " 5-1", "5-1 ", "5-1\r\n",
      "\r\n5-1", "5-1\r\nMAXLEN", "a-1", "0x5", "5.0", "5\u{2013}1", "\u{0663}", "5-\u{0663}",
      "\u{FF15}-1", "18446744073709551616", "18446744073709551616-0", "0-18446744073709551616",
      "**",
    ])
  func xaddRefusedID(id: String) {
    let key = RedisKeyRef(db: 0, bytes: Self.text("s"))
    #expect(
      RedisKeyCommands.xadd(key, id: Self.text(id), fields: [(Self.field, Self.value)]) == nil)
  }

  @Test(
    "Builders refuse what Redis would misread: a non-finite score, a cross-db rename, a TTL <= 0")
  func refusedInputs() throws {
    let key = RedisKeyRef(db: 1, bytes: Self.injectionKey)
    for score in [Double.nan, .infinity, -.infinity] {
      #expect(RedisKeyCommands.zadd(key, score: score, member: Self.member) == nil)
      #expect(RedisKeyCommands.createSortedSet(key, score: score, member: Self.member) == nil)
    }
    // The score text parses back to the same Double
    for score in [0.1, -2.5e-300, 1e20, 5e-324, 123_456_789.123_456_78, -0.0] {
      let command = try #require(RedisKeyCommands.zadd(key, score: score, member: Self.member))
      let parsed = try #require(Double(String(decoding: command.args[2], as: UTF8.self)))
      #expect(parsed.bitPattern == score.bitPattern)
    }
    #expect(RedisKeyCommands.renameNX(key, to: RedisKeyRef(db: 2, bytes: Self.cafeNFC)) == nil)
    #expect(RedisKeyCommands.pexpire(key, milliseconds: 0) == nil)
    #expect(RedisKeyCommands.pexpire(key, milliseconds: -1) == nil)
    #expect(RedisKeyCommands.xadd(key, id: nil, fields: []) == nil)
  }
}
