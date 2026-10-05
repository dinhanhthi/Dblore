//
//  DbloreApp.swift
//  Dblore
//

import AppKit
import Combine
@preconcurrency import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Delegate for file handling

class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set once quitting is confirmed, so closing the windows on quit does not reopen Welcome
  private var isTerminating = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    PerfSignpost.event("launch.didFinish")
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let window = note.object as? NSWindow else { return }
      // Read now, on this main-queue callback: the content view is still attached
      // while the window closes. A later hop would miss the marker.
      let wasWelcome = MainActor.assumeIsolated { WelcomeWindowMarker.isWelcome(window) }
      Task { @MainActor in self?.reopenWelcomeIfLastWindowClosed(window, wasWelcome: wasWelcome) }
    }
    // Start Sparkle (no-op under tests)
    UpdaterController.shared.start()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    // Separate workspace files from document files
    var workspaceURLs: [URL] = []
    var documentURLs: [URL] = []

    for url in urls {
      let ext = url.pathExtension.lowercased()
      if ext == "sqlws" {
        workspaceURLs.append(url)
      } else {
        documentURLs.append(url)
      }
    }

    Task { @MainActor in
      // Open workspace files directly
      for url in workspaceURLs {
        if let manager = try? await WorkspaceWindowManager.shared.openWorkspace(url: url) {
          WorkspaceWindowManager.shared.pendingWorkspaceId = manager.id
        }
      }

      // For document files, check if we have existing workspaces
      if !documentURLs.isEmpty {
        let existingWorkspaces = WorkspaceWindowManager.shared.allWorkspaces

        if existingWorkspaces.isEmpty {
          // No existing workspaces - create new one and open files
          let newManager = WorkspaceWindowManager.shared.newWorkspace()
          WorkspaceWindowManager.shared.pendingWorkspaceId = newManager.id
          for url in documentURLs {
            try? await newManager.openFile(url: url)
          }
        } else {
          // Have existing workspaces - store URLs for chooser dialog
          // The new window SwiftUI creates will show the chooser
          PendingFileOpen.shared.addFiles(documentURLs)
        }
      }
    }
  }

  /// The "+" button in a window's tab bar sends this down the responder chain.
  @MainActor @objc func newWindowForTab(_ sender: Any?) {
    NewWindowStore.shared.openWelcomeWindowTab()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // Keep app running even when all windows are closed
  }

  /// Closing the last workspace/welcome window opens a new window on the welcome screen.
  /// Closing the welcome window itself never reopens it.
  /// Another document window (including a minimized one) just lets this window close.
  /// About and other small windows are not resizable, so they never trigger this.
  @MainActor
  private func reopenWelcomeIfLastWindowClosed(_ closed: NSWindow, wasWelcome: Bool) {
    guard !wasWelcome, !isTerminating, !SessionManager.isRunningAsTestHost,
      closed.isDbloreDocumentWindow
    else { return }
    let frame = closed.frame
    // Let a quit in progress (which closes the windows too) win over the reopen
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, !self.isTerminating else { return }
      let hasOtherDocumentWindow = NSWindow.hasOtherOpenDocumentWindow(
        in: NSApp.windows, excluding: closed)
      guard !hasOtherDocumentWindow else { return }
      NewWindowStore.shared.openWelcomeWindow(frame: frame)
    }
  }

  /// Quitting with a pending Protected transaction asks Commit / Roll back / Cancel for each
  /// workspace (Cancel keeps the app running). A force-quit skips this: the connection closes
  /// without COMMIT, so the server rolls the transaction back.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let managers = WorkspaceWindowManager.shared.allWorkspaces
    // A running tab may have opened a transaction the mirror does not show yet: resolve refreshes
    guard managers.contains(where: { !$0.pendingTransaction.isIdle || $0.isAnyTabExecuting })
    else {
      isTerminating = true
      return .terminateNow
    }
    Task { @MainActor in
      for manager in managers {
        guard await manager.resolvePendingTransaction(action: .quit) else {
          NSApp.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      isTerminating = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Save all workspace states
    Task { @MainActor in
      for manager in WorkspaceWindowManager.shared.workspaceManagers {
        try? await manager.saveWorkspace()
      }
    }
    // Note: Tab state is now saved per-workspace in saveWorkspace() above
  }
}

// MARK: - Pending File Open Manager

/// Manages files that are waiting to be opened when user chooses a workspace
@MainActor
@Observable
class PendingFileOpen {
  static let shared = PendingFileOpen()

  /// Files waiting to be opened
  private(set) var pendingFiles: [URL] = []

  /// Whether there are pending files
  var hasPendingFiles: Bool {
    !pendingFiles.isEmpty
  }

  private init() {}

  /// Add files to pending list
  func addFiles(_ urls: [URL]) {
    pendingFiles.append(contentsOf: urls)
  }

  /// Take all pending files (clears the list)
  func takePendingFiles() -> [URL] {
    let files = pendingFiles
    pendingFiles = []
    return files
  }

  /// Clear pending files without opening
  func clearPendingFiles() {
    pendingFiles = []
  }
}

@main
struct DbloreApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    PerfSignpost.event("launch.init")
    // Show .help() tooltips after 300ms instead of the slow system default (read when AppKit
    // creates its tooltip manager, so it must be registered this early)
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
    // Migrate from single session to connection history (one-time operation)
    if !SessionManager.isRunningAsTestHost {
      SessionManager.migrateIfNeeded()
      pruneQueryHistoryOnLaunch()
    }

    // Configure SQLite temp directory to use app's temp directory
    configureSQLiteTempDirectory()
  }

  var body: some Scene {
    // Main window group - each window can show Welcome or a Workspace
    // Window-local state determines what to show
    WindowGroup {
      AppWindowView()
        .frame(minWidth: 800, minHeight: 600)
        // Disable all SwiftUI animations app-wide for snappier tab and layout switches
        .transaction {
          // Sidebar show/hide keeps its animation
          guard !$0.isSidebarAnimation else { return }
          $0.disablesAnimations = true
          $0.animation = nil
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      SharedCommands()
      WorkspaceCommands()
      TabCommands()
      NotebookCommands()
      EditorCommands()
      SchemaVisualizerCommands()
    }
    .defaultSize(width: 1200, height: 800)
    // Note: handlesExternalEvents doesn't work for file open events
    // Duplicate windows are closed in AppDelegate.application(_:open:)
  }

  /// Drop expired history rows. A failure is logged; launch continues either way.
  /// Skipped under XCTest so the test host never opens History.sqlite.
  private func pruneQueryHistoryOnLaunch() {
    guard !SessionManager.isRunningAsTestHost else { return }
    Task { @MainActor in
      let days = AppSettings.shared.historyRetentionDays
      let olderThan = QueryHistoryStore.retentionCutoff(retentionDays: days)
      let maxEntries = AppSettings.shared.historyMaxEntries
      do {
        try await QueryHistoryStore.shared.prune(olderThan: olderThan, maxEntries: maxEntries)
      } catch {
        await AppLogger.shared.error(
          "Query history prune failed: \(error.localizedDescription)", category: "History")
      }
    }
  }

  /// Configure SQLite to use app's temporary directory to avoid sandbox issues
  private func configureSQLiteTempDirectory() {
    let tempDir = FileManager.default.temporaryDirectory.path
    // Safe: called once during app initialization on main thread
    MainActor.assumeIsolated {
      sqlite3_temp_directory = strdup(tempDir)
    }
  }
}

