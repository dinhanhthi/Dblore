//
//  AppRootView.swift
//  SQLNotebook
//
//  Root view that decides whether to show AppWelcomeView or WorkspaceContainerView

import SwiftUI

/// Root view of the application that switches between welcome screen and workspace
struct AppRootView: View {
  @Bindable private var windowManager = WorkspaceWindowManager.shared

  /// State for settings modal when no workspace is open
  @State private var isSettingsModalVisible = false

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
    // Settings modal for when no workspace is open (AppWelcomeView)
    .settingsModal(
      isPresented: $isSettingsModalVisible,
      viewMode: nil
    )
    .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
      // Only handle if showing welcome view (no workspace)
      // When workspace is active, WorkspaceContainerView handles the notification
      if windowManager.isShowingWelcome {
        isSettingsModalVisible.toggle()
      }
    }
  }
}
