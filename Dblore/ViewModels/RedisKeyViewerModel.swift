// RedisKeyViewerModel.swift
// The key tab's header: a key's type, TTL and size, read through the Redis gate as the app's own
// reads (`userInitiated: false`) under the workspace's protection policy, so read-only
// connections show them too. `TYPE` first (`none`: the key no longer exists), then `PTTL`,
// `MEMORY USAGE` and, for a string, `STRLEN`. Each load has its own token, and each read
// sequence (the load, a re-check) the connection epoch read when it starts: a result for an
// older load (another key in the same preview tab) is dropped. A key with a TTL is checked again
// once its countdown reaches zero. Replies are untrusted: decoded strictly, an unknown type name
// escaped and cut.
// Then the value, in the same read sequence: a string's first 256 KiB (`GETRANGE`) as text, hex
// and, when complete and valid, pretty JSON; any other core type in pages of 200 rows ("Load
// more": `HSCAN` / `SSCAN` by cursor with duplicates dropped, `LRANGE` / `ZRANGE` by offset,
// `XRANGE` after the last entry id), each "Load more" a new read sequence (a fresh epoch) under
// the same token. Every cell is escaped plain text cut to 4 KiB, built off the main thread; one
// open key keeps at most 10,000 rows (and 64 MiB of cells). The model is the view's `@State`,
// keyed by the tab: switching back reads the key again.

import Foundation
import Observation

@MainActor
@Observable
final class RedisKeyViewerModel {
  /// Sends one command and answers its reply (the gate in the app, a fake in tests)
  typealias Read = @Sendable (RedisCommand) async throws -> RedisReply
  /// Makes the `Read` of one read sequence (the gate's: under the epoch current then)
  typealias MakeRead = @Sendable () async -> Read
  /// One read sequence: its reads and the connection epoch they run under (nil when scripted)
  nonisolated struct ReadSequence: Sendable {
    let epoch: UInt64?
    let read: Read
  }
  /// Makes one read sequence
  typealias MakeSequence = @Sendable () async -> ReadSequence

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

  // MARK: Values

  /// Rows asked for per page (the `COUNT` hint of `HSCAN` / `SSCAN`, the span of `LRANGE` /
  /// `ZRANGE`, the `COUNT` of `XRANGE`)
  nonisolated static let pageSize = 200
  /// The most rows one open key keeps; past it a note points to a command tab
  nonisolated static let maxRows = 10_000
  /// The most bytes of cells (identity bytes and shown text) one open key keeps
  nonisolated static let maxRowBytes = 64 * 1_048_576
  /// The most bytes of a cell escaped, and characters shown, before "…"
  nonisolated static let maxCellLength = 4_096
  /// The most round trips of one page read while pages add fewer than `pageSize` new rows (a
  /// SCAN-family page may be empty or repeat rows, with a non-zero cursor)
  nonisolated static let maxPageRoundTrips = 10
  /// The longest pretty JSON shown, in UTF-8 bytes; a longer one gets no JSON tab
  nonisolated static let maxPrettyJSONBytes = 2 * 1_048_576

  /// One row of a hash, list, set, sorted set or stream
  nonisolated struct ValueRow: Equatable, Sendable {
    /// What a row is in its key, by its exact bytes (never its label): what an edit addresses
    enum Identity: Hashable, Sendable {
      case field(Data)
      case index(Int)
      case member(Data)
      case entry(Data)
    }

    let identity: Identity
    /// The field, index, member or entry id, escaped and cut
    let name: String
    /// The field's value, the element, the score, or the entry's fields (one `field: value` per
    /// line), escaped and cut; nil for a set member
    let value: String?

    /// Bytes the row holds, for `maxRowBytes`
    var byteCount: Int {
      let identityBytes: Int
      switch identity {
      case .field(let bytes), .member(let bytes), .entry(let bytes): identityBytes = bytes.count
      case .index: identityBytes = 8
      }
      return identityBytes + name.utf8.count + (value?.utf8.count ?? 0)
    }
  }

  /// Where the next page starts
  nonisolated enum PageCursor: Equatable, Sendable {
    /// `HSCAN` / `SSCAN` cursor (0 for the first page)
    case scan(UInt64)
    /// `LRANGE` / `ZRANGE` start index
    case offset(Int)
    /// `XRANGE` after this entry id; nil from the first entry
    case after(Data?)
  }

  /// One page read
  nonisolated struct Page: Equatable, Sendable {
    let rows: [ValueRow]
    /// nil when this was the last page
    let next: PageCursor?
  }

  /// The rows read so far of a hash, list, set, sorted set or stream
  nonisolated struct RowList: Equatable, Sendable {
    let kind: KeyType
    var rows: [ValueRow] = []
    /// Where the next page starts; nil once every row was read or paging stopped at a cap
    var next: PageCursor?
    /// `maxRows` or `maxRowBytes` stopped paging with rows left
    var isCapped = false
    var isLoadingMore = false
    /// Why the last "Load more" failed (escaped and cut)
    var moreError: String?
    /// `byteCount` of `rows`
    var byteCount = 0
  }

  /// A string's first `RedisKeyCommands.valuePreviewBytes`, as the Text, Hex and JSON tabs show it
  nonisolated struct StringValue: Equatable, Sendable {
    /// The bytes read
    let bytes: Data
    /// `STRLEN`; nil when unknown
    let length: Int?
    /// The bytes read are the whole value
    let isComplete: Bool
    /// Text with its line breaks (UTF-8), else one line, every byte from 0x80 as `\xNN`
    let text: String
    /// Hex dump: offset, 16 bytes, their ASCII
    let hex: String
    /// Pretty JSON (escaped as text) when the value is complete and a JSON object or array
    let json: String?
    /// The bytes are text to edit (`RedisKeyWrite.editableText`), found off the main thread
    let isText: Bool
  }

  enum Values: Equatable {
    case loading
    case string(StringValue)
    case rows(RowList)
    /// A type the key tab has no view for (a module's)
    case unsupported
    /// Why the value could not be read (escaped and cut)
    case failed(String)
  }

  /// The key the state is for; the view shows `state(for:)` its own key, so a new key in the
  /// same tab shows the placeholder in the frame it arrives
  private(set) var key: RedisKeyRef?
  private(set) var state: State = .loading
  /// The value of `key` (shown under a loaded header)
  private(set) var values: Values = .loading
  /// Changes with each load: the placeholder's delayed spinner restarts with it
  private(set) var loadID = UUID()
  /// The connection epoch the current load read the key under (its first read sequence; never a
  /// re-check's or a "Load more"'s): every edit of the key is sent under it, so a reconnect since
  /// makes the gate refuse the edit. Nil before the load started reading, after `stop()`, or for
  /// scripted reads.
  @ObservationIgnored private(set) var loadEpoch: UInt64?

  /// Results of a load are dropped once a newer one started (or `stop()`)
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  /// Makes the reads of "Load more" (a new read sequence of the current load)
  @ObservationIgnored private var makeSequence: MakeSequence?
  /// Identities of the rows kept: a SCAN-family page may repeat rows
  @ObservationIgnored private var seen: Set<ValueRow.Identity> = []

  /// The header has been read (or found missing, or failed) for the current key
  var loaded: Bool { state != .loading }

  /// `state` when it is for `key`, else `.loading`
  func state(for key: RedisKeyRef) -> State {
    self.key == key ? state : .loading
  }

