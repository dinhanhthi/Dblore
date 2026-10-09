//
//  SecurityScopedAccessHooks.swift
//  Dblore
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Bookmark resolution, access tokens and the panels that re-grant access, in one place so
/// tests can inject fakes (the live panels never open under XCTest).
@MainActor
struct SecurityScopedAccessHooks {
  var resolve: (Data) throws -> (url: URL, isStale: Bool) = {
    try SecurityScopedAccess.resolve($0)
  }
  var makeBookmark: (URL) -> Data? = { SecurityScopedAccess.bookmarkIfPossible(for: $0) }
  var startAccess: (URL) -> SecurityScopedAccessToken = { SecurityScopedAccessToken(url: $0) }
  /// Ask the user to select `file` again (the panel opens in its folder); nil = cancelled
  var chooseFile: @MainActor (URL) async -> URL? = { await FileAccessPanel.chooseFile($0) }
  /// Ask the user to grant the folder containing the workspace `file`; nil = cancelled
  var chooseFolder: @MainActor (URL) async -> URL? = {
    await FileAccessPanel.chooseFolder(containing: $0)
  }
  /// Ask the user for a Parquet / CSV file for DuckDB; the argument is the panel's message.
  /// nil = cancelled
  var chooseDataFile: @MainActor (String) async -> URL? = {
    await FileAccessPanel.chooseDataFile(message: $0)
  }

  static var live: SecurityScopedAccessHooks { SecurityScopedAccessHooks() }

  /// Access through a resolved bookmark: `bookmark` is the stored one, or a fresh one when the
  /// stored one was stale (the file moved)
  struct Access {
    let url: URL
    let isStale: Bool
    let token: SecurityScopedAccessToken
    let bookmark: Data
  }

  /// Resolve `bookmark` and start accessing its file; nil when there is none or it no longer
  /// resolves (the caller then tries the plain URL)
  func access(_ bookmark: Data?) -> Access? {
    guard let bookmark else { return nil }
    do {
      let resolved = try resolve(bookmark)
      let token = startAccess(resolved.url)
      let fresh = resolved.isStale ? makeBookmark(resolved.url) : nil
      return Access(
        url: resolved.url, isStale: resolved.isStale, token: token, bookmark: fresh ?? bookmark)
    } catch {
      let message = "Failed to resolve bookmark: \(error.localizedDescription)"
      Task { await AppLogger.shared.warning(message, category: "Workspace") }
      return nil
    }
  }
}

/// NSOpenPanels asking the user to re-grant access to a file or folder the app lost access to
@MainActor
enum FileAccessPanel {
  static func chooseFile(_ file: URL) async -> URL? {
    let panel = NSOpenPanel()
    panel.directoryURL = file.deletingLastPathComponent()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let type = UTType(filenameExtension: file.pathExtension) {
      panel.allowedContentTypes = [type]
    }
    panel.message = "Select \"\(file.lastPathComponent)\" to allow Dblore to open it."
    panel.prompt = "Allow"
    return await run(panel)
  }

  /// `message` defaults to the workspace wording (reopening its tabs).
  static func chooseFolder(containing file: URL, message: String? = nil) async -> URL? {
    let folder = file.deletingLastPathComponent()
    let panel = NSOpenPanel()
    panel.directoryURL = folder
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message =
      message
      ?? "Allow access to the folder \"\(folder.lastPathComponent)\" to reopen the tabs of "
      + "\"\(file.lastPathComponent)\"."
    panel.prompt = "Allow"
    return await run(panel)
  }

  static func chooseDataFile(message: String) async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes =
      [.commaSeparatedText, .tabSeparatedText]
      + [UTType(filenameExtension: "parquet")].compactMap { $0 }
    panel.message = message
    panel.prompt = "Query"
    return await run(panel)
  }

  private static func run(_ panel: NSOpenPanel) async -> URL? {
    guard !SessionManager.isRunningAsTestHost else { return nil }
    let response = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    return response == .OK ? panel.url : nil
  }
}
