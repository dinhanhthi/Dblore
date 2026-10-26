//
//  LockedFileIO.swift
//  Dblore
//

import CryptoKit
import Foundation

/// The only reader and writer of a locked workspace's files and the only place that seals:
/// callers hand it plaintext bytes and get plaintext back. A document that carries a lock key id
/// (the id of the workspace whose key sealed it) is always written as an envelope; when it
/// cannot be sealed nothing is written, never plaintext. Reading, sniffing and sealing run off
/// the main actor, except `sealPayload`, which quit uses synchronously.
nonisolated struct LockedFileIO: Sendable {
  static let shared = LockedFileIO()

  /// A file's plaintext and, for an envelope, the session that opened it (its `workspaceId` is
  /// the document's lock key id)
  struct Read: Sendable {
    let plaintext: Data
    let session: WorkspaceLockSession?
  }

  /// Asked for the session of an envelope's workspace when none is open or the workspace is
  /// relocked; nil when the owner did not unlock
  typealias Unlock = @Sendable (LockEnvelope.Header) async -> WorkspaceLockSession?

  let sessions: WorkspaceLockSessions
  let registry: LockRegistry

  init(sessions: WorkspaceLockSessions = .shared, registry: LockRegistry = .shared) {
    self.sessions = sessions
    self.registry = registry
  }

  /// The plaintext of the file at `url`: as is when it is not an envelope, else opened with its
  /// workspace's open session, or with the session `unlock` returns. An envelope of another
  /// `kind` than the caller expects is refused before asking. The caller holds a returned
  /// session (`WorkspaceLockSessions.hold`) for as long as the document is open.
  @concurrent func read(
    from url: URL, kind: LockEnvelope.Kind? = nil, unlock: Unlock
  ) async throws -> Read {
    try await open(Data(contentsOf: url), kind: kind, unlock: unlock)
  }

  /// `read` of bytes already read: as is when they are not an envelope, else opened with the
  /// open session of its workspace or the one `unlock` returns (`kind`: the only envelope kind
  /// accepted, nil for any)
  @concurrent func open(
    _ data: Data, kind: LockEnvelope.Kind? = nil, unlock: Unlock
  ) async throws -> Read {
    guard let header = try LockEnvelope.sniff(data) else {
      return Read(plaintext: data, session: nil)
    }
    if let kind, header.kind != kind { throw LockedFileIOError.wrongKind }
    let id = header.workspaceId
    var session = registry.isBlocked(.workspace(id)) ? nil : sessions.session(for: id)
    if session == nil { session = await unlock(header) }
    guard let session, session.workspaceId == id else {
      throw LockedFileIOError.unlockRefused(id)
    }
    return Read(
      plaintext: try LockEnvelope.open(data, contentKey: session.contentKey), session: session)
  }

  /// Writes `plaintext` to `url`: sealed when `lockKeyId` is set, as is otherwise. A plaintext
  /// write never replaces an envelope (a document that lost its key, e.g. a tab recreated
  /// without opening its sealed file) unless `replacingEnvelope`, which only Remove Lock passes.
  @concurrent func write(
    _ plaintext: Data, kind: LockEnvelope.Kind, lockKeyId: UUID?, to url: URL,
    replacingEnvelope: Bool = false
  ) async throws {
    if lockKeyId == nil, !replacingEnvelope, Self.isEnvelope(at: url) {
      throw LockedFileIOError.sealedTarget
    }
    let data =
      try lockKeyId.map { try sealPayload(plaintext, kind: kind, lockKeyId: $0) } ?? plaintext
    try SecurityScopedAccess.write(data, to: url)
  }

  /// Whether the file at `url` starts with the envelope magic (reads 8 bytes; false when it
  /// does not exist or cannot be read)
  static func isEnvelope(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: LockEnvelope.magic.count)) ?? Data()
    return head.elementsEqual(LockEnvelope.magic)
  }

  /// Rewrites the file at `url` in one atomic write: as `session`'s envelope (Lock Workspace),
  /// or as plaintext when `session` is nil (Remove Lock). Its current bytes are opened with the
  /// open sessions, never asking; on any error the file is left as it was.
  @concurrent func rewrite(
    _ url: URL, kind: LockEnvelope.Kind, sealingWith session: WorkspaceLockSession?
  ) async throws {
    let current = try await read(from: url) { _ in nil }
    let data =
      try session.map {
        try LockEnvelope.seal(
          current.plaintext, kind: kind, workspaceId: $0.workspaceId, wrapBlock: $0.wrapBlock,
          contentKey: $0.contentKey)
      } ?? current.plaintext
    try SecurityScopedAccess.write(data, to: url)
  }

  /// One envelope of `plaintext` with the open session of `lockKeyId`: AES-GCM only, the wrap
  /// block copied verbatim, never PBKDF2. Synchronous for the quit flush and the quit-time launch
  /// snapshot; every other write goes through `write`. Throws when no session is open.
  func sealPayload(_ plaintext: Data, kind: LockEnvelope.Kind, lockKeyId: UUID) throws -> Data {
    guard let session = sessions.session(for: lockKeyId) else {
      throw LockedFileIOError.sessionMissing(lockKeyId)
    }
    return try LockEnvelope.seal(
      plaintext, kind: kind, workspaceId: lockKeyId, wrapBlock: session.wrapBlock,
      contentKey: session.contentKey)
  }
}

