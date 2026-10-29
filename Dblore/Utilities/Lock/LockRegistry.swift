//
//  LockRegistry.swift
//  Dblore
//
//  Threat model: Lock is a gate inside Dblore. Another app or tool on the same Mac can still
//  open a SQLite or DuckDB file, or reach a server that asks no password; server connections
//  are protected by the passwords Dblore keeps in its own Keychain. The identities fold the
//  cheap in-app aliases of one target (host spellings, numeric IPv4 forms, path spellings,
//  symbolic and hard links, a renamed file); a host name that merely resolves to the same
//  address (DNS, /etc/hosts) is another identity. A locked file renamed or replaced outside
//  Dblore stays locked under every inode its path had for the app session; after a relaunch
//  only the inode its path has at the first publish is known.
//

import Foundation
import os

/// What one lock covers. A server lock covers every database of the login (two saved rows on
/// one login share it), a file database lock its file, a workspace lock the workspace id.
nonisolated enum LockIdentity: Hashable, Sendable {
  case server(engine: DatabaseType, host: String, port: Int, username: String)
  case file(engine: DatabaseType, path: String)
  /// The device and inode of a file database that exists: its other names (renamed, moved,
  /// hard-linked) reach the same file
  case fileID(device: UInt64, inode: UInt64)
  case workspace(UUID)

  /// The identity `config` belongs to. The config's own `isLocked` plays no part.
  init(_ config: ConnectionConfig) {
    if config.databaseType.capabilities.isFileBased {
      self = .file(engine: config.databaseType, path: Self.canonicalPath(config.database))
    } else {
      self = .server(
        engine: config.databaseType, host: Self.canonicalHost(config.host), port: config.port,
        username: config.username)
    }
  }

  /// Every identity `config` reaches: its own, the `fileID` of its file when it exists, plus
  /// one per host of a MongoDB connection string (the seed list, or the `+srv` name on the
  /// default port, as `ParsedMongoURI.applied` saves it), which is what the session connects
  /// to. A string that does not parse adds none.
  static func all(_ config: ConnectionConfig) -> Set<LockIdentity> {
    let own = LockIdentity(config)
    var identities: Set<LockIdentity> = [own]
    if let fileID = own.fileIdentity { identities.insert(fileID) }
    guard config.databaseType == .mongodb, let text = config.mongoURI,
      let uri = try? MongoURIParser.parse(text)
    else { return identities }
    for host in uri.hosts {
      identities.insert(
        .server(
          engine: .mongodb, host: canonicalHost(host.name),
          port: host.port ?? MongoURIParser.defaultPort, username: config.username))
    }
    return identities
  }

  /// The `fileID` of a file database that exists (`stat` follows links); nil for any other
  /// identity, or when `stat` fails
  var fileIdentity: LockIdentity? {
    guard case .file(_, let path) = self, path.hasPrefix("/") else { return nil }
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return .fileID(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
  }

  /// The loopback and unspecified addresses, `localhost` and its local names share this name
  private static let loopback = "localhost"

  /// A host name as the network sees it: trimmed, without one trailing dot or IPv6 brackets,
  /// lowercased; an IP address in its one printed form (`inet_ntop`), including the numeric
  /// IPv4 forms the resolver accepts (`127.1`, `2130706433`, hex and octal parts) and an IPv6
  /// zone dropped; an IPv4-mapped IPv6 address as IPv4; 127.0.0.0/8, 0.0.0.0/8, `::1`, `::`,
  /// `*.localhost` and `localhost.localdomain` as `localhost`.
  private static func canonicalHost(_ host: String) -> String {
    var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if name.hasSuffix(".") { name.removeLast() }
    if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
    if name == loopback || name.hasSuffix(".localhost") || name == "localhost.localdomain" {
      return loopback
    }
    // `inet_aton` reads `0177` as octal like the resolver (`inet_pton` reads it as 177). Only
    // digits, dots and hex parts: it would otherwise accept text after a space.
    var v4 = in_addr()
    if name.allSatisfy({ "0123456789abcdefx.".contains($0) }), inet_aton(name, &v4) == 1 {
      return ipv4(withUnsafeBytes(of: v4) { Array($0) })
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, String(name.prefix { $0 != "%" }), &v6) == 1 else { return name }
    let bytes = withUnsafeBytes(of: v6) { Array($0) }
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
      return ipv4(Array(bytes[12..<16]))
    }
    if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return loopback }
    var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    return inet_ntop(AF_INET6, &v6, &text, socklen_t(text.count)) == nil
      ? name
      : String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  /// The four bytes of an IPv4 address dotted, or `localhost` for 127.0.0.0/8 and 0.0.0.0/8
  private static func ipv4(_ bytes: [UInt8]) -> String {
    bytes[0] == 127 || bytes[0] == 0 ? loopback : bytes.map(String.init).joined(separator: ".")
  }

  /// The file a path names: `~` expanded, a `file://` URL taken as its path, a relative path
  /// against the working directory (where the engine opens it), without `.`, `..` or repeated
  /// slashes, symbolic links resolved (through the nearest existing folder when the file does
  /// not exist yet; Foundation also drops a leading `/private`, so `/tmp` and `/private/tmp`
  /// agree), in NFC, and lowercased when the resolved folder's volume ignores case. When the
  /// volume cannot be asked (the sandbox, nothing on the path exists) the path is lowercased
  /// too: macOS's default APFS ignores case, and a lock that also covers a case variant on a
  /// case-sensitive volume fails closed. The DuckDB in-memory name and an empty path name no
  /// file and stay as typed.
  private static func canonicalPath(_ path: String) -> String {
    let url: URL
    // `file://` is a URL for every engine on purpose: wider than an engine opens, fails closed
    if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
      url = fileURL
    } else if path == DuckDBSession.inMemoryPath || path.isEmpty {
      return path
    } else {
      let expanded = (path as NSString).expandingTildeInPath
      url = URL(
        fileURLWithPath: expanded.hasPrefix("/")
          ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded)
    }
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      missing.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    let target = existing.resolvingSymlinksInPath()
    let caseSensitive =
      (try? target.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
      .volumeSupportsCaseSensitiveNames ?? false
    let resolved = missing.reduce(target) { $0.appendingPathComponent($1) }.path
      .precomposedStringWithCanonicalMapping
    return caseSensitive ? resolved : resolved.lowercased()
  }
}