// MARK: - FocusedValues Extension

/// Represents the document type/mode of the currently focused window/tab.
enum DocumentMode {
  case notebook  // Notebook mode (.dblore files) - has Cell menu, custom Find
  case editor  // Editor mode (.sql files) - uses native macOS menus
}

/// FocusedValue key for tracking document mode across the app.
struct DocumentModeFocusedValueKey: FocusedValueKey {
  typealias Value = DocumentMode
}

/// FocusedValue key for tracking active tab ID
struct ActiveTabIdKey: FocusedValueKey {
  typealias Value = UUID
}

/// FocusedValue key for accessing active tab's ViewModel
struct ActiveViewModelKey: FocusedValueKey {
  typealias Value = NotebookViewModel
}

extension FocusedValues {
  /// Document mode of the active tab
  var documentMode: DocumentMode? {
    get { self[DocumentModeFocusedValueKey.self] }
    set { self[DocumentModeFocusedValueKey.self] = newValue }
  }

  /// Active tab ID
  var activeTabId: UUID? {
    get { self[ActiveTabIdKey.self] }
    set { self[ActiveTabIdKey.self] = newValue }
  }

  /// Active tab's ViewModel
  var activeViewModel: NotebookViewModel? {
    get { self[ActiveViewModelKey.self] }
    set { self[ActiveViewModelKey.self] = newValue }
  }

