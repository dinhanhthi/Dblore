//
//  LockedWorkspaceList.swift
//  Dblore
//

import Foundation

/// Every locked workspace file this Mac has seen (Lock Workspace, an open that found an
/// envelope), kept apart from Recents, which holds only the latest few: a Lock password change
/// re-seals each one, and the Lock password stays while one still depends on it. One entry per
/// workspace id and file; Remove Lock drops it. Holds no key material.
nonisolated struct LockedWorkspaceList: @unchecked Sendable {
  static let key = "ace.thi.dblore.lockedWorkspaces"

  /// Recents' store (the user's defaults in the app, an isolated suite under the test host)
  static var shared: LockedWorkspaceList {
    LockedWorkspaceList(defaults: RecentManager.sharedDefaults)
  }

  let defaults: UserDefaults

  /// Oldest first, each marked locked
  var entries: [WorkspaceHistoryEntry] {
    guard let data = defaults.data(forKey: Self.key) else { return [] }
    return (try? JSONDecoder().decode([WorkspaceHistoryEntry].self, from: data)) ?? []
  }

  /// Adds `entry` (marked locked), or refreshes the one with its id and file (name, bookmarks)
  func add(_ entry: WorkspaceHistoryEntry) {
    var entry = entry
    entry.isLocked = true
    var list = entries
    if let index = list.firstIndex(where: { Self.isSame($0, entry.id, entry.fileURL) }) {
      list[index] = entry
    } else {
      list.append(entry)
    }
    save(list)
  }

  /// Drops the entry of workspace `id` at `fileURL` (Remove Lock); copies elsewhere stay
  func remove(id: UUID, fileURL: URL) {
    let list = entries
    let kept = list.filter { !Self.isSame($0, id, fileURL) }
    guard kept.count != list.count else { return }
    save(kept)
  }

  /// `workspaces` followed by the entries of this list they do not have (same file), each
  /// marked locked: what a Lock password change re-seals
  func merged(with workspaces: [WorkspaceHistoryEntry]) -> [WorkspaceHistoryEntry] {
    let paths = Set(workspaces.map(\.fileURL.standardizedFileURL.path))
    return workspaces + entries.filter { !paths.contains($0.fileURL.standardizedFileURL.path) }
  }

  /// The entries whose file is still sealed: a missing or plaintext file is skipped (a file
  /// that went away never blocks anything), one that cannot be read or parsed counts (it cannot
  /// be checked). With `password`, a sealed file counts only when `password` unwraps its key
  /// (PBKDF2 per file). Reads the header of each file, so never on the main actor.
  @concurrent static func stillSealed(
    _ entries: [WorkspaceHistoryEntry], password: String? = nil
  ) async -> [WorkspaceHistoryEntry] {
    entries.filter { entry in
      let resolved = entry.bookmark.flatMap { try? SecurityScopedAccess.resolve($0) }
      let token = resolved.map { SecurityScopedAccessToken(url: $0.url) }
      defer { token?.release() }
      return isSealed(resolved?.url ?? entry.fileURL, password: password)
    }
  }

  private static func isSealed(_ url: URL, password: String?) -> Bool {
    let head: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      head = try handle.read(upToCount: LockEnvelope.minimumLength) ?? Data()
    } catch {
      return !isMissing(error)
    }
    guard head.starts(with: LockEnvelope.magic) else { return false }
    guard let header = try? LockEnvelope.sniff(head) else { return true }
    guard let password else { return true }
    return (try? LockEnvelope.unwrapKey(header.wrapBlock, password: password)) != nil
  }

  /// No such file (ENOENT), as opposed to a file that is there but cannot be read
  private static func isMissing(_ error: any Error) -> Bool {
    let error = error as NSError
    switch (error.domain, error.code) {
    case (NSCocoaErrorDomain, NSFileNoSuchFileError),
      (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
      (NSPOSIXErrorDomain, Int(ENOENT)):
      return true
    default:
      return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissing) ?? false
    }
  }

  private static func isSame(_ entry: WorkspaceHistoryEntry, _ id: UUID, _ url: URL) -> Bool {
    entry.id == id && entry.fileURL.standardizedFileURL == url.standardizedFileURL
  }

  private func save(_ list: [WorkspaceHistoryEntry]) {
    guard let data = try? JSONEncoder().encode(list) else { return }
    defaults.set(data, forKey: Self.key)
  }
}
