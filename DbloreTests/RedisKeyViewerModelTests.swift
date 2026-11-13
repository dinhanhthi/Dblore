// RedisKeyViewerModelTests.swift
// The key tab header's pure logic (TYPE / PTTL / count reply parsing, TTL countdown math and
// text), its loads on scripted replies (missing key, a refused MEMORY USAGE, an older load
// dropped, the re-check when the TTL ends) and its reads through the gate on a read-only
// connection. The value's pure logic (page commands and replies per type, paging cursors and
// offsets, duplicates and caps, cell escaping, string preview, hex, JSON) and its loads (first
// page, "Load more", stale pages dropped, reset).

import Foundation
import Testing

@testable import Dblore

/// Answers each command by its name (`MEMORY` for `MEMORY USAGE`), queued replies first; can
/// hold the next command of a name
private actor ScriptedReads {
  private var answers: [String: Result<RedisReply, any Error>] = [:]
  private var queued: [String: [RedisReply]] = [:]
  private(set) var sent: [RedisCommand] = []
  private var holdsNext: String?
  private var held: CheckedContinuation<Void, Never>?

  var isHolding: Bool { held != nil }

  func answer(_ name: String, _ reply: RedisReply) { answers[name] = .success(reply) }
  func fail(_ name: String, _ error: any Error) { answers[name] = .failure(error) }
  /// Each next send of `name` answers the next of `replies` (then `answers` again)
  func queue(_ name: String, _ replies: [RedisReply]) { queued[name, default: []] += replies }
  func holdNextType() { holdsNext = "TYPE" }
  func holdNext(_ name: String) { holdsNext = name }

  func release() {
    held?.resume()
    held = nil
  }

  func read(_ command: RedisCommand) async throws -> RedisReply {
    sent.append(command)
    let name = String(decoding: command.args[0], as: UTF8.self)
    if name == holdsNext {
      holdsNext = nil
      await withCheckedContinuation { held = $0 }
    }
    if var replies = queued[name], !replies.isEmpty {
      let reply = replies.removeFirst()
      queued[name] = replies
      return reply
    }
    guard let answer = answers[name] else {
      throw RedisReplyDecodingError(message: "no scripted answer for \(name)")
    }
    return try answer.get()
  }
}

