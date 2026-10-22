//
//  WorkspaceCommands.swift
//  Dblore
//

import AppKit
import SwiftUI

// MARK: - Workspace Commands

struct WorkspaceCommands: Commands {
  @BridgedFocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @BridgedFocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @BridgedFocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction
  @BridgedFocusedValue(\.toggleAIAssistantAction) private var toggleAIAssistantAction
  @BridgedFocusedValue(\.openCommandPaletteAction) private var openCommandPaletteAction
  @BridgedFocusedValue(\.openDataRewindAction) private var openDataRewindAction

  var body: some Commands {
    // Sidebar toggle commands - only show when no document is open
    // (NotebookCommands and EditorCommands handle their own modes)
    if documentMode == nil || documentMode == .markdown {
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
        .disabled(documentMode == .markdown)
      }
    }

    CommandGroup(after: .sidebar) {
      Button {
        toggleAIAssistantAction?()
      } label: {
        Label("Toggle AI Assistant", systemImage: "sparkles")
      }
      .keyboardShortcut("l", modifiers: .command)
      .disabled(toggleAIAssistantAction == nil)

      Divider()

      Button {
        openCommandPaletteAction?()
      } label: {
        Label("Command Palette", systemImage: "magnifyingglass")
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(openCommandPaletteAction == nil)

      Button {
        openDataRewindAction?()
      } label: {
        Label("Data Rewind...", systemImage: "clock.arrow.circlepath")
      }
      .disabled(openDataRewindAction == nil)
    }
  }
}

// MARK: - FocusedValue for Workspace

struct ActiveWorkspaceKey: FocusedValueKey {
  typealias Value = WorkspaceManager
}

struct ToggleAIAssistantActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct OpenCommandPaletteActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct OpenTableImportActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Data Rewind (View menu): nil unless the workspace is connected to an engine that records
/// data viewer edits (`WorkspaceManager.canOpenDataRewind`)
struct OpenDataRewindActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Export SQL Dump, Restore SQL Dump, Copy Database File (File menu): nil unless the workspace
/// is connected to an engine with `supportsSQLDump` (the file copy: SQLite only). On MongoDB the
/// first two are Back Up Database and Restore Backup (`WorkspaceManager.canBackUpMongo`).
struct OpenSQLDumpActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct OpenSQLRestoreActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct OpenDatabaseFileCopyActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleAIAssistantAction: (() -> Void)? {
    get { self[ToggleAIAssistantActionKey.self] }
    set { self[ToggleAIAssistantActionKey.self] = newValue }
  }

  var openCommandPaletteAction: (() -> Void)? {
    get { self[OpenCommandPaletteActionKey.self] }
    set { self[OpenCommandPaletteActionKey.self] = newValue }
  }

  var openTableImportAction: (() -> Void)? {
    get { self[OpenTableImportActionKey.self] }
    set { self[OpenTableImportActionKey.self] = newValue }
  }

  var openDataRewindAction: (() -> Void)? {
    get { self[OpenDataRewindActionKey.self] }
    set { self[OpenDataRewindActionKey.self] = newValue }
  }

  var openSQLDumpAction: (() -> Void)? {
    get { self[OpenSQLDumpActionKey.self] }
    set { self[OpenSQLDumpActionKey.self] = newValue }
  }

  var openSQLRestoreAction: (() -> Void)? {
    get { self[OpenSQLRestoreActionKey.self] }
    set { self[OpenSQLRestoreActionKey.self] = newValue }
  }

  var openDatabaseFileCopyAction: (() -> Void)? {
    get { self[OpenDatabaseFileCopyActionKey.self] }
    set { self[OpenDatabaseFileCopyActionKey.self] = newValue }
  }

  var activeWorkspace: WorkspaceManager? {
    get { self[ActiveWorkspaceKey.self] }
    set { self[ActiveWorkspaceKey.self] = newValue }
  }
}

// MARK: - Workspace Notification Names

extension Notification.Name {
  static let openWorkspace = Notification.Name("openWorkspace")
  static let saveWorkspace = Notification.Name("saveWorkspace")
  static let closeWorkspace = Notification.Name("closeWorkspace")
  static let workspaceConnectionChanged = Notification.Name("workspaceConnectionChanged")
}
