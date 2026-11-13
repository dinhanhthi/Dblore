// RedisKeyCommands.swift
// The commands the key browser and the key tab send: pure builders from a key's identity to the
// exact argument array, with every key, member, field, value, pattern and stream id as its own
// argument

import Foundation

/// Builds the key browser's commands. Every key, member, field, value, pattern and stream id goes
/// in as its own argument with its exact bytes, never spliced into another argument or into
/// command text. A command runs in its key's database (`RedisKeyRef.db`). Every command here
/// needs Redis 6.0 or later (`SCAN … TYPE`, `SET … KEEPTTL`).
nonisolated enum RedisKeyCommands {

  /// The `COUNT` hint of each `SCAN` page
  static let scanCount = 500
  /// The most bytes of a string value the key tab reads (`GETRANGE k 0 262143`)
  static let valuePreviewBytes = 262_144

  // MARK: - Reads

  /// `SCAN cursor MATCH pattern COUNT 500 [TYPE type]`. `MATCH` is always sent; pass `*` for
  /// every key.
  static func scan(
    db: Int, cursor: UInt64, match pattern: Data, type: Data? = nil
  )
    -> RedisCommand
  {
    var args = [word("SCAN"), number(cursor), word("MATCH"), pattern]
    args += [word("COUNT"), number(scanCount)]
    if let type { args += [word("TYPE"), type] }
    return RedisCommand(args: args, db: db)
  }

  /// `TYPE k`: the key's type, `none` when it does not exist
  static func type(_ key: RedisKeyRef) -> RedisCommand { command("TYPE", key) }

  /// `PTTL k`: milliseconds left, -1 without an expiry, -2 when the key does not exist
  static func pttl(_ key: RedisKeyRef) -> RedisCommand { command("PTTL", key) }

  /// `STRLEN k`
  static func strlen(_ key: RedisKeyRef) -> RedisCommand { command("STRLEN", key) }

  /// `MEMORY USAGE k`
  static func memoryUsage(_ key: RedisKeyRef) -> RedisCommand {
    RedisCommand(args: [word("MEMORY"), word("USAGE"), key.bytes], db: key.db)
  }

  /// `GETRANGE k 0 262143`: the first `valuePreviewBytes` of a string value
  static func getRange(_ key: RedisKeyRef) -> RedisCommand {
    command("GETRANGE", key, number(0), number(valuePreviewBytes - 1))
  }

  /// `HSCAN k cursor COUNT n`
  static func hscan(_ key: RedisKeyRef, cursor: UInt64, count: Int) -> RedisCommand {
    command("HSCAN", key, number(cursor), word("COUNT"), number(count))
  }

  /// `LRANGE k start stop` (inclusive indexes, negative from the end)
  static func lrange(_ key: RedisKeyRef, start: Int, stop: Int) -> RedisCommand {
    command("LRANGE", key, number(start), number(stop))
  }

  /// `SSCAN k cursor COUNT n`
  static func sscan(_ key: RedisKeyRef, cursor: UInt64, count: Int) -> RedisCommand {
    command("SSCAN", key, number(cursor), word("COUNT"), number(count))
  }

  /// `ZRANGE k start stop WITHSCORES`, by index
  static func zrange(_ key: RedisKeyRef, start: Int, stop: Int) -> RedisCommand {
    command("ZRANGE", key, number(start), number(stop), word("WITHSCORES"))
  }

  /// `XRANGE k start + COUNT n`: the first page starts at `-` (`lastID` nil), each later page at
  /// the id right after `lastID` (`nextStreamID(after:)`), inclusive, since the exclusive `(id`
  /// start needs Redis 6.2. nil when `lastID` is malformed or the last possible id.
  static func xrange(_ key: RedisKeyRef, after lastID: Data?, count: Int) -> RedisCommand? {
    var start = word("-")
    if let lastID {
      guard let next = nextStreamID(after: lastID) else { return nil }
      start = next
    }
    return command("XRANGE", key, start, word("+"), word("COUNT"), number(count))
  }

  /// The stream id right after `id`: `ms-(seq+1)`, or `(ms+1)-0` when `seq` is the largest
  /// UInt64. nil when `id` is not exactly `<ms>-<seq>` (two UInt64 decimals, digits only) or is
  /// the last possible id, never a guessed id.
  static func nextStreamID(after id: Data) -> Data? {
    let parts = id.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
    guard parts.count == 2, let ms = decimal(parts[0]), let seq = decimal(parts[1]) else {
      return nil
    }
    if seq < .max { return Data("\(ms)-\(seq + 1)".utf8) }
    guard ms < .max else { return nil }
    return Data("\(ms + 1)-0".utf8)
  }

  /// `INFO keyspace`: the databases that hold keys and their counts. Exactly one section, which
  /// read-only connections allow; never a bare `INFO` or `CONFIG GET`.
  static func infoKeyspace(db: Int) -> RedisCommand {
    RedisCommand(args: [word("INFO"), word("keyspace")], db: db)
  }

  // MARK: - Writes

  /// `SET k v KEEPTTL XX`: replaces an existing string value and keeps its expiry
  static func set(_ key: RedisKeyRef, value: Data) -> RedisCommand {
    command("SET", key, value, word("KEEPTTL"), word("XX"))
  }

  /// `HSET k f v`
  static func hset(_ key: RedisKeyRef, field: Data, value: Data) -> RedisCommand {
    command("HSET", key, field, value)
  }

  /// `HSETNX k f v`: adds a field, never over an existing one (answers 0 then)
  static func hsetnx(_ key: RedisKeyRef, field: Data, value: Data) -> RedisCommand {
    command("HSETNX", key, field, value)
  }

  /// `HDEL k f`
  static func hdel(_ key: RedisKeyRef, field: Data) -> RedisCommand {
    command("HDEL", key, field)
  }

  /// `LSET k i v`
  static func lset(_ key: RedisKeyRef, index: Int, value: Data) -> RedisCommand {
    command("LSET", key, number(index), value)
  }

  /// `RPUSH k v`
  static func rpush(_ key: RedisKeyRef, value: Data) -> RedisCommand {
    command("RPUSH", key, value)
  }

  /// `LPUSH k v`
  static func lpush(_ key: RedisKeyRef, value: Data) -> RedisCommand {
    command("LPUSH", key, value)
  }

  /// `SADD k m`
  static func sadd(_ key: RedisKeyRef, member: Data) -> RedisCommand {
    command("SADD", key, member)
  }

  /// `SREM k m`
  static func srem(_ key: RedisKeyRef, member: Data) -> RedisCommand {
    command("SREM", key, member)
  }

  /// `ZADD k score m`. The score is Swift's shortest text that parses back to the same Double;
  /// nil for NaN or an infinity.
  static func zadd(_ key: RedisKeyRef, score: Double, member: Data) -> RedisCommand? {
    guard score.isFinite else { return nil }
    return command("ZADD", key, Data("\(score)".utf8), member)
  }

  /// `ZADD k NX score m`: adds a member, never over an existing one (answers 0 then); nil for
  /// NaN or an infinity
  static func zaddNX(_ key: RedisKeyRef, score: Double, member: Data) -> RedisCommand? {
    guard score.isFinite else { return nil }
    return command("ZADD", key, word("NX"), Data("\(score)".utf8), member)
  }

  /// `ZREM k m`
  static func zrem(_ key: RedisKeyRef, member: Data) -> RedisCommand {
    command("ZREM", key, member)
  }

  /// `XADD k id f v …` with `id` as typed, its exact bytes (`*` when nil, which lets the server
  /// pick it). nil without a field, or when `id` is not `*`, `<ms>`, `<ms>-*` or `<ms>-<seq>`
  /// (ASCII digits, each a UInt64): Redis reads the argument after the key as an option first,
  /// so an id like `MAXLEN` would trim the stream.
  static func xadd(
    _ key: RedisKeyRef, id: Data?, fields: [(field: Data, value: Data)]
  )
    -> RedisCommand?
  {
    let id = id ?? word("*")
    guard !fields.isEmpty, isStreamAddID(id) else { return nil }
    return RedisCommand(
      args: [word("XADD"), key.bytes, id] + fields.flatMap { [$0.field, $0.value] },
      db: key.db)
  }

  /// `XDEL k id`
  static func xdel(_ key: RedisKeyRef, id: Data) -> RedisCommand {
    command("XDEL", key, id)
  }

  /// `PEXPIRE k ms`. nil when `milliseconds` is 0 or less, which would delete the key (`unlink`
  /// does that).
  static func pexpire(_ key: RedisKeyRef, milliseconds: Int) -> RedisCommand? {
    guard milliseconds > 0 else { return nil }
    return command("PEXPIRE", key, number(milliseconds))
  }

  /// `PERSIST k`: removes the expiry
  static func persist(_ key: RedisKeyRef) -> RedisCommand { command("PERSIST", key) }

  /// `RENAMENX k newk`: fails on the server when `newKey` exists. nil when the keys are in
  /// different databases.
  static func renameNX(_ key: RedisKeyRef, to newKey: RedisKeyRef) -> RedisCommand? {
    guard key.db == newKey.db else { return nil }
    return command("RENAMENX", key, newKey.bytes)
  }

  /// `UNLINK k`
  static func unlink(_ key: RedisKeyRef) -> RedisCommand { command("UNLINK", key) }

  // MARK: - Create

  /// `SET k v NX`: creates a string key, never overwrites an existing key
  static func createString(_ key: RedisKeyRef, value: Data) -> RedisCommand {
    command("SET", key, value, word("NX"))
  }

  // The commands below add to an existing key of their type (and fail on another type): the
  // caller sends `type(key)` first and creates only when it answers `none`.

  /// `HSET k f v`: creates a hash key when `type(key)` answered `none`
  static func createHash(_ key: RedisKeyRef, field: Data, value: Data) -> RedisCommand {
    hset(key, field: field, value: value)
  }

  /// `RPUSH k v`: creates a list key when `type(key)` answered `none`
  static func createList(_ key: RedisKeyRef, value: Data) -> RedisCommand {
    rpush(key, value: value)
  }

  /// `SADD k m`: creates a set key when `type(key)` answered `none`
  static func createSet(_ key: RedisKeyRef, member: Data) -> RedisCommand {
    sadd(key, member: member)
  }

  /// `ZADD k score m`: creates a sorted set key when `type(key)` answered `none`; nil for a
  /// non-finite score
  static func createSortedSet(_ key: RedisKeyRef, score: Double, member: Data) -> RedisCommand? {
    zadd(key, score: score, member: member)
  }

  /// `XADD k * f v`: creates a stream key when `type(key)` answered `none`
  static func createStream(_ key: RedisKeyRef, field: Data, value: Data) -> RedisCommand {
    command("XADD", key, word("*"), field, value)
  }

  // MARK: - Arguments

  /// `name key rest…` in the key's database
  private static func command(
    _ name: String, _ key: RedisKeyRef, _ rest: Data...
  )
    -> RedisCommand
  {
    RedisCommand(args: [word(name), key.bytes] + rest, db: key.db)
  }

  /// A command name or keyword
  private static func word(_ text: String) -> Data { Data(text.utf8) }

  /// An integer as decimal text
  private static func number(_ value: some BinaryInteger) -> Data { Data("\(value)".utf8) }

  /// An `XADD` id: `*`, `<ms>`, `<ms>-*` or `<ms>-<seq>`, each number a UInt64 in ASCII digits
  private static func isStreamAddID(_ id: Data) -> Bool {
    if id == word("*") { return true }
    let parts = id.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), decimal(parts[0]) != nil else { return false }
    return parts.count == 1 || parts[1].elementsEqual(word("*")) || decimal(parts[1]) != nil
  }

  /// A UInt64 written as ASCII digits only (no sign, no space), nil otherwise or on overflow
  private static func decimal(_ bytes: Data.SubSequence) -> UInt64? {
    guard !bytes.isEmpty, bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
    return UInt64(String(decoding: bytes, as: UTF8.self))
  }
}