private actor Counter {
  private(set) var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

@MainActor
@Suite("Redis key viewer")
struct RedisKeyViewerModelTests {
  private typealias Model = RedisKeyViewerModel

  private static let key = RedisKeyRef(db: 3, bytes: Data("user:1".utf8))
  private static let otherKey = RedisKeyRef(db: 3, bytes: Data("user:2".utf8))

  private static func reads(
    type: String = "hash", pttl: Int = -1, memory: Int = 1_234
  ) async -> ScriptedReads {
    let reads = ScriptedReads()
    await reads.answer("TYPE", .simple(.text(type)))
    await reads.answer("PTTL", .integer(pttl))
    await reads.answer("MEMORY", .integer(memory))
    await reads.answer("STRLEN", .integer(5))
    await reads.answer("HSCAN", scan("0", ["f", "v"]))
    await reads.answer("GETRANGE", .bulk(.text("hello")))
    return reads
  }

  /// A `SCAN`-family reply
  private static func scan(_ cursor: String, _ items: [String]) -> RedisReply {
    .array([.bulk(.text(cursor)), .array(items.map { .bulk(.text($0)) })])
  }

  /// An array of bulk strings
  private static func bulks(_ items: [String]) -> RedisReply {
    .array(items.map { .bulk(.text($0)) })
  }

  /// The rows of `values`, else nil
  private static func rowList(_ values: Model.Values) -> Model.RowList? {
    if case .rows(let list) = values { return list }
    return nil
  }

  private static func read(_ reads: ScriptedReads) -> Model.Read {
    { try await reads.read($0) }
  }

  /// Waits until `condition` holds, at most `seconds`
  private static func waitUntil(
    seconds: Double = 3, _ condition: @MainActor () async -> Bool
  ) async {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end, !(await condition()) {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  // MARK: - Parsing

  @Test("TYPE: core names map, none is no key, any other name is escaped and cut")
  func typeParsing() throws {
    #expect(try Model.keyType(.simple(.text("none"))) == nil)
    #expect(try Model.keyType(.simple(.text("string"))) == .string)
    #expect(try Model.keyType(.bulk(.text("zset"))) == .sortedSet)
    #expect(try Model.keyType(.simple(.text("stream"))) == .stream)
    #expect(try Model.keyType(.simple(.text("ReJSON-RL"))) == .other("ReJSON-RL"))
    #expect(try Model.keyType(.simple(.text("x\r\ny\u{202E}"))) == .other(#"x\r\ny\u{202E}"#))
    #expect(try Model.keyType(.simple(.bytes(Data([0xFF, 0x41])))) == .other(#"\xffA"#))
    // A name made of bytes is never a core type, even "none"
    #expect(try Model.keyType(.simple(.bytes(Data("none".utf8)))) == .other("none"))
    let long = try Model.keyType(.simple(.text(String(repeating: "a", count: 500))))
    #expect(long == .other(String(repeating: "a", count: Model.maxTypeLength) + "…"))
    #expect(throws: RedisReplyDecodingError.self) { try Model.keyType(.integer(1)) }
    #expect(throws: RedisReplyDecodingError.self) { try Model.keyType(.error(.text("ERR"))) }
    #expect(throws: RedisReplyDecodingError.self) { try Model.keyType(.simple(.text(""))) }
  }

  @Test("PTTL: -2 is no key, -1 no expiry, else the milliseconds left; anything else throws")
  func ttlParsing() throws {
    #expect(try Model.ttlReading(.integer(-2)) == nil)
    #expect(try Model.ttlReading(.integer(-1)) == .noExpiry)
    #expect(try Model.ttlReading(.integer(0)) == .milliseconds(0))
    #expect(try Model.ttlReading(.integer(5_000)) == .milliseconds(5_000))
    #expect(throws: RedisReplyDecodingError.self) { try Model.ttlReading(.integer(-3)) }
    #expect(throws: RedisReplyDecodingError.self) { try Model.ttlReading(.bulk(.text("5"))) }
    #expect(throws: RedisReplyDecodingError.self) { try Model.ttlReading(.null) }
  }

  @Test("Counts are non-negative integers only")
  func countParsing() {
    #expect(Model.count(.integer(0)) == 0)
    #expect(Model.count(.integer(72)) == 72)
    #expect(Model.count(.integer(-1)) == nil)
    #expect(Model.count(.null) == nil)
    #expect(Model.count(.bulk(.text("72"))) == nil)
    #expect(Model.memoryText(nil) == "—")
    #expect(!Model.memoryText(72).isEmpty)
  }

  // MARK: - TTL countdown

  @Test("The countdown rounds up to whole seconds and names the units")
  func ttlText() {
    #expect(Model.ttlText(remainingMilliseconds: 0) == "Expiring…")
    #expect(Model.ttlText(remainingMilliseconds: 1) == "1s")
    #expect(Model.ttlText(remainingMilliseconds: 1_000) == "1s")
    #expect(Model.ttlText(remainingMilliseconds: 1_001) == "2s")
    #expect(Model.ttlText(remainingMilliseconds: 59_999) == "1m 00s")
    #expect(Model.ttlText(remainingMilliseconds: 61_000) == "1m 01s")
    #expect(Model.ttlText(remainingMilliseconds: 3_600_000) == "1h 00m 00s")
    #expect(Model.ttlText(remainingMilliseconds: 90_061_000) == "1d 01h 01m 01s")
    #expect(Model.ttlText(remainingMilliseconds: Int.max).hasSuffix("s"))
  }

  @Test("Time left and the next tick come from the deadline")
  func countdownMath() {
    let now = ContinuousClock.now
    #expect(Model.remainingMilliseconds(until: now + .milliseconds(4_300), now: now) == 4_300)
    #expect(Model.remainingMilliseconds(until: now, now: now) == 0)
    #expect(Model.remainingMilliseconds(until: now - .seconds(5), now: now) == 0)
    let far = now + .milliseconds(Int.max) + .seconds(10)
    #expect(Model.remainingMilliseconds(until: far, now: now) == Int.max)
    #expect(Model.nextTickDelay(remainingMilliseconds: 4_300) == 300)
    #expect(Model.nextTickDelay(remainingMilliseconds: 4_000) == 1_000)
    #expect(Model.nextTickDelay(remainingMilliseconds: 1) == 1)
  }

  // MARK: - Loads

  @Test("A hash key: TYPE, PTTL and MEMORY USAGE in its db, no STRLEN, then its first page")
  func loadsHeader() async throws {
    let reads = await Self.reads()
    let model = Model()
    let task = model.load(Self.key, read: Self.read(reads))
    // Loading for the key as soon as the call returns
    #expect(model.state(for: Self.key) == .loading)
    #expect(!model.loaded)
    await task.value
    #expect(model.loaded)
    #expect(
      model.state(for: Self.key)
        == .loaded(.init(type: .hash, expiry: .never, memoryBytes: 1_234, stringLength: nil)))
    #expect(model.state(for: Self.otherKey) == .loading)
    let sent = await reads.sent
    #expect(
      sent == [
        RedisKeyCommands.type(Self.key), RedisKeyCommands.pttl(Self.key),
        RedisKeyCommands.memoryUsage(Self.key),
        RedisKeyCommands.hscan(Self.key, cursor: 0, count: Model.pageSize),
      ])
    #expect(sent.allSatisfy { $0.db == 3 })
    // Then its first page, in the same read sequence
    let list = try #require(Self.rowList(model.values(for: Self.key)))
    #expect(list.rows == [.init(identity: .field(Data("f".utf8)), name: "f", value: "v")])
    #expect(list.next == nil)
    #expect(!list.isLoadingMore)
    #expect(model.values(for: Self.otherKey) == .loading)
  }

  @Test("A string key also reads STRLEN; a refused MEMORY USAGE is no size, not an error")
  func stringAndRefusedMemory() async {
    let reads = await Self.reads(type: "string")
    await reads.fail("MEMORY", DatabaseError.queryFailed("NOPERM no permissions", 0))
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    #expect(
      model.state
        == .loaded(.init(type: .string, expiry: .never, memoryBytes: nil, stringLength: 5)))
    let sent = await reads.sent
    #expect(
      sent.suffix(2) == [RedisKeyCommands.strlen(Self.key), RedisKeyCommands.getRange(Self.key)])
    guard case .string(let value) = model.values else {
      Issue.record("expected a string value, got \(model.values)")
      return
    }
    #expect(value.text == "hello")
    #expect(value.isComplete)
    #expect(value.json == nil)
  }

  @Test("TYPE none and PTTL -2 show the missing state; nothing more is read")
  func missingKey() async {
    let none = await Self.reads(type: "none")
    let model = Model()
    await model.load(Self.key, read: Self.read(none)).value
    #expect(model.state == .missing)
    #expect(await none.sent.count == 1)

    let gone = await Self.reads(pttl: -2)
    await model.load(Self.key, read: Self.read(gone)).value
    #expect(model.state == .missing)
    #expect(await gone.sent.count == 2)
  }

  @Test("A failed read shows one escaped line; a reconnect says so")
  func failures() async {
    let reads = await Self.reads()
    await reads.fail("TYPE", DatabaseError.queryFailed("bad\r\nline", 0))
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    guard case .failed(let message) = model.state else {
      Issue.record("expected a failure, got \(model.state)")
      return
    }
    #expect(!message.contains("\n"))
    #expect(message.contains(#"\r\n"#))

    await reads.fail("PTTL", DatabaseError.sessionChanged(skippedStatements: 1))
    await reads.answer("TYPE", .simple(.text("hash")))
    await model.load(Self.key, read: Self.read(reads)).value
    #expect(model.state == .failed("The connection changed while this key was read."))
  }

  @Test("An older load never overwrites a newer key's header, and stops reading")
  func staleLoadDropped() async {
    let reads = await Self.reads()
    await reads.holdNextType()
    let model = Model()
    let first = model.load(Self.key, read: Self.read(reads))
    await Self.waitUntil { await reads.isHolding }
    #expect(await reads.isHolding)

    let second = model.load(Self.otherKey, read: Self.read(reads))
    #expect(model.state(for: Self.otherKey) == .loading)
    await second.value
    let header = Model.Header(
      type: .hash, expiry: .never, memoryBytes: 1_234, stringLength: nil)
    #expect(model.state(for: Self.otherKey) == .loaded(header))

    // The held load now answers another type: dropped, and its PTTL is never sent
    await reads.answer("TYPE", .simple(.text("list")))
    await reads.release()
    await first.value
    #expect(model.key == Self.otherKey)
    #expect(model.state == .loaded(header))
    #expect(await reads.sent.filter { $0.args.contains(Self.key.bytes) }.count == 1)
  }

  @Test("When the TTL ends the key is checked again: gone shows the missing state")
  func expiredDuringCountdown() async {
    let reads = await Self.reads(pttl: 1)
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    guard case .loaded(let header) = model.state, case .at = header.expiry else {
      Issue.record("expected a header with an expiry, got \(model.state)")
      return
    }
    await reads.answer("TYPE", .simple(.text("none")))
    await Self.waitUntil { model.state == .missing }
    #expect(model.state == .missing)
    #expect(await reads.sent.last == RedisKeyCommands.type(Self.key))
  }

  @Test("The re-check is a new read sequence (a fresh epoch), not the load's")
  func recheckTakesNewReader() async {
    let first = await Self.reads(pttl: 1)
    let second = await Self.reads(type: "none")
    let made = Counter()
    let model = Model()
    await model.load(
      Self.key,
      makeRead: {
        let reads = await made.next() == 1 ? first : second
        return { try await reads.read($0) }
      }
    ).value
    await Self.waitUntil { model.state == .missing }
    #expect(model.state == .missing)
    #expect(await made.value == 2)
    #expect(await second.sent == [RedisKeyCommands.type(Self.key)])
  }

  @Test("A key still there after its countdown shows its new TTL; the header stays meanwhile")
  func persistedDuringCountdown() async {
    let reads = await Self.reads(pttl: 1)
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    await reads.answer("PTTL", .integer(-1))
    #expect(model.loaded)
    await Self.waitUntil {
      if case .loaded(let header) = model.state { return header.expiry == .never }
      return false
    }
    #expect(
      model.state
        == .loaded(.init(type: .hash, expiry: .never, memoryBytes: 1_234, stringLength: nil)))
    // Same type: the rows shown stay, the first page is not read again
    #expect(Self.rowList(model.values)?.rows.count == 1)
    #expect(await reads.sent.filter { $0.args[0] == Data("HSCAN".utf8) }.count == 1)
  }

  @Test("stop() drops a load in flight and the expiry check")
  func stopDropsLoad() async {
    let reads = await Self.reads(pttl: 1)
    await reads.holdNextType()
    let model = Model()
    let task = model.load(Self.key, read: Self.read(reads))
    await Self.waitUntil { await reads.isHolding }
    model.stop()
    await reads.release()
    await task.value
    #expect(model.state == .loading)
    #expect(await reads.sent.count == 1)
  }

  // MARK: - Value pages (pure)

  @Test("Each type pages with its own command: SCAN-family by cursor, ranges by offset")
  func pageCommands() {
    let key = Self.key
    let size = Model.pageSize
    #expect(Model.firstCursor(.hash) == .scan(0))
    #expect(Model.firstCursor(.set) == .scan(0))
    #expect(Model.firstCursor(.list) == .offset(0))
    #expect(Model.firstCursor(.sortedSet) == .offset(0))
    #expect(Model.firstCursor(.stream) == .after(nil))
    #expect(Model.firstCursor(.string) == nil)
    #expect(Model.firstCursor(.other("ReJSON-RL")) == nil)
    #expect(
      Model.pageCommand(key, kind: .hash, cursor: .scan(7))
        == RedisKeyCommands.hscan(key, cursor: 7, count: size))
    #expect(
      Model.pageCommand(key, kind: .set, cursor: .scan(0))
        == RedisKeyCommands.sscan(key, cursor: 0, count: size))
    #expect(
      Model.pageCommand(key, kind: .list, cursor: .offset(200))
        == RedisKeyCommands.lrange(key, start: 200, stop: 399))
    #expect(
      Model.pageCommand(key, kind: .sortedSet, cursor: .offset(0))
        == RedisKeyCommands.zrange(key, start: 0, stop: 199))
    #expect(
      Model.pageCommand(key, kind: .stream, cursor: .after(Data("5-1".utf8)))
        == RedisKeyCommands.xrange(key, after: Data("5-1".utf8), count: size))
    // A cursor of another kind, or no id after the last one: nothing to send
    #expect(Model.pageCommand(key, kind: .hash, cursor: .offset(0)) == nil)
    let last = Data("\(UInt64.max)-\(UInt64.max)".utf8)
    #expect(Model.pageCommand(key, kind: .stream, cursor: .after(last)) == nil)
  }

  @Test("HSCAN / SSCAN pages: pairs or members by their bytes; cursor 0 is the last page")
  func scanPages() throws {
    let hash = try Model.page(
      .array([
        .bulk(.text("9")),
        .array([
          .bulk(.bytes(Data([0xFF, 0x0A]))), .bulk(.text("v\u{202E}")), .bulk(.text("g")),
          .bulk(.text("")),
        ]),
      ]), kind: .hash, cursor: .scan(0))
    #expect(
      hash.rows == [
        .init(identity: .field(Data([0xFF, 0x0A])), name: #"\xff\n"#, value: #"v\u{202E}"#),
        .init(identity: .field(Data("g".utf8)), name: "g", value: ""),
      ])
    #expect(hash.next == .scan(9))
    let set = try Model.page(Self.scan("0", ["a", "b"]), kind: .set, cursor: .scan(9))
    #expect(set.rows.map(\.identity) == [.member(Data("a".utf8)), .member(Data("b".utf8))])
    #expect(set.rows.allSatisfy { $0.value == nil })
    #expect(set.next == nil)
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.page(Self.scan("0", ["f"]), kind: .hash, cursor: .scan(0))
    }
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.page(Self.bulks(["a"]), kind: .set, cursor: .scan(0))
    }
  }

  @Test("LRANGE / ZRANGE pages: indexes from the offset; a short page is the last")
  func rangePages() throws {
    let full = (0..<Model.pageSize).map { "e\($0)" }
    let list = try Model.page(Self.bulks(full), kind: .list, cursor: .offset(400))
    #expect(list.rows.first == .init(identity: .index(400), name: "400", value: "e0"))
    #expect(list.rows.last?.identity == .index(599))
    #expect(list.next == .offset(600))
    let short = try Model.page(Self.bulks(["x"]), kind: .list, cursor: .offset(600))
    #expect(short.next == nil)
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.page(.integer(1), kind: .list, cursor: .offset(0))
    }

    // RESP3: [member, double] pairs; RESP2: member, score flat
    let resp3 = try Model.page(
      .array([
        .array([.bulk(.text("m")), .double("1.5")]), .array([.bulk(.text("n")), .double("inf")]),
      ]),
      kind: .sortedSet, cursor: .offset(0))
    #expect(
      resp3.rows == [
        .init(identity: .member(Data("m".utf8)), name: "m", value: "1.5"),
        .init(identity: .member(Data("n".utf8)), name: "n", value: "inf"),
      ])
    #expect(resp3.next == nil)
    let resp2 = try Model.page(
      Self.bulks(["m", "1.5", "n", "2"]), kind: .sortedSet, cursor: .offset(0))
    #expect(
      resp2.rows == Array(resp3.rows.prefix(1)) + [
        .init(identity: .member(Data("n".utf8)), name: "n", value: "2")
      ])
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.page(Self.bulks(["m"]), kind: .sortedSet, cursor: .offset(0))
    }
  }

  @Test("XRANGE pages: entry ids with their fields; a full page goes on after its last id")
  func streamPages() throws {
    func entry(_ id: String, _ fields: RedisReply) -> RedisReply {
      .array([.bulk(.text(id)), fields])
    }
    let page = try Model.page(
      .array([
        entry("1-0", Self.bulks(["a", "1", "b", "x\ny"])),
        entry("1-1", .map([RedisReplyPair(key: .bulk(.text("c")), value: .bulk(.text("3")))])),
      ]), kind: .stream, cursor: .after(nil))
    #expect(
      page.rows == [
        .init(identity: .entry(Data("1-0".utf8)), name: "1-0", value: "a: 1\nb: " + #"x\ny"#),
        .init(identity: .entry(Data("1-1".utf8)), name: "1-1", value: "c: 3"),
      ])
    #expect(page.next == nil)

    let full = (0..<Model.pageSize).map { entry("7-\($0)", Self.bulks(["f", "v"])) }
    let fullPage = try Model.page(.array(full), kind: .stream, cursor: .after(nil))
    #expect(fullPage.next == .after(Data("7-199".utf8)))
    // The last possible id: no page can follow it
    let max = "\(UInt64.max)-\(UInt64.max)"
    let last = try Model.page(
      .array(Array(full.dropLast()) + [entry(max, Self.bulks(["f", "v"]))]), kind: .stream,
      cursor: .after(nil))
    #expect(last.next == nil)
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.page(.array([entry("1-0", Self.bulks(["a"]))]), kind: .stream, cursor: .after(nil))
    }
  }

  @Test("Merging pages drops rows already seen and keeps paging past an empty page")
  func mergeDropsDuplicates() {
    var list = Model.RowList(kind: .set, next: .scan(0))
    var seen: Set<Model.ValueRow.Identity> = []
    func member(_ name: String) -> Model.ValueRow {
      .init(identity: .member(Data(name.utf8)), name: name, value: nil)
    }
    #expect(
      Model.apply(.init(rows: [member("a"), member("b")], next: .scan(5)), to: &list, seen: &seen)
        == 2)
    // An empty page with a non-zero cursor: nothing added, paging goes on
    #expect(Model.apply(.init(rows: [], next: .scan(8)), to: &list, seen: &seen) == 0)
    #expect(list.next == .scan(8))
    #expect(
      Model.apply(.init(rows: [member("b"), member("c")], next: nil), to: &list, seen: &seen) == 1)
    #expect(list.rows.map(\.name) == ["a", "b", "c"])
    #expect(list.next == nil)
    #expect(!list.isCapped)
    #expect(list.byteCount == list.rows.reduce(0) { $0 + $1.byteCount })
  }

  @Test("The row cap stops paging mid-page and says so")
  func rowCap() {
    var list = Model.RowList(kind: .list, next: .offset(0))
    var seen: Set<Model.ValueRow.Identity> = []
    let rows = (0..<5).map { Model.ValueRow(identity: .index($0), name: "\($0)", value: "e") }
    #expect(
      Model.apply(.init(rows: rows, next: .offset(5)), to: &list, seen: &seen, maxRows: 3) == 3)
    #expect(list.rows.count == 3)
    #expect(list.isCapped)
    #expect(list.next == nil)

    // Exactly at the cap with nothing after it: not capped
    var whole = Model.RowList(kind: .list, next: .offset(0))
    var wholeSeen: Set<Model.ValueRow.Identity> = []
    _ = Model.apply(
      .init(rows: Array(rows.prefix(3)), next: nil), to: &whole, seen: &wholeSeen, maxRows: 3)
    #expect(!whole.isCapped)

    // The byte cap too
    var bytes = Model.RowList(kind: .list, next: .offset(0))
    var bytesSeen: Set<Model.ValueRow.Identity> = []
    _ = Model.apply(
      .init(rows: rows, next: nil), to: &bytes, seen: &bytesSeen,
      maxBytes: rows[0].byteCount * 2)
    #expect(bytes.rows.count == 2)
    #expect(bytes.isCapped)
  }

  // MARK: - Cells, strings, hex, JSON (pure)

  @Test("Cells are one escaped line, cut after the limit; a cut never splits a character")
  func cells() {
    #expect(Model.cell(Data("a\r\nb\t\\".utf8)) == #"a\r\nb\t\\"#)
    #expect(Model.cell(Data([0x41, 0xFF, 0x00])) == #"A\xff\x00"#)
    #expect(Model.cell(Data("x\u{202E}y".utf8)) == #"x\u{202E}y"#)
    #expect(Model.cell(Data("abcdef".utf8), limit: 4) == "abcd…")
    #expect(Model.cell(Data("abcd".utf8), limit: 4) == "abcd")
    // "é" is 2 bytes: a 3-byte cut keeps "a" + "é" as text, never a stray \xc3
    #expect(Model.cell(Data("aéé".utf8), limit: 3) == "aé…")
    // Escapes count: 4 bytes become 16 characters, cut to the limit
    #expect(Model.cell(Data([0xFF, 0xFF, 0xFF, 0xFF]), limit: 4) == #"\xff"# + "…")
    let huge = Data(repeating: 0x61, count: 1_000_000)
    #expect(Model.cell(huge).count == Model.maxCellLength + 1)
    #expect(
      Model.fieldsText([(Data("a".utf8), Data("1".utf8)), (Data("b".utf8), Data("2".utf8))])
        == "a: 1\nb: 2")
    let many = (0..<5_000).map { (Data("f\($0)".utf8), Data("v".utf8)) }
    let text = Model.fieldsText(many)
    #expect(text.count == Model.maxCellLength + 1)
    #expect(text.hasSuffix("…"))
  }

  @Test("A string preview is complete when shorter than 256 KiB or as long as STRLEN")
  func stringPreview() {
    let preview = RedisKeyCommands.valuePreviewBytes
    let short = Model.stringValue(Data("line 1\r\nline\u{202E}2".utf8), length: nil)
    #expect(short.isComplete)
    #expect(short.text == "line 1\nline" + #"\u{202E}"# + "2")
    let binary = Model.stringValue(Data([0x00, 0xFF]), length: 2)
    #expect(binary.text == #"\x00\xff"#)
    let full = Data(repeating: 0x61, count: preview)
    #expect(Model.stringValue(full, length: preview).isComplete)
    #expect(!Model.stringValue(full, length: preview + 1).isComplete)
    #expect(!Model.stringValue(full, length: nil).isComplete)
    // A cut that splits a character still shows text
    let split = Data(repeating: 0x61, count: preview - 1) + Data("é".utf8).prefix(1)
    let cut = Model.stringValue(split, length: preview + 5)
    #expect(cut.text == String(repeating: "a", count: preview - 1))
    #expect(cut.hex.hasSuffix("|aaaaaaaaaaaaaaa.|"))
  }

  @Test("JSON: only a complete object or array, re-indented as written")
  func jsonPreview() {
    #expect(
      Model.prettyJSON(Data(#"{"b":1.50,"a":[1,{}],"s":"x,{\"y\":[]}","e":[]}"#.utf8))
        == """
        {
          "b": 1.50,
          "a": [
            1,
            {}
          ],
          "s": "x,{\\"y\\":[]}",
          "e": []
        }
        """)
    #expect(Model.prettyJSON(Data(" [ ] ".utf8)) == "[]")
    #expect(Model.prettyJSON(Data("42".utf8)) == nil)
    #expect(Model.prettyJSON(Data(#""text""#.utf8)) == nil)
    #expect(Model.prettyJSON(Data(#"{"a":1"#.utf8)) == nil)
    #expect(Model.prettyJSON(Data(#"{"a":1} x"#.utf8)) == nil)
    #expect(Model.prettyJSON(Data([0x7B, 0x00, 0x7D, 0x00])) == nil)
    #expect(Model.prettyJSON(Data(#"[1,2,3]"#.utf8), maxBytes: 5) == nil)
    // Shown escaped: a bidi control in a string is visible
    let value = Model.stringValue(Data("{\"k\":\"a\u{202E}b\"}".utf8), length: nil)
    #expect(value.json == "{\n  \"k\": \"a" + #"\u{202E}"# + "b\"\n}")
    // Never for a cut preview
    let cut = Data(("[" + String(repeating: "1,", count: 140_000) + "1]").utf8)
    #expect(
      Model.stringValue(cut.prefix(RedisKeyCommands.valuePreviewBytes), length: cut.count).json
        == nil)
  }

  @Test("Hex dump: offset, 16 bytes in two groups, printable ASCII")
  func hexDump() {
    let dump = Model.hexDump(Data("Hi\n".utf8))
    #expect(dump == "00000000  48 69 0a" + String(repeating: " ", count: 42) + "|Hi.|")
    let lines = Model.hexDump(Data(0..<20)).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(
      lines[0] == "00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|")
    #expect(lines[1].hasPrefix("00000010  10 11 12 13 "))
    #expect(Model.hexDump(Data()) == "")
  }

  // MARK: - Value loads

  @Test("A SCAN-family first page reads on past empty and repeated pages until the end")
  func scanFirstPage() async throws {
    let reads = await Self.reads(type: "set")
    await reads.queue(
      "SSCAN", [Self.scan("4", ["a", "b"]), Self.scan("9", []), Self.scan("0", ["b", "c"])])
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    let list = try #require(Self.rowList(model.values))
    #expect(list.rows.map(\.name) == ["a", "b", "c"])
    #expect(list.next == nil)
    let cursors = await reads.sent.filter { $0.args[0] == Data("SSCAN".utf8) }.map { $0.args[2] }
    #expect(cursors == [Data("0".utf8), Data("4".utf8), Data("9".utf8)])
    #expect(model.loadMore() == nil)
  }

  @Test("Load more reads the next page from the offset, through a new read sequence")
  func loadMoreList() async throws {
    let reads = await Self.reads(type: "list")
    let full = (0..<Model.pageSize).map { "e\($0)" }
    await reads.queue("LRANGE", [Self.bulks(full), Self.bulks(["last"])])
    let made = Counter()
    let model = Model()
    await model.load(
      Self.key,
      makeRead: {
        _ = await made.next()
        return { try await reads.read($0) }
      }
    ).value
    var list = try #require(Self.rowList(model.values))
    #expect(list.rows.count == Model.pageSize)
    #expect(list.next == .offset(Model.pageSize))
    let more = try #require(model.loadMore())
    // The click shows at once: loading, a second click does nothing
    #expect(Self.rowList(model.values)?.isLoadingMore == true)
    #expect(model.loadMore() == nil)
    await more.value
    list = try #require(Self.rowList(model.values))
    #expect(list.rows.count == Model.pageSize + 1)
    #expect(list.rows.last == .init(identity: .index(200), name: "200", value: "last"))
    #expect(list.next == nil)
    #expect(!list.isLoadingMore)
    #expect(await made.value == 2)
    #expect(await reads.sent.last == RedisKeyCommands.lrange(Self.key, start: 200, stop: 399))
  }

  @Test("A failed Load more keeps the rows and says why; a failed first page shows the failure")
  func pageFailures() async throws {
    let reads = await Self.reads(type: "list")
    await reads.queue("LRANGE", [Self.bulks((0..<Model.pageSize).map { "e\($0)" })])
    await reads.fail("LRANGE", DatabaseError.queryFailed("boom\r\n", 0))
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    await model.loadMore()?.value
    let list = try #require(Self.rowList(model.values))
    #expect(list.rows.count == Model.pageSize)
    #expect(list.moreError?.contains(#"\r\n"#) == true)
    #expect(list.next == .offset(Model.pageSize))
    #expect(!list.isLoadingMore)

    await model.load(Self.key, read: Self.read(reads)).value
    guard case .failed = model.values else {
      Issue.record("expected a failed value, got \(model.values)")
      return
    }
  }

  @Test("A page for an older key never lands in a newer key's view")
  func stalePageDropped() async throws {
    let reads = await Self.reads(type: "list")
    await reads.answer("LRANGE", Self.bulks(["old"]))
    await reads.holdNext("LRANGE")
    let model = Model()
    let first = model.load(Self.key, read: Self.read(reads))
    await Self.waitUntil { await reads.isHolding }
    #expect(await reads.isHolding)

    // The newer key is a set: a stale list page landing would show as index rows
    await reads.answer("TYPE", .simple(.text("set")))
    await reads.answer("SSCAN", Self.scan("0", ["new"]))
    await model.load(Self.otherKey, read: Self.read(reads)).value
    await reads.release()
    await first.value
    let list = try #require(Self.rowList(model.values(for: Self.otherKey)))
    #expect(list.kind == .set)
    #expect(list.rows.map(\.name) == ["new"])
    #expect(model.values(for: Self.key) == .loading)
  }

  @Test("A Load more in flight is dropped when another key loads")
  func staleLoadMoreDropped() async throws {
    let reads = await Self.reads(type: "list")
    await reads.answer("LRANGE", Self.bulks((0..<Model.pageSize).map { "a\($0)" }))
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    await reads.holdNext("LRANGE")
    let more = try #require(model.loadMore())
    await Self.waitUntil { await reads.isHolding }
    #expect(await reads.isHolding)
    await reads.answer("TYPE", .simple(.text("set")))
    await reads.answer("SSCAN", Self.scan("0", ["b"]))
    await model.load(Self.otherKey, read: Self.read(reads)).value
    await reads.release()
    await more.value
    let list = try #require(Self.rowList(model.values(for: Self.otherKey)))
    #expect(list.kind == .set)
    #expect(list.rows.map(\.name) == ["b"])
  }

  @Test("reset() drops the header and rows and restarts the placeholder")
  func resetClears() async {
    let reads = await Self.reads()
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    let loadID = model.loadID
    model.reset()
    #expect(model.state == .loading)
    #expect(model.values == .loading)
    #expect(model.loadID != loadID)
    #expect(model.loadMore() == nil)
  }

  @Test("A module type has no value view; nothing is read for it")
  func unsupportedType() async {
    let reads = await Self.reads(type: "ReJSON-RL")
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    #expect(model.values == .unsupported)
    #expect(await reads.sent.count == 3)
  }

  @Test("Value pages of many nodes decode (the header's replies are one node)")
  func decodesPages() async throws {
    let rows: [[CellValue]] = [
      [.string("0"), .string("array"), .int(2)],
      [.string("0.0"), .string("bulk"), .string("0")],
      [.string("0.1"), .string("array"), .int(2)],
      [.string("0.1.0"), .string("bulk"), .string("f")],
      [.string("0.1.1"), .string("bulk"), .data(Data([0xFF]))],
    ]
    let reply = try await Model.decode(
      QueryResult(columns: [], rows: rows, rowCount: rows.count, executionTime: 0))
    let page = try Model.page(reply, kind: .hash, cursor: .scan(0))
    #expect(page.rows == [.init(identity: .field(Data("f".utf8)), name: "f", value: #"\xff"#)])
  }

  // MARK: - Through the gate

  @Test("On a read-only connection the header's reads pass the gate")
  func readOnlyReads() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .redis, host: "fake", port: 6379, database: "3", username: "",
        sslMode: .disable, protectionLevel: .readOnly, safeMode: .silent))
    let session = try #require(factory.sessions.first)
    let policy = ProtectionPolicy(protectionLevel: .readOnly)
    let epoch = await manager.connectionEpoch
    for command in [
      RedisKeyCommands.type(Self.key), RedisKeyCommands.pttl(Self.key),
      RedisKeyCommands.memoryUsage(Self.key), RedisKeyCommands.strlen(Self.key),
      RedisKeyCommands.getRange(Self.key),
    ]
      + [Model.KeyType.hash, .list, .set, .sortedSet, .stream].compactMap({ kind in
        Model.firstCursor(kind).flatMap { Model.pageCommand(Self.key, kind: kind, cursor: $0) }
      })
    {
      _ = try await manager.executeGatedRedisCommand(
        command, policy: policy, connectionEpoch: epoch, userInitiated: false)
    }
    #expect(session.redisCommands.count == 10)

    session.answerRedisSends(with: [[.string("0"), .string("simple"), .string("none")]])
    let model = Model()
    await model.load(Self.key, manager: manager, policy: policy).value
    #expect(model.state == .missing)
    #expect(session.redisCommands.last == RedisKeyCommands.type(Self.key))
  }
}