  /// `values` when they are for `key`, else `.loading`
  func values(for key: RedisKeyRef) -> Values {
    self.key == key ? values : .loading
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
      makeSequence: {
        let epoch = await manager.connectionEpoch
        return ReadSequence(
          epoch: epoch,
          read: { command in
            let result = try await manager.executeGatedRedisCommand(
              command, policy: policy, connectionEpoch: epoch, userInitiated: false)
            return try await Self.decode(result)
          })
      })
  }

  /// Reads `key`'s header with `read`; as `load(_:manager:policy:)`
  @discardableResult
  func load(_ key: RedisKeyRef, read: @escaping Read) -> Task<Void, Never> {
    load(key, makeSequence: { ReadSequence(epoch: nil, read: read) })
  }

  /// Reads `key`'s header with the `Read` `makeRead` makes for each read sequence
  @discardableResult
  func load(_ key: RedisKeyRef, makeRead: @escaping MakeRead) -> Task<Void, Never> {
    load(key, makeSequence: { ReadSequence(epoch: nil, read: await makeRead()) })
  }

  /// Reads `key`'s header with the read sequence `makeSequence` makes each time
  @discardableResult
  func load(_ key: RedisKeyRef, makeSequence: @escaping MakeSequence) -> Task<Void, Never> {
    let token = begin(key, makeSequence: makeSequence)
    // Unstructured: leaving the tab must not cancel a read half way
    return Task { await self.run(key, token: token, makeSequence: makeSequence, isLoad: true) }
  }

  /// Drops every read in flight and the expiry check (the tab is gone)
  func stop() {
    token = UUID()
    expiryTask?.cancel()
    expiryTask = nil
    makeSequence = nil
    loadEpoch = nil
  }

  /// `key` is this model's key and its load was not stopped (another key in the same preview
  /// tab, a closed tab or a disconnect): what a write's answer may read again or mark missing
  func isShowing(_ key: RedisKeyRef) -> Bool {
    self.key == key && makeSequence != nil
  }

  /// A write found `key` gone (`SET … XX` answered nil): the missing state, nothing more read.
  /// Nothing when the model no longer shows `key` (`isShowing`).
  func markMissing(_ key: RedisKeyRef) {
    guard isShowing(key) else { return }
    stop()
    state = .missing
    clearValues()
  }

  /// `stop()`, then the placeholder state (a new `loadID`, no value rows): what a disconnected
  /// tab keeps, so a reconnect never shows the previous header or rows first
  func reset() {
    stop()
    state = .loading
    clearValues()
    loadID = token
  }

  /// Reads the next page of rows into the list (a new read sequence: the epoch current now),
  /// unless one is being read, every row was read, or no load is current. Results are dropped
  /// once a newer load started.
  @discardableResult
  func loadMore() -> Task<Void, Never>? {
    guard let key, let makeSequence, case .rows(var list) = values, list.next != nil,
      !list.isLoadingMore
    else { return nil }
    list.isLoadingMore = true
    list.moreError = nil
    values = .rows(list)
    let token = self.token
    return Task {
      let read = await makeSequence().read
      await self.readPages(key, token: token, read: read)
    }
  }

  // MARK: - Loading

  private func begin(_ key: RedisKeyRef, makeSequence: @escaping MakeSequence) -> UUID {
    stop()
    self.key = key
    self.makeSequence = makeSequence
    state = .loading
    clearValues()
    loadID = token
    return token
  }

  private func clearValues() {
    values = .loading
    seen = []
  }

  /// Reads the header and shows it, then the value's first page (or the string), unless a newer
  /// load started meanwhile. A re-check reads the value again only when the type changed. The
  /// load's own sequence (`isLoad`) sets `loadEpoch`; a re-check's never does.
  private func run(
    _ key: RedisKeyRef, token: UUID, makeSequence: @escaping MakeSequence, isLoad: Bool
  ) async {
    let sequence = await makeSequence()
    guard self.token == token else { return }
    if isLoad { loadEpoch = sequence.epoch }
    let read = sequence.read
    let outcome = await Self.fetch(
      key, isCurrent: { [weak self] in self?.token == token }, read: read)
    guard self.token == token, let outcome else { return }
    switch outcome {
    case .missing:
      state = .missing
      clearValues()
    case .failed(let message):
      state = .failed(message)
      clearValues()
    case .found(let type, let ttl, let memory, let length):
      let expiry: Expiry
      switch ttl {
      case .noExpiry: expiry = .never
      case .milliseconds(let ms): expiry = .at(ContinuousClock.now + .milliseconds(ms))
      }
      var previousType: KeyType?
      if case .loaded(let previous) = state { previousType = previous.type }
      state = .loaded(
        Header(type: type, expiry: expiry, memoryBytes: memory, stringLength: length))
      if case .at(let deadline) = expiry {
        scheduleRecheck(key, at: deadline, token: token, makeSequence: makeSequence)
      }
      // A re-check of the same type keeps the rows shown (and any page being read)
      guard previousType != type else { return }
      await loadValues(key, type: type, length: length, token: token, read: read)
    }
  }

  /// The string's preview, or the first page of rows
  private func loadValues(
    _ key: RedisKeyRef, type: KeyType, length: Int?, token: UUID, read: Read
  ) async {
    clearValues()
    if type == .string {
      do {
        let bytes = try Self.stringBytes(await read(RedisKeyCommands.getRange(key)))
        let value = await Self.buildString(bytes, length: length)
        // Never over the rows of another type a re-check found meanwhile
        guard self.token == token, values == .loading else { return }
        values = .string(value)
      } catch {
        guard self.token == token, values == .loading else { return }
        values = .failed(Self.message(error))
      }
      return
    }
    guard let first = Self.firstCursor(type) else {
      values = .unsupported
      return
    }
    values = .rows(RowList(kind: type, next: first, isLoadingMore: true))
    await readPages(key, token: token, read: read)
  }

  /// Reads pages into the row list from its `next` until `pageSize` new rows, the last page, a
  /// cap, or `maxPageRoundTrips`; the token is checked after every read. A failure on the first
  /// page shows the failed state, on a later one a note under the rows.
  private func readPages(_ key: RedisKeyRef, token: UUID, read: Read) async {
    guard case .rows(let start) = values else { return }
    // A re-check that found another type replaced the list: this read is not for it
    let kind = start.kind
    var added = 0
    do {
      for _ in 0..<Self.maxPageRoundTrips {
        guard self.token == token, case .rows(let list) = values, list.kind == kind,
          let cursor = list.next, let command = Self.pageCommand(key, kind: kind, cursor: cursor)
        else { break }
        let reply = try await read(command)
        guard self.token == token else { return }
        let page = try await Self.buildPage(reply, kind: kind, cursor: cursor)
        guard self.token == token, case .rows(var current) = values, current.kind == kind,
          current.next == cursor
        else { return }
        added += Self.apply(page, to: &current, seen: &seen)
        values = .rows(current)
        guard added < Self.pageSize else { break }
      }
    } catch {
      guard self.token == token, case .rows(var list) = values, list.kind == kind else { return }
      guard !list.rows.isEmpty else {
        values = .failed(Self.message(error))
        return
      }
      list.isLoadingMore = false
      list.moreError = Self.message(error)
      values = .rows(list)
      return
    }
    guard self.token == token, case .rows(var list) = values, list.kind == kind else { return }
    if let cursor = list.next, Self.pageCommand(key, kind: kind, cursor: cursor) == nil {
      list.next = nil
    }
    list.isLoadingMore = false
    values = .rows(list)
  }

  /// Once the countdown ends (plus `expiryRecheckDelay`), reads the header again (a new read
  /// sequence, under the epoch current then), keeping the shown header until it answers: `none`
  /// shows the missing state, a key the server still holds (its TTL changed) its new header
  private func scheduleRecheck(
    _ key: RedisKeyRef, at deadline: ContinuousClock.Instant, token: UUID,
    makeSequence: @escaping MakeSequence
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
      await self.run(key, token: token, makeSequence: makeSequence, isLoad: false)
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

  // MARK: - Values (untrusted server data)

  /// Where the first page of `type` starts; nil for a string or a type without a row view
  nonisolated static func firstCursor(_ type: KeyType) -> PageCursor? {
    switch type {
    case .hash, .set: .scan(0)
    case .list, .sortedSet: .offset(0)
    case .stream: .after(nil)
    case .string, .other: nil
    }
  }

  /// The command reading the page of `kind` at `cursor`; nil when the cursor does not fit the
  /// kind, or no stream id follows the last one read
  nonisolated static func pageCommand(
    _ key: RedisKeyRef, kind: KeyType, cursor: PageCursor
  ) -> RedisCommand? {
    switch (kind, cursor) {
    case (.hash, .scan(let next)): RedisKeyCommands.hscan(key, cursor: next, count: pageSize)
    case (.set, .scan(let next)): RedisKeyCommands.sscan(key, cursor: next, count: pageSize)
    case (.list, .offset(let start)):
      RedisKeyCommands.lrange(key, start: start, stop: start + pageSize - 1)
    case (.sortedSet, .offset(let start)):
      RedisKeyCommands.zrange(key, start: start, stop: start + pageSize - 1)
    case (.stream, .after(let id)): RedisKeyCommands.xrange(key, after: id, count: pageSize)
    default: nil
    }
  }

  /// The page `reply` of `kind` read at `cursor`, every cell escaped and cut (`cell`). `HSCAN`
  /// / `SSCAN`: `[cursor, [items]]`, cursor 0 is the last page. `LRANGE` / `ZRANGE`: a page
  /// shorter than `pageSize` is the last; `ZRANGE … WITHSCORES` as `[member, score]` pairs
  /// (RESP3) or a flat member, score array (RESP2). `XRANGE`: `[[id, [field, value, …]], …]`, a
  /// full page goes on after its last id while one follows it. Anything else throws.
  nonisolated static func page(
    _ reply: RedisReply, kind: KeyType, cursor: PageCursor
  ) throws -> Page {
    switch (kind, cursor) {
    case (.hash, .scan), (.set, .scan):
      let (next, items) = try RedisKeyBrowserModel.scanPage(reply)
      let rows: [ValueRow]
      if kind == .hash {
        guard items.count.isMultiple(of: 2) else {
          throw RedisReplyDecodingError(message: "HSCAN answered a field without its value")
        }
        rows = stride(from: 0, to: items.count, by: 2).map {
          ValueRow(
            identity: .field(items[$0]), name: cell(items[$0]), value: cell(items[$0 + 1]))
        }
      } else {
        rows = items.map { ValueRow(identity: .member($0), name: cell($0), value: nil) }
      }
      return Page(rows: rows, next: next == 0 ? nil : .scan(next))
    case (.list, .offset(let start)):
      let elements = try items(reply, "LRANGE").map(stringBytes)
      let rows = elements.enumerated().map { index, element in
        ValueRow(identity: .index(start + index), name: "\(start + index)", value: cell(element))
      }
      return Page(rows: rows, next: offsetAfter(start, count: rows.count))
    case (.sortedSet, .offset(let start)):
      let rows = try scoredMembers(items(reply, "ZRANGE")).map { member, score in
        ValueRow(identity: .member(member), name: cell(member), value: score)
      }
      return Page(rows: rows, next: offsetAfter(start, count: rows.count))
    case (.stream, .after):
      let rows = try items(reply, "XRANGE").map(streamEntry)
      var next: PageCursor?
      if rows.count >= pageSize, case .entry(let last) = rows.last?.identity,
        RedisKeyCommands.nextStreamID(after: last) != nil
      {
        next = .after(last)
      }
      return Page(rows: rows, next: next)
    default:
      throw RedisReplyDecodingError(message: "no page for this key type")
    }
  }

  /// Appends the rows of `page` not yet `seen` until `maxRows` rows or `maxBytes` of cells
  /// (then paging stops, `isCapped` when rows were left) and moves `next` on; returns how many
  /// rows were added
  nonisolated static func apply(
    _ page: Page, to list: inout RowList, seen: inout Set<ValueRow.Identity>,
    maxRows: Int = RedisKeyViewerModel.maxRows, maxBytes: Int = RedisKeyViewerModel.maxRowBytes
  ) -> Int {
    var added = 0
    var isLeft = false
    for row in page.rows where !seen.contains(row.identity) {
      let size = row.byteCount
      guard list.rows.count < maxRows, list.byteCount + size <= maxBytes else {
        isLeft = true
        break
      }
      seen.insert(row.identity)
      list.rows.append(row)
      list.byteCount += size
      added += 1
    }
    list.next = page.next
    if isLeft || (page.next != nil && list.rows.count >= maxRows) {
      list.isCapped = true
      list.next = nil
    }
    return added
  }

  /// `bytes` as one escaped line (`RedisDisplayText.line`; bytes that are not UTF-8 as `\xNN`),
  /// cut after `limit` characters with "…". Only the first `limit` bytes (backed off to a UTF-8
  /// scalar boundary) are escaped, so a large value costs no more than a short one.
  nonisolated static func cell(_ bytes: Data, limit: Int = maxCellLength) -> String {
    var kept = Data(bytes.prefix(limit))
    if kept.count < bytes.count { kept = utf8Head(kept) }
    let shown = RedisDisplayText.line(replyString(kept))
    guard shown.count > limit || kept.count < bytes.count else { return shown }
    return String(shown.prefix(limit)) + "…"
  }

  /// A stream entry's fields, one `field: value` line each, cut after `limit` characters
  nonisolated static func fieldsText(
    _ fields: [(Data, Data)], limit: Int = maxCellLength
  ) -> String {
    var out = ""
    var length = 0
    for (field, value) in fields {
      // Fields left past the limit: cut
      guard length < limit else { return String(out.prefix(limit)) + "…" }
      let room = limit - length
      let line =
        (out.isEmpty ? "" : "\n") + cell(field, limit: room) + ": " + cell(value, limit: room)
      out += line
      length += line.count
    }
    guard length > limit else { return out }
    return String(out.prefix(limit)) + "…"
  }

  /// A string preview: complete when shorter than `valuePreviewBytes` or as long as `STRLEN`
  nonisolated static func stringValue(_ bytes: Data, length: Int?) -> StringValue {
    let isComplete = bytes.count < RedisKeyCommands.valuePreviewBytes || length == bytes.count
    // A cut preview may end inside a character: drop it from the text only
    let textBytes = isComplete ? bytes : utf8Head(bytes)
    let text: String
    if case .text(let decoded) = replyString(textBytes) {
      text = RedisDisplayText.lines(decoded)
    } else {
      text = RedisDisplayText.line(.bytes(bytes))
    }
    return StringValue(
      bytes: bytes, length: length, isComplete: isComplete, text: text, hex: hexDump(bytes),
      json: isComplete ? prettyJSON(bytes).map(RedisDisplayText.lines) : nil,
      isText: RedisKeyWrite.editableText(bytes) != nil)
  }

  /// `bytes` as lines of 16: an 8-digit hex offset, the bytes in hex (two groups of 8), and
  /// their printable ASCII between bars (`.` for any other byte)
  nonisolated static func hexDump(_ bytes: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    let all = [UInt8](bytes)
    var out: [UInt8] = []
    out.reserveCapacity((all.count + 15) / 16 * 80)
    var offset = 0
    while offset < all.count {
      let end = min(offset + 16, all.count)
      if offset > 0 { out.append(0x0A) }
      for shift in stride(from: 28, through: 0, by: -4) {
        out.append(digits[(offset >> shift) & 0xF])
      }
      out += [0x20, 0x20]
      for column in 0..<16 {
        if offset + column < end {
          let byte = all[offset + column]
          out += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)], 0x20]
        } else {
          out += [0x20, 0x20, 0x20]
        }
        if column == 7 { out.append(0x20) }
      }
      out += [0x20, UInt8(ascii: "|")]
      for byte in all[offset..<end] { out.append((0x20...0x7E).contains(byte) ? byte : 0x2E) }
      out.append(UInt8(ascii: "|"))
      offset = end
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// `bytes` re-indented (two spaces a level) when they are one valid JSON object or array in
  /// UTF-8, else nil; also nil past `maxBytes` of output. Validated by `JSONSerialization`, then
  /// the original bytes are re-indented, so key order, numbers and string escapes stay as
  /// written.
  nonisolated static func prettyJSON(_ bytes: Data, maxBytes: Int = maxPrettyJSONBytes) -> String? {
    let json = [UInt8](bytes)
    let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    // No NUL: JSON in UTF-8 never has one, and without one no other encoding is guessed
    guard let first = json.first(where: { !isSpace($0) }),
      first == UInt8(ascii: "{") || first == UInt8(ascii: "["), !json.contains(0),
      String(data: bytes, encoding: .utf8) != nil,
      (try? JSONSerialization.jsonObject(with: bytes)) != nil
    else { return nil }
    var out: [UInt8] = []
    var depth = 0
    var inString = false
    var escaped = false
    var pendingOpen = false
    func newline() {
      out.append(0x0A)
      out += repeatElement(0x20, count: max(0, depth) * 2)
    }
    for byte in json {
      guard out.count <= maxBytes else { return nil }
      if inString {
        out.append(byte)
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }
        continue
      }
      if isSpace(byte) { continue }
      let isClose = byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
      if pendingOpen {
        pendingOpen = false
        // An empty object or array stays on one line
        if isClose {
          out.append(byte)
          continue
        }
        depth += 1
        newline()
      }
      switch byte {
      case UInt8(ascii: "\""):
        inString = true
        out.append(byte)
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        out.append(byte)
        pendingOpen = true
      case _ where isClose:
        depth -= 1
        newline()
        out.append(byte)
      case UInt8(ascii: ","):
        out.append(byte)
        newline()
      case UInt8(ascii: ":"):
        out += [byte, 0x20]
      default:
        out.append(byte)
      }
    }
    guard out.count <= maxBytes else { return nil }
    return String(decoding: out, as: UTF8.self)
  }

  /// A string reply's exact bytes (bulk, simple or verbatim); anything else throws
  nonisolated static func stringBytes(_ reply: RedisReply) throws -> Data {
    switch reply {
    case .bulk(let string), .simple(let string), .verbatim(let string):
      switch string {
      case .text(let text): return Data(text.utf8)
      case .bytes(let bytes): return bytes
      }
    default:
      throw RedisReplyDecodingError(message: "expected a string, got \(reply.typeName)")
    }
  }

  /// An array reply's items
  private nonisolated static func items(
    _ reply: RedisReply, _ command: String
  ) throws
    -> [RedisReply]
  {
    guard case .array(let items) = reply else {
      throw RedisReplyDecodingError(message: "\(command) did not answer an array")
    }
    return items
  }

  /// The next offset after a page of `count` rows from `start`; nil after a short page
  private nonisolated static func offsetAfter(_ start: Int, count: Int) -> PageCursor? {
    count >= pageSize ? .offset(start + count) : nil
  }

  /// `ZRANGE … WITHSCORES` items: `[member, score]` pairs or a flat member, score array; each
  /// score as the server wrote it, escaped and cut
  private nonisolated static func scoredMembers(_ items: [RedisReply]) throws -> [(Data, String)] {
    let pairs: [(RedisReply, RedisReply)]
    if items.allSatisfy({ if case .array(let pair) = $0 { pair.count == 2 } else { false } }) {
      pairs = items.compactMap { item in
        guard case .array(let pair) = item else { return nil }
        return (pair[0], pair[1])
      }
    } else {
      guard items.count.isMultiple(of: 2) else {
        throw RedisReplyDecodingError(message: "ZRANGE answered a member without its score")
      }
      pairs = stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
    }
    return try pairs.map { member, score in
      let text: Data
      switch score {
      case .double(let written): text = Data(written.utf8)
      case .integer(let number): text = Data(String(number).utf8)
      default: text = try stringBytes(score)
      }
      return (try stringBytes(member), cell(text))
    }
  }

  /// One `XRANGE` entry: `[id, [field, value, …]]` (fields also as a map, or null)
  private nonisolated static func streamEntry(_ entry: RedisReply) throws -> ValueRow {
    guard case .array(let parts) = entry, parts.count == 2 else {
      throw RedisReplyDecodingError(
        message: "XRANGE answered an entry that is not an id and fields")
    }
    let id = try stringBytes(parts[0])
    var fields: [(Data, Data)] = []
    switch parts[1] {
    case .array(let items):
      guard items.count.isMultiple(of: 2) else {
        throw RedisReplyDecodingError(message: "XRANGE answered a field without its value")
      }
      fields = try stride(from: 0, to: items.count, by: 2).map {
        (try stringBytes(items[$0]), try stringBytes(items[$0 + 1]))
      }
    case .map(let pairs):
      fields = try pairs.map { (try stringBytes($0.key), try stringBytes($0.value)) }
    case .null:
      break
    default:
      throw RedisReplyDecodingError(message: "XRANGE answered fields that are not an array")
    }
    return ValueRow(identity: .entry(id), name: cell(id), value: fieldsText(fields))
  }

  /// `bytes` without a UTF-8 character a cut split at its end (at most 3 bytes); unchanged when
  /// no shorter head decodes either
  private nonisolated static func utf8Head(_ bytes: Data) -> Data {
    for drop in 0...3 where String(data: bytes.dropLast(drop), encoding: .utf8) != nil {
      return Data(bytes.dropLast(drop))
    }
    return bytes
  }

  /// `bytes` as text when they are valid UTF-8 (decoding gives back the same bytes)
  private nonisolated static func replyString(_ bytes: Data) -> RedisReplyString {
    guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
      return .bytes(bytes)
    }
    return .text(text)
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

  /// A reply from its rows, off the main actor
  @concurrent nonisolated static func decode(
    _ result: QueryResult
  ) async throws
    -> RedisReply
  {
    // A value page is many nodes; the gate already refuses a reply past this cap
    try RedisReply(rows: result.rows, maxNodes: RedisReply.defaultMaxNodes)
  }

  @concurrent private nonisolated static func buildPage(
    _ reply: RedisReply, kind: KeyType, cursor: PageCursor
  ) async throws -> Page {
    try page(reply, kind: kind, cursor: cursor)
  }

  @concurrent private nonisolated static func buildString(
    _ bytes: Data, length: Int?
  ) async -> StringValue {
    stringValue(bytes, length: length)
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

// MARK: - Edits

/// One write of a key (the key tab's edits, the sidebar's New Key): the exact command sent, what
/// its confirmation shows, and what is read right before it. Built only from exact bytes (a key's
/// `RedisKeyRef`, a row's `ValueRow.identity`, text typed as UTF-8), never from a shown label.
nonisolated struct RedisKeyWrite: Sendable, Equatable {
  /// What the write did to the key: what the key tab and the sidebar refresh
  enum Effect: Sendable, Equatable {
    /// The value or the TTL changed: the key is read again
    case changed
    /// `UNLINK`: the key's tab closes
    case deleted
    /// `RENAMENX`: the key's tab shows the new name
    case renamed(to: RedisKeyRef)
    /// A new key (New Key in the sidebar)
    case created
  }

  /// Read right before the confirmation shows and again right before the write is sent. Another
  /// client can still write between that read and the write (last write wins).
  enum Check: Sendable, Equatable {
    /// `TYPE` answers this type: an edit never re-creates a deleted key or writes over a key
    /// another client replaced with another type (`SET … XX` replaces any type)
    case type(RedisKeyViewerModel.KeyType)
    /// `TYPE` answers `none`: a new key never adds to an existing one
    case absent
    /// `LRANGE k i i` answers exactly these bytes: the element the edit started from, so a push
    /// or pop by another client since (which moves the indexes) refuses the edit
    case element(index: Int, bytes: Data)
  }

  /// What a reply means beyond "done"
  enum Reply: Sendable, Equatable {
    case any
    /// nil or 0: the key no longer exists (`SET … XX`, `PEXPIRE`)
    case existingKey
    /// nil or 0: another key has the name (`SET … NX`, `RENAMENX`)
    case newName
    /// 0: the field or member exists (`HSETNX`, `ZADD … NX`); refused with this message
    case newItem(String)
  }

  /// The key written (for New Key and a rename: the key named before the write)
  let key: RedisKeyRef
  let command: RedisCommand
  /// The confirmation's question
  let title: String
  /// The confirm button's title
  let confirmTitle: String
  /// Key, db, field / index / member, old and new value: escaped and cut, one per line
  let details: [String]
  /// A removal (`UNLINK`, `HDEL`, `SREM`, `ZREM`, `XDEL`): asked under every commit style,
  /// Immediate included. The gate asks only for destructive commands, and these are data writes.
  let isRemoval: Bool
  let check: Check?
  let reply: Reply
  let effect: Effect

  /// The most bytes a value, field, member or name typed in the edit sheet may hold
  static let maxInputBytes = 1_048_576
  /// The most characters of a value a confirmation shows
  static let maxDetailLength = 200
  /// The most fields of a new stream entry a confirmation lists
  static let maxDetailFields = 20
  static let fieldTakenMessage = "A field with that name already exists."
  static let memberTakenMessage = "That member already exists."

  // MARK: String and TTL

  /// `SET k v KEEPTTL XX` of a string key, after `TYPE` still answers `string`
  static func stringValue(_ key: RedisKeyRef, value: Data, old: Data) throws -> RedisKeyWrite {
    try checkSize(value, "value")
    return RedisKeyWrite(
      key: key, command: RedisKeyCommands.set(key, value: value), title: "Save the new value?",
      confirmTitle: "Save",
      details: keyLines(key) + ["Old value: " + shown(old), "New value: " + shown(value)],
      isRemoval: false, check: .type(.string), reply: .existingKey, effect: .changed)
  }

  /// `PEXPIRE k ms`; whole seconds, 1 or more
  static func expire(_ key: RedisKeyRef, seconds: Int) throws -> RedisKeyWrite {
    let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow, let command = RedisKeyCommands.pexpire(key, milliseconds: milliseconds) else {
      throw RedisKeyEditError(message: "The TTL must be a whole number of seconds, 1 or more.")
    }
    return RedisKeyWrite(
      key: key, command: command, title: "Set the TTL?", confirmTitle: "Save",
      details: keyLines(key)
        + ["New TTL: " + RedisKeyViewerModel.ttlText(remainingMilliseconds: milliseconds)],
      isRemoval: false, check: nil, reply: .existingKey, effect: .changed)
  }

  /// `PERSIST k`
  static func persist(_ key: RedisKeyRef) -> RedisKeyWrite {
    RedisKeyWrite(
      key: key, command: RedisKeyCommands.persist(key), title: "Remove the expiry?",
      confirmTitle: "Remove Expiry", details: keyLines(key), isRemoval: false, check: nil,
      reply: .any, effect: .changed)
  }

  // MARK: Hash, list, set, sorted set, stream

  /// `HSETNX k f v`: a new field (`old` nil), never over one not on the loaded page; else
  /// `HSET k f v`: a new value of a field
  static func hashField(
    _ key: RedisKeyRef, field: Data, value: Data, old: Data?
  ) throws -> RedisKeyWrite {
    try checkSize(field, "field name")
    try checkSize(value, "value")
    var lines = keyLines(key) + ["Field: " + shown(field)]
    if let old { lines.append("Old value: " + shown(old)) }
    lines.append("New value: " + shown(value))
    return RedisKeyWrite(
      key: key,
      command: old == nil
        ? RedisKeyCommands.hsetnx(key, field: field, value: value)
        : RedisKeyCommands.hset(key, field: field, value: value),
      title: old == nil ? "Add the field?" : "Save the field's value?", confirmTitle: "Save",
      details: lines, isRemoval: false, check: .type(.hash),
      reply: old == nil ? .newItem(fieldTakenMessage) : .any, effect: .changed)
  }

  /// `HDEL k f`
  static func removeHashField(_ key: RedisKeyRef, field: Data) -> RedisKeyWrite {
    removal(
      key, RedisKeyCommands.hdel(key, field: field), title: "Remove the field?",
      line: "Field: " + shown(field))
  }

  /// `LPUSH k v` (at the head) or `RPUSH k v` (at the tail)
  static func pushElement(_ key: RedisKeyRef, value: Data, atHead: Bool) throws -> RedisKeyWrite {
    try checkSize(value, "element")
    return RedisKeyWrite(
      key: key,
      command: atHead
        ? RedisKeyCommands.lpush(key, value: value) : RedisKeyCommands.rpush(key, value: value),
      title: atHead ? "Add the element at the head?" : "Add the element at the tail?",
      confirmTitle: "Add", details: keyLines(key) + ["New element: " + shown(value)],
      isRemoval: false, check: .type(.list), reply: .any, effect: .changed)
  }

  /// `LSET k i v`, after `LRANGE k i i` still answers `old`
  static func listElement(
    _ key: RedisKeyRef, index: Int, value: Data, old: Data
  ) throws -> RedisKeyWrite {
    try checkSize(value, "element")
    return RedisKeyWrite(
      key: key, command: RedisKeyCommands.lset(key, index: index, value: value),
      title: "Save the element at index \(index)?", confirmTitle: "Save",
      details: keyLines(key) + [
        "Index: \(index)", "Old value: " + shown(old), "New value: " + shown(value),
      ],
      isRemoval: false, check: .element(index: index, bytes: old), reply: .any, effect: .changed)
  }

  /// `SADD k m`
  static func addSetMember(_ key: RedisKeyRef, member: Data) throws -> RedisKeyWrite {
    try checkSize(member, "member")
    return RedisKeyWrite(
      key: key, command: RedisKeyCommands.sadd(key, member: member), title: "Add the member?",
      confirmTitle: "Add", details: keyLines(key) + ["Member: " + shown(member)],
      isRemoval: false, check: .type(.set), reply: .any, effect: .changed)
  }

  /// `SREM k m`
  static func removeSetMember(_ key: RedisKeyRef, member: Data) -> RedisKeyWrite {
    removal(
      key, RedisKeyCommands.srem(key, member: member), title: "Remove the member?",
      line: "Member: " + shown(member))
  }

  /// `ZADD k NX score m`: a new member (`oldScore` nil), never over one not on the loaded page;
  /// else `ZADD k score m`: a new score of a member. `oldScore` is the server's text: shown
  /// escaped and cut.
  static func sortedSetMember(
    _ key: RedisKeyRef, member: Data, score: Double, oldScore: String?
  ) throws -> RedisKeyWrite {
    try checkSize(member, "member")
    let built =
      oldScore == nil
      ? RedisKeyCommands.zaddNX(key, score: score, member: member)
      : RedisKeyCommands.zadd(key, score: score, member: member)
    guard let command = built else { throw scoreError }
    var lines = keyLines(key) + ["Member: " + shown(member)]
    if let oldScore { lines.append("Old score: " + shown(Data(oldScore.utf8))) }
    lines.append("New score: \(score)")
    return RedisKeyWrite(
      key: key, command: command, title: oldScore == nil ? "Add the member?" : "Save the score?",
      confirmTitle: "Save", details: lines, isRemoval: false, check: .type(.sortedSet),
      reply: oldScore == nil ? .newItem(memberTakenMessage) : .any, effect: .changed)
  }

  /// `ZREM k m`
  static func removeSortedSetMember(_ key: RedisKeyRef, member: Data) -> RedisKeyWrite {
    removal(
      key, RedisKeyCommands.zrem(key, member: member), title: "Remove the member?",
      line: "Member: " + shown(member))
  }

  /// `XADD k * f v …`: the server picks the entry id
  static func addStreamEntry(
    _ key: RedisKeyRef, fields: [(field: Data, value: Data)]
  ) throws -> RedisKeyWrite {
    for (field, value) in fields {
      try checkSize(field, "field name")
      try checkSize(value, "value")
    }
    guard let command = RedisKeyCommands.xadd(key, id: nil, fields: fields) else {
      throw RedisKeyEditError(message: "An entry needs at least one field.")
    }
    var lines =
      keyLines(key)
      + fields.prefix(maxDetailFields).map { shown($0.field) + ": " + shown($0.value) }
    let more = fields.count - maxDetailFields
    if more > 0 { lines.append("… and \(more) more \(more == 1 ? "field" : "fields")") }
    return RedisKeyWrite(
      key: key, command: command, title: "Add the entry?", confirmTitle: "Add", details: lines,
      isRemoval: false, check: .type(.stream), reply: .any, effect: .changed)
  }

  /// `XDEL k id`
  static func deleteStreamEntry(_ key: RedisKeyRef, id: Data) -> RedisKeyWrite {
    removal(
      key, RedisKeyCommands.xdel(key, id: id), title: "Delete the entry?",
      line: "Entry ID: " + shown(id))
  }

  // MARK: Key

  /// `UNLINK k`
  static func delete(_ key: RedisKeyRef) -> RedisKeyWrite {
    RedisKeyWrite(
      key: key, command: RedisKeyCommands.unlink(key), title: "Delete the key?",
      confirmTitle: "Delete", details: keyLines(key), isRemoval: true, check: nil, reply: .any,
      effect: .deleted)
  }

  /// `RENAMENX k name` in the key's db
  static func rename(_ key: RedisKeyRef, to name: Data) throws -> RedisKeyWrite {
    try checkName(name)
    let target = RedisKeyRef(db: key.db, bytes: name)
    guard name != key.bytes, let command = RedisKeyCommands.renameNX(key, to: target) else {
      throw RedisKeyEditError(message: "The new name is the key's name.")
    }
    return RedisKeyWrite(
      key: key, command: command, title: "Rename the key?", confirmTitle: "Rename",
      details: keyLines(key) + ["New name: " + RedisKeyBrowserModel.label(name)],
      isRemoval: false, check: nil, reply: .newName, effect: .renamed(to: target))
  }

  /// The first content of a new key
  enum NewKeyContent: Sendable, Equatable {
    case string(Data)
    case hash(field: Data, value: Data)
    case list(Data)
    case set(Data)
    case sortedSet(member: Data, score: Double)
    case stream(field: Data, value: Data)
  }

  /// A new key with its first content: `SET k v NX` (refuses an existing key by itself), else
  /// `HSET` / `RPUSH` / `SADD` / `ZADD` / `XADD k *` after `TYPE` answered `none` (checked
  /// right before the confirmation and right before the write)
  static func create(_ key: RedisKeyRef, content: NewKeyContent) throws -> RedisKeyWrite {
    try checkName(key.bytes)
    let command: RedisCommand
    let check: Check?
    var lines = keyLines(key)
    switch content {
    case .string(let value):
      try checkSize(value, "value")
      command = RedisKeyCommands.createString(key, value: value)
      check = nil
      lines += ["Type: String", "Value: " + shown(value)]
    case .hash(let field, let value):
      try checkSize(field, "field name")
      try checkSize(value, "value")
      command = RedisKeyCommands.createHash(key, field: field, value: value)
      check = .absent
      lines += ["Type: Hash", "Field: " + shown(field), "Value: " + shown(value)]
    case .list(let value):
      try checkSize(value, "element")
      command = RedisKeyCommands.createList(key, value: value)
      check = .absent
      lines += ["Type: List", "Element: " + shown(value)]
    case .set(let member):
      try checkSize(member, "member")
      command = RedisKeyCommands.createSet(key, member: member)
      check = .absent
      lines += ["Type: Set", "Member: " + shown(member)]
    case .sortedSet(let member, let score):
      try checkSize(member, "member")
      guard let built = RedisKeyCommands.createSortedSet(key, score: score, member: member) else {
        throw scoreError
      }
      command = built
      check = .absent
      lines += ["Type: Sorted set", "Member: " + shown(member), "Score: \(score)"]
    case .stream(let field, let value):
      try checkSize(field, "field name")
      try checkSize(value, "value")
      command = RedisKeyCommands.createStream(key, field: field, value: value)
      check = .absent
      lines += ["Type: Stream", shown(field) + ": " + shown(value)]
    }
    // Only `SET … NX` answers nil for a taken name; the others answer a count or an id
    return RedisKeyWrite(
      key: key, command: command, title: "Create the key?", confirmTitle: "Create",
      details: lines, isRemoval: false, check: check, reply: check == nil ? .newName : .any,
      effect: .created)
  }

  // MARK: Input

  /// A score typed as text: a finite number
  static func score(_ text: String) throws -> Double {
    guard let score = Double(text.trimmingCharacters(in: .whitespaces)), score.isFinite else {
      throw scoreError
    }
    return score
  }

  /// Whole seconds typed as text: 1 or more
  static func seconds(_ text: String) throws -> Int {
    guard let seconds = Int(text.trimmingCharacters(in: .whitespaces)), seconds > 0 else {
      throw RedisKeyEditError(message: "The TTL must be a whole number of seconds, 1 or more.")
    }
    return seconds
  }

  /// `bytes` as text to edit: valid UTF-8 that encodes back to the same bytes; nil for a binary
  /// value, which cannot be typed
  static func editableText(_ bytes: Data) -> String? {
    guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
      return nil
    }
    return text
  }

  // MARK: Private

  private static let scoreError = RedisKeyEditError(message: "The score must be a finite number.")

  private static func checkSize(_ bytes: Data, _ name: String) throws {
    guard bytes.count <= maxInputBytes else {
      throw RedisKeyEditError(message: "The \(name) is larger than 1 MiB; use a command tab.")
    }
  }

  /// A key name typed: not empty (the empty key is reached from a command tab only, never by a
  /// stray Save) and at most 1 MiB
  private static func checkName(_ name: Data) throws {
    guard !name.isEmpty else { throw RedisKeyEditError(message: "Type a key name.") }
    try checkSize(name, "name")
  }

  private static func keyLines(_ key: RedisKeyRef) -> [String] {
    ["Key: " + RedisKeyBrowserModel.label(key.bytes), "Database: db \(key.db)"]
  }

  /// A value for the confirmation: one escaped line, cut
  private static func shown(_ bytes: Data) -> String {
    RedisKeyViewerModel.cell(bytes, limit: maxDetailLength)
  }

  private static func removal(
    _ key: RedisKeyRef, _ command: RedisCommand, title: String, line: String
  ) -> RedisKeyWrite {
    RedisKeyWrite(
      key: key, command: command, title: title,
      confirmTitle: title.hasPrefix("Delete") ? "Delete" : "Remove",
      details: keyLines(key) + [line], isRemoval: true, check: nil, reply: .any,
      effect: .changed)
  }
}

