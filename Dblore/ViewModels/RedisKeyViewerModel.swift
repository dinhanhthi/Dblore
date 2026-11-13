// RedisKeyViewerModel.swift
// The key tab's header: a key's type, TTL and size, read through the Redis gate as the app's own
// reads (`userInitiated: false`) under the workspace's protection policy, so read-only
// connections show them too. `TYPE` first (`none`: the key no longer exists), then `PTTL`,
// `MEMORY USAGE` and, for a string, `STRLEN`. Each load has its own token, and each read
// sequence (the load, a re-check) the connection epoch read when it starts: a result for an
// older load (another key in the same preview tab) is dropped. A key with a TTL is checked again
// once its countdown reaches zero. Replies are untrusted: decoded strictly, an unknown type name
// escaped and cut.

import Foundation
import Observation

@MainActor
@Observable
final class RedisKeyViewerModel {
  /// Sends one command and answers its reply (the gate in the app, a fake in tests)
  typealias Read = @Sendable (RedisCommand) async throws -> RedisReply
  /// Makes the `Read` of one read sequence (the gate's: under the epoch current then)
  typealias MakeRead = @Sendable () async -> Read

  /// The longest type name shown, in characters, before it is cut with "…"
  nonisolated static let maxTypeLength = 64
  /// The longest error text shown, in characters
  nonisolated static let maxErrorLength = 300
  /// How long after the countdown's end the key is checked again (and the least wait between two
  /// checks, so a key the server still holds is not read in a loop)
  nonisolated static let expiryRecheckDelay: Duration = .milliseconds(250)

  /// What `TYPE` answered
  nonisolated enum KeyType: Equatable, Sendable {
    case string, list, set, sortedSet, hash, stream
    /// Any other type name (a module's), escaped and cut
    case other(String)

    var title: String {
      switch self {
      case .string: "String"
      case .list: "List"
      case .set: "Set"
      case .sortedSet: "Sorted set"
      case .hash: "Hash"
      case .stream: "Stream"
      case .other(let name): name
      }
    }
  }

  /// What `PTTL` answered for a key that exists
  nonisolated enum TTLReading: Equatable, Sendable {
    case noExpiry
    case milliseconds(Int)
  }

  /// When the key expires
  nonisolated enum Expiry: Equatable, Sendable {
    case never
    case at(ContinuousClock.Instant)
  }

  nonisolated struct Header: Equatable, Sendable {
    let type: KeyType
    let expiry: Expiry
    /// `MEMORY USAGE` in bytes; nil when the server refused it or answered no number
    let memoryBytes: Int?
    /// `STRLEN` of a string key; nil for other types or when unavailable
    let stringLength: Int?
  }

  enum State: Equatable {
    case loading
    case loaded(Header)
    /// `TYPE` answered `none`, `PTTL` -2, or the key expired during the countdown
    case missing
    /// Why the header could not be read (escaped and cut)
    case failed(String)
  }

  /// The key the state is for; the view shows `state(for:)` its own key, so a new key in the
  /// same tab shows the placeholder in the frame it arrives
  private(set) var key: RedisKeyRef?
  private(set) var state: State = .loading
  /// Changes with each load: the placeholder's delayed spinner restarts with it
  private(set) var loadID = UUID()

  /// Results of a load are dropped once a newer one started (or `stop()`)
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private var expiryTask: Task<Void, Never>?

  /// The header has been read (or found missing, or failed) for the current key
  var loaded: Bool { state != .loading }

  /// `state` when it is for `key`, else `.loading`
  func state(for key: RedisKeyRef) -> State {
    self.key == key ? state : .loading
  }

  /// Reads `key`'s header through the gate. Synchronous up to the read: the state is `.loading`
  /// for `key` when this returns. The connection epoch is read when the reads start (and again
  /// for the re-check when the TTL ends); a reconnect meanwhile makes the gate refuse them
  /// (`DatabaseError.sessionChanged`).
  @discardableResult
  func load(
    _ key: RedisKeyRef, manager: DatabaseConnectionManager, policy: ProtectionPolicy
  ) -> Task<Void, Never> {
    load(
      key,
      makeRead: {
        let epoch = await manager.connectionEpoch
        return { command in
          let result = try await manager.executeGatedRedisCommand(
            command, policy: policy, connectionEpoch: epoch, userInitiated: false)
          return try await Self.decode(result)
        }
      })
  }

  /// Reads `key`'s header with `read`; as `load(_:manager:policy:)`
  @discardableResult
  func load(_ key: RedisKeyRef, read: @escaping Read) -> Task<Void, Never> {
    load(key, makeRead: { read })
  }