  /// Action to toggle the left sidebar in the focused tab.
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  /// Action to toggle the right sidebar in the focused tab.
  var toggleRightSidebarAction: (() -> Void)? {
    get { self[ToggleRightSidebarActionKey.self] }
    set { self[ToggleRightSidebarActionKey.self] = newValue }
  }

  var openSearchAction: (() -> Void)? {
    get { self[OpenSearchActionKey.self] }
    set { self[OpenSearchActionKey.self] = newValue }
  }

  var findNextAction: (() -> Void)? {
    get { self[FindNextActionKey.self] }
    set { self[FindNextActionKey.self] = newValue }
  }

  var findPreviousAction: (() -> Void)? {
    get { self[FindPreviousActionKey.self] }
    set { self[FindPreviousActionKey.self] = newValue }
  }

  /// Whether schema visualizer is active
  var isSchemaVisualizerActive: Bool? {
    get { self[IsSchemaVisualizerActiveKey.self] }
    set { self[IsSchemaVisualizerActiveKey.self] = newValue }
  }
}

/// FocusedValue key for left sidebar toggle action.
struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for right sidebar toggle action.
struct ToggleRightSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for schema visualizer active state.
struct IsSchemaVisualizerActiveKey: FocusedValueKey {
  typealias Value = Bool
}

/// FocusedValue key for opening search panel.
struct OpenSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for find next match.
struct FindNextActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for find previous match.
struct FindPreviousActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

// MARK: - Shared Commands

struct SharedCommands: Commands {
  var body: some Commands {
    // About command
    CommandGroup(replacing: .appInfo) {
      Button("About Dblore") {
        showAboutWindow()
      }
    }

    // Owns the system Settings slot, so Cmd+, opens this modal in notebook, SQL,
    // and data viewer instead of a second SwiftUI Settings window.
    CommandGroup(replacing: .appSettings) {
      Button("Settings") {
        NotificationCenter.default.post(name: .openSettings, object: nil)
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandGroup(after: .appInfo) {
      CheckForUpdatesButton()
    }

    // Cell and staged grid edits live on the view model's undo manager, not the text
    // view's. No key equivalent: Cmd+Z stays on the system Undo item.
    CommandGroup(after: .undoRedo) {
      CellUndoCommandButtons()
    }
  }

  private func showAboutWindow() {
    let aboutView = AboutView()
    let hostingController = NSHostingController(rootView: aboutView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "About Dblore"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
  }
}

/// "Check for Updates" menu item; observes the updater so the disabled state stays current.
private struct CheckForUpdatesButton: View {
  @ObservedObject private var updater = UpdaterController.shared

  var body: some View {
    Button("Check for Updates") {
      updater.checkForUpdates()
    }
    .disabled(!updater.canCheckForUpdates)
  }
}

/// Edit menu items for the focused notebook or data viewer undo stack.
private struct CellUndoCommandButtons: View {
  @ObservedObject private var refresh = CellUndoMenuRefresh.shared
  @FocusedValue(\.activeViewModel) private var activeViewModel: NotebookViewModel?

  var body: some View {
    let _ = refresh.revision
    Button(title(prefix: "Undo", actionName: cellUndoTarget?.undoManager.undoActionName)) {
      cellUndoTarget?.undoCellChange()
    }
    .disabled(cellUndoTarget?.undoManager.canUndo != true)

    Button(title(prefix: "Redo", actionName: cellUndoTarget?.undoManager.redoActionName)) {
      cellUndoTarget?.redoCellChange()
    }
    .disabled(cellUndoTarget?.undoManager.canRedo != true)
  }

  /// Notebook tabs and data viewer tabs. A plain SQL editor keeps the system items only.
  private var cellUndoTarget: NotebookViewModel? {
    guard let activeViewModel else { return nil }
    guard activeViewModel.viewMode == .notebook || activeViewModel.dataViewer != nil else {
      return nil
    }
    return activeViewModel
  }

  /// Empty stack (no action name) stays "Undo Cell Change" / "Redo Cell Change".
  private func title(prefix: String, actionName: String?) -> String {
    guard let actionName, !actionName.isEmpty else { return "\(prefix) Cell Change" }
    return "\(prefix) \(actionName)"
  }
}

/// Republishes so the cell undo titles match the focused view model's undo manager.
/// `removeAllActions` does not close a group; opening a menu reads the stack again.
@MainActor
private final class CellUndoMenuRefresh: ObservableObject {
  static let shared = CellUndoMenuRefresh()

  @Published private(set) var revision = 0
  private var tokens: [any NSObjectProtocol] = []
  private var didRefreshForTracking = false

  private init() {
    let stackNames: [Notification.Name] = [
      .NSUndoManagerDidCloseUndoGroup,
      .NSUndoManagerDidUndoChange,
      .NSUndoManagerDidRedoChange,
    ]
    for name in stackNames {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated {
            CellUndoMenuRefresh.shared.revision += 1
          }
        })
    }
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          CellUndoMenuRefresh.shared.menuDidBeginTracking()
        }
      })
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          CellUndoMenuRefresh.shared.menuDidEndTracking()
        }
      })
  }

  /// One refresh per tracking session, so rebuilding the items cannot loop.
  private func menuDidBeginTracking() {
    guard !didRefreshForTracking else { return }
    didRefreshForTracking = true
    revision += 1
  }

  private func menuDidEndTracking() {
    didRefreshForTracking = false
  }
}

