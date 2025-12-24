//
//  SQLNoteBookApp.swift
//  SQLNotebook
//

import SwiftUI
@preconcurrency import SQLite3

@main
struct SQLNoteBookApp: App {
    init() {
        // Configure SQLite temp directory to use app's temp directory
        configureSQLiteTempDirectory()
    }
    
    var body: some Scene {
        DocumentGroup(newDocument: SQLNotebookDocument()) { file in
            ContentView(document: file.$document)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .commands {
            NotebookCommands()
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

// MARK: - Menu Commands

struct NotebookCommands: Commands {
    var body: some Commands {
        // Cell commands
        CommandGroup(after: .newItem) {
            Divider()

            Button("Add Code Cell") {
                NotificationCenter.default.post(name: .addCodeCell, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Add Markdown Cell") {
                NotificationCenter.default.post(name: .addMarkdownCell, object: nil)
            }
            .keyboardShortcut("m", modifiers: .command)
        }

        // Run commands
        CommandMenu("Cell") {
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

        // View commands
        CommandGroup(after: .sidebar) {
            Button("Toggle Right Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let addCodeCell = Notification.Name("addCodeCell")
    static let addMarkdownCell = Notification.Name("addMarkdownCell")
    static let runCell = Notification.Name("runCell")
    static let runCellAndSelectNext = Notification.Name("runCellAndSelectNext")
    static let runCellAndInsertBelow = Notification.Name("runCellAndInsertBelow")
    static let runAllCells = Notification.Name("runAllCells")
    static let clearCellOutput = Notification.Name("clearCellOutput")
    static let clearAllOutputs = Notification.Name("clearAllOutputs")
    static let deleteCell = Notification.Name("deleteCell")
    static let duplicateCell = Notification.Name("duplicateCell")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let selectNextCell = Notification.Name("selectNextCell")
    static let selectPreviousCell = Notification.Name("selectPreviousCell")
    static let focusEditor = Notification.Name("focusEditor")
    static let unfocusEditor = Notification.Name("unfocusEditor")
}
