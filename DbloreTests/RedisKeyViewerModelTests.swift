// RedisKeyViewerModelTests.swift
// The key tab header's pure logic (TYPE / PTTL / count reply parsing, TTL countdown math and
// text), its loads on scripted replies (missing key, a refused MEMORY USAGE, an older load
// dropped, the re-check when the TTL ends) and its reads through the gate on a read-only
// connection.

import Foundation
import Testing

@testable import Dblore

/// Answers each command by its name (`MEMORY` for `MEMORY USAGE`); can hold the next `TYPE`
private actor ScriptedReads {
  private var answers: [String: Result<RedisReply, any Error>] = [:]
  private(set) var sent: [RedisCommand] = []
  private var holdsNextType = false
  private var held: CheckedContinuation<Void, Never>?

  var isHolding: Bool { held != nil }

  func answer(_ name: String, _ reply: RedisReply) { answers[name] = .success(reply) }
  func fail(_ name: String, _ error: any Error) { answers[name] = .failure(error) }
  func holdNextType() { holdsNextType = true }

  func release() {
    held?.resume()
    held = nil
  }

  func read(_ command: RedisCommand) async throws -> RedisReply {
    sent.append(command)
    let name = String(decoding: command.args[0], as: UTF8.self)
    if name == "TYPE", holdsNextType {
      holdsNextType = false
      await withCheckedContinuation { held = $0 }
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
    return reads
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

  @Test("A hash key: TYPE, PTTL and MEMORY USAGE in its db, no STRLEN")
  func loadsHeader() async {
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
      ])
    #expect(sent.allSatisfy { $0.db == 3 })
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
    #expect(await reads.sent.last == RedisKeyCommands.strlen(Self.key))
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
    ] {
      _ = try await manager.executeGatedRedisCommand(
        command, policy: policy, connectionEpoch: epoch, userInitiated: false)
    }
    #expect(session.redisCommands.count == 4)

    session.answerRedisSends(with: [[.string("0"), .string("simple"), .string("none")]])
    let model = Model()
    await model.load(Self.key, manager: manager, policy: policy).value
    #expect(model.state == .missing)
    #expect(session.redisCommands.last == RedisKeyCommands.type(Self.key))
  }
}