// MARK: - Edits

/// Writes a scripted edit context received, with their epoch and confirmation
private actor WriteLog {
  struct Entry: Equatable {
    let command: RedisCommand
    let epoch: UInt64
    let confirmed: Bool
  }

  private(set) var entries: [Entry] = []

  func note(_ command: RedisCommand, _ epoch: UInt64, _ confirmed: Bool) {
    entries.append(Entry(command: command, epoch: epoch, confirmed: confirmed))
  }
}

/// History rows and the commit style an edit context hands over
@MainActor
private final class EditSink {
  var outcomes: [QueryHistoryOutcome] = []
  var style: CommitStyle

  init(style: CommitStyle) {
    self.style = style
  }
}

extension RedisKeyViewerModelTests {
  private static let binaryKey = RedisKeyRef(
    db: 3, bytes: Data([0xFF, 0x00, 0x0D, 0x0A]) + Data("FLUSHALL".utf8))

  private static func args(_ words: String...) -> [Data] { words.map { Data($0.utf8) } }

  /// Reads and writes answered by `reads` (by command name), writes logged in `log`
  private static func editContext(
    _ reads: ScriptedReads, log: WriteLog, sink: EditSink
  ) -> RedisKeyWriteContext {
    RedisKeyWriteContext(
      read: { command, _ in try await reads.read(command) },
      write: { command, epoch, confirmed in
        await log.note(command, epoch, confirmed)
        return try await reads.read(command)
      },
      commitStyle: { sink.style }, recordHistory: { sink.outcomes += $0 })
  }