extension LockedFileIO {
  /// The unlock of a sealed file's workspace through this Mac's Keychain, by `LockCenter`
  /// (which registers the workspace before granting it and keeps `relocked` current): owner
  /// authentication (Touch ID or the Mac password, the system prompt) reads the workspace's
  /// stored content key. A workspace with no key stored here (Lock password only, or sealed on
  /// another Mac) is refused without a prompt. Under the test host the shared center never
  /// prompts.
  @MainActor static func keychainUnlock(
    reason: String, center: LockCenter = .shared, keyStore: LockKeyStore = LockKeyStore()
  ) -> Unlock {
    { @MainActor header in
      await center.unlockWorkspace(header, reason: reason, keyStore: keyStore)
    }
  }

  /// The envelope header of the file at `url`, from its first bytes only; nil for a plaintext
  /// file. Throws when it cannot be read, or starts with the magic but is not a v1 header.
  @concurrent static func sniffHeader(at url: URL) async throws -> LockEnvelope.Header? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try LockEnvelope.sniff(handle.read(upToCount: LockEnvelope.minimumLength) ?? Data())
  }
}

// MARK: - Re-seal after a Lock password change

nonisolated extension LockedFileIO {
  /// A file that was not rewritten, and why. The file is left as it was.
  struct FileFailure: Sendable, Equatable {
    let url: URL
    let reason: String
  }

  struct ResealResult: Sendable {
    /// Files left untouched: they keep their old wrap block (the old Lock password or this
    /// Mac's Keychain item still opens them)
    var failures: [FileFailure] = []
    /// The new session (same key, new wrap block) of each workspace whose key was found, already
    /// swapped into an open window's session; its files that failed are in `failures`
    var sessions: [WorkspaceLockSession] = []
  }

  /// Re-seals each locked workspace of `workspaces` (Recents) and its tab files under
  /// `newPassword`. Each workspace keeps its content key, found as: the open session's key
  /// when a window has it open, else `storedKeys` (read from this Mac's Keychain by the caller
  /// with one evaluated owner authentication), else the `.sqlws` wrap block unwrapped with
  /// `currentPassword`. Each file is one atomic write of its bytes read just before; a file
  /// sealed by another workspace, or plaintext, is skipped (a `.sqlws` is listed). An open
  /// session takes the new wrap block. PBKDF2 runs here, off the main actor (twice per
  /// workspace: the new block is checked by unwrapping it). `progress` reports each workspace
  /// twice: before it, and once its key is ready (nothing written yet).
  @concurrent func reseal(
    _ workspaces: [WorkspaceHistoryEntry], currentPassword: String?, newPassword: String,
    storedKeys: [UUID: SymmetricKey] = [:],
    iterations: Int = SafeModePasswordRecord.lockIterations,
    progress: @Sendable (Int, Int) -> Void = { _, _ in }
  ) async -> ResealResult {
    var result = ResealResult()
    for (index, entry) in workspaces.enumerated() {
      progress(index, workspaces.count)
      reseal(
        entry, currentPassword: currentPassword, newPassword: newPassword,
        storedKeys: storedKeys, iterations: iterations, into: &result
      ) { progress(index, workspaces.count) }
    }
    progress(workspaces.count, workspaces.count)
    return result
  }

  /// `keyReady` runs once the workspace's new wrap block is made, before any file is written.
  /// Each file is read again just before it is sealed (a save of an open window meanwhile is
  /// kept: it opens with the same key); a `.sqlws` that is no longer this workspace's envelope
  /// is left as it is and listed.
  private func reseal(
    _ entry: WorkspaceHistoryEntry, currentPassword: String?, newPassword: String,
    storedKeys: [UUID: SymmetricKey], iterations: Int, into result: inout ResealResult,
    keyReady: () -> Void
  ) {
    let access = Self.access(entry.bookmark, fallback: entry.fileURL)
    // Reaches the bookmark-less tab files next to the .sqlws
    let folderAccess = entry.folderBookmark
      .flatMap { try? SecurityScopedAccess.resolve($0) }
      .map { SecurityScopedAccessToken(url: $0.url) }
    defer {
      access.token?.release()
      folderAccess?.release()
    }
    let url = access.url
    do {
      let data = try Data(contentsOf: url)
      guard let header = try LockEnvelope.sniff(data), header.kind == .workspace else { return }
      let id = header.workspaceId
      guard
        let key = sessions.session(for: id)?.contentKey ?? storedKeys[id]
          ?? currentPassword.flatMap({ try? LockEnvelope.unwrapKey(header.wrapBlock, password: $0) }
          )
      else { throw LockEnvelopeError.wrongPassword }
      let plaintext = try LockEnvelope.open(data, contentKey: key)
      let block = try LockEnvelope.makeWrapBlock(
        contentKey: key, password: newPassword, workspaceId: id, iterations: iterations)
      guard try LockEnvelope.unwrapKey(block, password: newPassword) == key else {
        throw LockEnvelopeError.wrongPassword
      }
      let session = WorkspaceLockSession(workspaceId: id, contentKey: key, wrapBlock: block)
      // An open window seals its next writes with the new block, so a file that fails below
      // is sealed again on its next save
      sessions.replace(session)
      result.sessions.append(session)
      keyReady()
      for tab in try JSONDecoder().decode(TabFiles.self, from: plaintext).tabs ?? [] {
        guard let fileURL = tab.fileURL else { continue }
        let tabAccess = Self.access(tab.bookmark, fallback: fileURL)
        defer { tabAccess.token?.release() }
        do {
          try Self.reseal(tabAccess.url, with: session)
        } catch {
          result.failures.append(FileFailure(url: fileURL, reason: error.localizedDescription))
        }
      }
      // The bytes on disk now, not those read above
      let current = try Data(contentsOf: url)
      guard let now = try LockEnvelope.sniff(current), now.kind == .workspace,
        now.workspaceId == id
      else { throw LockedFileIOError.lockRemovedMeanwhile }
      try SecurityScopedAccess.write(
        LockEnvelope.seal(
          LockEnvelope.open(current, contentKey: key), kind: .workspace, workspaceId: id,
          wrapBlock: block, contentKey: key),
        to: url)
    } catch {
      result.failures.append(FileFailure(url: url, reason: error.localizedDescription))
    }
  }

  /// The tab files a .sqlws lists (`Workspace.tabs`), read off the main actor
  private struct TabFiles: Decodable {
    struct Tab: Decodable {
      let fileURL: URL?
      let bookmark: Data?
    }
    let tabs: [Tab]?
  }

  /// One tab file of `session`'s workspace sealed again with its new wrap block; plaintext and
  /// other workspaces' files are left alone
  private static func reseal(_ url: URL, with session: WorkspaceLockSession) throws {
    let data = try Data(contentsOf: url)
    guard let header = try LockEnvelope.sniff(data), header.workspaceId == session.workspaceId
    else { return }
    let plaintext = try LockEnvelope.open(data, contentKey: session.contentKey)
    try SecurityScopedAccess.write(
      LockEnvelope.seal(
        plaintext, kind: header.kind, workspaceId: session.workspaceId,
        wrapBlock: session.wrapBlock, contentKey: session.contentKey),
      to: url)
  }

  /// The file a stored bookmark resolves to, with access started, else `fallback` as is
  private static func access(
    _ bookmark: Data?, fallback: URL
  ) -> (url: URL, token: SecurityScopedAccessToken?) {
    guard let bookmark, let resolved = try? SecurityScopedAccess.resolve(bookmark) else {
      return (fallback, nil)
    }
    return (resolved.url, SecurityScopedAccessToken(url: resolved.url))
  }
}

/// Why a locked workspace's file was not read or written. Never carries key material.
nonisolated enum LockedFileIOError: Error, Equatable, LocalizedError, Sendable {
  /// The workspace was not unlocked, so its file stays sealed
  case unlockRefused(UUID)
  /// The document carries a lock key id but its workspace is not open: nothing was written
  case sessionMissing(UUID)
  /// A plaintext write would replace an encrypted file: nothing was written
  case sealedTarget
  /// The envelope holds another kind of file than the one opened
  case wrongKind
  /// A Lock password change found the workspace file no longer encrypted by its workspace
  case lockRemovedMeanwhile

  var errorDescription: String? {
    switch self {
    case .unlockRefused: return "The workspace is locked."
    case .lockRemovedMeanwhile:
      return "The workspace file is no longer encrypted by this workspace, so it was left as it is."
    case .sessionMissing:
      return "The file belongs to a locked workspace that is not open, so it was not saved."
    case .sealedTarget:
      return "The file on disk is encrypted by a locked workspace, so it was not replaced."
    case .wrongKind: return "The encrypted file is not the kind of file expected here."
    }
  }
}
