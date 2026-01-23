//
//  SQLNotebookApp.swift
//  SQLNotebook
//

import AppKit
@preconcurrency import SQLite3
import SwiftUI

@main
struct SQLNotebookApp: App {
  init() {
    // Migrate from single session to connection history (one-time operation)
    SessionManager.migrateIfNeeded()

    // Configure SQLite temp directory to use app's temp directory
    configureSQLiteTempDirectory()
  }

  var body: some Scene {
    // Scene 1: Notebook documents (.sqlnb)
    DocumentGroup(newDocument: { SQLNotebookDocument() }) { file in
      NotebookContentView(document: file.document)
        .frame(minWidth: 800, minHeight: 600)
    }
    .commands {
      // Shared commands (About, Settings) - chỉ add ở scene đầu tiên
      SharedCommands()
      // New Document commands (File > New...) - chỉ add ở scene đầu tiên
      NewDocumentCommands()
      // Notebook-specific commands (Cell menu, sidebars, search)
      NotebookCommands()
    }
    .defaultSize(width: 1200, height: 800)

    // Scene 2: SQL Editor documents (.sql)
    DocumentGroup(newDocument: { SQLEditorDocument() }) { file in
      EditorContentView(document: file.document)
        .frame(minWidth: 800, minHeight: 600)
    }
    .commands {
      // Editor-specific commands (chỉ có sidebar toggle)
      EditorCommands()
    }
    .defaultSize(width: 1200, height: 800)
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

/// Represents the document type/mode of the currently focused window.
///
/// Used to dynamically show/hide menu commands based on whether a Notebook (.sqlnb)
/// or Editor (.sql) window is currently focused. When user switches between windows,
/// this value automatically updates, causing menus to update without needing to
/// re-render the entire app.
///
/// Example:
/// ```
/// // In NotebookContentView
/// .focusedSceneValue(\.documentMode, .notebook)
///
/// // In NotebookCommands
/// @FocusedValue(\.documentMode) private var documentMode: DocumentMode?
/// if documentMode == .notebook { ... }  // Show Cell menu only for notebook
/// ```
enum DocumentMode {
  case notebook  // Notebook mode (.sqlnb files) - has Cell menu, custom Find
  case editor  // Editor mode (.sql files) - uses native macOS menus
}

/// FocusedValue key for tracking document mode across the app.
/// See: https://developer.apple.com/documentation/swiftui/focusedvaluekey
struct DocumentModeFocusedValueKey: FocusedValueKey {
  typealias Value = DocumentMode
}

extension FocusedValues {
  /// Accessed by menu command structs to determine which commands to show.
  /// Value is automatically set by NotebookContentView and EditorContentView
  /// via `.focusedSceneValue(\.documentMode, ...)` modifier.
  var documentMode: DocumentMode? {
    get { self[DocumentModeFocusedValueKey.self] }
    set { self[DocumentModeFocusedValueKey.self] = newValue }
  }

  /// Action to toggle the left sidebar in the focused window.
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  /// Action to toggle the right sidebar in the focused window.
  var toggleRightSidebarAction: (() -> Void)? {
    get { self[ToggleRightSidebarActionKey.self] }
    set { self[ToggleRightSidebarActionKey.self] = newValue }
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

extension FocusedValues {
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

// MARK: - Shared Commands (cho cả Notebook và Editor)

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

// MARK: - Notebook Commands (chỉ cho Notebook mode)

/// Menu commands that appear only when a Notebook window (.sqlnb) is focused.
///
/// Includes Cell menu, custom sidebar toggles, and search commands (Find in Notebook).
/// These commands are hidden when an Editor window (.sql) is focused.
///
/// Key: Uses @FocusedValue to dynamically show/hide based on `documentMode`
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
    // This conditional is the key to preventing duplicate menus in Editor mode
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

      // View commands (notebook-specific) - use focused actions for window-specific behavior
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

      // Edit commands (notebook-specific) - use focused actions for window-specific behavior
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

    // Note: We don't replace .undoRedo here to preserve native undo/redo for TextEditor
    // Custom undo/redo handling is done via key event monitoring in ContentView
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

      // Edit commands (editor-specific search) - use focused actions for window-specific behavior
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

      // View Menu - Sidebar toggles - use focused actions for window-specific behavior
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

// MARK: - New Document Commands

struct NewDocumentCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button {
        NSDocumentController.shared.newDocument(nil)
      } label: {
        Label("New Notebook", systemImage: "doc.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button {
        createNewSQLFile()
      } label: {
        Label("New SQL File", systemImage: "doc.text")
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
    }

    // Save As command
    CommandGroup(after: .saveItem) {
      Button {
        saveCurrentDocumentAs()
      } label: {
        Text("Save As...")
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }
  }

  private func createNewSQLFile() {
    // Create a new SQLEditorDocument and show save panel
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.sql]
    savePanel.nameFieldStringValue = "Untitled.sql"
    savePanel.message = "Create a new SQL file"

    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      Task { @MainActor in
        do {
          // Create empty SQL file
          try "".write(to: url, atomically: true, encoding: .utf8)

          // Open the file
          NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
            _, _, error in
            if let error = error {
              print("Failed to open SQL file: \(error)")
            }
          }
        } catch {
          print("Failed to create SQL file: \(error)")
        }
      }
    }
  }

  private func saveCurrentDocumentAs() {
    // Get the current document
    guard let currentDocument = NSDocumentController.shared.currentDocument else {
      return
    }

    // Use the built-in runModalSavePanel to show Save As dialog
    currentDocument.runModalSavePanel(for: .saveAsOperation, delegate: nil, didSave: nil, contextInfo: nil)
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
}
