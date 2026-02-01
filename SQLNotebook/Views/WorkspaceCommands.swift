//
//  WorkspaceCommands.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

// MARK: - Workspace Commands

struct WorkspaceCommands: Commands {
  @FocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction

  var body: some Commands {
    // Sidebar toggle commands - only show when no document is open
    // (NotebookCommands and EditorCommands handle their own modes)
    if documentMode == nil {
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
    }

    // Workspace save commands (after standard save)
    // Note: New/Open workspace commands are now in TabCommands to avoid CommandGroup conflicts
    CommandGroup(after: .saveItem) {
      Divider()

      Button("Save Workspace") {
        saveActiveWorkspace()
      }
      .keyboardShortcut("s", modifiers: [.command, .option])

      Button("Save Workspace As...") {
        saveActiveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .option, .shift])

      Divider()

      Button("Close Workspace") {
        closeActiveWorkspace()
      }
      .keyboardShortcut("w", modifiers: [.command, .option])
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

  private func closeActiveWorkspace() {
    Task {
      _ = await WorkspaceWindowManager.shared.closeActiveWorkspace()
    }
  }
}

// MARK: - FocusedValue for Workspace

struct ActiveWorkspaceKey: FocusedValueKey {
  typealias Value = WorkspaceManager
}

extension FocusedValues {
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