  private static func redisConfig(
    level: ConnectionProtectionLevel = .none, style: CommitStyle = .immediate
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .redis, host: "fake", port: 6379, database: "3", username: "",
      sslMode: .disable, protectionLevel: level, safeMode: .silent)
    config.applyCommitStyle(style)
    return config
  }

  @Test("Edits go through the gate as the user's (in flight), under the epoch of the key's load")
  func editsThroughTheGate() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.redisConfig())
    let session = try #require(factory.sessions.first)
    let policy = ProtectionPolicy(protectionLevel: .none)
    let model = Model()
    await model.load(Self.key, manager: manager, policy: policy).value
    let epoch = await manager.connectionEpoch
    #expect(model.loadEpoch == epoch)

    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(
      context: .gated(
        manager: manager, policy: { policy }, commitStyle: { sink.style },
        recordHistory: { sink.outcomes += $0 }))
    let write = try RedisKeyWrite.rename(Self.key, to: Data("user:9".utf8))
    #expect(write.command == RedisCommand(args: Self.args("RENAMENX", "user:1", "user:9"), db: 3))
    session.holdNextRedisSend()
    let sending = Task { await editor.request(write, epoch: model.loadEpoch) }
    await Self.waitUntil { session.heldRedisSendCount > 0 }
    #expect(session.heldRedisSendCount == 1)
    // Counted as running only for a user-initiated command
    #expect(await manager.runningStatementStatus().inFlight)
    session.releaseHeldRedisSends()
    #expect(await sending.value == .written(.simple(.text("OK"))))
    #expect(session.redisCommands.last == write.command)
    #expect(sink.outcomes.map(\.sql) == [RedisTokenizer.render(write.command.args)])
    #expect(sink.outcomes.first?.status == .success)
  }

  @Test("An edit under the epoch of an older connection is refused before anything is sent")
  func staleEpochRefused() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.redisConfig()
    try await manager.connect(config: config)
    let policy = ProtectionPolicy(protectionLevel: .none)
    let model = Model()
    await model.load(Self.key, manager: manager, policy: policy).value
    let loaded = try #require(model.loadEpoch)
    // A reconnect since the key was read
    try await manager.connect(config: config)
    #expect(await manager.connectionEpoch != loaded)
    let sent = factory.redisCommands.count

    let sink = EditSink(style: .immediate)
    let context = RedisKeyWriteContext.gated(
      manager: manager, policy: { policy }, commitStyle: { sink.style },
      recordHistory: { sink.outcomes += $0 })
    let editor = RedisKeyEditor(context: context)
    #expect(await editor.request(.persist(Self.key), epoch: loaded) == nil)
    #expect(editor.phase == .failed(context.staleMessage))
    // A removal is asked first, then refused the same way once confirmed
    _ = await editor.request(.delete(Self.key), epoch: loaded)
    let pending = try #require(editor.pending)
    #expect(await editor.confirm(pending) == nil)
    #expect(editor.phase == .failed(context.staleMessage))
    // No epoch (the key was never read on this connection) is refused too
    #expect(await editor.request(.persist(Self.key), epoch: nil) == nil)
    #expect(editor.phase == .failed(context.staleMessage))
    #expect(factory.redisCommands.count == sent)
    #expect(sink.outcomes.isEmpty)
  }

  @Test("A read-only connection refuses every edit at the gate; nothing is sent")
  func readOnlyRefuses() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.redisConfig(level: .readOnly))
    let session = try #require(factory.sessions.first)
    let policy = ProtectionPolicy(protectionLevel: .readOnly)
    let epoch = await manager.connectionEpoch
    let sink = EditSink(style: .immediate)
    let context = RedisKeyWriteContext.gated(
      manager: manager, policy: { policy }, commitStyle: { sink.style },
      recordHistory: { sink.outcomes += $0 })
    let key = Self.key
    let value = Data("v".utf8)
    var writes: [RedisKeyWrite] = [
      try .stringValue(key, value: value, old: value), try .expire(key, seconds: 60),
      .persist(key), try .hashField(key, field: value, value: value, old: nil),
      .removeHashField(key, field: value), try .pushElement(key, value: value, atHead: true),
      try .pushElement(key, value: value, atHead: false),
      try .listElement(key, index: 0, value: value, old: value),
      try .addSetMember(key, member: value), .removeSetMember(key, member: value),
      try .sortedSetMember(key, member: value, score: 1, oldScore: nil),
      .removeSortedSetMember(key, member: value),
      try .addStreamEntry(key, fields: [(value, value)]),
      .deleteStreamEntry(key, id: Data("1-0".utf8)), .delete(key),
      try .rename(key, to: Data("other".utf8)),
    ]
    for content: RedisKeyWrite.NewKeyContent in [
      .string(value), .hash(field: value, value: value), .list(value), .set(value),
      .sortedSet(member: value, score: 2), .stream(field: value, value: value),
    ] {
      writes.append(try .create(RedisKeyRef(db: 3, bytes: Data("new".utf8)), content: content))
    }
    for write in writes {
      await #expect(throws: DatabaseError.self) {
        _ = try await context.write(write.command, epoch, true)
      }
    }
    // Through the editor: refused with the gate's reason, still nothing sent
    let editor = RedisKeyEditor(context: context)
    #expect(await editor.request(.persist(key), epoch: epoch) == nil)
    guard case .failed = editor.phase else {
      Issue.record("Expected a refusal, got \(editor.phase)")
      return
    }
    #expect(session.redisCommands.isEmpty)
    #expect(sink.outcomes.isEmpty)
  }

  @Test("UNLINK and every removal ask first even under Immediate; Cancel sends nothing")
  func removalsAlwaysAsk() async throws {
    // The gate asks only for destructive commands, and UNLINK is a data write
    #expect(
      !RedisCommandClassifier.classify(RedisKeyCommands.unlink(Self.key).args).statement
        .isDestructive)
    let field = Data("f".utf8)
    for removal in [
      RedisKeyWrite.delete(Self.key), .removeHashField(Self.key, field: field),
      .removeSetMember(Self.key, member: field), .removeSortedSetMember(Self.key, member: field),
      .deleteStreamEntry(Self.key, id: Data("1-0".utf8)),
    ] {
      #expect(removal.isRemoval)
    }
    let reads = await Self.reads()
    await reads.answer("UNLINK", .integer(1))
    let log = WriteLog()
    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: log, sink: sink))
    let write = RedisKeyWrite.delete(Self.key)
    #expect(await editor.request(write, epoch: 7) == nil)
    let pending = try #require(editor.pending)
    #expect(!pending.needsSafeModePanel)
    #expect(pending.write.details.contains("Key: user:1"))
    editor.cancel()
    #expect(await editor.confirm(pending) == nil)
    #expect(await log.entries.isEmpty)

    _ = await editor.request(write, epoch: 7)
    let asked = try #require(editor.pending)
    #expect(await editor.confirm(asked) == .written(.integer(1)))
    #expect(await log.entries == [.init(command: write.command, epoch: 7, confirmed: true)])

    // A stronger style set while the plain question was shown asks again in the Safe Mode panel
    _ = await editor.request(write, epoch: 7)
    let plain = try #require(editor.pending)
    sink.style = .password
    #expect(await editor.confirm(plain) == nil)
    let again = try #require(editor.pending)
    #expect(again.needsSafeModePanel)
    #expect(again.requiresPassword)
    #expect(await log.entries.count == 1)
    // Under Password a write that is no removal asks too
    editor.cancel()
    _ = await editor.request(.persist(Self.key), epoch: 7)
    #expect(editor.pending?.requiresPassword == true)
    #expect(await log.entries.count == 1)
  }

  @Test("A string edit sends SET … KEEPTTL XX with the key's exact bytes; nil shows it missing")
  func stringEditKeepsTTL() async throws {
    let reads = await Self.reads(type: "string")
    await reads.answer("SET", .null)
    let log = WriteLog()
    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: log, sink: sink))
    let write = try RedisKeyWrite.stringValue(
      Self.binaryKey, value: Data("new".utf8), old: Data("old".utf8))
    #expect(
      write.command
        == RedisCommand(
          args: [Data("SET".utf8), Self.binaryKey.bytes, Data("new".utf8)]
            + Self.args("KEEPTTL", "XX"),
          db: 3))
    #expect(await editor.request(write, epoch: 4) == .keyGone)
    // TYPE checked first, by the same bytes
    #expect(
      await reads.sent.map(\.args) == [
        [Data("TYPE".utf8), Self.binaryKey.bytes], write.command.args,
      ])
    #expect(await log.entries == [.init(command: write.command, epoch: 4, confirmed: false)])

    // The tab then shows the missing state
    let model = Model()
    await model.load(Self.binaryKey, read: Self.read(reads)).value
    #expect(model.loaded)
    model.markMissing(Self.binaryKey)
    #expect(model.state == .missing)
    #expect(model.values == .loading)

    // A key another client replaced with a hash, or deleted: no SET is sent
    await reads.answer("TYPE", .simple(.text("hash")))
    #expect(await editor.request(write, epoch: 4) == nil)
    #expect(editor.phase == .failed("The key is now a hash; reload it."))
    await reads.answer("TYPE", .simple(.text("none")))
    #expect(await editor.request(write, epoch: 4) == .keyGone)
    #expect(await log.entries.count == 1)
    // Over 1 MiB typed is refused before anything
    #expect(throws: RedisKeyEditError.self) {
      try RedisKeyWrite.stringValue(
        Self.key, value: Data(count: RedisKeyWrite.maxInputBytes + 1), old: Data())
    }
  }

  @Test("LSET re-reads the element right before asking and before sending; a change refuses it")
  func listSetRecheck() async throws {
    let reads = await Self.reads(type: "list")
    let log = WriteLog()
    let sink = EditSink(style: .confirm)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: log, sink: sink))
    let write = try RedisKeyWrite.listElement(
      Self.key, index: 2, value: Data("new".utf8), old: Data("a".utf8))
    #expect(write.command == RedisCommand(args: Self.args("LSET", "user:1", "2", "new"), db: 3))
    #expect(write.details.contains("Index: 2"))
    #expect(write.details.contains("Old value: a"))

    // Still "a" when asked, "b" (another client pushed) when confirmed
    await reads.queue("LRANGE", [Self.bulks(["a"]), Self.bulks(["b"])])
    #expect(await editor.request(write, epoch: 1) == nil)
    let pending = try #require(editor.pending)
    #expect(await editor.confirm(pending) == nil)
    #expect(
      editor.phase == .failed("The element at index 2 changed since it was read; reload the key."))
    #expect(
      await reads.sent.filter { $0.args[0] == Data("LRANGE".utf8) }.map(\.args)
        == Array(repeating: Self.args("LRANGE", "user:1", "2", "2"), count: 2))
    // Gone from the index: refused when asked
    await reads.queue("LRANGE", [Self.bulks([])])
    #expect(await editor.request(write, epoch: 1) == nil)
    #expect(
      editor.phase == .failed("The list has no element at index 2 any more; reload the key."))
    #expect(await log.entries.isEmpty)

    // Unchanged: sent once confirmed
    await reads.queue("LRANGE", [Self.bulks(["a"]), Self.bulks(["a"])])
    await reads.answer("LSET", .simple(.text("OK")))
    _ = await editor.request(write, epoch: 1)
    let asked = try #require(editor.pending)
    #expect(asked.needsSafeModePanel)
    #expect(await editor.confirm(asked) == .written(.simple(.text("OK"))))
    #expect(await log.entries == [.init(command: write.command, epoch: 1, confirmed: true)])
  }

  @Test("New Key: SET NX refuses a taken name; other types need TYPE none right before sending")
  func newKeyChecks() async throws {
    let reads = await Self.reads(type: "none")
    await reads.answer("SET", .null)
    await reads.answer("HSET", .integer(1))
    let log = WriteLog()
    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: log, sink: sink))
    let key = RedisKeyRef(db: 2, bytes: Data("new".utf8))
    let string = try RedisKeyWrite.create(key, content: .string(Data("v".utf8)))
    #expect(string.command == RedisCommand(args: Self.args("SET", "new", "v", "NX"), db: 2))
    #expect(await editor.request(string, epoch: 1) == nil)
    #expect(editor.phase == .failed(RedisKeyEditor.nameTakenMessage))

    let hash = try RedisKeyWrite.create(
      key, content: .hash(field: Data("f".utf8), value: Data("v".utf8)))
    #expect(await editor.request(hash, epoch: 1) == .written(.integer(1)))
    // Exists by the time it would be sent: refused, nothing more written
    await reads.answer("TYPE", .simple(.text("list")))
    #expect(await editor.request(hash, epoch: 1) == nil)
    #expect(editor.phase == .failed(RedisKeyEditor.nameTakenMessage))
    #expect(await log.entries.map(\.command) == [string.command, hash.command])
    #expect(throws: RedisKeyEditError.self) {
      try RedisKeyWrite.create(key, content: .sortedSet(member: Data(), score: .nan))
    }
    // An empty name is never created or renamed to by a stray Save
    #expect(throws: RedisKeyEditError(message: "Type a key name.")) {
      try RedisKeyWrite.create(RedisKeyRef(db: 2, bytes: Data()), content: .string(Data()))
    }
    #expect(throws: RedisKeyEditError(message: "Type a key name.")) {
      try RedisKeyWrite.rename(key, to: Data())
    }
  }

  @Test("History stores the rendered arguments of a sent write, never one holding a password")
  func historyRendersArgs() async throws {
    let ok = Result<RedisReply, any Error>.success(.simple(.text("OK")))
    let set = Self.args("SET", "a b", "v", "KEEPTTL", "XX")
    let stored = try #require(RedisKeyEditor.historyOutcome(set, result: ok, elapsed: 0.5))
    #expect(stored.sql == RedisTokenizer.render(set))
    #expect(stored.status == .success)
    #expect(stored.rowCount == nil)
    #expect(RedisKeyEditor.historyOutcome(Self.args("AUTH", "pw"), result: ok, elapsed: 0) == nil)
    #expect(
      RedisKeyEditor.historyOutcome(
        Self.args("CONFIG", "SET", "requirepass", "pw"), result: ok, elapsed: 0) == nil)
    // Refused by the gate before sending: nothing to store
    let stale = Result<RedisReply, any Error>.failure(
      DatabaseError.sessionChanged(skippedStatements: 1))
    #expect(RedisKeyEditor.historyOutcome(set, result: stale, elapsed: 0) == nil)
    let failed = Result<RedisReply, any Error>.failure(DatabaseError.queryFailed("WRONGTYPE", 0))
    #expect(RedisKeyEditor.historyOutcome(set, result: failed, elapsed: 0)?.status == .error)

    // Through the editor: the write's render, after it was sent
    let reads = await Self.reads(type: "hash")
    await reads.answer("HSETNX", .integer(1))
    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: WriteLog(), sink: sink))
    let write = try RedisKeyWrite.hashField(
      Self.binaryKey, field: Data([0xC3]), value: Data("x".utf8), old: nil)
    #expect(await editor.request(write, epoch: 2) == .written(.integer(1)))
    #expect(sink.outcomes.map(\.sql) == [RedisTokenizer.render(write.command.args)])
  }

  @Test("A pre-fill over 1 MiB is refused off the main actor; HSTRLEN keeps a large field unread")
  func prefillSizeCap() async throws {
    let reads = await Self.reads(type: "hash")
    let sink = EditSink(style: .immediate)
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: WriteLog(), sink: sink))
    let field = Data("f".utf8)
    let tooLarge = RedisKeyEditor.Prefill.failed(RedisKeyEditor.tooLargeMessage)
    let over = RedisKeyWrite.maxInputBytes + 1

    // HSTRLEN past the cap: HGET is never sent
    await reads.answer("HSTRLEN", .integer(over))
    #expect(await editor.prefill(.hashField(Self.key, field: field), epoch: 1) == tooLarge)
    #expect(await reads.sent.map(\.args) == [Self.args("HSTRLEN", "user:1", "f")])
    // A small HSTRLEN, then a larger value (it grew, or the server lied): still refused
    await reads.answer("HSTRLEN", .integer(3))
    await reads.answer("HGET", .bulk(.bytes(Data(repeating: 0x61, count: over))))
    #expect(await editor.prefill(.hashField(Self.key, field: field), epoch: 1) == tooLarge)
    await reads.answer("HGET", .bulk(.text("abc")))
    #expect(
      await editor.prefill(.hashField(Self.key, field: field), epoch: 1)
        == .value(Data("abc".utf8), text: "abc"))
    await reads.answer("HGET", .null)
    #expect(await editor.prefill(.hashField(Self.key, field: field), epoch: 1) == .gone)

    // A list element has no length command: read, then refused before it is decoded
    await reads.answer("LRANGE", .array([.bulk(.text(String(repeating: "a", count: over)))]))
    #expect(await editor.prefill(.listElement(Self.key, index: 4), epoch: 1) == tooLarge)
    await reads.answer("LRANGE", .array([.bulk(.bytes(Data([0xFF])))]))
    #expect(
      await editor.prefill(.listElement(Self.key, index: 4), epoch: 1)
        == .failed(RedisKeyEditor.binaryMessage))
    await reads.answer("LRANGE", .array([]))
    #expect(await editor.prefill(.listElement(Self.key, index: 4), epoch: 1) == .gone)

    // A loaded string, and a score longer than any number
    #expect(await editor.prefill(.loaded(Data(count: over)), epoch: nil) == tooLarge)
    #expect(Model.stringValue(Data("é".utf8), length: 2).isText)
    #expect(!Model.stringValue(Data([0xFF]), length: 1).isText)
    await reads.answer("ZSCORE", .bulk(.text(String(repeating: "1", count: 65))))
    guard case .failed = await editor.prefill(.score(Self.key, member: field), epoch: 1) else {
      Issue.record("A 65-byte score was taken")
      return
    }
    await reads.answer("ZSCORE", .bulk(.text("1.5")))
    #expect(await editor.prefill(.score(Self.key, member: field), epoch: 1) == .score("1.5"))

    // No epoch: refused as stale, nothing sent
    let sent = await reads.sent.count
    #expect(
      await editor.prefill(.listElement(Self.key, index: 0), epoch: nil)
        == .failed(editor.context.staleMessage))
    #expect(await reads.sent.count == sent)
  }

  @Test("A write's answer acts only on the key the tab still shows, never after stop()")
  func writeAnswerFollowsLiveKey() async {
    let reads = await Self.reads()
    let model = Model()
    await model.load(Self.key, read: Self.read(reads)).value
    #expect(model.isShowing(Self.key))
    #expect(!model.isShowing(Self.otherKey))
    // The preview moved to another key while a write for the first was in flight
    await model.load(Self.otherKey, read: Self.read(reads)).value
    #expect(!model.isShowing(Self.key))
    model.markMissing(Self.key)
    guard case .loaded = model.state(for: Self.otherKey) else {
      Issue.record("The other key's header was replaced: \(model.state)")
      return
    }
    // The tab closed
    model.stop()
    #expect(!model.isShowing(Self.otherKey))
    model.markMissing(Self.otherKey)
    #expect(model.state != .missing)
  }

  @Test("Add Field and Add Member never overwrite: HSETNX and ZADD NX, 0 refuses with a reason")
  func addsNeverOverwrite() async throws {
    let field = Data("f".utf8)
    let value = Data("v".utf8)
    let addField = try RedisKeyWrite.hashField(Self.key, field: field, value: value, old: nil)
    #expect(addField.command == RedisCommand(args: Self.args("HSETNX", "user:1", "f", "v"), db: 3))
    let editField = try RedisKeyWrite.hashField(Self.key, field: field, value: value, old: value)
    #expect(editField.command == RedisCommand(args: Self.args("HSET", "user:1", "f", "v"), db: 3))
    let addMember = try RedisKeyWrite.sortedSetMember(
      Self.key, member: field, score: 2, oldScore: nil)
    #expect(
      addMember.command == RedisCommand(args: Self.args("ZADD", "user:1", "NX", "2.0", "f"), db: 3))
    let editScore = try RedisKeyWrite.sortedSetMember(
      Self.key, member: field, score: 2, oldScore: "1")
    #expect(editScore.command == RedisCommand(args: Self.args("ZADD", "user:1", "2.0", "f"), db: 3))
    for write in [addField, addMember] {
      #expect(RedisCommandClassifier.classify(write.command.args).statement.kind == .dml)
    }

    let reads = await Self.reads(type: "hash")
    await reads.answer("HSETNX", .integer(0))
    let sink = EditSink(style: .immediate)
    let log = WriteLog()
    let editor = RedisKeyEditor(context: Self.editContext(reads, log: log, sink: sink))
    #expect(await editor.request(addField, epoch: 1) == nil)
    #expect(editor.phase == .failed(RedisKeyWrite.fieldTakenMessage))
    await reads.answer("TYPE", .simple(.text("zset")))
    await reads.answer("ZADD", .integer(0))
    #expect(await editor.request(addMember, epoch: 1) == nil)
    #expect(editor.phase == .failed(RedisKeyWrite.memberTakenMessage))
    await reads.answer("ZADD", .integer(1))
    #expect(await editor.request(addMember, epoch: 1) == .written(.integer(1)))
    #expect(
      await log.entries.map(\.command) == [addField.command, addMember.command, addMember.command])
  }

  @Test(
    "Server text in a confirmation is escaped and cut; a long entry lists how many fields are left")
  func confirmationDetailsEscaped() throws {
    let hostile = "1\nKey: other\u{202E}" + String(repeating: "9", count: 500)
    let write = try RedisKeyWrite.sortedSetMember(
      Self.key, member: Data("m".utf8), score: 2, oldScore: hostile)
    #expect(write.details.allSatisfy { !$0.contains("\n") && !$0.contains("\u{202E}") })
    #expect(write.details.filter { $0.hasPrefix("Key: ") } == ["Key: user:1"])
    let old = try #require(write.details.first { $0.hasPrefix("Old score: ") })
    #expect(old.count <= "Old score: ".count + RedisKeyWrite.maxDetailLength + 1)

    let fields = (0..<25).map { (Data("f\($0)".utf8), Data("v".utf8)) }
    let entry = try RedisKeyWrite.addStreamEntry(Self.key, fields: fields)
    #expect(entry.details.count == 2 + RedisKeyWrite.maxDetailFields + 1)
    #expect(entry.details.last == "… and 5 more fields")
    let one = try RedisKeyWrite.addStreamEntry(Self.key, fields: Array(fields.prefix(21)))
    #expect(one.details.last == "… and 1 more field")
    let few = try RedisKeyWrite.addStreamEntry(Self.key, fields: Array(fields.prefix(3)))
    #expect(few.details.count == 5)
  }
}
