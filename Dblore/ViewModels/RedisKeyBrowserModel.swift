// RedisKeyBrowserModel.swift
// The Redis sidebar's key browser: the databases 0–15 plus those `INFO keyspace` names (never
// `CONFIG GET`), with their key counts, and per open database the keys read by paged `SCAN`
// (the user's MATCH pattern as one argument), deduplicated, capped, and shown as a tree split
// on the `:` byte. Every read goes through the Redis gate as the app's own (`userInitiated:
// false`) under the workspace's protection policy; they are reads, so read-only connections
// list keys too. Server text is untrusted: parsed strictly with size caps, labels escaped by
// `RedisDisplayText`. A key's identity is its `RedisKeyRef` (db and exact bytes), so NFC / NFD
// twins stay two rows. Opening a database or picking a key in the tree never changes the db
// the command tabs run in (`WorkspaceManager.redisDatabaseChoice`).

import Foundation
import Observation

@MainActor
@Observable
final class RedisKeyBrowserModel {
  /// The databases always listed; `INFO keyspace` adds any other that holds keys
  nonisolated static let listedDatabases = 0...15
  /// The most keys kept for one database; "Load more" stops there
  nonisolated static let maxKeysPerDatabase = 10_000
  /// One "Load more" stops once it added this many keys
  nonisolated static let pageKeys = RedisKeyCommands.scanCount
  /// The most `SCAN` round trips of one "Load more" (a MATCH can answer empty pages)
  nonisolated static let maxScansPerPage = 10
  /// The most tree levels: past them the rest of the key, colons included, is the leaf's label
  nonisolated static let maxTreeDepth = 32
  /// The longest label, in characters, before it is cut with "…"
  nonisolated static let maxLabelLength = 256
  /// The most bytes of the `INFO keyspace` reply read; the rest is ignored
  nonisolated static let maxKeyspaceBytes = 65_536
  /// The most databases read from `INFO keyspace`
  nonisolated static let maxKeyspaceDatabases = 256
  /// The longest error text shown, in characters
  nonisolated static let maxErrorLength = 300

  /// One database row
  struct Database: Identifiable, Equatable {
    let index: Int
    /// From `INFO keyspace` (0 when it does not name the db); nil when it could not be read
    let keyCount: Int?
    var id: Int { index }
  }

  /// A tree row's identity: a folder by its db and its prefix up to and including its `:`, a
  /// key by its `RedisKeyRef`. Never built from a label.
  nonisolated enum NodeID: Hashable, Sendable {
    case folder(db: Int, prefix: Data)
    case key(RedisKeyRef)
  }

  /// A folder (keys sharing a prefix up to a `:`) or a key
  nonisolated struct KeyNode: Equatable, Sendable {
    let id: NodeID
    /// The escaped segment (`label(_:)`); empty for an empty segment
    let label: String
    /// A key's whole name, a folder's segment, escaped (`label(_:)`); built with the tree, never
    /// in a row's body
    let tooltip: String
    /// A folder's rows, folders before keys at the same segment, in byte order
    let children: [KeyNode]
    /// Keys below a folder; 1 for a key
    let keyCount: Int
  }

  /// One visible row of a database's tree
  nonisolated struct Row: Identifiable, Equatable, Sendable {
    let id: NodeID
    let depth: Int
    let label: String
    let tooltip: String
    /// Nil for a key
    let folderKeyCount: Int?
    let isExpanded: Bool
  }

  /// The keys read so far in one database for the current pattern
  struct Listing {
    /// In the order read, without repeats
    var keys: [Data] = []
    var seen: Set<Data> = []
    /// The cursor of the next `SCAN`
    var cursor: UInt64 = 0
    /// The server answered cursor 0: every key matching the pattern was read
    var isComplete = false
    /// `maxKeysPerDatabase` keys kept: no more are read
    var isCapped = false
    var isLoading = false
    /// The last read failed (escaped and cut); the keys read before it stay
    var error: String?
    var tree: [KeyNode] = []
    /// Results of a read are dropped once the listing they were started for is gone
    fileprivate var token = UUID()

    var canLoadMore: Bool { !isComplete && !isCapped && !isLoading }
  }

