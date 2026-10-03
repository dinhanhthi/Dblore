//
//  WorkspaceWindowView.swift
//  Dblore
//
//  View for app windows. Each window can show either Welcome or a Workspace.

import AppKit
import SwiftUI

// MARK: - Host Window Reader

/// Weak reference to the NSWindow hosting a SwiftUI view.
final class HostWindowReference {
  weak var window: NSWindow?
}

/// Fills a `HostWindowReference` with the window the view lives in.
struct HostWindowReader: NSViewRepresentable {
  let reference: HostWindowReference

  func makeNSView(context: Context) -> NSView { ReaderView(reference: reference) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class ReaderView: NSView {
    let reference: HostWindowReference

    init(reference: HostWindowReference) {
      self.reference = reference
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reference.window = window
    }
  }
}

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
  @State private var hostWindow = HostWindowReference()

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
    // System bordered and glass buttons match the capsule design-system buttons.
    .buttonBorderShape(.capsule)
    .background(HostWindowReader(reference: hostWindow))
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
      guard isPendingWorkspaceHandler else { return }
      windowManager.pendingWorkspaceId = nil
      NewWindowStore.shared.clearPendingDetach(workspaceId: newWorkspaceId)
      workspaceId = newWorkspaceId
    } else if workspaceId == newWorkspaceId {
      // This workspace is already showing in THIS window - just focus it
      windowManager.pendingWorkspaceId = nil
      NewWindowStore.shared.clearPendingDetach(workspaceId: newWorkspaceId)
      hostWindow.window?.makeKeyAndOrderFront(nil)
    } else {
      // This window has a different workspace
      // Only the key window should handle this to avoid duplicates
      guard isPendingWorkspaceHandler else { return }
      windowManager.pendingWorkspaceId = nil

      // Check if this workspace is already open in another window - focus that window
      if let existingWindow = NewWindowStore.shared.findWindow(for: newWorkspaceId) {
        NewWindowStore.shared.clearPendingDetach(workspaceId: newWorkspaceId)
        existingWindow.makeKeyAndOrderFront(nil)
      } else {
        openNewWindow(for: newWorkspaceId)
      }
    }
  }

  /// Exactly one window's view handles a pending workspace: the key window, else (Finder open
  /// while inactive, async tab moves) the main window, else the first visible document window.
  private var isPendingWorkspaceHandler: Bool {
    guard let window = hostWindow.window else { return false }
    if let keyWindow = NSApp.keyWindow, keyWindow.isDbloreDocumentWindow {
      return keyWindow === window
    }
    if let mainWindow = NSApp.mainWindow { return mainWindow === window }
    return NSApp.orderedWindows.first { $0.isVisible && $0.isDbloreDocumentWindow } === window
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
    let detachDropPoint = NewWindowStore.shared.takePendingDetach(workspaceId: newWorkspaceId)
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
    newWindow.tabbingIdentifier = .dbloreDocument
    newWindow.tabbingMode = .automatic

    if let dropPoint = detachDropPoint {
      // Dragged out of its window: always a separate window, even when new windows open as tabs
      let size = NSApp.keyWindow?.frame.size ?? NSSize(width: 1200, height: 800)
      newWindow.setContentSize(size)
      let screen =
        NSScreen.screens.first { NSMouseInRect(dropPoint, $0.frame, false) } ?? NSScreen.main
      let origin = TabDragOut.detachedWindowOrigin(
        dropPoint: dropPoint, windowSize: newWindow.frame.size)
      newWindow.setFrameOrigin(
        screen.map {
          TabDragOut.clampedOrigin(
            origin, windowSize: newWindow.frame.size, visibleFrame: $0.visibleFrame)
        } ?? origin)
    } else if let parent = NewWindowStore.tabParent(
      openAsTab: AppSettings.shared.openWindowsAsTabs, keyWindow: NSApp.keyWindow)
    {
      parent.addTabbedWindow(newWindow, ordered: .above)
    } else if let currentWindow = NSApp.keyWindow, currentWindow.isVisible {
      // Use the current key window's size and cascade position
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
    .buttonBorderShape(.capsule)
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
  /// Screen points where tabs were dropped outside their window, keyed by the new workspace id
  private var pendingDetachDropPoints: [UUID: NSPoint] = [:]

  func setPendingDetach(workspaceId: UUID, point: NSPoint?) {
    pendingDetachDropPoints[workspaceId] = point
  }

  /// Returns and consumes the drop point of this workspace only
  func takePendingDetach(workspaceId: UUID) -> NSPoint? {
    pendingDetachDropPoints.removeValue(forKey: workspaceId)
  }

  func clearPendingDetach(workspaceId: UUID) {
    pendingDetachDropPoints[workspaceId] = nil
  }

  private var windowControllers: [(controller: NSWindowController, workspaceId: UUID?)] = []

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

  /// The window a new window should join as a tab, or nil to open it standalone.
  static func tabParent(openAsTab: Bool, keyWindow: NSWindow?) -> NSWindow? {
    guard openAsTab, keyWindow?.isDbloreDocumentWindow == true else { return nil }
    return keyWindow
  }

  /// All managed windows
  var allWindows: [NSWindow] {
    windowControllers.compactMap { $0.controller.window }
  }

  /// New window tab: joins the key document window's tab group, or opens standalone.
  func openWelcomeWindowTab() {
    let key = NSApp.keyWindow
    openWelcomeWindow(
      frame: key?.frame ?? .zero, asTabOf: key?.isDbloreDocumentWindow == true ? key : nil)
  }

  /// A fresh document window showing the welcome screen, kept alive until it closes.
  /// With `parent`, it joins that window's tab group instead of reusing a Welcome window.
  func openWelcomeWindow(frame: NSRect, asTabOf parent: NSWindow? = nil) {
    if parent == nil,
      let existing = windowControllers.first(where: { $0.workspaceId == nil })?.controller.window,
      existing.isVisible || existing.isMiniaturized
    {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return
    }

    let welcome = AppWindowView()
      .frame(minWidth: 800, minHeight: 600)
      .transaction {
        guard !$0.isSidebarAnimation else { return }
        $0.disablesAnimations = true
        $0.animation = nil
      }
    let hostingController = NSHostingController(rootView: welcome)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Dblore"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 800, height: 600)
    window.isRestorable = false
    window.tabbingIdentifier = .dbloreDocument
    window.tabbingMode = .automatic

    if let parent {
      parent.addTabbedWindow(window, ordered: .above)
    } else if frame.width >= 800, frame.height >= 600 {
      window.setFrame(frame, display: false)
    } else {
      window.setContentSize(NSSize(width: 1200, height: 800))
      window.center()
    }

    let windowController = NSWindowController(window: window)
    windowController.showWindow(nil)
    windowControllers.append((controller: windowController, workspaceId: nil))
    NSApp.activate()
  }
}

/// Tags the window hosting the welcome screen, so closing it does not open another one.
struct WelcomeWindowMarker: NSViewRepresentable {
  private static let windows = NSHashTable<NSWindow>.weakObjects()

  static func isWelcome(_ window: NSWindow) -> Bool {
    windows.contains(window)
  }

  func makeNSView(context: Context) -> MarkerView { MarkerView() }
  func updateNSView(_ nsView: MarkerView, context: Context) {}

  final class MarkerView: NSView {
    private weak var markedWindow: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let markedWindow { WelcomeWindowMarker.windows.remove(markedWindow) }
      markedWindow = window
      if let window { WelcomeWindowMarker.windows.add(window) }
    }
  }
}

extension NSWindow.TabbingIdentifier {
  static let dbloreDocument = NSWindow.TabbingIdentifier("app.dblore.document")
}

extension NSWindow {
  /// Workspace and welcome windows. About and panels are smaller and not resizable.
  var isDbloreDocumentWindow: Bool {
    // No canBecomeMain: it is already false once the window is closing
    level == .normal && styleMask.contains([.titled, .resizable])
  }

  /// A document window that is still open. A minimized window counts: it is open, just not on screen.
  /// A background tab counts too: it reports `isVisible == false` but is part of a tab group.
  var isOpenDbloreDocumentWindow: Bool {
    isDbloreDocumentWindow
      && (isVisible || isMiniaturized || (tabbedWindows?.count ?? 0) > 1)
  }

  /// Whether a document window other than `closed` is still open (decides the Welcome reopen).
  static func hasOtherOpenDocumentWindow(
    in windows: [NSWindow], excluding closed: NSWindow
  )
    -> Bool
  {
    windows.contains { $0 !== closed && $0.isOpenDbloreDocumentWindow }
  }
}