/// Why a write cannot be built (a value too large, a score that is not a number)
nonisolated struct RedisKeyEditError: LocalizedError, Equatable {
  let message: String

  var errorDescription: String? { message }
}

/// Where the key tab's writes go: the gate in the app (`gated`), closures in tests
struct RedisKeyWriteContext {
  /// One read as the app's own (`userInitiated: false`) under `epoch`: a pre-fill or a check.
  /// Never recorded in History.
  var read: @Sendable (_ command: RedisCommand, _ epoch: UInt64) async throws -> RedisReply
  /// One write as the user's (`userInitiated: true`) under `epoch`; `confirmed` once the user
  /// confirmed it
  var write:
    @Sendable (_ command: RedisCommand, _ epoch: UInt64, _ confirmed: Bool) async throws ->
      RedisReply
  /// Read when a write is asked and again when it is confirmed
  var commitStyle: @MainActor () -> CommitStyle
  /// Stores sent writes in History (`RedisTokenizer.render(args)`); the workspace skips it with
  /// History off
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void
  /// Shown when the connection changed since the key (or the key list) was read
  var staleMessage = "The connection changed; reload the key."

  /// Through `executeGatedRedisCommand` under `policy` (read at each command)
  static func gated(
    manager: DatabaseConnectionManager,
    policy: @escaping @MainActor @Sendable () -> ProtectionPolicy,
    commitStyle: @escaping @MainActor () -> CommitStyle,
    recordHistory: @escaping @MainActor ([QueryHistoryOutcome]) async -> Void
  ) -> RedisKeyWriteContext {
    RedisKeyWriteContext(
      read: { command, epoch in
        let result = try await manager.executeGatedRedisCommand(
          command, policy: await policy(), connectionEpoch: epoch, userInitiated: false)
        return try await RedisKeyViewerModel.decode(result)
      },
      write: { command, epoch, confirmed in
        let result = try await manager.executeGatedRedisCommand(
          command, policy: await policy(), connectionEpoch: epoch, userInitiated: true,
          confirmed: confirmed)
        return try await RedisKeyViewerModel.decode(result)
      },
      commitStyle: commitStyle, recordHistory: recordHistory)
  }
}

