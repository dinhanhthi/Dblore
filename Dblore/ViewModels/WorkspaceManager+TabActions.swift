// WorkspaceManager+TabActions.swift
// Pinned-tab rules: pinned tabs form a leading zone of `tabs`.

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

  /// Only saved file tabs (notebook or SQL) have a file to reveal
  func canRevealFile(tabId: UUID) -> Bool {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
    return (tab.documentType == .notebook || tab.documentType == .sqlFile) && tab.fileURL != nil
  }

  func revealFile(tabId: UUID) {
    guard canRevealFile(tabId: tabId),
      let url = tabs.first(where: { $0.id == tabId })?.fileURL
    else { return }
    revealInFinder(url)
  }

  private func closesAsynchronously(tabId: UUID) -> Bool {
    if viewModels[tabId]?.hasPendingStagedChanges == true { return true }
    return isResolvingPendingTransaction
      || WorkspaceTransactionRules.requiresResolution(
        state: pendingTransaction, action: .closeTab(tabId), originTabId: transactionOriginTabId)
  }
}
