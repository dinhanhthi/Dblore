//
//  WorkspaceWindowView.swift
//  SQLNotebook
//
//  View for app windows. Each window can show either Welcome or a Workspace.

import AppKit
import SwiftUI

// MARK: - App Window View

/// Main view for each app window
/// Shows Welcome when no workspace is assigned, or WorkspaceContainer when workspace exists
struct AppWindowView: View {
  /// Window-local workspace ID - nil means show Welcome
  @State private var workspaceId: UUID?
  @Bindable private var windowManager = WorkspaceWindowManager.shared

  var body: some View {
    Group {
      if let id = workspaceId,
        let manager = windowManager.workspace(for: id)
      {
        // Show workspace
        WorkspaceContainerView(workspaceManager: manager)
          .onAppear {
            windowManager.setActiveWorkspace(id)
          }
      } else {
        // Show welcome - pass callback so welcome can set workspace for this window
        AppWelcomeView(
          onWorkspaceSelected: { selectedId in
            // Open workspace in THIS window (replace welcome)
            workspaceId = selectedId
          }
        )
      }
    }
    // Listen for workspace open requests from menu
    .onReceive(NotificationCenter.default.publisher(for: .openWindowForWorkspace)) { notification in
      handleOpenWorkspaceNotification(notification)
    }
  }

  private func handleOpenWorkspaceNotification(_ notification: Notification) {
    guard let newWorkspaceId = notification.userInfo?["workspaceId"] as? UUID else { return }

    // Check if this notification was already handled
    if NotificationTracker.shared.wasHandled(newWorkspaceId) { return }

    if workspaceId == nil {
      // This window is showing welcome - open workspace here
      NotificationTracker.shared.markHandled(newWorkspaceId)
      workspaceId = newWorkspaceId
    } else {
      // This window already has a workspace
      // Only handle if this is the key window (front-most)
      guard let keyWindow = NSApp.keyWindow,
        keyWindow.isKeyWindow
      else { return }

      // Mark as handled and open new window
      NotificationTracker.shared.markHandled(newWorkspaceId)
      openNewWindow(for: newWorkspaceId)
    }
  }

  private func openNewWindow(for newWorkspaceId: UUID) {
    // Create a new NSWindow programmatically with SwiftUI content
    let newWindowView = NewWorkspaceWindowView(workspaceId: newWorkspaceId)
    let hostingController = NSHostingController(rootView: newWindowView)

    let newWindow = NSWindow(contentViewController: hostingController)
    newWindow.title = "SQLNotebook"
    newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    newWindow.titlebarAppearsTransparent = true
    newWindow.titleVisibility = .hidden
    newWindow.setContentSize(NSSize(width: 1200, height: 800))
    newWindow.minSize = NSSize(width: 800, height: 600)
    newWindow.center()

    // Use NSWindowController to manage the window lifecycle
    let windowController = NSWindowController(window: newWindow)
    windowController.showWindow(nil)

    // Keep a reference to prevent deallocation
    NewWindowStore.shared.addWindow(windowController)
  }
}

// MARK: - New Workspace Window View

/// Standalone view for a new workspace window (opened from menu when workspace already exists)
struct NewWorkspaceWindowView: View {
  let workspaceId: UUID
  @Bindable private var windowManager = WorkspaceWindowManager.shared

  var body: some View {
    Group {
      if let manager = windowManager.workspace(for: workspaceId) {
        WorkspaceContainerView(workspaceManager: manager)
          .onAppear {
            windowManager.setActiveWorkspace(workspaceId)
          }
      } else {
        // Workspace not found - show error
        VStack(spacing: Spacing.md) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundColor(.orange)
          Text("Workspace not found")
            .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
      }
    }
    .frame(minWidth: 800, minHeight: 600)
  }
}

// MARK: - Notification Tracker

/// Tracks which notifications have been handled to prevent duplicate handling
@MainActor
class NotificationTracker {
  static let shared = NotificationTracker()
  private var handledIds: Set<UUID> = []

  private init() {}

  func wasHandled(_ id: UUID) -> Bool {
    handledIds.contains(id)
  }

  func markHandled(_ id: UUID) {
    handledIds.insert(id)
    // Clean up old IDs after a delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.handledIds.remove(id)
    }
  }
}

// MARK: - Window Store

/// Stores references to programmatically created windows to prevent deallocation
@MainActor
class NewWindowStore {
  static let shared = NewWindowStore()
  private var windowControllers: [NSWindowController] = []

  private init() {
    // Listen for window close to clean up
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      self?.windowControllers.removeAll { $0.window == window }
    }
  }

  func addWindow(_ controller: NSWindowController) {
    windowControllers.append(controller)
  }
}