/// Asks, checks and sends one write at a time (`RedisKeyWrite`), as the command tab's runner
/// does: under the Immediate commit style a write is sent at once (a removal still asks, in a
/// plain confirmation); under Confirm and Password it asks first in the Safe Mode panel
/// (`needsSafeModePanel`, `requiresPassword`). The style is read when the write is asked and
/// again when it is confirmed: a stronger one meanwhile asks again. The write's check runs before
/// it is asked and again right before it is sent. Everything runs under the epoch the caller
/// read the key under: a reconnect since makes the gate refuse it ("reload the key"), and it is
/// never sent again under a newer epoch. History gets each sent write.
@MainActor
@Observable
final class RedisKeyEditor {
  /// What the confirmation shows; confirming sends exactly this write under this epoch
  struct Confirmation: Identifiable, Equatable {
    /// One per question: a late answer meant for an earlier one sends nothing
    let id = UUID()
    let write: RedisKeyWrite
    let epoch: UInt64
    /// Show `SafeModeConfirmationPanel` (Confirm / Password); else a plain confirmation
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
  }

  enum Phase: Equatable {
    case idle
    /// Reading the write's check
    case checking
    case confirming(Confirmation)
    case sending
    /// Why nothing (or nothing more) was written: escaped and cut
    case failed(String)
  }

