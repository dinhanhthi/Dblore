//
//  WorkspaceWindowManager.swift
//  Dblore
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Manages multiple workspace windows.
/// This is the top-level manager for the entire application.
@MainActor
@Observable
class WorkspaceWindowManager {
  // MARK: - Shared Instance

  static let shared = WorkspaceWindowManager()

  // MARK: - State

  /// All open workspaces (one per window)
  var workspaces: [UUID: WorkspaceManager] = [:]

  /// Currently active workspace ID
  var activeWorkspaceId: UUID?

  // MARK: - Toast Notifications (App Level)

  /// Toast state for app-level notifications (e.g., when no workspace is open)
  var toastState: ToastState = ToastState()
  private var toastDismissTask: Task<Void, Never>?

  /// Show a toast notification at app level
  func showToast(_ message: String, type: ToastMessage.ToastType = .info) {
    toastState.show(message, type: type)
    startToastDismissTimer()
  }

  /// Dismiss current toast
  func dismissToast() {
    toastDismissTask?.cancel()
    toastDismissTask = nil
    // The close button removes the view while the pointer is still over it,
    // so onHover(false) may never run. Clear hover or the next toast stays up.
    toastState.setHovered(false)
    toastState.dismiss()
  }

  /// Set toast hover state
  func setToastHovered(_ hovered: Bool) {
    toastState.setHovered(hovered)
    if !hovered && toastState.currentToast != nil {
      startToastDismissTimer()
    }
  }

