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
  @FocusedValue(\.toggleAIAssistantAction) private var toggleAIAssistantAction

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

    CommandGroup(after: .sidebar) {
      Button {
        toggleAIAssistantAction?()
      } label: {
        Label("Toggle AI Assistant", systemImage: "sparkles")
      }
      .keyboardShortcut("l", modifiers: .command)
      .disabled(toggleAIAssistantAction == nil)
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

extension FocusedValues {
  var toggleAIAssistantAction: (() -> Void)? {
    get { self[ToggleAIAssistantActionKey.self] }
    set { self[ToggleAIAssistantActionKey.self] = newValue }
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