  /// A write that reached the server
  enum Outcome: Equatable {
    case written(RedisReply)
    /// The key no longer exists: `SET … XX` answered nil, `PEXPIRE` 0, or the check found
    /// `TYPE` `none`
    case keyGone
  }

  /// The longest error text shown, in characters
  nonisolated static let maxErrorLength = 300
  nonisolated static let nameTakenMessage = "A key with that name already exists."

  private(set) var phase: Phase = .idle
  @ObservationIgnored let context: RedisKeyWriteContext
  /// A newer request (or `cancel`) drops the answer of an older one
  @ObservationIgnored private var requestID = UUID()

  init(context: RedisKeyWriteContext) {
    self.context = context
  }

  /// The confirmation waiting for an answer
  var pending: Confirmation? {
    if case .confirming(let confirmation) = phase { return confirmation }
    return nil
  }

  /// Checking or sending: no other write starts
  var isBusy: Bool { phase == .checking || phase == .sending }

  /// Checks `write`, then asks for it or (Immediate, not a removal) sends it, under `epoch` (nil:
  /// the key was not read on this connection, refused). Returns the outcome once sent; nil while
  /// it waits for `confirm`, or when it was refused (`phase` says why).
  func request(_ write: RedisKeyWrite, epoch: UInt64?) async -> Outcome? {
    guard !isBusy else { return nil }
    let id = UUID()
    requestID = id
    guard let epoch else {
      phase = .failed(context.staleMessage)
      return nil
    }
    let style = context.commitStyle()
    phase = .checking
    let checked = await check(write, epoch: epoch)
    guard requestID == id else { return nil }
    switch checked {
    case .passed: break
    case .gone:
      phase = .idle
      return .keyGone
    case .refused(let message):
      phase = .failed(message)
      return nil
    }
    if write.isRemoval || style != .immediate {
      phase = .confirming(
        Confirmation(
          write: write, epoch: epoch, needsSafeModePanel: style != .immediate,
          requiresPassword: style.requiresPassword))
      return nil
    }
    return await send(write, epoch: epoch, confirmed: false, id: id)
  }

