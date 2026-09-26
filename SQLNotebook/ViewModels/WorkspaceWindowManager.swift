//
//  WorkspaceWindowManager.swift
//  SQLNotebook
//

import AppKit
import Foundation
import SwiftUI

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

  // MARK: - Initialization

  private init() {}

  // MARK: - Workspace Operations

  /// Create a new empty workspace
  /// Note: Caller should open window using openWindow(value: manager.id) after calling this
  @discardableResult
  func newWorkspace(connection: ConnectionConfig? = nil) -> WorkspaceManager {
    let manager = WorkspaceManager.createNew(connection: connection)
    workspaces[manager.id] = manager
    activeWorkspaceId = manager.id
    return manager
  }

  /// Open workspace from file URL
  /// Note: Caller should open window using openWindow(value: manager.id)
  @discardableResult
  func openWorkspace(url: URL) async throws -> WorkspaceManager {
    // Check if already open - just return existing, caller will handle window activation
    if let existing = workspaces.values.first(where: { $0.workspace.fileURL == url }) {
      activeWorkspaceId = existing.id
      // Note: Window activation is handled by the view layer via notification
      return existing
    }

    let manager = try await WorkspaceManager.load(from: url)
    workspaces[manager.id] = manager
    activeWorkspaceId = manager.id

    // Add to recent
    if let entry = WorkspaceHistoryEntry.from(manager.workspace) {
      RecentManager.shared.addWorkspace(entry)
    }

    // Note: Caller should open window using openWindow(value: manager.id)
    return manager
  }

  /// Open workspace with file panel
  func openWorkspaceWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.sqlWorkspace]
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

    if response == .OK, let url = panel.url {
      do {
        try await openWorkspace(url: url)
      } catch {
        await AppLogger.shared.error("Failed to open workspace: \(error)", category: "Workspace")
      }
    }
  }

  /// Close a workspace
  func closeWorkspace(id: UUID, force: Bool = false) async -> Bool {
    guard let manager = workspaces[id] else { return true }

    if !force {
      let canClose = await manager.canClose()
      guard canClose else { return false }
    }

    // Disconnect if connected. A forced close answers with the first safe non-commit option
    // (Rollback, or Discard / Disconnect while a statement / ROLLBACK runs); none (COMMIT
    // awaited) asks.
    if manager.connectionState == .connected {
      var resolution: PendingTransactionResolution?
      if force {
        await manager.refreshPendingTransaction()
        resolution = WorkspaceTransactionRules.forcedResolution(
          for: manager.pendingTransaction, statementInFlight: manager.isStatementInFlight)
      }
      guard await manager.disconnect(resolution: resolution) else { return false }
    }

    workspaces.removeValue(forKey: id)

    if activeWorkspaceId == id {
      activeWorkspaceId = workspaces.keys.first
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
