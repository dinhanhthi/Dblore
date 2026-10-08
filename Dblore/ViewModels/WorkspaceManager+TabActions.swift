// WorkspaceManager+TabActions.swift
// Pinned-tab rules: pinned tabs form a leading zone of `tabs`.

import AppKit
import Foundation

extension WorkspaceManager {
  /// Number of pinned tabs (the pinned zone is `tabs[0..<pinnedCount]`)
  var pinnedCount: Int { tabs.filter(\.isPinned).count }

  /// Pin a tab at the end of the pinned zone, or unpin it to the first slot after the zone.
  /// Pinning also keeps a preview tab, so it is persisted and not replaced by the next preview.
  func setPinned(_ pinned: Bool, id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != pinned
    else { return }
    var tab = tabs.remove(at: index)
    tab.isPinned = pinned
    if pinned { tab.isPreview = false }
    tabs.insert(tab, at: pinnedCount)
    markDirtyAndScheduleAutoSave()
  }

  /// Clamp a move target so a tab never crosses the pinned boundary
  func clampedMoveTarget(from: Int, to: Int) -> Int {
    guard tabs.indices.contains(from) else { return to }
    let zone = pinnedCount
    return tabs[from].isPinned ? min(to, zone - 1) : max(to, zone)
  }

  /// Pinned tabs cannot be closed until unpinned
  func canClose(tabId: UUID) -> Bool {
    tabs.first(where: { $0.id == tabId })?.isPinned != true
  }

  /// Unpinned tabs after the given tab, in order
  func tabsToCloseRight(of id: UUID) -> [UUID] {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
    return tabs[(index + 1)...].filter { !$0.isPinned }.map(\.id)
  }

  /// Close the unpinned tabs to the right. Clean tabs close at once; each dirty tab prompts in
  /// turn, and Cancel (or a failed save) drops the rest.
  func closeTabsToTheRight(of id: UUID) {
    pendingCloseQueue = tabsToCloseRight(of: id)
    drainCloseQueue()
  }

  /// Resume the queue on the next main-actor turn: the confirmation dialog writes
  /// `showingCloseConfirmation = false` after its button action, which would swallow a prompt
  /// presented from inside that action.
  func scheduleDrainCloseQueue() {
    guard !pendingCloseQueue.isEmpty else { return }
    Task { @MainActor in
      await Task.yield()
      drainCloseQueue()
    }
  }

  /// Process queued tabs until one needs a confirmation (resumed from the confirmation handlers)
  func drainCloseQueue() {
    while tabToClose == nil, !pendingCloseQueue.isEmpty {
      let id = pendingCloseQueue.removeFirst()
      // These close asynchronously after their own prompt: leave them open rather than stall
      guard !closesAsynchronously(tabId: id) else { continue }
      requestCloseTab(id: id)
    }
  }

  /// Only saved file tabs (notebook, SQL or markdown) have a file to reveal
  func canRevealFile(tabId: UUID) -> Bool {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
    return [.notebook, .sqlFile, .markdown].contains(tab.documentType) && tab.fileURL != nil
  }

  func revealFile(tabId: UUID) {
    guard canRevealFile(tabId: tabId),
      let url = tabs.first(where: { $0.id == tabId })?.fileURL
    else { return }
    revealInFinder(url)
  }

  /// Pinned tabs stay (the close guard would leave them in both windows), the transaction-origin
  /// tab must resolve its transaction here, and unsaved work cannot travel through a file.
  func canMoveToNewWindow(tabId: UUID) -> Bool {
    guard let tab = tabs.first(where: { $0.id == tabId }),
      !tab.isPinned, tabId != transactionOriginTabId, !isResolvingPendingTransaction
    else { return false }
    switch tab.documentType {
    case .notebook, .sqlFile, .markdown:
      return tab.fileURL != nil && !tab.isDirty
    case .dataViewer:
      return viewModels[tabId]?.hasPendingStagedChanges != true
    }
  }

  /// Open the tab's file in `newManager` (through the tab's bookmark), then close it here.
  /// A failed open leaves the source tab untouched.
  func transfer(tabId: UUID, into newManager: WorkspaceManager) async throws {
    guard canMoveToNewWindow(tabId: tabId), let tab = tabs.first(where: { $0.id == tabId })
    else { return }
    if tab.documentType == .dataViewer {
      // Not pinned (pinned tabs cannot move), so only the relation carries over
      guard let state = viewModels[tabId]?.dataViewer else {
        throw CocoaError(.fileReadUnknown)
      }
      let ref = WorkspaceTabReference.DataViewerReference(
        schema: state.schema, name: state.name, orderColumns: state.orderColumns)
      let newRef = WorkspaceTabReference(
        documentType: .dataViewer, title: tab.title, dataViewer: ref)
      newManager.restoreDataViewer(tabRef: newRef, ref: ref)
      newManager.selectTab(id: newRef.id)
      requestCloseTab(id: tabId)
      return
    }
    guard let url = tab.fileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    if let bookmark = tabBookmarks[tabId] {
      newManager.recents.rememberDocumentBookmark(bookmark, for: url)
    }
    let existing = Set(newManager.tabs.map(\.id))
    try await newManager.openFile(url: url)
    // The open can suspend (permission prompt): the tab may have changed meanwhile
    guard canMoveToNewWindow(tabId: tabId) else {
      for added in newManager.tabs.map(\.id) where !existing.contains(added) {
        newManager.requestCloseTab(id: added)
      }
      throw CocoaError(.userCancelled)
    }
    requestCloseTab(id: tabId)
  }

  /// Move a tab to a new window of the same connection, connecting it when this one is connected
  func moveTabToNewWindow(id: UUID, dropPoint: NSPoint? = nil) async {
    guard canMoveToNewWindow(tabId: id) else { return }
    let config = workspace.connectionConfig
    let previousActive = WorkspaceWindowManager.shared.activeWorkspaceId
    let newManager = makeWindowManager(config)
    do {
      try await transfer(tabId: id, into: newManager)
    } catch {
      discardWindowManager(newManager, previousActive)
      await AppLogger.shared.error("Failed to move tab: \(error)", category: "Tabs")
      return
    }
    // Set only after the transfer succeeded, so a failed move never leaks it into a later open
    NewWindowStore.shared.setPendingDetach(workspaceId: newManager.id, point: dropPoint)
    WorkspaceWindowManager.shared.pendingWorkspaceId = newManager.id
    guard connectionState == .connected, let config else { return }
    do {
      try await newManager.connect(config: config)
    } catch {
      await AppLogger.shared.error("Failed to connect: \(error)", category: "Connection")
    }
  }

  private func closesAsynchronously(tabId: UUID) -> Bool {
    if viewModels[tabId]?.hasPendingStagedChanges == true { return true }
    return isResolvingPendingTransaction
      || WorkspaceTransactionRules.requiresResolution(
        state: pendingTransaction, action: .closeTab(tabId), originTabId: transactionOriginTabId)
  }
}