  /// Sends `confirmation`'s write while it is still the one asked (the Safe Mode panel verified
  /// the password or Touch ID before this), after its check passes again. A commit style made
  /// stronger since it was asked asks again instead.
  func confirm(_ confirmation: Confirmation) async -> Outcome? {
    guard pending?.id == confirmation.id else { return nil }
    let style = context.commitStyle()
    if (style != .immediate && !confirmation.needsSafeModePanel)
      || (style.requiresPassword && !confirmation.requiresPassword)
    {
      phase = .confirming(
        Confirmation(
          write: confirmation.write, epoch: confirmation.epoch, needsSafeModePanel: true,
          requiresPassword: style.requiresPassword))
      return nil
    }
    let id = UUID()
    requestID = id
    phase = .sending
    let checked = await check(confirmation.write, epoch: confirmation.epoch)
    guard requestID == id else { return nil }
    switch checked {
    case .passed: break
    case .gone:
      phase = .idle
      return .keyGone
    case .refused(let message):
      phase = .failed(message)
      return nil
    }
    return await send(confirmation.write, epoch: confirmation.epoch, confirmed: true, id: id)
  }

  /// Leaves a confirmation, a check or a failure without sending anything; a write already being
  /// sent goes on
  func cancel() {
    guard phase != .sending else { return }
    requestID = UUID()
    phase = .idle
  }