  /// Empty until `INFO keyspace` answered (or failed: then 0–15 without counts)
  private(set) var databases: [Database] = []
  private(set) var isLoadingDatabases = false
  /// Why the key counts could not be read (escaped and cut)
  private(set) var databasesError: String?
  private(set) var listings: [Int: Listing] = [:]
  private(set) var expandedDatabases: Set<Int> = []
  private(set) var expandedFolders: Set<NodeID> = []
  /// The MATCH pattern as typed; empty matches every key
  private(set) var pattern = ""
  /// The key picked in the tree, set in the same frame as the click. Only a key row's own body
  /// reads it, so a click redraws no list.
  private(set) var selectedKey: RedisKeyRef?
  /// The visible rows of each listed db (`rows(_:expanded:expandsAll:)`), rebuilt only when its
  /// tree, `expandedFolders` or `pattern` change, never on a selection
  private var visibleRows: [Int: [Row]] = [:]

  @ObservationIgnored private var manager: DatabaseConnectionManager?
  @ObservationIgnored private var policy: @MainActor () -> ProtectionPolicy = {
    ProtectionPolicy(config: nil)
  }
  /// The db `INFO keyspace` runs in (the connection's own)
  @ObservationIgnored private var homeDatabase = 0
  /// The connection the reads were started on; a reconnect since makes the gate refuse them
  @ObservationIgnored private var epoch: UInt64?
  @ObservationIgnored private var databasesToken = UUID()

  /// Loads the database list and opens `homeDatabase`, unless already loaded for the current
  /// connection. `policy` is read at each read, so a protection change since counts.
  func open(
    manager: DatabaseConnectionManager, policy: @escaping @MainActor () -> ProtectionPolicy,
    homeDatabase: Int
  ) async {
    let current = await manager.connectionEpoch
    guard current != epoch || self.manager !== manager else { return }
    reset()
    self.manager = manager
    self.policy = policy
    self.homeDatabase =
      (0...DatabaseConnectionManager.maxRedisDatabaseIndex).contains(homeDatabase)
      ? homeDatabase : 0
    epoch = current
    expandedDatabases = [self.homeDatabase]
    await loadDatabases()
    await loadPage(db: self.homeDatabase)
  }

  /// Forgets everything read (a disconnect or another connection); reads in flight are dropped
  func reset() {
    epoch = nil
    manager = nil
    databasesToken = UUID()
    databases = []
    isLoadingDatabases = false
    databasesError = nil
    listings = [:]
    visibleRows = [:]
    expandedDatabases = []
    expandedFolders = []
    pattern = ""
    selectedKey = nil
  }

  /// Opens or closes a database row; its first page is read when it opens unread
  func setDatabase(_ index: Int, expanded: Bool) {
    guard expanded else {
      expandedDatabases.remove(index)
      return
    }
    expandedDatabases.insert(index)
    if listings[index] == nil { Task { await loadPage(db: index) } }
  }

  /// Opens or closes a folder; ignored while a pattern is applied (every folder draws open)
  func toggleFolder(_ id: NodeID) {
    guard pattern.isEmpty, case .folder(let db, _) = id else { return }
    if expandedFolders.remove(id) == nil { expandedFolders.insert(id) }
    updateRows(db: db)
  }

  /// Picks `key` in the tree at once (nothing is read)
  func select(_ key: RedisKeyRef) {
    selectedKey = key
  }

  /// Reads every open database again from its first page under `text`; returns the reads
  @discardableResult
  func setPattern(_ text: String) -> Task<Void, Never>? {
    guard text != pattern else { return nil }
    pattern = text
    // Cleared now, so the old pattern's keys never show under the new one
    listings = [:]
    visibleRows = [:]
    expandedFolders = []
    return Task { await reloadListings() }
  }

  /// Reads the key counts and every open database again
  func refresh() {
    guard epoch != nil else { return }
    Task {
      await loadDatabases()
      await reloadListings()
    }
  }

  /// Drops every listing (and the folders opened in them), then reads the first page of each
  /// open database. Pages in flight for the dropped listings are dropped when they answer.
  func reloadListings() async {
    listings = [:]
    visibleRows = [:]
    expandedFolders = []
    for db in expandedDatabases.sorted() {
      await loadPage(db: db)
    }
  }

  /// `INFO keyspace` in the connection's db: the database rows and their key counts
  func loadDatabases() async {
    guard let manager, let epoch else { return }
    let token = UUID()
    databasesToken = token
    isLoadingDatabases = true
    let command = RedisKeyCommands.infoKeyspace(db: homeDatabase)
    var keyspace: [Int: Int]?
    var failure: String?
    do {
      let result = try await manager.executeGatedRedisCommand(
        command, policy: policy(), connectionEpoch: epoch, userInitiated: false)
      keyspace = try await Self.decodeKeyspace(result)
    } catch {
      failure = Self.message(error)
    }
    guard databasesToken == token else { return }
    databases = Self.databases(keyspace: keyspace, homeDatabase: homeDatabase)
    databasesError = failure
    isLoadingDatabases = false
  }

