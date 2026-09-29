//
//  WorkspaceCommands.swift
//  Dblore
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