/// Which connections, file databases and workspaces are locked, and which of them this session
/// unlocked. Connection locks come only from saved rows (`SessionManager` republishes them
/// whenever the history loads or changes), never from the `isLocked` of a config handed in.
nonisolated final class LockRegistry: Sendable {
  static let shared = LockRegistry()

  /// Posted on the main actor after `relockAll()`; the object is the registry
  static let didRelock = Notification.Name("ace.thi.dblore.lockRegistry.didRelock")
  /// Posted on the main actor after `setLockedConnections` changed the locked set; the object is
  /// the registry
  static let didChangeLocks = Notification.Name("ace.thi.dblore.lockRegistry.didChangeLocks")

  private struct State {
    var locked: Set<LockIdentity> = []
    var grants: Set<LockIdentity> = []
    /// Every `fileID` each locked file path had at a publish while it stayed locked
    var fileIDs: [LockIdentity: Set<LockIdentity>] = [:]
    var generation = 0

    /// Granted itself, or a `fileID` published for a granted path
    func isGranted(_ identity: LockIdentity) -> Bool {
      grants.contains(identity) || grants.contains { fileIDs[$0]?.contains(identity) == true }
    }
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var lockedIdentities: Set<LockIdentity> { state.withLock { $0.locked } }

  /// Bumped by every `relockAll()`
  var generation: Int { state.withLock { $0.generation } }

  /// Replaces the locked connections and file databases with `identities` (the saved rows that
  /// carry the lock), plus the `fileID` of each locked file that exists now, kept paired with its
  /// path so a grant or revoke of the path covers it whatever `stat` sees later. A path that
  /// stays locked keeps the `fileID`s of earlier publishes too (renamed away, `stat` fails;
  /// replaced, another inode): they stay locked until the path leaves `identities`. Locked
  /// workspaces stay. A grant whose identity is no longer locked ends, so locking it again
  /// asks again.
  func setLockedConnections(_ identities: Set<LockIdentity>) {
    let current = identities.reduce(into: [LockIdentity: LockIdentity]()) { pairs, identity in
      if let fileID = identity.fileIdentity { pairs[identity] = fileID }
    }
    let changed = state.withLock { state in
      let before = state.locked
      var fileIDs: [LockIdentity: Set<LockIdentity>] = [:]
      for identity in identities {
        var paired = state.fileIDs[identity] ?? []
        if let fileID = current[identity] { paired.insert(fileID) }
        if !paired.isEmpty { fileIDs[identity] = paired }
      }
      state.locked = state.locked.filter {
        if case .workspace = $0 { return true }
        return false
      }.union(identities).union(fileIDs.values.joined())
      state.fileIDs = fileIDs
      // A `.file` grant stays while its path is locked: it covers the path's `fileID`s
      state.grants.formIntersection(state.locked)
      return state.locked != before
    }
    guard changed else { return }
    Task { @MainActor in
      NotificationCenter.default.post(name: Self.didChangeLocks, object: self)
    }
  }

  /// Adds the workspace `id` to the locked set (its files are sealed), so a grant of it holds
  /// and a relock covers it again. It stays for the app session.
  func registerWorkspace(_ id: UUID) {
    let changed = state.withLock { $0.locked.insert(.workspace(id)).inserted }
    guard changed else { return }
    Task { @MainActor in
      NotificationCenter.default.post(name: Self.didChangeLocks, object: self)
    }
  }

  /// Drops the workspace `id` from the locked set and its grant (Remove Lock: its files are
  /// plaintext again)
  func unregisterWorkspace(_ id: UUID) {
    let changed = state.withLock { state in
      state.grants.remove(.workspace(id))
      return state.locked.remove(.workspace(id)) != nil
    }
    guard changed else { return }
    Task { @MainActor in
      NotificationCenter.default.post(name: Self.didChangeLocks, object: self)
    }
  }

  /// Locked and not unlocked in this session
  func isBlocked(_ identity: LockIdentity) -> Bool {
    state.withLock { $0.locked.contains(identity) && !$0.isGranted(identity) }
  }

  /// Locked, whether or not this session unlocked it (MCP never serves it)
  func isLocked(_ identity: LockIdentity) -> Bool {
    state.withLock { $0.locked.contains(identity) }
  }

  /// The error for opening `config` while any identity it reaches (`LockIdentity.all`) is
  /// blocked; nil when it may open. Nothing locked: nil at once, without `stat` or parsing.
  func refusal(for config: ConnectionConfig) -> DatabaseError? {
    guard !state.withLock({ $0.locked.isEmpty }) else { return nil }
    return LockIdentity.all(config).contains(where: isBlocked) ? .connectionLocked : nil
  }

  /// Unlocks `identity` until `revoke` or `relockAll`; a file database's grant covers its
  /// file's other names too (the `fileID`s published for its path)
  func grant(_ identity: LockIdentity) {
    state.withLock { _ = $0.grants.insert(identity) }
  }

  /// `grant` only when no `relockAll()` landed since `generation` was read (one step, so a
  /// relock cannot slip in between the check and the grant); false when one did
  func grant(_ identity: LockIdentity, ifGeneration generation: Int) -> Bool {
    grant([identity], ifGeneration: generation)
  }

  /// Grants all of `identities` in one step, or none when a `relockAll()` landed since
  /// `generation` was read. A `fileID` is granted through the locked paths published with it,
  /// so a revoke of such a path covers it again. An identity that is not locked is not granted:
  /// locking it later still asks.
  func grant(_ identities: Set<LockIdentity>, ifGeneration generation: Int) -> Bool {
    state.withLock { state in
      guard state.generation == generation else { return false }
      for identity in identities {
        let paths = state.fileIDs.filter { $0.value.contains(identity) }.keys
        if !paths.isEmpty {
          state.grants.formUnion(paths)
        } else if state.locked.contains(identity) {
          state.grants.insert(identity)
        }
      }
      return true
    }
  }

  func revoke(_ identity: LockIdentity) {
    state.withLock { _ = $0.grants.remove(identity) }
  }

  /// Drops every session unlock and tells the app (`didRelock`) to cover locked items again
  func relockAll() {
    state.withLock {
      $0.grants.removeAll()
      $0.generation += 1
    }
    Task { @MainActor in
      NotificationCenter.default.post(name: Self.didRelock, object: self)
    }
  }
}