  /// Reads the next page of `db` ("Load more", or the first page): `SCAN` from the listing's
  /// cursor until `pageKeys` new keys, the end, the cap, or `maxScansPerPage` round trips.
  /// A failed read keeps the keys read before it and the cursor to resume from.
  func loadPage(db: Int) async {
    guard let manager, let epoch else { return }
    var listing = listings[db] ?? Listing()
    guard listing.canLoadMore else { return }
    listing.isLoading = true
    listing.error = nil
    listings[db] = listing
    let token = listing.token
    let match = Self.matchArgument(pattern)
    var added = 0
    for _ in 0..<Self.maxScansPerPage {
      do {
        let result = try await manager.executeGatedRedisCommand(
          RedisKeyCommands.scan(db: db, cursor: listing.cursor, match: match),
          policy: policy(), connectionEpoch: epoch, userInitiated: false)
        let page = try await Self.decodeScan(result)
        guard listings[db]?.token == token else { return }
        added += Self.merge(
          page.keys, into: &listing.keys, seen: &listing.seen, cap: Self.maxKeysPerDatabase)
        listing.cursor = page.cursor
        listing.isComplete = page.cursor == 0
        listing.isCapped = listing.keys.count >= Self.maxKeysPerDatabase
      } catch {
        guard listings[db]?.token == token else { return }
        listing.error = Self.message(error)
        break
      }
      if listing.isComplete || listing.isCapped || added >= Self.pageKeys { break }
    }
    let tree = await Self.buildTree(listing.keys, db: db)
    guard listings[db]?.token == token else { return }
    listing.tree = tree
    listing.isLoading = false
    listings[db] = listing
    updateRows(db: db)
  }

  /// The visible rows of `db`'s tree (cached); every folder draws open while a pattern is applied
  func rows(db: Int) -> [Row] {
    visibleRows[db] ?? []
  }

  /// Rebuilds the cached rows of `db` from its tree, `expandedFolders` and `pattern`
  private func updateRows(db: Int) {
    guard let tree = listings[db]?.tree else {
      visibleRows[db] = nil
      return
    }
    visibleRows[db] = Self.rows(tree, expanded: expandedFolders, expandsAll: !pattern.isEmpty)
  }

  // MARK: - Parsing (untrusted server data)

  /// The MATCH argument: the pattern's exact UTF-8 bytes, one argument; `*` when empty
  nonisolated static func matchArgument(_ pattern: String) -> Data {
    pattern.isEmpty ? Data("*".utf8) : Data(pattern.utf8)
  }