  /// Reads `key`'s header with the `Read` `makeRead` makes for each read sequence
  @discardableResult
  func load(_ key: RedisKeyRef, makeRead: @escaping MakeRead) -> Task<Void, Never> {
    let token = begin(key)
    // Unstructured: leaving the tab must not cancel a read half way
    return Task { await self.run(key, token: token, makeRead: makeRead) }
  }

  /// Drops every read in flight and the expiry check (the tab is gone)
  func stop() {
    token = UUID()
    expiryTask?.cancel()
    expiryTask = nil
  }

  // MARK: - Loading

  private func begin(_ key: RedisKeyRef) -> UUID {
    stop()
    self.key = key
    state = .loading
    loadID = token
    return token
  }

  /// Reads the header and shows it, unless a newer load started meanwhile
  private func run(_ key: RedisKeyRef, token: UUID, makeRead: @escaping MakeRead) async {
    let read = await makeRead()
    guard self.token == token else { return }
    let outcome = await Self.fetch(
      key, isCurrent: { [weak self] in self?.token == token }, read: read)
    guard self.token == token, let outcome else { return }
    switch outcome {
    case .missing:
      state = .missing
    case .failed(let message):
      state = .failed(message)
    case .found(let type, let ttl, let memory, let length):
      let expiry: Expiry
      switch ttl {
      case .noExpiry: expiry = .never
      case .milliseconds(let ms): expiry = .at(ContinuousClock.now + .milliseconds(ms))
      }
      state = .loaded(
        Header(type: type, expiry: expiry, memoryBytes: memory, stringLength: length))
      if case .at(let deadline) = expiry {
        scheduleRecheck(key, at: deadline, token: token, makeRead: makeRead)
      }
    }
  }

  /// Once the countdown ends (plus `expiryRecheckDelay`), reads the header again (a new read
  /// sequence, under the epoch current then), keeping the shown header until it answers: `none`
  /// shows the missing state, a key the server still holds (its TTL changed) its new header
  private func scheduleRecheck(
    _ key: RedisKeyRef, at deadline: ContinuousClock.Instant, token: UUID,
    makeRead: @escaping MakeRead
  ) {
    let wake = max(deadline, ContinuousClock.now) + Self.expiryRecheckDelay
    // Only the sleep is cancelled, never the read after it
    expiryTask = Task { [weak self] in
      // A day at a time: a TTL of years (any value the server sends) never asks the clock for
      // a far deadline
      while ContinuousClock.now < wake {
        let step = min(wake, ContinuousClock.now + .seconds(86_400))
        guard (try? await Task.sleep(until: step, clock: .continuous)) != nil else { return }
      }
      guard let self, self.token == token else { return }
      self.expiryTask = nil
      await self.run(key, token: token, makeRead: makeRead)
    }
  }

  nonisolated enum Outcome: Equatable, Sendable {
    case found(KeyType, TTLReading, memory: Int?, length: Int?)
    case missing
    case failed(String)
  }

  /// `TYPE`, then `PTTL`, `MEMORY USAGE` and (strings) `STRLEN`. Nil when `isCurrent` turned
  /// false between two reads: nothing more is sent for a dropped load.
  nonisolated static func fetch(
    _ key: RedisKeyRef, isCurrent: @MainActor @Sendable () -> Bool, read: Read
  ) async -> Outcome? {
    do {
      guard let type = try keyType(await read(RedisKeyCommands.type(key))) else {
        return .missing
      }
      guard await isCurrent() else { return nil }
      guard let ttl = try ttlReading(await read(RedisKeyCommands.pttl(key))) else {
        return .missing
      }
      guard await isCurrent() else { return nil }
      let memory = try await optionalCount(RedisKeyCommands.memoryUsage(key), read: read)
      var length: Int?
      if type == .string {
        guard await isCurrent() else { return nil }
        length = try await optionalCount(RedisKeyCommands.strlen(key), read: read)
      }
      return .found(type, ttl, memory: memory, length: length)
    } catch {
      return .failed(message(error))
    }
  }

  // MARK: - Parsing (untrusted server data)

