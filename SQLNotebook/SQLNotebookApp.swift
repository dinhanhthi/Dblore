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
  case editor    // Editor mode (.sql files) - uses native macOS menus
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

  var body: some Commands {
    // Chỉ show Cell menu khi documentMode == .notebook
    // This conditional is the key to preventing duplicate menus in Editor mode
    if documentMode == .notebook {
      // Cell commands
      CommandMenu("Cell") {
        Button("Add New") {
          NotificationCenter.default.post(name: .addCodeCell, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)

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

      // View commands (notebook-specific)
      CommandGroup(after: .sidebar) {
        Button {
          NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          NotificationCenter.default.post(name: .toggleSidebar, object: nil)
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }

      // Edit commands (notebook-specific)
      CommandMenu("Edit") {
        Button("Find in Notebook") {
          NotificationCenter.default.post(name: .openSearch, object: nil)
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Find Next") {
          NotificationCenter.default.post(name: .findNext, object: nil)
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          NotificationCenter.default.post(name: .findPrevious, object: nil)
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

  var body: some Commands {
    // Chỉ show sidebar toggles khi documentMode == .editor
    if documentMode == .editor {
      // View Menu - Sidebar toggles (giống như Notebook mode)
      CommandGroup(after: .sidebar) {
        Button {
          NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          NotificationCenter.default.post(name: .toggleSidebar, object: nil)
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }
  }
}

// MARK: - New Document Commands

struct NewDocumentCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("New Notebook") {
        // Default Cmd+N already creates notebook, but provide explicit command
        NSDocumentController.shared.newDocument(nil)
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button("New SQL File") {
        createNewSQLFile()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
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
          NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
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
}