// MARK: - Tab Commands

struct TabCommands: Commands {
  // Note: All tab operations now go through WorkspaceManager
  // No fallback to legacy TabStateManager.shared

  var body: some Commands {
    // File menu - New documents (includes workspace commands)
    CommandGroup(replacing: .newItem) {
      // Workspace commands first
      Button {
        let manager = WorkspaceWindowManager.shared.newWorkspace()
        WorkspaceWindowManager.shared.pendingWorkspaceId = manager.id
      } label: {
        Label("New Workspace", systemImage: "folder.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .control])

      Button {
        Task {
          if let manager = await openWorkspaceWithPanel() {
            WorkspaceWindowManager.shared.pendingWorkspaceId = manager.id
          }
        }
      } label: {
        Label("Open Workspace", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])

      // Recent Workspaces submenu
      Menu("Open Recent Workspace") {
        ForEach(RecentManager.shared.recentWorkspaces.prefix(10)) { workspace in
          Button(workspace.displayString) {
            Task {
              if let manager = try? await WorkspaceWindowManager.shared.openWorkspace(
                url: workspace.fileURL)
              {
                WorkspaceWindowManager.shared.pendingWorkspaceId = manager.id
              }
            }
          }
        }

        if !RecentManager.shared.recentWorkspaces.isEmpty {
          Divider()
          Button("Clear Recent Workspaces") {
            RecentManager.shared.clearWorkspaces()
          }
        }
      }
      .disabled(RecentManager.shared.recentWorkspaces.isEmpty)

      Divider()

      // Document commands - create workspace if needed
      Button {
        let manager = activeWorkspaceOrNew
        switch AppSettings.shared.defaultNewTabType {
        case .notebook: manager.newNotebook()
        case .sqlFile: manager.newSQLFile()
        }
      } label: {
        Label("New Tab", systemImage: "plus.square")
      }
      .keyboardShortcut("t", modifiers: .command)

      Button {
        let manager = activeWorkspaceOrNew
        manager.newNotebook()
      } label: {
        Label("New Notebook", systemImage: "doc.badge.plus")
      }

      Button {
        let manager = activeWorkspaceOrNew
        manager.newSQLFile()
      } label: {
        Label("New SQL File", systemImage: "doc.text")
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])

      Divider()

      Button {
        openFile()
      } label: {
        Label("Open", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: .command)
    }

    // File menu - Save
    CommandGroup(replacing: .saveItem) {
      Button {
        // If active tab, save tab; otherwise save workspace
        if activeTabId != nil {
          saveActiveTab()
        } else {
          saveActiveWorkspace()
        }
      } label: {
        Text("Save")
      }
      .keyboardShortcut("s", modifiers: .command)

      Button {
        // If active tab, save as; otherwise save workspace as
        if activeTabId != nil {
          saveActiveTabAs()
        } else {
          saveActiveWorkspaceAs()
        }
      } label: {
        Text("Save As")
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])

      // Workspace save commands live here: a separate CommandGroup(after: .saveItem)
      // is dropped by SwiftUI because this group replaces .saveItem
      Divider()

      Button("Save Workspace") {
        saveActiveWorkspace()
      }
      .keyboardShortcut("s", modifiers: [.command, .option])

      Button("Save Workspace As") {
        saveActiveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .option, .shift])
      .disabled(WorkspaceWindowManager.shared.activeWorkspace?.workspace.isSaved != true)

      Divider()

      Button("Close Workspace") {
        Task {
          _ = await WorkspaceWindowManager.shared.closeActiveWorkspace()
        }
      }
      .keyboardShortcut("w", modifiers: [.command, .option])
    }

    // Window menu - Tab navigation
    CommandGroup(after: .windowArrangement) {
      Divider()

      Button("New Window Tab") {
        NewWindowStore.shared.openWelcomeWindowTab()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button("Close Tab") {
        if let workspaceManager = WorkspaceWindowManager.shared.activeWorkspaceManager,
          let id = workspaceManager.activeTabId
        {
          workspaceManager.requestCloseTab(id: id)
        }
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(activeTabId == nil)

      Button("Reopen Closed Tab") {
        Task {
          do {
            try await WorkspaceWindowManager.shared.activeWorkspaceManager?.reopenClosedTab()
          } catch {
            WorkspaceWindowManager.shared.showToast(
              "Could not reopen tab: \(error.localizedDescription)", type: .warning)
          }
        }
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])
      .disabled(WorkspaceWindowManager.shared.activeWorkspaceManager?.canReopenClosedTab != true)

      Divider()

      Button("Next Tab") {
        WorkspaceWindowManager.shared.activeWorkspaceManager?.selectNextTab()
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])
      .disabled(activeTabCount < 2)

      Button("Previous Tab") {
        WorkspaceWindowManager.shared.activeWorkspaceManager?.selectPreviousTab()
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
      .disabled(activeTabCount < 2)

      Divider()

      // Tab shortcuts 1-9 (only show if tabs exist)
      ForEach(Array(activeTabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
        Button("Tab \(index + 1): \(tab.title)") {
          WorkspaceWindowManager.shared.activeWorkspaceManager?.selectTab(atIndex: index + 1)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
      }
    }
  }

  /// Get active workspace or create new one
  private var activeWorkspaceOrNew: WorkspaceManager {
    WorkspaceWindowManager.shared.activeWorkspaceManager
      ?? WorkspaceWindowManager.shared.newWorkspace()
  }

  /// Get active tab ID from workspace manager
  private var activeTabId: UUID? {
    WorkspaceWindowManager.shared.activeWorkspaceManager?.activeTabId
  }

  /// Get tab count from workspace manager
  private var activeTabCount: Int {
    WorkspaceWindowManager.shared.activeWorkspaceManager?.tabs.count ?? 0
  }

  /// Get tabs from workspace manager
  private var activeTabs: [TabItem] {
    WorkspaceWindowManager.shared.activeWorkspaceManager?.tabs ?? []
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.dblore, .sql]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        var manager = WorkspaceWindowManager.shared.activeWorkspaceManager
        if manager == nil {
          manager = WorkspaceWindowManager.shared.newWorkspace()
          WorkspaceWindowManager.shared.pendingWorkspaceId = manager!.id
        }
        for url in panel.urls {
          try? await manager?.openFile(url: url)
        }
      }
    }
  }