  /// A `TYPE` reply: a simple or bulk string; nil for `none` (no such key). The six core types by
  /// their exact name; any other name escaped and cut after `maxTypeLength` characters.
  nonisolated static func keyType(_ reply: RedisReply) throws -> KeyType? {
    let name: RedisReplyString
    switch reply {
    case .simple(let string), .bulk(let string): name = string
    default: throw RedisReplyDecodingError(message: "TYPE did not answer a type name")
    }
    if case .text(let text) = name {
      switch text {
      case "none": return nil
      case "string": return .string
      case "list": return .list
      case "set": return .set
      case "zset": return .sortedSet
      case "hash": return .hash
      case "stream": return .stream
      default: break
      }
    }
    let shown = RedisDisplayText.line(name)
    guard !shown.isEmpty else {
      throw RedisReplyDecodingError(message: "TYPE answered an empty type name")
    }
    guard shown.count > maxTypeLength else { return .other(shown) }
    return .other(String(shown.prefix(maxTypeLength)) + "…")
  }

  /// A `PTTL` reply: an integer; nil for -2 (no such key), `.noExpiry` for -1, else the
  /// milliseconds left. Any other reply throws.
  nonisolated static func ttlReading(_ reply: RedisReply) throws -> TTLReading? {
    guard case .integer(let value) = reply else {
      throw RedisReplyDecodingError(message: "PTTL did not answer an integer")
    }
    switch value {
    case -2: return nil
    case -1: return .noExpiry
    case 0...: return .milliseconds(value)
    default: throw RedisReplyDecodingError(message: "PTTL answered \(value)")
    }
  }

  /// A count reply (`MEMORY USAGE`, `STRLEN`): a non-negative integer, else nil (a null for a
  /// key gone meanwhile, or anything else)
  nonisolated static func count(_ reply: RedisReply) -> Int? {
    guard case .integer(let value) = reply, value >= 0 else { return nil }
    return value
  }

  // MARK: - TTL countdown

  /// Milliseconds from `now` to `deadline`, 0 once it passed (Int.max past Int)
  nonisolated static func remainingMilliseconds(
    until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant
  ) -> Int {
    guard deadline > now else { return 0 }
    let (seconds, attoseconds) = (deadline - now).components
    let (ms, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else { return Int.max }
    let (total, overflowSum) = ms.addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
    return overflowSum ? Int.max : Int(total)
  }

  /// The countdown's text: whole seconds rounded up (`42s`, `3m 04s`, `2h 03m 04s`,
  /// `5d 02h 03m 04s`); "Expiring…" at 0
  nonisolated static func ttlText(remainingMilliseconds ms: Int) -> String {
    guard ms > 0 else { return "Expiring…" }
    let total = ms / 1_000 + (ms % 1_000 == 0 ? 0 : 1)
    let days = total / 86_400
    let hours = total % 86_400 / 3_600
    let minutes = total % 3_600 / 60
    let seconds = total % 60
    func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
    if days > 0 { return "\(days)d \(two(hours))h \(two(minutes))m \(two(seconds))s" }
    if hours > 0 { return "\(hours)h \(two(minutes))m \(two(seconds))s" }
    if minutes > 0 { return "\(minutes)m \(two(seconds))s" }
    return "\(seconds)s"
  }

  /// Milliseconds until the countdown's text changes (the next whole second down)
  nonisolated static func nextTickDelay(remainingMilliseconds ms: Int) -> Int {
    let rest = ms % 1_000
    return rest == 0 ? 1_000 : rest
  }

  /// `MEMORY USAGE` for the header: "—" when unavailable
  nonisolated static func memoryText(_ bytes: Int?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
  }

  /// `STRLEN` for the header, with the exact byte count
  nonisolated static func lengthText(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.includesActualByteCount = bytes >= 1_024
    return formatter.string(fromByteCount: Int64(bytes))
  }

  // MARK: - Private

  /// A count read that may be refused (`MEMORY USAGE` behind an ACL, a renamed command, a
  /// `STRLEN` on a key replaced by another type): the server's refusal is nil, any other error
  /// (the connection changed or was lost) throws
  private nonisolated static func optionalCount(
    _ command: RedisCommand, read: Read
  ) async throws -> Int? {
    do {
      return count(try await read(command))
    } catch DatabaseError.queryFailed {
      return nil
    } catch is RedisReplyDecodingError {
      return nil
    }
  }

  @concurrent private nonisolated static func decode(
    _ result: QueryResult
  ) async throws
    -> RedisReply
  {
    // Every reply read here is one node (a type name or an integer)
    try RedisReply(rows: result.rows, maxNodes: 1)
  }

  /// An error for the UI: one escaped line, cut
  private nonisolated static func message(_ error: Error) -> String {
    if case .sessionChanged = error as? DatabaseError {
      return "The connection changed while this key was read."
    }
    let text = RedisDisplayText.line(.text(error.localizedDescription))
    guard text.count > maxErrorLength else { return text }
    return String(text.prefix(maxErrorLength)) + "…"
  }
}
