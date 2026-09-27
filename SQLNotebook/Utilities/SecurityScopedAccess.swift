//
//  SecurityScopedAccess.swift
//  SQLNotebook
//

import Foundation
import Synchronization

/// App-scope security-scoped bookmarks for files the user picked, so the sandboxed app can
/// reach them again after a relaunch.
nonisolated enum SecurityScopedAccess {
  /// Create an app-scope security-scoped bookmark (the app must currently have access to `url`)
  static func makeBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// Resolve a bookmark made by `makeBookmark(for:)`
  static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
      bookmarkDataIsStale: &isStale)
    return (url, isStale)
  }

  /// Create a bookmark, logging and ignoring failures (never blocks the user action)
  static func bookmarkIfPossible(for url: URL) -> Data? {
    do {
      return try makeBookmark(for: url)
    } catch {
      let message = "Failed to create bookmark for \(url.lastPathComponent): \(error)"
      Task { await AppLogger.shared.warning(message, category: "Workspace") }
      return nil
    }
  }
}

/// Access to a security-scoped URL: starts on creation, stops exactly once on `release()` or
/// deinit, and only if access was granted.
nonisolated final class SecurityScopedAccessToken: Sendable {
  let url: URL
  let isGranted: Bool
  private let stop: @Sendable (URL) -> Void
  private let isReleased = Mutex(false)

  init(
    url: URL,
    start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
  ) {
    self.url = url
    self.stop = stop
    isGranted = start(url)
  }

  /// Stop accessing now; later calls and deinit do nothing
  func release() {
    let shouldStop = isReleased.withLock { released in
      defer { released = true }
      return !released && isGranted
    }
    if shouldStop { stop(url) }
  }

  deinit {
    release()
  }
}