  /// Open workspace with file panel and return the manager
  private func openWorkspaceWithPanel() async -> WorkspaceManager? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = UTType.sqlWorkspaceOpenTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a workspace file to open"

    let response = await withCheckedContinuation { continuation in
      panel.begin { result in
        continuation.resume(returning: result)
      }
    }

    if response == .OK, let url = panel.url {
      do {
        return try await WorkspaceWindowManager.shared.openWorkspace(url: url)
      } catch {
        await AppLogger.shared.error("Failed to open workspace: \(error)", category: "Workspace")
        return nil
      }
    }
    return nil
  }

  private func saveActiveTab() {
    guard let manager = WorkspaceWindowManager.shared.activeWorkspaceManager,
      let id = manager.activeTabId
    else { return }
    Task {
      try? await manager.saveTab(id: id)
    }
  }

  private func saveActiveTabAs() {
    guard let manager = WorkspaceWindowManager.shared.activeWorkspaceManager,
      let id = manager.activeTabId,
      let index = manager.tabs.firstIndex(where: { $0.id == id })
    else { return }
    // For Save As, we clear the fileURL first to force save panel
    manager.tabs[index].fileURL = nil
    Task {
      try? await manager.saveTab(id: id)
    }
  }

  private func saveActiveWorkspace() {
    guard let workspace = WorkspaceWindowManager.shared.activeWorkspace else { return }
    Task {
      try? await workspace.saveWorkspace()
    }
  }

  private func saveActiveWorkspaceAs() {
    guard let workspace = WorkspaceWindowManager.shared.activeWorkspace else { return }
    Task {
      try? await workspace.saveWorkspaceWithPanel()
    }
  }
}