  /// Key counts by db index from an `INFO keyspace` text: lines `db<N>:keys=<M>,…` (CRLF or
  /// LF). Only the first `maxKeyspaceBytes` are read and the first `maxKeyspaceDatabases`
  /// databases kept; a line that does not fit (other digits than ASCII, an index past
  /// `DatabaseConnectionManager.maxRedisDatabaseIndex`, a count past Int) is ignored, and a
  /// repeated db keeps its first count.
  nonisolated static func parseKeyspace(_ text: Data) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for line in text.prefix(maxKeyspaceBytes).split(separator: 0x0A) {
      guard counts.count < maxKeyspaceDatabases else { break }
      var line = Data(line)
      if line.last == 0x0D { line.removeLast() }
      guard line.starts(with: Data("db".utf8)),
        let colon = line.firstIndex(of: UInt8(ascii: ":")),
        let db = decimal(line[line.startIndex + 2..<colon], maxDigits: 10),
        db <= DatabaseConnectionManager.maxRedisDatabaseIndex
      else { continue }
      let fields = line[(colon + 1)...]
      let first = fields.prefix { $0 != UInt8(ascii: ",") }
      let keysPrefix = Data("keys=".utf8)
      guard first.starts(with: keysPrefix),
        let keys = decimal(first.dropFirst(keysPrefix.count), maxDigits: 19)
      else { continue }
      if counts[db] == nil { counts[db] = keys }
    }
    return counts
  }

  /// The database rows: 0–15, `homeDatabase` (opened by `open`, so it always has a row) and
  /// every db in `keyspace`, in index order. Nil `keyspace` (the counts could not be read):
  /// those dbs without counts. A `homeDatabase` past
  /// `DatabaseConnectionManager.maxRedisDatabaseIndex` is not listed.
  nonisolated static func databases(keyspace: [Int: Int]?, homeDatabase: Int) -> [Database] {
    var indexes = Set(listedDatabases).union(keyspace.map { Array($0.keys) } ?? [])
    if (0...DatabaseConnectionManager.maxRedisDatabaseIndex).contains(homeDatabase) {
      indexes.insert(homeDatabase)
    }
    return indexes.sorted().map { index in
      Database(index: index, keyCount: keyspace.map { $0[index] ?? 0 })
    }
  }

  /// The `INFO keyspace` reply: one bulk or verbatim string
  nonisolated static func keyspaceText(_ reply: RedisReply) throws -> Data {
    switch reply {
    case .bulk(let string), .verbatim(let string): return bytes(string)
    default: throw RedisReplyDecodingError(message: "INFO keyspace did not answer a string")
    }
  }

  /// A `SCAN` reply: `[cursor, [key, …]]`, the cursor a UInt64 in ASCII digits, every key a
  /// bulk string kept as its exact bytes
  nonisolated static func scanPage(_ reply: RedisReply) throws -> (cursor: UInt64, keys: [Data]) {
    guard case .array(let parts) = reply, parts.count == 2,
      case .bulk(let cursorText) = parts[0], case .array(let items) = parts[1],
      let cursor = cursor(bytes(cursorText))
    else {
      throw RedisReplyDecodingError(message: "SCAN did not answer a cursor and a list of keys")
    }
    let keys = try items.map { item -> Data in
      guard case .bulk(let key) = item else {
        throw RedisReplyDecodingError(message: "SCAN answered a key that is not a string")
      }
      return bytes(key)
    }
    return (cursor, keys)
  }

  /// Appends the keys of `page` not yet `seen` until `keys` holds `cap`; returns how many
  /// were added
  nonisolated static func merge(
    _ page: [Data], into keys: inout [Data], seen: inout Set<Data>, cap: Int
  ) -> Int {
    var added = 0
    for key in page where keys.count < cap && seen.insert(key).inserted {
      keys.append(key)
      added += 1
    }
    return added
  }

  // MARK: - Tree

  /// `keys` of `db` as a tree split on the `:` byte (0x3A), at most `maxTreeDepth` levels.
  /// Empty segments stay (`a::b` has an empty folder); a key that is also a prefix (`user` and
  /// `user:1`) is a key row and a folder row. Rows sort by their segment's bytes.
  nonisolated static func tree(_ keys: [Data], db: Int) -> [KeyNode] {
    let root = TreeBuilder()
    for key in keys {
      let parts = key.split(
        separator: 0x3A, maxSplits: maxTreeDepth - 1, omittingEmptySubsequences: false)
      var node = root
      var prefix = Data()
      for part in parts.dropLast() {
        let segment = Data(part)
        prefix.append(segment)
        prefix.append(0x3A)
        if let next = node.folders[segment] {
          node = next
        } else {
          let next = TreeBuilder(prefix: prefix)
          node.folders[segment] = next
          node = next
        }
      }
      node.keys.append((Data(parts.last ?? Data()), key))
    }
    return root.nodes(db: db)
  }

  /// The rows shown: each node, then the children of an expanded folder (all with `expandsAll`)
  nonisolated static func rows(
    _ tree: [KeyNode], expanded: Set<NodeID>, expandsAll: Bool
  ) -> [Row] {
    var rows: [Row] = []
    func append(_ nodes: [KeyNode], depth: Int) {
      for node in nodes {
        let isFolder: Bool
        if case .folder = node.id { isFolder = true } else { isFolder = false }
        let isOpen = isFolder && (expandsAll || expanded.contains(node.id))
        rows.append(
          Row(
            id: node.id, depth: depth, label: node.label, tooltip: node.tooltip,
            folderKeyCount: isFolder ? node.keyCount : nil, isExpanded: isOpen))
        if isOpen { append(node.children, depth: depth + 1) }
      }
    }
    append(tree, depth: 0)
    return rows
  }

  /// `bytes` for the UI: `RedisDisplayText.line` (control, invisible and non-UTF-8 bytes
  /// escaped), cut after `maxLabelLength` characters with "…". Only the first
  /// `maxLabelLength * 4` bytes (backed off to a UTF-8 scalar boundary) are escaped, so a
  /// multi-MB key costs no more than a short one; a longer key is judged text or bytes by that
  /// kept prefix, and always ends with "…".
  nonisolated static func label(_ bytes: Data) -> String {
    let cutBytes = maxLabelLength * 4
    var kept = bytes
    if bytes.count > cutBytes {
      kept = Data(bytes.prefix(cutBytes))
      // Drop a scalar the cut split (at most 3 bytes), so valid UTF-8 stays text
      for drop in 0...3 where String(data: kept.dropLast(drop), encoding: .utf8) != nil {
        kept = Data(kept.dropLast(drop))
        break
      }
    }
    let text = RedisDisplayText.line(replyString(kept))
    guard text.count > maxLabelLength || kept.count < bytes.count else { return text }
    return String(text.prefix(maxLabelLength)) + "…"
  }

  // MARK: - Private

  /// A folder being built: its sub-folders by segment and its keys (segment, whole key)
  private nonisolated final class TreeBuilder {
    let prefix: Data
    var folders: [Data: TreeBuilder] = [:]
    var keys: [(segment: Data, key: Data)] = []

    init(prefix: Data = Data()) {
      self.prefix = prefix
    }

    /// Sorted by segment bytes, a folder before a key with the same segment
    func nodes(db: Int) -> [KeyNode] {
      let folderNodes = folders.map { segment, builder in
        let children = builder.nodes(db: db)
        let label = RedisKeyBrowserModel.label(segment)
        return (
          segment,
          KeyNode(
            id: .folder(db: db, prefix: builder.prefix),
            label: label, tooltip: label, children: children,
            keyCount: children.reduce(0) { $0 + $1.keyCount })
        )
      }
      let keyNodes = keys.map { segment, key in
        (
          segment,
          KeyNode(
            id: .key(RedisKeyRef(db: db, bytes: key)),
            label: RedisKeyBrowserModel.label(segment), tooltip: RedisKeyBrowserModel.label(key),
            children: [], keyCount: 1)
        )
      }
      let sortedFolders = folderNodes.sorted { $0.0.lexicographicallyPrecedes($1.0) }
      let sortedKeys = keyNodes.sorted { $0.0.lexicographicallyPrecedes($1.0) }
      // Merge, a folder first on a tie
      var merged: [KeyNode] = []
      var folderIndex = 0
      var keyIndex = 0
      while folderIndex < sortedFolders.count || keyIndex < sortedKeys.count {
        let takesFolder =
          keyIndex == sortedKeys.count
          || (folderIndex < sortedFolders.count
            && !sortedKeys[keyIndex].0.lexicographicallyPrecedes(sortedFolders[folderIndex].0))
        if takesFolder {
          merged.append(sortedFolders[folderIndex].1)
          folderIndex += 1
        } else {
          merged.append(sortedKeys[keyIndex].1)
          keyIndex += 1
        }
      }
      return merged
    }
  }

  @concurrent private nonisolated static func decodeKeyspace(
    _ result: QueryResult
  ) async throws -> [Int: Int] {
    parseKeyspace(try keyspaceText(RedisReply(rows: result.rows)))
  }

  @concurrent private nonisolated static func decodeScan(
    _ result: QueryResult
  ) async throws -> (cursor: UInt64, keys: [Data]) {
    try scanPage(RedisReply(rows: result.rows))
  }

  @concurrent private nonisolated static func buildTree(
    _ keys: [Data], db: Int
  ) async -> [KeyNode] {
    tree(keys, db: db)
  }

  /// An error for the UI: one escaped line, cut
  private nonisolated static func message(_ error: Error) -> String {
    let text = RedisDisplayText.line(.text(error.localizedDescription))
    guard text.count > maxErrorLength else { return text }
    return String(text.prefix(maxErrorLength)) + "…"
  }

  /// A reply string's exact bytes
  private nonisolated static func bytes(_ string: RedisReplyString) -> Data {
    switch string {
    case .text(let text): Data(text.utf8)
    case .bytes(let bytes): bytes
    }
  }

  /// `bytes` as text when they are valid UTF-8 (decoding gives back the same bytes)
  private nonisolated static func replyString(_ bytes: Data) -> RedisReplyString {
    guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
      return .bytes(bytes)
    }
    return .text(text)
  }

  /// ASCII digits only, 1 to `maxDigits` of them, that fit an Int; else nil
  private nonisolated static func decimal(_ digits: Data.SubSequence, maxDigits: Int) -> Int? {
    guard (1...maxDigits).contains(digits.count),
      digits.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return Int(String(decoding: digits, as: UTF8.self))
  }

  /// A SCAN cursor: ASCII digits only, 1 to 20 of them, that fit a UInt64; else nil
  private nonisolated static func cursor(_ digits: Data) -> UInt64? {
    guard (1...20).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return UInt64(String(decoding: digits, as: UTF8.self))
  }
}