  private func startToastDismissTimer() {
    toastDismissTask?.cancel()
    toastDismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, !toastState.isHovered else { return }
      toastState.dismiss()
    }
  }

  /// Pending workspace ID to open in a window (set by menu commands)
  /// Observed by AppWindowView to open workspace in current or new window
  var pendingWorkspaceId: UUID?

  /// Whether app is showing welcome screen (no workspaces open)
  var isShowingWelcome: Bool {
    workspaces.isEmpty
  }

  // MARK: - Computed Properties

  /// Currently active workspace
  var activeWorkspace: WorkspaceManager? {
    guard let id = activeWorkspaceId else { return nil }
    return workspaces[id]
  }

  /// All workspace managers as array
  var allWorkspaces: [WorkspaceManager] {
    Array(workspaces.values)
  }

  /// Alias for allWorkspaces for compatibility
  var workspaceManagers: [WorkspaceManager] {
    allWorkspaces
  }

  /// Currently active workspace manager (alias for activeWorkspace)
  var activeWorkspaceManager: WorkspaceManager? {
    activeWorkspace
  }

  // MARK: - Locked Workspaces

  /// Locked workspaces being opened, by workspace id: their windows show a locked placeholder
  /// until the unlock and load end. Never in `workspaces` before that.
  private(set) var lockedOpens: [UUID: LockedWorkspaceOpen] = [:]

  /// Asks on the window (`anchor`) for the session of a locked workspace being opened; the
  /// String is the file's name. Nil when cancelled. Tests answer without a sheet.
  @ObservationIgnored var promptUnlock:
    @MainActor (LockEnvelope.Header, String, NSWindow?) async -> WorkspaceLockSession?

  /// The unlock a registered workspace asks through for a sealed file (its window's sheet;
  /// tests answer without one)
  @ObservationIgnored var makeFileUnlock: @MainActor (WorkspaceManager) -> LockedFileIO.Unlock = {
    $0.windowUnlock
  }

  /// The unlock a locked workspace being loaded asks through for a sealed file of another
  /// workspace (a sheet on its window; tests answer without one)
  @ObservationIgnored var makeLockedOpenFileUnlock:
    @MainActor (LockedWorkspaceOpen) -> LockedFileIO.Unlock = { open in
      WorkspaceUnlockPrompt.unlock(
        reason: "open a file of a locked workspace", anchor: { [weak open] in open?.anchor })
    }

  @ObservationIgnored private let lockedIO: LockedFileIO
  @ObservationIgnored private let lockCenter: LockCenter
  @ObservationIgnored private let recents: RecentManager
  @ObservationIgnored private let accessHooks: SecurityScopedAccessHooks

  // MARK: - Initialization

  init(
    lockedIO: LockedFileIO = .shared, lockCenter: LockCenter = .shared,
    recents: RecentManager = .shared, accessHooks: SecurityScopedAccessHooks = .live,
    keyStore: LockKeyStore = LockKeyStore()
  ) {
    self.lockedIO = lockedIO
    self.lockCenter = lockCenter
    self.recents = recents
    self.accessHooks = accessHooks
    promptUnlock = { header, name, anchor in
      await WorkspaceUnlockPrompt.present(
        header, title: name, reason: "open \(name)", anchor: anchor, center: lockCenter,
        keyStore: keyStore)
    }
  }

  // MARK: - Workspace Operations

  /// Create a new empty workspace
  /// Note: Caller should open window using openWindow(value: manager.id) after calling this
  @discardableResult
  func newWorkspace(connection: ConnectionConfig? = nil) -> WorkspaceManager {
    let manager = WorkspaceManager.createNew(connection: connection)
    manager.unlockLockedFile = makeFileUnlock(manager)
    workspaces[manager.id] = manager
    activeWorkspaceId = manager.id
    LaunchSessionCapture.schedule()
    return manager
  }

  /// `requestWorkspace`'s load of a plaintext workspace (or a locked one already unlocked here)
  /// before it returns. A non-nil bookmark wins over the Recents entry's, so launch restore does
  /// not depend on the recent list.
  private func openWorkspace(
    url: URL, bookmark: Data?, folderBookmark: Data?
  ) async throws -> WorkspaceManager {
    // Check if already open - just return existing, caller will handle window activation
    // Note: Window activation is handled by the view layer via notification
    if let existing = openManager(at: url) { return existing }

    let stored = recents.recentWorkspaces.first { $0.fileURL == url }
    let manager: WorkspaceManager
    do {
      manager = try await WorkspaceManager.load(
        from: url,
        bookmark: bookmark ?? stored?.bookmark,
        folderBookmark: folderBookmark ?? stored?.folderBookmark,
        hooks: accessHooks, lockedIO: lockedIO, markedLocked: stored?.isLocked == true,
        isOpen: { workspaces[$0] != nil || lockedOpens[$0] != nil })
    } catch WorkspaceOpenError.otherCopyOpen {
      // The same file opened while it loaded (a double click): that window comes to the front
      if let existing = openManager(at: url) { return existing }
      throw WorkspaceOpenError.otherCopyOpen
    }
    // Another file with the same workspace id is open or being opened
    guard workspaces[manager.id] == nil, lockedOpens[manager.id] == nil else {
      manager.autoConnectTask?.cancel()
      manager.releaseFileAccess(keepsSessions: workspaces[manager.id] != nil)
      // The same file opened while it loaded (a double click)
      if let existing = openManager(at: url) { return existing }
      throw WorkspaceOpenError.otherCopyOpen
    }
    register(manager, openedFrom: url)
    // Note: Caller should open window using openWindow(value: manager.id)
    return manager
  }

  /// The id a window shows for the workspace file at `url` (every user opener: Welcome, Finder,
  /// File > Open Workspace, Open Recent Workspace). Reads only the file's first bytes before it
  /// returns. A plaintext file (or a locked one whose key is open and unlocked here) loads as
  /// before; a locked one returns at once with a `LockedWorkspaceOpen`, so its window opens with
  /// the locked placeholder and asks there; nothing is decrypted before the unlock. An open
  /// workspace or one being opened returns its id (its window comes to the front). A file naming
  /// the id of a workspace open or being opened from another file (a copy, or a forged header)
  /// is refused: a window never shows one workspace's id for another file.
  func requestWorkspace(
    url: URL, bookmark: Data? = nil, folderBookmark: Data? = nil
  ) async throws -> UUID {
    if let id = openId(of: url) { return id }
    let stored = recents.recentWorkspaces.first { $0.fileURL == url }
    let bookmark = bookmark ?? stored?.bookmark
    let folderBookmark = folderBookmark ?? stored?.folderBookmark
    let header = await sniffHeader(url, bookmark: bookmark)
    // Sealed on disk: Recents keeps the lock mark even when this open is cancelled, and the
    // durable list keeps the file even once it left Recents
    if let header {
      recents.markWorkspaceLocked(url: url)
      let list = recents.lockedWorkspaces
      if !list.entries.contains(where: {
        $0.id == header.workspaceId && $0.fileURL.standardizedFileURL == url.standardizedFileURL
      }) {
        var entry = WorkspaceHistoryEntry(
          id: header.workspaceId, fileURL: url,
          name: stored?.name ?? url.deletingPathExtension().lastPathComponent, bookmark: bookmark)
        entry.folderBookmark = folderBookmark
        list.add(entry)
      }
    }
    // A second click while sniffing
    if header != nil, let id = openId(of: url) { return id }
    if let header, workspaces[header.workspaceId] != nil || lockedOpens[header.workspaceId] != nil {
      throw WorkspaceOpenError.otherCopyOpen
    }
    if let header, needsUnlock(header) {
      let open = LockedWorkspaceOpen(
        url: url, header: header, bookmark: bookmark, folderBookmark: folderBookmark,
        windows: self)
      lockedOpens[open.id] = open
      return open.id
    }
    return try await openWorkspace(url: url, bookmark: bookmark, folderBookmark: folderBookmark)
      .id
  }

  /// `requestWorkspace` for openers without their own error UI (Finder, the Dock, File > Open
  /// Workspace, Open Recent Workspace): a failure is shown in a toast. Nil when not opened.
  func requestWorkspaceReportingError(url: URL) async -> UUID? {
    do {
      return try await requestWorkspace(url: url)
    } catch {
      showToast(
        error is WorkspaceOpenError
          ? error.localizedDescription : "Failed to open workspace: \(error.localizedDescription)",
        type: .error)
      await AppLogger.shared.error("Failed to open workspace: \(error)", category: "Workspace")
      return nil
    }
  }

  /// After the unlock: loads `open`'s workspace with `session` (the .sqlws and its own tabs
  /// open without asking again; a tab of another locked workspace asks on the same window) and
  /// puts it in `workspaces` in place of the placeholder. Auto-connect starts only now. The file
  /// was sealed when sniffed: plaintext now is refused. Any end without content takes the
  /// unlock's grant back.
  func finishLockedOpen(_ open: LockedWorkspaceOpen, session: WorkspaceLockSession) async throws {
    let id = open.id
    let registry = lockedIO.registry
    let fileUnlock = makeLockedOpenFileUnlock(open)
    let unlock: LockedFileIO.Unlock = { @MainActor [weak self] header in
      // The session just granted, unless Dblore relocked since
      if header.workspaceId == id && !registry.isBlocked(.workspace(id)) { return session }
      // Its window closed: nothing asks any more (no prompt without that window)
      guard let self, self.lockedOpens[id] === open, let granted = await fileUnlock(header)
      else { return nil }
      open.noteLoadGrant(granted)
      return self.lockedOpens[id] === open ? granted : nil
    }
    let manager: WorkspaceManager
    do {
      manager = try await WorkspaceManager.load(
        from: open.url, bookmark: open.bookmark, folderBookmark: open.folderBookmark,
        hooks: accessHooks, lockedIO: lockedIO, unlock: unlock, markedLocked: true,
        expectsEnvelope: true)
    } catch {
      // The grant came from this file's own header: it did not open, so nothing keeps it
      if lockedOpens[id] === open {
        lockCenter.revokeWorkspace(id)
      } else {
        revokeUnusedGrant(of: id)
      }
      revokeLoadGrants(of: open)
      throw error
    }
    func isCurrent() -> Bool {
      lockedOpens[id] === open && manager.id == id && workspaces[id] == nil
    }
    // Launch restore: the snapshot's sealed text, opened only now (off the main actor)
    if isCurrent() { await manager.applySealedLaunchOverlays(open.sealedLaunchOverlays) }
    // Cancelled (its window closed) while loading, not the workspace its envelope names, or
    // opened from another file meanwhile
    guard isCurrent() else {
      manager.autoConnectTask?.cancel()
      manager.releaseFileAccess(keepsSessions: workspaces[manager.id] != nil)
      revokeLoadGrants(of: open)
      guard lockedOpens[id] === open else {
        revokeUnusedGrant(of: id)
        return
      }
      guard manager.id == id else {
        lockCenter.revokeWorkspace(id)
        throw WorkspaceOpenError.mismatchedEnvelope
      }
      throw WorkspaceOpenError.otherCopyOpen
    }
    open.markOpened()
    lockedOpens[id] = nil
    register(manager, openedFrom: open.url)
    // Text another window of it added while the first text was applied (already handled
    // envelopes are skipped)
    manager.startSealedLaunchOverlays(open.sealedLaunchOverlays)
  }

  /// Removes `open` (Cancel); nothing of it was registered
  func dropLockedOpen(_ open: LockedWorkspaceOpen) {
    if lockedOpens[open.id] === open { lockedOpens[open.id] = nil }
  }

  /// Takes back the grant of workspace `id` after its open ended without content, unless a
  /// window has it open or another open of it is under way
  func revokeUnusedGrant(of id: UUID) {
    guard workspaces[id] == nil, lockedOpens[id] == nil else { return }
    lockCenter.revokeWorkspace(id)
  }

  /// Takes back the grants of other workspaces' keys `open`'s load was given once it ended
  /// without content, unless a window holds that key or has that workspace open or opening
  private func revokeLoadGrants(of open: LockedWorkspaceOpen) {
    for granted in open.loadGrants
    where workspaces[granted.workspaceId] == nil && lockedOpens[granted.workspaceId] == nil {
      lockCenter.abandonUnlock(granted)
    }
  }

  /// The workspace open from `url`, made active
  private func openManager(at url: URL) -> WorkspaceManager? {
    guard let existing = workspaces.values.first(where: { $0.workspace.fileURL == url }) else {
      return nil
    }
    activeWorkspaceId = existing.id
    return existing
  }

  /// The id of the workspace open or being opened from `url`, made active
  private func openId(of url: URL) -> UUID? {
    if let existing = openManager(at: url) { return existing.id }
    return lockedOpens.values.first { $0.url == url }?.id
  }

  /// The envelope header of the file (its first bytes, off the main actor); nil for plaintext
  /// or when it cannot be read (the load path then asks for access or reports it)
  private func sniffHeader(_ url: URL, bookmark: Data?) async -> LockEnvelope.Header? {
    let access = accessHooks.access(bookmark)
    defer { access?.token.release() }
    let target = access?.isStale == true ? access?.url ?? url : url
    return try? await LockedFileIO.sniffHeader(at: target)
  }

  /// A locked workspace needs the unlock unless its key is open and it is unlocked here (as
  /// `LockedFileIO.read` decides)
  private func needsUnlock(_ header: LockEnvelope.Header) -> Bool {
    let id = header.workspaceId
    return lockedIO.registry.isBlocked(.workspace(id)) || lockedIO.sessions.session(for: id) == nil
  }

  /// A loaded workspace joins `workspaces`, becomes active and goes to Recents (a moved file
  /// replaces its old entry); later sealed files ask on its window
  private func register(_ manager: WorkspaceManager, openedFrom url: URL) {
    manager.unlockLockedFile = makeFileUnlock(manager)
    workspaces[manager.id] = manager
    activeWorkspaceId = manager.id
    LaunchSessionCapture.schedule()
    if let entry = manager.recentEntry {
      if entry.fileURL != url {
        recents.removeWorkspace(url: url)
      }
      recents.addWorkspace(entry)
    }
  }

  /// Open workspace with file panel
  func openWorkspaceWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = UTType.sqlWorkspaceOpenTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a workspace file to open"

    let response: NSApplication.ModalResponse
    if let window = NSApp.keyWindow {
      response = await panel.beginSheetModal(for: window)
    } else {
      response = await withCheckedContinuation { continuation in
        panel.begin { result in
          continuation.resume(returning: result)
        }
      }
    }

    if response == .OK, let url = panel.url,
      let id = await requestWorkspaceReportingError(url: url)
    {
      pendingWorkspaceId = id
    }
  }

  /// Close a workspace
  func closeWorkspace(id: UUID, force: Bool = false) async -> Bool {
    guard let manager = workspaces[id] else { return true }

    if !force {
      let canClose = await manager.canClose()
      guard canClose else { return false }
    }

    manager.autoConnectTask?.cancel()
    manager.sealedOverlayTask?.cancel()

    // Disconnect if connected. A forced close answers with the first safe non-commit option
    // (Rollback, or Discard / Disconnect while a statement / ROLLBACK runs); none (COMMIT
    // awaited) asks.
    if manager.connectionState == .connected || manager.connectionState.isConnecting {
      var resolution: PendingTransactionResolution?
      if force {
        await manager.refreshPendingTransaction()
        resolution = WorkspaceTransactionRules.forcedResolution(
          for: manager.pendingTransaction, statementInFlight: manager.isStatementInFlight)
      }
      guard await manager.disconnect(resolution: resolution) else { return false }
    }

    workspaces.removeValue(forKey: id)
    manager.releaseFileAccess()
    // A locked workspace asks again at its next open
    if let lockKeyId = manager.lockKeyId { revokeUnusedGrant(of: lockKeyId) }

    if activeWorkspaceId == id {
      activeWorkspaceId = nil
    }

    return true
  }

  /// Close active workspace
  func closeActiveWorkspace() async -> Bool {
    guard let id = activeWorkspaceId else { return true }
    return await closeWorkspace(id: id)
  }

  /// Set active workspace
  func setActiveWorkspace(_ id: UUID) {
    guard workspaces[id] != nil else { return }
    activeWorkspaceId = id
  }

  /// Clear the active workspace (a Welcome or chooser window became key)
  func clearActiveWorkspace() {
    activeWorkspaceId = nil
  }

  /// Get workspace by ID
  func workspace(for id: UUID) -> WorkspaceManager? {
    workspaces[id]
  }

  // MARK: - Window Management
  // Note: Window opening is now handled by view layer using openWindow(value: workspaceId)
  // The WorkspaceWindowManager only manages workspace state, not windows

  // MARK: - App Lifecycle

  /// Save all workspaces state before app terminates
  func saveAllState() {
    for manager in workspaces.values {
      if manager.workspace.fileURL != nil {
        Task {
          try? await manager.saveWorkspace()
        }
      }
    }
  }

  /// Restore workspaces from last session
  func restoreLastSession() async {
    // For now, just restore from recent workspaces if any
    // In a full implementation, we'd save/restore the exact window state
  }
}