// MARK: - Notebook Commands (chỉ cho Notebook mode)

struct NotebookCommands: Commands {
  @FocusedValue(\.isCellValueEditing) private var isCellValueEditing: Bool?
  @FocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction
  @FocusedValue(\.openSearchAction) private var openSearchAction
  @FocusedValue(\.findNextAction) private var findNextAction
  @FocusedValue(\.findPreviousAction) private var findPreviousAction

  var body: some Commands {
    // Chỉ show Cell menu khi documentMode == .notebook
    if documentMode == .notebook {
      // Cell commands
      CommandMenu("Cell") {
        Button("Add New") {
          NotificationCenter.default.post(name: .addCodeCell, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Divider()
        Button("Run Cell") {
          NotificationCenter.default.post(name: .runCell, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .control)

        Button("Run Cell and Select Next") {
          NotificationCenter.default.post(name: .runCellAndSelectNext, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .shift)

        Button("Run Cell and Insert Below") {
          NotificationCenter.default.post(name: .runCellAndInsertBelow, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .option)

        Button("Run All Cells") {
          NotificationCenter.default.post(name: .runAllCells, object: nil)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])

        Divider()

        ExplainCommandButtons()

        Divider()

        Button("Clear Cell Output") {
          NotificationCenter.default.post(name: .clearCellOutput, object: nil)
        }

        Button("Clear All Outputs") {
          NotificationCenter.default.post(name: .clearAllOutputs, object: nil)
        }

        Divider()

        Button("Delete Cell") {
          NotificationCenter.default.post(name: .deleteCell, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: .command)

        Button("Duplicate Cell") {
          NotificationCenter.default.post(name: .duplicateCell, object: nil)
        }
        .keyboardShortcut("d", modifiers: .command)
      }

      // View commands - use focused actions for tab-specific behavior
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          toggleRightSidebarAction?()
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
      }

      // Edit commands - use focused actions for tab-specific behavior
      CommandMenu("Edit") {
        Button("Find in Notebook") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
      }
    }
  }
}

// MARK: - Editor Commands (chỉ cho Editor mode)

struct EditorCommands: Commands {
  @FocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction
  @FocusedValue(\.openSearchAction) private var openSearchAction
  @FocusedValue(\.findNextAction) private var findNextAction
  @FocusedValue(\.findPreviousAction) private var findPreviousAction

  var body: some Commands {
    // Chỉ show khi documentMode == .editor
    if documentMode == .editor {
      // Query menu for editor mode
      CommandMenu("Query") {
        Button("Run") {
          NotificationCenter.default.post(name: .runEditorQuery, object: nil)
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("Run (Alt)") {
          NotificationCenter.default.post(name: .runEditorQuery, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .command)

        Divider()

        ExplainCommandButtons()
      }

      // Edit commands - use focused actions for tab-specific behavior
      CommandMenu("Edit") {
        Button("Find") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
      }

      // View Menu - Sidebar toggles
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          toggleRightSidebarAction?()
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Divider()

        Button {
          AppSettings.shared.wordWrapEnabled.toggle()
        } label: {
          if AppSettings.shared.wordWrapEnabled {
            Label("Disable Word Wrap", systemImage: "text.alignleft")
          } else {
            Label("Enable Word Wrap", systemImage: "text.word.spacing")
          }
        }
        .keyboardShortcut("z", modifiers: .option)
      }
    }
  }
}

// MARK: - Schema Visualizer Commands

struct SchemaVisualizerCommands: Commands {
  @FocusedValue(\.isSchemaVisualizerActive) private var isSchemaVisualizerActive: Bool?
  @FocusedValue(\.openSearchAction) private var openSearchAction
  @FocusedValue(\.findNextAction) private var findNextAction
  @FocusedValue(\.findPreviousAction) private var findPreviousAction
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction

  var body: some Commands {
    // Only show when schema visualizer is active
    if isSchemaVisualizerActive == true {
      // Edit commands for schema search
      CommandMenu("Edit") {
        Button("Find in Schema") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
      }

      // View commands
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)
      }
    }
  }
}

/// Explain actions for the Cell and Query menus. Shortcuts stay on these items.
private struct ExplainCommandButtons: View {
  @FocusedValue(\.activeViewModel) private var activeViewModel: NotebookViewModel?

  private var isDisabled: Bool {
    guard let activeViewModel else { return true }
    return activeViewModel.viewMode == .editor && activeViewModel.dataViewer != nil
  }

  var body: some View {
    Button("Explain") {
      NotificationCenter.default.post(name: .explainStatement, object: nil)
    }
    .keyboardShortcut("e", modifiers: .command)
    .disabled(isDisabled)

    Button("Explain Analyze (runs the statement)") {
      NotificationCenter.default.post(name: .explainAnalyzeStatement, object: nil)
    }
    .keyboardShortcut("e", modifiers: [.command, .shift])
    .disabled(isDisabled || activeViewModel?.canExplainAnalyze == false)
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let addCodeCell = Notification.Name("addCodeCell")
  static let runCell = Notification.Name("runCell")
  static let runCellAndSelectNext = Notification.Name("runCellAndSelectNext")
  static let runCellAndInsertBelow = Notification.Name("runCellAndInsertBelow")
  static let runAllCells = Notification.Name("runAllCells")
  static let clearCellOutput = Notification.Name("clearCellOutput")
  static let clearAllOutputs = Notification.Name("clearAllOutputs")
  static let deleteCell = Notification.Name("deleteCell")
  static let duplicateCell = Notification.Name("duplicateCell")
  static let toggleSidebar = Notification.Name("toggleSidebar")
  static let toggleLeftSidebar = Notification.Name("toggleLeftSidebar")
  static let selectNextCell = Notification.Name("selectNextCell")
  static let selectPreviousCell = Notification.Name("selectPreviousCell")
  static let focusEditor = Notification.Name("focusEditor")
  static let unfocusEditor = Notification.Name("unfocusEditor")
  static let undo = Notification.Name("undo")
  static let redo = Notification.Name("redo")
  static let editorFocused = Notification.Name("editorFocused")
  static let editorUnfocused = Notification.Name("editorUnfocused")
  static let insertTextIntoCell = Notification.Name("insertTextIntoCell")
  static let cellValueEditingStarted = Notification.Name("cellValueEditingStarted")
  static let cellValueEditingEnded = Notification.Name("cellValueEditingEnded")
  static let openSettings = Notification.Name("openSettings")

  // Search notifications
  static let openSearch = Notification.Name("openSearch")
  static let findNext = Notification.Name("findNext")
  static let findPrevious = Notification.Name("findPrevious")
  static let highlightSearchMatch = Notification.Name("highlightSearchMatch")
  static let clearSearchHighlights = Notification.Name("clearSearchHighlights")

  // Editor mode notifications
  static let runEditorQuery = Notification.Name("runEditorQuery")
  static let explainStatement = Notification.Name("explainStatement")
  static let explainAnalyzeStatement = Notification.Name("explainAnalyzeStatement")
  static let toggleWordWrap = Notification.Name("toggleWordWrap")

  // Settings change notifications
  static let syntaxHighlightingChanged = Notification.Name("syntaxHighlightingChanged")
  static let accentColorChanged = Notification.Name("accentColorChanged")
  static let scrollToSafeModeSettings = Notification.Name("scrollToSafeModeSettings")
}
