//
//  SQLNotebookApp.swift
//  SQLNotebook
//

import AppKit
@preconcurrency import SQLite3
import SwiftUI

// MARK: - App Delegate for file handling

class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      for url in urls {
        let ext = url.pathExtension.lowercased()
        if ext == "sqlws" {
          // Open workspace file
          _ = try? await WorkspaceWindowManager.shared.openWorkspace(url: url)
        } else {
          // Open file in active workspace or create new one
          if let activeManager = WorkspaceWindowManager.shared.activeWorkspaceManager {
            try? await activeManager.openFile(url: url)
          } else {
            // Fallback to TabStateManager for legacy support
            try? await TabStateManager.shared.openFile(url: url)
          }
        }
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // Keep app running even when all windows are closed
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Save all workspace states
    Task { @MainActor in
      for manager in WorkspaceWindowManager.shared.workspaceManagers {
        try? await manager.saveWorkspace()
      }
    }
    // Legacy: save tab state
    TabStateManager.shared.saveState()
  }
}

@main
struct SQLNotebookApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    // Migrate from single session to connection history (one-time operation)
    SessionManager.migrateIfNeeded()

    // Configure SQLite temp directory to use app's temp directory
    configureSQLiteTempDirectory()
  }

  var body: some Scene {
    // Main window - shows AppWelcomeView when no workspace, or WorkspaceContainerView
    WindowGroup {
      AppRootView()
        .frame(minWidth: 800, minHeight: 600)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      SharedCommands()
      WorkspaceCommands()
      TabCommands(tabManager: TabStateManager.shared)
      NotebookCommands()
      EditorCommands()
    }
    .defaultSize(width: 1200, height: 800)
    .handlesExternalEvents(matching: ["sqlws", "sqlnb", "sql", "*"])
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
  case notebook  // Notebook mode (.sqlnb files) - has Cell menu, custom Find
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
}

/// FocusedValue key for left sidebar toggle action.
struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for right sidebar toggle action.
struct ToggleRightSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
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
      Button("About SQLNotebook") {
        showAboutWindow()
      }

      Divider()

      Button("Settings") {
        NotificationCenter.default.post(name: .openSettings, object: nil)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }

  private func showAboutWindow() {
    let aboutView = AboutView()
    let hostingController = NSHostingController(rootView: aboutView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "About SQLNotebook"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
  }
}

// MARK: - Tab Commands

struct TabCommands: Commands {
  let tabManager: TabStateManager

  var body: some Commands {
    // File menu - New documents (includes workspace commands)
    CommandGroup(replacing: .newItem) {
      // Workspace commands first
      Button {
        _ = WorkspaceWindowManager.shared.newWorkspace()
      } label: {
        Label("New Workspace", systemImage: "folder.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .control])

      Button {
        Task {
          await WorkspaceWindowManager.shared.openWorkspaceWithPanel()
        }
      } label: {
        Label("Open Workspace...", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])

      // Recent Workspaces submenu
      Menu("Open Recent Workspace") {
        ForEach(RecentManager.shared.recentWorkspaces.prefix(10)) { workspace in
          Button(workspace.displayString) {
            Task {
              try? await WorkspaceWindowManager.shared.openWorkspace(url: workspace.fileURL)
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

      // Document commands
      Button {
        if let manager = WorkspaceWindowManager.shared.activeWorkspaceManager {
          manager.newNotebook()
        } else {
          tabManager.newNotebook()
        }
      } label: {
        Label("New Notebook", systemImage: "doc.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button {
        if let manager = WorkspaceWindowManager.shared.activeWorkspaceManager {
          manager.newSQLFile()
        } else {
          tabManager.newSQLFile()
        }
      } label: {
        Label("New SQL File", systemImage: "doc.text")
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])

      Divider()

      Button {
        openFile()
      } label: {
        Label("Open...", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: .command)
    }

    // File menu - Save
    CommandGroup(replacing: .saveItem) {
      Button {
        // If no active tab, save workspace instead
        if tabManager.activeTabId != nil {
          saveActiveTab()
        } else {
          saveActiveWorkspace()
        }
      } label: {
        Text("Save")
      }
      .keyboardShortcut("s", modifiers: .command)

      Button {
        // If no active tab, save workspace as instead
        if tabManager.activeTabId != nil {
          saveActiveTabAs()
        } else {
          saveActiveWorkspaceAs()
        }
      } label: {
        Text("Save As...")
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }

    // Window menu - Tab navigation
    CommandGroup(after: .windowArrangement) {
      Divider()

      Button("Close Tab") {
        if let id = tabManager.activeTabId {
          tabManager.requestCloseTab(id: id)
        }
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(tabManager.activeTabId == nil)

      Divider()

      Button("Next Tab") {
        tabManager.selectNextTab()
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])
      .disabled(tabManager.tabs.count < 2)

      Button("Previous Tab") {
        tabManager.selectPreviousTab()
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
      .disabled(tabManager.tabs.count < 2)

      Divider()

      // Tab shortcuts 1-9 (only show if tabs exist)
      ForEach(Array(tabManager.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
        Button("Tab \(index + 1): \(tab.title)") {
          tabManager.selectTab(atIndex: index + 1)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
      }
    }
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.sqlNotebook, .sql]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          try? await tabManager.openFile(url: url)
        }
      }
    }
  }

  private func saveActiveTab() {
    guard let id = tabManager.activeTabId else { return }
    Task {
      try? await tabManager.saveTab(id: id)
    }
  }

  private func saveActiveTabAs() {
    guard let id = tabManager.activeTabId else { return }
    // For Save As, we clear the fileURL first to force save panel
    if let index = tabManager.tabs.firstIndex(where: { $0.id == id }) {
      tabManager.tabs[index].fileURL = nil
    }
    Task {
      try? await tabManager.saveTab(id: id)
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
        .keyboardShortcut(",", modifiers: [.command])
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
        .keyboardShortcut(",", modifiers: [.command])

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
  static let toggleWordWrap = Notification.Name("toggleWordWrap")

  // Settings change notifications
  static let syntaxHighlightingChanged = Notification.Name("syntaxHighlightingChanged")
  static let accentColorChanged = Notification.Name("accentColorChanged")
  static let scrollToSafeModeSettings = Notification.Name("scrollToSafeModeSettings")
}
