//
//  AppRootView.swift
//  SQLNotebook
//
//  Root view that decides whether to show AppWelcomeView or WorkspaceContainerView

import SwiftUI

/// Root view of the application that switches between welcome screen and workspace
struct AppRootView: View {
  @Bindable private var windowManager = WorkspaceWindowManager.shared

  var body: some View {
    Group {
      if windowManager.isShowingWelcome {
        // No workspace open - show welcome screen
        AppWelcomeView()
      } else if let activeManager = windowManager.activeWorkspaceManager {
        // Workspace is open - show workspace container
        WorkspaceContainerView(workspaceManager: activeManager)
      } else {
        // Fallback - should not happen but show welcome anyway
        AppWelcomeView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
