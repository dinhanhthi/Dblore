//
//  WorkspaceWindowView.swift
//  Dblore
//
//  View for app windows. Each window can show either Welcome or a Workspace.

import AppKit
import SwiftUI

// MARK: - App Window View

/// Main view for each app window
/// Shows Welcome when no workspace is assigned, or WorkspaceContainer when workspace exists
/// When files are opened from Finder and workspaces exist, shows a chooser dialog
struct AppWindowView: View {
  /// Window-local workspace ID - nil means show Welcome or FileOpenChooser
  @State private var workspaceId: UUID?
  /// Flag to close this window after file open is handled
  @State private var shouldCloseWindow = false
  @Bindable private var windowManager = WorkspaceWindowManager.shared
  @Bindable private var pendingFileOpen = PendingFileOpen.shared

  var body: some View {
    Group {
      if shouldCloseWindow {
        // Empty view - window will close itself
        Color.clear
          .frame(width: 1, height: 1)
      } else if let id = workspaceId,
        let manager = windowManager.workspace(for: id)
      {
        // Show workspace
        WorkspaceContainerView(workspaceManager: manager)
          .onAppear {
            windowManager.setActiveWorkspace(id)
          }
      } else if pendingFileOpen.hasPendingFiles && !windowManager.workspaces.isEmpty {
        // Show file open chooser when files are waiting and workspaces exist
        FileOpenChooserView(
          onWorkspaceSelected: { selectedManager in
            openFilesInWorkspace(selectedManager)
          },
          onNewWorkspace: {
            openFilesInNewWorkspace()
          },
          onCancel: {
            cancelFileOpen()
          }
        )
      } else if SessionManager.isRunningAsTestHost {
        // Running as test host - skip welcome (it loads recent connections from Keychain)
        Color.clear
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
    // Observe pendingWorkspaceId changes from menu commands
    .onChange(of: windowManager.pendingWorkspaceId) { _, newId in
      guard let newId else { return }
      handlePendingWorkspace(newId)
    }
  }

  /// Handle a pending workspace open request from menu commands
  private func handlePendingWorkspace(_ newWorkspaceId: UUID) {
    if workspaceId == nil {
      // This window is showing welcome - open workspace here
      windowManager.pendingWorkspaceId = nil
      workspaceId = newWorkspaceId
    } else if workspaceId == newWorkspaceId {
      // This workspace is already showing in THIS window - just focus it
      windowManager.pendingWorkspaceId = nil
      // Find and focus the main WindowGroup window (not a NewWindowStore window)
      let storeWindows = Set(NewWindowStore.shared.allWindows)
      if let mainWindow = NSApp.windows.first(where: {
        $0.isVisible && !storeWindows.contains($0)
      }) {
        mainWindow.makeKeyAndOrderFront(nil)
      }
    } else {
      // This window has a different workspace
      // Only the key window should handle this to avoid duplicates
      guard isKeyWindow else { return }
      windowManager.pendingWorkspaceId = nil

      // Check if this workspace is already open in another window - focus that window
      if let existingWindow = NewWindowStore.shared.findWindow(for: newWorkspaceId) {
        existingWindow.makeKeyAndOrderFront(nil)
      } else {
        openNewWindow(for: newWorkspaceId)
      }
    }
  }

  /// Check if the current NSWindow is the key window
  private var isKeyWindow: Bool {
    guard let keyWindow = NSApp.keyWindow else {
      // No key window (e.g., during menu interaction) - let the first window handle it
      return true
    }
    return keyWindow.isKeyWindow
  }

  /// Open pending files in the selected workspace
  private func openFilesInWorkspace(_ manager: WorkspaceManager) {
    let files = pendingFileOpen.takePendingFiles()
    Task {
      for url in files {
        try? await manager.openFile(url: url)
      }
      // Bring the workspace window to front
      windowManager.setActiveWorkspace(manager.id)
      // Close this chooser window
      closeWindow()
    }
  }

  /// Open pending files in a new workspace
  private func openFilesInNewWorkspace() {
    let files = pendingFileOpen.takePendingFiles()
    let newManager = windowManager.newWorkspace()
    Task {
      for url in files {
        try? await newManager.openFile(url: url)
      }
      // Use this window for the new workspace
      workspaceId = newManager.id
    }
  }

  /// Cancel file open and close window
  private func cancelFileOpen() {
    pendingFileOpen.clearPendingFiles()
    closeWindow()
  }

  /// Close this window
  private func closeWindow() {
    shouldCloseWindow = true
    // Find and close the NSWindow
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
        window.close()
      }
    }
  }

  private func openNewWindow(for newWorkspaceId: UUID) {
    // Create a new NSWindow programmatically with SwiftUI content
    let newWindowView = NewWorkspaceWindowView(workspaceId: newWorkspaceId)
      // Disable all SwiftUI animations, same as the main WindowGroup
      .transaction {
        guard !$0.isSidebarAnimation else { return }
        $0.disablesAnimations = true
        $0.animation = nil
      }
    let hostingController = NSHostingController(rootView: newWindowView)

    let newWindow = NSWindow(contentViewController: hostingController)
    newWindow.title = "Dblore"
    newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    newWindow.titlebarAppearsTransparent = true
    newWindow.titleVisibility = .hidden
    newWindow.minSize = NSSize(width: 800, height: 600)

    // Use the current key window's size and cascade position
    if let currentWindow = NSApp.keyWindow, currentWindow.isVisible {
      newWindow.setContentSize(currentWindow.frame.size)
      // Offset down-right from the current window (standard macOS cascade)
      let offset: CGFloat = 22
      let newOrigin = CGPoint(
        x: currentWindow.frame.origin.x + offset,
        y: currentWindow.frame.origin.y - offset
      )
      newWindow.setFrameOrigin(newOrigin)
    } else {
      newWindow.setContentSize(NSSize(width: 1200, height: 800))
      newWindow.center()
    }

    // Use NSWindowController to manage the window lifecycle
    let windowController = NSWindowController(window: newWindow)
    windowController.showWindow(nil)

    // Keep a reference to prevent deallocation
    NewWindowStore.shared.addWindow(windowController, workspaceId: newWorkspaceId)
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
    // Observe pendingWorkspaceId to focus this window if its workspace is re-opened
    .onChange(of: windowManager.pendingWorkspaceId) { _, newId in
      guard let newId, newId == workspaceId else { return }
      // This workspace is already showing here - just focus this window
      windowManager.pendingWorkspaceId = nil
      NewWindowStore.shared.findWindow(for: workspaceId)?.makeKeyAndOrderFront(nil)
    }
  }
}

// MARK: - Window Store

/// Stores references to programmatically created windows to prevent deallocation
@MainActor
class NewWindowStore {
  static let shared = NewWindowStore()
  private var windowControllers: [(controller: NSWindowController, workspaceId: UUID)] = []

  private init() {
    // Listen for window close to clean up
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      // Dispatch to MainActor to safely access @MainActor properties
      Task { @MainActor in
        self?.windowControllers.removeAll { $0.controller.window == window }
      }
    }
  }

  func addWindow(_ controller: NSWindowController, workspaceId: UUID) {
    windowControllers.append((controller: controller, workspaceId: workspaceId))
  }

  /// Find the NSWindow displaying a specific workspace
  func findWindow(for workspaceId: UUID) -> NSWindow? {
    windowControllers.first { $0.workspaceId == workspaceId }?.controller.window
  }

  /// All managed windows
  var allWindows: [NSWindow] {
    windowControllers.compactMap { $0.controller.window }
  }
}