  // MARK: - Private

  private enum CheckResult: Equatable {
    case passed
    case gone
    case refused(String)
  }

  private func check(_ write: RedisKeyWrite, epoch: UInt64) async -> CheckResult {
    guard let check = write.check else { return .passed }
    do {
      switch check {
      case .type(let expected):
        let reply = try await context.read(RedisKeyCommands.type(write.key), epoch)
        guard let type = try RedisKeyViewerModel.keyType(reply) else { return .gone }
        guard type == expected else {
          return .refused("The key is now a \(type.title.lowercased()); reload it.")
        }
        return .passed
      case .absent:
        let reply = try await context.read(RedisKeyCommands.type(write.key), epoch)
        return try RedisKeyViewerModel.keyType(reply) == nil
          ? .passed : .refused(Self.nameTakenMessage)
      case .element(let index, let bytes):
        let command = RedisKeyCommands.lrange(write.key, start: index, stop: index)
        guard let same = try await Self.sameElement(await context.read(command, epoch), as: bytes)
        else {
          return .refused("The list has no element at index \(index) any more; reload the key.")
        }
        return same
          ? .passed
          : .refused("The element at index \(index) changed since it was read; reload the key.")
      }
    } catch {
      return .refused(message(error))
    }
  }

  private func send(
    _ write: RedisKeyWrite, epoch: UInt64, confirmed: Bool, id: UUID
  ) async -> Outcome? {
    phase = .sending
    let started = Date()
    let result: Result<RedisReply, any Error>
    do {
      result = .success(try await context.write(write.command, epoch, confirmed))
    } catch {
      result = .failure(error)
    }
    let elapsed = Date().timeIntervalSince(started)
    // Recorded even when the answer is dropped below: it was sent
    if let outcome = Self.historyOutcome(write.command.args, result: result, elapsed: elapsed) {
      await context.recordHistory([outcome])
    }
    guard requestID == id else { return nil }
    switch result {
    case .failure(let error):
      phase = .failed(message(error))
      return nil
    case .success(let reply):
      let gone: Bool
      switch reply {
      case .null, .integer(0): gone = true
      default: gone = false
      }
      switch write.reply {
      case .existingKey where gone:
        phase = .idle
        return .keyGone
      case .newName where gone:
        phase = .failed(Self.nameTakenMessage)
        return nil
      case .newItem(let message) where gone:
        phase = .failed(message)
        return nil
      default:
        phase = .idle
        return .written(reply)
      }
    }
  }

  /// The History row of a write: `RedisTokenizer.render(args)`, never a reply. Nil when `args`
  /// hold a password (`RedisCommandClassifier.containsSecret`) or the gate refused the write
  /// before sending it (a reconnect since the key was read, the protection level, a bad db).
  nonisolated static func historyOutcome(
    _ args: [Data], result: Result<RedisReply, any Error>, elapsed: TimeInterval
  ) -> QueryHistoryOutcome? {
    guard !RedisCommandClassifier.containsSecret(args) else { return nil }
    switch result {
    case .success:
      return QueryHistoryOutcome(
        sql: RedisTokenizer.render(args), duration: elapsed, rowCount: nil, status: .success,
        errorMessage: nil)
    case .failure(let error):
      if error is RedisCommandRefusal { return nil }
      switch error as? DatabaseError {
      case .sessionChanged, .blockedByProtection, .notConnected, .connectionLocked: return nil
      case .queryCancelled, .batchCancelled:
        return QueryHistoryOutcome(
          sql: RedisTokenizer.render(args), duration: elapsed, rowCount: nil, status: .cancelled,
          errorMessage: nil)
      default:
        return QueryHistoryOutcome(
          sql: RedisTokenizer.render(args), duration: elapsed, rowCount: nil, status: .error,
          errorMessage: error.localizedDescription)
      }
    }
  }

  // MARK: Pre-fill reads (untrusted server data)

  /// Where the edit sheet's old value comes from
  nonisolated enum PrefillSource: Sendable, Equatable {
    /// A string value the key tab read whole
    case loaded(Data)
    /// `HSTRLEN k f` (a field past `RedisKeyWrite.maxInputBytes` is never read), then `HGET k f`
    case hashField(RedisKeyRef, field: Data)
    /// `LRANGE k i i`
    case listElement(RedisKeyRef, index: Int)
    /// `ZSCORE k m`
    case score(RedisKeyRef, member: Data)
  }

  /// What the edit sheet starts from
  nonisolated enum Prefill: Sendable, Equatable {
    /// The old value's exact bytes (at most `RedisKeyWrite.maxInputBytes`) and their text
    case value(Data, text: String)
    /// The score as the server wrote it: the score field's text only (a confirmation shows it
    /// escaped and cut)
    case score(String)
    /// The field, element or member no longer exists
    case gone
    /// Why the form cannot start (escaped and cut)
    case failed(String)
  }

  nonisolated static let tooLargeMessage =
    "This value is too large to edit here. Use a command tab."
  nonisolated static let binaryMessage =
    "This value is binary; it cannot be edited as text. Use a command tab."
  /// The longest score text taken from the server, in bytes (a double needs about 24)
  nonisolated static let maxScoreLength = 64

  /// Reads the old value of `source` under `epoch` (nil: refused as stale, nothing sent). The
  /// reads, the size check and the decode run off the main actor: a value over
  /// `RedisKeyWrite.maxInputBytes` is refused (`tooLargeMessage`) before it is decoded.
  func prefill(_ source: PrefillSource, epoch: UInt64?) async -> Prefill {
    let read = context.read
    let stale = context.staleMessage
    do {
      return try await Self.readPrefill(source) { command in
        guard let epoch else { throw RedisKeyEditError(message: stale) }
        return try await read(command, epoch)
      }
    } catch let error as RedisKeyEditError {
      return .failed(error.message)
    } catch {
      return .failed(message(error))
    }
  }

  @concurrent private nonisolated static func readPrefill(
    _ source: PrefillSource, read: @Sendable (RedisCommand) async throws -> RedisReply
  ) async throws -> Prefill {
    switch source {
    case .loaded(let bytes):
      return try editable(bytes)
    case .hashField(let key, let field):
      guard
        let length = RedisKeyViewerModel.count(try await read(hstrlen(key, field: field)))
      else {
        throw RedisReplyDecodingError(message: "HSTRLEN did not answer a length")
      }
      guard length <= RedisKeyWrite.maxInputBytes else {
        throw RedisKeyEditError(message: tooLargeMessage)
      }
      let reply = try await read(hget(key, field: field))
      if case .null = reply { return .gone }
      return try editable(reply)
    case .listElement(let key, let index):
      let reply = try await read(RedisKeyCommands.lrange(key, start: index, stop: index))
      guard case .array(let items) = reply, items.count <= 1 else {
        throw RedisReplyDecodingError(message: "LRANGE did not answer one element")
      }
      guard let item = items.first else { return .gone }
      return try editable(item)
    case .score(let key, let member):
      guard let written = try score(await read(zscore(key, member: member))) else {
        return .gone
      }
      return .score(written)
    }
  }

  /// `HGET k f`: the field's exact bytes for the edit sheet's pre-fill (a row shows them escaped
  /// and cut). Each argument its own bytes.
  nonisolated static func hget(_ key: RedisKeyRef, field: Data) -> RedisCommand {
    RedisCommand(args: [Data("HGET".utf8), key.bytes, field], db: key.db)
  }

  /// `HSTRLEN k f`: the byte length of the field's value (0 when the field does not exist), read
  /// before `HGET`. Each argument its own bytes.
  nonisolated static func hstrlen(_ key: RedisKeyRef, field: Data) -> RedisCommand {
    RedisCommand(args: [Data("HSTRLEN".utf8), key.bytes, field], db: key.db)
  }

  /// `ZSCORE k m`: the member's score for the edit sheet's pre-fill
  nonisolated static func zscore(_ key: RedisKeyRef, member: Data) -> RedisCommand {
    RedisCommand(args: [Data("ZSCORE".utf8), key.bytes, member], db: key.db)
  }

  /// `LRANGE k i i` against the element an edit started from, off the main actor: nil when the
  /// list has no element at that index. Another size is a change, found before any copy.
  @concurrent nonisolated static func sameElement(
    _ reply: RedisReply, as bytes: Data
  ) async throws -> Bool? {
    guard case .array(let items) = reply, items.count <= 1 else {
      throw RedisReplyDecodingError(message: "LRANGE did not answer one element")
    }
    guard let item = items.first else { return nil }
    if let count = byteCount(item), count != bytes.count { return false }
    return try RedisKeyViewerModel.stringBytes(item) == bytes
  }

  /// `ZSCORE`: the score as the server wrote it, nil when the member is gone. A text past
  /// `maxScoreLength` bytes is no score.
  nonisolated static func score(_ reply: RedisReply) throws -> String? {
    let tooLong = RedisReplyDecodingError(message: "ZSCORE did not answer a score")
    switch reply {
    case .null: return nil
    case .double(let written):
      guard written.utf8.count <= maxScoreLength else { throw tooLong }
      return written
    case .integer(let number): return String(number)
    default:
      if let count = byteCount(reply), count > maxScoreLength { throw tooLong }
      let bytes = try RedisKeyViewerModel.stringBytes(reply)
      return RedisKeyWrite.editableText(bytes) ?? RedisKeyViewerModel.cell(bytes, limit: 64)
    }
  }

  /// A string reply as an old value to edit; its size is checked before its bytes are copied
  private nonisolated static func editable(_ reply: RedisReply) throws -> Prefill {
    if let count = byteCount(reply), count > RedisKeyWrite.maxInputBytes {
      throw RedisKeyEditError(message: tooLargeMessage)
    }
    return try editable(RedisKeyViewerModel.stringBytes(reply))
  }

  /// `bytes` as an old value to edit: at most `RedisKeyWrite.maxInputBytes`, and text
  private nonisolated static func editable(_ bytes: Data) throws -> Prefill {
    guard bytes.count <= RedisKeyWrite.maxInputBytes else {
      throw RedisKeyEditError(message: tooLargeMessage)
    }
    guard let text = RedisKeyWrite.editableText(bytes) else {
      throw RedisKeyEditError(message: binaryMessage)
    }
    return .value(bytes, text: text)
  }

  /// The bytes of a string reply, counted without copying them; nil for any other reply
  private nonisolated static func byteCount(_ reply: RedisReply) -> Int? {
    switch reply {
    case .bulk(let string), .simple(let string), .verbatim(let string):
      switch string {
      case .text(let text): text.utf8.count
      case .bytes(let bytes): bytes.count
      }
    default: nil
    }
  }

  /// An error for the UI: one escaped line, cut
  private func message(_ error: Error) -> String {
    if case .sessionChanged = error as? DatabaseError { return context.staleMessage }
    let text = RedisDisplayText.line(.text(error.localizedDescription))
    guard text.count > Self.maxErrorLength else { return text }
    return String(text.prefix(Self.maxErrorLength)) + "…"
  }
}
